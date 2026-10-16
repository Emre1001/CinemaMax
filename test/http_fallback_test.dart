import 'dart:convert';
import 'dart:io';

import 'package:cinemamax/models.dart';
import 'package:cinemamax/repo.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late HttpServer server;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await store.init();
    // IPTV-Server, der nur http spricht (wie Port 8080 bei den meisten Anbietern)
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      r.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'user_info': {'auth': 1, 'status': 'Active', 'exp_date': null, 'active_cons': 0, 'max_connections': 1},
        }))
        ..close();
    });
  });

  tearDownAll(() => server.close(force: true));

  test('https-Link auf http-Server: Fallback auf http, Quelle wird umgestellt', () async {
    final s = Source(id: 'x', name: 'X', type: SourceType.xtream, url: 'https://127.0.0.1:${server.port}', user: 'u', pass: 'p');
    final info = await Repo.xtreamAccount(s);
    expect(info['status'], 'Active');
    expect(s.url, 'http://127.0.0.1:${server.port}');
  });

  test('Server nicht erreichbar: Fehler bleibt, Link bleibt unverändert', () async {
    final s = Source(id: 'y', name: 'Y', type: SourceType.xtream, url: 'https://127.0.0.1:1', user: 'u', pass: 'p');
    await expectLater(Repo.xtreamAccount(s), throwsA(anything));
    expect(s.url, 'https://127.0.0.1:1');
  });
}
