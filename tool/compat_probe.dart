// Kompatibilitätstest mit echtem Player: Links erkennen, abspielen, spulen; Xtream/M3U/Stalker laden; Downloads.
// Braucht den Testserver (Mock-IPTV mit HTTP, HLS, DASH, RTMP, RTSP, UDP, SRT).
//   Linux:   flutter build linux -t tool/compat_probe.dart --dart-define=HOST=127.0.0.1 && build/linux/x64/release/bundle/cinemamax
//   Android: flutter build apk --debug -t tool/compat_probe.dart --dart-define=HOST=10.0.2.2 --dart-define=ENGINE=exo
// Ausgabe: Zeilen „COMPAT PASS|FAIL …“, am Ende „COMPAT DONE x/y“.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cinemamax/downloads.dart';
import 'package:cinemamax/epg.dart';
import 'package:cinemamax/links.dart';
import 'package:cinemamax/models.dart';
import 'package:cinemamax/playback.dart';
import 'package:cinemamax/repo.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';

const host = String.fromEnvironment('HOST', defaultValue: '127.0.0.1');
const engineName = String.fromEnvironment('ENGINE', defaultValue: 'mpv');
const only = String.fromEnvironment('ONLY'); // Teil des Namens: nur diese Fälle
const extra = String.fromEnvironment('EXTRA'); // zusätzliche Links (Leerzeichen), als Fälle „extra-N“

const h = 'http://$host:8765';
final view = ValueNotifier<Engine?>(null);
final boundary = GlobalKey();

/// Prüfsumme des oberen linken Bildbereichs (eingebrannte Zeit der Testvideos).
Future<int> frame() async {
  final img = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: .5);
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = data!.buffer.asUint8List();
  var h = 0;
  for (var y = 0; y < img.height ~/ 8; y++) {
    for (var x = 0; x < img.width ~/ 6 * 4; x++) {
      h = (h * 31 + bytes[y * img.width * 4 + x]) & 0x3fffffff;
    }
  }
  return h;
}
var passed = 0, total = 0;

void log(bool ok, String name, String detail) {
  total++;
  if (ok) passed++;
  // print statt stdout: landet auf Android im Logcat
  // ignore: avoid_print
  print('COMPAT ${ok ? 'PASS' : 'FAIL'} [$engineName] $name :: $detail');
}

/// (Name, Link, erwarteter Typ, spulbar)
final cases = <(String, String, LinkKind, bool)>[
  ('mp4', '$h/media/film.mp4', LinkKind.vod, true),
  ('mkv-hevc-ac3', '$h/media/film_hevc_ac3.mkv', LinkKind.vod, true),
  ('mkv-2audio-subs', '$h/media/film_multi.mkv', LinkKind.vod, true),
  ('webm-vp9-opus', '$h/media/film.webm', LinkKind.vod, true),
  ('avi-mpeg4-mp3', '$h/media/film.avi', LinkKind.vod, true),
  ('mov', '$h/media/film.mov', LinkKind.vod, true),
  ('flv', '$h/media/film.flv', LinkKind.vod, true),
  ('ts-file', '$h/media/film.ts', LinkKind.vod, true),
  ('ts-mpeg2-sd', '$h/media/sd_mpeg2.ts', LinkKind.vod, false),
  ('mp3-radio', '$h/media/radio.mp3', LinkKind.vod, false),
  ('hls-vod-master', '$h/media/hls/master.m3u8', LinkKind.vod, true),
  ('hls-fmp4', '$h/media/hlsfmp4/index.m3u8', LinkKind.vod, true),
  ('dash-vod', '$h/media/dash/manifest.mpd', LinkKind.vod, true),
  ('live-ts', '$h/live.ts', LinkKind.live, false),
  ('live-hls', '$h/live/hls/index.m3u8', LinkKind.live, false),
  ('noext-mp4', '$h/noext/film', LinkKind.vod, true),
  ('noext-hls', '$h/noext/hls', LinkKind.vod, true),
  ('noext-live-ts', '$h/noext/live', LinkKind.live, false),
  ('user-agent', '$h/ua/film.mp4|User-Agent=CinemaTest/1.0', LinkKind.vod, true),
  ('referer', '$h/ref/film.mp4|Referer=http%3A%2F%2Fref.example%2F', LinkKind.vod, true),
  ('redirect', '$h/redir/film.mp4', LinkKind.vod, true),
  ('spaces-umlaut', '$h/Film Über [2020].mp4', LinkKind.vod, true),
  ('https-selfsigned', 'https://$host:8766/media/film.mp4', LinkKind.vod, true),
  ('https-on-http-server', 'https://$host:8765/media/hls/master.m3u8', LinkKind.vod, true),
  ('xtream-live-ts', '$h/live/u/p%23w/1.ts', LinkKind.live, false),
  ('xtream-live-m3u8', '$h/live/u/p%23w/1.m3u8', LinkKind.live, false),
  ('xtream-movie', '$h/movie/u/p%23w/10.mp4', LinkKind.vod, true),
  ('rtmp', 'rtmp://$host:1935/live/test', LinkKind.live, false),
  ('rtsp', 'rtsp://$host:8557/test', LinkKind.live, false), // nur UDP (VLC-Server)
  ('rtsp-tcp', 'rtsp://$host:8556/test', LinkKind.live, false), // nur TCP, UDP wird mit 461 abgelehnt
  ('udp', 'udp://${Platform.isAndroid ? '0.0.0.0' : '127.0.0.1'}:5000', LinkKind.live, false),
  ('srt', 'srt://$host:9000', LinkKind.live, false),
  // Mehrere Links durch Leerzeichen getrennt: extra-1, extra-2 …
  for (final (i, u) in extra.split(' ').where((u) => u.isNotEmpty).indexed) ('extra-${i + 1}', u, LinkKind.live, false),
];

/// Abspielen bis Bild/Ton läuft (Zeit läuft weiter), optional spulen.
Future<void> play(String name, String link,
    {bool seek = false, Duration timeout = const Duration(seconds: 30), String? engine}) async {
  final (url, headers) = Engine.splitHeaders(link, Repo.headers);
  final e = Engine.create(url, engine ?? engineName);
  view.value = e;
  final sw = Stopwatch()..start();
  String result;
  var ok = false;
  try {
    await WidgetsBinding.instance.endOfFrame;
    await e.open(url, headers);
    Duration? first;
    var steady = 0;
    final live = cases.any((c) => c.$2 == link && c.$3 == LinkKind.live);
    while (sw.elapsed < timeout) {
      await Future.delayed(const Duration(milliseconds: 250));
      final s = e.state.value;
      if (s.error != null && sw.elapsed > const Duration(seconds: 8)) break; // Schonfrist wie im Player
      if (s.ready && s.playing && s.position > Duration.zero) {
        first ??= s.position;
        steady = s.buffering ? 0 : steady + 1;
        // Live-HLS: die Position bleibt am Live-Rand stehen, daher zählt auch 3 s ohne Puffern
        if (s.position - first >= const Duration(milliseconds: 1500) || (live && steady >= 12)) {
          ok = true;
          break;
        }
      }
    }
    // Bildprüfung: Standbild trotz laufender Zeit erkennen. PC: zwei Bilder des Video-Widgets vergleichen;
    // Android: das Testskript vergleicht zwei Bildschirmfotos (Plattform-Ansichten erscheinen nicht in toImage)
    if (ok && const bool.fromEnvironment('SHOTS') && e.state.value.size.width > 0) {
      if (Platform.isAndroid) {
        // ignore: avoid_print
        print('COMPAT SHOT $name');
        await Future.delayed(const Duration(seconds: 6));
      } else {
        final a = await frame();
        await Future.delayed(const Duration(milliseconds: 2500));
        final b = await frame();
        log(a != b, '[bild] $name', a != b ? 'Bild bewegt sich' : 'STANDBILD');
      }
    }
    final s = e.state.value;
    result = ok
        ? 'läuft nach ${sw.elapsed.inMilliseconds} ms, ${s.size.width.round()}x${s.size.height.round()}, Dauer ${s.duration.inSeconds}s'
        : 'Fehler: ${s.error ?? 'Zeitüberschreitung'} (ready=${s.ready} playing=${s.playing} pos=${s.position})';
    if (ok && seek) {
      final to = e.state.value.duration > const Duration(seconds: 16) ? 12 : 6;
      await e.seek(Duration(seconds: to));
      var seeked = false;
      for (var i = 0; i < 40 && !seeked; i++) {
        await Future.delayed(const Duration(milliseconds: 250));
        seeked = e.state.value.position >= Duration(seconds: to - 1);
      }
      result += seeked ? ', Spulen ok' : ', Spulen FEHLT (pos=${e.state.value.position})';
      ok = seeked;
    }
    if (ok && name == 'mkv-2audio-subs') {
      final a = await e.audioTracks();
      result += ', Tonspuren: ${a.map((t) => t.label).join(' | ')}';
    }
  } catch (err) {
    result = 'Ausnahme: $err';
  }
  log(ok, 'play $name', result);
  view.value = null;
  await WidgetsBinding.instance.endOfFrame;
  await e.dispose();
}

Future<void> check(String name, Future<String> Function() f) async {
  try {
    log(true, name, await f().timeout(const Duration(seconds: 60)));
  } catch (e) {
    log(false, name, '$e');
  }
}

Future<void> run() async {
  bool want(String n) => only.isEmpty || only.split(',').any(n.contains);

  // 1) Typ-Erkennung aller Links
  for (final (name, link, kind, _) in cases) {
    if (!want(name)) continue;
    final k = await probeLink(link);
    log(k == kind, 'kind $name', '$k (erwartet $kind)');
  }

  // 2) Wiedergabe
  for (final (name, link, _, seekable) in cases) {
    if (!want(name)) continue;
    await play(name, link, seek: seekable);
  }

  if (!want('sources')) return;
  // 3) Quellen
  final xt = Source(id: 'xt', name: 'Xtream', type: SourceType.xtream, url: '$h/', user: 'u', pass: 'p#w');
  await check('xtream account', () async => '${(await Repo.xtreamAccount(xt))['status']}');
  late Library lib;
  await check('xtream load', () async {
    lib = await Repo.load(xt, force: true);
    final m = lib.of(Kind.movie);
    if (!m.any((x) => x.url!.endsWith('/10.mp4'))) throw 'leere Endung nicht .mp4: ${m.map((x) => x.url)}';
    return 'live ${lib.of(Kind.live).length}, filme ${m.length}, serien ${lib.of(Kind.series).length}, epg ${lib.epgUrl}';
  });
  await check('xtream episodes', () async {
    final eps = await Repo.episodes(xt, lib.of(Kind.series).first);
    if (eps.length != 2 || !eps.last.url.endsWith('.mp4')) throw 'Folgen: ${eps.map((e) => e.url)}';
    return eps.map((e) => e.url.split('/').last).join(', ');
  });
  await check('xtream epg', () async {
    await epg.ensure(xt, lib, force: true);
    final p = epg.now(xt, 'test.de');
    if (p == null) throw 'keine Sendung: ${epg.errors[xt.id]}';
    return p.title;
  });
  await play('xtream live from lib', lib.of(Kind.live).first.url!);
  await play('xtream catchup', Repo.catchupUrl(xt, lib.of(Kind.live).first, DateTime.now().subtract(const Duration(hours: 1)), DateTime.now()));

  final m3u = Source(id: 'm3u', name: 'M3U', type: SourceType.m3u, url: '$h/list.m3u');
  await check('m3u load', () async {
    final l = await Repo.load(m3u, force: true);
    final ua = l.of(Kind.live).firstWhere((x) => x.name == 'Mit UA');
    await play('m3u entry with EXTVLCOPT', ua.url!);
    return 'live ${l.of(Kind.live).length}, filme ${l.of(Kind.movie).length}, serien ${l.of(Kind.series).map((s) => s.name)}';
  });

  final st = Source(id: 'st', name: 'Stalker', type: SourceType.stalker, url: '$h/c/', mac: '00:1A:79:00:00:01');
  await check('stalker load+resolve', () async {
    final l = await Repo.load(st, force: true);
    final ch = l.of(Kind.live).single;
    final link = await Repo.stalkerResolve(st, ch.url!);
    await play('stalker live', link);
    final films = await l.lazy!(Kind.movie, 'Kino');
    final f = await Repo.stalkerResolve(st, films.single.url!);
    return 'kanal ${ch.name} -> $link; film ${films.single.name} -> $f';
  });

  // 4) Downloads und Aufnahme, danach offline abspielen
  final dl = Source(id: 'dl', name: 'DL', type: SourceType.m3u, url: '');
  store.saveSource(dl);
  for (final (name, url) in [('mp4', '$h/media/film.mp4'), ('hls', '$h/media/hls/master.m3u8'), ('hls-fmp4', '$h/media/hlsfmp4/index.m3u8')]) {
    await check('download $name', () async {
      await downloads.remove(url);
      downloads.add(dl, MediaItem(id: url, name: name, kind: Kind.movie, group: 'T'), url, 'Test $name', maxHeight: 480);
      final d = downloads.of(url)!;
      while (d.status != DlStatus.done && d.status != DlStatus.failed) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      if (d.status == DlStatus.failed) throw 'Download: ${d.error}';
      await play('offline $name', d.file, seek: true, engine: downloads.engineFor(url));
      return '${d.received} Bytes -> ${d.file}';
    });
  }
  await check('record live', () async {
    downloads.record(dl, const MediaItem(id: 'l', name: 'Live', kind: Kind.live, group: 'T'), '$h/live.ts', 1);
    final d = downloads.list.firstWhere((x) => x.isRecording && x.status == DlStatus.running);
    await Future.delayed(const Duration(seconds: 6));
    downloads.stopRecording(d.url);
    while (d.status == DlStatus.running) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (d.status != DlStatus.done) throw 'Aufnahme: ${d.status} ${d.error}';
    await play('offline recording', d.file);
    return '${d.received} Bytes';
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await store.init();
  await downloads.init();
  // Wie auf dem Fernseher: SurfaceView statt TextureView (ExoPlayer)
  store.set('surfaceView', const bool.fromEnvironment('SURFACE'));
  runApp(MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: RepaintBoundary(
        key: boundary,
        child: ValueListenableBuilder(
          valueListenable: view,
          builder: (_, e, _) => e == null ? const SizedBox.expand() : e.view(BoxFit.contain),
        ),
      ),
    ),
  ));
  await Future.delayed(const Duration(milliseconds: 500));
  await run();
  // ignore: avoid_print
  print('COMPAT DONE [$engineName] $passed/$total');
  await Future.delayed(const Duration(seconds: 1));
  exit(0);
}
