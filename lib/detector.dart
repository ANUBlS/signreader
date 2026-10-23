// Офлайн-детектор дорожных знаков: YOLO (Ultralytics) в формате TFLite.
// Вся обработка (конвертация кадра, инференс, NMS) идёт в отдельном изоляте,
// чтобы не тормозить интерфейс.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

class Detection {
  final int cls;
  final double score;
  // Координаты нормализованы (0..1) относительно исходного кадра камеры.
  final double x1, y1, x2, y2;
  const Detection(this.cls, this.score, this.x1, this.y1, this.x2, this.y2);
}

class DetectResult {
  final double inferenceMs;
  final List<Detection> detections;
  const DetectResult(this.inferenceMs, this.detections);
}

class Detector {
  Detector._();

  late final Isolate _isolate;
  late final SendPort _toWorker;
  final ReceivePort _fromWorker = ReceivePort();
  Completer<DetectResult>? _pending;

  int inputSize = 0;
  int numClasses = 0;
  bool usingGpu = false;

  /// Запускает изолят и загружает модель.
  static Future<Detector> start({
    required Uint8List model,
    double conf = 0.5,
    double iou = 0.45,
    double roi = 1.0,
    bool useGpu = false,
  }) async {
    final d = Detector._();
    final portReady = Completer<SendPort>();
    final infoReady = Completer<Map>();

    d._fromWorker.listen((msg) {
      if (msg is SendPort) {
        portReady.complete(msg);
      } else if (msg is Map) {
        infoReady.complete(msg);
      } else if (msg is Float64List) {
        final p = d._pending;
        d._pending = null;
        p?.complete(_decode(msg));
      } else if (msg is String) {
        final p = d._pending;
        d._pending = null;
        p?.completeError(Exception(msg));
      }
    });

    d._isolate = await Isolate.spawn<List<Object?>>(
      _workerMain,
      [
        d._fromWorker.sendPort,
        TransferableTypedData.fromList([model]),
        conf,
        iou,
        roi,
        useGpu,
      ],
      debugName: 'sign-detector',
    );

    d._toWorker = await portReady.future;
    final info = await infoReady.future;
    if (info['ok'] != true) {
      d.dispose();
      throw Exception(info['error'] ?? 'Не удалось загрузить модель');
    }
    d.inputSize = info['input'] as int;
    d.numClasses = info['classes'] as int;
    d.usingGpu = info['gpu'] as bool;
    return d;
  }

  bool get busy => _pending != null;

  /// frame: [width, height, isBgra, planes(List<TransferableTypedData>),
  ///         rowStrides(List<int>), pixelStrides(List<int>)]
  Future<DetectResult> detect(List<Object?> frame) {
    if (_pending != null) {
      return Future.error(StateError('Детектор занят'));
    }
    final c = Completer<DetectResult>();
    _pending = c;
    _toWorker.send(frame);
    return c.future;
  }

  void dispose() {
    try {
      _toWorker.send(null);
    } catch (_) {}
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  static DetectResult _decode(Float64List f) {
    final ms = f[0];
    final n = f[1].toInt();
    final out = <Detection>[];
    for (var i = 0; i < n; i++) {
      final o = 2 + i * 6;
      out.add(Detection(f[o].toInt(), f[o + 1], f[o + 2], f[o + 3], f[o + 4], f[o + 5]));
    }
    return DetectResult(ms, out);
  }
}

// ---------------------------------------------------------------------------
// Изолят-обработчик
// ---------------------------------------------------------------------------

@pragma('vm:entry-point')
void _workerMain(List<Object?> args) {
  final SendPort out = args[0] as SendPort;
  final Uint8List modelBytes =
      (args[1] as TransferableTypedData).materialize().asUint8List();
  final double conf = args[2] as double;
  final double iou = args[3] as double;
  final double roi = (args[4] as double).clamp(0.2, 1.0);
  final bool useGpu = args[5] as bool;

  final inbox = ReceivePort();
  out.send(inbox.sendPort);

  Interpreter? interp;
  var gpu = false;

  if (useGpu) {
    try {
      final opts = InterpreterOptions()..threads = 4;
      if (Platform.isAndroid) {
        opts.addDelegate(GpuDelegateV2());
      } else if (Platform.isIOS) {
        opts.addDelegate(GpuDelegate());
      }
      interp = Interpreter.fromBuffer(modelBytes, options: opts);
      gpu = true;
    } catch (_) {
      interp = null;
    }
  }

  if (interp == null) {
    try {
      interp = Interpreter.fromBuffer(
        modelBytes,
        options: InterpreterOptions()..threads = 4,
      );
    } catch (e) {
      out.send({'ok': false, 'error': 'Ошибка загрузки модели: $e'});
      inbox.close();
      return;
    }
  }

  final Interpreter it = interp;
  final inT = it.getInputTensor(0);
  final outT = it.getOutputTensor(0);

  if (inT.type != TensorType.float32) {
    out.send({
      'ok': false,
      'error': 'Нужна float32/float16 модель (не int8). Тип входа: ${inT.type}',
    });
    it.close();
    inbox.close();
    return;
  }

  // Вход: [1, S, S, 3]
  final int s = inT.shape[1];
  // Выход: [1, 4+nc, N] (стандарт Ultralytics) или [1, N, 4+nc]
  final oShape = outT.shape;
  final bool channelsFirst = oShape[1] < oShape[2];
  final int ch = channelsFirst ? oShape[1] : oShape[2];
  final int nBoxes = channelsFirst ? oShape[2] : oShape[1];
  final int nc = ch - 4;

  out.send({'ok': true, 'input': s, 'classes': nc, 'gpu': gpu});

  final input = Float32List(s * s * 3);
  final srcX = Int32List(s);
  final srcY = Int32List(s);

  inbox.listen((msg) {
    if (msg == null) {
      it.close();
      inbox.close();
      return;
    }
    try {
      final sw = Stopwatch()..start();
      final m = msg as List<Object?>;
      final int w = m[0] as int;
      final int h = m[1] as int;
      final bool isBgra = m[2] as bool;
      final planes = (m[3] as List)
          .map((t) => (t as TransferableTypedData).materialize().asUint8List())
          .toList();
      final rowStrides = (m[4] as List).cast<int>();
      final pixStrides = (m[5] as List).cast<int>();

      // --- Letterbox + ROI (правая часть кадра) ---
      final int rx0 = ((1.0 - roi) * w).round();
      final int rw = w - rx0;
      final int rh = h;
      final double scale = math.min(s / rw, s / rh);
      final int nw = (rw * scale).round();
      final int nh = (rh * scale).round();
      final int padX = (s - nw) ~/ 2;
      final int padY = (s - nh) ~/ 2;

      for (var o = 0; o < s; o++) {
        final dx = o - padX;
        srcX[o] = (dx < 0 || dx >= nw)
            ? -1
            : (rx0 + ((dx + 0.5) / scale).floor()).clamp(rx0, w - 1).toInt();
        final dy = o - padY;
        srcY[o] = (dy < 0 || dy >= nh)
            ? -1
            : ((dy + 0.5) / scale).floor().clamp(0, h - 1).toInt();
      }

      const double pad = 114.0 / 255.0;
      var idx = 0;

      if (isBgra) {
        final p = planes[0];
        final row = rowStrides[0];
        for (var oy = 0; oy < s; oy++) {
          final sy = srcY[oy];
          for (var ox = 0; ox < s; ox++) {
            final sx = srcX[ox];
            if (sy < 0 || sx < 0) {
              input[idx++] = pad;
              input[idx++] = pad;
              input[idx++] = pad;
              continue;
            }
            final o = sy * row + sx * 4;
            input[idx++] = p[o + 2] / 255.0; // R
            input[idx++] = p[o + 1] / 255.0; // G
            input[idx++] = p[o] / 255.0; // B
          }
        }
      } else {
        // YUV420 (Android)
        final yP = planes[0], uP = planes[1], vP = planes[2];
        final yRow = rowStrides[0];
        final uRow = rowStrides[1], vRow = rowStrides[2];
        final uPix = pixStrides[1], vPix = pixStrides[2];
        for (var oy = 0; oy < s; oy++) {
          final sy = srcY[oy];
          for (var ox = 0; ox < s; ox++) {
            final sx = srcX[ox];
            if (sy < 0 || sx < 0) {
              input[idx++] = pad;
              input[idx++] = pad;
              input[idx++] = pad;
              continue;
            }
            final yv = yP[sy * yRow + sx];
            final ux = sx >> 1, uy = sy >> 1;
            final u = uP[uy * uRow + ux * uPix] - 128;
            final v = vP[uy * vRow + ux * vPix] - 128;
            var r = yv + 1.402 * v;
            var g = yv - 0.344136 * u - 0.714136 * v;
            var b = yv + 1.772 * u;
            input[idx++] = r.clamp(0.0, 255.0) / 255.0;
            input[idx++] = g.clamp(0.0, 255.0) / 255.0;
            input[idx++] = b.clamp(0.0, 255.0) / 255.0;
          }
        }
      }

      // --- Инференс ---
      it.getInputTensor(0).data = input.buffer.asUint8List();
      it.invoke();
      final raw = Uint8List.fromList(it.getOutputTensor(0).data);
      final o = raw.buffer.asFloat32List();

      double at(int c, int i) =>
          channelsFirst ? o[c * nBoxes + i] : o[i * ch + c];

      // --- Декодирование ---
      final cands = <List<double>>[]; // [cls, score, x1, y1, x2, y2] в пикселях входа
      for (var i = 0; i < nBoxes; i++) {
        var best = -1;
        var bestScore = conf;
        for (var c = 0; c < nc; c++) {
          final sc = at(4 + c, i);
          if (sc > bestScore) {
            bestScore = sc;
            best = c;
          }
        }
        if (best < 0) continue;
        var cx = at(0, i), cy = at(1, i), bw = at(2, i), bh = at(3, i);
        // TFLite-экспорт Ultralytics даёт нормализованные координаты
        if (cx <= 1.5 && cy <= 1.5 && bw <= 1.5 && bh <= 1.5) {
          cx *= s;
          cy *= s;
          bw *= s;
          bh *= s;
        }
        cands.add([
          best.toDouble(),
          bestScore,
          cx - bw / 2,
          cy - bh / 2,
          cx + bw / 2,
          cy + bh / 2,
        ]);
      }

      final kept = _nms(cands, iou, 20);

      // Перевод в нормализованные координаты исходного кадра
      final flat = Float64List(2 + kept.length * 6);
      flat[0] = sw.elapsedMicroseconds / 1000.0;
      flat[1] = kept.length.toDouble();
      var k = 2;
      for (final d in kept) {
        double mapX(double x) =>
            ((rx0 + (x - padX) / scale) / w).clamp(0.0, 1.0).toDouble();
        double mapY(double y) =>
            (((y - padY) / scale) / h).clamp(0.0, 1.0).toDouble();
        flat[k++] = d[0];
        flat[k++] = d[1];
        flat[k++] = mapX(d[2]);
        flat[k++] = mapY(d[3]);
        flat[k++] = mapX(d[4]);
        flat[k++] = mapY(d[5]);
      }
      out.send(flat);
    } catch (e) {
      out.send('Ошибка обработки кадра: $e');
    }
  });
}

List<List<double>> _nms(List<List<double>> boxes, double iouThr, int maxDet) {
  boxes.sort((a, b) => b[1].compareTo(a[1]));
  final kept = <List<double>>[];
  for (final b in boxes) {
    var ok = true;
    for (final k in kept) {
      if (k[0] == b[0] && _iou(k, b) > iouThr) {
        ok = false;
        break;
      }
    }
    if (ok) {
      kept.add(b);
      if (kept.length >= maxDet) break;
    }
  }
  return kept;
}

double _iou(List<double> a, List<double> b) {
  final x1 = math.max(a[2], b[2]);
  final y1 = math.max(a[3], b[3]);
  final x2 = math.min(a[4], b[4]);
  final y2 = math.min(a[5], b[5]);
  final inter = math.max(0.0, x2 - x1) * math.max(0.0, y2 - y1);
  final areaA = (a[4] - a[2]) * (a[5] - a[3]);
  final areaB = (b[4] - b[2]) * (b[5] - b[3]);
  final union = areaA + areaB - inter;
  return union <= 0 ? 0 : inter / union;
}
