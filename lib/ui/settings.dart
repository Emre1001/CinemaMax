import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../downloads.dart';
import '../external_player.dart';
import '../i18n.dart';
import '../playback.dart';

import '../repo.dart';
import '../store.dart';
import '../update.dart';
import 'common.dart';
import 'fx.dart';
import 'setup.dart';
import 'start.dart';

/// Eine Einstellung: ohne [options] ein Schalter, sonst eine Auswahl.
class _Opt {
  final String key, label;
  final String? hint;
  final Object def;
  final Map<Object, String>? options;
  final bool Function()? visible;
  const _Opt(this.key, this.label, this.def, {this.options, this.hint, this.visible});
}

const _langs = {
  '': 'Automatisch',
  'de,deu,ger': 'Deutsch',
  'en,eng': 'Englisch',
  'tr,tur': 'Türkisch',
  'fr,fra,fre': 'Französisch',
  'es,spa': 'Spanisch',
  'it,ita': 'Italienisch',
  'ar,ara': 'Arabisch',
  'ru,rus': 'Russisch',
  'pl,pol': 'Polnisch',
  'sr,srp,hr,hrv,bs,bos': 'Serbisch/Kroatisch/Bosnisch',
};

final _desktop = Platform.isLinux || Platform.isWindows;

/// Akzentfarben zur Auswahl (Einstellungen und Einrichtung).
const accentColors = <Object, String>{
  0xFF3E8BFF: 'Blau',
  0xFF2563EB: 'Königsblau',
  0xFF00B2CC: 'Cyan',
  0xFF14B8A6: 'Türkis',
  0xFF30A46C: 'Grün',
  0xFFE5A23A: 'Bernstein',
  0xFFE5484D: 'Rot',
  0xFFE93D82: 'Pink',
  0xFF8E4EC6: 'Violett',
  0xFFEDEDED: 'Weiß',
};

/// Kategorie der Einstellungen: Einträge sind [_Opt] (Schalter/Auswahl) oder [_Act] (Aktion).
class _Cat {
  final String title, summary;
  final IconData icon;
  final List<Object> items;
  const _Cat(this.title, this.summary, this.icon, this.items);
}

/// Aktion mit wechselndem Hinweis (z. B. Anzahl) und optionalem Schalter-Zustand.
class _Act {
  final String key, label;
  final String? Function()? hint;
  final bool? Function()? toggle;
  const _Act(this.key, this.label, {this.hint, this.toggle});
}

// Getter: die erkannte Bildschirmauflösung steht in der aktuellen Sprache im Text
List<_Cat> get _cats => [
  _Cat('Darstellung', 'Sprache, Hell/Dunkel, Farbe, Oberfläche', Icons.palette_outlined, [
    _Opt('lang', 'Sprache', 'system', options: Map<Object, String>.from(languages)),
    const _Opt('theme', 'Erscheinungsbild', 'system',
        hint: 'Hell, dunkel oder wie das Gerät', options: {'system': 'Wie das Gerät', 'dark': 'Dunkel', 'light': 'Hell'}),
    const _Opt('accent', 'Akzentfarbe', Store.defaultAccent,
        hint: 'Farbe der ganzen Oberfläche', options: {...accentColors, -1: 'Eigene Farbe …'}),
    const _Opt('layout', 'Oberfläche', 'auto',
        hint: 'Automatisch erkennt Handy, Tablet, TV und PC',
        options: {'auto': 'Automatisch', 'phone': 'Handy', 'tv': 'Fernseher', 'desktop': 'PC / Tablet'}),
    const _Opt('tileSize', 'Kachelgröße', 'M', options: {'S': 'Klein', 'M': 'Mittel', 'L': 'Groß'}),
    const _Opt('liveAsList', 'Live-Sender als Liste', false),
    const _Opt('logoBg', 'Hintergrund für Senderlogos', 'dark',
        hint: 'Hell macht dunkle Logos sichtbar', options: {'dark': 'Dunkel', 'light': 'Hell'}),
    const _Opt('showLogos', 'Logos und Poster laden', true, hint: 'Aus spart Datenvolumen'),
    const _Opt('clock', 'Uhr anzeigen', true),
    const _Opt('perf', 'Leistung', 'auto',
        hint: 'Schwache Geräte laufen mit weniger Effekten flüssiger',
        options: {
          'auto': 'Automatisch',
          'full': 'Alle Effekte',
          'lite': 'Flüssig (schwaches Gerät)',
          'speed': 'Speed (ohne Animationen und Effekte)',
        }),
    const _Opt('reduceMotion', 'Animationen reduzieren', false, hint: 'Für langsame TV-Boxen'),
  ]),
  _Cat('Player', 'ExoPlayer/mpv, Bildformat, Bedienung', Icons.play_circle_outline_rounded, [
    _Opt('engine', 'Player', 'exo',
        hint: 'ExoPlayer: schnell und stabil. mpv: mehr Formate und Untertitel',
        options: {'exo': 'ExoPlayer (empfohlen)', 'mpv': 'mpv'},
        visible: () => Platform.isAndroid),
    _Opt('extPlayer', 'Externer Player', '',
        hint: 'Alles in einem anderen Player abspielen (muss installiert sein). Einzeln: im Player unter „Mehr“',
        options: {
          '': 'Aus (eingebauter Player)',
          for (final e in ExternalPlayer.names.entries)
            if (Platform.isAndroid || ExternalPlayer.desktop.contains(e.key)) e.key: e.value,
        }),
    _Opt('autoMpv', 'Bei Fehlern anderen Player versuchen', true,
        hint: 'ExoPlayer und mpv springen füreinander ein (z. B. bei 4K oder DTS-Ton)',
        visible: () => Platform.isAndroid),
    _Opt('ffmpegAudio', 'FFmpeg-Tondecoder', 'on',
        hint: 'Spielt AC3, E-AC3, DTS und TrueHD auch ohne Decoder im Gerät',
        options: {'on': 'Wenn nötig (empfohlen)', 'prefer': 'Immer FFmpeg', 'off': 'Aus'},
        visible: () => Platform.isAndroid && store.get('engine', 'exo') == 'exo'),
    _Opt('surfaceView', 'Videoausgabe SurfaceView', isAndroidTv,
        hint: 'Echtes 4K und richtige HDR-Farben, schneller auf TV-Boxen (Fernseher: an)',
        visible: () => Platform.isAndroid && store.get('engine', 'exo') == 'exo'),
    const _Opt('hwdec', 'Hardware-Dekodierung', true, hint: 'Aus bei Bildfehlern oder grünem Bild'),
    const _Opt('bufferMb', 'Puffergröße', 64, options: {16: '16 MB', 32: '32 MB', 64: '64 MB', 128: '128 MB', 256: '256 MB'}),
    const _Opt('fit', 'Standard-Bildformat', 'contain', options: {'contain': 'Einpassen', 'original': 'Original (1:1)', 'cover': 'Zoomen', 'fill': 'Strecken', '169': '16:9', '43': '4:3'}),
    const _Opt('deinterlace', 'Deinterlacing', false, hint: 'Für ältere SD-/1080i-Sender'),
    const _Opt('hideSec', 'Bedienleiste ausblenden nach', 5, options: {3: '3 s', 5: '5 s', 8: '8 s', 12: '12 s'}),
    const _Opt('seekStep', 'Spulschritt', 10, options: {5: '5 s', 10: '10 s', 15: '15 s', 30: '30 s', 60: '60 s'}),
    const _Opt('remaining', 'Restzeit statt Gesamtdauer', false),
    _Opt('landscape', 'Auf Handy immer Querformat', true, visible: () => Platform.isAndroid),
    _Opt('autoFullscreen', 'Player im Vollbild starten', false, visible: () => _desktop),
    _Opt('autoPip', 'Bild-in-Bild beim Verlassen', true,
        hint: 'Video läuft im kleinen Fenster weiter', visible: () => Platform.isAndroid && !isAndroidTv),
  ]),
  _Cat('Live-TV', 'Senderwechsel, Neuverbinden, EPG', Icons.live_tv_rounded, [
    const _Opt('autoReconnect', 'Live automatisch neu verbinden', true),
    const _Opt('zapInvert', 'Senderwechsel umkehren', false, hint: 'Pfeil hoch = nächster Sender'),
    const _Opt('epg', 'Programmführer (EPG) laden', true, hint: 'Zeigt was läuft, TV-Guide und Rückschau'),
    const _Opt('liveFormat', 'Live-Format (Xtream)', 'ts', options: {'ts': 'MPEG-TS (.ts)', 'm3u8': 'HLS (.m3u8)'}),
  ]),
  _Cat('Filme & Serien', 'Fortsetzen, nächste Folge, Intro', Icons.movie_outlined, [
    const _Opt('resume', 'An letzter Stelle fortsetzen', true),
    const _Opt('autoNext', 'Nächste Folge automatisch', true),
    const _Opt('nextBefore', 'Nächste Folge anbieten', 30,
        hint: 'Sekunden vor dem Ende (Abspann)',
        options: {15: '15 s', 30: '30 s', 45: '45 s', 60: '60 s', 90: '90 s', 120: '2 min'}),
    const _Opt('nextCountdown', 'Countdown bis zur nächsten Folge', 10,
        options: {5: '5 s', 10: '10 s', 15: '15 s', 20: '20 s'}),
    const _Opt('introSkip', 'Intro überspringen', 85,
        hint: 'Knopf in den ersten Minuten einer Folge, springt so weit vor',
        options: {0: 'Aus', 60: '60 s', 75: '75 s', 85: '85 s', 90: '90 s', 120: '120 s'}),
    const _Opt('stillWatching', '„Schaust du noch?“ nach 3 Folgen', true, hint: 'Pausiert, wenn niemand mehr zuschaut'),
    _Opt('defaultRate', 'Standard-Tempo (Filme/Serien)', 1.0,
        options: {0.75: '0.75x', 1.0: '1x', 1.25: '1.25x', 1.5: '1.5x', 2.0: '2x'}),
  ]),
  _Cat('Ton & Untertitel', 'Sprachen, Untertitel, Lautstärke', Icons.subtitles_outlined, [
    const _Opt('audioLang', 'Bevorzugte Tonspur', 'de,deu,ger', options: _langs),
    const _Opt('subLang', 'Bevorzugte Untertitel', 'de,deu,ger', options: _langs),
    const _Opt('subsOn', 'Untertitel automatisch an', false),
    const _Opt('subSize', 'Untertitelgröße', 44, options: {32: 'Klein', 44: 'Mittel', 56: 'Groß', 68: 'Sehr groß'}),
    const _Opt('subBg', 'Untertitel-Hintergrund', false),
    const _Opt('normalize', 'Lautstärke angleichen', false, hint: 'Nachtmodus: leise Dialoge lauter'),
  ]),
  _Cat('Qualität & Daten', 'Auflösung, Downloads, Daten sparen', Icons.high_quality_outlined, [
    _Opt('maxRes', 'Bildschirmauflösung', -1,
        hint: 'Streams nie höher laden als der Bildschirm zeigt: spart Daten und Leistung. Kleiner wählen bei langsamem Internet',
        options: {
          -1: Engine.screenHeight > 0
              ? tr('Automatisch ({0})', [Engine.resolution(0, Engine.screenHeight)])
              : 'Automatisch',
          0: 'Keine Grenze (beste Qualität)',
          2160: '4K (2160p)',
          1440: '1440p (2K)',
          1080: '1080p (Full HD)',
          720: '720p (HD)',
          480: '480p',
          360: '360p',
          240: '240p',
          144: '144p',
        }),
    const _Opt('dlQuality', 'Download-Qualität', -1,
        hint: 'Kleinere Auflösung spart Speicher. Wählbar bei Streams mit mehreren Qualitäten (HLS); MP4/MKV gibt es nur in einer',
        options: {-1: 'Jedes Mal fragen', 0: 'Beste', 1080: '1080p', 720: '720p', 480: '480p (spart Speicher)', 360: '360p (sehr klein)'}),
  ]),
  _Cat('Inhalte & Quellen', 'Sortierung, Cache, User-Agent', Icons.list_alt_rounded, [
    const _Opt('sort', 'Sortierung', 'default', options: {
      'default': 'Wie vom Anbieter',
      'az': 'A–Z',
      'za': 'Z–A',
      'new': 'Neueste zuerst',
      'rating': 'Beste Bewertung',
    }),
    const _Opt('sortGroups', 'Kategorien alphabetisch', false),
    const _Opt('cacheHours', 'Playlist-Cache', 12,
        hint: 'Wie lange geladene Listen gültig bleiben',
        options: {1: '1 Stunde', 6: '6 Stunden', 12: '12 Stunden', 24: '1 Tag', 72: '3 Tage', 168: '1 Woche'}),
    const _Opt('userAgent', 'User-Agent', 'VLC/3.0.20 LibVLC/3.0.20',
        hint: 'Manche Anbieter blockieren unbekannte Player',
        options: {
          'VLC/3.0.20 LibVLC/3.0.20': 'VLC',
          'Kodi/21.0 (Linux; Android 12)': 'Kodi',
          'IPTVSmartersPlayer': 'IPTV Smarters',
          'okhttp/4.12.0': 'okhttp',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36': 'Browser',
        }),
    _Opt('iptvCountry', 'IPTV-Land', 'de', options: Map<Object, String>.from(iptvCountries)),
  ]),
  _Cat('Start', 'Startbildschirm, Animation, Updates', Icons.rocket_launch_outlined, [
    const _Opt('intro', 'Startanimation', true),
    const _Opt('introSound', 'Startton', true),
    const _Opt('askOnStart', 'Beim Start Modus wählen', true, hint: 'Aus: letzte Quelle direkt öffnen'),
    const _Opt('startTab', 'Startbereich', 'mine',
        options: {'mine': 'Start', 'live': 'Live TV', 'guide': 'TV-Guide', 'movie': 'Filme', 'series': 'Serien'}),
    const _Opt('updateCheck', 'Nach Updates fragen', true, hint: 'Beim Start prüfen, ob eine neue Version da ist'),
    _Act('update', 'Nach Updates suchen', hint: () => tr('Installiert: {0}', [appVersion])),
    _Act('setup', 'Einrichtung erneut starten', hint: () => tr('Sprache, Aussehen, Bildschirm und Geräte-Check')),
    _Act('check', 'Geräte-Check', hint: () => tr('Welche Formate dein Gerät abspielt')),
  ]),
  _Cat('Kindersicherung', 'PIN, ausgeblendete Inhalte', Icons.lock_outline_rounded, [
    const _Opt('hideAdult', 'Erwachseneninhalte ausblenden', true, hint: 'Mit PIN schützbar'),
    _Act('pin', 'Kindersicherungs-PIN',
        hint: () => store.get('pin', '').isEmpty ? tr('Keine PIN gesetzt') : tr('PIN aktiv')),
    _Act('pinOnStart', 'PIN beim App-Start',
        hint: () => store.get('pin', '').isEmpty ? tr('Zuerst eine PIN festlegen') : null,
        toggle: () => store.get('pinOnStart', false)),
    _Act('unhide', 'Ausgeblendete Kategorien einblenden', hint: () => tr('{0} ausgeblendet', [store.hiddenGroups.length])),
  ]),
  _Cat('Speicher & Sicherung', 'Sicherung, Cache, Verlauf', Icons.storage_rounded, [
    _Act('export', 'Sicherung kopieren', hint: () => tr('Server, Favoriten und Einstellungen in die Zwischenablage')),
    _Act('import', 'Sicherung einfügen', hint: () => tr('Aus der Zwischenablage wiederherstellen')),
    _Act('downloads', 'Downloads löschen',
        hint: () => tr('{0} Dateien · {1}', [downloads.items.length, fmtBytes(downloads.usedBytes)])),
    _Act('cache', 'Cache leeren', hint: () => tr('Playlists und Bilder neu laden')),
    _Act('history', 'Verlauf löschen', hint: () => tr('{0} Einträge', [store.history.length])),
    _Act('favs', 'Favoriten löschen', hint: () => tr('{0} Einträge', [store.favs.length])),
  ]),
];

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Einstellungen'), style: TextStyle(fontWeight: FontWeight.w700))),
        body: const SettingsBody(),
      );
}

class SettingsBody extends StatefulWidget {
  const SettingsBody({super.key});

  @override
  State<SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<SettingsBody> {
  int _sel = 0;
  // Fernbedienung: Pfeil rechts springt in die erste Option, Pfeil links zurück zur gewählten Kategorie.
  // Flutter würde sonst nach Höhe die Kategorie daneben wählen und dabei den Inhalt wechseln.
  final _catNodes = [for (final _ in _cats) FocusNode()];
  final _first = FocusNode();

  @override
  void dispose() {
    for (final n in _catNodes) {
      n.dispose();
    }
    _first.dispose();
    super.dispose();
  }

  KeyEventResult _jump(KeyEvent e, LogicalKeyboardKey key, FocusNode Function() target) {
    if (e is KeyUpEvent || e.logicalKey != key) return KeyEventResult.ignored;
    final t = target();
    if (t.context == null) return KeyEventResult.ignored;
    t.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([store, downloads]),
        builder: (context, _) => LayoutBuilder(builder: (context, box) {
          // Schmal (Handy): Kategorien als Liste, Inhalt auf eigener Seite
          if (box.maxWidth < 760) return _catList(context, narrow: true);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 360,
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (_, e) => _jump(e, LogicalKeyboardKey.arrowRight, () => _first),
                child: FocusTraversalGroup(child: _catList(context, narrow: false)),
              ),
            ),
            VerticalDivider(width: 1, color: ink(.1)),
            Expanded(
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (_, e) => _jump(e, LogicalKeyboardKey.arrowLeft, () => _catNodes[_sel]),
                child: FocusTraversalGroup(child: _CatBody(_cats[_sel], first: _first, key: ValueKey(_sel))),
              ),
            ),
          ]);
        }),
      );

  Widget _catList(BuildContext context, {required bool narrow}) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          for (final (i, c) in _cats.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Tap(
                fill: true,
                scale: 1,
                autofocus: i == 0,
                focusNode: narrow ? null : _catNodes[i],
                // Fernbedienung/Tastatur: Kategorie beim Darüberfahren rechts zeigen
                onFocus: narrow ? null : (f) => f && _sel != i ? setState(() => _sel = i) : null,
                onTap: narrow
                    ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => _CatPage(c)))
                    : () => setState(() => _sel = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: !narrow && _sel == i ? ink(.07) : null,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                          color: store.accent.withValues(alpha: .15), borderRadius: BorderRadius.circular(10)),
                      child: Icon(c.icon, size: 21, color: store.accent),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(tr(c.title), style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(tr(c.summary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: textDim, fontSize: 12.5)),
                      ]),
                    ),
                    if (narrow) Icon(Icons.chevron_right_rounded, color: textDim),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 20),
          Text('CinemaMax $appVersion', textAlign: TextAlign.center, style: TextStyle(color: textDim, fontSize: 12)),
        ],
      );
}

/// Handy: eine Kategorie als eigene Seite.
class _CatPage extends StatelessWidget {
  final _Cat cat;
  const _CatPage(this.cat);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr(cat.title), style: const TextStyle(fontWeight: FontWeight.w700))),
        body: ListenableBuilder(listenable: Listenable.merge([store, downloads]), builder: (context, _) => _CatBody(cat)),
      );
}

/// Einträge einer Kategorie.
class _CatBody extends StatelessWidget {
  final _Cat cat;
  final FocusNode? first; // Fokusziel für Pfeil rechts aus der Kategorienliste
  const _CatBody(this.cat, {this.first, super.key});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
            children: [
              SectionTitle(tr(cat.title)),
              for (final (i, it) in cat.items.where((it) => it is! _Opt || (it.visible?.call() ?? true)).indexed)
                // Gestaffelt einblenden; Schlüssel je Eintrag, damit beim Ein-/Ausblenden nichts neu startet
                if (it is _Opt)
                  Rise(i,
                      key: ValueKey(it.key),
                      distance: 14,
                      child: _row(
                        context,
                        focusNode: i == 0 ? first : null,
                        tr(it.label),
                        it.hint == null ? null : tr(it.hint!),
                        value: it.options == null
                            ? null
                            : tr(it.options![store.get<Object>(it.key, it.def)] ??
                                (it.key == 'accent' ? hexColor(store.accent) : '—')),
                        toggle: it.options == null ? store.get<bool>(it.key, it.def as bool) : null,
                        color: it.key == 'accent' ? store.accent : null,
                        onTap: () => _change(context, it),
                      ))
                else if (it is _Act)
                  Rise(i,
                      key: ValueKey(it.key),
                      distance: 14,
                      child: _row(context, tr(it.label), it.hint?.call(),
                          focusNode: i == 0 ? first : null,
                          toggle: it.toggle?.call(),
                          onTap: () => _action(context, it.key))),
            ],
          ),
        ),
      );
}

Future<String?> _askPin(BuildContext c, String title) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: c,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: dpadField(TextField(
        controller: ctrl,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 8,
        onSubmitted: (v) => Navigator.pop(c, v),
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Abbrechen'))),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: Text(tr('OK'))),
      ],
    ),
  );
}

Future<void> _change(BuildContext c, _Opt o) async {
  final cur = store.get<Object>(o.key, o.def);
  if (o.options == null) {
    // Kindersicherung: Ausschalten nur mit PIN
    if (o.key == 'hideAdult' && cur == true && store.get('pin', '').isNotEmpty) {
      final p = await _askPin(c, tr('PIN eingeben'));
      if (p != store.get('pin', '')) {
        if (c.mounted && p != null) toast(c, tr('Falsche PIN'));
        return;
      }
    }
    store.set(o.key, !(cur as bool));
    return;
  }
  final v = await pick<Object>(c, tr(o.label), {for (final e in o.options!.entries) e.key: tr(e.value)},
      current: cur,
      leading: o.key == 'accent'
          ? (k) => k == -1
              ? const Icon(Icons.palette_outlined, size: 20)
              : Container(width: 18, height: 18, decoration: BoxDecoration(color: Color(k as int), shape: BoxShape.circle))
          : null);
  if (v == -1 && c.mounted) {
    final col = await showDialog<Color>(context: c, builder: (_) => ColorPickerDialog(initial: store.accent));
    if (col != null) store.set('accent', col.toARGB32());
    return;
  }
  if (v != null && v != cur) {
    store.set(o.key, v);
    // Xtream-Senderlinks enthalten das Format (.ts/.m3u8) und liegen im Listen-Cache: neu laden lassen
    if (o.key == 'liveFormat') await Repo.clearCache();
  }
}

Future<void> _action(BuildContext c, String what) async {
  switch (what) {
    case 'setup':
      store.set('setupDone', false);
      Navigator.of(c).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const SetupScreen()), (_) => false);
    case 'check':
      Navigator.push(c, MaterialPageRoute(builder: (_) => const DeviceCheckScreen()));
    case 'pin':
      final p = await _askPin(c, tr('Neue PIN (leer = keine PIN)'));
      if (p != null) {
        store.set('pin', p);
        if (c.mounted) toast(c, p.isEmpty ? tr('PIN entfernt') : tr('PIN gespeichert'));
      }
    case 'pinOnStart':
      if (store.get('pin', '').isEmpty) return toast(c, tr('Zuerst eine PIN festlegen'));
      store.set('pinOnStart', !store.get('pinOnStart', false));
    case 'unhide':
      store.unhideAll();
      toast(c, tr('Alle Kategorien wieder sichtbar'));
    case 'export':
      await Clipboard.setData(ClipboardData(text: store.exportBackup()));
      if (c.mounted) toast(c, tr('Sicherung kopiert. Enthält Zugangsdaten, nur sicher weitergeben.'));
    case 'import':
      final t = (await Clipboard.getData('text/plain'))?.text ?? '';
      try {
        await store.importBackup(t);
        if (c.mounted) toast(c, tr('Sicherung wiederhergestellt'));
      } catch (e) {
        if (c.mounted) toast(c, tr('Keine gültige Sicherung in der Zwischenablage'));
      }
    case 'downloads':
      final ok = await pick(c, tr('Alle Downloads löschen?'), {false: tr('Abbrechen'), true: tr('Löschen')});
      if (ok == true) await downloads.removeAll();
    case 'cache':
      await Repo.clearCache();
      imageCache.clear();
      if (c.mounted) toast(c, tr('Cache geleert'));
    case 'history':
      store.clearHistory();
      toast(c, tr('Verlauf gelöscht'));
    case 'favs':
      final ok = await pick(c, tr('Alle Favoriten löschen?'), {false: tr('Abbrechen'), true: tr('Löschen')});
      if (ok == true) {
        store.clearFavs();
        if (c.mounted) toast(c, tr('Favoriten gelöscht'));
      }
  }
}

Widget _row(BuildContext c, String label, String? hint,
        {String? value,
        bool? toggle,
        Color? color,
        bool autofocus = false,
        FocusNode? focusNode,
        required VoidCallback onTap}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Tap(
        fill: true,
        scale: 1,
        autofocus: autofocus,
        focusNode: focusNode,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                if (hint != null) ...[
                  const SizedBox(height: 2),
                  Text(hint, style: TextStyle(color: textDim, fontSize: 12.5)),
                ],
              ]),
            ),
            if (color != null) ...[
              Container(width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 10),
            ],
            if (value != null) Text(value, style: TextStyle(color: ink(.7), fontSize: 14)),
            if (toggle != null)
              ExcludeFocus(child: IgnorePointer(child: Switch(value: toggle, onChanged: (_) {}))),
          ]),
        ),
      ),
    );
