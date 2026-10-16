import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'links.dart';
import 'm3u.dart';
import 'models.dart';
import 'store.dart';

/// Lädt Inhalte von M3U-, Xtream- und IPTV-Quellen, mit Disk-Cache für schnellen Start.
class Repo {
  static final _mem = <String, Library>{};

  static Map<String, String> get headers => {'User-Agent': store.userAgent};

  static Future<String> _get(String url) async {
    // Playlist als Datei (über „Öffnen mit“ übernommen oder lokal eingetragen)
    final file = localPath(url);
    if (file != null) return utf8.decode(await File(file).readAsBytes(), allowMalformed: true);
    final r = await http.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}', uri: Uri.parse(url));
    return utf8.decode(r.bodyBytes, allowMalformed: true);
  }

  static Future<File> _cacheFile(Source s) async =>
      File('${(await getApplicationSupportDirectory()).path}/cache_v2_${s.id}.json');

  /// Liefert Library aus Speicher, Disk-Cache (wenn jünger als Einstellung) oder Netz.
  static Future<Library> load(Source s, {bool force = false}) async {
    if (!force && _mem[s.id] != null) return _mem[s.id]!;
    // Stalker: Sitzung + Nachladen pro Kategorie, daher nur Speicher-Cache
    if (s.type == SourceType.stalker) {
      if (force) _stalkerToken.remove(s.id); // MAC/URL evtl. geändert: neu anmelden
      return _mem[s.id] = await _loadStalker(s);
    }
    final f = await _cacheFile(s);
    if (!force && await f.exists()) {
      try {
        final (items, epg) = await compute(_decode, await f.readAsString());
        final lib = _mem[s.id] = Library(items, epgUrl: epg);
        // Abgelaufen: sofort den Cache zeigen, im Hintergrund neu laden (nächstes Öffnen ist aktuell)
        if (DateTime.now().difference(await f.lastModified()) > Duration(hours: store.cacheHours)) {
          _fetch(s, f).catchError((_) => lib);
        }
        return lib;
      } catch (_) {/* kaputter Cache: neu laden */}
    }
    return _fetch(s, f);
  }

  static Future<Library> _fetch(Source s, File f) async {
    String? epg;
    final items = switch (s.type) {
      SourceType.m3u || SourceType.iptv => await () async {
          final text = await _get(s.url);
          epg = m3uEpgUrl(text);
          return compute(_parseM3u, (text, s.type == SourceType.iptv));
        }(),
      SourceType.xtream => await _loadXtream(s),
      SourceType.stalker => throw StateError('unreachable'),
    };
    if (s.type == SourceType.xtream) epg = _api(s).replaceFirst('player_api.php', 'xmltv.php');
    await f.writeAsString(await compute(_encode, (items, epg)));
    return _mem[s.id] = Library(items, epgUrl: epg);
  }

  static Future<void> clearCache() async {
    _mem.clear();
    final dir = await getApplicationSupportDirectory();
    for (final f in dir.listSync()) {
      if (f is File && f.path.contains('cache_')) await f.delete();
    }
  }

  /// HTTP-Header für den Stream selbst (Stalker-Portale erwarten MAG-Kennung).
  static Map<String, String> streamHeaders(Source s) =>
      s.type == SourceType.stalker ? {'User-Agent': _magUa, 'X-User-Agent': 'Model: MAG250; Link: WiFi'} : headers;

  /// Episoden einer Serie, je nach Quelle.
  static Future<List<Episode>> episodes(Source s, MediaItem m) async => switch (s.type) {
        _ when m.episodes != null => m.episodes!,
        SourceType.stalker => _stalkerEpisodes(s, m),
        _ => xtreamEpisodes(s, m.id),
      };

  // ---------------- Stalker-Portal (MAG / Ministra) ----------------

  static const _magUa =
      'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3';
  static final _stalkerToken = <String, String>{};
  static final _stalkerEndpoint = <String, String>{};

  static Map<String, String> _stalkerHeaders(Source s, [String? token]) => {
        'User-Agent': _magUa,
        'X-User-Agent': 'Model: MAG250; Link: WiFi',
        'Cookie': 'mac=${Uri.encodeComponent(s.mac)}; stb_lang=en; timezone=Europe/Berlin',
        'Referer': '${s.host}/',
        'Authorization': 'Bearer ${token ?? ''}',
      };

  /// Handshake: Token holen. Probiert die üblichen Portal-Pfade durch.
  static Future<String> _stalkerLogin(Source s) async {
    final base = s.host.replaceAll(RegExp(r'/c$'), '');
    final candidates = base.contains('/stalker_portal')
        ? ['${base.split('/stalker_portal').first}/stalker_portal/server/load.php']
        : ['$base/portal.php', '$base/server/load.php', '$base/stalker_portal/server/load.php'];
    for (final ep in candidates) {
      try {
        final r = await http
            .get(Uri.parse('$ep?type=stb&action=handshake&token=&JsHttpRequest=1-xml'), headers: _stalkerHeaders(s))
            .timeout(const Duration(seconds: 20));
        final t = (jsonDecode(r.body) as Map)['js']?['token'];
        if (t is! String || t.isEmpty) continue;
        _stalkerEndpoint[s.id] = ep;
        _stalkerToken[s.id] = t;
        // Viele Portale schalten die Sitzung erst nach get_profile frei
        await http
            .get(Uri.parse('$ep?type=stb&action=get_profile&hd=1&stb_type=MAG250&JsHttpRequest=1-xml'),
                headers: _stalkerHeaders(s, t))
            .timeout(const Duration(seconds: 20))
            .catchError((_) => http.Response('', 500));
        return t;
      } catch (_) {/* nächsten Pfad probieren */}
    }
    throw const FormatException('Portal-Login fehlgeschlagen (URL oder MAC prüfen)');
  }

  static Future<dynamic> _stalker(Source s, String query) async {
    var token = _stalkerToken[s.id] ?? await _stalkerLogin(s);
    Future<http.Response> go(String t) => http
        .get(Uri.parse('${_stalkerEndpoint[s.id]}?$query&JsHttpRequest=1-xml'), headers: _stalkerHeaders(s, t))
        .timeout(const Duration(seconds: 45));
    var r = await go(token);
    if (r.statusCode == 401 || r.body.contains('Authorization failed')) {
      token = await _stalkerLogin(s); // Token abgelaufen
      r = await go(token);
    }
    if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
    return (jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true)) as Map)['js'];
  }

  static String? _stalkerLogo(Source s, dynamic v) {
    final l = _str(v);
    if (l == null) return null;
    if (l.startsWith('http')) return l;
    return l.startsWith('/') ? '${Uri.parse(s.url).origin}$l' : null;
  }

  static Future<Library> _loadStalker(Source s) async {
    final genres = await _stalker(s, 'type=itv&action=get_genres');
    final genreName = {for (final g in genres is List ? genres : const []) '${g['id']}': '${g['title']}'};
    final ch = await _stalker(s, 'type=itv&action=get_all_channels');
    final live = [
      for (final e in (ch is Map ? ch['data'] : ch) as List? ?? const [])
        MediaItem(
          id: '${e['id']}',
          name: '${e['name']}',
          kind: Kind.live,
          group: genreName['${e['tv_genre_id']}'] ?? 'Ohne Kategorie',
          logo: _stalkerLogo(s, e['logo']),
          url: 'stalker:itv:${e['cmd']}',
        ),
    ];
    // Kategorien: Name -> ID (ohne Sammelkategorie "*")
    Future<Map<String, String>> cats(String type) async {
      try {
        final j = await _stalker(s, 'type=$type&action=get_categories');
        return {
          for (final c in j as List)
            if ('${c['id']}' != '*') '${c['title']}': '${c['id']}',
        };
      } catch (_) {
        return {};
      }
    }

    final ids = {Kind.movie: await cats('vod'), Kind.series: await cats('series')};
    final memo = <String, Future<List<MediaItem>>>{};
    return Library(
      {Kind.live: live},
      groups: {
        Kind.live: {for (final m in live) m.group}.toList(),
        Kind.movie: ids[Kind.movie]!.keys.toList(),
        Kind.series: ids[Kind.series]!.keys.toList(),
      },
      lazy: (kind, group) => memo['$kind|$group'] ??=
          _stalkerList(s, kind, group, ids[kind]![group] ?? '*').catchError((Object e) {
        memo.remove('$kind|$group');
        throw e;
      }),
      search: (kind, q) => _stalkerList(s, kind, 'Suche', '*', search: q, maxPages: 3),
    );
  }

  /// Film-/Serienliste einer Kategorie, seitenweise (max. 40 Seiten).
  static Future<List<MediaItem>> _stalkerList(Source s, Kind kind, String group, String catId,
      {String? search, int maxPages = 40}) async {
    final type = kind == Kind.movie ? 'vod' : 'series';
    final q = search == null ? '' : '&search=${Uri.encodeQueryComponent(search)}';
    Future<Map> page(int p) async {
      final j = await _stalker(s, 'type=$type&action=get_ordered_list&category=$catId&sortby=added$q&p=$p');
      return j is Map ? j : const {};
    }

    final first = await page(1);
    final total = int.tryParse('${first['total_items']}') ?? 0;
    final per = int.tryParse('${first['max_page_items']}') ?? 14;
    final pages = per == 0 ? 1 : ((total + per - 1) ~/ per).clamp(1, maxPages);
    final rest = <Map>[];
    for (var p = 2; p <= pages; p += 6) {
      rest.addAll(await Future.wait([for (var q = p; q < p + 6 && q <= pages; q++) page(q)]));
    }
    return [
      for (final pg in [first, ...rest])
        for (final e in pg['data'] as List? ?? const [])
          // Ältere Portale liefern Serien im VOD-Bereich (is_series=1)
          if ('${e['is_series']}' == '1' || kind == Kind.series)
            MediaItem(
              id: '$type:${e['id']}',
              name: '${e['name']}',
              kind: Kind.series,
              group: group,
              logo: _stalkerLogo(s, e['screenshot_uri']),
              rating: _str(e['rating_imdb']),
              year: _str(e['year']),
            )
          else
            MediaItem(
              id: '${e['id']}',
              name: '${e['name']}',
              kind: Kind.movie,
              group: group,
              logo: _stalkerLogo(s, e['screenshot_uri']),
              url: 'stalker:vod:${e['cmd']}',
              rating: _str(e['rating_imdb']),
              year: _str(e['year']),
            ),
    ];
  }

  static Future<List<Episode>> _stalkerEpisodes(Source s, MediaItem m) async {
    final i = m.id.indexOf(':');
    final type = m.id.substring(0, i), id = m.id.substring(i + 1);
    Future<List> list(String q) async {
      final j = await _stalker(s, 'type=$type&action=get_ordered_list&movie_id=$id&$q&p=1');
      return (j is Map ? j['data'] : null) as List? ?? const [];
    }

    final eps = <Episode>[];
    final seasons = await list('season_id=0&episode_id=0');
    for (final (si, se) in seasons.indexed) {
      final season = int.tryParse(RegExp(r'\d+').firstMatch('${se['name']}')?.group(0) ?? '') ?? si + 1;
      final nums = se['series'];
      if (nums is List && nums.isNotEmpty) {
        // Variante A: Staffel-cmd + Episodennummer
        for (final n in nums) {
          eps.add(Episode(
            id: '${se['id']}:$n',
            season: season,
            number: int.tryParse('$n') ?? 0,
            title: 'Folge $n',
            url: 'stalker:vod:${se['cmd']}#ep=$n',
            image: _stalkerLogo(s, se['screenshot_uri']),
          ));
        }
      } else {
        // Variante B: Episoden der Staffel einzeln abfragen
        for (final (ei, e) in (await list('season_id=${se['id']}&episode_id=0')).indexed) {
          eps.add(Episode(
            id: '${e['id']}',
            season: season,
            number: int.tryParse('${e['series_number'] ?? ''}') ?? ei + 1,
            title: '${e['name']}',
            url: 'stalker:vod:${e['cmd']}',
            image: _stalkerLogo(s, e['screenshot_uri']),
            plot: _str(e['description']),
          ));
        }
      }
    }
    return eps;
  }

  /// Macht aus `stalker:<itv|vod>:<cmd>[#ep=n]` per create_link einen abspielbaren Link.
  static Future<String> stalkerResolve(Source s, String url) async {
    final rest = url.substring('stalker:'.length);
    final type = rest.substring(0, rest.indexOf(':'));
    var cmd = rest.substring(type.length + 1);
    String? ep;
    final h = cmd.lastIndexOf('#ep=');
    if (h >= 0) {
      ep = cmd.substring(h + 4);
      cmd = cmd.substring(0, h);
    }
    final js = await _stalker(s,
        'type=$type&action=create_link&cmd=${Uri.encodeQueryComponent(cmd)}${ep == null ? '' : '&series=$ep'}&disable_ad=0&download=0');
    final link = '${js is Map ? js['cmd'] : ''}'.trim().replaceFirst(RegExp(r'^(ffmpeg|ffrt\d?|auto)\s+'), '');
    if (!RegExp(r'^(https?|rtmp|rtsp|udp)://').hasMatch(link)) {
      throw const FormatException('Portal liefert keinen Stream-Link');
    }
    return link;
  }

  // ---------------- Xtream Codes ----------------

  static String _api(Source s, [String action = '']) =>
      '${s.host}/player_api.php?username=${Uri.encodeQueryComponent(s.user)}'
      '&password=${Uri.encodeQueryComponent(s.pass)}${action.isEmpty ? '' : '&action=$action'}';

  /// Kontoinfo (Status, Ablaufdatum, Verbindungen). Wirft bei falschen Zugangsdaten.
  static Future<Map<String, dynamic>> xtreamAccount(Source s) async {
    final j = jsonDecode(await _get(_api(s)));
    if (j is! Map || j['user_info'] == null || j['user_info']['auth'] == 0) {
      throw const FormatException('Login fehlgeschlagen');
    }
    return Map<String, dynamic>.from(j['user_info']);
  }

  static Future<Map<Kind, List<MediaItem>>> _loadXtream(Source s) async {
    final r = await Future.wait([
      'get_live_categories', 'get_live_streams',
      'get_vod_categories', 'get_vod_streams',
      'get_series_categories', 'get_series',
    ].map((a) => _get(_api(s, a)).catchError((_) => '[]')));
    return compute(_buildXtream, (
      r,
      '${s.host}/live/${s.user}/${s.pass}/',
      '${s.host}/movie/${s.user}/${s.pass}/',
      store.liveFormat,
    ));
  }

  static Future<List<Episode>> xtreamEpisodes(Source s, String seriesId) async {
    final j = jsonDecode(await _get('${_api(s, 'get_series_info')}&series_id=$seriesId'));
    final eps = <Episode>[];
    final map = j['episodes'];
    final seasons = map is Map ? map.values : (map is List ? map : const []);
    for (final list in seasons) {
      for (final e in list as List) {
        final info = e['info'] is Map ? e['info'] : const {};
        eps.add(Episode(
          id: '${e['id']}',
          season: int.tryParse('${e['season']}') ?? 1,
          number: int.tryParse('${e['episode_num']}') ?? 0,
          title: '${e['title'] ?? ''}',
          url: '${s.host}/series/${s.user}/${s.pass}/${e['id']}.${e['container_extension'] ?? 'mp4'}',
          image: _str(info['movie_image']),
          plot: _str(info['plot']),
        ));
      }
    }
    eps.sort((a, b) => a.season != b.season ? a.season - b.season : a.number - b.number);
    return eps;
  }

  /// Film- oder Serien-Details (Handlung, Genre, Besetzung, Backdrop).
  static Future<Map<String, dynamic>> xtreamInfo(Source s, MediaItem m) async {
    final q = m.kind == Kind.movie ? 'get_vod_info&vod_id=${m.id}' : 'get_series_info&series_id=${m.id}';
    final j = jsonDecode(await _get(_api(s, q)));
    return j is Map && j['info'] is Map ? Map<String, dynamic>.from(j['info']) : {};
  }

  /// Catch-up (Xtream timeshift): vergangene Sendung eines Rückschau-Senders.
  static String catchupUrl(Source s, MediaItem ch, DateTime start, DateTime stop) {
    String two(int v) => '$v'.padLeft(2, '0');
    final t = '${start.year}-${two(start.month)}-${two(start.day)}:${two(start.hour)}-${two(start.minute)}';
    final minutes = stop.difference(start).inMinutes.clamp(1, 24 * 60);
    return '${s.host}/timeshift/${s.user}/${s.pass}/$minutes/$t/${ch.id}.ts';
  }

  /// Aktuelle + nächste Sendung (EPG) für einen Live-Sender.
  static Future<List<({String title, DateTime start, DateTime end})>> xtreamEpg(
      Source s, String streamId) async {
    final j = jsonDecode(await _get('${_api(s, 'get_short_epg')}&stream_id=$streamId&limit=3'));
    String b64(dynamic v) {
      try {
        return utf8.decode(base64.decode('$v'));
      } catch (_) {
        return '$v';
      }
    }

    DateTime ts(v) => DateTime.fromMillisecondsSinceEpoch((int.tryParse('$v') ?? 0) * 1000);
    return [
      for (final e in (j['epg_listings'] as List? ?? const []))
        (title: b64(e['title']), start: ts(e['start_timestamp']), end: ts(e['stop_timestamp'])),
    ];
  }
}

String? _str(dynamic v) => v == null || '$v'.isEmpty ? null : '$v';

Map<Kind, List<MediaItem>> _parseM3u((String, bool) a) => parseM3u(a.$1, liveOnly: a.$2);

String _encode((Map<Kind, List<MediaItem>>, String?) a) =>
    jsonEncode({for (final e in a.$1.entries) '${e.key.index}': e.value, 'epg': a.$2});

(Map<Kind, List<MediaItem>>, String?) _decode(String s) {
  final j = jsonDecode(s) as Map;
  return (
    {
      for (final e in j.entries)
        if (int.tryParse(e.key) != null) Kind.values[int.parse(e.key)]: [for (final x in e.value) MediaItem.fromJson(x)],
    },
    j['epg'] as String?,
  );
}

Map<Kind, List<MediaItem>> _buildXtream((List<String>, String, String, String) a) {
  final (r, livePrefix, moviePrefix, liveExt) = a;
  List list(String s) {
    try {
      final j = jsonDecode(s);
      return j is List ? j : const [];
    } catch (_) {
      return const [];
    }
  }

  Map<String, String> cats(String s) =>
      {for (final c in list(s)) '${c['category_id']}': '${c['category_name']}'};
  final liveCats = cats(r[0]), vodCats = cats(r[2]), seriesCats = cats(r[4]);
  int added(v) => int.tryParse('${v ?? 0}') ?? 0;

  return {
    Kind.live: [
      for (final e in list(r[1]))
        MediaItem(
          id: '${e['stream_id']}',
          name: '${e['name']}',
          kind: Kind.live,
          group: liveCats['${e['category_id']}'] ?? 'Ohne Kategorie',
          logo: _str(e['stream_icon']),
          url: '$livePrefix${e['stream_id']}.$liveExt',
          epgId: _str(e['epg_channel_id']),
          archive: '${e['tv_archive']}' == '1' ? int.tryParse('${e['tv_archive_duration']}') ?? 1 : 0,
          added: added(e['added']),
        ),
    ],
    Kind.movie: [
      for (final e in list(r[3]))
        MediaItem(
          id: '${e['stream_id']}',
          name: '${e['name']}',
          kind: Kind.movie,
          group: vodCats['${e['category_id']}'] ?? 'Ohne Kategorie',
          logo: _str(e['stream_icon']),
          url: '$moviePrefix${e['stream_id']}.${e['container_extension'] ?? 'mp4'}',
          rating: _str(e['rating']),
          year: _str(e['year']),
          added: added(e['added']),
        ),
    ],
    Kind.series: [
      for (final e in list(r[5]))
        MediaItem(
          id: '${e['series_id']}',
          name: '${e['name']}',
          kind: Kind.series,
          group: seriesCats['${e['category_id']}'] ?? 'Ohne Kategorie',
          logo: _str(e['cover']),
          rating: _str(e['rating']),
          year: _str(e['releaseDate'] ?? e['year']),
          added: added(e['last_modified']),
        ),
    ],
  };
}
