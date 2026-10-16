import 'models.dart';

final _vlcOpt = RegExp(r'^#EXTVLCOPT:\s*(http-user-agent|http-referrer|http-referer)\s*=\s*(.+)$', caseSensitive: false);
final _jsonPair = RegExp(r'"([\w-]+)"\s*:\s*"([^"]*)"');
final _attr = RegExp(r'([\w-]+)="([^"]*)"');
final _episode = RegExp(r'^(.*?)[\s._\-|]*S(\d{1,2})[\s._]*E(\d{1,4})', caseSensitive: false);
final _vodExt = RegExp(r'\.(mp4|mkv|avi|mov|wmv|flv|m4v|webm|mpg|mpeg)(\?|$)', caseSensitive: false);
final _moviePath = RegExp(r'/(movie|movies|vod|film|films)/', caseSensitive: false);
final _seriesPath = RegExp(r'/(series|serie|shows)/', caseSensitive: false);
// Viele Listen trennen Filme/Serien nur über den Kategorienamen
final _movieGroup = RegExp(r'\b(vod|movies?|filme?|films|cinema|kino|4k uhd movies)\b', caseSensitive: false);
final _seriesGroup = RegExp(r'\b(series|serien?|tv ?shows?|dizi(ler)?|staffel)\b', caseSensitive: false);

final _tvgUrl = RegExp(r'(?:url-tvg|x-tvg-url|tvg-url)="([^"]+)"', caseSensitive: false);

/// EPG-Adresse aus dem #EXTM3U-Kopf (erste nur, falls mehrere per Komma).
String? m3uEpgUrl(String text) {
  final head = text.length > 2000 ? text.substring(0, 2000) : text;
  final line = head.split('\n').firstWhere((l) => l.startsWith('#EXTM3U'), orElse: () => '');
  final m = _tvgUrl.firstMatch(line);
  return m?.group(1)?.split(',').first.trim();
}

/// Typ eines Eintrags: Pfad > tvg-type > Episodenmuster > Dateiendung > Kategoriename.
Kind classify(String url, String name, String group, String? tvgType) {
  final bare = url.split('|').first;
  final path = Uri.tryParse(bare)?.path ?? bare;
  if (_seriesPath.hasMatch(path)) return Kind.series;
  if (_moviePath.hasMatch(path)) return Kind.movie;
  switch (tvgType?.toLowerCase()) {
    case 'movie' || 'movies' || 'vod': return Kind.movie;
    case 'series' || 'serie' || 'show': return Kind.series;
    case 'live' || 'stream': return Kind.live;
  }
  final vodFile = _vodExt.hasMatch(path);
  if (_episode.hasMatch(name) && (vodFile || _seriesGroup.hasMatch(group))) return Kind.series;
  // .ts/.m3u8 sind fast immer Live-Sender, auch in Kategorien wie "DE | KINO"
  final liveFile = path.endsWith('.ts') || path.endsWith('.m3u8');
  if (_seriesGroup.hasMatch(group) && !liveFile) return Kind.series;
  if (vodFile || (_movieGroup.hasMatch(group) && !liveFile)) return Kind.movie;
  return Kind.live;
}

/// Parst eine M3U/M3U8-Playlist. Läuft per compute() im Isolate.
/// [liveOnly]: alles als Live-Sender behandeln (öffentliche IPTV-Listen).
Map<Kind, List<MediaItem>> parseM3u(String text, {bool liveOnly = false}) {
  final live = <MediaItem>[];
  final movies = <MediaItem>[];
  final series = <String, ({String group, String? logo, List<Episode> eps})>{};

  Map<String, String> attrs = {};
  String? title;
  String? extGroup;
  final headers = <String, String>{}; // aus #EXTVLCOPT / #EXTHTTP, gilt für den nächsten Link

  for (var line in text.split('\n')) {
    line = line.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF')) {
      attrs = {for (final m in _attr.allMatches(line)) m.group(1)!.toLowerCase(): m.group(2)!};
      // Titel = alles nach dem letzten Komma außerhalb von Anführungszeichen
      final q = line.lastIndexOf('"');
      final c = line.indexOf(',', q < 0 ? 0 : q);
      title = c < 0 ? attrs['tvg-name'] : line.substring(c + 1).trim();
      continue;
    }
    if (line.startsWith('#EXTGRP:')) {
      extGroup = line.substring(8).trim();
      continue;
    }
    final vlc = _vlcOpt.firstMatch(line);
    if (vlc != null) {
      headers[vlc.group(1)!.toLowerCase() == 'http-user-agent' ? 'User-Agent' : 'Referer'] = vlc.group(2)!.trim();
      continue;
    }
    if (line.startsWith('#EXTHTTP:')) {
      for (final m in _jsonPair.allMatches(line)) {
        headers[m.group(1)!] = m.group(2)!;
      }
      continue;
    }
    if (line.startsWith('#')) continue;

    // Header in Kodi-Schreibweise an den Link hängen ("url|User-Agent=..."); der Player trennt sie wieder ab
    final url = headers.isEmpty || line.contains('|')
        ? line
        : '$line|${headers.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}';
    headers.clear();
    final name = (title == null || title.isEmpty) ? (attrs['tvg-name'] ?? url) : title;
    final group = attrs['group-title']?.isNotEmpty == true
        ? attrs['group-title']!
        : (extGroup ?? 'Ohne Kategorie');
    final logo = attrs['tvg-logo']?.isNotEmpty == true ? attrs['tvg-logo'] : null;

    final kind = liveOnly ? Kind.live : classify(url, name, group, attrs['tvg-type'] ?? attrs['type']);
    final isSeries = kind == Kind.series;
    final isMovie = kind == Kind.movie;

    if (isSeries) {
      final m = _episode.firstMatch(name);
      final show = (m?.group(1)?.trim().isNotEmpty == true) ? m!.group(1)!.trim() : name;
      final entry = series.putIfAbsent('$group|$show', () => (group: group, logo: logo, eps: []));
      entry.eps.add(Episode(
        id: url,
        season: int.tryParse(m?.group(2) ?? '') ?? 1,
        number: int.tryParse(m?.group(3) ?? '') ?? entry.eps.length + 1,
        title: name,
        url: url,
        image: logo,
      ));
    } else {
      (isMovie ? movies : live).add(MediaItem(
        id: url,
        name: name,
        kind: isMovie ? Kind.movie : Kind.live,
        group: group,
        logo: logo,
        url: url,
        epgId: attrs['tvg-id'],
      ));
    }
    attrs = {};
    title = null;
    extGroup = null;
  }

  return {
    Kind.live: live,
    Kind.movie: movies,
    Kind.series: [
      for (final e in series.entries)
        MediaItem(
          id: 'm3u-series:${e.key}',
          name: e.key.substring(e.key.indexOf('|') + 1),
          kind: Kind.series,
          group: e.value.group,
          logo: e.value.logo,
          episodes: e.value.eps
            ..sort((a, b) => a.season != b.season ? a.season - b.season : a.number - b.number),
        ),
    ],
  };
}
