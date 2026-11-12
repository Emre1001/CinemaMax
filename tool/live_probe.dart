// ignore_for_file: deprecated_member_use
// Prüft am Fernseher-Layout: Ordner als M3U-Quelle, Live-Vorschau, Wachsen zum Vollbild, Senderleiste,
// Spulen mit Pfeiltasten. Speichert Bilder nach $OUT.
//   flutter build linux -t tool/live_probe.dart
//   XDG_DATA_HOME=<leer> MEDIA=<ordner mit a.mp4, b.mp4> OUT=<ordner> build/linux/x64/release/bundle/cinemamax
// XDG_DATA_HOME setzen: sonst ändert die Probe die echten Einstellungen.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cinemamax/downloads.dart';
import 'package:cinemamax/models.dart';
import 'package:cinemamax/store.dart';
import 'package:cinemamax/ui/browse.dart';
import 'package:cinemamax/ui/common.dart';
import 'package:cinemamax/ui/fx.dart';
import 'package:cinemamax/ui/player.dart';
import 'package:cinemamax/ui/preview.dart';
import 'package:cinemamax/ui/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await store.init();
  await downloads.init();
  store.set('layout', 'tv');
  store.set('startTab', 'live');
  store.set('hideSec', 3);
  final media = Platform.environment['MEDIA']!, out = Platform.environment['OUT']!;
  // Zwei Listen im Ordner: Dateiname wird Kategorie
  final folder = Directory('$out/listen')..createSync(recursive: true);
  // Jeder Sender braucht eine eigene Adresse: Verknüpfungen auf die zwei Testvideos
  String link(String name, String file) {
    final l = Link('$out/listen/$name.mp4');
    if (!l.existsSync()) l.createSync('$media/$file.mp4');
    return l.path;
  }

  String list(List<String> names) => [
        '#EXTM3U',
        for (final (i, n) in names.indexed) ...['#EXTINF:-1 tvg-type="live",$n', link(n, i.isEven ? 'a' : 'b')],
      ].join('\n');
  File('${folder.path}/Sport.m3u').writeAsStringSync(list(['Eins', 'Zwei', 'Drei', 'Vier', 'Fünf', 'Sechs']));
  File('${folder.path}/News.m3u').writeAsStringSync(list(['Sieben', 'Acht']));
  final src = Source(id: 'probe', name: 'Probe', type: SourceType.m3u, url: folder.path);
  final key = GlobalKey();
  final nav = GlobalKey<NavigatorState>();
  FlutterError.onError = (d) => stdout.writeln('FEHLER ${d.exceptionAsString()}');
  runApp(RepaintBoundary(
    key: key,
    child: MaterialApp(
      navigatorKey: nav,
      // Seitenwechsel wie in der App: Flutters Standard (Zoom mit Momentaufnahme) zeichnet die Videotextur
      // zu spät, mpv findet dann bei lokalen Dateien keine Videoausgabe
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: kBg,
        pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.linux: FxPageTransitions()}),
      ),
      home: BrowseScreen(source: src),
    ),
  ));
  Future<void> wait(int ms) => Future.delayed(Duration(milliseconds: ms));
  Future<void> shot(String name) async {
    final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: .6);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('$out/live_$name.png').writeAsBytes(png!.buffer.asUint8List());
    final f = FocusManager.instance.primaryFocus;
    stdout.writeln('SHOT $name fokus=${f?.debugLabel} ${f?.context?.widget.runtimeType}');
  }

  Future<void> press(LogicalKeyboardKey k, PhysicalKeyboardKey p, {int after = 400}) async {
    final handler = ServicesBinding.instance.keyEventManager.keyMessageHandler!;
    handler(KeyMessage([KeyDownEvent(physicalKey: p, logicalKey: k, timeStamp: Duration.zero)], null));
    await wait(60);
    handler(KeyMessage([KeyUpEvent(physicalKey: p, logicalKey: k, timeStamp: Duration.zero)], null));
    await wait(after);
  }

  Future<void> right() => press(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
  Future<void> down() => press(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown);
  Future<void> ok({int after = 400}) => press(LogicalKeyboardKey.select, PhysicalKeyboardKey.select, after: after);

  final mode = Platform.environment['MODE'] ?? '';
  const film0 = MediaItem(id: 'f', name: 'Film', kind: Kind.movie, group: 'Test');
  Future<void> film() async {
    nav.currentState!.push(MaterialPageRoute(
        builder: (_) => PlayerScreen(source: src, list: [PlayItem('$media/long.mp4', 'Film', film0)], index: 0)));
    await wait(5000);
    await shot('film_$mode');
    exit(0);
  }

  await wait(2500);
  if (mode == 'film') await film(); // ohne Vorschau davor
  if (mode == 'einstellungen') {
    store.set('hideSec', 5); // Standard, sonst gilt „Player“ als geändert
    store.set('bufferMb', 128);
    nav.currentState!.push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
    await wait(1500);
    await down();
    await down();
    await wait(1200);
    await shot('einstellungen');
    exit(0);
  }
  await shot('1_liste');
  // Seitenleiste → Kategorien → Raster
  await right();
  await right();
  await shot('2_fokus');
  await wait(3000);
  if (mode == 'gleichzeitig') await film(); // Vorschau endet im selben Moment
  if (mode == 'nacheinander') {
    await LivePreview.take(film0); // Vorschau erst beenden
    await film();
  }
  await shot('3_vorschau');
  await right(); // nächster Sender: Vorschau wechselt
  await wait(3000);
  await shot('4_vorschau2');
  // Echtes Fensterbild (xwd): toImage erwischt die Videotextur mitten im Größenwechsel nicht zuverlässig
  for (final ms in [60, 130, 200, 270, 400]) {
    Future.delayed(Duration(milliseconds: 60 + ms), () => Process.run('xwd', ['-name', 'CinemaMax', '-out', '$out/grow_$ms.xwd']));
  }
  await ok(after: 2000);
  await shot('6_vollbild');
  await wait(3500); // Bedienleiste blendet aus
  await down();
  await wait(600);
  await shot('7_leiste');
  await right();
  await ok(after: 2500);
  await shot('8_gewechselt');
  nav.currentState!.pop();
  await wait(2500);
  await shot('9_zurueck');

  // Film: Pfeil rechts spult beliebig oft, die Bedienleiste bleibt zu
  nav.currentState!.push(MaterialPageRoute(
      builder: (_) => PlayerScreen(source: src, list: [PlayItem('$media/long.mp4', 'Film', film0)], index: 0)));
  await wait(5500);
  await shot('10a_film');
  for (var i = 0; i < 4; i++) {
    await right();
  }
  await shot('10b_spulen');
  await wait(2500);
  await shot('10c_danach');
  exit(0);
}
