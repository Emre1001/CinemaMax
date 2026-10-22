import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'store.dart';

/// Leistungsmodus. „full“: alle Effekte. „lite“ (schwaches Gerät): ruhiger Hintergrund, keine Glanz-/Lichteffekte,
/// kürzere Übergänge. „speed“: keine Animationen, kein Hintergrund, keine Effekte.
/// „auto“ entscheidet nach Gerät (Android: wenig RAM oder Kerne) und gemessenen Bildzeiten.
class Perf {
  static bool _weakDevice = false, _veryWeakDevice = false;

  /// Bilder pro Sekunde zuletzt (nur wenn gezeichnet wird), für die Anzeige in der Einrichtung.
  static final fps = ValueNotifier<double>(0);

  /// Letzte Bildzeiten in ms (Build oder Raster, der größere Wert), für die Anzeige.
  static final frameMs = <double>[];

  /// Player läuft: nicht messen (Videobilder zählen sonst mit).
  static int paused = 0;

  static String get mode => store.get('perf', 'auto');

  /// Schwaches Gerät erkannt (RAM/Kerne oder zu langsame Bilder).
  static bool get detectedWeak => _weakDevice || store.get('perfSlow', false);

  /// Sehr schwach: selbst „Flüssig“ schafft keine 30 fps, oder unter 1,5 GB RAM / höchstens 2 Kerne.
  static bool get detectedVeryWeak => _veryWeakDevice || store.get('perfVerySlow', false);

  /// Wirksamer Modus: „full“, „lite“ oder „speed“.
  static String get effective => mode != 'auto'
      ? mode
      : detectedVeryWeak
          ? 'speed'
          : (detectedWeak ? 'lite' : 'full');

  /// Weniger Effekte (auch im Speed-Modus).
  static bool get lite => effective != 'full';

  /// Ohne Animationen und Schnickschnack.
  static bool get speed => effective == 'speed';

  /// Beim Start: Gerätedaten holen und Bildzeiten beobachten.
  static Future<void> init() async {
    if (Platform.isAndroid) {
      try {
        final r = await const MethodChannel('cinemamax/device').invokeMapMethod<String, Object?>('perfInfo') ?? {};
        final lowRam = r['lowRam'] == true, ramMb = (r['ramMb'] as num?)?.toInt() ?? 0;
        final cores = (r['cores'] as num?)?.toInt() ?? 0;
        _weakDevice = weak(lowRam: lowRam, ramMb: ramMb, cores: cores);
        _veryWeakDevice = (ramMb > 0 && ramMb < 1500) || (cores > 0 && cores <= 2);
      } catch (_) {/* unbekannt: nach Bildzeiten */}
    }
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  /// TV-Boxen und alte Handys: unter 3 GB RAM, Android-„Low RAM“ oder weniger als 4 Kerne.
  static bool weak({required bool lowRam, required int ramMb, required int cores}) =>
      lowRam || (ramMb > 0 && ramMb < 3000) || (cores > 0 && cores < 4);

  static final _stamps = <int>[];

  static void _onTimings(List<FrameTiming> list) {
    if (paused > 0) return;
    for (final t in list) {
      final ms = (t.buildDuration > t.rasterDuration ? t.buildDuration : t.rasterDuration).inMicroseconds / 1000;
      frameMs.add(ms);
      _stamps.add(t.timestampInMicroseconds(FramePhase.vsyncStart));
    }
    if (frameMs.length > 120) frameMs.removeRange(0, frameMs.length - 120);
    final now = _stamps.isEmpty ? 0 : _stamps.last;
    _stamps.removeWhere((s) => now - s > 1000000);
    fps.value = _stamps.length.toDouble();
    if (mode != 'auto' || frameMs.length < 120 || detectedVeryWeak) return;
    // Stufe für Stufe herunter, danach neu messen
    if (!detectedWeak && slow(frameMs)) {
      store.set('perfSlow', true);
      frameMs.clear();
    } else if (detectedWeak && slow(frameMs, 33.4)) {
      store.set('perfVerySlow', true);
      frameMs.clear();
    }
  }

  /// Mehr als ein Drittel der Bilder braucht länger als [limit] ms (16,7 = 60 fps, 33,4 = 30 fps).
  static bool slow(List<double> ms, [double limit = 16.7]) => ms.where((m) => m > limit).length > ms.length / 3;
}
