import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'perf.dart';

final store = Store();

/// Einstellungen, Server, Favoriten und Wiedergabeverlauf. Alles in SharedPreferences.
class Store extends ChangeNotifier {
  late SharedPreferences _p;
  List<Source> sources = [];
  Map<String, Map<String, dynamic>> favs = {}; // key -> {src, item}
  Map<String, Map<String, dynamic>> history = {}; // url -> {src, item, title, pos, dur, ts}

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    sources = [for (final j in _json('sources', [])) Source.fromJson(j)];
    favs = Map<String, Map<String, dynamic>>.from(_json('favs', {}));
    history = Map<String, Map<String, dynamic>>.from(_json('history', {}));
    // Ältere Versionen speicherten bei M3U-Serien die ganze Folgenliste mit: einmal verkleinern
    // (spart Speicher und macht jedes Speichern des Fortschritts schneller)
    for (final (key, map) in [('history', history), ('favs', favs)]) {
      var slim = false;
      for (final e in map.values) {
        final item = e['item'];
        if (item is Map && item.remove('eps') != null) slim = true;
      }
      if (slim) await _p.setString(key, jsonEncode(map));
    }
    // Früheres Standard-Orange auf das neue Standard-Blau umstellen (einmalig)
    if (!(_p.getBool('accentMigrated') ?? false)) {
      if (_p.getInt('accent') == 0xFFE5A23A) await _p.remove('accent');
      await _p.setBool('accentMigrated', true);
    }
  }

  dynamic _json(String k, dynamic def) {
    final s = _p.getString(k);
    return s == null ? def : jsonDecode(s);
  }

  /// Wert oder [def]. Falscher Typ (z. B. aus einer alten Sicherung: 2 statt 2.0) stürzt nicht ab.
  T get<T>(String k, T def) {
    final v = _p.get(k);
    if (v == null) return def;
    if (v is T) return v as T;
    if (v is num && def is double) return v.toDouble() as T;
    if (v is num && def is int) return v.toInt() as T;
    return def;
  }

  /// Speichert eine Einstellung. Unveränderte Werte lösen keinen Neuaufbau aus; [notify] false für
  /// Merker ohne sichtbare Wirkung (zuletzt gewählte Kategorie usw.), sonst baut sich bei jedem Klick
  /// die ganze App neu auf.
  void set(String k, Object v, {bool notify = true}) {
    if (_p.get(k) == v) return;
    switch (v) {
      case bool b: _p.setBool(k, b);
      case int i: _p.setInt(k, i);
      case double d: _p.setDouble(k, d);
      case String s: _p.setString(k, s);
    }
    if (notify) notifyListeners();
  }

  /// Einstellungen auf den Standard zurücksetzen.
  void reset(Iterable<String> keys) {
    for (final k in keys) {
      _p.remove(k);
    }
    notifyListeners();
  }

  // ---- häufig genutzte Einstellungen ----
  static const defaultAccent = 0xFF3E8BFF; // Blau
  Color get accent => Color(get('accent', defaultAccent));

  /// Text-/Symbolfarbe auf Akzentflächen: weiß auf dunklen, schwarz auf hellen Wunschfarben.
  Color get onAccent =>
      ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;
  String get layout => get('layout', 'auto');
  double get tileScale => const {'S': .82, 'M': 1.0, 'L': 1.22}[get('tileSize', 'M')]!;
  // Speed-Modus: ohne Animationen wie „Animationen reduzieren“
  bool get reduceMotion => get('reduceMotion', false) || Perf.speed;
  bool get hideAdult => get('hideAdult', true);
  String get userAgent => get('userAgent', 'VLC/3.0.20 LibVLC/3.0.20');
  String get liveFormat => get('liveFormat', 'ts');
  int get cacheHours => get('cacheHours', 12);
  Duration get anim => Duration(milliseconds: reduceMotion ? 0 : 160);

  // ---- Server ----
  void saveSource(Source s) {
    final i = sources.indexWhere((x) => x.id == s.id);
    i < 0 ? sources.add(s) : sources[i] = s;
    _persistSources();
  }

  void removeSource(Source s) {
    sources.removeWhere((x) => x.id == s.id);
    _persistSources();
  }

  void moveSource(int from, int to) {
    sources.insert(to, sources.removeAt(from));
    _persistSources();
  }

  void _persistSources() {
    _p.setString('sources', jsonEncode(sources));
    notifyListeners();
  }

  // ---- Favoriten ----
  String favKey(Source s, MediaItem m) => '${s.id}|${m.kind.index}|${m.id}';
  bool isFav(Source s, MediaItem m) => favs.containsKey(favKey(s, m));

  void toggleFav(Source s, MediaItem m) {
    final k = favKey(s, m);
    // Ohne Folgenliste speichern (M3U-Serien: kann Tausende Folgen enthalten); die kommt aus der Playlist
    favs.containsKey(k) ? favs.remove(k) : favs[k] = {'src': s.id, 'item': m.toJson(episodes: false)};
    _favCache.clear();
    _p.setString('favs', jsonEncode(favs));
    notifyListeners();
  }

  final _favCache = <String, List<MediaItem>>{};

  /// Favoriten einer Quelle und Art (zwischengespeichert: wird bei jedem Neuaufbau mehrfach abgefragt).
  List<MediaItem> favsOf(Source s, Kind k) => _favCache['${s.id}|${k.index}'] ??= [
        for (final f in favs.values)
          if (f['src'] == s.id && f['item']['kind'] == k.index) MediaItem.fromJson(f['item']),
      ];

  // ---- Verlauf / Fortsetzen ----
  Duration? resumeAt(String url) {
    final h = history[url];
    if (h == null || h['dur'] == 0) return null;
    final pos = h['pos'] as int, dur = h['dur'] as int;
    // Fast fertig oder kaum angefangen: von vorne
    if (pos < 30000 || pos > dur * .95) return null;
    return Duration(milliseconds: pos);
  }

  double progressOf(String? url) {
    final h = url == null ? null : history[url];
    if (h == null || h['dur'] == 0) return 0;
    return ((h['pos'] as int) / (h['dur'] as int)).clamp(0, 1);
  }

  /// [notify] false: nur speichern. Der Player sichert alle 15 s; mit Meldung baute sich dabei jedes Mal die
  /// Liste unter dem Player neu auf. Er meldet einmal beim Schließen ([refresh]).
  void saveProgress(Source s, MediaItem item, String url, String title, Duration pos, Duration dur,
      {bool notify = true}) {
    history[url] = {
      'src': s.id,
      'item': item.toJson(episodes: false),
      'title': title,
      'pos': pos.inMilliseconds,
      'dur': dur.inMilliseconds,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    if (history.length > 200) {
      final oldest = history.entries.reduce((a, b) => a.value['ts'] < b.value['ts'] ? a : b);
      history.remove(oldest.key);
    }
    _p.setString('history', jsonEncode(history));
    if (notify) notifyListeners();
  }

  /// Listen neu aufbauen (Fortschritt, „Weiterschauen“), nachdem ohne Meldung gespeichert wurde.
  void refresh() => notifyListeners();

  /// Zuletzt gesehen (neueste zuerst) für eine Quelle. Serien nur einmal: mit der zuletzt gesehenen Folge.
  List<MapEntry<String, Map<String, dynamic>>> recent(Source s) {
    final l = history.entries.where((e) => e.value['src'] == s.id).toList()
      ..sort((a, b) => (b.value['ts'] as int).compareTo(a.value['ts'] as int));
    final series = <dynamic>{};
    return [
      for (final e in l)
        if (e.value['item']['kind'] != Kind.series.index || series.add(e.value['item']['id'])) e,
    ];
  }

  void clearHistory() {
    history.clear();
    _p.remove('history');
    notifyListeners();
  }

  // ---- Ausgeblendete Kategorien ----
  Set<String>? _hidden;
  Set<String> get hiddenGroups => _hidden ??= {...(_p.getStringList('hiddenGroups') ?? const [])};
  bool isHidden(Source s, Kind k, String g) => hiddenGroups.contains('${s.id}|${k.index}|$g');

  void hideGroup(Source s, Kind k, String g) {
    _hidden = {...hiddenGroups, '${s.id}|${k.index}|$g'};
    _p.setStringList('hiddenGroups', _hidden!.toList());
    notifyListeners();
  }

  void unhideAll() {
    _hidden = null;
    _p.remove('hiddenGroups');
    notifyListeners();
  }

  // ---- Zuletzt gesehene Live-Sender ----
  final _recentLive = <String, List<MediaItem>>{};
  List<MediaItem> recentLive(Source s) => _recentLive[s.id] ??= [
        for (final j in _json('recentLive_${s.id}', [])) MediaItem.fromJson(j),
      ];

  void addRecentLive(Source s, MediaItem m) {
    final l = _recentLive[s.id] = [m, ...recentLive(s).where((x) => x.id != m.id)].take(20).toList();
    _p.setString('recentLive_${s.id}', jsonEncode([for (final x in l) x.toJson(episodes: false)]));
  }

  // ---- Sicherung: Server, Favoriten, Einstellungen als JSON ----
  String exportBackup() => jsonEncode({
        for (final k in _p.getKeys())
          // Gerätebezogen: Downloads und gemessene Leistung gehören nicht auf ein anderes Gerät
          if (!k.startsWith('lastGroup_') &&
              !k.startsWith('recentLive_') &&
              !const {'downloads', 'perfSlow', 'perfVerySlow'}.contains(k))
            k: _p.get(k),
      });

  Future<void> importBackup(String json) async {
    final m = jsonDecode(json) as Map<String, dynamic>;
    if (!m.containsKey('sources')) throw const FormatException('Keine CinemaMax-Sicherung');
    for (final e in m.entries) {
      switch (e.value) {
        case bool b: await _p.setBool(e.key, b);
        case int i: await _p.setInt(e.key, i);
        case double d: await _p.setDouble(e.key, d);
        case String s: await _p.setString(e.key, s);
        case List l: await _p.setStringList(e.key, l.cast<String>());
      }
    }
    _hidden = null;
    _recentLive.clear();
    _favCache.clear();
    await init();
    notifyListeners();
  }

  void clearFavs() {
    favs.clear();
    _favCache.clear();
    _p.remove('favs');
    notifyListeners();
  }
}

final _adult = RegExp(r'adult|xxx|18\+|porn|erotic|\bsex', caseSensitive: false);
final _adultCache = <String, bool>{};

/// Erwachsenen-Kategorie? Je Kategoriename nur einmal geprüft (wird für jeden Eintrag gefragt).
bool isAdult(String group) => _adultCache[group] ??= _adult.hasMatch(group);
