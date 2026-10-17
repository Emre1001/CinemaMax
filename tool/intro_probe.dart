// Prüft „Intro überspringen“: sichtbar mit Countdown, verschwindet nach 10 s von selbst.
// Braucht eine Folge > 10 min (MP4 mit faststart):
//   flutter build linux -t tool/intro_probe.dart --dart-define=URL=http://… && OUT=/tmp build/linux/x64/release/bundle/cinemamax
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cinemamax/downloads.dart';
import 'package:cinemamax/models.dart';
import 'package:cinemamax/store.dart';
import 'package:cinemamax/ui/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';

const url = String.fromEnvironment('URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await store.init();
  await downloads.init();
  store.set('resume', false);
  final key = GlobalKey();
  final src = Source(id: 'probe', name: 'Probe', type: SourceType.m3u, url: '');
  const show = MediaItem(id: 's', name: 'Testserie', kind: Kind.series, group: 'Test');
  final eps = [Episode(id: '1', season: 1, number: 1, title: 'Folge 1', url: url)];
  runApp(RepaintBoundary(
    key: key,
    child: MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: PlayerScreen(source: src, list: episodeList(show, eps), index: 0)),
  ));
  for (final t in [7, 12, 18]) {
    await Future.delayed(Duration(seconds: t == 7 ? 7 : (t == 12 ? 5 : 6)));
    final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: .5);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('${Platform.environment['OUT']}/intro_$t.png').writeAsBytes(png!.buffer.asUint8List());
  }
  exit(0);
}
