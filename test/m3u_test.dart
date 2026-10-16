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
