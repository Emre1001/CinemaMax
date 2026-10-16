import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'playback.dart';
import 'repo.dart';

/// Von außen geöffnete Links: Android „Öffnen mit“/„Teilen“, Startparameter am PC.
class Links {
  /// Noch nicht verarbeiteter Link; der Startbildschirm holt ihn nach der PIN-Abfrage ab.
  static final pending = ValueNotifier<String?>(null);
  static const _device = MethodChannel('cinemamax/device');

  static Future<void> init(List<String> args) async {
    final arg = args.where((a) => !a.startsWith('-')).firstOrNull;
    if (arg != null) pending.value = arg;
    if (!Platform.isAndroid) return;
    _device.setMethodCallHandler((c) async {
      if (c.method == 'link') pending.value = '${c.arguments}';
    });
    try {
      final l = await _device.invokeMethod<String>('initialLink');
      if (l != null) pending.value = l;
    } catch (_) {/* ältere App-Version ohne Kanal */}
  }

  /// Text einer content://-Adresse (Android), höchstens [max] Bytes.
  static Future<String> readContent(String uri, int max) async =>
      await _device.invokeMethod<String>('readText', {'uri': uri, 'max': max}) ?? '';
}

enum LinkKind { xtream, playlist, vod, live }

final _urlIn = RegExp(r'''(?:https?|rtmps?|rtsp|udp|rtp|mms|mmsh|srt|content|file)://[^\s"'<>]+''', caseSensitive: false);
final _winPath = RegExp(r'^[a-zA-Z]:[\\/]');
final _vodExt = RegExp(
    r'\.(mp4|mkv|avi|mov|wmv|flv|m4v|webm|mpg|mpeg|3gp|mp3|aac|flac|ogg|opus|m4a|wav)$',
    caseSensitive: false);

/// Lokaler Dateipfad (Linux/Android „/…“, Windows „C:\…“, „file://…“), sonst null.
String? localPath(String url) {
  if (url.startsWith('/') || _winPath.hasMatch(url)) return url;
  if (url.toLowerCase().startsWith('file://')) return Uri.parse(url).toFilePath();
  return null;
}

/// Link aus geteiltem Text herausziehen („Schau mal: http://…“). Dateipfade bleiben unverändert.
String? extractLink(String text) {
  final t = text.trim();
  if (localPath(t) != null && !t.toLowerCase().startsWith('file://')) return t;
  return _urlIn.firstMatch(t)?.group(0)?.replaceFirst(RegExp(r'[.,;)\]]+$'), '');
}

/// Lesbarer Titel: Dateiname ohne Endung, sonst Host.
String linkTitle(String link) {
  final u = Uri.tryParse(link.split('|').first);
  // pathSegments sind schon dekodiert; content://-Namen enthalten oft „primary:Download/…“
  final seg = (u?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? link).split(RegExp(r'[/:\\]')).last;
  final name = seg.replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '');
  if (name.isNotEmpty && int.tryParse(name) == null) return name;
  return (u?.host.isNotEmpty ?? false) ? u!.host : name.isEmpty ? link : name;
}

/// Typ aus Link und Anfang des Inhalts ([head] null = nicht lesbar).
LinkKind classifyLink(String link, String? head, {String? contentType}) {
  final bare = link.split('|').first;
  final u = Uri.tryParse(bare);
  final path = u?.path ?? bare;
  final local = localPath(bare) != null || bare.startsWith('content://');
  if (path.endsWith('get.php') && u?.queryParameters['username'] != null) return LinkKind.xtream;
  final text = head?.replaceFirst('\uFEFF', '').trimLeft();
  if (text != null && (text.startsWith('#EXTM3U') || text.contains('#EXTINF'))) {
    if (text.contains('#EXT-X-')) return text.contains('#EXT-X-ENDLIST') ? LinkKind.vod : LinkKind.live;
    return LinkKind.playlist;
  }
  if (_vodExt.hasMatch(path)) return LinkKind.vod;
  final type = contentType?.toLowerCase() ?? '';
  if (type.startsWith('video/') && !type.contains('mp2t')) return LinkKind.vod;
  // Unbekannte Dateien haben ein Ende, unbekannte Netz-Streams meist nicht
  return local ? LinkKind.vod : LinkKind.live;
}

/// Liest höchstens 64 KB, um Playlist, HLS-Film oder Live-Stream zu unterscheiden.
Future<LinkKind> probeLink(String link, {int depth = 0}) async {
  const max = 65536;
  final bare = link.split('|').first;
  final u = Uri.tryParse(bare);
  if (_vodExt.hasMatch(u?.path ?? bare)) return LinkKind.vod;
  try {
    final file = localPath(bare);
    if (file != null) {
      final bytes = await File(file).openRead(0, max).fold<List<int>>([], (a, b) => a..addAll(b));
      return classifyLink(link, utf8.decode(bytes, allowMalformed: true));
    }
    if (bare.startsWith('content://')) return classifyLink(link, await Links.readContent(bare, max));
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(bare)) return classifyLink(link, null);

    final (url, headers) = Engine.splitHeaders(link, Repo.headers);
    final client = http.Client();
    try {
      final r = await client.send(http.Request('GET', Uri.parse(url))..headers.addAll(headers))
          .timeout(const Duration(seconds: 15));
      final bytes = <int>[];
      await for (final chunk in r.stream.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length >= max) break;
      }
      final head = utf8.decode(bytes, allowMalformed: true);
      // HLS-Hauptliste: an der ersten Variante sehen, ob Film (ENDLIST) oder Live
      if (head.contains('#EXT-X-STREAM-INF') && depth == 0) {
        final lines = head.split('\n').map((l) => l.trim()).toList();
        final i = lines.indexWhere((l) => l.startsWith('#EXT-X-STREAM-INF'));
        final variant = lines.skip(i + 1).firstWhere((l) => l.isNotEmpty && !l.startsWith('#'), orElse: () => '');
        if (variant.isNotEmpty) {
          final kind = await probeLink(r.request!.url.resolve(variant).toString(), depth: 1);
          return kind == LinkKind.vod ? LinkKind.vod : LinkKind.live;
        }
      }
      return classifyLink(link, head, contentType: r.headers['content-type']);
    } finally {
      client.close();
    }
  } catch (_) {
    // Nicht lesbar: der Player zeigt den eigentlichen Fehler
    return classifyLink(link, null);
  }
}
