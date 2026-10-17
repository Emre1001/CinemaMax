import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../i18n.dart';
import '../errors.dart';
import '../links.dart';
import '../models.dart';
import '../repo.dart';
import '../store.dart';
import '../update.dart';
import 'browse.dart';
import 'common.dart';
import 'downloads_view.dart';
import 'player.dart';
import 'settings.dart';
import 'tv_link_ui.dart';

const iptvCountries = {
  'de': 'Deutschland', 'at': 'Österreich', 'ch': 'Schweiz', 'tr': 'Türkei', 'uk': 'Großbritannien',
  'us': 'USA', 'fr': 'Frankreich', 'it': 'Italien', 'es': 'Spanien', 'nl': 'Niederlande',
  'pl': 'Polen', 'gr': 'Griechenland', 'rs': 'Serbien', 'hr': 'Kroatien', 'ba': 'Bosnien',
  'al': 'Albanien', 'ru': 'Russland', 'ua': 'Ukraine', 'ar': 'Arabisch', 'in': 'Indien', 'all': 'Alle Länder',
};

Source iptvSource() {
  final cc = store.get('iptvCountry', 'de');
  return Source(
    id: 'iptv-$cc',
    name: 'IPTV · ${tr(iptvCountries[cc] ?? cc)}',
    type: SourceType.iptv,
    url: cc == 'all'
        ? 'https://iptv-org.github.io/iptv/index.m3u'
        : cc == 'ar'
            ? 'https://iptv-org.github.io/iptv/languages/ara.m3u'
            : 'https://iptv-org.github.io/iptv/countries/$cc.m3u',
  );
}

void openSource(BuildContext c, Source s, {bool replace = false}) {
  store.set('lastMode', s.type == SourceType.iptv ? 'iptv' : 'own');
  store.set('lastSource', s.id);
  final route = MaterialPageRoute(builder: (_) => BrowseScreen(source: s));
  replace ? Navigator.pushReplacement(c, route) : Navigator.push(c, route);
}

/// Quelle für direkt geöffnete Links (nicht gespeichert).
final linkSource = Source(id: 'link', name: 'Link', type: SourceType.m3u, url: '');

/// Externer Link: Playlist/Xtream als Server anlegen, Stream oder Datei direkt abspielen.
Future<void> openLink(BuildContext c, String raw) async {
  final link = extractLink(raw);
  if (link == null) return toast(c, tr('Kein Link erkannt: {0}', [raw]));
  toast(c, tr('Link wird geprüft …'));
  final kind = await probeLink(link);
  if (!c.mounted) return;
  // Laufenden Player schließen, statt einen zweiten darüber zu öffnen
  Navigator.popUntil(c, (r) => r.settings.name != PlayerScreen.route);
  switch (kind) {
    case LinkKind.xtream || LinkKind.playlist:
      var url = link;
      if (link.startsWith('content://')) {
        // Freigabe gilt nur kurz: Playlist in den App-Speicher kopieren
        try {
          final text = await Links.readContent(link, 64 << 20);
          final f = File('${(await getApplicationSupportDirectory()).path}/playlist_${DateTime.now().millisecondsSinceEpoch}.m3u');
          await f.writeAsString(text);
          url = f.path;
        } catch (e) {
          if (c.mounted) toast(c, tr('Fehler: {0}', [explain(e)]));
          return;
        }
      }
      if (!c.mounted) return;
      Navigator.push(c, MaterialPageRoute(builder: (_) => SourceEditor(prefill: url, prefillName: linkTitle(link))));
    case LinkKind.vod || LinkKind.live:
      final item = MediaItem(
        id: link,
        name: linkTitle(link),
        kind: kind == LinkKind.vod ? Kind.movie : Kind.live,
        group: tr('Externer Link'),
        url: link,
      );
      PlayerScreen.open(c, linkSource, [PlayItem(link, item.name, item)], 0);
  }
}

/// Dialog „Link öffnen“, mit Link aus der Zwischenablage vorbelegt.
Future<void> askLink(BuildContext c) async {
  final clip = await Clipboard.getData(Clipboard.kTextPlain).catchError((_) => null);
  final ctrl = TextEditingController(text: extractLink(clip?.text ?? '') ?? '');
  if (!c.mounted) return;
  final v = await showDialog<String>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(tr('Link öffnen')),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          dpadField(TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(hintText: 'http://…'),
            onSubmitted: (v) => Navigator.pop(d, v),
          )),
          const SizedBox(height: 10),
          Text(tr('Stream, Video oder Playlist (M3U, Xtream get.php)'), style: const TextStyle(color: textDim, fontSize: 13)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Abbrechen'))),
        FilledButton(onPressed: () => Navigator.pop(d, ctrl.text), child: Text(tr('Öffnen'))),
      ],
    ),
  );
  ctrl.dispose();
  if (v != null && v.trim().isNotEmpty && c.mounted) await openLink(c, v);
}

/// Startbildschirm: Auswahl IPTV oder eigene Playlist (M3U / Xtream).
class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  /// App-Sperre: PIN beim Start abfragen, danach ggf. letzte Quelle öffnen.
  Future<void> _unlock() async {
    final pin = store.get('pin', '');
    while (pin.isNotEmpty && store.get('pinOnStart', false) && mounted) {
      final c = TextEditingController();
      final v = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (d) => AlertDialog(
          title: Text(tr('PIN eingeben')),
          content: dpadField(TextField(
            controller: c,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            onSubmitted: (v) => Navigator.pop(d, v),
          )),
          actions: [FilledButton(onPressed: () => Navigator.pop(d, c.text), child: Text(tr('OK')))],
        ),
      );
      if (v == pin) break;
    }
    if (!mounted) return;
    // Externe Links erst nach der PIN-Abfrage öffnen
    Links.pending.addListener(_onLink);
    Links.pending.value != null ? _onLink() : _autoOpen();
    checkForUpdate(context);
  }

  void _onLink() {
    final l = Links.pending.value;
    if (l == null || !mounted) return;
    Links.pending.value = null;
    openLink(context, l);
  }

  @override
  void dispose() {
    Links.pending.removeListener(_onLink);
    super.dispose();
  }

  void _autoOpen() {
    if (!store.get('askOnStart', true)) {
      final mode = store.get('lastMode', '');
      final last = store.sources.where((s) => s.id == store.get('lastSource', '')).firstOrNull;
      if (mode == 'iptv') openSource(context, last ?? iptvSource());
      if (mode == 'own' && last != null) openSource(context, last);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 640;
    final cards = [
      _ModeCard(
        autofocus: true,
        icon: Icons.satellite_alt_rounded,
        title: tr('IPTV'),
        text: tr('Freie Live-Sender aus aller Welt\nund eigene IPTV-Listen.'),
        foot: tr('{0} Listen', [store.sources.where((s) => s.type == SourceType.iptv).length + 1]),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SourcesScreen(iptv: true)))
            .then((_) => setState(() {})),
      ),
      _ModeCard(
        icon: Icons.dns_rounded,
        title: tr('M3U / Xtream / Stalker'),
        text: tr('Playlist, Xtream-Codes oder Stalker-Portal.\nLive, Filme und Serien.'),
        foot: tr('{0} Server gespeichert', [store.sources.where((s) => s.type != SourceType.iptv).length]),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SourcesScreen()))
            .then((_) => setState(() {})),
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: wide ? 56 : 20, vertical: 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Wordmark(),
              const Spacer(),
              Tap(
                radius: 100,
                onTap: () => askLink(context),
                child: Tooltip(
                  message: tr('Link öffnen'),
                  child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.link_rounded)),
                ),
              ),
              const SizedBox(width: 4),
              // Downloads auch ohne Internet erreichbar
              Tap(
                radius: 100,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadsScreen())),
                child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.download_rounded)),
              ),
              const SizedBox(width: 4),
              Tap(
                radius: 100,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))
                    .then((_) => setState(() {})),
                child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.tune_rounded)),
              ),
            ]),
            const Spacer(),
            Text(tr('Was möchtest du schauen?'),
                style: TextStyle(fontSize: wide ? 34 : 26, fontWeight: FontWeight.w800, letterSpacing: -1)),
            const SizedBox(height: 24),
            wide
                ? IntrinsicHeight(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: cards[0]),
                      const SizedBox(width: 20),
                      Expanded(child: cards[1]),
                    ]),
                  )
                : Column(children: [cards[0], const SizedBox(height: 14), cards[1]]),
            const Spacer(flex: 2),
          ]),
        ),
      ),
    );
  }
}

class Wordmark extends StatelessWidget {
  final bool compact; // nur das Akzent-Zeichen
  const Wordmark({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 10,
          height: 22,
          decoration: BoxDecoration(color: store.accent, borderRadius: BorderRadius.circular(3)),
        ),
        if (!compact) const SizedBox(width: 10),
        if (!compact)
          Text(tr('CinemaMax'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -.6)),
      ]);
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title, text, foot;
  final VoidCallback onTap;
  final bool autofocus;

  const _ModeCard(
      {required this.icon,
      required this.title,
      required this.text,
      required this.foot,
      required this.onTap,
      this.autofocus = false});

  @override
  Widget build(BuildContext context) => Tap(
        autofocus: autofocus,
        onTap: onTap,
        radius: 18,
        scale: 1.03,
        child: Container(
          padding: const EdgeInsets.all(26),
          decoration: BoxDecoration(color: surface, border: Border.all(color: line), borderRadius: BorderRadius.circular(18)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 34, color: store.accent),
            const SizedBox(height: 22),
            Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -.6)),
            const SizedBox(height: 8),
            Text(text, style: const TextStyle(color: textDim, fontSize: 15, height: 1.4)),
            const SizedBox(height: 22),
            Row(children: [
              Text(foot, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              const Icon(Icons.arrow_forward_rounded, size: 20),
            ]),
          ]),
        ),
      );
}

// ---------------- Serverauswahl ----------------

/// Serverliste. [iptv]: IPTV-Listen (iptv-org + eigene), sonst M3U/Xtream/Stalker.
class SourcesScreen extends StatefulWidget {
  final bool iptv;
  const SourcesScreen({super.key, this.iptv = false});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  Future<void> _edit([Source? s, bool receive = false]) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => SourceEditor(source: s, iptv: widget.iptv, receive: receive)));
    setState(() {});
  }

  Future<void> _menu(Source s) async {
    final builtin = s.id.startsWith('iptv-');
    final a = await pick(context, s.name, {
      'open': tr('Öffnen'),
      'refresh': tr('Neu laden (Cache ignorieren)'),
      if (builtin) 'country': tr('Land wählen'),
      if (!builtin) 'epg': tr('EPG-URL festlegen'),
      if (!builtin) ...{
        'send': tr('An anderes Gerät senden'),
        'edit': tr('Bearbeiten'),
        'up': tr('Nach oben'),
        'delete': tr('Löschen'),
      },
    });
    if (!mounted) return;
    switch (a) {
      case 'epg':
        final c = TextEditingController(text: store.get('epgUrl_${s.id}', ''));
        final v = await showDialog<String>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text(tr('EPG-URL (XMLTV, auch .gz)')),
            content: SizedBox(
              width: 520,
              child: dpadField(TextField(controller: c, autofocus: true, keyboardType: TextInputType.url, onSubmitted: (v) => Navigator.pop(d, v))),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, ''), child: Text(tr('Entfernen'))),
              FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('OK')),
            ],
          ),
        );
        if (v != null) store.set('epgUrl_${s.id}', v);
      case 'country':
        final cc = await pick(context, tr('Land'), {for (final e in iptvCountries.entries) e.key: tr(e.value)}, current: store.get('iptvCountry', 'de'));
        if (cc != null) setState(() => store.set('iptvCountry', cc));
      case 'open': openSource(context, s);
      case 'refresh':
        toast(context, tr('Lade {0} …', [s.name]));
        try {
          await Repo.load(s, force: true);
          if (mounted) toast(context, tr('Aktualisiert'));
        } catch (e) {
          if (mounted) toast(context, tr('Fehler: {0}', [explain(e)]));
        }
      case 'send': sendServer(context, s);
      case 'edit': _edit(s);
      case 'up':
        // Vor den vorherigen Eintrag derselben Liste schieben
        final i = store.sources.indexOf(s);
        final prev = store.sources.lastIndexWhere((x) => (x.type == SourceType.iptv) == widget.iptv, i - 1);
        if (prev >= 0) setState(() => store.moveSource(i, prev));
      case 'delete':
        final ok = await pick(context, tr('„{0}“ wirklich löschen?', [s.name]), {false: tr('Abbrechen'), true: tr('Löschen')});
        if (ok == true) setState(() => store.removeSource(s));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final list = [
      if (widget.iptv) iptvSource(),
      ...store.sources.where((s) => (s.type == SourceType.iptv) == widget.iptv),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: bg,
        title: Text(widget.iptv ? tr('IPTV-Liste wählen') : tr('Server wählen'), style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: EdgeInsets.symmetric(horizontal: wide ? 48 : 16, vertical: 8),
        children: [
          for (final (i, s) in list.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _SourceTile(
                key: ValueKey('${s.id}${s.name}'),
                source: s,
                autofocus: i == 0,
                onTap: () => openSource(context, s),
                onMenu: () => _menu(s),
              ),
            ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              Pill(widget.iptv ? tr('Eigene IPTV-Liste hinzufügen') : tr('Server hinzufügen'),
                  icon: Icons.add, primary: true, autofocus: list.isEmpty, onTap: () => _edit()),
              // Zugangsdaten vom Handy oder von Freunden, ohne Tippen mit der Fernbedienung
              Pill(tr('Per Code empfangen'), icon: Icons.qr_code_2_rounded, onTap: () => _edit(null, true)),
            ]),
          ),
          if (list.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: 18),
              child: Text(tr('Lange drücken oder Menü-Taste für Optionen.'), style: TextStyle(color: textDim)),
            ),
        ],
      ),
    );
  }
}

class _SourceTile extends StatefulWidget {
  final Source source;
  final VoidCallback onTap, onMenu;
  final bool autofocus;
  const _SourceTile(
      {super.key, required this.source, required this.onTap, required this.onMenu, this.autofocus = false});

  @override
  State<_SourceTile> createState() => _SourceTileState();
}

class _SourceTileState extends State<_SourceTile> {
  String? _info;

  @override
  void initState() {
    super.initState();
    final s = widget.source;
    if (s.type == SourceType.xtream) {
      Repo.xtreamAccount(s).then((u) {
        if (!mounted) return;
        final exp = int.tryParse('${u['exp_date']}');
        final date = exp == null
            ? tr('unbegrenzt')
            : MaterialLocalizations.of(context).formatShortDate(DateTime.fromMillisecondsSinceEpoch(exp * 1000));
        {
          setState(() => _info = tr('{0} · bis {1} · {2}/{3} Verbindungen', [u['status'], date, u['active_cons'], u['max_connections']]));
        }
      }).catchError((_) {
        if (mounted) setState(() => _info = tr('Nicht erreichbar'));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.source;
    return Tap(
      autofocus: widget.autofocus,
      onTap: widget.onTap,
      onLongPress: widget.onMenu,
      scale: 1.02,
      radius: 14,
      child: Container(
        padding: EdgeInsets.all(18),
        color: surface,
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(color: surface2, borderRadius: BorderRadius.circular(12)),
            child: Icon(
                switch (s.type) {
                  SourceType.xtream => Icons.vpn_key_rounded,
                  SourceType.stalker => Icons.router_rounded,
                  SourceType.iptv => Icons.satellite_alt_rounded,
                  SourceType.m3u => Icons.list_alt_rounded,
                },
                color: store.accent),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.name, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              SizedBox(height: 3),
              Text(
                '${_typeLabel[s.type]} · ${(Uri.tryParse(s.url)?.host ?? '').isEmpty ? s.url : Uri.parse(s.url).host}${s.type == SourceType.stalker ? ' · ${s.mac}' : ''}'
                '${_info == null ? '' : '\n$_info'}',
                style: TextStyle(color: textDim, fontSize: 13, height: 1.4),
              ),
            ]),
          ),
          ExcludeFocus(child: IconButton(onPressed: widget.onMenu, icon: Icon(Icons.more_vert))),
        ]),
      ),
    );
  }
}

const _typeLabel = {
  SourceType.xtream: 'Xtream',
  SourceType.m3u: 'M3U',
  SourceType.stalker: 'Stalker',
  SourceType.iptv: 'IPTV',
};

// ---------------- Server anlegen / bearbeiten ----------------

final _macRe = RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$');

/// „00-1a-79-12-34-56“, „001A79123456“ … wird zu „00:1A:79:12:34:56“.
String normalizeMac(String v) {
  final hex = v.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
  if (hex.length != 12) return v.trim().toUpperCase();
  return [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join(':');
}

/// Xtream-Zugang aus einem get.php- oder player_api.php-Link (Pfad davor bleibt erhalten).
({String host, String user, String pass})? xtreamFromUrl(Uri u) {
  final q = u.queryParameters;
  final file = u.pathSegments.isEmpty ? '' : u.pathSegments.last;
  if (!const {'get.php', 'player_api.php'}.contains(file) || q['username'] == null) return null;
  return (host: '${u.origin}${u.path.substring(0, u.path.lastIndexOf('/'))}', user: q['username']!, pass: q['password'] ?? '');
}

class SourceEditor extends StatefulWidget {
  final Source? source;
  final bool iptv;
  /// Von außen geöffneter Playlist-Link: vorbelegt, nach dem Speichern direkt öffnen.
  final String? prefill, prefillName;
  /// Gleich den QR-Code zum Empfangen zeigen.
  final bool receive;
  const SourceEditor({super.key, this.source, this.iptv = false, this.prefill, this.prefillName, this.receive = false});

  @override
  State<SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<SourceEditor> {
  late SourceType _type = widget.source?.type ??
      (widget.iptv ? SourceType.iptv : (widget.prefill != null ? SourceType.m3u : SourceType.xtream));
  late final _name = TextEditingController(text: widget.source?.name ?? widget.prefillName);
  late final _url = TextEditingController(text: widget.source?.url ?? widget.prefill);
  late final _user = TextEditingController(text: widget.source?.user);
  late final _pass = TextEditingController(text: widget.source?.pass);
  late final _mac = TextEditingController(text: widget.source?.mac);
  bool _busy = false, _showPass = false;

  @override
  void initState() {
    super.initState();
    if (widget.receive) WidgetsBinding.instance.addPostFrameCallback((_) => _receive());
  }

  /// Prüft, verbindet und speichert. Rückgabe: Fehlertext, null = gespeichert.
  Future<String?> _save() async {
    String? fail(String m) {
      if (mounted) toast(context, m);
      return m;
    }

    var url = _url.text.trim();
    var type = _type;
    var user = _user.text.trim(), pass = _pass.text.trim();
    final mac = normalizeMac(_mac.text);
    if (url.isEmpty) return fail(tr('URL fehlt'));
    if (type == SourceType.stalker && !_macRe.hasMatch(mac)) return fail(tr('MAC-Adresse ungültig (Format 00:1A:79:XX:XX:XX)'));
    // Ohne Schema: http ergänzen (nicht bei Dateien und rtmp/… -Links)
    if (!url.contains('://') && localPath(url) == null) url = 'http://$url';
    // get.php-Links sind Xtream-Zugänge: als Xtream speichern (Filme/Serien/EPG besser).
    // Im Xtream-Feld eingefügte get.php-/player_api.php-Links: Zugangsdaten übernehmen.
    final u = Uri.tryParse(url);
    final m3uUrl = url;
    final xt = u == null ? null : xtreamFromUrl(u);
    if (xt != null && (type == SourceType.m3u || type == SourceType.xtream)) {
      if (type == SourceType.m3u || user.isEmpty) (user, pass) = (xt.user, xt.pass);
      type = SourceType.xtream;
      url = xt.host;
    }
    final s = Source(
      id: widget.source?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim().isNotEmpty
          ? _name.text.trim()
          : (u?.host.isNotEmpty ?? false)
          ? u!.host
          : tr('Server'),
      type: type,
      url: url,
      user: user,
      pass: pass,
      mac: type == SourceType.stalker ? mac : '',
    );
    setState(() => _busy = true);
    try {
      if (type == SourceType.xtream) {
        try {
          await Repo.xtreamAccount(s);
        } catch (_) {
          // Manche Anbieter erlauben nur die Playlist (get.php), nicht die Xtream-API: dann als M3U
          if (_type != SourceType.m3u) rethrow;
          s
            ..type = SourceType.m3u
            ..url = m3uUrl
            ..user = ''
            ..pass = '';
        }
      }
      await Repo.load(s, force: true);
      store.saveSource(s);
      if (mounted) widget.prefill != null ? openSource(context, s, replace: true) : Navigator.pop(context);
      return null;
    } catch (e) {
      return fail(tr('Verbindung fehlgeschlagen: {0}', [explain(e)]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Daten per Code/QR empfangen (Handy, PC oder ein Freund irgendwo), dann direkt verbinden
  /// und dem Absender das Ergebnis melden.
  Future<void> _receive() async {
    final got = await receiveServer(context);
    if (got == null || !mounted) return;
    final d = got.data;
    setState(() {
      if (!widget.iptv) _type = SourceType.values.asNameMap()['${d['type']}'] ?? _type;
      if ('${d['name'] ?? ''}'.trim().isNotEmpty) _name.text = '${d['name']}'.trim();
      _url.text = '${d['url'] ?? ''}'.trim();
      _user.text = '${d['user'] ?? ''}'.trim();
      _pass.text = '${d['pass'] ?? ''}';
      _mac.text = '${d['mac'] ?? ''}'.trim();
    });
    toast(context, tr('Daten empfangen, verbinde …'));
    final error = await _save();
    await got.link
        .send({'k': 'status', 'state': error == null ? 'ok' : 'error', 'text': error})
        .catchError((_) {});
  }

  Widget _field(TextEditingController c, String label, {bool secret = false, TextInputType? type, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: InputBox(
          controller: c,
          secret: secret && !_showPass,
          keyboardType: type,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            suffixIcon: secret
                ? IconButton(
                    icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showPass = !_showPass),
                  )
                : null,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final what = widget.iptv ? tr('IPTV-Liste') : tr('Server');
    return Scaffold(
      appBar: AppBar(backgroundColor: bg, title: Text(widget.source == null ? tr('{0} hinzufügen', [what]) : tr('{0} bearbeiten', [what]))),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 560),
          child: ListView(padding: EdgeInsets.all(20), children: [
            if (!widget.iptv) ...[
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final (i, t) in [SourceType.xtream, SourceType.m3u, SourceType.stalker].indexed)
                  Pill(
                    {SourceType.xtream: tr('Xtream Codes'), SourceType.m3u: tr('M3U-Link'), SourceType.stalker: tr('Stalker-Portal')}[t]!,
                    selected: _type == t,
                    autofocus: i == 0 && widget.prefill == null,
                    onTap: () => setState(() => _type = t),
                  ),
              ]),
              const SizedBox(height: 20),
            ],
            _field(_name, tr('Name (optional)')),
            _field(
                _url,
                switch (_type) {
                  SourceType.xtream => tr('Server-URL (http://host:port)'),
                  SourceType.stalker => tr('Portal-URL (http://host:port/c/)'),
                  _ => tr('M3U-URL'),
                },
                type: TextInputType.url),
            if (_type == SourceType.xtream) ...[
              _field(_user, tr('Benutzername')),
              _field(_pass, tr('Passwort'), secret: true),
            ],
            if (_type == SourceType.stalker) _field(_mac, tr('MAC-Adresse'), hint: '00:1A:79:XX:XX:XX'),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: _busy
                  ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())
                  : Wrap(spacing: 10, runSpacing: 10, children: [
                      Pill(tr('Verbinden & speichern'), icon: Icons.check, primary: true, autofocus: widget.iptv || widget.prefill != null, onTap: _save),
                      // Tippen mit der Fernbedienung ist mühsam
                      Pill(tr('Per Code empfangen'), icon: Icons.qr_code_2_rounded, onTap: _receive),
                    ]),
            ),
            const SizedBox(height: 16),
            Text(
              switch (_type) {
                SourceType.iptv => tr('Beliebiger M3U-Link mit Live-Sendern, z. B. eine eigene oder geteilte IPTV-Liste.'),
                SourceType.stalker => tr('Die MAC-Adresse muss beim Anbieter freigeschaltet sein.'),
                _ => tr('Tipp: Ein get.php-Link mit username/password wird automatisch als Xtream-Zugang gespeichert.'),
              },
              style: const TextStyle(color: textDim, fontSize: 13),
            ),
          ]),
        ),
      ),
    );
  }
}
