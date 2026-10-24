// Дорожные знаки (офлайн) — распознавание знаков Азербайджана
// и озвучка на русском. Интернет не нужен.
//
// Источник видео:
//   • камера телефона
//   • видеорегистратор 70mai по Wi-Fi (RTSP)

import 'dart:async';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'dashcam_source.dart';
import 'detector.dart';
import 'sign_phrases.dart';

// ---------------- Настройки ----------------
const double kConf = 0.55; // порог уверенности
const double kIou = 0.45; // порог NMS
const double kRoi = 1.0; // доля кадра справа (1.0 = весь кадр, 0.6 = правые 60%)
const int kConfirmFrames = 2; // знак должен быть виден N кадров подряд
const Duration kCooldown = Duration(seconds: 15); // не повторять тот же знак
const bool kUseGpu = false; // GPU-делегат (на некоторых телефонах нестабилен)
const bool kSpeakPlates = false; // озвучивать таблички 8.x
// -------------------------------------------

enum VideoSource { phone, dashcam }

const _kPrefSource = 'video_source';
const _kPrefUrl = 'dashcam_url';
const _kPrefTcp = 'dashcam_tcp';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
  // Источники
  VideoSource _source = VideoSource.phone;
  CameraController? _camera;
  DashcamSource? _dash;
  String _dashUrl = kDashcamPresets.first.url;
  bool _dashTcp = true;
  bool _dashLoopRunning = false;
  Timer? _dashWatchdog;

  Detector? _detector;
  SignLabels _labels = SignLabels([]);
  final FlutterTts _tts = FlutterTts();

  bool _running = false;
  bool _busy = false;
  bool _muted = false;
  bool _ttsOffline = true;
  String _status = 'Загрузка модели…';
  String _lastSpoken = '';
  double _inferMs = 0;
  double _fps = 0;
  DateTime _lastFrameAt = DateTime.now();
  List<Detection> _dets = const [];

  final Map<int, int> _streak = {};
  final Map<int, DateTime> _spokenAt = {};
  final List<String> _speechQueue = [];
  bool _speaking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _loadPrefs();
    try {
      final labelsText = await rootBundle.loadString('assets/labels.txt');
      _labels = SignLabels.parse(labelsText, speakPlates: kSpeakPlates);
      final model = await rootBundle.load('assets/model.tflite');
      _detector = await Detector.start(
        model: model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes),
        conf: kConf,
        iou: kIou,
        roi: kRoi,
        useGpu: kUseGpu,
      );
      final d = _detector!;
      var msg = 'Модель: ${d.inputSize}px, ${d.numClasses} классов, ${d.usingGpu ? 'GPU' : 'CPU'}';
      if (d.numClasses != _labels.length) {
        msg += ' ⚠ labels.txt: ${_labels.length} строк';
      }
      _setStatus(msg);
    } catch (e) {
      _setStatus('Модель не загружена: $e');
    }
    await _initTts();
    await _activateSource();
  }

  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      _source = p.getString(_kPrefSource) == 'dashcam' ? VideoSource.dashcam : VideoSource.phone;
      _dashUrl = p.getString(_kPrefUrl) ?? _dashUrl;
      _dashTcp = p.getBool(_kPrefTcp) ?? true;
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kPrefSource, _source == VideoSource.dashcam ? 'dashcam' : 'phone');
      await p.setString(_kPrefUrl, _dashUrl);
      await p.setBool(_kPrefTcp, _dashTcp);
    } catch (_) {}
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('ru-RU');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(true);

      // Предпочитаем русский голос, который работает без интернета.
      final voices = await _tts.getVoices;
      if (voices is List) {
        Map? offline;
        for (final v in voices) {
          if (v is! Map) continue;
          final locale = (v['locale'] ?? '').toString().toLowerCase();
          if (!locale.startsWith('ru')) continue;
          final net = (v['network_required'] ?? '0').toString();
          if (net == '0' || net == 'false') {
            offline = v;
            break;
          }
        }
        if (offline != null) {
          await _tts.setVoice({
            'name': offline['name'].toString(),
            'locale': offline['locale'].toString(),
          });
          _ttsOffline = true;
        } else {
          final any = voices.whereType<Map>().any(
              (v) => (v['locale'] ?? '').toString().toLowerCase().startsWith('ru'));
          _ttsOffline = any;
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  // ---------------- Источники видео ----------------

  Future<void> _activateSource() async {
    if (_source == VideoSource.phone) {
      await _closeDashcam();
      await _initCamera();
    } else {
      await _closeCamera();
      await _openDashcam();
    }
  }

  Future<void> _switchSource(VideoSource s) async {
    if (s == _source) return;
    final wasRunning = _running;
    await _stop();
    setState(() => _source = s);
    await _savePrefs();
    await _activateSource();
    if (wasRunning) await _start();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _setStatus('Камера не найдена');
        return;
      }
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final c = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      await c.initialize();
      await c.setFlashMode(FlashMode.off);
      if (!mounted) return;
      setState(() => _camera = c);
    } catch (e) {
      _setStatus('Ошибка камеры: $e');
    }
  }

  Future<void> _closeCamera() async {
    final c = _camera;
    _camera = null;
    if (c != null) {
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
      await c.dispose();
    }
    if (mounted) setState(() {});
  }

  Future<void> _openDashcam() async {
    await _closeDashcam();
    final bound = await DashcamSource.bindToWifi();
    final d = DashcamSource();
    setState(() => _dash = d);
    _setStatus(bound
        ? 'Подключение к регистратору…'
        : 'Подключите телефон к Wi-Fi регистратора 70mai');
    try {
      await d.open(_dashUrl, tcp: _dashTcp);
    } catch (e) {
      _setStatus('Ошибка RTSP: $e');
    }
    d.player.stream.width.listen((_) {
      if (mounted) setState(() {});
    });
    d.player.stream.error.listen((e) {
      if (e.isNotEmpty) _setStatus('Регистратор: $e');
    });
    // Если видео не пришло — подсказка и повторная попытка
    _dashWatchdog?.cancel();
    _dashWatchdog = Timer.periodic(const Duration(seconds: 10), (_) async {
      final cur = _dash;
      if (cur == null || !mounted) return;
      if (!cur.hasVideo) {
        _setStatus('Нет видео. Wi-Fi регистратора включён и телефон подключён к нему? Повтор…');
        await DashcamSource.bindToWifi();
        try {
          await cur.open(_dashUrl, tcp: _dashTcp);
        } catch (_) {}
      } else if (_status.startsWith('Нет видео') || _status.startsWith('Подключ')) {
        _setStatus('Регистратор: ${cur.width}×${cur.height}');
      }
    });
  }

  Future<void> _closeDashcam() async {
    _dashWatchdog?.cancel();
    _dashWatchdog = null;
    final d = _dash;
    _dash = null;
    if (d != null) {
      await d.dispose();
      await DashcamSource.unbindNetwork();
    }
    if (mounted) setState(() {});
  }

  // ---------------- Старт / стоп ----------------

  Future<void> _toggle() async => _running ? _stop() : _start();

  Future<void> _start() async {
    if (_detector == null) return;
    await WakelockPlus.enable();
    _streak.clear();
    if (_source == VideoSource.phone) {
      final c = _camera;
      if (c == null) return;
      await c.startImageStream(_onCameraFrame);
    } else {
      if (_dash == null) return;
      _dashLoop();
    }
    setState(() => _running = true);
    _enqueueSpeech('Распознавание знаков включено');
  }

  Future<void> _stop() async {
    _running = false;
    final c = _camera;
    if (c != null && c.value.isStreamingImages) {
      await c.stopImageStream();
    }
    await WakelockPlus.disable();
    if (mounted) {
      setState(() => _dets = const []);
    }
  }

  // ---------------- Кадры ----------------

  void _onCameraFrame(CameraImage img) {
    final d = _detector;
    if (!_running || _busy || d == null) return;
    _busy = true;

    final isBgra = img.format.group == ImageFormatGroup.bgra8888;
    final frame = <Object?>[
      img.width,
      img.height,
      isBgra,
      img.planes.map((p) => TransferableTypedData.fromList([p.bytes])).toList(),
      img.planes.map((p) => p.bytesPerRow).toList(),
      img.planes.map((p) => p.bytesPerPixel ?? 1).toList(),
    ];

    d.detect(frame).then(_onResult).catchError((e) {
      _setStatus('$e');
    }).whenComplete(() => _busy = false);
  }

  Future<void> _dashLoop() async {
    if (_dashLoopRunning) return;
    _dashLoopRunning = true;
    try {
      while (_running && _source == VideoSource.dashcam) {
        final d = _detector;
        final cam = _dash;
        if (d == null || cam == null) break;
        RawFrame? f;
        try {
          f = await cam.grab();
        } catch (_) {
          f = null;
        }
        if (f == null) {
          await Future.delayed(const Duration(milliseconds: 300));
          continue;
        }
        final frame = <Object?>[
          f.width,
          f.height,
          true, // bgr0 == раскладка BGRA
          [TransferableTypedData.fromList([f.bytes])],
          [f.stride],
          [4],
        ];
        try {
          final r = await d.detect(frame);
          _onResult(r);
        } catch (e) {
          _setStatus('$e');
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    } finally {
      _dashLoopRunning = false;
    }
  }

  void _onResult(DetectResult r) {
    final now = DateTime.now();
    final dt = now.difference(_lastFrameAt).inMilliseconds;
    _lastFrameAt = now;

    // Подтверждение: знак виден несколько кадров подряд
    final seen = <int, double>{};
    for (final d in r.detections) {
      seen[d.cls] = (seen[d.cls] ?? 0) < d.score ? d.score : seen[d.cls]!;
    }
    _streak.removeWhere((k, _) => !seen.containsKey(k));
    for (final c in seen.keys) {
      _streak[c] = (_streak[c] ?? 0) + 1;
    }

    final ready = seen.entries
        .where((e) => (_streak[e.key] ?? 0) >= kConfirmFrames)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final phrases = <String>[];
    for (final e in ready.take(2)) {
      final label = _labels[e.key];
      final phrase = label?.phrase;
      if (phrase == null) continue;
      final last = _spokenAt[e.key];
      if (last != null && now.difference(last) < kCooldown) continue;
      _spokenAt[e.key] = now;
      phrases.add(phrase);
    }

    if (!mounted || !_running) return;
    setState(() {
      _dets = r.detections;
      _inferMs = r.inferenceMs;
      if (dt > 0) _fps = _fps == 0 ? 1000 / dt : _fps * 0.8 + (1000 / dt) * 0.2;
      if (phrases.isNotEmpty) _lastSpoken = phrases.join('\n');
    });

    if (phrases.isNotEmpty) {
      HapticFeedback.mediumImpact();
      for (final p in phrases) {
        _enqueueSpeech(p);
      }
    }
  }

  // ---------------- Речь ----------------

  void _enqueueSpeech(String text) {
    if (_muted) return;
    if (_speechQueue.length > 3) _speechQueue.removeAt(0);
    _speechQueue.add(text);
    _drainSpeech();
  }

  Future<void> _drainSpeech() async {
    if (_speaking) return;
    _speaking = true;
    try {
      while (_speechQueue.isNotEmpty) {
        final t = _speechQueue.removeAt(0);
        await _tts.speak(t);
      }
    } finally {
      _speaking = false;
    }
  }

  // ---------------- Настройки регистратора ----------------

  Future<void> _openDashcamSettings() async {
    final urlCtrl = TextEditingController(text: _dashUrl);
    var tcp = _dashTcp;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Видеорегистратор 70mai'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '1. Включите Wi-Fi на регистраторе.\n'
                  '2. Подключите телефон к его сети (70mai_…). '
                  'На вопрос «нет интернета» выберите «Оставаться на связи».\n'
                  '3. Закройте официальное приложение 70mai.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                for (final p in kDashcamPresets)
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(p.name),
                    subtitle: Text(p.url, style: const TextStyle(fontSize: 11)),
                    value: p.url,
                    groupValue: urlCtrl.text,
                    onChanged: (v) => setD(() => urlCtrl.text = v ?? urlCtrl.text),
                  ),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(labelText: 'RTSP адрес'),
                  onChanged: (_) => setD(() {}),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('RTSP по TCP'),
                  subtitle: const Text('Выключите, если видео зависает'),
                  value: tcp,
                  onChanged: (v) => setD(() => tcp = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    _dashUrl = urlCtrl.text.trim();
    _dashTcp = tcp;
    await _savePrefs();
    if (_source == VideoSource.dashcam) {
      final wasRunning = _running;
      await _stop();
      await _openDashcam();
      if (wasRunning) await _start();
    } else {
      await _switchSource(VideoSource.dashcam);
    }
  }

  // ---------------- Жизненный цикл ----------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_source != VideoSource.phone) return; // регистратор продолжает работать
    final c = _camera;
    if (c == null || !c.value.isInitialized) {
      if (state == AppLifecycleState.resumed && _camera == null) _initCamera();
      return;
    }
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _stop();
      c.dispose();
      _camera = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dashWatchdog?.cancel();
    _camera?.dispose();
    _dash?.dispose();
    DashcamSource.unbindNetwork();
    _detector?.dispose();
    _tts.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------------- UI ----------------

  Widget _preview() {
    if (_source == VideoSource.phone) {
      final c = _camera;
      if (c == null || !c.value.isInitialized) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(c),
              CustomPaint(painter: _BoxPainter(_dets, _labels)),
              if (kRoi < 1.0) _roiShade(),
            ],
          ),
        ),
      );
    }

    final d = _dash;
    if (d == null) return const Center(child: CircularProgressIndicator());
    final ar = d.hasVideo ? d.width! / d.height! : 16 / 9;
    return Center(
      child: AspectRatio(
        aspectRatio: ar,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Video(
              controller: d.controller,
              controls: NoVideoControls,
              fit: BoxFit.fill,
              wakelock: false,
              pauseUponEnteringBackgroundMode: false,
            ),
            CustomPaint(painter: _BoxPainter(_dets, _labels)),
            if (kRoi < 1.0) _roiShade(),
            if (!d.hasVideo)
              const Center(
                child: Text(
                  'Ожидание видео с регистратора…',
                  style: TextStyle(fontSize: 18, color: Colors.white70),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _roiShade() => Positioned.fill(
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: 1 - kRoi,
          child: Container(color: Colors.black38),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ready = _detector != null &&
        (_source == VideoSource.phone ? _camera != null : _dash != null);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _preview(),

          // Статус
          Positioned(
            top: 12,
            left: 12,
            right: 190,
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _chip(
                  Icons.circle,
                  _running
                      ? '${_fps.toStringAsFixed(1)} к/с · ${_inferMs.toStringAsFixed(0)} мс'
                      : 'Остановлено',
                  color: _running ? Colors.greenAccent : Colors.grey,
                ),
                _chip(Icons.info_outline, _status),
                if (!_ttsOffline)
                  _chip(Icons.warning_amber, 'Нет офлайн-голоса RU (см. README)',
                      color: Colors.orangeAccent),
              ],
            ),
          ),

          // Выбор источника
          Positioned(
            top: 10,
            right: 12,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sourceButton(VideoSource.phone, Icons.phone_android, 'Телефон'),
                  _sourceButton(VideoSource.dashcam, Icons.videocam, '70mai'),
                  IconButton(
                    tooltip: 'Настройки регистратора',
                    icon: const Icon(Icons.settings, size: 20),
                    onPressed: _openDashcamSettings,
                  ),
                ],
              ),
            ),
          ),

          // Последний озвученный знак
          if (_lastSpoken.isNotEmpty)
            Positioned(
              left: 16,
              right: 130,
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.redAccent, width: 2),
                ),
                child: Text(
                  _lastSpoken,
                  style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ),

          // Кнопки
          Positioned(
            right: 16,
            bottom: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton(
                  heroTag: 'test',
                  mini: true,
                  onPressed: () => _enqueueSpeech('Ограничение скорости шестьдесят'),
                  child: const Icon(Icons.record_voice_over),
                ),
                const SizedBox(height: 10),
                FloatingActionButton(
                  heroTag: 'mute',
                  mini: true,
                  onPressed: () {
                    setState(() => _muted = !_muted);
                    if (_muted) {
                      _speechQueue.clear();
                      _tts.stop();
                    }
                  },
                  child: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.large(
                  heroTag: 'run',
                  backgroundColor: _running ? Colors.redAccent : Colors.green,
                  onPressed: ready ? _toggle : null,
                  child: Icon(_running ? Icons.stop : Icons.play_arrow, size: 48),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceButton(VideoSource s, IconData icon, String label) {
    final selected = _source == s;
    return TextButton.icon(
      onPressed: () => _switchSource(s),
      icon: Icon(icon, size: 18, color: selected ? Colors.greenAccent : Colors.white70),
      label: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.greenAccent : Colors.white70,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String text, {Color color = Colors.white70}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  final List<Detection> dets;
  final SignLabels labels;
  _BoxPainter(this.dets, this.labels);

  @override
  void paint(Canvas canvas, Size size) {
    final box = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.yellowAccent;
    for (final d in dets) {
      final r = Rect.fromLTRB(
        d.x1 * size.width,
        d.y1 * size.height,
        d.x2 * size.width,
        d.y2 * size.height,
      );
      canvas.drawRect(r, box);
      final name = labels[d.cls]?.short ?? '#${d.cls}';
      final tp = TextPainter(
        text: TextSpan(
          text: ' $name ${(d.score * 100).toStringAsFixed(0)}% ',
          style: const TextStyle(
            color: Colors.black,
            backgroundColor: Colors.yellowAccent,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset(r.left, (r.top - tp.height).clamp(0.0, size.height).toDouble()));
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) => old.dets != dets;
}
