// Видео с видеорегистратора 70mai по Wi-Fi (RTSP) + захват кадров для детектора.
//
// Регистратор раздаёт свою Wi-Fi сеть; телефон подключается к ней, и живое видео
// доступно по RTSP без пароля:
//   70mai Pro / A500S / M300 / A800 …  rtsp://192.168.0.1:554/livestream/12
//   70mai 1S                           rtsp://192.72.1.1/liveRTSP/av4

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class DashcamPreset {
  final String name;
  final String url;
  const DashcamPreset(this.name, this.url);
}

const List<DashcamPreset> kDashcamPresets = [
  DashcamPreset('70mai Pro / A500S / M300 / A800', 'rtsp://192.168.0.1:554/livestream/12'),
  DashcamPreset('70mai 1S', 'rtsp://192.72.1.1/liveRTSP/av4'),
];

/// Кадр в формате BGR0 (как BGRA): 4 байта на пиксель, построчно со stride.
class RawFrame {
  final Uint8List bytes;
  final int width;
  final int height;
  final int stride;
  const RawFrame(this.bytes, this.width, this.height, this.stride);
}

class DashcamSource {
  DashcamSource()
      : player = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 2 * 1024 * 1024,
            logLevel: MPVLogLevel.warn,
          ),
        ) {
    controller = VideoController(player);
  }

  final Player player;
  late final VideoController controller;

  static const _net = MethodChannel('signreader/net');

  /// Android: если у Wi-Fi регистратора нет интернета, система шлёт трафик
  /// через мобильные данные и регистратор недоступен. Привязываем приложение к Wi-Fi.
  static Future<bool> bindToWifi() async {
    try {
      return await _net.invokeMethod<bool>('bindWifi') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> unbindNetwork() async {
    try {
      await _net.invokeMethod('unbind');
    } catch (_) {}
  }

  Future<void> open(String url, {bool tcp = true}) async {
    final p = player.platform;
    if (p is NativePlayer) {
      // Минимальная задержка: без кэша, кадры показываются сразу.
      await p.setProperty('cache', 'no');
      await p.setProperty('untimed', 'yes');
      await p.setProperty('aid', 'no');
      await p.setProperty('network-timeout', '10');
      await p.setProperty(
        'demuxer-lavf-o',
        'rtsp_transport=${tcp ? 'tcp' : 'udp'},fflags=nobuffer',
      );
    }
    await player.open(Media(url), play: true);
  }

  int? get width => player.state.width;
  int? get height => player.state.height;
  bool get hasVideo => (width ?? 0) > 0 && (height ?? 0) > 0;

  /// Текущий кадр без сжатия (mpv screenshot-raw, формат bgr0).
  Future<RawFrame?> grab() async {
    final w = width, h = height;
    if (w == null || h == null || w == 0 || h == 0) return null;
    final bytes = await player.screenshot(format: null);
    if (bytes == null || bytes.isEmpty) return null;
    final stride = bytes.length ~/ h;
    if (stride < w * 4) return null;
    return RawFrame(bytes, w, h, stride);
  }

  Future<void> stop() async {
    try {
      await player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await player.dispose();
    } catch (_) {}
  }
}
