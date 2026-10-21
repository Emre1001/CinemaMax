import 'dart:convert';
import 'dart:io';

import 'package:cinemamax/downloads.dart';
import 'package:cinemamax/epg.dart';
import 'package:cinemamax/links.dart';
import 'package:cinemamax/m3u.dart';
import 'package:cinemamax/models.dart';
import 'package:cinemamax/playback.dart';
import 'package:cinemamax/repo.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Eingaben aus der Praxis: Links, Playlists, Header, Server-Macken.
void main() {
  late HttpServer server;
  late String base;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    final dir = Directory.systemTemp.createTempSync('cm');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    SharedPreferences.setMockInitialValues({});
    await store.init();
    await downloads.init();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final res = r.response;
      switch (r.uri.path) {
        // Live-Sender: endloser Strom ohne Range-Unterstützung (immer 200)
        case '/live.ts':
          res.headers.contentType = ContentType('video', 'mp2t');
          try {
            for (var i = 0; i < 400; i++) {
              res.add(List.filled(188, 0x47));
              await res.flush();
              await Future.delayed(const Duration(milliseconds: 10));
            }
          } catch (_) {/* Client hat beendet */}
        // HLS-Hauptliste hinter Weiterleitung, Varianten relativ zur neuen Adresse
        case '/go':
          res
            ..statusCode = 302
            ..headers.set('location', '/cdn/x/master.m3u8');
        case '/cdn/x/master.m3u8':
          res.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv/index.m3u8\n');
        case '/cdn/x/v/index.m3u8':
          res.write('#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST\n');
        case '/noext':
          res.add([0, 0, 0, 0x18, ...ascii.encode('ftypisom'), ...List.filled(64, 0)]);
        case '/dash':
          res.write('<?xml version="1.0"?><MPD type="static" mediaPresentationDuration="PT1M"></MPD>');
        case '/dashlive':
          res.write("<?xml version='1.0'?><MPD type='dynamic'></MPD>");
        // Playlist nur mit passendem User-Agent, alte Latin-1-Kodierung
        case '/ua.m3u':
          if (r.headers.value('user-agent') != 'Smart/1') {
            res.statusCode = 403;
          } else {
            res.add(latin1.encode('#EXTM3U\n#EXTINF:-1 group-title="Österreich",ORF 1\nhttp://x/1.ts\n'));
          }
        case '/gz.m3u':
          res.add(gzip.encode(utf8.encode('#EXTM3U\n#EXTINF:-1,Sender\nhttp://x/2.ts\n')));
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDownAll(() => server.close(force: true));

  group('Links', () {
    test('Pfade in Anführungszeichen, Netzwerkfreigaben, weitere Protokolle', () {
      expect(extractLink(r'"C:\Users\Emre\Videos\Film 1.mkv"'), r'C:\Users\Emre\Videos\Film 1.mkv');
      expect(extractLink(r'\\nas\filme\a.mp4'), r'\\nas\filme\a.mp4');
      expect(localPath(r'\\nas\filme\a.mp4'), r'\\nas\filme\a.mp4');
      expect(extractLink("'/home/u/liste.m3u'"), '/home/u/liste.m3u');
      expect(extractLink('rtsps://cam/live'), 'rtsps://cam/live');
      expect(extractLink('mmsh://srv/x'), 'mmsh://srv/x');
      expect(extractLink('rtmpe://srv/app'), 'rtmpe://srv/app');
    });

    test('Typ-Erkennung: player_api.php, DASH, Dateikopf, Groß-/Kleinschreibung', () {
      expect(classifyLink('http://h/player_api.php?username=u&password=p', null), LinkKind.xtream);
      expect(classifyLink('http://h/GET.PHP?username=u&password=p', null), LinkKind.xtream);
      expect(classifyLink('http://h/m', '<?xml?><MPD type="static">'), LinkKind.vod);
      expect(classifyLink('http://h/m', "<MPD type='dynamic'>"), LinkKind.live);
      expect(classifyLink('http://h/x', '\u0000\u0000\u0000\u0018ftypisom'), LinkKind.vod);
      expect(classifyLink('http://h/x', '\u001aE\u07e3\u0001'), LinkKind.vod);
      expect(classifyLink('http://h/FILM.M2TS', null), LinkKind.vod);
    });

    test('Probe: Weiterleitung mit relativen Varianten, Datei ohne Endung, DASH', () async {
      expect(await probeLink('$base/go'), LinkKind.vod);
      expect(await probeLink('$base/noext'), LinkKind.vod);
      expect(await probeLink('$base/dash'), LinkKind.vod);
      expect(await probeLink('$base/dashlive'), LinkKind.live);
    });
  });

  group('Header', () {
    test('Schreibweise egal, keine Doppel, kaputte Kodierung stürzt nicht ab', () {
      final (u, h) = Engine.splitHeaders('http://h/a.m3u8|user-agent=X%2F1&referrer=http://r/&x=100%', {'User-Agent': 'VLC'});
      expect(u, 'http://h/a.m3u8');
      expect(h, {'User-Agent': 'X/1', 'Referer': 'http://r/', 'X': '100%'});
    });

    test('Tonspur-Sprache als Wort', () {
      expect(Engine.langMatch('Audio Description · en', ['de', 'deu', 'ger']), isFalse);
      expect(Engine.langMatch('Undefined · und', ['de', 'deu', 'ger']), isFalse);
      expect(Engine.langMatch('Stereo · de', ['de', 'deu', 'ger']), isTrue);
      expect(Engine.langMatch('German', ['de', 'deu', 'ger']), isTrue);
      expect(Engine.langMatch('DEU', ['de', 'deu', 'ger']), isTrue);
    });
  });

  group('M3U', () {
    test('Serienname bei Kategorie mit „|“', () {
      final r = parseM3u('#EXTM3U\n#EXTINF:-1 group-title="DE | SERIEN",Dark S01 E01\nhttp://h/series/1.mkv\n');
      expect(r[Kind.series]!.single.name, 'Dark');
      expect(r[Kind.series]!.single.group, 'DE | SERIEN');
    });

    test('Header: vorhandene Kodi-Header behalten, Attribute, KODIPROP, nur CR als Zeilenende', () {
      final r = parseM3u('#EXTM3U\r'
          '#EXTINF:-1,A\r#EXTVLCOPT:http-referrer=http://r/\rhttp://h/a.m3u8|User-Agent=Foo\r'
          '#EXTINF:-1 http-user-agent="Bar/2" tvg-id="b",B\rhttp://h/b.m3u8\r'
          '#EXTINF:-1,C\r#KODIPROP:inputstream.adaptive.stream_headers=User-Agent=Baz%2F3&Referer=http%3A%2F%2Fq%2F\rhttp://h/c.mpd\r');
      final live = r[Kind.live]!;
      expect(live.map((e) => e.name), ['A', 'B', 'C']);
      expect(Engine.splitHeaders(live[0].url!, {}).$2, {'User-Agent': 'Foo', 'Referer': 'http://r/'});
      expect(Engine.splitHeaders(live[1].url!, {}).$2, {'User-Agent': 'Bar/2'});
      final (c, ch) = Engine.splitHeaders(live[2].url!, {});
      expect(c, 'http://h/c.mpd');
      expect(ch, {'User-Agent': 'Baz/3', 'Referer': 'http://q/'});
    });

    test('EPG-Adresse auch mit BOM', () {
      expect(m3uEpgUrl('\uFEFF#EXTM3U url-tvg="http://e/epg.xml.gz"\n'), 'http://e/epg.xml.gz');
    });

    test('Playlist mit Pflicht-User-Agent am Link, Latin-1 und gzip', () async {
      final ua = Source(id: 'ua', name: 'UA', type: SourceType.m3u, url: '$base/ua.m3u|User-Agent=Smart/1');
      final lib = await Repo.load(ua, force: true);
      expect(lib.of(Kind.live).single.group, 'Österreich');
      final gz = Source(id: 'gz', name: 'GZ', type: SourceType.m3u, url: '$base/gz.m3u');
      expect((await Repo.load(gz, force: true)).of(Kind.live).single.name, 'Sender');
      expect(Repo.decodeText(utf8.encode('Grüße \u00ff')), 'Grüße \u00ff');
    });
  });

  test('Video-Stream als Playlist eingetragen: schneller, klarer Fehler', () async {
    final s = Source(id: 'vs', name: 'VS', type: SourceType.m3u, url: '$base/live.ts');
    final sw = Stopwatch()..start();
    await expectLater(Repo.load(s, force: true), throwsA(isA<FormatException>()));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  group('Xtream', () {
    test('Leere Dateiendung, Serie ohne Folgen, Staffeln als Objekt', () async {
      final s = Source(id: 'xc', name: 'X', type: SourceType.xtream, url: 'http://h', user: 'u', pass: 'p');
      await http.runWithClient(() async {
        final lib = await Repo.load(s, force: true);
        expect(lib.of(Kind.movie).single.url, 'http://h/movie/u/p/5.mp4');
        expect(await Repo.xtreamEpisodes(s, 'leer'), isEmpty);
        final eps = await Repo.xtreamEpisodes(s, '9');
        expect(eps.map((e) => e.url), ['http://h/series/u/p/91.mp4', 'http://h/series/u/p/92.mkv']);
      }, () => MockClient((r) async {
        final q = r.url.queryParameters;
        final body = switch (q['action']) {
          'get_vod_streams' => [{'stream_id': 5, 'name': 'Film', 'category_id': '1', 'container_extension': ''}],
          'get_series_info' when q['series_id'] == 'leer' => [],
          'get_series_info' => {
              'episodes': {
                '1': {
                  '0': {'id': 91, 'season': 1, 'episode_num': '1', 'title': 'A', 'container_extension': null},
                  '1': {'id': 92, 'season': 1, 'episode_num': '2', 'title': 'B', 'container_extension': 'mkv'},
                },
              },
            },
          _ => [],
        };
        return http.Response(jsonEncode(body), 200);
      }));
    });
  });

  test('EPG: Zahlen-Zeichen und einfache Anführungszeichen', () {
    final out = <String, List<Prog>>{};
    final now = DateTime.now().toUtc();
    String t(DateTime d) => '${d.year}${'${d.month}'.padLeft(2, '0')}${'${d.day}'.padLeft(2, '0')}'
        '${'${d.hour}'.padLeft(2, '0')}0000 +0000';
    parseProgrammes(
        "<programme start='${t(now)}' stop='${t(now.add(const Duration(hours: 2)))}' channel='ard'>"
        '<title>K&#228;se &#xFC;ber &amp; mehr</title></programme>',
        {'ard': 3},
        DateTime.now(),
        DateTime.now().add(const Duration(hours: 36)),
        out);
    expect(out['ard']!.single.title, 'Käse über & mehr');
  });

  test('Live-Aufnahme: Server antwortet mit 200, Aufnahme wird fertig', () async {
    final s = Source(id: 'rec', name: 'R', type: SourceType.m3u, url: '');
    const ch = MediaItem(id: 'c', name: 'Kanal', kind: Kind.live, group: 'G');
    downloads.record(s, ch, '$base/live.ts', 15);
    final d = downloads.list.firstWhere((d) => d.isRecording);
    for (var i = 0; i < 100 && d.received < 188 * 20; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    downloads.stopRecording(d.url);
    for (var i = 0; i < 100 && d.status == DlStatus.running; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(d.error, isNull);
    expect(d.status, DlStatus.done);
    expect(await File(d.file).length(), greaterThan(188 * 20));
  });
}
