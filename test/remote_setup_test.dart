import 'dart:io';

import 'package:cinemamax/remote_setup.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('Handy-Eingabe: Formular nur mit Code, Daten kommen an', () async {
    SharedPreferences.setMockInitialValues({});
    await store.init();
    if (await RemoteSetup.lanAddress() == null) return markTestSkipped('kein Netz');
    Map<String, String>? got;
    final setup = await RemoteSetup.start((d) => got = d);
    try {
      // Über localhost testen: gleicher Port und Code wie in der angezeigten Adresse
      final u = Uri.parse(setup.url).replace(host: InternetAddress.loopbackIPv4.address);
      expect((await http.get(u.replace(path: '/00000'))).statusCode, 404);
      expect((await http.get(u)).body, contains('<form'));
      final r = await http.post(u, body: {'type': 'xtream', 'url': 'http://h.tv:8080', 'user': 'a b', 'pass': 'p+w&x'});
      expect(r.body, contains('<h2>'));
      expect(got, {'type': 'xtream', 'url': 'http://h.tv:8080', 'user': 'a b', 'pass': 'p+w&x'});
    } finally {
      await setup.stop();
    }
  });
}
