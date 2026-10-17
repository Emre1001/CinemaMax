import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../downloads.dart';
import '../i18n.dart';

import '../repo.dart';
import '../store.dart';
import '../update.dart';
import 'common.dart';
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

final _sections = <String, List<_Opt>>{
  'Darstellung': [
    _Opt('lang', 'Sprache', 'system', options: Map<Object, String>.from(languages)),
    const _Opt('accent', 'Akzentfarbe', Store.defaultAccent,
        hint: 'Farbe der ganzen Oberfläche',
        options: {
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
          -1: 'Eigene Farbe …',
        }),
    const _Opt('layout', 'Oberfläche', 'auto',
        hint: 'Automatisch erkennt Handy, Tablet, TV und PC',
        options: {'auto': 'Automatisch', 'phone': 'Handy', 'tv': 'Fernseher', 'desktop': 'PC / Tablet'}),
    const _Opt('tileSize', 'Kachelgröße', 'M', options: {'S': 'Klein', 'M': 'Mittel', 'L': 'Groß'}),
    const _Opt('liveAsList', 'Live-Sender als Liste', false),
    const _Opt('logoBg', 'Hintergrund für Senderlogos', 'dark',
        hint: 'Hell macht dunkle Logos sichtbar', options: {'dark': 'Dunkel', 'light': 'Hell'}),
    const _Opt('showLogos', 'Logos und Poster laden', true, hint: 'Aus spart Datenvolumen'),
    const _Opt('clock', 'Uhr anzeigen', true),
    const _Opt('reduceMotion', 'Animationen reduzieren', false, hint: 'Für langsame TV-Boxen'),
  ],
  'Start': [
    const _Opt('intro', 'Startanimation', true),
    const _Opt('introSound', 'Startton', true),
    const _Opt('updateCheck', 'Nach Updates fragen', true, hint: 'Beim Start prüfen, ob eine neue Version da ist'),
    const _Opt('askOnStart', 'Beim Start Modus wählen', true, hint: 'Aus: letzte Quelle direkt öffnen'),
    const _Opt('startTab', 'Startbereich', 'mine',
        options: {'mine': 'Start', 'live': 'Live TV', 'guide': 'TV-Guide', 'movie': 'Filme', 'series': 'Serien'}),
    _Opt('iptvCountry', 'IPTV-Land', 'de', options: Map<Object, String>.from(iptvCountries)),
  ],
  'Inhalte': [
    const _Opt('sort', 'Sortierung', 'default', options: {
      'default': 'Wie vom Anbieter',
      'az': 'A–Z',
      'za': 'Z–A',
      'new': 'Neueste zuerst',
      'rating': 'Beste Bewertung',
    }),
    const _Opt('sortGroups', 'Kategorien alphabetisch', false),
    const _Opt('hideAdult', 'Erwachseneninhalte ausblenden', true, hint: 'Mit PIN schützbar'),
    const _Opt('epg', 'Programmführer (EPG) laden', true, hint: 'Zeigt was läuft, TV-Guide und Rückschau'),
    const _Opt('cacheHours', 'Playlist-Cache', 12,
        hint: 'Wie lange geladene Listen gültig bleiben',
        options: {1: '1 Stunde', 6: '6 Stunden', 12: '12 Stunden', 24: '1 Tag', 72: '3 Tage', 168: '1 Woche'}),
    const _Opt('liveFormat', 'Live-Format (Xtream)', 'ts', options: {'ts': 'MPEG-TS (.ts)', 'm3u8': 'HLS (.m3u8)'}),
    const _Opt('userAgent', 'User-Agent', 'VLC/3.0.20 LibVLC/3.0.20',
        hint: 'Manche Anbieter blockieren unbekannte Player',
        options: {
          'VLC/3.0.20 LibVLC/3.0.20': 'VLC',
          'Kodi/21.0 (Linux; Android 12)': 'Kodi',
          'IPTVSmartersPlayer': 'IPTV Smarters',
          'okhttp/4.12.0': 'okhttp',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36': 'Browser',
        }),
  ],
  'Wiedergabe': [
    _Opt('engine', 'Player', 'exo',
        hint: 'ExoPlayer: schnell und stabil. mpv: mehr Formate und Untertitel',
        options: {'exo': 'ExoPlayer (empfohlen)', 'mpv': 'mpv'},
        visible: () => Platform.isAndroid),
    _Opt('autoMpv', 'Bei Fehlern anderen Player versuchen', true,
        hint: 'ExoPlayer und mpv springen füreinander ein (z. B. bei 4K oder DTS-Ton)',
        visible: () => Platform.isAndroid),
    _Opt('surfaceView', 'Videoausgabe SurfaceView', isAndroidTv,
        hint: 'Echtes 4K und richtige HDR-Farben, schneller auf TV-Boxen (Fernseher: an)',
        visible: () => Platform.isAndroid && store.get('engine', 'exo') == 'exo'),
    const _Opt('maxRes', 'Maximale Auflösung (Daten sparen)', 0,
        hint: 'Für langsames Internet oder mobile Daten. Nur bei Streams mit mehreren Qualitäten (meist HLS)',
        options: {0: 'Beste (automatisch)', 1080: '1080p', 720: '720p', 480: '480p (spart Daten)', 360: '360p (sehr langsames Internet)'}),
    const _Opt('dlQuality', 'Download-Qualität', -1,
        hint: 'Kleinere Auflösung spart Speicher. Wählbar bei Streams mit mehreren Qualitäten (HLS); MP4/MKV gibt es nur in einer',
        options: {-1: 'Jedes Mal fragen', 0: 'Beste', 1080: '1080p', 720: '720p', 480: '480p (spart Speicher)', 360: '360p (sehr klein)'}),
    _Opt('defaultRate', 'Standard-Tempo (Filme/Serien)', 1.0,
        options: {0.75: '0.75x', 1.0: '1x', 1.25: '1.25x', 1.5: '1.5x', 2.0: '2x'}),    const _Opt('hwdec', 'Hardware-Dekodierung', true, hint: 'Aus bei Bildfehlern oder grünem Bild'),
    const _Opt('bufferMb', 'Puffergröße', 64, options: {16: '16 MB', 32: '32 MB', 64: '64 MB', 128: '128 MB', 256: '256 MB'}),
    const _Opt('fit', 'Standard-Bildformat', 'contain', options: {'contain': 'Einpassen', 'cover': 'Zoomen', 'fill': 'Strecken'}),
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
    const _Opt('autoReconnect', 'Live automatisch neu verbinden', true),
    const _Opt('seekStep', 'Spulschritt', 10, options: {5: '5 s', 10: '10 s', 15: '15 s', 30: '30 s', 60: '60 s'}),
    const _Opt('zapInvert', 'Senderwechsel umkehren', false, hint: 'Pfeil hoch = nächster Sender'),
    const _Opt('hideSec', 'Bedienleiste ausblenden nach', 5, options: {3: '3 s', 5: '5 s', 8: '8 s', 12: '12 s'}),
    const _Opt('remaining', 'Restzeit statt Gesamtdauer', false),
    const _Opt('deinterlace', 'Deinterlacing', false, hint: 'Für ältere SD-/1080i-Sender'),
    const _Opt('normalize', 'Lautstärke angleichen', false, hint: 'Nachtmodus: leise Dialoge lauter'),
    _Opt('landscape', 'Auf Handy immer Querformat', true, visible: () => Platform.isAndroid),
    _Opt('autoFullscreen', 'Player im Vollbild starten', false, visible: () => _desktop),
    _Opt('autoPip', 'Bild-in-Bild beim Verlassen', true,
        hint: 'Video läuft im kleinen Fenster weiter', visible: () => Platform.isAndroid && !isAndroidTv),
  ],
  'Ton & Untertitel': [
    const _Opt('audioLang', 'Bevorzugte Tonspur', 'de,deu,ger', options: _langs),
    const _Opt('subLang', 'Bevorzugte Untertitel', 'de,deu,ger', options: _langs),
    const _Opt('subsOn', 'Untertitel automatisch an', false),
    const _Opt('subSize', 'Untertitelgröße', 44, options: {32: 'Klein', 44: 'Mittel', 56: 'Groß', 68: 'Sehr groß'}),
    const _Opt('subBg', 'Untertitel-Hintergrund', false),
  ],
};

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(backgroundColor: bg, title: Text(tr('Einstellungen'), style: TextStyle(fontWeight: FontWeight.w700))),
        body: const SettingsBody(),
      );
}

class SettingsBody extends StatelessWidget {
  const SettingsBody({super.key});

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
    if (v != null) store.set(o.key, v);
  }

  Future<void> _action(BuildContext c, String what) async {
    switch (what) {
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
              children: [
                for (final (si, sec) in _sections.entries.indexed) ...[
                  SectionTitle(tr(sec.key)),
                  for (final (oi, o) in sec.value.indexed)
                    if (o.visible?.call() ?? true)
                      _row(
                        context,
                        tr(o.label),
                        o.hint == null ? null : tr(o.hint!),
                        autofocus: si == 0 && oi == 0,
                        value: o.options == null
                            ? null
                            : tr(o.options![store.get<Object>(o.key, o.def)] ??
                                (o.key == 'accent' ? hexColor(store.accent) : '—')),
                        toggle: o.options == null ? store.get<bool>(o.key, o.def as bool) : null,
                        color: o.key == 'accent' ? store.accent : null,
                        onTap: () => _change(context, o),
                      ),
                ],
                SectionTitle(tr('Daten & Sicherheit')),
                _row(context, tr('Kindersicherungs-PIN'), store.get('pin', '').isEmpty ? tr('Keine PIN gesetzt') : tr('PIN aktiv'),
                    onTap: () => _action(context, 'pin')),
                _row(context, tr('PIN beim App-Start'), store.get('pin', '').isEmpty ? tr('Zuerst eine PIN festlegen') : null,
                    toggle: store.get('pinOnStart', false), onTap: () => _action(context, 'pinOnStart')),
                _row(context, tr('Ausgeblendete Kategorien einblenden'), tr('{0} ausgeblendet', [store.hiddenGroups.length]),
                    onTap: () => _action(context, 'unhide')),
                _row(context, tr('Sicherung kopieren'), tr('Server, Favoriten und Einstellungen in die Zwischenablage'),
                    onTap: () => _action(context, 'export')),
                _row(context, tr('Sicherung einfügen'), tr('Aus der Zwischenablage wiederherstellen'), onTap: () => _action(context, 'import')),
                _row(context, tr('Downloads löschen'), tr('{0} Dateien · {1}', [downloads.items.length, fmtBytes(downloads.usedBytes)]),
                    onTap: () => _action(context, 'downloads')),
                _row(context, tr('Cache leeren'), tr('Playlists und Bilder neu laden'), onTap: () => _action(context, 'cache')),
                _row(context, tr('Verlauf löschen'), tr('{0} Einträge', [store.history.length]), onTap: () => _action(context, 'history')),
                _row(context, tr('Favoriten löschen'), tr('{0} Einträge', [store.favs.length]), onTap: () => _action(context, 'favs')),
                _row(context, tr('Nach Updates suchen'), tr('Installiert: {0}', [appVersion]),
                    onTap: () => checkForUpdate(context, manual: true)),
                const SizedBox(height: 24),
                Text('CinemaMax $appVersion',
                    textAlign: TextAlign.center, style: TextStyle(color: textDim, fontSize: 12)),
              ],
            ),
          ),
        ),
      );

  Widget _row(BuildContext c, String label, String? hint,
          {String? value, bool? toggle, Color? color, bool autofocus = false, required VoidCallback onTap}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Tap(
          fill: true,
          scale: 1,
          autofocus: autofocus,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  if (hint != null) ...[
                    const SizedBox(height: 2),
                    Text(hint, style: const TextStyle(color: textDim, fontSize: 12.5)),
                  ],
                ]),
              ),
              if (color != null) ...[
                Container(width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 10),
              ],
              if (value != null) Text(value, style: const TextStyle(color: Colors.white70, fontSize: 14)),
              if (toggle != null)
                ExcludeFocus(child: IgnorePointer(child: Switch(value: toggle, onChanged: (_) {}))),
            ]),
          ),
        ),
      );
}
