import 'dart:convert';
import 'dart:io';

import 'package:cinemamax/models.dart';
import 'package:cinemamax/repo.dart';
import 'package:cinemamax/store.dart';
import 'package:cinemamax/ui/start.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Xtream-Server mit typischen Macken: BOM, PHP-Warnung vor dem JSON, Liste als Objekt.
http.Response panel(http.Request r, {String status = 'Active'}) {
  final a = r.url.queryParameters['action'];
  final body = switch (a) {
    null => {'user_info': {'auth': 1, 'status': status}},
    'get_live_categories' => [{'category_id': '1', 'category_name': 'Sport'}],
    'get_live_streams' => {'0': {'stream_id': 7, 'name': 'Sport 1', 'category_id': '1'}},
    _ => [],
  };
  final json = jsonEncode(body);
  return http.Response.bytes(utf8.encode(a == 'get_live_streams' ? '<br /><b>Warning</b>: x<br />$json' : '\uFEFF$json'), 200);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Disk-Cache der Bibliothek in einen Temp-Ordner
    final dir = Directory.systemTemp.createTempSync('cm');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    SharedPreferences.setMockInitialValues({});
    await store.init();
  });

  test('get.php- und player_api.php-Links werden zu Xtream, Pfad bleibt', () {
    final a = xtreamFromUrl(Uri.parse('http://h.tv:8080/get.php?username=u&password=p%23w&type=m3u_plus'))!;
    expect((a.host, a.user, a.pass), ('http://h.tv:8080', 'u', 'p#w'));
    expect(xtreamFromUrl(Uri.parse('https://h.tv/panel/player_api.php?username=u'))!.host, 'https://h.tv/panel');
    expect(xtreamFromUrl(Uri.parse('http://h.tv/list.m3u')), isNull);
    expect(xtreamFromUrl(Uri.parse('http://h.tv/get.php?type=m3u')), isNull);
  });

  test('MAC in jeder Schreibweise', () {
    expect(normalizeMac('00-1a-79-12-34-ab'), '00:1A:79:12:34:AB');
    expect(normalizeMac(' 001A7912 34AB '), '00:1A:79:12:34:AB');
    expect(normalizeMac('00:1A:79:'), '00:1A:79:');
  });

  test('Xtream mit BOM, PHP-Warnung, Liste als Objekt und Sonderzeichen im Passwort', () async {
    final s = Source(id: 'xt', name: 'X', type: SourceType.xtream, url: 'http://h.tv:8080/', user: 'u', pass: 'p#w');
    await http.runWithClient(() async {
      expect((await Repo.xtreamAccount(s))['status'], 'Active');
      final ch = (await Repo.load(s, force: true)).of(Kind.live).single;
      expect(ch.group, 'Sport');
      expect(ch.url, 'http://h.tv:8080/live/u/p%23w/7.ts');
    }, () => MockClient((r) async => panel(r)));
  });

  test('Abgelaufener Zugang wird klar gemeldet', () async {
    final s = Source(id: 'xe', name: 'X', type: SourceType.xtream, url: 'http://h.tv', user: 'u', pass: 'p');
    await http.runWithClient(
      () => expectLater(Repo.xtreamAccount(s), throwsA(isA<StateError>())),
      () => MockClient((r) async => panel(r, status: 'Expired')),
    );
  });
}
