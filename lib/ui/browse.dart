import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n.dart';
import '../downloads.dart';
import '../epg.dart';
import '../models.dart';
import '../repo.dart';
import '../store.dart';
import 'common.dart';
import 'detail.dart';
import 'guide.dart';
import 'downloads_view.dart';
import 'player.dart';
import 'settings.dart';
import 'start.dart';

enum Tab { mine, live, guide, movie, series, search, downloads, settings, more }

const _tabInfo = {
  Tab.live: ('Live TV', Icons.live_tv_rounded),
  Tab.movie: ('Filme', Icons.movie_rounded),
  Tab.series: ('Serien', Icons.video_library_rounded),
  Tab.mine: ('Start', Icons.home_rounded),
  Tab.guide: ('TV-Guide', Icons.view_agenda_rounded),
  Tab.search: ('Suche', Icons.search_rounded),
  Tab.more: ('Mehr', Icons.menu_rounded),
  Tab.downloads: ('Downloads', Icons.download_rounded),
  Tab.settings: ('Einstellungen', Icons.tune_rounded),
};

Kind? _kindOf(Tab t) => switch (t) { Tab.live => Kind.live, Tab.movie => Kind.movie, Tab.series => Kind.series, _ => null };

/// Öffnet Film/Serie im Detail oder spielt Live-Sender direkt (mit Senderliste zum Zappen).
void openItem(BuildContext c, Source s, MediaItem m, {List<MediaItem>? siblings}) {
  if (m.kind != Kind.live) {
    Navigator.push(c, MaterialPageRoute(builder: (_) => DetailScreen(source: s, item: m)));
    return;
  }
  final list = siblings ?? [m];
  PlayerScreen.open(c, s, [for (final x in list) PlayItem(x.url!, x.name, x)], list.indexOf(m).clamp(0, list.length));
}

void toggleFav(BuildContext c, Source s, MediaItem m) {
  store.toggleFav(s, m);
  toast(c, store.isFav(s, m) ? tr('„{0}“ zu Favoriten hinzugefügt', [m.name]) : tr('Aus Favoriten entfernt'));
}

class BrowseScreen extends StatefulWidget {
  final Source source;
  const BrowseScreen({super.key, required this.source});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  Library? _lib;
  Object? _error;
  Tab _tab = Tab.live;
  // Kein FocusScope: der würde die Pfeil-Navigation zum Inhalt blockieren
  final _navFocus = FocusNode(debugLabel: 'nav', skipTraversal: true, canRequestFocus: false);
  final _navNodes = {for (final t in Tab.values) t: FocusNode(debugLabel: 'nav-${t.name}')};
  bool _navOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _navFocus.dispose();
    for (final n in _navNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _lib = null;
      _error = null;
    });
    try {
      final lib = (await Repo.load(widget.source, force: force)).withEpg(store.get('epgUrl_${widget.source.id}', ''));
      if (!mounted) return;
      // Programmführer im Hintergrund laden
      if (store.get('epg', true)) epg.ensure(widget.source, lib);
      final start = Tab.values.byName(store.get('startTab', 'mine'));
      setState(() {
        _lib = lib;
        _tab = _tabs.contains(start) || (start == Tab.guide && _hasGuide) ? start : (_contentTabs.firstOrNull ?? Tab.search);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  List<Tab> get _contentTabs => [
        for (final t in [Tab.live, Tab.movie, Tab.series])
          if (_lib!.groups[_kindOf(t)!]!.isNotEmpty) t,
      ];

  bool get _hasGuide => _lib!.epgUrl != null && _lib!.of(Kind.live).isNotEmpty;

  // Handy: höchstens 5 Einträge unten (TV-Guide über den Knopf im Live-Bereich)
  // Suche steckt oben in der Leiste, „Mehr“ enthält alles Weitere wie die PC-Seitenleiste
  List<Tab> get _tabs => [Tab.mine, ..._contentTabs, Tab.more];

  void _openSearch() => setState(() => _tab = Tab.search);

  Widget _content(Tab t) => switch (t) {
        Tab.mine => MineView(source: widget.source, lib: _lib!),
        Tab.guide => GuideView(source: widget.source, lib: _lib!),
        Tab.search => SearchView(source: widget.source, lib: _lib!),
        Tab.settings => const SettingsBody(),
        Tab.downloads => const DownloadsView(),
        Tab.more => MoreView(
            source: widget.source,
            hasGuide: _hasGuide,
            onTab: (t) => setState(() => _tab = t),
          ),
        _ => ContentView(
            key: ValueKey(t),
            source: widget.source,
            lib: _lib!,
            kind: _kindOf(t)!,
            onSearch: _openSearch,
            onGuide: t == Tab.live && _hasGuide ? () => setState(() => _tab = Tab.guide) : null),
      };

  List<Widget> _actions({bool phone = false}) => [
        if (_tab != Tab.search)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: phone
                ? Tap(
                    radius: 100,
                    onTap: _openSearch,
                    child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.search_rounded)),
                  )
                : Pill(tr('Suchen'), icon: Icons.search_rounded, onTap: _openSearch),
          ),
        if (widget.source.id.startsWith('iptv-'))
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Pill(tr(iptvCountries[store.get('iptvCountry', 'de')] ?? 'Land'), icon: Icons.public, onTap: () async {
              final cc = await pick(context, tr('Land'), {for (final e in iptvCountries.entries) e.key: tr(e.value)}, current: store.get('iptvCountry', 'de'));
              if (cc != null && mounted) {
                store.set('iptvCountry', cc);
                openSource(context, iptvSource(), replace: true);
              }
            }),
          ),
        Tap(
          radius: 100,
          onTap: () => _load(force: true),
          child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.refresh_rounded)),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    if (_lib == null) {
      return Scaffold(
        body: Center(
          child: _error == null
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(width: 34, height: 34, child: CircularProgressIndicator(strokeWidth: 3)),
                  const SizedBox(height: 20),
                  Text(tr('Lade {0} …', [widget.source.name]), style: const TextStyle(color: textDim)),
                ])
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.cloud_off_rounded, size: 48, color: textDim),
                  const SizedBox(height: 16),
                  Text(tr('Server nicht erreichbar'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text('$_error', textAlign: TextAlign.center, style: const TextStyle(color: textDim)),
                  ),
                  const SizedBox(height: 22),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Pill(tr('Erneut versuchen'), icon: Icons.refresh, primary: true, autofocus: true, onTap: () => _load(force: true)),
                    const SizedBox(width: 10),
                    Pill(tr('Zurück'), onTap: () => Navigator.pop(context)),
                  ]),
                ]),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openSearch,
        const SingleActivator(LogicalKeyboardKey.browserSearch): _openSearch,
        const SingleActivator(LogicalKeyboardKey.find): _openSearch,
      },
      child: _layout(context),
    );
  }

  Widget _layout(BuildContext context) {
    if (!isWide(context)) {
      final tabs = _tabs;
      return Scaffold(
        appBar: AppBar(
          backgroundColor: bg,
          surfaceTintColor: Colors.transparent,
          titleSpacing: 16,
          title: Text(tr(_tabInfo[_tab]!.$1), style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -.5)),
          actions: [
            ..._actions(phone: true),
            Tap(
              radius: 100,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
              child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.tune_rounded)),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: _content(_tab),
        bottomNavigationBar: NavigationBar(
          backgroundColor: surface,
          indicatorColor: store.accent.withValues(alpha: .22),
          height: 64,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          selectedIndex: tabs.contains(_tab) ? tabs.indexOf(_tab) : tabs.length - 1,
          onDestinationSelected: (i) => setState(() => _tab = tabs[i]),
          destinations: [
            for (final t in tabs) NavigationDestination(icon: Icon(_tabInfo[t]!.$2), label: tr(_tabInfo[t]!.$1)),
          ],
        ),
      );
    }

    // TV / Desktop / Tablet: Seitenleiste, klappt bei Fokus auf
    final tv = formFactor(context) == Ff.tv;
    final navItems = [
      Tab.search,
      Tab.mine,
      for (final t in _contentTabs) ...[t, if (t == Tab.live && _hasGuide) Tab.guide],
      Tab.downloads,
      Tab.settings,
    ];
    return PopScope(
      canPop: _navFocus.hasFocus || !tv,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _navNodes[_tab]!.requestFocus();
      },
      child: Scaffold(
        body: Row(children: [
          Focus(
            focusNode: _navFocus,
            onFocusChange: (v) => setState(() => _navOpen = v),
            child: AnimatedContainer(
              duration: store.anim,
              curve: Curves.easeOutCubic,
              width: _navOpen || !tv ? 228 : 84,
              color: surface,
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  height: 40,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      maxWidth: 220,
                      child: Padding(
                          padding: const EdgeInsets.only(left: 12), child: Wordmark(compact: !(_navOpen || !tv))),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                for (final t in navItems) ...[
                  if (t == Tab.settings) const Spacer(),
                  _NavItem(
                    focusNode: _navNodes[t],
                    tab: t,
                    selected: t == _tab,
                    expanded: _navOpen || !tv,
                    autofocus: t == _tab,
                    onSelect: () => setState(() => _tab = t),
                  ),
                ],
                _NavItem(
                  icon: Icons.swap_horiz_rounded,
                  label: tr('Server wechseln'),
                  expanded: _navOpen || !tv,
                  onSelect: () => Navigator.pop(context),
                ),
              ]),
            ),
          ),
          Expanded(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 22, 24, 0),
                child: Row(children: [
                  Text(tr(_tabInfo[_tab]!.$1),
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -.8)),
                  const SizedBox(width: 14),
                  Text(widget.source.name, style: const TextStyle(color: textDim, fontSize: 14)),
                  const Spacer(),
                  if (_tab != Tab.settings) ..._actions(),
                  if (store.get('clock', true)) const Padding(padding: EdgeInsets.only(left: 12), child: Clock()),
                ]),
              ),
              Expanded(child: FocusTraversalGroup(child: _content(_tab))),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final FocusNode? focusNode;
  final Tab? tab;
  final IconData? icon;
  final String? label;
  final bool selected, expanded, autofocus;
  final VoidCallback onSelect;

  const _NavItem({
    this.focusNode,
    this.tab,
    this.icon,
    this.label,
    this.selected = false,
    required this.expanded,
    this.autofocus = false,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Tap(
        fill: true,
        scale: 1,
        focusNode: focusNode,
        autofocus: autofocus,
        onTap: onSelect,
        // TV: Tab wechselt schon beim Fokussieren (wie Apple TV)
        onFocus: (v) {
          if (v && tab != null && tab != Tab.settings && formFactor(context) == Ff.tv) onSelect();
        },
        child: SizedBox(
          height: 46,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: 200,
              child: Row(children: [
                const SizedBox(width: 14),
                Icon(icon ?? _tabInfo[tab]!.$2, size: 22, color: selected ? accent : Colors.white70),
                const SizedBox(width: 16),
                AnimatedOpacity(
                  opacity: expanded ? 1 : 0,
                  duration: store.anim,
                  child: Text(label ?? tr(_tabInfo[tab]!.$1),
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? Colors.white : Colors.white70)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class Clock extends StatelessWidget {
  const Clock({super.key});

  @override
  Widget build(BuildContext context) => StreamBuilder(
        stream: Stream.periodic(const Duration(seconds: 15)),
        builder: (c, _) => Text(
          TimeOfDay.now().format(c),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
        ),
      );
}

// ---------------- Inhalt eines Typs: Kategorien + Raster ----------------

List<MediaItem> sorted(List<MediaItem> l) {
  switch (store.get('sort', 'default')) {
    case 'az': return [...l]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    case 'za': return [...l]..sort((a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
    case 'new': return [...l]..sort((a, b) => b.added.compareTo(a.added));
    case 'rating':
      return [...l]..sort((a, b) => (double.tryParse(b.rating ?? '') ?? 0).compareTo(double.tryParse(a.rating ?? '') ?? 0));
  }
  return l;
}

// Anbieter-Präfixe wie "DE | Sport", "|TR| Ulusal", "[EN] News", "4K: Filme"
final _prefixRe = RegExp(r'^\s*[\[(|]?\s*([A-Z0-9]{2,3}(?:-[A-Z]{2})?)\s*[\])|:\-–•]+\s*(\S.*)$');

/// Teilt einen Kategorienamen in Länder-/Anbieterpräfix und lesbaren Namen.
({String? prefix, String name}) splitGroup(String g) {
  final m = _prefixRe.firstMatch(g);
  return m == null ? (prefix: null, name: g.trim()) : (prefix: m.group(1), name: m.group(2)!.trim());
}

class ContentView extends StatefulWidget {
  final Source source;
  final Library lib;
  final Kind kind;
  final VoidCallback onSearch;
  final VoidCallback? onGuide;
  const ContentView(
      {super.key, required this.source, required this.lib, required this.kind, required this.onSearch, this.onGuide});

  @override
  State<ContentView> createState() => _ContentViewState();
}

class _ContentViewState extends State<ContentView> {
  static const _all = '\u0000all', _fav = '\u0000fav', _recent = '\u0000new';
  final _byGroup = <String, List<MediaItem>>{};
  late final List<String> _groups;
  late final Map<String, int> _prefixes; // Präfix -> Anzahl Kategorien
  String? _prefix; // aktiver Präfixfilter, null = alle
  String _sel = _all;
  // Stalker: pro Kategorie nachgeladene Einträge
  final _lazyItems = <String, List<MediaItem>>{};
  Timer? _lazyTimer;
  List<MediaItem>? _itemsCache;

  bool get _lazy => widget.lib.lazy != null && widget.kind != Kind.live;
  String get _key => '${widget.source.id}_${widget.kind.index}';

  void _fetch(String g) {
    if (!_lazy || g == _fav || _lazyItems.containsKey(g)) return;
    widget.lib.lazy!(widget.kind, g).then((l) {
      if (mounted) setState(() => _lazyItems[g] = l);
    }).catchError((Object e) {
      if (!mounted) return;
      setState(() => _lazyItems[g] = const []);
      toast(context, tr('Kategorie konnte nicht geladen werden: {0}', [e]));
    });
  }

  @override
  void dispose() {
    _lazyTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    for (final m in widget.lib.of(widget.kind)) {
      (_byGroup[m.group] ??= []).add(m);
    }
    _groups = widget.lib.groups[widget.kind]!
        .where((g) => (!store.hideAdult || !isAdult(g)) && !store.isHidden(widget.source, widget.kind, g))
        .toList();
    if (store.get('sortGroups', false)) {
      _groups.sort((a, b) => splitGroup(a).name.toLowerCase().compareTo(splitGroup(b).name.toLowerCase()));
    }
    final counts = <String, int>{};
    for (final g in _groups) {
      final p = splitGroup(g).prefix;
      if (p != null) counts[p] = (counts[p] ?? 0) + 1;
    }
    // Filter nur anbieten, wenn es wirklich mehrere Präfixe gibt
    _prefixes = counts.length >= 2 ? (Map.fromEntries(counts.entries.toList()..sort((a, b) => b.value - a.value))) : {};
    final p = store.get('prefix_$_key', '');
    _prefix = _prefixes.containsKey(p) ? p : null;
    _sel = store.get('lastGroup_$_key', _all);
    if (_sel != _all && _sel != _fav && _sel != _recent && !_visibleGroups.contains(_sel)) _sel = _all;
    if (_lazy && _sel == _recent) _sel = _all;
    _fetch(_sel);
  }

  List<String> get _visibleGroups =>
      _prefix == null ? _groups : _groups.where((g) => splitGroup(g).prefix == _prefix).toList();

  int _count(String g) => switch (g) {
        _fav => store.favsOf(widget.source, widget.kind).length,
        _all || _recent => -1,
        _ => _byGroup[g]?.length ?? _lazyItems[g]?.length ?? -1,
      };

  List<MediaItem> _computeItems() {
    if (_sel == _fav) return store.favsOf(widget.source, widget.kind);
    bool ok(MediaItem m) =>
        (!store.hideAdult || !isAdult(m.group)) && (_prefix == null || splitGroup(m.group).prefix == _prefix);
    if (_lazy) return sorted((_lazyItems[_sel] ?? const []).where(ok).toList());
    if (_sel == _recent) {
      return ([...widget.lib.of(widget.kind).where(ok)]..sort((a, b) => b.added.compareTo(a.added))).take(200).toList();
    }
    if (_sel == _all) return sorted(widget.lib.of(widget.kind).where(ok).toList());
    return sorted(_byGroup[_sel] ?? const []);
  }

  void _select(String g) {
    if (g == _sel) return;
    setState(() {
      _sel = g;
      _itemsCache = null;
    });
    store.set('lastGroup_$_key', g);
    // Verzögert laden: beim Durchscrollen der Kategorien am TV nicht jede abrufen
    _lazyTimer?.cancel();
    _lazyTimer = Timer(const Duration(milliseconds: 350), () => _fetch(g));
  }

  Future<void> _hideGroup(String g) async {
    final ok = await pick(context, _label(g), {true: tr('Kategorie ausblenden'), false: tr('Abbrechen')});
    if (ok != true || !mounted) return;
    store.hideGroup(widget.source, widget.kind, g);
    setState(() {
      _groups.remove(g);
      if (_sel == g) _sel = _all;
      _itemsCache = null;
    });
    toast(context, tr('Ausgeblendet. Zurückholen unter Einstellungen › Daten.'));
  }

  void _setPrefix(String? p) {
    setState(() {
      _prefix = p;
      _itemsCache = null;
      if (_sel != _all && _sel != _fav && _sel != _recent && !_visibleGroups.contains(_sel)) _sel = _all;
    });
    store.set('prefix_$_key', p ?? '');
  }

  String _label(String g) => switch (g) {
        _all => _prefix == null ? tr('Alle') : tr('Alle {0}', [_prefix]),
        _fav => tr('Favoriten'),
        _recent => tr('Neu hinzugefügt'),
        _ => _prefix != null ? splitGroup(g).name : g,
      };

  IconData? _icon(String g) => switch (g) {
        _all => Icons.apps_rounded,
        _fav => Icons.bookmark_rounded,
        _recent => Icons.schedule_rounded,
        _ => null,
      };

  /// Handy: Kategorie-Auswahl als Vollbild-Liste mit Suchfeld.
  Future<void> _openPicker(List<String> cats) async {
    final g = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: surface,
      showDragHandle: true,
      builder: (c) => _CategoryPicker(cats: cats, selected: _sel, label: _label, icon: _icon, count: _count),
    );
    if (g != null) _select(g);
  }

  Widget _prefixBar() => SizedBox(
        height: 44,
        child: FocusTraversalGroup(
          child: ListView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              Pill(tr('Alle'), selected: _prefix == null, onTap: () => _setPrefix(null)),
              for (final p in _prefixes.keys)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Pill(p, selected: _prefix == p, onTap: () => _setPrefix(p)),
                ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final cats = [_all, _fav, if (widget.kind != Kind.live && !_lazy) _recent, ..._visibleGroups];
    final loading = _lazy && _sel != _fav && !_lazyItems.containsKey(_sel);
    final grid = loading
        ? const Center(child: CircularProgressIndicator())
        : ListenableBuilder(
            listenable: store,
            builder: (_, _) => MediaGrid(
              key: PageStorageKey('${widget.kind}$_sel$_prefix'),
              source: widget.source,
              // Favoriten können sich ändern, der Rest wird nur bei Auswahlwechsel neu sortiert
              items: _sel == _fav ? _computeItems() : (_itemsCache ??= _computeItems()),
              empty: _sel == _fav ? tr('Noch keine Favoriten.\nOK lange drücken zum Hinzufügen.') : tr('Keine Einträge'),
            ),
          );

    if (!wide) {
      return Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Row(children: [
            Expanded(
              child: Tap(
                radius: 12,
                scale: 1.02,
                onTap: () => _openPicker(cats),
                child: Container(
                  color: surface2,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    Icon(_icon(_sel) ?? Icons.folder_rounded, size: 20, color: store.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(tr('Kategorie · {0}', [cats.length - 2 - (cats.contains(_recent) ? 1 : 0)]),
                            style: const TextStyle(color: textDim, fontSize: 11.5)),
                        Text(_label(_sel),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      ]),
                    ),
                    const Icon(Icons.expand_more_rounded),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Tap(
              radius: 12,
              onTap: widget.onSearch,
              child: Container(
                color: surface2,
                padding: const EdgeInsets.all(13),
                child: const Icon(Icons.search_rounded),
              ),
            ),
            if (widget.onGuide != null) ...[
              const SizedBox(width: 8),
              Tap(
                radius: 12,
                onTap: widget.onGuide,
                child: Container(color: surface2, padding: const EdgeInsets.all(13), child: const Icon(Icons.view_agenda_rounded)),
              ),
            ],
          ]),
        ),
        if (_prefixes.isNotEmpty)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _prefixBar()),
        Expanded(child: grid),
      ]);
    }

    return Row(children: [
      SizedBox(
        width: 270,
        child: FocusTraversalGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_prefixes.isNotEmpty)
              Padding(padding: const EdgeInsets.fromLTRB(20, 12, 8, 0), child: _prefixBar()),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 24),
                itemCount: cats.length,
                itemBuilder: (_, i) => _CategoryRow(
                  label: _label(cats[i]),
                  icon: _icon(cats[i]),
                  count: _count(cats[i]),
                  selected: cats[i] == _sel,
                  divider: i == (cats.contains(_recent) ? 3 : 2),
                  onTap: () => _select(cats[i]),
                  onLongPress: _icon(cats[i]) == null ? () => _hideGroup(cats[i]) : null,
                ),
              ),
            ),
          ]),
        ),
      ),
      Container(width: 1, color: line),
      Expanded(child: FocusTraversalGroup(child: grid)),
    ]);
  }
}

class _CategoryRow extends StatelessWidget {
  final String label;
  final IconData? icon;
  final int count;
  final bool selected, divider;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _CategoryRow({
    this.onLongPress,
    required this.label,
    required this.icon,
    required this.count,
    required this.selected,
    required this.onTap,
    this.divider = false,
  });

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (divider)
          Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Text(tr('KATEGORIEN'), style: TextStyle(color: textDim, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Tap(
            fill: true,
            scale: 1,
            radius: 8,
            onTap: onTap,
            onLongPress: onLongPress,
            child: AnimatedContainer(
              duration: store.anim,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: selected ? store.accent.withValues(alpha: .14) : Colors.transparent,
              child: Row(children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: selected ? store.accent : Colors.white60),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? Colors.white : Colors.white70,
                      )),
                ),
                if (count >= 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(20)),
                    child: Text('$count', style: const TextStyle(color: Colors.white60, fontSize: 11.5)),
                  ),
              ]),
            ),
          ),
        ),
      ]);
}

class _CategoryPicker extends StatefulWidget {
  final List<String> cats;
  final String selected;
  final String Function(String) label;
  final IconData? Function(String) icon;
  final int Function(String) count;
  const _CategoryPicker(
      {required this.cats, required this.selected, required this.label, required this.icon, required this.count});

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = normalize(_q);
    final list = widget.cats.where((g) => q.isEmpty || normalize(widget.label(g)).contains(q)).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(hintText: tr('Kategorie suchen'), prefixIcon: Icon(Icons.search_rounded)),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 24),
            itemCount: list.length,
            itemBuilder: (c, i) => _CategoryRow(
              label: widget.label(list[i]),
              icon: widget.icon(list[i]),
              count: widget.count(list[i]),
              selected: list[i] == widget.selected,
              onTap: () => Navigator.pop(c, list[i]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Für Suche: Kleinbuchstaben, Umlaute vereinfacht, Satzzeichen weg ("Spider-Man" = "spider man").
String normalize(String s) => s
    .toLowerCase()
    .replaceAll('ä', 'a')
    .replaceAll('ö', 'o')
    .replaceAll('ü', 'u')
    .replaceAll('ß', 'ss')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// Raster aus Postern (Filme/Serien) oder Senderkacheln (Live).
class MediaGrid extends StatelessWidget {
  final Source source;
  final List<MediaItem> items;
  final String? empty;
  const MediaGrid({super.key, required this.source, required this.items, this.empty});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(child: Text(empty ?? tr('Keine Einträge'), textAlign: TextAlign.center, style: const TextStyle(color: textDim, fontSize: 15)));
    }
    final live = items.first.kind == Kind.live;
    final s = store.tileScale * (formFactor(context) == Ff.phone ? .8 : 1);
    final listMode = live && store.get('liveAsList', false);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 24, 32),
      clipBehavior: Clip.hardEdge,
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: listMode ? 520 : (live ? 210 : 160) * s,
        childAspectRatio: listMode ? 6 : (live ? 1.05 : .53),
        crossAxisSpacing: 16,
        mainAxisSpacing: listMode ? 10 : 18,
      ),
      itemCount: items.length,
      itemBuilder: (c, i) => MediaTile(
        source: source,
        item: items[i],
        listMode: listMode,
        onTap: () => openItem(c, source, items[i], siblings: live ? items : null),
      ),
    );
  }
}

class MediaTile extends StatelessWidget {
  final Source source;
  final MediaItem item;
  final VoidCallback onTap;
  final bool listMode;
  final double? progress;
  final String? caption;

  const MediaTile({
    super.key,
    required this.source,
    required this.item,
    required this.onTap,
    this.listMode = false,
    this.progress,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    final fav = store.isFav(source, item);
    final p = progress ?? (item.kind == Kind.movie ? store.progressOf(item.url) : 0);
    final badge = fav
        ? Positioned(top: 6, right: 6, child: Icon(Icons.bookmark_rounded, size: 18, color: store.accent))
        : null;
    final bar = p > 0
        ? Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(value: p, minHeight: 3, color: store.accent, backgroundColor: Colors.black54),
          )
        : null;

    if (item.kind == Kind.live) {
      return Tap(
        onTap: onTap,
        onLongPress: () => toggleFav(context, source, item),
        scale: listMode ? 1.02 : 1.06,
        child: Container(
          color: surface,
          child: listMode
              ? Row(children: [
                  SizedBox(width: 90, child: Padding(padding: const EdgeInsets.all(8), child: Artwork(item.logo, item.name, fit: BoxFit.contain, width: 90))),
                  Expanded(child: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                  if (fav) Padding(padding: const EdgeInsets.only(right: 12), child: Icon(Icons.bookmark_rounded, size: 18, color: store.accent)),
                ])
              : Stack(children: [
                  Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
                        child: Artwork(item.logo, item.name, fit: BoxFit.contain, width: 170),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Column(children: [
                        Text(caption ?? item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        // Aktuelle Sendung aus dem Programmführer
                        ListenableBuilder(
                          listenable: epg,
                          builder: (_, _) {
                            final now = epg.now(source, item.epgId);
                            return now == null
                                ? const SizedBox.shrink()
                                : Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Column(children: [
                                      Text(now.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(fontSize: 11.5, color: textDim)),
                                      const SizedBox(height: 4),
                                      LinearProgressIndicator(
                                          value: now.progress, minHeight: 2, color: store.accent, backgroundColor: Colors.white12),
                                    ]),
                                  );
                          },
                        ),
                      ]),
                    ),
                  ]),
                  ?badge,
                ]),
        ),
      );
    }

    final meta = [
      if (item.year != null && item.year!.length >= 4) item.year!.substring(0, 4),
      if (item.rating != null && item.rating != '0' && double.tryParse(item.rating!) != null)
        '★ ${double.parse(item.rating!).toStringAsFixed(1)}',
    ].join('  ·  ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AspectRatio(
        aspectRatio: 2 / 3,
        child: Tap(
          onTap: onTap,
          onLongPress: () => toggleFav(context, source, item),
          scale: 1.07,
          child: Stack(fit: StackFit.expand, children: [Artwork(item.logo, item.name), ?badge, ?bar]),
        ),
      ),
      SizedBox(height: 8),
      Text(caption ?? item.name,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.25)),
      if (meta.isNotEmpty) Text(meta, style: TextStyle(fontSize: 11.5, color: textDim)),
    ]);
  }
}

// ---------------- Meine Liste: Weiterschauen + Favoriten ----------------

Widget get _emptyMine => Text(tr('Hier erscheinen Favoriten und zuletzt Gesehenes.\nOK lange drücken fügt Favoriten hinzu.'),
    textAlign: TextAlign.center, style: TextStyle(color: textDim, fontSize: 15));

class MineView extends StatelessWidget {
  final Source source;
  final Library lib;
  const MineView({super.key, required this.source, required this.lib});

  /// Neueste (falls Datum bekannt) bzw. am besten bewertete Einträge, ohne Erwachsenen-Kategorien.
  List<MediaItem> _top(Kind k, {bool rating = false}) {
    final l = lib.of(k).where((m) => !store.hideAdult || !isAdult(m.group)).toList();
    if (rating) {
      double r(MediaItem m) => double.tryParse(m.rating ?? '') ?? 0;
      l.sort((a, b) => r(b).compareTo(r(a)));
      return r(l.firstOrNull ?? const MediaItem(id: '', name: '', kind: Kind.movie, group: '')) > 0 ? l.take(30).toList() : [];
    }
    if (l.any((m) => m.added > 0)) l.sort((a, b) => b.added.compareTo(a.added));
    return l.take(30).toList();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final recent = store.recent(source).take(30).toList();
          final rows = <(String, Kind, List<Widget>)>[
            (
              tr('Weiterschauen'),
              Kind.movie,
              [
                for (final e in recent)
                  _sized(
                    Kind.movie,
                    MediaTile(
                      source: source,
                      item: MediaItem.fromJson(e.value['item']),
                      caption: e.value['title'],
                      progress: store.progressOf(e.key),
                      onTap: () => PlayerScreen.open(
                          context, source, [PlayItem(e.key, e.value['title'], MediaItem.fromJson(e.value['item']))], 0),
                    ),
                  ),
              ]
            ),
            for (final (title, k, rating) in [
              (tr('Neu: Filme'), Kind.movie, false),
              (tr('Neu: Serien'), Kind.series, false),
              (tr('Top bewertet'), Kind.movie, true),
            ])
              (
                title,
                k,
                [
                  for (final m in _top(k, rating: rating))
                    _sized(k, MediaTile(source: source, item: m, onTap: () => openItem(context, source, m))),
                ]
              ),
            (
              tr('Zuletzt gesehene Sender'),
              Kind.live,
              [
                for (final m in store.recentLive(source))
                  _sized(Kind.live, MediaTile(source: source, item: m, onTap: () => openItem(context, source, m, siblings: store.recentLive(source)))),
              ]
            ),
            for (final k in Kind.values)
              (
                tr('Favoriten · {0}', [{Kind.live: tr('Live'), Kind.movie: tr('Filme'), Kind.series: tr('Serien')}[k]]),
                k,
                [
                  for (final m in store.favsOf(source, k))
                    _sized(
                        k,
                        MediaTile(
                            source: source,
                            item: m,
                            onTap: () =>
                                openItem(context, source, m, siblings: k == Kind.live ? store.favsOf(source, k) : null))),
                ]
              ),
          ].where((r) => r.$3.isNotEmpty).toList();

          final dl = Padding(
            padding: const EdgeInsets.only(top: 12, right: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Pill(tr('Downloads · {0}', [downloads.items.length]),
                  icon: Icons.download_rounded,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadsScreen()))),
            ),
          );
          if (rows.isEmpty) {
            if (!isWide(context)) return ListView(padding: const EdgeInsets.only(left: 24), children: [dl, const SizedBox(height: 120), _emptyMine]);
            return Center(child: _emptyMine);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 0, 32),
            children: [
              if (!isWide(context)) dl,
              for (final (title, kind, tiles) in rows) ...[
                SectionTitle(title,
                    trailing: title == tr('Weiterschauen')
                        ? Padding(
                            padding: const EdgeInsets.only(right: 20),
                            child: Pill(tr('Verlauf löschen'), icon: Icons.delete_outline, onTap: store.clearHistory),
                          )
                        : null),
                SizedBox(
                  height: kind == Kind.live ? 176 : 296,
                  child: FocusTraversalGroup(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      clipBehavior: Clip.none,
                      padding: const EdgeInsets.only(right: 24, top: 6),
                      itemCount: tiles.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 16),
                      itemBuilder: (_, i) => tiles[i],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      );

  Widget _sized(Kind k, Widget child) =>
      SizedBox(width: k == Kind.live ? 200 : 140, height: k == Kind.live ? 170 : 290, child: child);
}

// ---------------- Suche ----------------

class SearchView extends StatefulWidget {
  final Source source;
  final Library lib;
  const SearchView({super.key, required this.source, required this.lib});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _ctrl = TextEditingController();
  final _field = FocusNode();
  Timer? _debounce;
  Kind? _only; // Filter: nur Live/Filme/Serien
  Map<Kind, List<MediaItem>> _results = {};
  bool _remoteBusy = false;
  // Namen einmal normalisieren statt bei jedem Tastendruck
  late final Map<Kind, List<(String, MediaItem)>> _index = {
    for (final k in Kind.values)
      k: [
        for (final m in widget.lib.of(k))
          if (!store.hideAdult || !isAdult(m.group)) (normalize(m.name), m),
      ],
  };

  @override
  void initState() {
    super.initState();
    // TV: Fokus erst aufs Feld legen; Tastatur öffnet sich mit OK
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && formFactor(context) != Ff.tv) _field.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _field.dispose();
    super.dispose();
  }

  List<String> get _recent => store.get('recentSearches', '').split('\n').where((x) => x.isNotEmpty).toList();

  void _remember(String q) {
    q = q.trim();
    if (q.length < 2) return;
    store.set('recentSearches', ([q, ..._recent.where((x) => x != q)].take(10)).join('\n'));
  }

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () => _run(q));
  }

  void _run(String q) {
    final n = normalize(q);
    if (n.isEmpty) return setState(() => _results = {});
    final words = n.split(' ');
    final res = <Kind, List<MediaItem>>{};
    for (final k in Kind.values) {
      final starts = <MediaItem>[], contains = <MediaItem>[];
      for (final (name, m) in _index[k]!) {
        if (!words.every(name.contains)) continue;
        (name.startsWith(n) ? starts : contains).add(m);
        if (starts.length + contains.length >= 300) break;
      }
      res[k] = [...starts, ...contains]; // Treffer am Wortanfang zuerst
    }
    setState(() => _results = res);
    // Stalker: Filme/Serien sind nicht vorgeladen, daher beim Portal suchen
    final remote = widget.lib.search;
    if (remote != null && n.length >= 2) {
      setState(() => _remoteBusy = true);
      Future.wait([remote(Kind.movie, q), remote(Kind.series, q)]).then((r) {
        if (!mounted || _ctrl.text != q) return;
        setState(() {
          _results = {..._results, Kind.movie: r[0], Kind.series: r[1]};
          _remoteBusy = false;
        });
      }).catchError((_) {
        if (mounted) setState(() => _remoteBusy = false);
      });
    }
  }

  void _apply(String q) {
    _ctrl.text = q;
    _run(q);
  }

  static Map<Kind, String> get _names => {Kind.live: tr('Live'), Kind.movie: tr('Filme'), Kind.series: tr('Serien')};

  @override
  Widget build(BuildContext context) {
    final sections = _results.entries.where((e) => e.value.isNotEmpty && (_only == null || e.key == _only)).toList();
    final total = _results.values.fold(0, (a, l) => a + l.length);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 24, 8),
        child: InputBox(
          controller: _ctrl,
          focusNode: _field,
          onChanged: _search,
          onSubmitted: (q) {
            _remember(q);
            _run(q);
          },
          style: const TextStyle(fontSize: 18),
          decoration: InputDecoration(
            hintText: tr('Sender, Filme, Serien …'),
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _remoteBusy
                ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : (_ctrl.text.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => _apply(''))),
          ),
        ),
      ),
      if (_results.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            Pill(tr('Alle · {0}', [total]), selected: _only == null, onTap: () => setState(() => _only = null)),
            for (final k in Kind.values)
              if (_results[k]?.isNotEmpty == true)
                Pill('${_names[k]} · ${_results[k]!.length}', selected: _only == k, onTap: () => setState(() => _only = k)),
          ]),
        ),
      Expanded(
        child: _ctrl.text.isEmpty
            ? ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
                if (_recent.isNotEmpty) ...[
                  SectionTitle(tr('Zuletzt gesucht')),
                  // "Leeren" zuletzt, damit die Fernbedienung zuerst auf den Suchbegriffen landet
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final q in _recent) Pill(q, icon: Icons.history_rounded, onTap: () => _apply(q)),
                    Pill(tr('Leeren'), icon: Icons.close_rounded, onTap: () => store.set('recentSearches', '')),
                  ]),
                ] else
                  Padding(
                    padding: EdgeInsets.only(top: 60),
                    child: Text(tr('Suche nach Sendern, Filmen und Serien.'),
                        textAlign: TextAlign.center, style: TextStyle(color: textDim)),
                  ),
              ])
            : sections.isEmpty
                ? Center(child: Text(_remoteBusy ? tr('Suche …') : tr('Nichts gefunden'), style: const TextStyle(color: textDim)))
                : _only != null
                    ? MediaGrid(source: widget.source, items: _results[_only]!)
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 0, 30),
                        children: [
                          for (final e in sections) ...[
                            SectionTitle('${_names[e.key]} (${e.value.length})'),
                            SizedBox(
                              height: e.key == Kind.live ? 176 : 296,
                              child: FocusTraversalGroup(
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  clipBehavior: Clip.none,
                                  padding: const EdgeInsets.only(right: 24, top: 6),
                                  itemCount: e.value.length,
                                  separatorBuilder: (_, _) => const SizedBox(width: 16),
                                  itemBuilder: (c, i) => SizedBox(
                                    width: e.key == Kind.live ? 200 : 140,
                                    height: e.key == Kind.live ? 170 : 290,
                                    child: MediaTile(
                                      source: widget.source,
                                      item: e.value[i],
                                      onTap: () {
                                        _remember(_ctrl.text);
                                        openItem(c, widget.source, e.value[i], siblings: e.key == Kind.live ? e.value : null);
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
      ),
    ]);
  }
}


/// Handy: alles, was auf TV/PC in der Seitenleiste steht, plus Sprache direkt wählbar.
class MoreView extends StatelessWidget {
  final Source source;
  final bool hasGuide;
  final ValueChanged<Tab> onTab;
  const MoreView({super.key, required this.source, required this.hasGuide, required this.onTab});

  Widget _item(BuildContext c, IconData icon, String title, String? sub, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Tap(
          fill: true,
          scale: 1,
          radius: 14,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            color: surface,
            child: Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: store.accent.withValues(alpha: .16), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: store.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  if (sub != null) Text(sub, style: const TextStyle(color: textDim, fontSize: 13)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: textDim),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _item(context, Icons.search_rounded, tr('Suche'), tr('Sender, Filme, Serien …'), () => onTab(Tab.search)),
          if (hasGuide) _item(context, Icons.view_agenda_rounded, tr('TV-Guide'), tr('Was läuft, Rückschau'), () => onTab(Tab.guide)),
          _item(context, Icons.download_rounded, tr('Downloads'), tr('{0} Dateien · {1}', [downloads.items.length, fmtBytes(downloads.usedBytes)]),
              () => onTab(Tab.downloads)),
          _item(context, Icons.translate_rounded, tr('Sprache'), languages[store.get('lang', 'system')], () async {
            final l = await pick(context, tr('Sprache'), Map<String, String>.from(languages), current: store.get('lang', 'system'));
            if (l != null) store.set('lang', l);
          }),
          _item(context, Icons.palette_outlined, tr('Akzentfarbe'), hexColor(store.accent),
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
          _item(context, Icons.tune_rounded, tr('Einstellungen'), tr('Wiedergabe, Kindersicherung, Daten …'),
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
          _item(context, Icons.swap_horiz_rounded, tr('Server wechseln'), source.name, () => Navigator.pop(context)),
        ],
      );
}
