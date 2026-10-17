import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'i18n.dart';

/// Zugangsdaten am Handy eintippen statt mit der Fernbedienung: kleiner Webserver im Heimnetz,
/// nur solange das Fenster offen ist, mit Zufallscode im Link.
class RemoteSetup {
  final HttpServer _server;
  final String url;
  RemoteSetup._(this._server, this.url);

  /// Startet den Server. [onData] bekommt die Formularfelder (type, url, user, pass, mac).
  static Future<RemoteSetup> start(void Function(Map<String, String> data) onData) async {
    final ip = await lanAddress();
    if (ip == null) throw StateError(tr('Kein Heimnetz gefunden. WLAN oder LAN verbinden.'));
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 8642);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    final code = '${10000 + Random.secure().nextInt(90000)}';
    var wrong = 0;
    server.listen((req) async {
      final res = req.response..headers.contentType = ContentType.html;
      try {
        if (req.uri.path != '/$code') {
          // Code raten im Heimnetz verhindern (Browser fragen von selbst nach favicon.ico)
          if (req.uri.path != '/favicon.ico' && ++wrong > 10) server.close(force: true);
          res.statusCode = 404;
          return;
        }
        if (req.method == 'POST') {
          final data = Uri.splitQueryString(await utf8.decoder.bind(req).join());
          res.write(_page('<h2>✓ ${tr('Übertragen. Weiter am Fernseher.')}</h2>'));
          onData(data);
        } else {
          res.write(_page(_form));
        }
      } catch (_) {
        res.statusCode = 400;
      } finally {
        await res.close().catchError((_) {});
      }
    });
    return RemoteSetup._(server, 'http://${ip.address}:${server.port}/$code');
  }

  Future<void> stop() => _server.close(force: true);

  /// Private IPv4-Adresse im Heimnetz (WLAN/LAN), null ohne Netz.
  static Future<InternetAddress?> lanAddress() async {
    final all = [for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) ...i.addresses]
        .where((a) => !a.isLoopback)
        .toList();
    bool private(InternetAddress a) {
      final b = a.rawAddress;
      return b[0] == 10 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31);
    }

    return all.where(private).firstOrNull ?? all.firstOrNull;
  }

  static String get _form =>
      '''
<h2>CinemaMax</h2>
<form method="post">
<label>${tr('Art')}<select name="type">
<option value="xtream">Xtream Codes</option><option value="m3u">${tr('M3U-Link')}</option><option value="stalker">${tr('Stalker-Portal')}</option>
</select></label>
<label>${tr('Server-URL oder M3U-Link')}<input name="url" type="url" inputmode="url" autocapitalize="off" required></label>
<label>${tr('Benutzername')}<input name="user" autocapitalize="off" autocomplete="off"></label>
<label>${tr('Passwort')}<input name="pass" autocapitalize="off" autocomplete="off"></label>
<label>${tr('MAC-Adresse')}<input name="mac" placeholder="00:1A:79:XX:XX:XX" autocapitalize="characters"></label>
<button>${tr('An Fernseher senden')}</button>
</form>''';

  static String _page(String body) => '''
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CinemaMax</title><style>
body{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:0;padding:20px;max-width:480px}
label{display:block;margin:14px 0 0;font-size:14px;color:#aaa}
input,select,button{display:block;width:100%;box-sizing:border-box;margin-top:6px;padding:12px;font-size:16px;border-radius:10px;border:1px solid #333;background:#222;color:#fff}
button{margin-top:22px;background:#e50914;border:0;font-weight:700}
</style></head><body>$body</body></html>''';
}
