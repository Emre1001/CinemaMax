import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'playback.dart';
import 'repo.dart';

final epg = EpgStore();

class Prog {
  final DateTime start, stop;
  final String title;
  final String? desc;
  const Prog(this.start, this.stop, this.title, this.desc);

  bool get isNow {
    final n = DateTime.now();
    return !start.isAfter(n) && stop.isAfter(n);
  }

  bool get isPast => !stop.isAfter(DateTime.now());
  double get progress {
    final total = stop.difference(start).inSeconds;
    return total <= 0 ? 0 : (DateTime.now().difference(start).inSeconds / total).clamp(0, 1);
  }

  List toJson() => [start.millisecondsSinceEpoch, stop.millisecondsSinceEpoch, title, desc];
  factory Prog.fromJson(List j) => Prog(DateTime.fromMillisecondsSinceEpoch(j[0]),
      DateTime.fromMillisecondsSinceEpoch(j[1]), j[2] as String, j[3] as String?);
}

/// Programmführer je Quelle: XMLTV laden, auf die Sender der Playlist filtern, 12 h zwischenspeichern.
class EpgStore extends ChangeNotifier {
  final _data = <String, Map<String, List<Prog>>>{}; // Quelle -> Sender-ID (klein) -> Sendungen
  final _loading = <String, Future<void>>{};
  final errors = <String, String>{};

  bool has(Source s) => _data[s.id]?.isNotEmpty == true;
  bool loading(Source s) => _loading.containsKey(s.id);

  List<Prog> of(Source s, String? id) => id == null ? const [] : _data[s.id]?[id.toLowerCase()] ?? const [];

  Prog? now(Source s, String? id) => of(s, id).where((p) => p.isNow).firstOrNull;

  Prog? next(Source s, String? id) {
    final n = DateTime.now();
    return of(s, id).where((p) => p.start.isAfter(n)).firstOrNull;
  }

  Future<void> ensure(Source s, Library lib, {bool force = false}) {
    if (lib.epgUrl == null) return Future.value();
    if (!force && _data.containsKey(s.id)) return Future.value();
    return _loading[s.id] ??= _load(s, lib, force).whenComplete(() {
      _loading.remove(s.id);
      notifyListeners();
    });
  }

  Future<void> _load(Source s, Library lib, bool force) async {
    final dir = await getApplicationSupportDirectory();
    final cache = File('${dir.path}/epg_${s.id}.json');
    if (!force && await cache.exists() && DateTime.now().difference(await cache.lastModified()).inHours < 12) {
      try {
        _data[s.id] = await compute(_decode, await cache.readAsString());
        return;
      } catch (_) {/* neu laden */}
    }
    // Rückschau-Sender behalten mehr Vergangenheit (für Catch-up)
    final keep = <String, int>{
      for (final m in lib.of(Kind.live))
        if (m.epgId != null) m.epgId!.toLowerCase(): m.archive > 0 ? m.archive * 24 : 3,
    };
    if (keep.isEmpty) return;
    final tmp = File('${dir.path}/epg_${s.id}.download');
    try {
      final client = http.Client();
      try {
        // Kodi-Header am EPG-Link erlaubt; Server, die nie antworten, blockieren sonst den Programmführer
        final (url, headers) = Engine.splitHeaders(lib.epgUrl!, Repo.headers);
        final res = await client.send(http.Request('GET', Uri.parse(url))..headers.addAll(headers))
            .timeout(const Duration(seconds: 60));
        if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
        await res.stream.pipe(tmp.openWrite()); // auf Platte streamen statt ins RAM
      } finally {
        client.close();
      }
      final parsed = await compute(_parseFile, (tmp.path, keep));
      _data[s.id] = parsed;
      await cache.writeAsString(await compute(_encode, parsed));
      errors.remove(s.id);
    } catch (e) {
      errors[s.id] = '$e';
      _data[s.id] = {};
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }
}

String _encode(Map<String, List<Prog>> d) => jsonEncode({for (final e in d.entries) e.key: e.value});

Map<String, List<Prog>> _decode(String s) => {
      for (final e in (jsonDecode(s) as Map).entries) e.key as String: [for (final p in e.value) Prog.fromJson(p)],
    };

final _progRe = RegExp(r'<programme\b([^>]*)>([\s\S]*?)</programme>');
final _attrRe = RegExp(r'''(\w+)=(?:"([^"]*)"|'([^']*)')''');
final _titleRe = RegExp(r'<title[^>]*>([\s\S]*?)</title>');
final _descRe = RegExp(r'<desc[^>]*>([\s\S]*?)</desc>');

/// "20261016203000 +0200" -> DateTime (lokal).
DateTime? xmltvTime(String s) {
  final m = RegExp(r'^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)?\s*([+-]\d{4})?').firstMatch(s.trim());
  if (m == null) return null;
  var t = DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!),
      int.parse(m[6] ?? '0'));
  final off = m[7];
  if (off != null) {
    final mins = int.parse(off.substring(1, 3)) * 60 + int.parse(off.substring(3));
    t = t.subtract(Duration(minutes: off.startsWith('-') ? -mins : mins));
  }
  return t.toLocal();
}

String _unescape(String s) => s
    .replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '')
    // Zeichen als Zahl: &#228; &#xE4;
    .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
      final c = int.tryParse(m[2]!, radix: m[1]!.isEmpty ? 10 : 16);
      return c == null || c > 0x10FFFF ? m[0]! : String.fromCharCode(c);
    })
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .trim();

/// Liest XMLTV (auch .gz) blockweise. [keep]: Sender-ID -> wie viele Stunden Vergangenheit behalten.
Future<Map<String, List<Prog>>> _parseFile((String, Map<String, int>) a) async {
  final (path, keep) = a;
  final f = File(path);
  final head = await f.openRead(0, 2).first;
  Stream<List<int>> bytes = f.openRead();
  if (head.length == 2 && head[0] == 0x1f && head[1] == 0x8b) bytes = bytes.transform(gzip.decoder);
  final out = <String, List<Prog>>{};
  final now = DateTime.now();
  final maxFuture = now.add(const Duration(hours: 36));
  var buf = StringBuffer();
  await for (final chunk in bytes.transform(const Utf8Decoder(allowMalformed: true))) {
    buf.write(chunk);
    var s = buf.toString();
    final end = s.lastIndexOf('</programme>');
    if (end < 0) {
      if (s.length > 4 << 20) buf = StringBuffer(s.substring(s.length - 65536)); // kein Programm: Rest verwerfen
      continue;
    }
    parseProgrammes(s.substring(0, end + 12), keep, now, maxFuture, out);
    buf = StringBuffer(s.substring(end + 12));
  }
  for (final l in out.values) {
    l.sort((a, b) => a.start.compareTo(b.start));
  }
  return out;
}

@visibleForTesting
void parseProgrammes(String s, Map<String, int> keep, DateTime now, DateTime maxFuture, Map<String, List<Prog>> out) {
  for (final m in _progRe.allMatches(s)) {
    final attrs = {for (final a in _attrRe.allMatches(m[1]!)) a[1]!: a[2] ?? a[3]!};
    final ch = attrs['channel']?.toLowerCase();
    final hours = ch == null ? null : keep[ch];
    if (hours == null) continue;
    final start = xmltvTime(attrs['start'] ?? ''), stop = xmltvTime(attrs['stop'] ?? '');
    if (start == null || stop == null) continue;
    if (stop.isBefore(now.subtract(Duration(hours: hours))) || start.isAfter(maxFuture)) continue;
    final title = _titleRe.firstMatch(m[2]!)?[1];
    if (title == null) continue;
    final desc = _descRe.firstMatch(m[2]!)?[1];
    (out[ch!] ??= []).add(Prog(start, stop, _unescape(title), desc == null ? null : _unescape(desc)));
  }
}
