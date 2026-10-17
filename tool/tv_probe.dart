// ignore_for_file: deprecated_member_use
// Prüft die Player-Bedienung mit Fernbedienung (Layout „Fernseher“): Tasten in den Fokusbaum, Bilder speichern.
//   flutter build linux -t tool/tv_probe.dart && OUT=/tmp build/linux/x64/release/bundle/cinemamax
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cinemamax/downloads.dart';
import 'package:cinemamax/models.dart';
import 'package:cinemamax/store.dart';
import 'package:cinemamax/ui/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

const url = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await store.init();
  await downloads.init();
  store.set('layout', 'tv');
  final key = GlobalKey();
  final src = Source(id: 'probe', name: 'Probe', type: SourceType.m3u, url: '');
  const show = MediaItem(id: 's', name: 'Big Buck Bunny', kind: Kind.series, group: 'Test');
  final eps = [
    for (var n = 1; n <= 3; n++) Episode(id: '$n', season: 1, number: n, title: 'Folge $n', url: '$url?ep=$n'),
  ];
  runApp(RepaintBoundary(
    key: key,
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: PlayerScreen(source: src, list: episodeList(show, eps), index: 0),
    ),
  ));
  final out = Platform.environment['OUT'] ?? Directory.systemTemp.path;
  Future<void> shot(String name) async {
    final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: .5);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('$out/tv_$name.png').writeAsBytes(png!.buffer.asUint8List());
    final f = FocusManager.instance.primaryFocus;
    stdout.writeln('SHOT $name ${f.runtimeType} ${f?.context?.findAncestorWidgetOfExactType<Tooltip>()?.message}');
  }

  Future<void> press(LogicalKeyboardKey k, PhysicalKeyboardKey p) async {
    final handler = ServicesBinding.instance.keyEventManager.keyMessageHandler!;
    handler(KeyMessage([KeyDownEvent(physicalKey: p, logicalKey: k, timeStamp: Duration.zero)], null));
    await Future.delayed(const Duration(milliseconds: 120));
    handler(KeyMessage([KeyUpEvent(physicalKey: p, logicalKey: k, timeStamp: Duration.zero)], null));
    await Future.delayed(const Duration(milliseconds: 500));
  }

  for (var i = 0; i < 6; i++) {
    await Future.delayed(const Duration(milliseconds: 500));
    final f = FocusManager.instance.primaryFocus;
    stdout.writeln('T$i ${f.runtimeType} ${f?.context?.widget.runtimeType} ${f?.context?.findAncestorWidgetOfExactType<Tooltip>()?.message}');
  }
  await shot('1_start');
  await press(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown);
  await press(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown);
  await shot('2_down');
  await press(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
  await press(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
  await press(LogicalKeyboardKey.select, PhysicalKeyboardKey.select);
  await Future.delayed(const Duration(seconds: 1));
  await shot('3_panel');
  await press(LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape);
  // Leiste ausblenden lassen, dann OK: muss Leiste mit Fokus zeigen
  await Future.delayed(const Duration(seconds: 7));
  await press(LogicalKeyboardKey.select, PhysicalKeyboardKey.select);
  await shot('4_ok');
  await press(LogicalKeyboardKey.colorF2Yellow, PhysicalKeyboardKey.select);
  await Future.delayed(const Duration(seconds: 1));
  await shot('5_yellow');
  exit(0);
}
