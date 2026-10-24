// Видео с видеорегистратора 70mai по Wi-Fi (RTSP) + захват кадров для детектора.
//
// Регистратор раздаёт свою Wi-Fi сеть; телефон подключается к ней, и живое видео
// доступно по RTSP без пароля:
//   70mai Pro / A500S / M300 / A800 …  rtsp://192.168.0.1:554/livestream/12
//   70mai 1S                           rtsp://192.72.1.1/liveRTSP/av4

import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

/// Result of the automatic stream search.
class ProbeResult {
  final String? url; // working RTSP URL, if found
  final String report; // human-readable log of what was tried
  const ProbeResult(this.url, this.report);
}

// Hosts and paths used by 70mai and the chipsets inside dashcams
// (HiSilicon, SigmaStar, Novatek, Ambarella, Allwinner).
const _probeHosts = ['192.168.0.1', '192.72.1.1', '192.168.1.254', '192.168.169.1', '192.168.42.1', '192.168.1.1'];
const _probePorts = [554, 8554];
const _probePaths = [
  '/livestream/12', '/livestream/11', '/liveRTSP/av4', '/liveRTSP/av0',
  '/live', '/live/ch0', '/live/ch00_0', '/stream1', '/stream0', '/h264',
  '/av0_0', '/0', '/11', '/12', '/xxx.mov', '/',
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

  static Future<String?> gatewayIp() async {
    try {
      return await _net.invokeMethod<String>('gateway');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _portOpen(String host, int port) async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(milliseconds: 1500));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sends RTSP DESCRIBE and returns the status line (e.g. "RTSP/1.0 200 OK").
  static Future<String?> _describe(String host, int port, String url) async {
    Socket? s;
    try {
      s = await Socket.connect(host, port, timeout: const Duration(milliseconds: 1500));
      s.write('DESCRIBE $url RTSP/1.0\r\nCSeq: 2\r\nAccept: application/sdp\r\n'
          'User-Agent: signreader\r\n\r\n');
      await s.flush();
      final first = await s
          .cast<List<int>>()
          .transform(latin1.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 2));
      return first.trim();
    } catch (_) {
      return null;
    } finally {
      s?.destroy();
    }
  }

  /// Finds the dashcam's RTSP stream: gateway IP + known hosts, ports and paths.
  static Future<ProbeResult> autodetect({void Function(String)? progress}) async {
    await bindToWifi();
    final log = StringBuffer();
    final gw = await gatewayIp();
    log.writeln('Wi-Fi gateway: ${gw ?? 'unknown'}');
    final hosts = <String>{if (gw != null && gw.isNotEmpty) gw, ..._probeHosts}.toList();

    for (final host in hosts) {
      progress?.call('Проверка $host…');
      final open = <int>[];
      for (final port in [..._probePorts, 80, 21, 23, 8080]) {
        if (await _portOpen(host, port)) open.add(port);
      }
      if (open.isEmpty) continue;
      log.writeln('$host open ports: ${open.join(', ')}');
      for (final port in _probePorts.where(open.contains)) {
        for (final path in _probePaths) {
          final url = port == 554 ? 'rtsp://$host:554$path' : 'rtsp://$host:$port$path';
          progress?.call('Пробую $url');
          final st = await _describe(host, port, url);
          log.writeln('  $path -> ${st ?? 'no answer'}');
          if (st != null && st.contains(' 200')) {
            log.writeln('FOUND: $url');
            return ProbeResult(url, log.toString());
          }
        }
      }
    }
    if (log.toString().split('\n').where((l) => l.contains('open ports')).isEmpty) {
      log.writeln('No dashcam found. Is the phone connected to the dashcam Wi-Fi?');
    } else {
      log.writeln('No RTSP stream found on the open ports.');
    }
    return ProbeResult(null, log.toString());
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
