import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n.dart';
import 'errors.dart';
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
  final int maxHeight; // HLS: höchste Auflösung (Speicher sparen), 0 = beste
  DlStatus status;
  int received, total;
  int seg = 0, segs = 0; // HLS: fertige/alle Segmente (Fortschritt und Fortsetzen)
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
    this.maxHeight = 0,
  });

  bool get isRecording => until > 0;

  double get progress => segs > 0 ? seg / segs : (total == 0 ? 0 : (received / total).clamp(0, 1));

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
        if (maxHeight > 0) 'maxH': maxHeight,
        if (segs > 0) ...{'seg': seg, 'segs': segs},
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
        maxHeight: j['maxH'] ?? 0,
      )
        ..seg = j['seg'] ?? 0
        ..segs = j['segs'] ?? 0;
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

  /// Fügt einen Film/eine Episode zur Warteschlange hinzu. HLS wird in [maxHeight] (0 = beste) geladen.
  void add(Source s, MediaItem item, String url, String title, {int maxHeight = 0}) {
    if (item.kind == Kind.live) throw StateError(tr('Live-Sender können nicht heruntergeladen werden'));
    if (items.containsKey(url)) return;
    final hls = isHls(url);
    final ext = hls
        ? 'ts'
        : RegExp(r'\.(mp4|mkv|avi|mov|m4v|webm|ts|wmv|flv)(\?|$)', caseSensitive: false).firstMatch(url)?.group(1) ?? 'mp4';
    final safe = title.replaceAll(RegExp(r'[^\p{L}\p{N} ._()-]+', unicode: true), '_').trim();
    final name = '${safe.isEmpty ? 'video' : safe.substring(0, safe.length.clamp(0, 80))}_${url.hashCode.toUnsigned(32)}.$ext';
    items[url] = Download(url: url, srcId: s.id, item: item, title: title, file: '${_dir.path}/$name', maxHeight: maxHeight);
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
        d.error = d.received > 0 ? null : explain(e);
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
        d.error = explain(e);
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
    if (!d.isRecording && isHls(url)) return _runHls(d, url, headers);
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

/// HLS-Link (Download mit wählbarer Auflösung möglich).
bool isHls(String url) => url.split('|').first.toLowerCase().contains('.m3u8');

/// Eine Qualitätsstufe einer HLS-Hauptliste.
typedef HlsVariant = ({Uri uri, int height, int bandwidth, bool separateAudio});

/// HLS-Playlist laden; Weiterleitungen selbst folgen, damit relative Segment-Links stimmen.
Future<(Uri, String)> _fetchPlaylist(http.Client client, Uri uri, Map<String, String> headers) async {
  for (var hop = 0; hop < 6; hop++) {
    final req = http.Request('GET', uri)
      ..headers.addAll(headers)
      ..followRedirects = false;
    final res = await client.send(req).timeout(const Duration(seconds: 30));
    final loc = res.headers['location'];
    if (res.isRedirect && loc != null) {
      await res.stream.drain();
      uri = uri.resolve(loc);
      continue;
    }
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: uri);
    return (uri, utf8.decode(await res.stream.toBytes(), allowMalformed: true));
  }
  throw HttpException(tr('Zu viele Weiterleitungen'), uri: uri);
}

final _attr = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
Map<String, String> _attrs(String line) => {
      for (final m in _attr.allMatches(line.substring(line.indexOf(':') + 1)))
        m.group(1)!: m.group(2)!.replaceAll('"', ''),
    };

/// Stufen einer HLS-Hauptliste, höchste zuerst. Leer = Medienliste (nur eine Qualität).
List<HlsVariant> parseVariants(Uri base, String text) {
  final lines = text.split('\n').map((l) => l.trim()).toList();
  final audioWithUri = {
    for (final l in lines)
      if (l.startsWith('#EXT-X-MEDIA:') && _attrs(l)['TYPE'] == 'AUDIO' && _attrs(l)['URI'] != null) _attrs(l)['GROUP-ID'],
  };
  final out = <HlsVariant>[];
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
    final a = _attrs(lines[i]);
    final uri = lines.skip(i + 1).firstWhere((l) => l.isNotEmpty && !l.startsWith('#'), orElse: () => '');
    if (uri.isEmpty) continue;
    final res = a['RESOLUTION']?.split('x');
    out.add((
      uri: base.resolve(uri),
      height: int.tryParse(res?.last ?? '') ?? 0,
      bandwidth: int.tryParse(a['BANDWIDTH'] ?? '') ?? 0,
      separateAudio: audioWithUri.contains(a['AUDIO']),
    ));
  }
  return out..sort((a, b) => b.bandwidth - a.bandwidth);
}

/// Höchste Stufe bis [maxHeight] (0 = beste), sonst die kleinste. Getrennter Ton nur, wenn nichts anderes da ist.
HlsVariant pickVariant(List<HlsVariant> v, int maxHeight) {
  final muxed = v.where((x) => !x.separateAudio).toList();
  final pool = muxed.isNotEmpty ? muxed : v;
  return pool.where((x) => maxHeight <= 0 || x.height == 0 || x.height <= maxHeight).firstOrNull ?? pool.last;
}

/// Qualitäten eines HLS-Films mit geschätzter Dateigröße (höchste zuerst). Leer = nur eine Qualität.
Future<List<({int height, int bytes})>> hlsQualities(Source s, String url) async {
  final (raw, headers) = Engine.splitHeaders(url, Repo.streamHeaders(s));
  final client = http.Client();
  try {
    final (base, text) = await _fetchPlaylist(client, Uri.parse(raw), headers);
    final variants = parseVariants(base, text).where((v) => v.height > 0 && !v.separateAudio).toList();
    if (variants.length < 2) return [];
    final (_, media) = await _fetchPlaylist(client, variants.first.uri, headers);
    final seconds = RegExp(r'#EXTINF:([\d.]+)').allMatches(media).fold(0.0, (a, m) => a + double.parse(m.group(1)!));
    final out = <({int height, int bytes})>[];
    for (final v in variants) {
      if (out.every((o) => o.height != v.height)) out.add((height: v.height, bytes: (v.bandwidth / 8 * seconds).round()));
    }
    return out;
  } finally {
    client.close();
  }
}

extension on Downloads {
  /// HLS-Film als eine Datei: Segmente nacheinander anhängen, fortsetzbar ab dem letzten Segment.
  Future<void> _runHls(Download d, String url, Map<String, String> headers) async {
    final client = _clients[d.url] = http.Client();
    try {
      var (base, text) = await _fetchPlaylist(client, Uri.parse(url), headers);
      final variants = parseVariants(base, text);
      if (variants.isNotEmpty) {
        final v = pickVariant(variants, d.maxHeight);
        if (v.separateAudio) throw StateError(tr('Dieser Stream hat den Ton getrennt vom Bild und kann nicht heruntergeladen werden.'));
        (base, text) = await _fetchPlaylist(client, v.uri, headers);
      }
      if (!text.contains('#EXT-X-ENDLIST')) throw StateError(tr('Live-Sender können nicht heruntergeladen werden'));
      if (RegExp(r'#EXT-X-KEY:.*METHOD=(AES-128|SAMPLE-AES)').hasMatch(text)) {
        throw StateError(tr('Verschlüsselte Streams können nicht heruntergeladen werden.'));
      }
      final lines = text.split('\n').map((l) => l.trim()).toList();
      final map = lines.where((l) => l.startsWith('#EXT-X-MAP:')).map((l) => _attrs(l)['URI']).nonNulls.firstOrNull;
      final segments = [for (final l in lines) if (l.isNotEmpty && !l.startsWith('#')) base.resolve(l)];
      final seconds = RegExp(r'#EXTINF:([\d.]+)').allMatches(text).fold(0.0, (a, m) => a + double.parse(m.group(1)!));
      final bandwidth = variants.isEmpty ? 0 : pickVariant(variants, d.maxHeight).bandwidth;
      d.segs = segments.length;
      if (d.total == 0 && bandwidth > 0) d.total = (bandwidth / 8 * seconds).round(); // Schätzung
      final f = File(d.file);
      if (d.seg == 0 || !await f.exists()) {
        d.seg = 0;
        d.received = 0;
        await f.writeAsBytes([]);
      } else {
        // Nach Abbruch: angefangenes Segment verwerfen (Stand und Bytes werden zusammen gespeichert)
        final raf = await f.open(mode: FileMode.append);
        await raf.truncate(d.received);
        await raf.close();
      }
      final sink = f.openWrite(mode: FileMode.append);
      try {
        Future<List<int>> get(Uri u) async {
          for (var attempt = 1;; attempt++) {
            try {
              final res = await client.send(http.Request('GET', u)..headers.addAll(headers)).timeout(const Duration(seconds: 30));
              if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: u);
              return await res.stream.toBytes();
            } catch (_) {
              if (attempt == 3 || !_clients.containsKey(d.url)) rethrow;
              await Future.delayed(Duration(seconds: attempt * 2));
            }
          }
        }

        if (d.seg == 0 && map != null) {
          final init = await get(base.resolve(map));
          sink.add(init);
          d.received += init.length;
        }
        for (; d.seg < segments.length; d.seg++) {
          final bytes = await get(segments[d.seg]);
          sink.add(bytes);
          await sink.flush(); // erst schreiben, dann zählen: Fortsetzen beginnt nie mitten im Segment
          d.received += bytes.length;
          _save(force: false);
        }
      } finally {
        await sink.close();
      }
      d.total = d.received;
    } finally {
      client.close();
      _clients.remove(d.url);
    }
  }
}

String fmtBytes(int b) {
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(0)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}
