import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'i18n.dart';
import 'errors.dart';
import 'external_player.dart';
import 'store.dart';
import 'ui/common.dart';

/// Installierte Version. Muss zu `version:` in pubspec.yaml passen (test/update_test.dart prüft das).
const appVersion = '1.7.1';
const _repo = 'Emre1001/CinemaMax';

/// Beim Start: geladene Update-APKs löschen. Nach der Installation braucht sie niemand mehr,
/// sonst belegen sie mit jedem Update mehr Speicher.
Future<void> deleteUpdateFiles() async {
  if (!Platform.isAndroid) return;
  try {
    await Directory('${(await getTemporaryDirectory()).path}/updates').delete(recursive: true);
  } catch (_) {
    /* nichts da */
  }
}

typedef Release = ({String version, String page, String? asset});

List<int> _parts(String v) => [for (final m in RegExp(r'\d+').allMatches(v)) int.parse(m[0]!)];

/// Ist [a] neuer als [b]? ("1.10.0" > "1.9.2")
bool isNewer(String a, String b) {
  final x = _parts(a), y = _parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d > 0;
  }
  return false;
}

/// Passende Datei aus dem Release: APK, Windows-Setup oder AppImage. null = nur Release-Seite öffnen (deb/rpm).
String? pickAsset(List<String> urls, {required bool android, required bool windows, required bool appImage}) {
  bool ours(String u) => u.startsWith('https://github.com/$_repo/releases/download/');
  final ext = android ? '.apk' : windows ? '-setup.exe' : appImage ? '.AppImage' : null;
  if (ext == null) return null;
  return urls.where((u) => ours(u) && u.endsWith(ext)).firstOrNull;
}

/// Neueste Version auf GitHub, null = keine neuere.
Future<Release?> fetchUpdate() async {
  final r = await http
      .get(Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
          headers: {'Accept': 'application/vnd.github+json'})
      .timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
  final j = jsonDecode(r.body) as Map;
  final v = '${j['tag_name']}'.replaceFirst(RegExp(r'^v'), '');
  if (!isNewer(v, appVersion)) return null;
  final urls = [for (final a in j['assets'] as List? ?? const []) '${a['browser_download_url']}'];
  return (
    version: v,
    page: '${j['html_url'] ?? 'https://github.com/$_repo/releases/latest'}',
    asset: pickAsset(urls,
        android: Platform.isAndroid,
        windows: Platform.isWindows,
        appImage: Platform.isLinux && Platform.environment['APPIMAGE'] != null),
  );
}

/// Bei jedem Start oder von Hand: fragt, ob aktualisiert werden soll.
Future<void> checkForUpdate(BuildContext c, {bool manual = false}) async {
  if (!manual) {
    // Bei jedem Start prüfen: eine Anfrage, GitHub erlaubt 60 pro Stunde
    if (!store.get('updateCheck', true)) return;
  } else {
    toast(c, tr('Suche nach Updates …'));
  }
  Release? rel;
  try {
    rel = await fetchUpdate();
  } catch (e) {
    if (manual && c.mounted) toast(c, tr('Update-Prüfung fehlgeschlagen: {0}', [explain(e)]));
    return;
  }
  if (!c.mounted) return;
  if (rel == null) {
    if (manual) toast(c, tr('CinemaMax ist aktuell ({0})', [appVersion]));
    return;
  }
  if (!manual && store.get('skipVersion', '') == rel.version) return;
  final a = await showDialog<String>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(tr('Update verfügbar')),
      content: Text(tr('Version {0} ist da (installiert: {1}).\nJetzt aktualisieren?', [rel!.version, appVersion])),
      actions: [
        if (!manual) TextButton(onPressed: () => Navigator.pop(d, 'skip'), child: Text(tr('Version überspringen'))),
        TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Später'))),
        FilledButton(autofocus: true, onPressed: () => Navigator.pop(d, 'yes'), child: Text(tr('Update installieren'))),
      ],
    ),
  );
  if (a == 'skip') store.set('skipVersion', rel.version);
  if (a == 'yes' && c.mounted) await _install(c, rel);
}

Future<void> _install(BuildContext c, Release rel) async {
  final asset = rel.asset;
  if (asset == null) {
    // deb/rpm brauchen Root: Release-Seite im Browser öffnen
    try {
      await Process.start(Platform.isWindows ? 'explorer' : 'xdg-open', [rel.page],
          environment: ExternalPlayer.hostEnvironment());
    } catch (_) {
      if (c.mounted) toast(c, rel.page);
    }
    return;
  }
  final appImage = Platform.environment['APPIMAGE'];
  final File target;
  if (Platform.isAndroid) {
    target = File('${(await getTemporaryDirectory()).path}/updates/CinemaMax-${rel.version}.apk');
  } else if (Platform.isWindows) {
    target = File('${(await getTemporaryDirectory()).path}/CinemaMax-${rel.version}-setup.exe');
  } else {
    target = File('$appImage.new');
  }
  await target.parent.create(recursive: true);

  // Laden mit Fortschritt, abbrechbar
  final progress = ValueNotifier<double?>(null);
  final client = http.Client();
  var cancelled = false;
  if (!c.mounted) return;
  final dialog = showDialog<void>(
    context: c,
    barrierDismissible: false,
    builder: (d) => AlertDialog(
      title: Text(tr('Update wird geladen …')),
      content: SizedBox(
        width: 360,
        child: ValueListenableBuilder(
          valueListenable: progress,
          builder: (_, p, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: p),
            const SizedBox(height: 10),
            Text(p == null ? '' : '${(p * 100).round()} %'),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            client.close();
            Navigator.pop(d);
          },
          child: Text(tr('Abbrechen')),
        ),
      ],
    ),
  );
  try {
    final res = await client.send(http.Request('GET', Uri.parse(asset))).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final total = res.contentLength ?? 0;
    var got = 0;
    final sink = target.openWrite();
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) progress.value = got / total;
      }
    } finally {
      await sink.close();
    }
    if (total > 0 && got < total) throw HttpException(tr('Verbindung abgebrochen'));
  } catch (e) {
    if (await target.exists()) await target.delete();
    if (!cancelled && c.mounted) {
      Navigator.pop(c);
      toast(c, tr('Update fehlgeschlagen: {0}', [explain(e)]));
    }
    return;
  } finally {
    client.close();
  }
  if (cancelled || !c.mounted) return;
  Navigator.pop(c);
  await dialog;

  if (Platform.isAndroid) {
    // Android-Installer übernimmt; die Signatur muss zur installierten App passen
    try {
      await const MethodChannel('cinemamax/device').invokeMethod('installApk', target.path);
    } catch (e) {
      if (c.mounted) toast(c, tr('Update fehlgeschlagen: {0}', [explain(e)]));
    }
  } else if (Platform.isWindows) {
    await Process.start(target.path, const [], mode: ProcessStartMode.detached);
    exit(0); // Setup ersetzt die laufende App
  } else {
    await Process.run('chmod', ['755', target.path]);
    await target.rename(appImage!);
    await Process.start(appImage, const [], mode: ProcessStartMode.detached, environment: ExternalPlayer.hostEnvironment());
    exit(0);
  }
}
