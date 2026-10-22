import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'i18n.dart';
import 'playback.dart';
import 'store.dart';

/// Ergebnis einer Prüfung: läuft direkt, über eine Ausweichlösung (anderer Player), nur Hinweis, geht nicht.
enum Level { ok, alt, info, fail }

typedef CheckItem = ({String group, String label, Level level, String detail});

/// Bildschirm und Prüfergebnisse für den Geräte-Check der Einrichtung.
typedef DeviceInfo = ({int width, int height, double refresh, List<CheckItem> items});

/// Formate des Geräte-Checks: (Gruppe, Name, Android-MIME, mpv-Decoder, FFmpeg-Tondecoder kann es).
const _formats = [
  ('Bild', 'H.264 (AVC)', 'video/avc', 'h264', false),
  ('Bild', 'H.265 (HEVC)', 'video/hevc', 'hevc', false),
  ('Bild', 'AV1', 'video/av01', 'av1', false),
  ('Bild', 'VP9', 'video/x-vnd.on2.vp9', 'vp9', false),
  ('Bild', 'MPEG-2 (alte SD-Sender)', 'video/mpeg2', 'mpeg2video', false),
  ('Ton', 'AAC', 'audio/mp4a-latm', 'aac', false),
  ('Ton', 'Dolby Digital (AC3)', 'audio/ac3', 'ac3', true),
  ('Ton', 'Dolby Digital Plus (E-AC3)', 'audio/eac3', 'eac3', true),
  ('Ton', 'DTS', 'audio/vnd.dts', 'dts', true),
  ('Ton', 'Dolby TrueHD', 'audio/true-hd', 'truehd', true),
  ('Ton', 'Opus', 'audio/opus', 'opus', false),
];

/// Display.HdrCapabilities-Arten.
const _hdrNames = {1: 'Dolby Vision', 2: 'HDR10', 3: 'HLG', 4: 'HDR10+'};

class DeviceCheck {
  /// Prüft Decoder (Android: MediaCodec, PC: libmpv) und Bildschirm.
  static Future<DeviceInfo> run() async {
    if (Platform.isAndroid) {
      final r = await const MethodChannel('cinemamax/device').invokeMapMethod<String, Object?>('deviceCheck') ?? {};
      return android(r,
          exo: store.get('engine', 'exo') == 'exo',
          ffmpeg: store.get('ffmpegAudio', 'on') != 'off',
          autoMpv: store.get('autoMpv', true));
    }
    final d = WidgetsBinding.instance.platformDispatcher;
    Size size = Size.zero;
    double refresh = 0;
    try {
      final disp = d.implicitView?.display ?? d.displays.first;
      size = disp.size;
      refresh = disp.refreshRate;
    } catch (_) {/* Bildschirm nicht gemeldet */}
    Set<String>? decoders;
    try {
      decoders = await _mpvDecoders();
    } catch (_) {/* libmpv fehlt */}
    final w = size.width.round(), h = size.height.round();
    return (width: w, height: h, refresh: refresh, items: _system(desktop(decoders, hwdec: store.get('hwdec', true)), w, h, refresh));
  }

  /// Decoder aus libmpv („decoder-list“ als JSON).
  static Future<Set<String>> _mpvDecoders() async {
    final p = mk.Player();
    try {
      final np = p.platform as mk.NativePlayer;
      final list = jsonDecode(await np.getProperty('decoder-list')) as List;
      return {for (final x in list) '${(x as Map)['codec']}'};
    } finally {
      await p.dispose();
    }
  }

  /// Android: [r] vom Gerät (MainActivity.deviceCheck), bewertet für den eingestellten Player.
  static DeviceInfo android(Map<String, Object?> r, {required bool exo, required bool ffmpeg, required bool autoMpv}) {
    final codecs = Map<String, Object?>.from(r['codecs'] as Map? ?? {});
    final pass = List<Object?>.from(r['passthrough'] as List? ?? []);
    final hdr = [for (final t in List<Object?>.from(r['hdr'] as List? ?? [])) ?_hdrNames[t]];
    final items = <CheckItem>[];
    for (final (group, label, mime, _, ffmpegCan) in _formats) {
      final found = codecs[mime];
      final (Level, String) res;
      if (found == 'hw') {
        res = (Level.ok, tr('Hardware'));
      } else if (found == 'sw') {
        res = (Level.ok, tr('Software'));
      } else if (pass.contains(mime)) {
        res = (Level.ok, tr('An Fernseher/Anlage durchgereicht'));
      } else if (!exo) {
        res = (Level.ok, tr('mpv (Software)'));
      } else if (ffmpeg && ffmpegCan) {
        res = (Level.ok, tr('FFmpeg (Software)'));
      } else if (autoMpv) {
        res = (Level.alt, tr('Wechselt automatisch zu mpv'));
      } else {
        res = (Level.fail, tr('Nicht abspielbar'));
      }
      items.add((group: group, label: label, level: res.$1, detail: res.$2));
    }
    items.add(r['uhd'] == true
        ? (group: 'Bild', label: '4K', level: Level.ok, detail: tr('4K-Decoder vorhanden'))
        : (group: 'Bild', label: '4K', level: Level.alt, detail: tr('Kein 4K-Decoder: Streams werden begrenzt')));
    items.add(hdr.isNotEmpty
        ? (group: 'Bild', label: 'HDR', level: Level.ok, detail: hdr.join(', '))
        : (group: 'Bild', label: 'HDR', level: Level.info, detail: tr('Kein HDR-Bildschirm: Bild wird normal gezeigt')));
    final w = (r['width'] as num?)?.toInt() ?? 0, h = (r['height'] as num?)?.toInt() ?? 0;
    final refresh = (r['refresh'] as num?)?.toDouble() ?? 0;
    return (width: w, height: h, refresh: refresh, items: _system(items, w, h, refresh));
  }

  /// PC: [decoders] aus libmpv, null = libmpv fehlt.
  static List<CheckItem> desktop(Set<String>? decoders, {required bool hwdec}) {
    return [
      for (final (group, label, _, name, _) in _formats)
        decoders == null
            ? (group: group, label: label, level: Level.fail, detail: tr('libmpv fehlt'))
            : decoders.contains(name)
                ? (
                    group: group,
                    label: label,
                    level: Level.ok,
                    detail: group == 'Bild' && hwdec ? tr('Grafikkarte, sonst Software') : tr('Software'),
                  )
                : (group: group, label: label, level: Level.fail, detail: tr('Nicht abspielbar')),
    ];
  }

  /// Gemeinsame Zeilen: Bildschirm und Auflösungsgrenze.
  static List<CheckItem> _system(List<CheckItem> items, int w, int h, double refresh) => [
        ...items,
        if (w > 0 && h > 0)
          (
            group: 'Gerät',
            label: tr('Bildschirm'),
            level: Level.info,
            detail: '${max(w, h)} × ${min(w, h)}${refresh > 0 ? ' · ${refresh.round()} Hz' : ''}',
          ),
        (
          group: 'Gerät',
          label: tr('Streams höchstens'),
          level: Level.info,
          detail: Engine.maxHeight > 0 ? Engine.resolution(0, Engine.maxHeight)! : tr('Keine Grenze'),
        ),
      ];

  /// Lauffähig (direkt oder über Ausweichlösung) von allen Formaten.
  static (int, int) score(List<CheckItem> items) {
    final f = items.where((i) => i.level != Level.info);
    return (f.where((i) => i.level != Level.fail).length, f.length);
  }
}
