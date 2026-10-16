import 'package:cinemamax/epg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('XMLTV-Zeit mit Zeitzone', () {
    expect(xmltvTime('20261016203000 +0200')!.toUtc(), DateTime.utc(2026, 10, 16, 18, 30));
    expect(xmltvTime('20261016203000')!.toUtc(), DateTime.utc(2026, 10, 16, 20, 30));
    expect(xmltvTime('kaputt'), isNull);
  });

  test('Programme filtern: nur bekannte Sender, Zeitfenster, Entities', () {
    final now = DateTime.utc(2026, 10, 16, 20);
    const xml = '''
<programme start="20261016190000 +0000" stop="20261016210000 +0000" channel="ARD.de">
  <title lang="de">Tagesschau &amp; Wetter</title><desc>Nachrichten</desc></programme>
<programme start="20261016190000 +0000" stop="20261016210000 +0000" channel="other"><title>X</title></programme>
<programme start="20261010190000 +0000" stop="20261010200000 +0000" channel="ard.de"><title>Alt</title></programme>''';
    final out = <String, List<Prog>>{};
    parseProgrammes(xml, {'ard.de': 3}, now, now.add(const Duration(hours: 36)), out);
    expect(out.keys, ['ard.de']);
    expect(out['ard.de']!.single.title, 'Tagesschau & Wetter');
    expect(out['ard.de']!.single.desc, 'Nachrichten');
  });
}
