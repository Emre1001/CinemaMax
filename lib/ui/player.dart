import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart' show defaultEnterNativeFullscreen, defaultExitNativeFullscreen;

import '../downloads.dart';
import '../epg.dart';
import '../i18n.dart';
import '../errors.dart';
import '../external_player.dart';
import '../models.dart';
import '../playback.dart';
import '../repo.dart';
import '../store.dart';
import 'browse.dart';
import 'common.dart';

class PlayItem {
  final String url;
  final String title;
  final MediaItem item;
  final Episode? episode; // Serienfolge: Staffel, Nummer, Bild, Handlung für Folgenliste/„Nächste Folge“
  const PlayItem(this.url, this.title, this.item, {this.episode});
  bool get live => item.kind == Kind.live;
}

/// Serienfolgen als Wiedergabeliste (Folgenliste und „Nächste Folge“ im Player).
List<PlayItem> episodeList(MediaItem show, List<Episode> eps) => [
  for (final x in eps) PlayItem(x.url, 'S${x.season} E${x.number} · ${x.title}', show, episode: x),
];

/// Aus dem Verlauf fortsetzen. Serie: mit allen Folgen, damit es danach weitergeht.
Future<void> resumeFromHistory(BuildContext c, Source s, String url, String title, MediaItem item) async {
  var list = [PlayItem(url, title, item)];
  if (item.kind == Kind.series) {
    try {
      final all = episodeList(item, await Repo.episodes(s, item).timeout(const Duration(seconds: 15)));
      if (all.any((p) => p.url == url)) list = all;
    } catch (_) {
      /* offline oder Server weg: nur diese Folge */
    }
  }
  if (!c.mounted) return;
  await PlayerScreen.open(c, s, list, list.indexWhere((p) => p.url == url).clamp(0, list.length - 1));
}

/// Bildformate: Name, Einpassung und erzwungenes Seitenverhältnis (null = wie die Quelle).
Map<String, (String, BoxFit, double?)> get fits => {
  'contain': (tr('Einpassen'), BoxFit.contain, null),
  'original': (tr('Original (1:1)'), BoxFit.none, null),
  'cover': (tr('Zoomen'), BoxFit.cover, null),
  'fill': (tr('Strecken'), BoxFit.fill, null),
  '169': ('16:9', BoxFit.fill, 16 / 9),
  '43': ('4:3', BoxFit.fill, 4 / 3),
};

/// Eintrag in VLC/MX Player abspielen; Position fürs Weiterschauen kommt zurück (Android).
/// false = Player fehlt oder Link nicht auflösbar (Meldung wurde gezeigt).
Future<bool> playExternal(BuildContext c, Source s, PlayItem item, String player,
    {bool fromStart = false, Duration? start}) async {
  var url = downloads.localFile(item.url) ?? item.url;
  try {
    if (url.startsWith('stalker:')) url = await Repo.stalkerResolve(s, url);
    final (clean, headers) = Engine.splitHeaders(url, Repo.streamHeaders(s));
    if (item.live) store.addRecentLive(s, item.item);
    start ??= !item.live && store.get('resume', true) && !fromStart ? store.resumeAt(item.url) : null;
    final r = await ExternalPlayer.play(player, clean, headers, item.title, start: start);
    if (r != null && !item.live && r.duration > Duration.zero) {
      store.saveProgress(s, item.item, item.url, item.title, r.position, r.duration);
    }
    return true;
  } on PlatformException catch (e) {
    if (c.mounted) {
      toast(c, e.code == 'missing'
          ? tr('{0} ist nicht installiert. Es wird der eingebaute Player genutzt.', [ExternalPlayer.names[player] ?? player])
          : tr('Fehler: {0}', [explain(e)]));
    }
  } catch (e) {
    if (c.mounted) toast(c, tr('Fehler: {0}', [explain(e)]));
  }
  return false;
}

class PlayerScreen extends StatefulWidget {
  final Source source;
  final List<PlayItem> list;
  final int index;
  final bool fromStart;
  final String? engine; // 'exo'/'mpv' nur für diese Wiedergabe, null = Einstellung

  const PlayerScreen({
    super.key,
    required this.source,
    required this.list,
    required this.index,
    this.fromStart = false,
    this.engine,
  });

  /// Routenname, damit externe Links einen laufenden Player ersetzen können.
  static const route = 'player';

  static Future<void> open(BuildContext c, Source s, List<PlayItem> list, int index, {bool fromStart = false}) async {
    // Externer Player gewählt (Einstellungen → Player): dort abspielen, bei Fehlern doch hier
    final ext = store.get('extPlayer', '');
    if (ext.isNotEmpty && await playExternal(c, s, list[index], ext, fromStart: fromStart)) return;
    if (!c.mounted) return;
    await Navigator.push(
      c,
      MaterialPageRoute(
        settings: const RouteSettings(name: route),
        builder: (_) => PlayerScreen(source: s, list: list, index: index, fromStart: fromStart),
      ),
    );
  }

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  // Offene Player: Systemleisten erst wieder zeigen, wenn der letzte zu ist. Ersetzt ein Player
  // den anderen (ExoPlayer → mpv, neue Folge per Link), räumt der alte erst danach auf.
  static int _open = 0;

  static void _immersive() {
    if (!Platform.isAndroid) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!isAndroidTv && store.get('landscape', true)) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
  }

  // Zurück aus einer anderen App oder Bild-in-Bild: Statusleiste wieder ausblenden
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _immersive();
  }

  late final Engine _e = Engine.create(
      widget.list[widget.index].url, widget.engine ?? downloads.engineFor(widget.list[widget.index].url));
  bool _leaving = false;
  final _root = FocusNode(debugLabel: 'player');
  final _playBtn = FocusNode(debugLabel: 'play');
  final _errorBtn = FocusNode(debugLabel: 'retry');
  final _errorAlt = FocusNode(debugLabel: 'other-engine'), _errorBack = FocusNode(debugLabel: 'back');
  final _stillBack = FocusNode(debugLabel: 'still-back');
  final _errorExt = [FocusNode(debugLabel: 'ext-1'), FocusNode(debugLabel: 'ext-2')];
  final _stillBtn = FocusNode(debugLabel: 'still');
  bool _everPlayed = false; // Stream lief schon: Fehler sind Abbrüche, kein Format-Problem
  bool _failed = false; // Fehlermeldung sichtbar (nicht während automatischem Neuverbinden)
  int _repeat = 0; // gehaltene Taste: Spulen beschleunigen
  late int _i = widget.index;
  late String _fit = fits.containsKey(store.get('fit', 'contain')) ? store.get('fit', 'contain') : 'contain';
  bool _controls = true, _fullscreen = false, _first = true, _muted = false, _locked = false;
  double _volume = 1, _audioDelay = 0, _subDelay = 0;
  int? _lastIndex; // vorheriger Sender für „Letzter Sender“
  double? _dragSeek; // Wischen zum Spulen: Sekunden
  double? _dragZap; // Wischen zum Senderwechsel: Strecke, null = schon gewechselt
  Timer? _hideTimer, _saveTimer, _sleepTimer, _retryTimer, _digitTimer, _toastTimer, _tapSeekTimer, _graceTimer;
  // Vor dem Wechsel zum anderen Player so lange weiter versuchen: manche Streams brauchen ein paar Anläufe
  static const _grace = Duration(seconds: 8);
  var _openedAt = DateTime.now();
  bool _graceRetried = false;
  List<String> _externals = []; // installierte externe Player (VLC, MX)
  DateTime? _sleepAt;
  int _retries = 0, _openId = 0, _tapSeek = 0;
  String _digits = '';
  String? _toast;
  List<({String title, DateTime start, DateTime end})> _epg = [];

  // Netflix-Ablauf: Abspann-Karte mit Countdown, Intro überspringen, „Schaust du noch?“
  bool _nextDismissed = false, _advancing = false, _introDone = false, _askStill = false;
  bool _stopAtEnd = false; // Sleep-Timer „Ende dieser Folge“
  int _autoChain = 0; // Folgen hintereinander ohne Eingabe

  static const _device = MethodChannel('cinemamax/device');
  bool get _phone => Platform.isAndroid && !isAndroidTv;

  PlayItem get _cur => widget.list[_i];
  bool get _hasNext => !_cur.live && _i < widget.list.length - 1;
  bool get _tv => formFactor(context) == Ff.tv;
  // PC am Fernseher (Layout „Fernseher“) bekommt die Fernbedienungs-Oberfläche
  bool get _desktop => (Platform.isLinux || Platform.isWindows) && !_tv;
  int get _step => store.get('seekStep', 10);
  int get _introSkip => store.get('introSkip', 85);

  /// Abspann: Karte „Nächste Folge“ sichtbar? Wert = Countdown-Fortschritt 0..1, null = keine Karte.
  double? _nextProgress(PlaybackState s) {
    if (!_hasNext || _nextDismissed || _askStill || s.duration < const Duration(minutes: 2)) return null;
    final left = (s.duration - s.position).inMilliseconds / 1000;
    final window = store.get('nextBefore', 30).toDouble();
    if (left > window || left < 0) return null;
    final countdown = store.get('nextCountdown', 10);
    if (countdown <= 0 || !store.get('autoNext', true)) return 0;
    return ((window - left) / countdown).clamp(0.0, 1.0);
  }

  /// Knopf „Intro überspringen“ möglich: in den ersten Minuten einer Folge, vor dem Sprungziel.
  bool _introEligible(PlaybackState s) =>
      _introSkip > 0 &&
      !_introDone &&
      _cur.item.kind == Kind.series &&
      s.duration > const Duration(minutes: 10) &&
      s.position > const Duration(seconds: 3) &&
      s.position < const Duration(minutes: 3) &&
      s.position < Duration(seconds: _introSkip);

  Duration? _introFrom; // Position, ab der der Knopf sichtbar ist
  static const _introWindow = Duration(seconds: 10);

  /// Countdown des Knopfs 0..1; nach 10 s Wiedergabe verschwindet er von selbst. null = nicht sichtbar.
  double? _introProgress(PlaybackState s) {
    final from = _introFrom;
    if (from == null || !_introEligible(s)) return null;
    final t = (s.position - from).inMilliseconds / _introWindow.inMilliseconds;
    return t < 0 || t >= 1 ? null : t;
  }

  bool _introVisible(PlaybackState s) => _introProgress(s) != null;

  @override
  void initState() {
    super.initState();
    _e.onCompleted = _completed;
    _e.state.addListener(_onState);
    _saveTimer = Timer.periodic(const Duration(seconds: 15), (_) => _saveProgress());
    // Bedienleiste beim Start zeigen und nach der eingestellten Zeit ausblenden
    _hideTimer = Timer(Duration(seconds: store.get('hideSec', 5)), _hide);
    // Handy: beim Verlassen der App als Bild-in-Bild weiterlaufen
    if (_phone && store.get('autoPip', true)) _device.invokeMethod('autoPip', true).catchError((_) {});
    _open++;
    _immersive();
    ExternalPlayer.available().then((v) {
      if (mounted) setState(() => _externals = v);
    });
    WidgetsBinding.instance.addObserver(this);
    if (_desktop && store.get('autoFullscreen', false)) _toggleFullscreen();
    _volume = store.get('volume', 1.0).clamp(0.0, _e.maxVolume).toDouble();
    // Fernbedienung: Fokus gleich auf Play/Pause, sonst führt kein Pfeil in die Bedienleiste
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controls && _playBtn.context != null) _playBtn.requestFocus();
    });
    _play(_i);
  }

  @override
  void dispose() {
    _saveProgress();
    for (final t in [_hideTimer, _saveTimer, _sleepTimer, _retryTimer, _digitTimer, _toastTimer, _tapSeekTimer, _graceTimer]) {
      t?.cancel();
    }
    _e.onCompleted = null;
    _e.state.removeListener(_onState);
    _e.dispose();
    _root.dispose();
    _playBtn.dispose();
    _errorBtn.dispose();
    _errorAlt.dispose();
    _errorBack.dispose();
    _stillBack.dispose();
    for (final n in _errorExt) {
      n.dispose();
    }
    _stillBtn.dispose();
    store.set('volume', _volume);
    if (_phone) _device.invokeMethod('autoPip', false).catchError((_) {});
    WidgetsBinding.instance.removeObserver(this);
    if (--_open == 0 && Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([]);
    }
    if (_fullscreen) defaultExitNativeFullscreen();
    super.dispose();
  }

  void _onState() {
    final s = _e.state.value;
    if (s.playing && s.ready) {
      _retries = 0;
      _everPlayed = true;
    }
    // Vor der ersten Wiedergabe: Fehler 8 s lang nicht zeigen, sondern weiter versuchen
    if (s.error != null && !_everPlayed) {
      final left = _grace - DateTime.now().difference(_openedAt);
      if (left > Duration.zero) {
        // Noch in der Schonfrist: Fehler nicht zeigen, einmal mit demselben Player neu öffnen
        if (_graceTimer?.isActive != true) {
          _graceTimer = Timer(left, () {
            if (mounted && !_everPlayed && _e.state.value.error != null) _onState();
          });
          if (!_graceRetried && !_cur.live) {
            _graceRetried = true;
            Timer(const Duration(seconds: 2), () {
              if (mounted && !_everPlayed && _e.state.value.error != null) _play(_i, retry: true);
            });
          }
          if (mounted) setState(() {});
        }
        return;
      }
    }
    // Ein Player kann den Stream gar nicht öffnen (z. B. 4K-HEVC, 10 Bit, DTS): einmal den anderen versuchen
    // (Android: ExoPlayer und mpv). Abbrüche eines laufenden Streams regelt das automatische Neuverbinden.
    final other = _e is ExoEngine ? 'mpv' : 'exo';
    if (s.error != null &&
        !_everPlayed &&
        Platform.isAndroid &&
        widget.engine == null &&
        !_leaving &&
        store.get('autoMpv', true) &&
        !(other == 'exo' && Engine.exotic(_cur.url))) {
      _leaving = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        toast(context, tr('{0} kann diesen Stream nicht abspielen, versuche {1} …',
            [_e is ExoEngine ? 'ExoPlayer' : 'mpv', other == 'exo' ? 'ExoPlayer' : 'mpv']));
        _replace(other);
      });
      return;
    }
    // Live-Streams brechen oft kurz ab: automatisch neu verbinden
    if (s.error != null &&
        _cur.live &&
        store.get('autoReconnect', true) &&
        _retries < 5 &&
        _retryTimer?.isActive != true) {
      _retries++;
      _retryTimer = Timer(Duration(seconds: 1 + _retries), () => _play(_i, retry: true));
    }
    // Fehler liegt über allem; Bedienleiste darunter nicht per Fernbedienung erreichbar
    final failed = s.error != null && !_waiting;
    if (failed != _failed && mounted) {
      setState(() => _failed = failed);
      // Fernbedienung: Fokus in die Fehlerknöpfe, die Bedienleiste darunter ist gesperrt
      // Kurz warten: das Sperren der Leiste (ExcludeFocus) setzt den Fokus sonst im selben Frame zurück
      if (failed) {
        Timer(const Duration(milliseconds: 200), () {
          if (mounted && _failed && _errorBtn.context != null) _errorBtn.requestFocus();
        });
      }
    }
    if (_introFrom == null && _introEligible(s)) _introFrom = s.position;
    // Countdown abgelaufen: nächste Folge
    if (!_advancing && (_nextProgress(s) ?? 0) >= 1) {
      _advancing = true;
      _autoAdvance();
    }
  }

  /// Fehler, aber es wird noch versucht (Neuverbinden oder Schonfrist vor dem Playerwechsel).
  bool get _waiting => _retryTimer?.isActive == true || _graceTimer?.isActive == true;

  void _completed() {
    if (_cur.live || !mounted) return;
    _saveProgress();
    if (_advancing) return;
    if (store.get('autoNext', true) && _hasNext && !_stopAtEnd) {
      _advancing = true;
      _autoAdvance();
    } else {
      Navigator.maybePop(context);
    }
  }

  void _autoAdvance() {
    _autoChain++;
    _play(_i + 1);
  }

  Future<void> _play(int i, {bool retry = false}) async {
    if (!retry) _saveProgress();
    final n = widget.list.length;
    i = (i % n + n) % n;
    final id = ++_openId;
    if (!retry && i != _i) _lastIndex = _i;
    setState(() {
      _i = i;
      if (!retry) {
        _everPlayed = false;
        _openedAt = DateTime.now();
        _graceRetried = false;
        _graceTimer?.cancel();
        _epg = [];
        _nextDismissed = false;
        _introDone = false;
        _introFrom = null;
        // „Ende dieser Folge“ gilt nur für die Folge, bei der er gestellt wurde
        if (_stopAtEnd) {
          _stopAtEnd = false;
          _sleepAt = null;
        }
      }
    });
    // Alten Stand verwerfen: sonst zählt der Abspann-Countdown der vorigen Folge weiter
    if (!retry) _e.state.value = const PlaybackState();
    final item = _cur;
    if (item.live) store.addRecentLive(widget.source, item.item);
    Duration? start;
    if (!item.live && store.get('resume', true) && !(widget.fromStart && _first)) start = store.resumeAt(item.url);
    _first = false;

    // Heruntergeladen? Dann offline aus der Datei abspielen
    var url = downloads.localFile(item.url) ?? item.url;
    if (url.startsWith('stalker:')) {
      try {
        url = await Repo.stalkerResolve(widget.source, url);
      } catch (e) {
        if (mounted && id == _openId) _e.state.value = PlaybackState(buffering: false, error: '$e');
        return;
      }
    }
    // Während des Ladens weitergezappt: diesen Aufruf verwerfen
    if (!mounted || id != _openId) return;
    final (cleanUrl, headers) = Engine.splitHeaders(url, Repo.streamHeaders(widget.source));
    await _e.open(cleanUrl, headers, start: start);
    if (!mounted || id != _openId) return;
    _advancing = false;
    _capQuality(id);
    final rate = store.get('defaultRate', 1.0);
    if (!item.live && rate != 1.0) _e.setRate(rate);
    if (_muted || _volume != 1) _e.setVolume(_muted ? 0 : _volume);
    // Mehrere Folgen ohne jede Eingabe: nachfragen statt ewig weiterzuspielen
    if (!item.live && _autoChain >= 3 && store.get('stillWatching', true)) {
      _e.pause();
      setState(() => _askStill = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _stillBtn.context != null) _stillBtn.requestFocus();
      });
    }
    if (item.live && widget.source.type == SourceType.xtream && !retry) {
      Repo.xtreamEpg(widget.source, item.item.id)
          .then((e) {
            if (mounted && id == _openId) setState(() => _epg = e);
          })
          .catchError((_) {});
    }
  }

  /// Daten sparen: höchstens die eingestellte Auflösung. Spuren sind erst kurz nach dem Start bekannt.
  Future<void> _capQuality(int id) async {
    final max = store.get('maxRes', 0);
    if (max <= 0) return;
    for (final wait in const [700, 2000, 4000]) {
      await Future.delayed(Duration(milliseconds: wait));
      if (!mounted || id != _openId || _e.qualityId != null) return;
      final label = await _e.capQuality(max);
      if (label != null) {
        if (mounted) _flash(tr('Daten sparen: {0}', [label]));
        return;
      }
    }
  }

  void _saveProgress() {
    if (_cur.live) return;
    final s = _e.state.value;
    if (s.duration > Duration.zero) {
      store.saveProgress(widget.source, _cur.item, _cur.url, _cur.title, s.position, s.duration);
    }
  }

  // ---------------- Steuerung ----------------

  void _show() {
    _hideTimer?.cancel();
    _autoChain = 0; // jemand schaut zu
    if (!_controls) {
      setState(() => _controls = true);
      // Fernbedienung: Fokus auf Play/Pause, damit Pfeile die Knöpfe erreichen
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controls && _root.hasPrimaryFocus) _playBtn.requestFocus();
      });
    }
    _hideTimer = Timer(Duration(seconds: store.get('hideSec', 5)), _hide);
  }

  void _hide() {
    _hideTimer?.cancel();
    if (!mounted || _e.state.value.error != null) return;
    setState(() => _controls = false);
    _root.requestFocus();
  }

  void _flash(String text) {
    _toastTimer?.cancel();
    setState(() => _toast = text);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  void _zap(int delta) {
    if (widget.list.length < 2) return;
    if (store.get('zapInvert', false)) delta = -delta;
    _play(_i + delta);
    _flash('${_i + 1}  ${_cur.title}');
  }

  void _next() {
    if (!_hasNext) return;
    _autoChain = 0;
    _play(_i + 1);
  }

  void _prev() {
    if (_cur.live || _i == 0) return;
    _autoChain = 0;
    _play(_i - 1);
  }

  void _skipIntro() {
    setState(() => _introDone = true);
    _seek(_introSkip, show: false);
    _flash(tr('Intro übersprungen'));
  }

  /// Zifferntasten: Sendernummer eingeben, nach 1,5 s umschalten.
  void _digit(int d) {
    _digitTimer?.cancel();
    _digits = '$_digits$d';
    if (_digits.length > 4) _digits = _digits.substring(_digits.length - 4);
    _flash(_digits);
    _digitTimer = Timer(const Duration(milliseconds: 1500), () {
      final n = int.tryParse(_digits) ?? 0;
      _digits = '';
      if (n >= 1 && n <= widget.list.length) {
        _play(n - 1);
        _flash('$n  ${widget.list[n - 1].title}');
      }
    });
  }

  void _seek(int seconds, {bool show = true}) {
    if (_cur.live) return;
    final s = _e.state.value;
    var p = s.position + Duration(seconds: seconds);
    if (p < Duration.zero) p = Duration.zero;
    if (s.duration > Duration.zero && p > s.duration) p = s.duration;
    _e.seek(p);
    if (show) _show();
  }

  /// Doppeltippen (Handy): Sprünge summieren sich wie bei Netflix („+30 s“).
  void _doubleTapSeek(int seconds) {
    if (_cur.live) return;
    _tapSeekTimer?.cancel();
    _tapSeek = _tapSeek.sign == seconds.sign ? _tapSeek + seconds : seconds;
    _seek(seconds, show: false);
    _flash('${_tapSeek > 0 ? '+' : '−'}${_tapSeek.abs()} s');
    _tapSeekTimer = Timer(const Duration(milliseconds: 900), () => _tapSeek = 0);
  }

  void _toggleMute() {
    _muted = !_muted;
    if (!_muted && _volume == 0) _volume = 1;
    _e.setVolume(_muted ? 0 : _volume);
    _flash(_muted ? tr('Ton aus') : tr('Ton an'));
  }

  void _setVolume(double v, {bool flash = true}) {
    _volume = v.clamp(0, _e.maxVolume).toDouble();
    _muted = _volume == 0;
    _e.setVolume(_volume);
    flash ? _flash(tr('Lautstärke {0} %', [(_volume * 100).round()])) : setState(() {});
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen ? await defaultExitNativeFullscreen() : await defaultEnterNativeFullscreen();
    if (mounted) setState(() => _fullscreen = !_fullscreen);
  }

  void _continueWatching() {
    _autoChain = 0;
    setState(() => _askStill = false);
    _e.play();
    _show();
  }

  static final _navKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  static final _digitKeys = {
    for (var d = 0; d <= 9; d++) ...{
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + d): d,
      LogicalKeyboardKey(LogicalKeyboardKey.numpad0.keyId + d): d,
    },
  };

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final nav = _navKeys.contains(k);
    _autoChain = 0;
    // Fehleranzeige und „Schaust du noch?“: Pfeile wechseln zwischen deren Knöpfen (nicht Spulen/
    // Senderwechsel). Flutters eigene Richtungssuche findet dort keinen Nachbarn und gibt den Fokus ab.
    final btns = _failed
        ? [_errorBtn, if (_errorAlt.context != null) _errorAlt, ..._errorExt.where((n) => n.context != null), _errorBack]
        : _askStill
        ? [_stillBtn, _stillBack]
        : null;
    if (_askStill && !nav) return KeyEventResult.ignored;
    if (btns != null && nav) {
      final i = btns.indexWhere((b) => b.hasPrimaryFocus);
      if (i < 0) {
        btns.first.requestFocus();
      } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
        btns[(i + (k == LogicalKeyboardKey.arrowRight ? 1 : -1)).clamp(0, btns.length - 1)].requestFocus();
      } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
        // nur eine Reihe
      } else {
        return KeyEventResult.ignored; // OK: der Knopf selbst
      }
      return KeyEventResult.handled;
    }
    // Fernbedienung: Bedienleiste oder Fehler sichtbar, aber nichts fokussiert: erst in die Knöpfe springen
    if (nav && !_desktop && _root.hasPrimaryFocus) {
      final target = _e.state.value.error != null ? _errorBtn : (_controls ? _playBtn : null);
      if (target?.context != null) {
        target!.requestFocus();
        _show();
        return KeyEventResult.handled;
      }
    }
    // Gehaltene Taste: Spulschritt wächst (bis 6x)
    _repeat = e is KeyRepeatEvent ? _repeat + 1 : 0;
    final step = _step * (1 + _repeat ~/ 4).clamp(1, 6);
    // Medientasten und Ziffern funktionieren immer
    if (_cur.live && widget.list.length > 1 && _digitKeys.containsKey(k)) {
      _digit(_digitKeys[k]!);
      return KeyEventResult.handled;
    }
    switch (k) {
      case LogicalKeyboardKey.mediaPlayPause:
        _e.playOrPause();
        _show();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaPlay:
        _e.play();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaPause:
        _e.pause();
        _show();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaFastForward:
        _seek(step * 3);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaRewind:
        _seek(-step * 3);
        return KeyEventResult.handled;
      // Fernbedienungs-Tasten
      case LogicalKeyboardKey.mediaStop || LogicalKeyboardKey.exit:
        Navigator.maybePop(context);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.info:
        _info();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.guide || LogicalKeyboardKey.tv:
        _cur.live ? _channelList() : _episodes();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.closedCaptionToggle ||
          LogicalKeyboardKey.subtitle ||
          LogicalKeyboardKey.mediaAudioTrack ||
          LogicalKeyboardKey.colorF1Green:
        _audioSubs();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.colorF0Red when widget.source.id != 'link':
        toggleFav(context, widget.source, _cur.item);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.colorF2Yellow:
        _qualityMenu();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.colorF3Blue || LogicalKeyboardKey.settings || LogicalKeyboardKey.mediaTopMenu:
        _morePanel();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaLast when _cur.live && _lastIndex != null:
        _play(_lastIndex!);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.channelUp || LogicalKeyboardKey.pageUp || LogicalKeyboardKey.mediaTrackNext:
        _cur.live ? _zap(1) : _next();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.channelDown || LogicalKeyboardKey.pageDown || LogicalKeyboardKey.mediaTrackPrevious:
        _cur.live ? _zap(-1) : _prev();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF when _desktop:
        _toggleFullscreen();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape when _fullscreen:
        _toggleFullscreen();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyM:
        _toggleMute();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyN when _hasNext:
        _next();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyS when _introVisible(_e.state.value):
        _skipIntro();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.space || LogicalKeyboardKey.keyK when _desktop:
        _e.playOrPause();
        _show();
        return KeyEventResult.handled;
    }
    // PC: Pfeile spulen und regeln die Lautstärke immer (wie im Browser-Player), dazu YouTube-Tasten
    if (_desktop) {
      if (!_cur.live && _digitKeys.containsKey(k)) {
        // 0–9: zu 0 %, 10 % … 90 % springen
        final d = _e.state.value.duration;
        _e.seek(d * (_digitKeys[k]! / 10));
        _show();
        return KeyEventResult.handled;
      }
      switch (k) {
        case LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.keyJ when !_cur.live:
          _seek(k == LogicalKeyboardKey.keyJ ? -10 : -step);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.keyL when !_cur.live:
          _seek(k == LogicalKeyboardKey.keyL ? 10 : step);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.home when !_cur.live:
          _e.seek(Duration.zero);
          _show();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.bracketLeft || LogicalKeyboardKey.bracketRight when !_cur.live:
          final r = (_e.rate + (k == LogicalKeyboardKey.bracketRight ? .25 : -.25)).clamp(.25, 3.0);
          _e.setRate(r);
          _flash('${r}x');
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyC:
          _audioSubs();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyI:
          _info();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.escape when !_fullscreen:
          Navigator.maybePop(context);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp when !_cur.live:
          _setVolume(_volume + .1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown when !_cur.live:
          _setVolume(_volume - .1);
          return KeyEventResult.handled;
      }
    }
    if (_controls) {
      _show(); // jede Taste verlängert die Anzeige
      return KeyEventResult.ignored;
    }
    switch (k) {
      case LogicalKeyboardKey.arrowUp:
        _cur.live ? _zap(-1) : _show();
      case LogicalKeyboardKey.arrowDown:
        _cur.live ? _zap(1) : _show();
      case LogicalKeyboardKey.arrowLeft:
        _cur.live ? _channelList() : _seek(-step);
      case LogicalKeyboardKey.arrowRight:
        _cur.live ? _show() : _seek(step);
      case LogicalKeyboardKey.select || LogicalKeyboardKey.enter || LogicalKeyboardKey.gameButtonA:
        // OK: im Abspann zur nächsten Folge, am Anfang Intro überspringen
        final s = _e.state.value;
        if (_nextProgress(s) != null) {
          _next();
        } else if (_introVisible(s)) {
          _skipIntro();
        } else {
          _show();
        }
      case LogicalKeyboardKey.contextMenu:
        _cur.live ? _channelList() : _episodes();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---------------- Menüs ----------------

  Future<void> _menu(Future<void> Function() f) async {
    _hideTimer?.cancel();
    await f();
    if (mounted) _show();
  }

  /// Seitenleiste (rechts oder links) für Folgen, Ton & Untertitel, Qualität, Mehr.
  Future<T?> _panel<T>(
    String label,
    Widget Function(BuildContext c, StateSetter setPanel) builder, {
    double width = 400,
    bool left = false,
  }) => showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: label,
    barrierColor: Colors.black38,
    transitionDuration: store.anim,
    transitionBuilder: (_, a, _, child) => SlideTransition(
      position: Tween(
        begin: Offset(left ? -1 : 1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
    pageBuilder: (c, _, _) => Align(
      alignment: left ? Alignment.centerLeft : Alignment.centerRight,
      child: Material(
        color: surface.withValues(alpha: .97),
        child: SizedBox(
          width: math.min(width, MediaQuery.sizeOf(c).width * .92),
          height: double.infinity,
          child: SafeArea(child: StatefulBuilder(builder: builder)),
        ),
      ),
    ),
  );

  Widget _panelTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
    child: Text(text, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
  );

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 18, 14, 6),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(color: textDim, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1),
    ),
  );

  Widget _option(String label, bool selected, VoidCallback onTap, {bool autofocus = false, String? value}) => Tap(
    fill: true,
    scale: 1,
    autofocus: autofocus,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          SizedBox(width: 30, child: selected ? Icon(Icons.check_rounded, size: 20, color: store.accent) : null),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 15, fontWeight: selected ? FontWeight.w800 : FontWeight.w500),
            ),
          ),
          if (value != null) Text(value, style: const TextStyle(color: textDim)),
        ],
      ),
    ),
  );

  /// Ton & Untertitel in einem Fenster (wie Netflix).
  void _audioSubs() => _menu(() async {
    final audio = await _e.audioTracks();
    final subs = await _e.subtitleTracks();
    if (!mounted) return;
    await _panel<void>(tr('Ton & Untertitel'), (c, setPanel) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(10, 24, 10, 24),
        children: [
          _panelTitle(tr('Ton & Untertitel')),
          _section(tr('Tonspur')),
          if (audio.isEmpty) _option(tr('Standard'), true, () {}, autofocus: true),
          for (final (i, t) in audio.indexed)
            _option(t.label, t.id == _e.audioId || (_e.audioId == null && i == 0), () async {
              await _e.selectAudio(t.id);
              setPanel(() {});
            }, autofocus: t.id == _e.audioId || (_e.audioId == null && i == 0)),
          _section(tr('Untertitel')),
          if (subs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                _e is ExoEngine
                    ? tr('Untertitel: in den Einstellungen Player „mpv“ wählen')
                    : tr('Keine Untertitel vorhanden'),
                style: const TextStyle(color: textDim),
              ),
            ),
          for (final t in subs)
            _option(t.label, t.id == (_e.subtitleId ?? (store.get('subsOn', false) ? 'auto' : 'no')), () async {
              await _e.selectSubtitle(t.id);
              setPanel(() {});
            }),
        ],
      );
    });
  });

  /// Auflösung wählen: Automatisch oder feste Qualität (HLS/DASH-Varianten).
  void _qualityMenu() => _menu(() async {
    final list = await _e.qualities();
    if (!mounted) return;
    final size = _e.state.value.size;
    await _panel<void>(tr('Qualität'), (c, setPanel) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(10, 24, 10, 24),
        children: [
          _panelTitle(tr('Qualität')),
          _option(
            tr('Automatisch'),
            _e.qualityId == null,
            () async {
              await _e.selectQuality(null);
              setPanel(() {});
            },
            autofocus: _e.qualityId == null,
            value: _quality(size),
          ),
          for (final q in list)
            _option(q.label, q.id == _e.qualityId, () async {
              await _e.selectQuality(q.id);
              setPanel(() {});
              if (mounted) _flash(tr('Qualität: {0}', [q.label]));
            }, autofocus: q.id == _e.qualityId),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                // Echte Auflösung zeigen: IPTV-Sender und Filme kommen meist nur in einer Qualität
                _quality(size) == null
                    ? tr('Der Stream bietet nur eine Qualität an.')
                    : tr(
                        'Der Anbieter sendet diesen Stream nur in {0} ({1} × {2}). Andere Auflösungen gibt es nur, wenn der Anbieter sie mitliefert, z. B. als eigener 4K-/UHD-Sender.',
                        [_quality(size), size.width.round(), size.height.round()],
                      ),
                style: const TextStyle(color: textDim),
              ),
            ),
        ],
      );
    });
  });

  void _fitMenu() => _menu(() async {
    final f = await pick(context, tr('Bildformat'), {
      for (final e in fits.entries) e.key: e.value.$1,
    }, current: _fit);
    if (f != null) setState(() => _fit = f);
  });

  void _rateMenu() => _menu(() async {
    final r = await pick(context, tr('Geschwindigkeit'), {
      for (final r in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]) r: r == 1.0 ? tr('1x (Normal)') : '${r}x',
    }, current: _e.rate);
    if (r != null) {
      await _e.setRate(r);
      if (mounted) setState(() {});
    }
  });

  void _sleepMenu() => _menu(() async {
    final m = await pick(context, tr('Sleep-Timer'), {
      0: tr('Aus'),
      15: tr('{0} Minuten', [15]),
      30: tr('{0} Minuten', [30]),
      60: tr('1 Stunde'),
      90: tr('{0} Minuten', [90]),
      120: tr('2 Stunden'),
      if (!_cur.live) -1: tr('Ende dieser Folge'),
    }, current: _sleepAt == null ? 0 : null);
    if (m == null) return;
    _sleepTimer?.cancel();
    final s = _e.state.value;
    // „Ende dieser Folge“: keine Abspann-Karte, am Ende schließen statt weiterspielen
    _stopAtEnd = m == -1;
    if (_stopAtEnd) _nextDismissed = true;
    final d = _stopAtEnd
        ? Duration(milliseconds: ((s.duration - s.position).inMilliseconds / (_e.rate == 0 ? 1 : _e.rate)).round())
        : Duration(minutes: m);
    setState(() => _sleepAt = m == 0 ? null : DateTime.now().add(d));
    if (m > 0) {
      _sleepTimer = Timer(d, () {
        _e.pause();
        if (mounted) Navigator.maybePop(context);
      });
    }
    if (m != 0 && mounted) toast(context, tr('Wiedergabe stoppt in {0} Minuten', [d.inMinutes]));
  });

  void _channelList() => _menu(() async {
    final i = await _panel<int>(tr('Senderliste'), left: true, width: 380, (c, _) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
        itemCount: widget.list.length,
        itemExtent: 58,
        // Zum aktuellen Sender scrollen
        controller: ScrollController(initialScrollOffset: (_i * 58.0 - 200).clamp(0, double.infinity)),
        itemBuilder: (_, j) => Tap(
          fill: true,
          scale: 1,
          autofocus: j == _i,
          onTap: () => Navigator.pop(c, j),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Text(
                  '${j + 1}',
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: textDim),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 48,
                height: 34,
                child: Artwork(widget.list[j].item.logo, widget.list[j].title, fit: BoxFit.contain, width: 48),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.list[j].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: j == _i ? FontWeight.w800 : FontWeight.w500,
                    color: j == _i ? store.accent : Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
    if (i != null && i != _i) _play(i);
  });

  /// Folgenliste mit Staffelwahl, Bild, Handlung und Fortschritt.
  void _episodes() => _menu(() async {
    if (widget.list.length < 2) return;
    final seasons = {for (final p in widget.list) p.episode?.season ?? 0}.toList()..sort();
    var season = _cur.episode?.season ?? seasons.first;
    final i = await _panel<int>(tr('Folgen'), width: 480, (c, setPanel) {
      final shown = [
        for (final (j, p) in widget.list.indexed)
          if ((p.episode?.season ?? 0) == season) j,
      ];
      return ListView(
        padding: const EdgeInsets.fromLTRB(10, 24, 10, 24),
        children: [
          _panelTitle(_cur.item.name),
          if (seasons.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in seasons)
                    Pill(
                      s == 0 ? tr('Folgen') : tr('Staffel {0}', [s]),
                      selected: s == season,
                      onTap: () => setPanel(() => season = s),
                    ),
                ],
              ),
            ),
          for (final j in shown) _episodeRow(c, j),
        ],
      );
    });
    if (i != null && i != _i) {
      _autoChain = 0;
      _play(i);
    }
  });

  Widget _episodeRow(BuildContext c, int j) {
    final p = widget.list[j];
    final ep = p.episode;
    final current = j == _i;
    final progress = store.progressOf(p.url);
    return Tap(
      fill: true,
      scale: 1,
      autofocus: current,
      onTap: () => Navigator.pop(c, j),
      child: Container(
        padding: const EdgeInsets.all(10),
        color: current ? Colors.white.withValues(alpha: .06) : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 34,
              child: Text(
                '${ep?.number ?? j + 1}',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: current ? store.accent : textDim),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 128,
                height: 72,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Artwork(ep?.image ?? p.item.logo, p.title, width: 128),
                    if (current)
                      const ColoredBox(color: Colors.black45, child: Icon(Icons.equalizer_rounded, size: 30)),
                    if (progress > 0)
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 3,
                          color: store.accent,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ep?.title.isNotEmpty == true ? ep!.title : p.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, color: current ? store.accent : Colors.white),
                  ),
                  if (ep?.plot != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      ep!.plot!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: textDim, fontSize: 12.5, height: 1.3),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _shortcuts() => _menu(() async {
    final rows = [
      (tr('Leertaste'), tr('Play/Pause')),
      ('← →', tr('{0} s spulen', [_step])),
      ('↑ ↓', tr('Lautstärke')),
      ('F', tr('Vollbild')),
      ('M', tr('Ton aus/an')),
      ('N', tr('Nächste Folge')),
      ('S', tr('Intro überspringen')),
      ('J · K · L', tr('10 s zurück · Pause · 10 s vor')),
      ('0–9', tr('Sprung zu 0–90 % (Film) · Sendernummer (Live)')),
      ('[ ]', tr('Tempo langsamer / schneller')),
      ('C · I', tr('Ton & Untertitel · Info')),
      (tr('Mausrad'), tr('Lautstärke')),
      (tr('Rechtsklick'), tr('Mehr')),
      ('Esc', tr('Vollbild beenden · Zurück')),
    ];
    await showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Tastenkürzel')),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (k, v) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(k, style: const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      Expanded(
                        child: Text(v, style: const TextStyle(color: textDim)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(d), autofocus: true, child: const Text('OK'))],
      ),
    );
  });

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final cur = _cur;
    // Programmführer (XMLTV) bevorzugt, sonst Xtream-Kurz-EPG
    final guide = epg.of(widget.source, cur.item.epgId).where((p) => p.stop.isAfter(DateTime.now()));
    final now = guide.isNotEmpty
        ? [for (final p in guide.take(2)) (title: p.title, start: p.start, end: p.stop)]
        : _epg.where((e) => e.end.isAfter(DateTime.now())).toList();
    final pip = _pip(context);

    return PopScope(
      canPop: !_controls || !_tv || _failed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hide();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _root,
          autofocus: true,
          onKeyEvent: _key,
          child: MouseRegion(
            onHover: (_) => _show(),
            cursor: _controls ? SystemMouseCursors.basic : SystemMouseCursors.none,
            // PC: Mausrad regelt die Lautstärke
            child: Listener(
              onPointerSignal: (e) {
                if (e is PointerScrollEvent && _desktop && !_locked) {
                  _setVolume(_volume + (e.scrollDelta.dy < 0 ? .05 : -.05));
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _controls ? _hide() : _show(),
                onSecondaryTap: _desktop ? _morePanel : null,
                // Handy: waagerecht wischen spult, rechts senkrecht wischen ändert die Lautstärke
                onHorizontalDragUpdate: _phone && !_locked && !_cur.live
                    ? (d) {
                        _dragSeek = (_dragSeek ?? 0) + d.delta.dx / MediaQuery.sizeOf(context).width * 180;
                        final target = _e.state.value.position + Duration(seconds: _dragSeek!.round());
                        _flash(
                          '${_dragSeek! >= 0 ? '+' : '−'}${fmtDuration(Duration(seconds: _dragSeek!.abs().round()))}  ·  ${fmtDuration(target < Duration.zero ? Duration.zero : target)}',
                        );
                      }
                    : null,
                onHorizontalDragEnd: _phone && !_locked && !_cur.live
                    ? (_) {
                        if (_dragSeek != null) _seek(_dragSeek!.round());
                        _dragSeek = null;
                      }
                    : null,
                onVerticalDragUpdate: _phone && !_locked
                    ? (d) {
                        if (d.localPosition.dx > MediaQuery.sizeOf(context).width / 2) {
                          _setVolume(_volume - d.delta.dy / 300);
                        } else if (_cur.live && _dragZap != null) {
                          // Links wischen: ein Senderwechsel pro Geste
                          _dragZap = _dragZap! + d.delta.dy;
                          if (_dragZap!.abs() > 70) {
                            _zap(_dragZap! < 0 ? 1 : -1);
                            _dragZap = null;
                          }
                        }
                      }
                    : null,
                onVerticalDragStart: _phone && !_locked ? (_) => _dragZap = 0 : null,
                onDoubleTapDown: _locked
                    ? null
                    : (d) {
                        if (_desktop) {
                          _toggleFullscreen();
                        } else {
                          _doubleTapSeek(d.localPosition.dx < MediaQuery.sizeOf(context).width / 2 ? -_step : _step);
                        }
                      },
                onDoubleTap: _locked ? null : () {},
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _video(),
                    // Nur Ton (Radio): Logo statt schwarzem Bild
                    ValueListenableBuilder(
                      valueListenable: _e.state,
                      builder: (_, s, _) => s.playing && s.size.isEmpty && s.error == null
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 160,
                                    height: 100,
                                    child: Artwork(cur.item.logo, cur.title, fit: BoxFit.contain, width: 160),
                                  ),
                                  const SizedBox(height: 14),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.graphic_eq_rounded, color: Colors.white70),
                                      const SizedBox(width: 8),
                                      Text(tr('Nur Ton'), style: const TextStyle(color: Colors.white70)),
                                    ],
                                  ),
                                ],
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    ValueListenableBuilder(
                      valueListenable: _e.state,
                      builder: (_, s, _) => (s.error == null ? !s.buffering : !_waiting)
                          ? const SizedBox.shrink()
                          : Stack(
                              children: [
                                const Center(
                                  child: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                                  ),
                                ),
                                // Unterhalb des großen Play-Knopfs der Bedienleiste
                                if (s.error != null)
                                  Align(
                                    alignment: const Alignment(0, .3),
                                    child: Text(
                                      _graceTimer?.isActive == true
                                          ? tr('Versuche weiter …')
                                          : tr('Verbinde neu … ({0}/5)', [_retries]),
                                      style: const TextStyle(color: Colors.white70),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    if (_toast != null && !_controls)
                      Positioned(
                        top: 36,
                        right: 40,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .75),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(_toast!, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    if (!pip)
                      IgnorePointer(
                        ignoring: !_controls,
                        child: AnimatedOpacity(
                          opacity: _controls ? 1 : 0,
                          duration: store.anim * 1.5,
                          child: ExcludeFocus(excluding: !_controls || _failed, child: _overlay(cur, now)),
                        ),
                      ),
                    // Intro überspringen / Abspann mit nächster Folge: auch ohne Bedienleiste
                    if (!pip && !_locked)
                      ValueListenableBuilder(
                        valueListenable: _e.state,
                        builder: (_, s, _) {
                          final next = _nextProgress(s);
                          final bottom = _controls ? (_tv ? 170.0 : 140.0) : 40.0;
                          if (next != null) {
                            return Positioned(right: _tv ? 48 : 28, bottom: bottom, child: _nextCard(next));
                          }
                          final intro = _introProgress(s);
                          if (intro != null) {
                            return Positioned(
                              right: _tv ? 48 : 28,
                              bottom: bottom,
                              child: _GhostButton(
                                tr('Intro überspringen'),
                                Icons.fast_forward_rounded,
                                _skipIntro,
                                progress: intro,
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    if (_askStill && !pip) _stillWatchingView(),
                    // Fehler zuletzt: liegt immer vorne, auch über Bedienleiste und Abspann-Karte
                    if (_failed && _e.state.value.error != null) _errorView(_e.state.value.error!),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Video im gewählten Bildformat.
  Widget _video() {
    final (_, fit, aspect) = fits[_fit]!;
    if (aspect != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(child: AspectRatio(aspectRatio: aspect, child: _e.view(BoxFit.fill))),
      );
    }
    if (fit != BoxFit.none) return _e.view(fit);
    // Original: ein Videopixel = ein Bildschirmpixel, mittig, Rand schwarz oder beschnitten
    return ValueListenableBuilder(
      valueListenable: _e.state,
      builder: (context, s, _) {
        if (s.size.isEmpty) return _e.view(BoxFit.contain);
        final px = s.size / MediaQuery.devicePixelRatioOf(context);
        return ColoredBox(
          color: Colors.black,
          child: ClipRect(
            child: OverflowBox(
              // 1:1 auch bei Videos kleiner als der Bildschirm (sonst gilt die Bildschirmgröße als Minimum)
              minWidth: 0,
              minHeight: 0,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: SizedBox(width: px.width, height: px.height, child: _e.view(BoxFit.fill)),
            ),
          ),
        );
      },
    );
  }

  /// Bild-in-Bild-Fenster: winzig, keine Bedienelemente.
  bool _pip(BuildContext c) {
    final sz = MediaQuery.sizeOf(c);
    return Platform.isAndroid && sz.width < 420 && sz.height < 320;
  }

  /// Abspann-Karte: nächste Folge mit Bild und füllendem Countdown-Knopf.
  Widget _nextCard(double progress) {
    final next = widget.list[_i + 1];
    final ep = next.episode;
    final countdown = store.get('nextCountdown', 10);
    final auto = store.get('autoNext', true) && countdown > 0;
    final left = (countdown * (1 - progress)).ceil();
    return Container(
      width: 380,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xF0141416),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 30)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 130,
                  height: 74,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Artwork(ep?.image ?? next.item.logo, next.title, width: 130),
                      const ColoredBox(color: Colors.black26, child: Icon(Icons.play_circle_outline_rounded, size: 34)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Nächste Folge').toUpperCase(),
                      style: TextStyle(
                        color: store.accent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      next.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, height: 1.25),
                    ),
                    if (ep?.plot != null)
                      Text(
                        ep!.plot!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: textDim, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _CountdownButton(
                  label: auto ? tr('Nächste Folge in {0}', [left]) : tr('Nächste Folge'),
                  progress: auto ? progress : 1,
                  autofocus: !_controls,
                  onTap: _next,
                ),
              ),
              const SizedBox(width: 8),
              _GhostButton(tr('Abspann'), Icons.close_rounded, () => setState(() => _nextDismissed = true)),
            ],
          ),
        ],
      ),
    );
  }

  /// „Schaust du noch?“ nach mehreren Folgen ohne Eingabe.
  Widget _stillWatchingView() => Positioned.fill(
    child: ColoredBox(
      color: Colors.black.withValues(alpha: .82),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Schaust du noch „{0}“?', [_cur.item.name]),
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -.5),
                ),
                const SizedBox(height: 22),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    Pill(
                      tr('Weiter ansehen'),
                      icon: Icons.play_arrow_rounded,
                      primary: true,
                      autofocus: true,
                      focusNode: _stillBtn,
                      onTap: _continueWatching,
                    ),
                    Pill(tr('Zurück'), icon: Icons.arrow_back_rounded, focusNode: _stillBack,
                        onTap: () => Navigator.maybePop(context)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  void _recordMenu() => _menu(() async {
    final m = await pick(context, tr('Aufnehmen'), {
      15: tr('{0} Minuten', [15]),
      30: tr('{0} Minuten', [30]),
      60: tr('1 Stunde'),
      120: tr('2 Stunden'),
      180: tr('{0} Stunden', [3]),
    });
    if (m == null || !mounted) return;
    try {
      downloads.record(widget.source, _cur.item, _cur.url, m);
      toast(context, tr('Aufnahme läuft ({0} min). Zu finden unter Downloads.', [m]));
    } catch (e) {
      toast(context, explain(e));
    }
  });

  void _info() => _menu(() async {
    final s = _e.state.value;
    final host = Uri.tryParse(_cur.url.split('|').first)?.host ?? '';
    final stats = await _e.stats();
    if (!mounted) return;
    final rows = <(String, String)>[
      (tr('Auflösung'), s.size.isEmpty ? tr('Nur Ton') : '${s.size.width.round()} × ${s.size.height.round()}'),
      (tr('Player'), _e is ExoEngine ? 'ExoPlayer' : 'mpv'),
      if (!_cur.live) (tr('Dauer'), fmtDuration(s.duration)),
      (tr('Puffer'), fmtDuration(s.buffered - s.position < Duration.zero ? Duration.zero : s.buffered - s.position)),
      if (host.isNotEmpty) (tr('Server'), host),
      for (final e in stats.entries) (tr(e.key), e.value),
      if (downloads.localFile(_cur.url) != null) (tr('Quelle'), tr('Offline verfügbar')),
    ];
    await showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_cur.title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (k, v) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text(k, style: const TextStyle(color: textDim)),
                      ),
                      Expanded(
                        child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(d), autofocus: true, child: const Text('OK'))],
      ),
    );
  });

  /// Gleiche Stelle im externen Player weiterschauen; der eigene Player schließt sich.
  void _openExternal(String id) {
    final s = _e.state.value;
    final start = _cur.live || s.position <= Duration.zero ? null : s.position;
    _saveProgress();
    final nav = Navigator.of(context);
    final below = nav.context;
    nav.pop();
    playExternal(below, widget.source, _cur, id, start: start);
  }

  void _switchEngine() {
    store.set('engine', _e is ExoEngine ? 'mpv' : 'exo');
    _replace(null);
  }

  /// Gleiche Liste und Folge mit anderem Player neu öffnen (Position kommt aus dem Verlauf).
  void _replace(String? engine) {
    _saveProgress();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: PlayerScreen.route),
        builder: (_) => PlayerScreen(source: widget.source, list: widget.list, index: _i, engine: engine),
      ),
    );
  }

  /// Abgedunkelt über allem; Tippen daneben schließt nichts und blendet nichts ein.
  Widget _errorView(String error) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () {},
    child: ColoredBox(
      color: Colors.black.withValues(alpha: .85),
      child: Center(child: _errorBody(error)),
    ),
  );

  Widget _errorBody(String error) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline_rounded, size: 46, color: Colors.white70),
        const SizedBox(height: 12),
        Text(
          tr('Stream kann nicht abgespielt werden'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            explain(error, playback: true),
            textAlign: TextAlign.center,
            maxLines: 3,
            style: const TextStyle(color: textDim),
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            Pill(
              tr('Erneut versuchen'),
              icon: Icons.refresh,
              primary: true,
              autofocus: true,
              focusNode: _errorBtn,
              onTap: () {
                _retries = 0;
                _play(_i, retry: true);
              },
            ),
            if (Platform.isAndroid)
              Pill(_e is ExoEngine ? tr('Mit mpv versuchen') : tr('Mit ExoPlayer versuchen'),
                  focusNode: _errorAlt, onTap: _switchEngine),
            for (final (i, x) in _externals.indexed)
              Pill(tr('In {0} öffnen', [ExternalPlayer.names[x]]),
                  icon: Icons.open_in_new_rounded, focusNode: _errorExt[i], onTap: () => _openExternal(x)),
            Pill(tr('Zurück'), icon: Icons.arrow_back_rounded, focusNode: _errorBack, onTap: () => Navigator.maybePop(context)),
          ],
        ),
      ],
    ),
  );

  // ---------------- Bedienoberfläche ----------------

  /// "1080p", "4K" … aus der Bildgröße.
  static String? _quality(Size s) => s.isEmpty ? null : Engine.resolution(s.width.round(), s.height.round());

  String _time(DateTime d) =>
      MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: true);

  Widget _overlay(PlayItem cur, List<({String title, DateTime start, DateTime end})> now) {
    final pad = EdgeInsets.symmetric(horizontal: _tv ? 48 : 22, vertical: _tv ? 30 : 14);
    final multi = widget.list.length > 1;
    final compact = MediaQuery.sizeOf(context).width < 640;
    final series = cur.item.kind == Kind.series;
    if (_locked) {
      // Touch-Sperre: nur der Entsperr-Knopf ist sichtbar
      return SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: pad,
            child: _Chip(Icons.lock_rounded, tr('Entsperren'), () => setState(() => _locked = false), autofocus: true),
          ),
        ),
      );
    }
    // Serie: Serienname groß, Folge darunter (wie Netflix)
    final title = series ? cur.item.name : (cur.live && multi ? '${_i + 1}  ${cur.title}' : cur.title);
    final subtitle = series
        ? cur.title
        : cur.live
        ? (now.isEmpty ? cur.item.group : '${_time(now.first.start)}–${_time(now.first.end)}  ${now.first.title}')
        : (cur.title != cur.item.name ? cur.item.name : cur.item.group);
    return Stack(
      children: [
        // Verlauf oben und unten für Lesbarkeit
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xD9000000), Color(0x00000000), Color(0x00000000), Color(0xF2000000)],
                stops: [0, .3, .5, 1],
              ),
            ),
          ),
        ),
        // ---- oben: Titel, Infos, Uhr ----
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: SafeArea(
            child: Padding(
              padding: pad,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_tv) ...[
                    _Round(Icons.arrow_back_rounded, tr('Zurück'), () => Navigator.maybePop(context), size: 44),
                    const SizedBox(width: 12),
                  ],
                  if (cur.item.logo != null && cur.live) ...[
                    Container(
                      width: 64,
                      height: 44,
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
                      child: Artwork(cur.item.logo, cur.title, fit: BoxFit.contain, width: 64),
                    ),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: _tv ? 28 : 20, fontWeight: FontWeight.w800, letterSpacing: -.5),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (cur.live) const _Badge('LIVE', dot: true),
                      ValueListenableBuilder(
                        valueListenable: _e.state,
                        builder: (_, s, _) {
                          final q = _quality(s.size);
                          // Film/Folge: wann ist sie zu Ende (bei aktuellem Tempo)?
                          final left = s.duration - s.position;
                          final ends = !cur.live && s.duration > Duration.zero && !compact
                              ? DateTime.now().add(left * (1 / (_e.rate == 0 ? 1 : _e.rate)))
                              : null;
                          return Wrap(
                            spacing: 6,
                            children: [
                              if (ends != null) _Badge(tr('Ende {0}', [_time(ends)]), icon: Icons.schedule_rounded),
                              if (q != null) _Badge(q),
                            ],
                          );
                        },
                      ),
                      if (downloads.localFile(cur.url) != null)
                        _Badge(tr('Offline'), icon: Icons.download_done_rounded),
                      if (_sleepAt != null)
                        _Badge(
                          tr('Sleep {0} min', [_sleepAt!.difference(DateTime.now()).inMinutes]),
                          icon: Icons.bedtime_rounded,
                        ),
                      if (_muted) const _Badge('', icon: Icons.volume_off_rounded),
                      const Padding(padding: EdgeInsets.only(left: 6), child: Clock()),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        // ---- Mitte: große Knöpfe (Handy/TV; am PC unten in der Leiste) ----
        if (!_desktop)
          Center(
            child: FocusTraversalGroup(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (cur.live && multi)
                    _Round(Icons.skip_previous_rounded, tr('Sender zurück'), () => _zap(-1), size: 56)
                  else if (!cur.live)
                    _Round(Icons.replay_10_rounded, '−$_step s', () => _seek(-_step), size: 56),
                  SizedBox(width: compact ? 26 : 40),
                  _playPause(82),
                  SizedBox(width: compact ? 26 : 40),
                  if (cur.live && multi)
                    _Round(Icons.skip_next_rounded, tr('Sender vor'), () => _zap(1), size: 56)
                  else if (!cur.live)
                    _Round(Icons.forward_10_rounded, '+$_step s', () => _seek(_step), size: 56),
                ],
              ),
            ),
          ),
        // ---- unten: Fortschritt / Sendung und Werkzeuge ----
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            child: Padding(
              padding: pad,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (cur.live) _LiveBar(now: now) else _SeekBar(engine: _e, step: _step, onUse: _show),
                  SizedBox(height: _desktop ? 6 : 14),
                  _desktop ? _desktopBar(cur, multi) : _chipBar(cur, multi),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _playPause(double size) => ValueListenableBuilder(
    valueListenable: _e.state,
    builder: (_, s, _) => _Round(
      s.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
      tr('Play/Pause'),
      _e.playOrPause,
      size: size,
      focusNode: _playBtn,
      autofocus: true,
    ),
  );

  /// Werkzeuge als Liste: [Symbol, Beschriftung, Aktion].
  List<(IconData, String, VoidCallback)> _tools(PlayItem cur, bool multi) => [
    if (multi && cur.live) (Icons.format_list_bulleted_rounded, tr('Senderliste'), _channelList),
    if (_hasNext) (Icons.skip_next_rounded, tr('Nächste Folge'), _next),
    if (multi && !cur.live) (Icons.video_library_rounded, tr('Folgen'), _episodes),
    (Icons.subtitles_rounded, tr('Ton & Untertitel'), _audioSubs),
    (Icons.high_quality_rounded, tr('Qualität'), _qualityMenu),
    if (!cur.live) (Icons.speed_rounded, '${tr('Tempo')} ${_e.rate}x', _rateMenu),
    (Icons.aspect_ratio_rounded, fits[_fit]!.$1, _fitMenu),
    if (_phone) (Icons.lock_outline_rounded, tr('Sperren'), () => setState(() => _locked = true)),
    (Icons.more_horiz_rounded, tr('Mehr'), _morePanel),
  ];

  /// Handy/TV: beschriftete Knöpfe in einer Reihe.
  Widget _chipBar(PlayItem cur, bool multi) => FocusTraversalGroup(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [for (final (icon, label, onTap) in _tools(cur, multi)) _Chip(icon, label, onTap)]),
    ),
  );

  /// PC: Wiedergabe links, Titel in der Mitte, Werkzeuge als Symbole rechts.
  Widget _desktopBar(PlayItem cur, bool multi) => FocusTraversalGroup(
    child: Row(
      children: [
        _playPause(46),
        if (!cur.live) ...[
          _IconBtn(Icons.replay_10_rounded, '−$_step s (←)', () => _seek(-_step)),
          _IconBtn(Icons.forward_10_rounded, '+$_step s (→)', () => _seek(_step)),
        ] else if (multi) ...[
          _IconBtn(Icons.skip_previous_rounded, tr('Sender zurück'), () => _zap(-1)),
          _IconBtn(Icons.skip_next_rounded, tr('Sender vor'), () => _zap(1)),
        ],
        _IconBtn(
          _muted || _volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          tr('Ton aus/an (M)'),
          _toggleMute,
        ),
        SizedBox(
          width: 110,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: SliderComponentShape.noOverlay,
              activeTrackColor: store.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
            ),
            child: ExcludeFocus(
              child: Slider(
                value: (_muted ? 0.0 : _volume).clamp(0.0, _e.maxVolume),
                max: _e.maxVolume,
                onChanged: (v) => _setVolume(v, flash: false),
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            cur.item.kind == Kind.series ? '${cur.item.name}  ·  ${cur.title}' : cur.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 14),
        for (final (icon, label, onTap) in _tools(cur, multi)) _IconBtn(icon, label, onTap),
        _IconBtn(
          _fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
          '${tr('Vollbild')} (F)',
          _toggleFullscreen,
        ),
      ],
    ),
  );

  // ---------------- „Mehr“-Panel ----------------

  void _morePanel() => _menu(() async {
    await _panel<void>(tr('Mehr'), _moreContent);
  });

  Widget _moreContent(BuildContext c, StateSetter setPanel) {
    final cur = _cur;
    Widget row(IconData icon, String label, {String? value, VoidCallback? onTap, bool autofocus = false}) => Tap(
      fill: true,
      scale: 1,
      autofocus: autofocus,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 22, color: Colors.white70),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            if (value != null)
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: textDim),
                ),
              ),
          ],
        ),
      ),
    );
    // Regler mit − und + (Fernbedienung: links/rechts zwischen den Knöpfen)
    Widget stepper(IconData icon, String label, String value, VoidCallback minus, VoidCallback plus) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 22, color: Colors.white70),
          const SizedBox(width: 14),
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          _Round(Icons.remove_rounded, '−', () => setPanel(minus), size: 38),
          SizedBox(
            width: 70,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          _Round(Icons.add_rounded, '+', () => setPanel(plus), size: 38),
        ],
      ),
    );
    String secs(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} s';
    // Direkt geöffnete Links gehören zu keiner gespeicherten Quelle
    final canFav = widget.source.id != 'link';
    void close(VoidCallback then) {
      Navigator.pop(c);
      then();
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 28, 10, 24),
      children: [
        _panelTitle(tr('Mehr')),
        if (canFav)
          ListenableBuilder(
            listenable: store,
            builder: (_, _) => row(
              store.isFav(widget.source, cur.item) ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              store.isFav(widget.source, cur.item) ? tr('In Favoriten') : tr('Favorit'),
              autofocus: true,
              onTap: () => toggleFav(context, widget.source, cur.item),
            ),
          ),
        if (cur.live && _lastIndex != null && _lastIndex != _i)
          row(
            Icons.history_rounded,
            tr('Letzter Sender'),
            value: widget.list[_lastIndex!].title,
            autofocus: !canFav,
            onTap: () => close(() => _play(_lastIndex!)),
          ),
        if (!cur.live && _i > 0) row(Icons.skip_previous_rounded, tr('Vorherige Folge'), onTap: () => close(_prev)),
        if (cur.live) row(Icons.fiber_manual_record_rounded, tr('Aufnehmen'), onTap: () => close(_recordMenu)),
        row(
          Icons.bedtime_rounded,
          tr('Sleep-Timer'),
          value: _sleepAt == null ? tr('Aus') : '${_sleepAt!.difference(DateTime.now()).inMinutes} min',
          onTap: () => close(_sleepMenu),
        ),
        stepper(
          _volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          tr('Lautstärke'),
          '${(_volume * 100).round()} %',
          () => _setVolume(_volume - .1),
          () => _setVolume(_volume + .1),
        ),
        if (_e.canTune) ...[
          stepper(
            Icons.graphic_eq_rounded,
            tr('Ton-Versatz'),
            secs(_audioDelay),
            () {
              _audioDelay -= .1;
              _e.setAudioDelay(_audioDelay);
            },
            () {
              _audioDelay += .1;
              _e.setAudioDelay(_audioDelay);
            },
          ),
          stepper(
            Icons.closed_caption_rounded,
            tr('Untertitel-Versatz'),
            secs(_subDelay),
            () {
              _subDelay -= .1;
              _e.setSubDelay(_subDelay);
            },
            () {
              _subDelay += .1;
              _e.setSubDelay(_subDelay);
            },
          ),
        ],
        if (_phone)
          row(
            Icons.picture_in_picture_alt_rounded,
            tr('Bild-in-Bild'),
            onTap: () => close(() {
              _hide();
              _device.invokeMethod('pip').catchError((_) => false);
            }),
          ),
        row(Icons.insights_rounded, tr('Info & Statistik'), onTap: () => close(_info)),
        if (_desktop) row(Icons.keyboard_rounded, tr('Tastenkürzel'), onTap: () => close(_shortcuts)),
        if (Platform.isAndroid)
          row(
            Icons.swap_horiz_rounded,
            tr('Player'),
            value: _e is ExoEngine ? 'ExoPlayer' : 'mpv',
            onTap: () => close(_switchEngine),
          ),
        for (final x in _externals)
          row(Icons.open_in_new_rounded, tr('In {0} öffnen', [ExternalPlayer.names[x]]),
              onTap: () => close(() => _openExternal(x))),
      ],
    );
  }
}

/// Beschrifteter Knopf in der unteren Leiste.
class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool autofocus;
  const _Chip(this.icon, this.label, this.onTap, {this.autofocus = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Tap(
      onTap: onTap,
      autofocus: autofocus,
      radius: 100,
      scale: 1.06,
      fill: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: .12), borderRadius: BorderRadius.circular(100)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 19),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 7),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Schlichtes Symbol mit Tooltip (PC-Leiste).
class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  const _IconBtn(this.icon, this.tip, this.onTap);

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tip,
    child: Tap(
      onTap: onTap,
      radius: 100,
      scale: 1.15,
      fill: true,
      child: Padding(padding: const EdgeInsets.all(9), child: Icon(icon, size: 27)),
    ),
  );
}

/// Runder Knopf (Play/Pause, Spulen, Zurück).
class _Round extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final double size;
  final bool autofocus;
  final FocusNode? focusNode;
  const _Round(this.icon, this.tip, this.onTap, {this.size = 56, this.autofocus = false, this.focusNode});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tip,
    child: Tap(
      onTap: onTap,
      autofocus: autofocus,
      focusNode: focusNode,
      radius: 100,
      scale: 1.1,
      fill: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: size > 70 ? .45 : .3),
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(icon, size: size * .52),
      ),
    ),
  );
}

/// Halbtransparenter Knopf über dem Bild („Intro überspringen“, „Abspann“).
class _GhostButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final double? progress; // Countdown 0..1: Fläche füllt sich, danach verschwindet der Knopf
  const _GhostButton(this.label, this.icon, this.onTap, {this.progress});

  @override
  Widget build(BuildContext context) => Tap(
    onTap: onTap,
    radius: 8,
    scale: 1.05,
    child: Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .55),
        border: Border.all(color: Colors.white54),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          if (progress != null)
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress,
                child: const ColoredBox(color: Colors.white24),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 19),
                const SizedBox(width: 7),
                Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Knopf, dessen Fläche sich während des Countdowns mit der Akzentfarbe füllt.
class _CountdownButton extends StatelessWidget {
  final String label;
  final double progress;
  final bool autofocus;
  final VoidCallback onTap;
  const _CountdownButton({required this.label, required this.progress, required this.onTap, this.autofocus = false});

  @override
  Widget build(BuildContext context) => Tap(
    onTap: onTap,
    autofocus: autofocus,
    radius: 8,
    scale: 1.04,
    child: Container(
      height: 44,
      color: Colors.white,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: progress,
            child: ColoredBox(color: store.accent.withValues(alpha: .35)),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.play_arrow_rounded, color: Colors.black),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Badge extends StatelessWidget {
  final String text;
  final IconData? icon;
  final bool dot;
  const _Badge(this.text, {this.icon, this.dot = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: dot ? const Color(0xFFE5484D) : Colors.white.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot) ...[
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
        ],
        if (icon != null) Icon(icon, size: 15),
        if (icon != null && text.isNotEmpty) const SizedBox(width: 5),
        if (text.isNotEmpty)
          Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: .3)),
      ],
    ),
  );
}

/// Live: aktuelle Sendung mit Fortschritt und was danach kommt.
class _LiveBar extends StatelessWidget {
  final List<({String title, DateTime start, DateTime end})> now;
  const _LiveBar({required this.now});

  @override
  Widget build(BuildContext context) {
    if (now.isEmpty) return const SizedBox.shrink();
    final p = now.first;
    String t(DateTime d) =>
        MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: true);
    final total = p.end.difference(p.start).inSeconds;
    final done = total <= 0 ? 0.0 : (DateTime.now().difference(p.start).inSeconds / total).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                p.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${t(p.start)} – ${t(p.end)}',
              style: const TextStyle(color: Colors.white70, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: done,
            minHeight: 4,
            color: store.accent,
            backgroundColor: Colors.white24,
          ),
        ),
        if (now.length > 1) ...[
          const SizedBox(height: 6),
          Text(
            '${tr('Danach')} ${t(now[1].start)}  ${now[1].title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
        ],
      ],
    );
  }
}

String fmtDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${'$m'.padLeft(2, '0')}:${'$s'.padLeft(2, '0')}' : '$m:${'$s'.padLeft(2, '0')}';
}

/// Fortschrittsleiste: Touch/Maus ziehen, D-Pad links/rechts spulen, Zeit-Vorschau über dem Regler.
class _SeekBar extends StatefulWidget {
  final Engine engine;
  final int step;
  final VoidCallback onUse;
  const _SeekBar({required this.engine, required this.step, required this.onUse});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  bool _focus = false;
  double? _drag, _hover;
  int _repeat = 0; // gehaltene Taste: Schritt wächst

  void _seekRel(int sec) {
    final s = widget.engine.state.value;
    var p = s.position + Duration(seconds: sec);
    if (p < Duration.zero) p = Duration.zero;
    if (s.duration > Duration.zero && p > s.duration) p = s.duration;
    widget.engine.seek(p);
    widget.onUse();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.engine.state,
    builder: (context, st, _) {
      final dur = st.duration.inMilliseconds;
      final v = _drag ?? (dur == 0 ? 0.0 : (st.position.inMilliseconds / dur).clamp(0.0, 1.0));
      final buf = dur == 0 ? 0.0 : (st.buffered.inMilliseconds / dur).clamp(0.0, 1.0);
      final preview = _drag ?? _hover;
      final big = _focus || _hover != null || _drag != null;
      return Focus(
        onFocusChange: (f) => setState(() => _focus = f),
        onKeyEvent: (_, e) {
          if (e is KeyUpEvent) return KeyEventResult.ignored;
          _repeat = e is KeyRepeatEvent ? _repeat + 1 : 0;
          final step = widget.step * (1 + _repeat ~/ 4).clamp(1, 6);
          if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _seekRel(-step);
            return KeyEventResult.handled;
          }
          if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
            _seekRel(step);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Row(
          children: [
            SizedBox(
              width: 72,
              child: Text(
                fmtDuration(Duration(milliseconds: (v * dur).round())),
                style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (_, c) {
                  double at(double x) => (x / c.maxWidth).clamp(0.0, 1.0);
                  return MouseRegion(
                    onHover: (e) => setState(() => _hover = at(e.localPosition.dx)),
                    onExit: (_) => setState(() => _hover = null),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (d) => setState(() => _drag = at(d.localPosition.dx)),
                      onHorizontalDragUpdate: (d) => setState(() => _drag = at(d.localPosition.dx)),
                      onHorizontalDragEnd: (_) {
                        if (_drag != null) widget.engine.seek(Duration(milliseconds: (_drag! * dur).round()));
                        setState(() => _drag = null);
                        widget.onUse();
                      },
                      onHorizontalDragCancel: () => setState(() => _drag = null),
                      onTapUp: (d) {
                        widget.engine.seek(Duration(milliseconds: (at(d.localPosition.dx) * dur).round()));
                        widget.onUse();
                      },
                      child: SizedBox(
                        height: 28,
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          clipBehavior: Clip.none,
                          children: [
                            AnimatedContainer(
                              duration: store.anim,
                              height: big ? 8 : 4,
                              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
                            ),
                            FractionallySizedBox(
                              widthFactor: buf,
                              child: Container(
                                height: big ? 8 : 4,
                                decoration: BoxDecoration(
                                  color: Colors.white38,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: v,
                              child: Container(
                                height: big ? 8 : 4,
                                decoration: BoxDecoration(color: store.accent, borderRadius: BorderRadius.circular(4)),
                              ),
                            ),
                            Positioned(
                              left: (v * c.maxWidth - 8).clamp(0, math.max(0, c.maxWidth - 16)),
                              child: AnimatedContainer(
                                duration: store.anim,
                                width: 16,
                                height: 16,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: _focus ? Border.all(color: store.accent, width: 3) : null,
                                ),
                              ),
                            ),
                            // Zeit an der Maus-/Fingerposition
                            if (preview != null && dur > 0)
                              Positioned(
                                left: (preview * c.maxWidth - 34).clamp(0, math.max(0, c.maxWidth - 68)),
                                top: -30,
                                child: Container(
                                  width: 68,
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: .8),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    fmtDuration(Duration(milliseconds: (preview * dur).round())),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            SizedBox(
              width: 80,
              child: Text(
                store.get('remaining', false) && dur > 0
                    ? '−${fmtDuration(st.duration - st.position)}'
                    : fmtDuration(st.duration),
                textAlign: TextAlign.right,
                style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ],
        ),
      );
    },
  );
}
