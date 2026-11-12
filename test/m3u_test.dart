import 'package:cinemamax/m3u.dart';
import 'package:cinemamax/models.dart';
import 'package:cinemamax/playback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sample = '''#EXTM3U
#EXTINF:-1 tvg-id="das.erste" tvg-logo="http://x/ard.png" group-title="DE | Vollprogramm",Das Erste HD
http://srv:8080/live/u/p/1.ts
#EXTINF:-1 group-title="Filme",Inception, the Movie (2010)
http://srv:8080/movie/u/p/55.mkv
#EXTINF:-1 tvg-logo="http://x/dark.jpg" group-title="Serien DE",Dark S02 E01
http://srv:8080/series/u/p/901.mp4
#EXTINF:-1 group-title="Serien DE",Dark S01 E02
http://srv:8080/series/u/p/900.mp4
#EXTINF:-1,Ohne Gruppe
#EXTGRP:Sonstiges
http://example.com/stream.m3u8
''';

  test('M3U: Live, Filme und Serien werden erkannt und gruppiert', () {
    final r = parseM3u(sample);
    expect(r[Kind.live]!.map((e) => e.name), ['Das Erste HD', 'Ohne Gruppe']);
    expect(r[Kind.live]!.first.logo, 'http://x/ard.png');
    expect(r[Kind.live]!.first.epgId, 'das.erste');
    expect(r[Kind.live]![1].group, 'Sonstiges');
    expect(r[Kind.movie]!.single.name, 'Inception, the Movie (2010)');
    final dark = r[Kind.series]!.single;
    expect(dark.name, 'Dark');
    expect(dark.episodes!.map((e) => '${e.season}x${e.number}'), ['1x2', '2x1']);
  });

  test('Andere Playlist-Formate: XSPF, PLS, ASX, Enigma2', () {
    List<String> live(String text) => [for (final m in parseM3u(text, liveOnly: true)[Kind.live]!) '${m.name}|${m.url}'];
    expect(
        live('<?xml version="1.0"?><playlist version="1"><trackList>'
            '<track><location>http://h/1.ts?a=1&amp;b=2</location><title>Eins &amp; Zwei</title><image>http://h/l.png</image></track>'
            '<track><title>ohne Link</title></track></trackList></playlist>'),
        ['Eins & Zwei|http://h/1.ts?a=1&b=2']);
    expect(parseM3u('<playlist><trackList><track><location>http://h/1.ts</location><image>http://h/l.png</image></track></trackList></playlist>',
            liveOnly: true)[Kind.live]!.single.logo, 'http://h/l.png');
    expect(live('[playlist]\nFile1=http://h/a.mp3\nTitle1=Radio A\nFile2=http://h/b.mp3\nNumberOfEntries=2\n'),
        ['Radio A|http://h/a.mp3', 'http://h/b.mp3|http://h/b.mp3']);
    expect(live('<ASX version="3.0"><Entry><Title>Sender</Title><Ref href="mms://h/s"/></Entry></ASX>'), ['Sender|mms://h/s']);
    final e2 = parseM3u('#NAME Sport\n#SERVICE 4097:0:1:0:0:0:0:0:0:0:http%3a//h%3a8080/live/u/p/1.ts:Alt\n#DESCRIPTION Sky Sport\n',
        liveOnly: true)[Kind.live]!.single;
    expect([e2.name, e2.url, e2.group], ['Sky Sport', 'http://h:8080/live/u/p/1.ts', 'Sport']);
    // M3U bleibt, wie es ist
    expect(toM3u(sample), sample);
  });

  test('Titel mit Anführungszeichen und Komma', () {
    final r = parseM3u('#EXTM3U\n#EXTINF:-1 tvg-name="X" group-title="Filme",Der "Pate", Teil 2\nhttp://h/movie/1.mkv\n');
    expect(r[Kind.movie]!.single.name, 'Der "Pate", Teil 2');
  });

  test('IPTV-Modus: alles ist Live', () {
    final r = parseM3u(sample, liveOnly: true);
    expect(r[Kind.live]!.length, 5);
    expect(r[Kind.movie], isEmpty);
    expect(r[Kind.series], isEmpty);
  });

  test('Typ-Erkennung ohne /movie/-Pfade', () {
    expect(classify('http://h/u/p/1', 'Matrix', 'VOD | Action', null), Kind.movie);
    expect(classify('http://h/u/p/2', 'Dark S01E03', 'Serien | Netflix', null), Kind.series);
    expect(classify('http://h/u/p/3.ts', 'Sky Cinema', 'DE | KINO', null), Kind.live);
    expect(classify('http://h/x.mkv', 'Film', 'Neu', null), Kind.movie);
    expect(classify('http://h/x', 'Film', 'Neu', 'movie'), Kind.movie);
    expect(classify('http://h/u/p/4', 'ARD', 'DE | Vollprogramm', null), Kind.live);
  });

  test('Header aus #EXTVLCOPT landen am Link (Kodi-Schreibweise)', () {
    final r = parseM3u('#EXTM3U\n#EXTINF:-1,Kanal\n#EXTVLCOPT:http-user-agent=Foo/1.0\n#EXTVLCOPT:http-referrer=http://ref/\nhttp://h/live.m3u8\n'
        '#EXTINF:-1,Ohne\nhttp://h/2.m3u8\n');
    expect(r[Kind.live]![0].url, 'http://h/live.m3u8|User-Agent=Foo%2F1.0&Referer=http%3A%2F%2Fref%2F');
    expect(r[Kind.live]![1].url, 'http://h/2.m3u8');
    final (u, h) = Engine.splitHeaders(r[Kind.live]![0].url!, {'User-Agent': 'VLC'});
    expect(u, 'http://h/live.m3u8');
    expect(h, {'User-Agent': 'Foo/1.0', 'Referer': 'http://ref/'});
  });
}
