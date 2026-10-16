// Öffnet den echten Player mit einem Teststream und speichert ein Bild der Oberfläche.
//   flutter build linux -t tool/player_ui_probe.dart && build/linux/x64/release/bundle/cinemamax
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cinemamax/downloads.dart';
import 'package:cinemamax/models.dart';
import 'package:cinemamax/store.dart';
import 'package:cinemamax/ui/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';

const url = 'https://tagesschau.akamaized.net/hls/live/2020115/tagesschau/tagesschau_1/master.m3u8';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await store.init();
  await downloads.init();
  final key = GlobalKey();
  final src = Source(id: 'probe', name: 'Probe', type: SourceType.m3u, url: '');
  final ch = [
    const MediaItem(id: '1', name: 'tagesschau24', kind: Kind.live, group: 'Nachrichten', url: url),
    const MediaItem(id: '2', name: 'Zweiter Sender', kind: Kind.live, group: 'Nachrichten', url: url),
  ];
  runApp(RepaintBoundary(
    key: key,
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: PlayerScreen(source: src, list: [for (final m in ch) PlayItem(m.url!, m.name, m)], index: 0),
    ),
  ));
  for (final t in [3, 10]) {
    await Future.delayed(Duration(seconds: t == 3 ? 3 : 7));
    final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: .6);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('${Platform.environment['OUT'] ?? Directory.systemTemp.path}/player_$t.png').writeAsBytes(png!.buffer.asUint8List());
  }
  exit(0);
}
