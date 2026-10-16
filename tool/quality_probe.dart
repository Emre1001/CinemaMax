// Prüft die Auflösungswahl mit mpv an einem HLS-Teststream.
//   flutter build linux -t tool/quality_probe.dart && build/linux/x64/release/bundle/cinemamax
import 'dart:io';

import 'package:cinemamax/playback.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await store.init();
  final e = MpvEngine();
  runApp(MaterialApp(home: e.view(BoxFit.contain)));
  await e.open('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8', const {});
  await Future.delayed(const Duration(seconds: 10));
  stdout.writeln('TRACKS ${await e.property('track-list/count')}');
  final q = await e.qualities();
  stdout.writeln('QUALITIES $q size=${e.state.value.size.height}');
  if (q.isNotEmpty) {
    await e.selectQuality(q.last.id);
    await Future.delayed(const Duration(seconds: 6));
    stdout.writeln('AFTER ${q.last.label} size=${e.state.value.size.height}');
  }
  exit(0);
}
