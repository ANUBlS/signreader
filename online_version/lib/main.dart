import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';

// Ключ передаётся при сборке: --dart-define=ANTHROPIC_API_KEY=sk-ant-...
const String apiKey = String.fromEnvironment('ANTHROPIC_API_KEY');
const String model = 'claude-haiku-5-5';
const Duration scanInterval = Duration(milliseconds: 2500);
const Duration repeatCooldown = Duration(seconds: 20);
const Duration apiTimeout = Duration(seconds: 10);

const String prompt = '''
Ты — система распознавания дорожных знаков для водителя. Это кадр с видеорегистратора.
Найди ТОЛЬКО чётко видимые дорожные знаки, которые повёрнуты к камере (относятся к направлению движения водителя).
Не угадывай. Если знак размыт или не читается — пропусти его.
Ответь СТРОГО JSON без пояснений:
{"signs":[{"id":"<номер знака по ПДД/ГОСТ, например 3.24, если известен, иначе пусто>","ru":"<короткая фраза для озвучки на русском, например: Ограничение скорости 60>"}]}
Если знаков нет: {"signs":[]}
''';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  cameras = await availableCameras();
  runApp(const SignApp());
}

class SignApp extends StatelessWidget {
  const SignApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Дорожные знаки',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const SignScreen(),
    );
  }
}

class SignScreen extends StatefulWidget {
  const SignScreen({super.key});

  @override
  State<SignScreen> createState() => _SignScreenState();
}

class _SignScreenState extends State<SignScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();
  final Map<String, DateTime> _lastSpoken = {};
  Timer? _timer;

  bool _running = false;
  bool _busy = false;
  bool _muted = false;
  String _status = 'Готово';
  String _lastSign = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTts();
    _initCamera();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('ru-RU');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) {
      setState(() => _status = 'Камера не найдена');
      return;
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      await controller.setFocusMode(FocusMode.auto);
      if (!mounted) return;
      setState(() => _controller = controller);
    } catch (e) {
      setState(() => _status = 'Ошибка камеры: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _stop();
      c.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  void _toggle() => _running ? _stop() : _start();

  void _start() {
    if (apiKey.isEmpty) {
      setState(() => _status = 'Нет API ключа (--dart-define=ANTHROPIC_API_KEY)');
      return;
    }
    WakelockPlus.enable();
    _timer = Timer.periodic(scanInterval, (_) => _tick());
    setState(() {
      _running = true;
      _status = 'Сканирование...';
    });
    _speak('Распознавание знаков включено');
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    WakelockPlus.disable();
    if (mounted) {
      setState(() {
        _running = false;
        _status = 'Остановлено';
      });
    }
  }

  Future<void> _tick() async {
    final c = _controller;
    if (_busy || !_running || c == null || !c.value.isInitialized) return;
    if (c.value.isTakingPicture) return;
    _busy = true;
    try {
      final file = await c.takePicture();
      final bytes = await file.readAsBytes();
      unawaited(File(file.path).delete().catchError((_) => File(file.path)));

      final signs = await _recognize(base64Encode(bytes));
      if (!mounted) return;

      final now = DateTime.now();
      final toSpeak = <String>[];
      for (final s in signs) {
        final key = (s['id']?.toString().trim().isNotEmpty ?? false)
            ? s['id'].toString()
            : (s['ru'] ?? '').toString();
        final text = (s['ru'] ?? '').toString().trim();
        if (text.isEmpty) continue;
        final last = _lastSpoken[key];
        if (last != null && now.difference(last) < repeatCooldown) continue;
        _lastSpoken[key] = now;
        toSpeak.add(text);
      }

      setState(() {
        _status = signs.isEmpty ? 'Знаков нет' : 'Найдено: ${signs.length}';
        if (toSpeak.isNotEmpty) _lastSign = toSpeak.join('\n');
      });

      if (toSpeak.isNotEmpty) {
        HapticFeedback.mediumImpact();
        await _speak(toSpeak.join('. '));
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка: ${_short(e)}');
    } finally {
      _busy = false;
    }
  }

  Future<List<Map<String, dynamic>>> _recognize(String b64) async {
    final body = jsonEncode({
      'model': model,
      'max_tokens': 300,
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/jpeg',
                'data': b64,
              },
            },
            {'type': 'text', 'text': prompt},
          ],
        },
      ],
    });

    final res = await http
        .post(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
            'content-type': 'application/json',
          },
          body: body,
        )
        .timeout(apiTimeout);

    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${_short(utf8.decode(res.bodyBytes))}');
    }

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final content = (data['content'] as List?) ?? [];
    final text = content
        .where((b) => b is Map && b['type'] == 'text')
        .map((b) => b['text'].toString())
        .join();

    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return [];
    final parsed = jsonDecode(text.substring(start, end + 1));
    final list = (parsed is Map ? parsed['signs'] : null) as List? ?? [];
    return list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  Future<void> _speak(String text) async {
    if (_muted) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  String _short(Object o) {
    final s = o.toString();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _controller?.dispose();
    _tts.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (c != null && c.value.isInitialized)
            Center(child: CameraPreview(c))
          else
            const Center(child: CircularProgressIndicator()),

          // Статус сверху
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle,
                      size: 12, color: _running ? Colors.greenAccent : Colors.grey),
                  const SizedBox(width: 8),
                  Text(_status, style: const TextStyle(fontSize: 14)),
                ],
              ),
            ),
          ),

          // Последний знак снизу
          if (_lastSign.isNotEmpty)
            Positioned(
              left: 16,
              right: 120,
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.redAccent, width: 2),
                ),
                child: Text(
                  _lastSign,
                  style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ),

          // Кнопки справа
          Positioned(
            right: 16,
            bottom: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton(
                  heroTag: 'mute',
                  mini: true,
                  onPressed: () => setState(() => _muted = !_muted),
                  child: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.large(
                  heroTag: 'run',
                  backgroundColor: _running ? Colors.redAccent : Colors.green,
                  onPressed: _toggle,
                  child: Icon(_running ? Icons.stop : Icons.play_arrow, size: 48),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
