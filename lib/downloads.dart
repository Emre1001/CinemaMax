import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n.dart';
import 'models.dart';
import 'playback.dart';
import 'repo.dart';
import 'store.dart';

final downloads = Downloads();

enum DlStatus { queued, running, paused, done, failed }

class Download {
  final String url; // Original-URL (Schlüssel, auch für Fortschritt/Verlauf)
  final String srcId;
  final MediaItem item;
  final String title;
  final String file;
  final int until; // Aufnahme: Ende als Unix-ms, 0 = normaler Download
  DlStatus status;
  int received, total;
  String? error;

  Download({
    required this.url,
    required this.srcId,
    required this.item,
    required this.title,
    required this.file,
    this.status = DlStatus.queued,
    this.received = 0,
    this.total = 0,
    this.error,
    this.until = 0,
  });

  bool get isRecording => until > 0;

  double get progress => total == 0 ? 0 : (received / total).clamp(0, 1);

  Map<String, dynamic> toJson() => {
        'url': url,
        'src': srcId,
        'item': item.toJson(),
        'title': title,
        'file': file,
        'status': status.index,
        'rec': received,
        'total': total,
        'err': error,
        'until': until,
      };

  factory Download.fromJson(Map<String, dynamic> j) => Download(
        url: j['url'],
        srcId: j['src'],
        item: MediaItem.fromJson(j['item']),
        title: j['title'],
        file: j['file'],
        status: DlStatus.values[j['status']],
        received: j['rec'] ?? 0,
        total: j['total'] ?? 0,
        error: j['err'],
        until: j['until'] ?? 0,
      );
}

/// Lädt Filme und Episoden als Datei herunter (eine nach der anderen, fortsetzbar per HTTP-Range).
class Downloads extends ChangeNotifier {
  final Map<String, Download> items = {};
  late SharedPreferences _p;
  late Directory _dir;
  final _clients = <String, http.Client>{};
  Download? _active;
  DateTime _lastNotify = DateTime(0);

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    _dir = Directory('${(await getApplicationDocumentsDirectory()).path}/CinemaMax Downloads');
    final raw = _p.getString('downloads');
    if (raw != null) {
      for (final j in jsonDecode(raw) as List) {
        final d = Download.fromJson(j);
        // App wurde beendet: Downloads fortsetzen, Aufnahmen mit Daten gelten als fertig
        if (d.status == DlStatus.running) d.status = d.isRecording ? (d.received > 0 ? DlStatus.done : DlStatus.failed) : DlStatus.queued;
        if (d.status == DlStatus.done && !File(d.file).existsSync()) continue; // Datei gelöscht
        items[d.url] = d;
      }
    }
    _next();
  }

  List<Download> get list => items.values.toList().reversed.toList();

  /// Pfad der fertigen Datei, falls offline verfügbar.
  String? localFile(String url) {
    final d = items[url];
    return d != null && d.status == DlStatus.done ? d.file : null;
  }

  Download? of(String url) => items[url];

  int get usedBytes => items.values.where((d) => d.status == DlStatus.done).fold(0, (a, d) => a + d.received);

  void _save({bool force = true}) {
    // Fortschritt höchstens 2x pro Sekunde speichern und melden, sonst ruckelt die Oberfläche
    final now = DateTime.now();
    if (force || now.difference(_lastNotify).inMilliseconds > 500) {
      _lastNotify = now;
      _p.setString('downloads', jsonEncode(items.values.toList()));
      notifyListeners();
    }
  }

  /// Fügt einen Film/eine Episode zur Warteschlange hinzu. Wirft bei Live/HLS (nicht als Datei ladbar).
  void add(Source s, MediaItem item, String url, String title) {
    if (item.kind == Kind.live) throw StateError(tr('Live-Sender können nicht heruntergeladen werden'));
    if (url.toLowerCase().contains('.m3u8')) throw StateError(tr('HLS-Streams können nicht heruntergeladen werden'));
    if (items.containsKey(url)) return;
    final ext = RegExp(r'\.(mp4|mkv|avi|mov|m4v|webm|ts|wmv|flv)(\?|$)', caseSensitive: false).firstMatch(url)?.group(1) ?? 'mp4';
    final safe = title.replaceAll(RegExp(r'[^\p{L}\p{N} ._()-]+', unicode: true), '_').trim();
    final name = '${safe.isEmpty ? 'video' : safe.substring(0, safe.length.clamp(0, 80))}_${url.hashCode.toUnsigned(32)}.$ext';
    items[url] = Download(url: url, srcId: s.id, item: item, title: title, file: '${_dir.path}/$name');
    _save();
    _next();
  }

  void pause(String url) {
    final d = items[url];
    if (d == null) return;
    if (d.isRecording) return stopRecording(url);
    if (_active == d) _abortActive();
    if (d.status != DlStatus.done) d.status = DlStatus.paused;
    _save();
    _next();
  }

  void resume(String url) {
    final d = items[url];
    if (d == null || d.status == DlStatus.done) return;
    d.status = DlStatus.queued;
    d.error = null;
    _save();
    _next();
  }

  Future<void> remove(String url) async {
    final d = items.remove(url);
    if (d == null) return;
    if (_active == d) _abortActive();
    _clients.remove(url)?.close();
    final f = File(d.file);
    if (await f.exists()) await f.delete();
    _save();
    _next();
  }

  Future<void> removeAll() async {
    for (final u in items.keys.toList()) {
      await remove(u);
    }
  }

  void _abortActive() {
    final a = _active;
    if (a != null) _clients.remove(a.url)?.close();
    _active = null;
  }

  /// Live-Sender für [minutes] Minuten aufnehmen. Läuft sofort, neben normalen Downloads.
  void record(Source s, MediaItem ch, String url, int minutes) {
    if (url.split('|').first.toLowerCase().contains('.m3u8')) {
      throw StateError(tr('HLS-Sender können nicht aufgenommen werden'));
    }
    final start = DateTime.now();
    String two(int v) => '$v'.padLeft(2, '0');
    final title = '${ch.name} ${two(start.day)}.${two(start.month)}. ${two(start.hour)}:${two(start.minute)}';
    final key = '$url#rec${start.millisecondsSinceEpoch}';
    final item = MediaItem(id: key, name: title, kind: Kind.movie, group: tr('Aufnahmen'), logo: ch.logo);
    final d = items[key] = Download(
      url: key,
      srcId: s.id,
      item: item,
      title: title,
      file: '${_dir.path}/rec_${start.millisecondsSinceEpoch}.ts',
      status: DlStatus.running,
      until: start.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
    );
    _save();
    _run(d).then((_) => d.status = DlStatus.done, onError: (Object e) {
      if (d.status == DlStatus.running) {
        // Abbruch nach Aufnahmeende ist normal
        d.status = d.received > 0 ? DlStatus.done : DlStatus.failed;
        d.error = d.received > 0 ? null : '$e';
      }
    }).whenComplete(_save);
  }

  void stopRecording(String url) {
    _clients.remove(url)?.close();
  }

  Future<void> _next() async {
    if (_active != null) return;
    final d = items.values.where((d) => d.status == DlStatus.queued).firstOrNull;
    if (d == null) return;
    _active = d;
    d.status = DlStatus.running;
    _save();
    try {
      await _run(d);
      if (_active == d) d.status = DlStatus.done;
    } catch (e) {
      // Pausiert/gelöscht: kein Fehler anzeigen
      if (_active == d) {
        d.status = DlStatus.failed;
        d.error = '$e';
      }
    }
    if (_active == d) _active = null;
    _save();
    _next();
  }

  Future<void> _run(Download d) async {
    await _dir.create(recursive: true);
    final source = store.sources.where((s) => s.id == d.srcId).firstOrNull;
    // Aufnahme-Schlüssel "url#rec…" und Kodi-Header "url|User-Agent=…" abtrennen
    final (raw, headers) = Engine.splitHeaders(
        d.url.replaceFirst(RegExp(r'#rec\d+$'), ''), source == null ? Repo.headers : Repo.streamHeaders(source));
    var url = raw;
    if (url.startsWith('stalker:')) {
      if (source == null) throw StateError(tr('Server nicht mehr vorhanden'));
      url = await Repo.stalkerResolve(source, url);
    }
    final f = File(d.file);
    var have = await f.exists() ? await f.length() : 0;
    final client = _clients[d.url] = http.Client();
    final req = http.Request('GET', Uri.parse(url))..headers.addAll(headers);
    if (have > 0 && !d.isRecording) req.headers['Range'] = 'bytes=$have-';
    final res = await client.send(req).timeout(const Duration(seconds: 30));
    // Datei ist schon vollständig (App wurde nach dem Laden beendet)
    if (res.statusCode == 416 && have > 0) {
      client.close();
      _clients.remove(d.url);
      d.received = d.total = have;
      return;
    }
    if (res.statusCode == 200 && !d.isRecording) {
      have = 0; // Server unterstützt kein Fortsetzen: neu beginnen
    } else if (res.statusCode != 206) {
      throw HttpException('HTTP ${res.statusCode}');
    }
    d.total = d.isRecording ? 0 : have + (res.contentLength ?? 0);
    d.received = have;
    final sink = f.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        d.received += chunk.length;
        _save(force: false);
        if (d.isRecording && DateTime.now().millisecondsSinceEpoch >= d.until) break;
      }
    } finally {
      await sink.close();
      client.close();
      _clients.remove(d.url);
    }
    if (d.total > 0 && d.received < d.total) throw HttpException(tr('Verbindung abgebrochen'));
    if (d.total == 0) d.total = d.received;
  }
}

String fmtBytes(int b) {
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(0)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}
