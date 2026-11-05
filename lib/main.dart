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
      final phone = prefs.getString('phone') ?? '';
      final password = prefs.getString('password') ?? '';
      final trigger1 = prefs.getDouble('trigger1') ?? 4.10;
      final trigger2 = prefs.getDouble('trigger2') ?? 1.5;

      final soundPath1 = prefs.getString('sound_path_1');
      final soundPath2 = prefs.getString('sound_path_2');

      bool alertedT1 = prefs.getBool('alerted_t1') ?? false;
      bool alertedT2 = prefs.getBool('alerted_t2') ?? false;
      bool alertedZero = prefs.getBool('alerted_zero') ?? false;

      if (phone.isEmpty || password.isEmpty) return;

      final double balance = await fetchBalanceSecurely(phone, password);

      if (balance >= 0) {
        await prefs.setDouble('last_balance', balance);

        // تنبيه الصفر العاجل (الخياط)
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

        // تشغيل صوت التنبيه الثاني
        if (balance <= trigger2 && balance > 0.0) {
          if (!alertedT2) {
            if (soundPath2 != null && File(soundPath2).existsSync()) {
              await audioPlayer.play(DeviceFileSource(soundPath2));
            }
            await prefs.setBool('alerted_t2', true);
            await prefs.setBool('alerted_t1', true);
          }
        } 
        // تشغيل صوت التنبيه الأول
        else if (balance <= trigger1 && balance > trigger2) {
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
            content: "آخر فحص ناجح كان الساعة $timeStr",
          );
        }
      }
    } catch (_) {}
  });
}

// دالة الفحص الذكية والمحدثة بآلية الضغط المتتابع
Future<double> fetchBalanceSecurely(
  String phone,
  String password, {
  void Function(String)? onLog,
}) async {
  final Completer<double> completer = Completer<double>();
  HeadlessInAppWebView? headlessWebView;
  bool isCompleted = false;

  void safeFinish(double result, String reason) {
    if (!isCompleted) {
      isCompleted = true;
      onLog?.call(reason);
      completer.complete(result);
    }
    headlessWebView?.dispose();
  }

  onLog?.call("1. فتح صفحة WE...");

  headlessWebView = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri("https://my.te.eg/#/login")),
    initialSettings: InAppWebViewSettings(
      userAgent: "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
      javaScriptEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
    ),
    onLoadStop: (controller, url) async {
      final currentUrl = url?.toString() ?? "";
      if (!currentUrl.contains("te.eg")) return;

      onLog?.call("2. تم تحميل الصفحة..");

      await Future.delayed(const Duration(seconds: 4));

      // 1. ملء الحقول أولاً وتحديث الـ State
      await controller.evaluateJavascript(source: """
        (function() {
          function forceType(input, text) {
            if(!input) return;
            input.focus();
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
            nativeSetter.call(input, text);
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            input.dispatchEvent(new Event('blur', { bubbles: true }));
          }

          var u = document.getElementById('login_loginid_input_01');
          var p = document.getElementById('login_password_input_01');
          if(u && p) {
            forceType(u, '$phone');
            forceType(p, '$password');
          }
        })();
      """);

      onLog?.call("3. تم إدخال البيانات.. فك قفل الزرار...");

      // 2. مهلة ثانية ونصف عشان Angular يفك قفل الزرار بنفسه
      await Future.delayed(const Duration(milliseconds: 1500));

      // 3. الضغط الثلاثي الجبري
      await controller.evaluateJavascript(source: """
        (function() {
          var p = document.getElementById('login_password_input_01');
          var btn = document.querySelector('button.ant-btn-primary') || 
                    document.querySelector('.ec_button_ant-btn-primary_U5RfnT');

          if(btn) {
            btn.disabled = false;
            btn.removeAttribute('disabled');
            btn.classList.remove('ant-btn-disabled');
            btn.click();
            btn.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
          }

          // محاكاة زرار Enter في خانة الباسورد كحل إضافي
          if(p) {
            p.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
            p.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
          }

          var form = document.querySelector('form');
          if(form) {
            form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
          }
        })();
      """);

      onLog?.call("4. تم الضغط والدخول.. انتظار الداشبورد..");

      await Future.delayed(const Duration(seconds: 6));

      // 4. دورة فحص الرصيد (الرقم العشري المكتشف)
      for (int i = 0; i < 15; i++) {
        await Future.delayed(const Duration(seconds: 1));

        var res = await controller.evaluateJavascript(source: """
          (function() {
            var allLeaves = Array.from(document.querySelectorAll('*')).filter(function(e) {
              return e.children.length === 0 && /^\\d+\\.\\d{2}\$/.test(e.innerText.trim());
            });
            return allLeaves.length > 0 ? allLeaves[0].innerText.trim() : null;
          })();
        """);

        if (res != null) {
          String clean = res.toString().replaceAll(RegExp(r'[^0-9.]'), '');
          double? val = double.tryParse(clean);
          if (val != null && val >= 0) {
            safeFinish(val, "نجاح! تم جلب الرصيد: $val ج.م");
            return;
          }
        }
      }

      // قراءة رسالة الخطأ النصية الحقيقية لو وجدت
      var pageText = await controller.evaluateJavascript(source: """
        (function() {
          var err = document.querySelector('.ant-message-notice') || 
                    document.querySelector('.ant-alert-message') || 
                    document.querySelector('.ant-form-item-explain-error') ||
                    document.querySelector('[role="alert"]');
          if (err && err.innerText.trim() !== "") {
            return "رسالة من WE: " + err.innerText.trim();
          }
          return "الرصيد لم يظهر، عنوان الصفحة: " + window.location.hash;
        })();
      """);

      safeFinish(-1.0, pageText?.toString() ?? "انتهى الوقت دون العثور على الرصيد");
    },
    onLoadError: (controller, url, code, message) => safeFinish(-1.0, "خطأ في الشبكة: $message"),
  );

  await headlessWebView.run();

  return completer.future.timeout(
    const Duration(seconds: 40),
    onTimeout: () {
      safeFinish(-1.0, "انتهت المهلة (40 ثانية) دون استجابة من WE");
      return -1.0;
    },
  );
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
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("حدث خطأ أثناء اختيار الملف")),
      );
    }
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

    setState(() {
      _isLoading = true;
      _statusMessage = "بدء الاتصال بـ WE...";
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('phone', _phoneController.text.trim());
    await prefs.setString('password', _passwordController.text.trim());
    await prefs.setDouble('trigger1', double.tryParse(_trigger1Controller.text) ?? 4.10);
    await prefs.setDouble('trigger2', double.tryParse(_trigger2Controller.text) ?? 1.5);

    final bal = await fetchBalanceSecurely(
      _phoneController.text.trim(),
      _passwordController.text.trim(),
      onLog: (liveMessage) {
        setState(() {
          _statusMessage = liveMessage;
        });
      },
    );

    setState(() {
      _isLoading = false;
      if (bal >= 0) {
        _currentBalance = bal;
      }
    });
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
                            : (_statusMessage.contains("خطأ") || _statusMessage.contains("تنبيه") || _statusMessage.contains("رسالة")
                                ? Colors.redAccent
                                : Colors.cyanAccent),
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
