import 'dart:async';
import 'dart:io';

import 'package:cinemamax/errors.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'lang': 'de'});
    await store.init();
  });

  test('Fehler werden als deutscher Klartext erklärt, ohne Code', () {
    expect(explain(const HandshakeException('WRONG_VERSION_NUMBER(tls_record.cc:127)')), contains('http://'));
    expect(explain(const SocketException('Failed host lookup: x')), startsWith('Server nicht gefunden'));
    expect(explain(const SocketException('Connection refused')), contains('lehnt die Verbindung ab'));
    expect(explain(TimeoutException('x')), contains('antwortet nicht'));
    expect(explain(const HttpException('HTTP 403')), startsWith('Zugang verweigert'));
    expect(explain(const HttpException('HTTP 503')), contains('Problem'));
    expect(explain(const FormatException('Login fehlgeschlagen')), startsWith('Anmeldung fehlgeschlagen'));
    expect(explain(const FormatException('Unexpected character')), contains('keine gültigen Daten'));
    expect(explain('Source error: MediaCodecVideoRenderer error, decoder failed', playback: true), contains('Videoformat'));
    expect(explain('irgendwas', playback: true), contains('nicht abgespielt'));
    expect(explain(Exception('x')), 'Unerwarteter Fehler. Bitte erneut versuchen.');
  });
}
