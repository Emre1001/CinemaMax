import 'dart:io';

import 'package:cinemamax/links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Link aus geteiltem Text', () {
    expect(extractLink('Schau mal: http://h:8080/live/a.m3u8, cool'), 'http://h:8080/live/a.m3u8');
    expect(extractLink('rtmp://srv/app/key'), 'rtmp://srv/app/key');
    expect(extractLink('/storage/emulated/0/Download/liste.m3u'), '/storage/emulated/0/Download/liste.m3u');
    expect(extractLink(r'C:\Videos\film.mkv'), r'C:\Videos\film.mkv');
    expect(extractLink('content://media/external/video/42'), 'content://media/external/video/42');
    expect(extractLink('kein link hier'), isNull);
  });

  test('Typ-Erkennung: Playlist, Xtream, HLS-Film, Live', () {
    expect(classifyLink('http://h/get.php?username=u&password=p&type=m3u_plus', null), LinkKind.xtream);
    expect(classifyLink('http://h/liste', '\uFEFF#EXTM3U\n#EXTINF:-1,ARD\nhttp://x/1.ts\n'), LinkKind.playlist);
    expect(classifyLink('http://h/a.m3u8', '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg1.ts\n'), LinkKind.live);
    expect(classifyLink('http://h/a.m3u8', '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg1.ts\n#EXT-X-ENDLIST\n'),
        LinkKind.vod);
    expect(classifyLink('http://h/film.mkv?token=1', null), LinkKind.vod);
    expect(classifyLink('http://h/stream', null, contentType: 'video/mp4'), LinkKind.vod);
    expect(classifyLink('http://h/live/1', null, contentType: 'video/mp2t'), LinkKind.live);
    expect(classifyLink('udp://239.0.0.1:1234', null), LinkKind.live);
    expect(classifyLink('/sdcard/aufnahme', null), LinkKind.vod);
  });

  test('Lokale Playlist-Datei wird als Playlist erkannt', () async {
    final f = File('${Directory.systemTemp.createTempSync().path}/liste.m3u')
      ..writeAsStringSync('#EXTM3U\n#EXTINF:-1,Kanal\nhttp://x/1.ts\n');
    expect(await probeLink(f.path), LinkKind.playlist);
    expect(await probeLink(Uri.file(f.path).toString()), LinkKind.playlist);
  });

  test('Titel aus Link', () {
    expect(linkTitle('http://h/filme/Der%20Pate.mkv'), 'Der Pate');
    expect(linkTitle('http://h:8080/live/u/p/123.ts'), 'h');
    expect(linkTitle('rtmp://srv.tv/app/'), 'app');
    expect(linkTitle('content://com.android.externalstorage.documents/document/primary%3ADownload%2Fliste.m3u'), 'liste');
    expect(linkTitle('http://h/100%25%20Pur.mp4'), '100% Pur');
    expect(linkTitle('/home/u/Meine Liste.m3u'), 'Meine Liste');
    expect(linkTitle(r'C:\Videos\film.mkv'), 'film');
  });
}
