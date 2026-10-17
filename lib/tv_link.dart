import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Zugangsdaten von überall auf einen Fernseher bringen (z. B. für Freunde): der Empfänger zeigt
/// einen Code (und QR), der Absender schickt die Daten über die App oder die Webseite.
///
/// Ende-zu-Ende verschlüsselt über ein öffentliches Relay (ntfy.sh). Das Relay sieht nur den
/// Chiffretext und ein aus dem Code abgeleitetes Thema, nie den Code selbst.
/// Verfahren (gleich in docs/tv/index.html): Schlüssel = HMAC-SHA256(Code, Zweck),
/// Verschlüsselung = HMAC-SHA256 als Zähler-Schlüsselstrom, Echtheit = HMAC-SHA256 über Nonce + Chiffretext.
class TvLink {
  static const relay = 'https://ntfy.sh';
  static const site = 'https://emre1001.github.io/CinemaMax/tv/';

  /// Crockford-Base32: keine verwechselbaren Zeichen (I, L, O, U).
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const length = 10; // 50 Bit

  final String code;
  TvLink(this.code);

  factory TvLink.random() {
    final r = Random.secure();
    return TvLink([for (var i = 0; i < length; i++) _alphabet[r.nextInt(32)]].join());
  }

  /// Eingabe wie „k7m2q-9xr4t“ oder „K7M2Q 9XR4T“; Verwechsler O/I/L werden korrigiert. null = ungültig.
  static String? normalize(String input) {
    final c = input
        .toUpperCase()
        .replaceAll(RegExp(r'[^0-9A-Z]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1')
        .replaceAll('U', 'V');
    return c.length == length && c.split('').every(_alphabet.contains) ? c : null;
  }

  /// Code aus einem gescannten Link („…/tv/#K7M2Q9XR4T“) oder getippt.
  static String? fromText(String text) => normalize(Uri.tryParse(text.trim())?.fragment ?? '') ?? normalize(text);

  String get pretty => '${code.substring(0, 5)}-${code.substring(5)}';
  String get url => '$site#$code';

  List<int> _key(String purpose) =>
      Hmac(sha256, utf8.encode(code)).convert(utf8.encode('cinemamax-link-v1/$purpose')).bytes;

  String get topic => 'cmx-${_hex(_key('topic')).substring(0, 32)}';

  List<int> _stream(List<int> nonce, int length) {
    final h = Hmac(sha256, _key('enc'));
    final out = <int>[];
    for (var i = 0; out.length < length; i++) {
      out.addAll(h.convert([...nonce, (i >> 24) & 255, (i >> 16) & 255, (i >> 8) & 255, i & 255]).bytes);
    }
    return out.sublist(0, length);
  }

  /// Verschlüsselte Nachricht (JSON-Text fürs Relay).
  String seal(Map<String, Object?> message) {
    final r = Random.secure();
    final nonce = [for (var i = 0; i < 16; i++) r.nextInt(256)];
    final plain = utf8.encode(jsonEncode(message));
    final ks = _stream(nonce, plain.length);
    final c = [for (var i = 0; i < plain.length; i++) plain[i] ^ ks[i]];
    final tag = Hmac(sha256, _key('mac')).convert([...nonce, ...c]).bytes;
    return jsonEncode({'v': 1, 'n': base64.encode(nonce), 'c': base64.encode(c), 't': base64.encode(tag)});
  }

  /// Entschlüsselt; null bei fremden, kaputten oder gefälschten Nachrichten.
  Map<String, Object?>? open(String body) {
    try {
      final j = jsonDecode(body) as Map;
      if (j['v'] != 1) return null;
      final nonce = base64.decode(j['n']), c = base64.decode(j['c']), tag = base64.decode(j['t']);
      final want = Hmac(sha256, _key('mac')).convert([...nonce, ...c]).bytes;
      var diff = tag.length ^ want.length;
      for (var i = 0; i < want.length && i < tag.length; i++) {
        diff |= tag[i] ^ want[i];
      }
      if (diff != 0) return null;
      final ks = _stream(nonce, c.length);
      return jsonDecode(utf8.decode([for (var i = 0; i < c.length; i++) c[i] ^ ks[i]])) as Map<String, Object?>;
    } catch (_) {
      return null;
    }
  }

  Future<void> send(Map<String, Object?> message) async {
    final r = await http.post(Uri.parse('$relay/$topic'), body: seal(message)).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw StateError('Relay: HTTP ${r.statusCode}');
  }

  /// Nachrichten ab jetzt, verbindet bei Abbrüchen neu. Abbestellen beendet die Verbindung.
  Stream<Map<String, Object?>> listen() {
    late StreamController<Map<String, Object?>> out;
    http.Client? client;
    var since = '${DateTime.now().millisecondsSinceEpoch ~/ 1000 - 5}';
    var stopped = false;

    Future<void> run() async {
      while (!stopped) {
        client = http.Client();
        try {
          final res = await client!.send(http.Request('GET', Uri.parse('$relay/$topic/json?since=$since')));
          await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
            if (line.isEmpty) continue;
            final e = jsonDecode(line) as Map;
            if (e['event'] != 'message') continue;
            since = '${e['id']}';
            final m = open('${e['message']}');
            if (m != null && !stopped) out.add(m);
          }
        } catch (_) {/* Netz weg: gleich neu verbinden */}
        client?.close();
        if (!stopped) await Future.delayed(const Duration(seconds: 3));
      }
    }

    out = StreamController(
      onListen: run,
      onCancel: () {
        stopped = true;
        client?.close();
      },
    );
    return out.stream;
  }
}

String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
