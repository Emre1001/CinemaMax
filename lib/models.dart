enum Kind { live, movie, series }

enum SourceType { m3u, xtream, iptv, stalker }

/// Ein gespeicherter Server: M3U-Link, Xtream-Codes-Zugang, Stalker-Portal oder IPTV-Liste.
class Source {
  final String id;
  String name;
  SourceType type;
  String url; // M3U-URL, Xtream-Host (http://host:port) bzw. Stalker-Portal (http://host/c/)
  String user;
  String pass;
  String mac; // nur Stalker

  Source({
    required this.id,
    required this.name,
    required this.type,
    required this.url,
    this.user = '',
    this.pass = '',
    this.mac = '',
  });

  String get host => url.replaceAll(RegExp(r'/+$'), '');

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'type': type.name, 'url': url, 'user': user, 'pass': pass, 'mac': mac};

  factory Source.fromJson(Map<String, dynamic> j) => Source(
        id: j['id'],
        name: j['name'],
        type: SourceType.values.byName(j['type']),
        url: j['url'],
        user: j['user'] ?? '',
        pass: j['pass'] ?? '',
        mac: j['mac'] ?? '',
      );
}

class MediaItem {
  final String id;
  final String name;
  final Kind kind;
  final String group;
  final String? logo;
  final String? url; // null bei Xtream-Serien (Episoden werden nachgeladen)
  final String? epgId;
  final String? rating;
  final String? year;
  final int added; // Unix-Sekunden, 0 = unbekannt
  final List<Episode>? episodes; // M3U-Serien: aus Einträgen gruppiert
  final int archive; // Xtream: Tage Rückschau (Catch-up), 0 = keine

  const MediaItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.group,
    this.logo,
    this.url,
    this.epgId,
    this.rating,
    this.year,
    this.added = 0,
    this.episodes,
    this.archive = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.index,
        'group': group,
        'logo': logo,
        'url': url,
        'epg': epgId,
        'rating': rating,
        'year': year,
        'added': added,
        if (archive > 0) 'arch': archive,
        if (episodes != null) 'eps': episodes!.map((e) => e.toJson()).toList(),
      };

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        id: j['id'],
        name: j['name'],
        kind: Kind.values[j['kind']],
        group: j['group'],
        logo: j['logo'],
        url: j['url'],
        epgId: j['epg'],
        rating: j['rating'],
        year: j['year'],
        added: j['added'] ?? 0,
        archive: j['arch'] ?? 0,
        episodes: (j['eps'] as List?)?.map((e) => Episode.fromJson(e)).toList(),
      );
}

class Episode {
  final String id;
  final int season;
  final int number;
  final String title;
  final String url;
  final String? image;
  final String? plot;

  const Episode({
    required this.id,
    required this.season,
    required this.number,
    required this.title,
    required this.url,
    this.image,
    this.plot,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 's': season, 'n': number, 't': title, 'u': url, 'i': image, 'p': plot};

  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
        id: j['id'],
        season: j['s'],
        number: j['n'],
        title: j['t'],
        url: j['u'],
        image: j['i'],
        plot: j['p'],
      );
}

/// Geladener Inhalt einer Quelle, je Typ nach Kategorie gruppiert.
class Library {
  final Map<Kind, List<MediaItem>> items;
  final Map<Kind, List<String>> groups;

  /// Stalker: Filme/Serien sind zu groß zum Vorladen und kommen pro Kategorie nach.
  final Future<List<MediaItem>> Function(Kind kind, String group)? lazy;

  /// Stalker: Suche direkt beim Portal (Filme/Serien sind nicht lokal).
  final Future<List<MediaItem>> Function(Kind kind, String query)? search;

  /// XMLTV-Programmführer (aus M3U-Kopf oder Xtream), null = keiner bekannt.
  final String? epgUrl;

  Library(this.items, {Map<Kind, List<String>>? groups, this.lazy, this.search, this.epgUrl})
      : groups = groups ??
            {
              for (final k in Kind.values)
                k: {for (final i in items[k] ?? const <MediaItem>[]) i.group}.toList(),
            };

  List<MediaItem> of(Kind k) => items[k] ?? const [];

  /// Gleiche Bibliothek mit anderem Programmführer (vom Nutzer eingetragen).
  Library withEpg(String url) =>
      url.isEmpty ? this : Library(items, groups: groups, lazy: lazy, search: search, epgUrl: url);
}
