import 'dart:io';

import 'package:cinemamax/downloads.dart';
import 'package:cinemamax/models.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late HttpServer server;
  late String base;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null; // echte Verbindungen zum lokalen Testserver
    final dir = Directory.systemTemp.createTempSync('cm');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    SharedPreferences.setMockInitialValues({});
    await store.init();
    await downloads.init();
    // Film als HLS: Hauptliste leitet auf einen anderen Pfad um, Segmente relativ dazu
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      final res = r.response;
      final p = r.uri.path;
      if (p == '/film.m3u8') {
        res
          ..statusCode = 302
          ..headers.set('location', '/cdn/master.m3u8');
      } else if (p == '/cdn/master.m3u8') {
        res.write('#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nlow/index.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1280x720\nhigh/index.m3u8\n');
      } else if (p.endsWith('/index.m3u8')) {
        res.write('#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
            '#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts\n#EXTINF:4,\nc.ts\n#EXT-X-ENDLIST\n');
      } else if (p.endsWith('.ts')) {
        res.write('${p.split('/')[2]}-${p.split('/').last};');
      } else {
        res.statusCode = 404;
      }
      res.close();
    });
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDownAll(() => server.close(force: true));

  test('1920×1088 gilt beim Download als 1080p', () {
    final v = [
      (uri: Uri.parse('a'), height: 2160, bandwidth: 20000000, separateAudio: false),
      (uri: Uri.parse('b'), height: 1088, bandwidth: 6000000, separateAudio: false),
      (uri: Uri.parse('c'), height: 720, bandwidth: 3000000, separateAudio: false),
    ];
    expect(pickVariant(v, 1080).height, 1088);
    expect(pickVariant(v, 0).height, 2160);
    expect(pickVariant(v, 360).height, 720); // nichts passt: kleinste
  });

  test('Sicherung enthält keine gerätebezogene Leistungsmessung', () {
    store.set('perfSlow', true);
    store.set('perfVerySlow', true);
    store.set('accent', 0xFF30A46C);
    final backup = store.exportBackup();
    expect(backup, isNot(contains('perfSlow')));
    expect(backup, contains('accent'));
  });

  test('Qualitäten mit geschätzter Größe', () async {
    final s = Source(id: 's', name: 'S', type: SourceType.m3u, url: '');
    final q = await hlsQualities(s, '$base/film.m3u8');
    expect(q.map((v) => v.height), [720, 360]);
    expect(q.first.bytes, 5000000 ~/ 8 * 12);
  });

  test('HLS-Download in gewählter Auflösung als eine Datei', () async {
    final s = Source(id: 's', name: 'S', type: SourceType.m3u, url: '');
    const m = MediaItem(id: 'f', name: 'Film', kind: Kind.movie, group: 'G');
    downloads.add(s, m, '$base/film.m3u8', 'Film', maxHeight: 480);
    final d = downloads.of('$base/film.m3u8')!;
    for (var i = 0; i < 100 && d.status != DlStatus.done && d.status != DlStatus.failed; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(d.error, isNull);
    expect(d.status, DlStatus.done);
    expect(await File(d.file).readAsString(), 'low-a.ts;low-b.ts;low-c.ts;');
    expect(d.progress, 1);
  });
}
