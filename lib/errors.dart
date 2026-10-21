import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'i18n.dart';

/// Fehler als verständlicher deutscher Satz (übersetzt), ohne Code oder Fachbegriffe.
/// [playback]: Fehler beim Abspielen eines Streams (andere Ursachen und Rückfalltext).
String explain(Object e, {bool playback = false}) {
  final s = '$e';
  final low = s.toLowerCase();
  bool has(List<String> words) => words.any(low.contains);

  if (e is TimeoutException || has(['timeout', 'timed out', 'zeitüberschreitung'])) {
    return tr('Der Server antwortet nicht. Später erneut versuchen oder die Adresse prüfen.');
  }
  if (e is TlsException || has(['handshake', 'certificate', 'wrong_version_number'])) {
    return tr('Die sichere Verbindung (https) ist fehlgeschlagen. Die Adresse mit http:// statt https:// versuchen.');
  }
  if (has(['failed host lookup', 'no address associated', 'unknownhost', 'unable to resolve', 'name or service not known'])) {
    return tr('Server nicht gefunden. Adresse prüfen und Internetverbindung testen.');
  }
  if (has(['connection refused', 'econnrefused'])) {
    return tr('Der Server lehnt die Verbindung ab. Adresse und Port prüfen, oder der Server ist gerade aus.');
  }
  if (has(['network is unreachable', 'network unreachable', 'no route to host', 'enetunreach'])) {
    return tr('Keine Internetverbindung.');
  }
  if (has(['connection reset', 'connection closed', 'broken pipe', 'verbindung abgebrochen', 'connection abort'])) {
    return tr('Die Verbindung wurde unterbrochen. Bitte erneut versuchen.');
  }
  final code = int.tryParse(RegExp(r'(?:HTTP|[Rr]esponse code:?)\s*(\d{3})').firstMatch(s)?.group(1) ?? '');
  if (code != null) {
    if (code == 401 || code == 403 || code == 458 || code == 512) {
      return tr('Zugang verweigert. Benutzername, Passwort oder MAC-Adresse prüfen, oder das Abo ist abgelaufen.');
    }
    if (code == 404 || code == 410) return tr('Nicht gefunden. Der Link ist falsch oder der Inhalt wurde entfernt.');
    if (code == 429) return tr('Zu viele Verbindungen. Andere Geräte schließen oder kurz warten.');
    if (code >= 500) return tr('Der Server hat gerade ein Problem. Später erneut versuchen.');
    return tr('Der Server hat die Anfrage abgelehnt.');
  }
  if (has(['portal-login'])) return tr('Anmeldung am Portal fehlgeschlagen. Portal-Adresse und MAC-Adresse prüfen.');
  if (has(['login fehlgeschlagen'])) return tr('Anmeldung fehlgeschlagen. Benutzername und Passwort prüfen.');
  if (has(['keinen stream-link'])) return tr('Für diesen Eintrag liefert das Portal keinen Stream.');
  if (playback) {
    // Die mpv-Bibliothek für Android enthält kein SRT und kein MMS
    if (Platform.isAndroid && has(['srt://', 'mms://', 'mmsh://', 'mmst://'])) {
      return tr('Dieses Streaming-Protokoll (SRT/MMS) kann der eingebaute Player auf Android nicht. Mit VLC öffnen.');
    }
    if (has(['decoder', 'mediacodec', 'exceeds_capabilities', 'unsupported', 'codec'])) {
      return tr('Dieses Gerät kann das Videoformat nicht abspielen (z. B. 4K/HEVC). Unter Einstellungen den Player „mpv“ versuchen.');
    }
    if (has(['unrecognizedinputformat', 'extractors', 'recognize', 'unrecognized file format', 'invalid data'])) {
      return tr('Unbekanntes Format. Das ist kein abspielbarer Stream.');
    }
    if (has(['behindlivewindow'])) return tr('Der Live-Stream ist zu weit zurück. Erneut versuchen.');
    return tr('Der Stream kann nicht abgespielt werden. Der Sender ist vielleicht offline oder überlastet.');
  }
  if (has(['keine playlist'])) {
    return tr('Das ist ein einzelner Video-Stream, keine Playlist. Über „Link öffnen“ direkt abspielen.');
  }
  if (e is FormatException) return tr('Der Server liefert keine gültigen Daten. Ist das wirklich ein IPTV-Zugang?');
  if (e is FileSystemException) {
    return tr('Datei konnte nicht gelesen oder gespeichert werden. Speicherplatz und Berechtigungen prüfen.');
  }
  // Eigene Meldungen (z. B. „HLS-Streams können nicht heruntergeladen werden“) sind schon verständlich
  if (e is StateError) return e.message;
  if (e is SocketException || e is http.ClientException || e is HttpException) {
    return tr('Keine Verbindung zum Server. Adresse und Internetverbindung prüfen.');
  }
  return tr('Unerwarteter Fehler. Bitte erneut versuchen.');
}

/// Für Meldungen von überall (auch ohne BuildContext), z. B. bei Abstürzen.
final messengerKey = GlobalKey<ScaffoldMessengerState>();
DateTime _lastReport = DateTime(0);

/// Unerwarteten Fehler melden statt abzustürzen: kurze Meldung, Details nur im Protokoll.
void reportError(Object e, [StackTrace? st]) {
  debugPrint('Fehler: $e\n${st ?? ''}');
  final now = DateTime.now();
  if (now.difference(_lastReport) < const Duration(seconds: 3)) return;
  _lastReport = now;
  // Nicht mitten im Bauen/Zeichnen anzeigen (Fehler kommen oft genau dort): sonst Folgefehler
  Timer.run(() => messengerKey.currentState?.showSnackBar(SnackBar(content: Text(tr('Fehler: {0}', [explain(e)])))));
}

/// Ersetzt den grauen/roten Fehlerbildschirm eines kaputten Bausteins.
Widget friendlyErrorWidget(FlutterErrorDetails d) => Material(
      color: Colors.transparent,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded, color: Colors.white54, size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text(tr('Dieser Bereich konnte nicht angezeigt werden.'),
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ),
          ]),
        ),
      ),
    );
