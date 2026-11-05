import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:file_picker/file_picker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeNotifications();
  await initializeBackgroundService();
  runApp(const WeBalanceApp());
}

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> initializeNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel silentChannel = AndroidNotificationChannel(
    'we_balance_channel',
    'مراقب رصيد WE',
    description: 'خدمة فحص رصيد WE الدوري في الخلفية',
    importance: Importance.low,
  );

  const AndroidNotificationChannel zeroChannel = AndroidNotificationChannel(
    'we_zero_balance_channel',
    'تنبيه الرصيد صفر العاجل',
    description: 'إشعار قوي جداً عند انتهاء الرصيد بالكامل',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  final androidPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  await androidPlugin?.createNotificationChannel(silentChannel);
  await androidPlugin?.createNotificationChannel(zeroChannel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartBackgroundService,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'we_balance_channel',
      initialNotificationTitle: 'مراقب الرصيد WE',
      initialNotificationContent: 'في انتظار أول فحص...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(),
  );
}

@pragma('vm:entry-point')
void onStartBackgroundService(ServiceInstance service) async {
  final AudioPlayer audioPlayer = AudioPlayer();

  Timer.periodic(const Duration(minutes: 15), (timer) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final trigger1 = prefs.getDouble('trigger1') ?? 4.10;
      final trigger2 = prefs.getDouble('trigger2') ?? 1.5;

      final soundPath1 = prefs.getString('sound_path_1');
      final soundPath2 = prefs.getString('sound_path_2');

      bool alertedT1 = prefs.getBool('alerted_t1') ?? false;
      bool alertedT2 = prefs.getBool('alerted_t2') ?? false;
      bool alertedZero = prefs.getBool('alerted_zero') ?? false;

      final double balance = prefs.getDouble('last_balance') ?? -1.0;

      if (balance >= 0) {
        if (balance <= 0.0) {
          if (!alertedZero) {
            await flutterLocalNotificationsPlugin.show(
              999,
              'تنبيه عاجل من WE ⚠️',
              'أخويا الخياط رصيدك خلص وبقيت على البلاط 😂!',
              const NotificationDetails(
                android: AndroidNotificationDetails(
                  'we_zero_balance_channel',
                  'تنبيه الرصيد صفر العاجل',
                  importance: Importance.max,
                  priority: Priority.high,
                  fullScreenIntent: true,
                  playSound: true,
                  enableVibration: true,
                ),
              ),
            );
            await prefs.setBool('alerted_zero', true);
          }
        } else {
          await prefs.setBool('alerted_zero', false);
        }

        if (balance <= trigger2 && balance > 0.0) {
          if (!alertedT2) {
            if (soundPath2 != null && File(soundPath2).existsSync()) {
              await audioPlayer.play(DeviceFileSource(soundPath2));
            }
            await prefs.setBool('alerted_t2', true);
            await prefs.setBool('alerted_t1', true);
          }
        } else if (balance <= trigger1 && balance > trigger2) {
          if (!alertedT1) {
            if (soundPath1 != null && File(soundPath1).existsSync()) {
              await audioPlayer.play(DeviceFileSource(soundPath1));
            }
            await prefs.setBool('alerted_t1', true);
          }
        } else if (balance > trigger1) {
          await prefs.setBool('alerted_t1', false);
          await prefs.setBool('alerted_t2', false);
        }

        if (service is AndroidServiceInstance) {
          final now = DateTime.now();
          final timeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
          service.setForegroundNotificationInfo(
            title: "رصيدك الحالي: $balance ج.م",
            content: "آخر فحص كان الساعة $timeStr",
          );
        }
      }
    } catch (_) {}
  });
}

class WeBalanceApp extends StatelessWidget {
  const WeBalanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مراقب رصيد WE الذكي',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF9333EA),
          secondary: Color(0xFFA855F7),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _trigger1Controller = TextEditingController(text: "4.10");
  final _trigger2Controller = TextEditingController(text: "1.5");

  String? _sound1Path;
  String? _sound2Path;
  String? _sound1Name;
  String? _sound2Name;

  double _currentBalance = 0.0;
  bool _isLoading = false;
  String _statusMessage = "جاهز وبانتظار تفعيلك";
  final AudioPlayer _audioTester = AudioPlayer();

  InAppWebViewController? _webViewController;
  bool _isWebViewReady = false;

  @override
  void initState() {
    super.initState();
    _requestNotificationPermission();
    _loadSavedData();
  }

  void _requestNotificationPermission() async {
    final androidImplementation = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImplementation?.requestNotificationsPermission();
  }

  void _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _phoneController.text = prefs.getString('phone') ?? '';
      _passwordController.text = prefs.getString('password') ?? '';
      _trigger1Controller.text = (prefs.getDouble('trigger1') ?? 4.10).toString();
      _trigger2Controller.text = (prefs.getDouble('trigger2') ?? 1.5).toString();
      _currentBalance = prefs.getDouble('last_balance') ?? 0.0;

      _sound1Path = prefs.getString('sound_path_1');
      _sound2Path = prefs.getString('sound_path_2');
      if (_sound1Path != null) _sound1Name = _sound1Path!.split('/').last;
      if (_sound2Path != null) _sound2Name = _sound2Path!.split('/').last;
    });
  }

  Future<void> _pickAudioFile(int soundIndex) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        final name = result.files.single.name;
        final prefs = await SharedPreferences.getInstance();

        setState(() {
          if (soundIndex == 1) {
            _sound1Path = path;
            _sound1Name = name;
            prefs.setString('sound_path_1', path);
          } else {
            _sound2Path = path;
            _sound2Name = name;
            prefs.setString('sound_path_2', path);
          }
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("تم اختيار ملف: $name بنجاح!")),
        );
      }
    } catch (_) {}
  }

  void _testAudio(int soundIndex) async {
    final path = soundIndex == 1 ? _sound1Path : _sound2Path;
    if (path != null && File(path).existsSync()) {
      await _audioTester.play(DeviceFileSource(path));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("ارفع ملف صوتي الأول عشان تجربه!")),
      );
    }
  }

  Future<void> _saveAndCheckNow() async {
    if (_phoneController.text.trim().isEmpty || _passwordController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("يرجى إدخال الرقم وكلمة السر أولاً!")),
      );
      return;
    }

    if (_webViewController == null || !_isWebViewReady) {
      setState(() => _statusMessage = "جاري تهيئة المتصفح.. انتظر ثواني واضغط مجدداً");
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = "1. فحص الاتصال بحساب WE...";
    });

    final prefs = await SharedPreferences.getInstance();
    final phone = _phoneController.text.trim();
    final password = _passwordController.text.trim();

    await prefs.setString('phone', phone);
    await prefs.setString('password', password);
    await prefs.setDouble('trigger1', double.tryParse(_trigger1Controller.text) ?? 4.10);
    await prefs.setDouble('trigger2', double.tryParse(_trigger2Controller.text) ?? 1.5);

    try {
      // 1. الانتقال المباشر لصفحة الحساب
      await _webViewController!.loadUrl(
        urlRequest: URLRequest(url: WebUri("https://my.te.eg/#/accountoverview")),
      );

      await Future.delayed(const Duration(seconds: 4));

      // فحص هل الحساب مسجل دخول أصلاً أم في صفحة Login؟
      var currentHash = await _webViewController!.evaluateJavascript(source: "window.location.hash");
      String hashStr = currentHash?.toString() ?? "";

      // لو طلب تسجيل دخول نملأ البيانات
      if (hashStr.contains("login")) {
        setState(() => _statusMessage = "2. تسجيل الدخول بالبيانات...");

        await _webViewController!.evaluateJavascript(source: """
          (function() {
            function forceType(input, text) {
              if(!input) return;
              input.focus();
              var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
              nativeSetter.call(input, text);
              input.dispatchEvent(new Event('input', { bubbles: true }));
              input.dispatchEvent(new Event('change', { bubbles: true }));
              input.blur();
            }

            var u = document.getElementById('login_loginid_input_01');
            var p = document.getElementById('login_password_input_01');
            if(u && p) {
              forceType(u, '$phone');
              forceType(p, '$password');
            }
          })();
        """);

        await Future.delayed(const Duration(milliseconds: 1500));

        await _webViewController!.evaluateJavascript(source: """
          (function() {
            var btn = document.querySelector('button.ant-btn-primary') || 
                      document.querySelector('.ec_button_ant-btn-primary_U5RfnT');
            if(btn) {
              btn.disabled = false;
              btn.removeAttribute('disabled');
              btn.click();
              btn.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            }
          })();
        """);

        setState(() => _statusMessage = "3. تم الدخول! انتظار الداشبورد...");
        await Future.delayed(const Duration(seconds: 6));
      }

      // 2. كسر أي تحويل لصفحات رخمة وتوجيهه للداشبورد إجبارياً
      await _webViewController!.evaluateJavascript(source: """
        (function() {
          if (window.location.hash.indexOf('accountoverview') === -1) {
            window.location.hash = '#/accountoverview';
          }
          // محاولة إغلاق أي إعلانات أو نوافذ منبثقة
          var closeBtn = document.querySelector('.ant-modal-close') || 
                         document.querySelector('[aria-label="Close"]') ||
                         document.querySelector('.close-btn');
          if (closeBtn) closeBtn.click();
        })();
      """);

      await Future.delayed(const Duration(seconds: 3));

      // 3. دورة استخراج الرصيد
      double foundBalance = -1.0;
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(seconds: 1));

        var res = await _webViewController!.evaluateJavascript(source: """
          (function() {
            var allElements = Array.from(document.querySelectorAll('*')).filter(function(e) {
              var t = e.innerText ? e.innerText.trim() : '';
              return e.children.length === 0 && /^\\d+(\\.\\d{1,2})?\$/.test(t) && parseFloat(t) < 5000;
            });

            if (allElements.length > 0) {
              return allElements[0].innerText.trim();
            }

            var matches = document.body.innerText.match(/\\b\\d+\\.\\d{2}\\b/);
            if (matches) return matches[0];

            return null;
          })();
        """);

        if (res != null) {
          String clean = res.toString().replaceAll(RegExp(r'[^0-9.]'), '');
          double? val = double.tryParse(clean);
          if (val != null && val >= 0) {
            foundBalance = val;
            break;
          }
        }
      }

      if (foundBalance >= 0) {
        setState(() {
          _currentBalance = foundBalance;
          _statusMessage = "نجاح! تم سحب الرصيد: $foundBalance ج.م";
        });
        await prefs.setDouble('last_balance', foundBalance);
      } else {
        var pageHash = await _webViewController!.evaluateJavascript(source: "window.location.hash");
        setState(() {
          _statusMessage = "تم التخطي بنجاح لكن الرصيد يحتاج ثوانٍ إضافية ($pageHash)";
        });
      }
    } catch (e) {
      setState(() => _statusMessage = "حدث خطأ: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("مراقب رصيد WE الذكي"),
        centerTitle: true,
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.purple.withOpacity(0.4)),
              ),
              child: Column(
                children: [
                  const Text("الرصيد المتبقي", style: TextStyle(color: Colors.grey, fontSize: 14)),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _currentBalance.toStringAsFixed(2),
                        style: const TextStyle(fontSize: 44, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 6),
                      const Text("ج.م", style: TextStyle(fontSize: 18, color: Colors.purpleAccent)),
                    ],
                  ),
                  const SizedBox(height: 14),

                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: _statusMessage.contains("نجاح")
                            ? Colors.greenAccent
                            : Colors.cyanAccent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // إعدادات الأصوات
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("إعدادات أصوات التنبيه (تسجيلات دوبلي)",
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.purpleAccent)),
                  const SizedBox(height: 15),
                  
                  _buildCustomAudioTrigger(
                    label: "مبلغ التنبيه الأول",
                    controller: _trigger1Controller,
                    soundIdx: 1,
                    fileName: _sound1Name,
                  ),
                  const Divider(height: 28, color: Colors.white10),

                  _buildCustomAudioTrigger(
                    label: "مبلغ التنبيه الثاني (الحرج)",
                    controller: _trigger2Controller,
                    soundIdx: 2,
                    fileName: _sound2Name,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // بيانات الحساب
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: "رقم موبايل WE أو النت المنزلي",
                      prefixIcon: Icon(Icons.phone_android),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: "كلمة المرور",
                      prefixIcon: Icon(Icons.lock),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _saveAndCheckNow,
                      icon: _isLoading ? const SizedBox.shrink() : const Icon(Icons.sync),
                      label: _isLoading
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text("حفظ وتحديث الرصيد الآن", style: TextStyle(fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // المتصفح الحقيقي المدمج
            Container(
              height: 260,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
              ),
              clipBehavior: Clip.antiAlias,
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri("https://my.te.eg/#/accountoverview")),
                initialSettings: InAppWebViewSettings(
                  userAgent: "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  databaseEnabled: true,
                  cacheEnabled: true,
                ),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                },
                onLoadStop: (controller, url) {
                  setState(() {
                    _isWebViewReady = true;
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomAudioTrigger({
    required String label,
    required TextEditingController controller,
    required int soundIdx,
    required String? fileName,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => _pickAudioFile(soundIdx),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF334155),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: fileName != null ? Colors.greenAccent : Colors.purple.withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  fileName != null ? Icons.check_circle : Icons.upload_file,
                  color: fileName != null ? Colors.greenAccent : Colors.purpleAccent,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    fileName != null ? "الملف المختار: $fileName" : "اضغط هنا لرفع تسجيل الصوت من الموبايل 📤",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: fileName != null ? FontWeight.bold : FontWeight.normal,
                      color: fileName != null ? Colors.greenAccent : Colors.white70,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            IconButton(
              icon: Icon(Icons.volume_up, size: 34, color: soundIdx == 1 ? Colors.purpleAccent : Colors.amber),
              onPressed: () => _testAudio(soundIdx),
              tooltip: "تجربة الصوت",
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: label,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
