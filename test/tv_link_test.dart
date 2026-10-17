import 'dart:convert';

import 'package:cinemamax/tv_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Code: Zufall, Schreibweisen, aus Link', () {
    final l = TvLink.random();
    expect(TvLink.normalize(l.code), l.code);
    expect(TvLink.normalize(l.pretty.toLowerCase()), l.code);
    expect(TvLink.normalize('k7m2q-9xr4t'), 'K7M2Q9XR4T');
    expect(TvLink.normalize('O1LIU 00000'), '0111V00000');
    expect(TvLink.normalize('K7M2Q'), isNull);
    expect(TvLink.fromText('https://emre1001.github.io/CinemaMax/tv/#K7M2Q9XR4T'), 'K7M2Q9XR4T');
  });

  test('Verschlüsselt hin und zurück, fremder Code und Manipulation scheitern', () {
    final a = TvLink('K7M2Q9XR4T');
    final msg = {'k': 'server', 'type': 'xtream', 'url': 'http://h.tv:8080', 'user': 'ü', 'pass': 'p#w' * 40};
    final sealed = a.seal(msg);
    expect(sealed, isNot(contains('h.tv')));
    expect(a.open(sealed), msg);
    expect(TvLink('K7M2Q9XR4V').open(sealed), isNull);
    final j = jsonDecode(sealed) as Map;
    final c = base64.decode(j['c'])..[0] ^= 1;
    expect(a.open(jsonEncode({...j, 'c': base64.encode(c)})), isNull);
    expect(a.topic, startsWith('cmx-'));
    expect(a.topic, isNot(contains(a.code)));
  });

  test('Gleiches Verfahren wie die Webseite (docs/tv/tvlink.js)', () {
    final a = TvLink('K7M2Q9XR4T');
    expect(a.topic, 'cmx-361d8cab4267c333919a65a575c542f5');
    // Mit tvlink.js (WebCrypto) verschlüsselt
    const fromWeb =
        '{"v":1,"n":"tAu1JeTq4BS5NrwCOd9fNA==","c":"NBh3UPCfi5icoNgusi3BecLK/OdvbbWUgsXQKVPpb2GLpEwB/Bf/z34ktIN2VXkgHY64f6OMH1KIgn8x4h7JdDmwObIF9OP0DuBSX4Kua7A=","t":"DWI7t/XCeJpcV0seixXkDcIuQKdRIA6imremhq2L7/0="}';
    expect(a.open(fromWeb), {'k': 'server', 'type': 'xtream', 'url': 'http://h.tv:8080', 'user': 'ü', 'pass': 'p#w'});
  });
}
