import 'dart:io';

import 'package:flutter/services.dart';

/// Externe Player für Streams, die der eingebaute nicht schafft: VLC und mpv (Android, Linux, Windows),
/// MX Player, Just Player und Kodi (Android). Android meldet beim Zurückkehren die Position fürs Weiterschauen.
class ExternalPlayer {
  static const _device = MethodChannel('cinemamax/device');
  static const names = {'vlc': 'VLC', 'mx': 'MX Player', 'mpv': 'mpv', 'just': 'Just Player', 'kodi': 'Kodi'};

  /// Am PC verfügbar (Rest nur Android).
  static const desktop = {'vlc', 'mpv'};

  /// Installierte externe Player (IDs aus [names]).
  static Future<List<String>> available() async {
    if (Platform.isAndroid) {
      try {
        return [...?await _device.invokeListMethod<String>('externalPlayers')];
      } catch (_) {
        return [];
      }
    }
    return [
      for (final id in desktop)
        if (await _command(id) != null) id,
    ];
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
    final cmd = await _command(id);
    if (cmd == null) throw StateError(names[id] ?? id);
    final ua = headers['User-Agent'], ref = headers['Referer'];
    final from = start != null && start > Duration.zero ? start.inSeconds : null;
    await Process.start(cmd.first, [
      ...cmd.skip(1),
      if (id == 'mpv') ...[
        '--force-media-title=$title',
        if (ua != null) '--user-agent=$ua',
        if (ref != null) '--referrer=$ref',
        if (from != null) '--start=$from',
      ] else ...[
        '--meta-title=$title',
        if (ua != null) '--http-user-agent=$ua',
        if (ref != null) '--http-referrer=$ref',
        if (from != null) '--start-time=$from',
      ],
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

  /// VLC/mpv am PC: Programm im Pfad, Flatpak (Linux) oder Standard-Installationsordner (Windows).
  static Future<List<String>?> _command(String id) async {
    if (Platform.isWindows) {
      final env = Platform.environment;
      for (final dir in [env['ProgramFiles'], env['ProgramFiles(x86)'], env['ProgramW6432'], env['LOCALAPPDATA']]) {
        final exe = id == 'vlc' ? '$dir\\VideoLAN\\VLC\\vlc.exe' : '$dir\\mpv\\mpv.exe';
        if (dir != null && File(exe).existsSync()) return [exe];
      }
      // Portable oder anders installiert (mpv meist per scoop/winget), aber im PATH
      try {
        final r = await Process.run('where', ['$id.exe']);
        final exe = '${r.stdout}'.split(RegExp(r'[\r\n]+')).first.trim();
        if (r.exitCode == 0 && exe.isNotEmpty) return [exe];
      } catch (_) {/* where fehlt */}
      return null;
    }
    if (!Platform.isLinux) return null;
    try {
      // „which“ fehlt auf manchen Distributionen; „command -v“ kennt jede Shell (auch Snap: /snap/bin)
      if ((await Process.run('sh', ['-c', 'command -v $id'])).exitCode == 0) return [id];
      final flatpak = id == 'vlc' ? 'org.videolan.VLC' : 'io.mpv.Mpv';
      if ((await Process.run('flatpak', ['info', flatpak])).exitCode == 0) {
        return ['flatpak', 'run', flatpak];
      }
    } catch (_) {/* which/flatpak fehlen */}
    return null;
  }
}
