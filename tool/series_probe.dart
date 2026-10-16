// Spielt eine Testserie kurz vor Folgenende ab und speichert Bilder: Bedienleiste, Abspann-Karte, Qualität.
//   flutter build linux -t tool/series_probe.dart && OUT=/tmp build/linux/x64/release/bundle/cinemamax
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cinemamax/downloads.dart';
import 'package:cinemamax/models.dart';
import 'package:cinemamax/store.dart';
import 'package:cinemamax/ui/player.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';

const url = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'; // ~10 min, mehrere Qualitäten

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await store.init();
  await downloads.init();
  final key = GlobalKey();
  final src = Source(id: 'probe', name: 'Probe', type: SourceType.m3u, url: '');
  const show = MediaItem(id: 's', name: 'Big Buck Bunny', kind: Kind.series, group: 'Test');
  final eps = [
    for (var n = 1; n <= 3; n++)
      Episode(id: '$n', season: 1, number: n, title: 'Folge $n', url: '$url?ep=$n', plot: 'Ein Hase sucht Rache.'),
  ];
  // Fortsetzen 40 s vor dem Ende, damit die Abspann-Karte erscheint
  store.saveProgress(src, show, eps[0].url, 'S1 E1', const Duration(seconds: 600), const Duration(seconds: 634));
  runApp(RepaintBoundary(
    key: key,
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: PlayerScreen(
        source: src,
        list: [for (final e in eps) PlayItem(e.url, 'S1 E${e.number} · ${e.title}', show, episode: e)],
        index: 0,
      ),
    ),
  ));
  Future<void> shot(String name) async {
    final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: .6);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('${Platform.environment['OUT'] ?? Directory.systemTemp.path}/series_$name.png')
        .writeAsBytes(png!.buffer.asUint8List());
  }

  await Future.delayed(const Duration(seconds: 3));
  await shot('controls');
  await Future.delayed(const Duration(seconds: 8));
  await shot('next');
  await Future.delayed(const Duration(seconds: 12));
  // Maus bewegen: Bedienleiste zeigt Titel der laufenden Folge
  for (final x in [100.0, 140.0]) {
    WidgetsBinding.instance.handlePointerEvent(PointerHoverEvent(position: Offset(x, 200)));
  }
  await Future.delayed(const Duration(milliseconds: 600));
  await shot('after');
  exit(0);
}
