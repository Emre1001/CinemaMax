// Misst die Wiedergabe unter Linux/Windows: spielt einen Teststream und gibt mpv-Werte aus.
//   flutter build linux -t tool/player_probe.dart && build/linux/x64/release/bundle/cinemamax
import 'dart:async';
import 'dart:io';

import 'package:cinemamax/models.dart';
import 'package:cinemamax/playback.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
import 'package:media_kit/media_kit.dart';

const url = String.fromEnvironment('URL', defaultValue: 'https://tagesschau.akamaized.net/hls/live/2020115/tagesschau/tagesschau_1/master.m3u8');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await store.init();
  final e = Engine.create(url);
  final key = GlobalKey();
  runApp(MaterialApp(home: Scaffold(backgroundColor: Colors.black, body: RepaintBoundary(key: key, child: e.view(BoxFit.contain)))));
  await Future.delayed(const Duration(milliseconds: 500));
  await e.open(url, const {'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20'});
  for (var i = 1; i <= 3; i++) {
    await Future.delayed(const Duration(seconds: 6));
    stdout.writeln('PROBE t=${i * 6}s ${await e.stats()} size=${e.state.value.size}');
    // Bild des Video-Widgets speichern (zeigt, ob wirklich Video ankommt)
    final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: .5);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('${Directory.systemTemp.path}/cinemamax_probe_$i.png').writeAsBytes(png!.buffer.asUint8List());
  }
  stdout.writeln('PROBE kind=${Kind.live} done');
  exit(0);
}
