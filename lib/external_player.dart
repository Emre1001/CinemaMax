import 'dart:io';

import 'package:flutter/services.dart';

/// Externe Player für Streams, die der eingebaute nicht schafft: VLC (Android, Linux, Windows)
/// und MX Player (Android). Android meldet beim Zurückkehren die Position fürs Weiterschauen.
class ExternalPlayer {
  static const _device = MethodChannel('cinemamax/device');
  static const names = {'vlc': 'VLC', 'mx': 'MX Player'};

  /// Installierte externe Player (IDs aus [names]).
  static Future<List<String>> available() async {
    if (Platform.isAndroid) {
      try {
        return [...?await _device.invokeListMethod<String>('externalPlayers')];
      } catch (_) {
        return [];
      }
    }
    return await _vlcCommand() == null ? [] : ['vlc'];
  }

  /// Startet [url] im Player [id]. Android: wartet, bis er zurückkehrt, und liefert Position/Dauer
  /// (null = unbekannt). Wirft, wenn der Player fehlt.
  static Future<({Duration position, Duration duration})?> play(
    String id,
    String url,
    Map<String, String> headers,
    String title, {
    Duration? start,
  }) async {
    if (Platform.isAndroid) {
      final r = await _device.invokeMapMethod<String, Object?>('playExternal', {
        'player': id,
        'url': url,
        'title': title,
        'headers': headers,
        'position': start?.inMilliseconds ?? 0,
      });
      if (r == null) return null;
      Duration ms(Object? v) => Duration(milliseconds: (v as num?)?.toInt() ?? 0);
      return (position: ms(r['position']), duration: ms(r['duration']));
    }
    final cmd = await _vlcCommand();
    if (cmd == null) throw StateError('VLC');
    await Process.start(cmd.first, [
      ...cmd.skip(1),
      '--meta-title=$title',
      if (headers['User-Agent'] != null) '--http-user-agent=${headers['User-Agent']}',
      if (headers['Referer'] != null) '--http-referrer=${headers['Referer']}',
      if (start != null && start > Duration.zero) '--start-time=${start.inSeconds}',
      url,
    ], mode: ProcessStartMode.detached, environment: hostEnvironment());
    return null;
  }

  /// AppImage: eigene Bibliotheken nicht an fremde Programme vererben (VLC, Browser stürzen sonst ab).
  static Map<String, String>? hostEnvironment() {
    final dir = Platform.environment['APPDIR'];
    if (!Platform.isLinux || dir == null) return null;
    final paths = (Platform.environment['LD_LIBRARY_PATH'] ?? '').split(':');
    return {'LD_LIBRARY_PATH': paths.where((p) => p.isNotEmpty && !p.startsWith(dir)).join(':')};
  }

  /// VLC am PC: Programm im Pfad, Flatpak (Linux) oder Standard-Installationsordner (Windows).
  static Future<List<String>?> _vlcCommand() async {
    if (Platform.isWindows) {
      final env = Platform.environment;
      for (final dir in [env['ProgramFiles'], env['ProgramFiles(x86)'], env['ProgramW6432'], env['LOCALAPPDATA']]) {
        final exe = '$dir\\VideoLAN\\VLC\\vlc.exe';
        if (dir != null && File(exe).existsSync()) return [exe];
      }
      // Portable oder anders installiert, aber im PATH
      try {
        final r = await Process.run('where', ['vlc.exe']);
        final exe = '${r.stdout}'.split(RegExp(r'[\r\n]+')).first.trim();
        if (r.exitCode == 0 && exe.isNotEmpty) return [exe];
      } catch (_) {/* where fehlt */}
      return null;
    }
    if (!Platform.isLinux) return null;
    try {
      // „which“ fehlt auf manchen Distributionen; „command -v“ kennt jede Shell (auch Snap: /snap/bin)
      if ((await Process.run('sh', ['-c', 'command -v vlc'])).exitCode == 0) return ['vlc'];
      if ((await Process.run('flatpak', ['info', 'org.videolan.VLC'])).exitCode == 0) {
        return ['flatpak', 'run', 'org.videolan.VLC'];
      }
    } catch (_) {/* which/flatpak fehlen */}
    return null;
  }
}
