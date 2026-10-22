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
    // Früheres Standard-Orange auf das neue Standard-Blau umstellen (einmalig)
    if (_p.getInt('accent') == 0xFFE5A23A && !(_p.getBool('accentMigrated') ?? false)) await _p.remove('accent');
    await _p.setBool('accentMigrated', true);
  }

  dynamic _json(String k, dynamic def) {
    final s = _p.getString(k);
    return s == null ? def : jsonDecode(s);
  }

  T get<T>(String k, T def) => (_p.get(k) as T?) ?? def;

  void set(String k, Object v) {
    switch (v) {
      case bool b: _p.setBool(k, b);
      case int i: _p.setInt(k, i);
      case double d: _p.setDouble(k, d);
      case String s: _p.setString(k, s);
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
    favs.containsKey(k) ? favs.remove(k) : favs[k] = {'src': s.id, 'item': m.toJson()};
    _p.setString('favs', jsonEncode(favs));
    notifyListeners();
  }

  List<MediaItem> favsOf(Source s, Kind k) => [
        for (final f in favs.values)
          if (f['src'] == s.id) MediaItem.fromJson(f['item']),
      ].where((m) => m.kind == k).toList();

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

  void saveProgress(Source s, MediaItem item, String url, String title, Duration pos, Duration dur) {
    history[url] = {
      'src': s.id,
      'item': item.toJson(),
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
    notifyListeners();
  }

  /// Zuletzt gesehen (neueste zuerst) für eine Quelle.
  List<MapEntry<String, Map<String, dynamic>>> recent(Source s) =>
      history.entries.where((e) => e.value['src'] == s.id).toList()
        ..sort((a, b) => (b.value['ts'] as int).compareTo(a.value['ts'] as int));

  void clearHistory() {
    history.clear();
    _p.remove('history');
    notifyListeners();
  }

  // ---- Ausgeblendete Kategorien ----
  Set<String> get hiddenGroups => {...(_p.getStringList('hiddenGroups') ?? const [])};
  bool isHidden(Source s, Kind k, String g) => hiddenGroups.contains('${s.id}|${k.index}|$g');

  void hideGroup(Source s, Kind k, String g) {
    _p.setStringList('hiddenGroups', [...hiddenGroups, '${s.id}|${k.index}|$g']);
    notifyListeners();
  }

  void unhideAll() {
    _p.remove('hiddenGroups');
    notifyListeners();
  }

  // ---- Zuletzt gesehene Live-Sender ----
  List<MediaItem> recentLive(Source s) => [
        for (final j in _json('recentLive_${s.id}', [])) MediaItem.fromJson(j),
      ];

  void addRecentLive(Source s, MediaItem m) {
    final l = [m, ...recentLive(s).where((x) => x.id != m.id)].take(20).toList();
    _p.setString('recentLive_${s.id}', jsonEncode(l));
  }

  // ---- Sicherung: Server, Favoriten, Einstellungen als JSON ----
  String exportBackup() => jsonEncode({
        for (final k in _p.getKeys())
          if (!k.startsWith('lastGroup_') && !k.startsWith('recentLive_') && k != 'downloads') k: _p.get(k),
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
    await init();
    notifyListeners();
  }

  void clearFavs() {
    favs.clear();
    _p.remove('favs');
    notifyListeners();
  }
}

final _adult = RegExp(r'adult|xxx|18\+|porn|erotic|\bsex', caseSensitive: false);
bool isAdult(String group) => _adult.hasMatch(group);
