import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart' show defaultEnterNativeFullscreen, defaultExitNativeFullscreen;

import '../downloads.dart';
import '../epg.dart';
import '../i18n.dart';
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
  const PlayItem(this.url, this.title, this.item);
  bool get live => item.kind == Kind.live;
}

Map<String, (String, BoxFit)> get fits => {
  'contain': (tr('Einpassen'), BoxFit.contain),
  'cover': (tr('Zoomen'), BoxFit.cover),
  'fill': (tr('Strecken'), BoxFit.fill),
};

class PlayerScreen extends StatefulWidget {
  final Source source;
  final List<PlayItem> list;
  final int index;
  final bool fromStart;

  const PlayerScreen({
    super.key,
    required this.source,
    required this.list,
    required this.index,
    this.fromStart = false,
  });

  static Future<void> open(BuildContext c, Source s, List<PlayItem> list, int index, {bool fromStart = false}) =>
      Navigator.push(
        c,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(source: s, list: list, index: index, fromStart: fromStart),
        ),
      );

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Engine _e = Engine.create(widget.list[widget.index].url);
  final _root = FocusNode(debugLabel: 'player');
  final _playBtn = FocusNode(debugLabel: 'play');
  late int _i = widget.index;
  late BoxFit _fit = fits[store.get('fit', 'contain')]!.$2;
  bool _controls = true, _fullscreen = false, _first = true, _muted = false, _locked = false;
  double _volume = 1, _audioDelay = 0, _subDelay = 0;
  int? _lastIndex; // vorheriger Sender für „Letzter Sender“
  double? _dragSeek; // Wischen zum Spulen: Sekunden
  double? _dragZap; // Wischen zum Senderwechsel: Strecke, null = schon gewechselt
  Timer? _hideTimer, _saveTimer, _sleepTimer, _retryTimer, _digitTimer, _toastTimer;
  DateTime? _sleepAt;
  int _retries = 0, _openId = 0;
  String _digits = '';
  String? _toast;
  List<({String title, DateTime start, DateTime end})> _epg = [];

  static const _device = MethodChannel('cinemamax/device');
  bool get _phone => Platform.isAndroid && !isAndroidTv;

  PlayItem get _cur => widget.list[_i];

  /// Folge/Film fast zu Ende und es gibt eine nächste: "Nächste Folge" anbieten.
  bool _nearEnd(PlaybackState s) =>
      !_cur.live &&
      _i < widget.list.length - 1 &&
      s.duration > const Duration(minutes: 2) &&
      s.duration - s.position < const Duration(seconds: 40);
  bool get _tv => formFactor(context) == Ff.tv;
  bool get _desktop => Platform.isLinux || Platform.isWindows;
  int get _step => store.get('seekStep', 10);

  @override
  void initState() {
    super.initState();
    _e.onCompleted = _completed;
    _e.state.addListener(_onState);
    _saveTimer = Timer.periodic(const Duration(seconds: 15), (_) => _saveProgress());
    // Handy: beim Verlassen der App als Bild-in-Bild weiterlaufen
    if (_phone && store.get('autoPip', true)) _device.invokeMethod('autoPip', true).catchError((_) {});
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (!isAndroidTv && store.get('landscape', true)) {
        SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      }
    }
    if (_desktop && store.get('autoFullscreen', false)) _toggleFullscreen();
    _play(_i);
  }

  @override
  void dispose() {
    _saveProgress();
    for (final t in [_hideTimer, _saveTimer, _sleepTimer, _retryTimer, _digitTimer, _toastTimer]) {
      t?.cancel();
    }
    _e.state.removeListener(_onState);
    _e.dispose();
    _root.dispose();
    _playBtn.dispose();
    if (_phone) _device.invokeMethod('autoPip', false).catchError((_) {});
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([]);
    }
    if (_fullscreen) defaultExitNativeFullscreen();
    super.dispose();
  }

  void _onState() {
    final s = _e.state.value;
    if (s.playing) _retries = 0;
    // Live-Streams brechen oft kurz ab: automatisch neu verbinden
    if (s.error != null &&
        _cur.live &&
        store.get('autoReconnect', true) &&
        _retries < 5 &&
        _retryTimer?.isActive != true) {
      _retries++;
      _retryTimer = Timer(Duration(seconds: 1 + _retries), () => _play(_i, retry: true));
    }
  }

  void _completed() {
    if (_cur.live || !mounted) return;
    _saveProgress();
    if (store.get('autoNext', true) && _i < widget.list.length - 1) {
      _play(_i + 1);
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _play(int i, {bool retry = false}) async {
    if (!retry) _saveProgress();
    final n = widget.list.length;
    i = (i % n + n) % n;
    final id = ++_openId;
    if (!retry && i != _i) _lastIndex = _i;
    setState(() {
      _i = i;
      if (!retry) _epg = [];
    });
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
    final rate = store.get('defaultRate', 1.0);
    if (!item.live && rate != 1.0) _e.setRate(rate);
    if (item.live && widget.source.type == SourceType.xtream && !retry) {
      Repo.xtreamEpg(widget.source, item.item.id)
          .then((e) {
            if (mounted && id == _openId) setState(() => _epg = e);
          })
          .catchError((_) {});
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

  void _seek(int seconds) {
    if (_cur.live) return;
    final p = _e.state.value.position + Duration(seconds: seconds);
    _e.seek(p < Duration.zero ? Duration.zero : p);
    _show();
  }

  void _toggleMute() {
    _muted = !_muted;
    if (!_muted && _volume == 0) _volume = 1;
    _e.setVolume(_muted ? 0 : _volume);
    _flash(_muted ? tr('Ton aus') : tr('Ton an'));
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen ? await defaultExitNativeFullscreen() : await defaultEnterNativeFullscreen();
    if (mounted) setState(() => _fullscreen = !_fullscreen);
  }

  static final _digitKeys = {
    for (var d = 0; d <= 9; d++) ...{
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + d): d,
      LogicalKeyboardKey(LogicalKeyboardKey.numpad0.keyId + d): d,
    },
  };

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
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
        _seek(_step * 3);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaRewind:
        _seek(-_step * 3);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.channelUp || LogicalKeyboardKey.pageUp || LogicalKeyboardKey.mediaTrackNext:
        _cur.live ? _zap(1) : (_i < widget.list.length - 1 ? _play(_i + 1) : null);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.channelDown || LogicalKeyboardKey.pageDown || LogicalKeyboardKey.mediaTrackPrevious:
        _cur.live ? _zap(-1) : (_i > 0 ? _play(_i - 1) : null);
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
      case LogicalKeyboardKey.space when _desktop:
        _e.playOrPause();
        _show();
        return KeyEventResult.handled;
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
        _cur.live ? _channelList() : _seek(-_step);
      case LogicalKeyboardKey.arrowRight:
        _cur.live ? _show() : _seek(_step);
      case LogicalKeyboardKey.select || LogicalKeyboardKey.enter || LogicalKeyboardKey.gameButtonA:
        // Am Ende einer Folge: OK springt direkt zur nächsten
        _nearEnd(_e.state.value) ? _play(_i + 1) : _show();
      case LogicalKeyboardKey.contextMenu:
        _channelList();
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

  void _audio() => _menu(() async {
    final tracks = await _e.audioTracks();
    if (!mounted) return;
    if (tracks.isEmpty) return toast(context, tr('Keine weiteren Tonspuren'));
    final id = await pick(context, tr('Tonspur'), {for (final t in tracks) t.id: t.label}, current: _e.audioId);
    if (id != null) _e.selectAudio(id);
  });

  void _subtitles() => _menu(() async {
    final tracks = await _e.subtitleTracks();
    if (!mounted) return;
    if (tracks.isEmpty) {
      return toast(
        context,
        _e is ExoEngine ? tr('Untertitel: in den Einstellungen Player „mpv“ wählen') : tr('Keine Untertitel vorhanden'),
      );
    }
    final id = await pick(context, tr('Untertitel'), {for (final t in tracks) t.id: t.label}, current: _e.subtitleId);
    if (id != null) _e.selectSubtitle(id);
  });

  void _fitMenu() => _menu(() async {
    final f = await pick(context, tr('Bildformat'), {
      for (final e in fits.entries) e.value.$2: e.value.$1,
    }, current: _fit);
    if (f != null) setState(() => _fit = f);
  });

  void _rateMenu() => _menu(() async {
    final r = await pick(context, tr('Geschwindigkeit'), {
      for (final r in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]) r: '${r}x',
    }, current: _e.rate);
    if (r != null) _e.setRate(r);
  });

  void _sleepMenu() => _menu(() async {
    final m = await pick(context, tr('Sleep-Timer'), {
      0: tr('Aus'),
      15: tr('{0} Minuten', [15]),
      30: tr('{0} Minuten', [30]),
      60: tr('1 Stunde'),
      90: tr('{0} Minuten', [90]),
      120: tr('2 Stunden'),
    }, current: _sleepAt == null ? 0 : null);
    if (m == null) return;
    _sleepTimer?.cancel();
    setState(() => _sleepAt = m == 0 ? null : DateTime.now().add(Duration(minutes: m)));
    if (m > 0) {
      _sleepTimer = Timer(Duration(minutes: m), () {
        _e.pause();
        if (mounted) Navigator.maybePop(context);
      });
      if (mounted) toast(context, tr('Wiedergabe stoppt in {0} Minuten', [m]));
    }
  });

  void _channelList() => _menu(() async {
    final i = await showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: tr('Senderliste'),
      barrierColor: Colors.black38,
      transitionDuration: store.anim,
      transitionBuilder: (_, a, _, child) => SlideTransition(
        position: Tween(begin: const Offset(-1, 0), end: Offset.zero).animate(a),
        child: child,
      ),
      pageBuilder: (c, _, _) => Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: surface.withValues(alpha: .97),
          child: SizedBox(
            width: 380,
            height: double.infinity,
            child: ListView.builder(
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
            ),
          ),
        ),
      ),
    );
    if (i != null && i != _i) _play(i);
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
    final hm = MaterialLocalizations.of(context);
    String t(DateTime d) => hm.formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: true);
    final subtitle = cur.live
        ? (now.isEmpty
              ? cur.item.group
              : '${t(now.first.start)}–${t(now.first.end)}  ${now.first.title}'
                    '${now.length > 1 ? '\n${tr('Danach')} ${t(now[1].start)}  ${now[1].title}' : ''}')
        : (cur.title != cur.item.name ? cur.item.name : cur.item.group);

    return PopScope(
      canPop: !_controls || !_tv,
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
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _controls ? _hide() : _show(),
              // Handy: waagerecht wischen spult, rechts senkrecht wischen ändert die Lautstärke
              onHorizontalDragUpdate: _phone && !_locked && !_cur.live
                  ? (d) {
                      _dragSeek = (_dragSeek ?? 0) + d.delta.dx / MediaQuery.sizeOf(context).width * 180;
                      final target = _e.state.value.position + Duration(seconds: _dragSeek!.round());
                      _flash(
                        '${_dragSeek! >= 0 ? '+' : '−'}${fmtDuration(Duration(seconds: _dragSeek!.abs().round()))}  ·  ${fmtDuration(target)}',
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
              onDoubleTapDown: (d) {
                if (_desktop) {
                  _toggleFullscreen();
                } else {
                  _seek(d.localPosition.dx < MediaQuery.sizeOf(context).width / 2 ? -_step : _step);
                }
              },
              onDoubleTap: () {},
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _e.view(_fit),
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
                  // Nächste Folge anbieten
                  if (!_pip(context))
                    ValueListenableBuilder(
                      valueListenable: _e.state,
                      builder: (_, s, _) => _nearEnd(s) && !_controls
                          ? Positioned(
                              right: 40,
                              bottom: 40,
                              child: Pill(
                                tr('Nächste Folge (OK)'),
                                icon: Icons.skip_next_rounded,
                                primary: true,
                                onTap: () => _play(_i + 1),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ValueListenableBuilder(
                    valueListenable: _e.state,
                    builder: (_, s, _) => s.error != null && _retryTimer?.isActive != true
                        ? _errorView(s.error!)
                        : (s.buffering
                              ? const Center(
                                  child: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                                  ),
                                )
                              : const SizedBox.shrink()),
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
                  if (!_pip(context))
                    IgnorePointer(
                      ignoring: !_controls,
                      child: AnimatedOpacity(
                        opacity: _controls ? 1 : 0,
                        duration: store.anim * 1.5,
                        child: ExcludeFocus(excluding: !_controls, child: _overlay(cur, subtitle, now)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Bild-in-Bild-Fenster: winzig, keine Bedienelemente.
  bool _pip(BuildContext c) {
    final sz = MediaQuery.sizeOf(c);
    return Platform.isAndroid && sz.width < 420 && sz.height < 320;
  }

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
      toast(context, '$e'.replaceFirst('Bad state: ', ''));
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
      (tr('Server'), host),
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

  Widget _errorView(String error) => Center(
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
            error,
            textAlign: TextAlign.center,
            maxLines: 3,
            style: const TextStyle(color: textDim),
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          children: [
            Pill(
              tr('Erneut versuchen'),
              icon: Icons.refresh,
              primary: true,
              autofocus: true,
              onTap: () {
                _retries = 0;
                _play(_i, retry: true);
              },
            ),
            if (Platform.isAndroid)
              Pill(
                _e is ExoEngine ? tr('Mit mpv versuchen') : tr('Mit ExoPlayer versuchen'),
                onTap: () {
                  // Anderen Player wählen und neu öffnen
                  store.set('engine', _e is ExoEngine ? 'mpv' : 'exo');
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PlayerScreen(source: widget.source, list: widget.list, index: _i),
                    ),
                  );
                },
              ),
          ],
        ),
      ],
    ),
  );

  // ---------------- Bedienoberfläche ----------------

  /// "1080p", "4K" … aus der Videohöhe.
  static String? _quality(Size s) {
    if (s.isEmpty) return null;
    final h = s.height;
    if (h >= 2000) return '4K';
    if (h >= 1400) return '1440p';
    if (h >= 1000) return '1080p';
    if (h >= 700) return '720p';
    return '${h.round()}p';
  }

  Widget _overlay(PlayItem cur, String subtitle, List<({String title, DateTime start, DateTime end})> now) {
    final pad = EdgeInsets.symmetric(horizontal: _tv ? 48 : 22, vertical: _tv ? 30 : 14);
    final multi = widget.list.length > 1;
    final compact = MediaQuery.sizeOf(context).width < 640;
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
                          cur.live && multi ? '${_i + 1}  ${cur.title}' : cur.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: _tv ? 28 : 20, fontWeight: FontWeight.w800, letterSpacing: -.5),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          cur.live ? cur.item.group : subtitle,
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
                          return q == null ? const SizedBox.shrink() : _Badge(q);
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
        // ---- Mitte: große Knöpfe ----
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
                ValueListenableBuilder(
                  valueListenable: _e.state,
                  builder: (_, s, _) => _Round(
                    s.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    tr('Play/Pause'),
                    _e.playOrPause,
                    size: 82,
                    focusNode: _playBtn,
                    autofocus: true,
                  ),
                ),
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
                  const SizedBox(height: 14),
                  FocusTraversalGroup(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (multi)
                            _Chip(
                              cur.live ? Icons.format_list_bulleted_rounded : Icons.video_library_rounded,
                              cur.live ? tr('Senderliste') : tr('Folgen'),
                              _channelList,
                            ),
                          if (!cur.live && _i < widget.list.length - 1)
                            _Chip(Icons.skip_next_rounded, tr('Nächste Folge'), () => _play(_i + 1)),
                          _Chip(Icons.audiotrack_rounded, tr('Tonspur'), _audio),
                          _Chip(Icons.subtitles_rounded, tr('Untertitel'), _subtitles),
                          _Chip(Icons.aspect_ratio_rounded, fits.values.firstWhere((f) => f.$2 == _fit).$1, _fitMenu),
                          if (!cur.live) _Chip(Icons.speed_rounded, '${_e.rate}x', _rateMenu),
                          if (_phone)
                            _Chip(Icons.lock_outline_rounded, tr('Sperren'), () => setState(() => _locked = true)),
                          if (_desktop)
                            _Chip(
                              _fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                              tr('Vollbild'),
                              _toggleFullscreen,
                            ),
                          _Chip(Icons.more_horiz_rounded, tr('Mehr'), _morePanel),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------- „Mehr“-Panel ----------------

  void _morePanel() => _menu(() async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: tr('Mehr'),
      barrierColor: Colors.black38,
      transitionDuration: store.anim,
      transitionBuilder: (_, a, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
      pageBuilder: (c, _, _) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: surface.withValues(alpha: .97),
          child: SizedBox(
            width: math.min(400, MediaQuery.sizeOf(c).width * .9),
            height: double.infinity,
            child: StatefulBuilder(builder: (c, setPanel) => _moreContent(c, setPanel)),
          ),
        ),
      ),
    );
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
            if (value != null) Text(value, style: const TextStyle(color: textDim)),
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 28, 10, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: Text(tr('Mehr'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        ),
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
            onTap: () {
              Navigator.pop(c);
              _play(_lastIndex!);
            },
          ),
        if (cur.live)
          row(
            Icons.fiber_manual_record_rounded,
            tr('Aufnehmen'),
            onTap: () {
              Navigator.pop(c);
              _recordMenu();
            },
          ),
        row(
          Icons.bedtime_rounded,
          tr('Sleep-Timer'),
          value: _sleepAt == null ? tr('Aus') : '${_sleepAt!.difference(DateTime.now()).inMinutes} min',
          onTap: () {
            Navigator.pop(c);
            _sleepMenu();
          },
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
            onTap: () {
              Navigator.pop(c);
              _hide();
              _device.invokeMethod('pip').catchError((_) => false);
            },
          ),
        row(
          Icons.insights_rounded,
          tr('Info & Statistik'),
          onTap: () {
            Navigator.pop(c);
            _info();
          },
        ),
        if (Platform.isAndroid)
          row(
            Icons.swap_horiz_rounded,
            tr('Player'),
            value: _e is ExoEngine ? 'ExoPlayer' : 'mpv',
            onTap: () {
              Navigator.pop(c);
              store.set('engine', _e is ExoEngine ? 'mpv' : 'exo');
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => PlayerScreen(source: widget.source, list: widget.list, index: _i),
                ),
              );
            },
          ),
      ],
    );
  }

  void _setVolume(double v) {
    _volume = v.clamp(0, _e.maxVolume).toDouble();
    _muted = _volume == 0;
    _e.setVolume(_volume);
    _flash(tr('Lautstärke {0} %', [(_volume * 100).round()]));
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

/// Fortschrittsleiste: Touch/Maus ziehen, D-Pad links/rechts spulen.
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
  double? _drag;

  void _seekRel(int sec) {
    final p = widget.engine.state.value.position + Duration(seconds: sec);
    widget.engine.seek(p < Duration.zero ? Duration.zero : p);
    widget.onUse();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.engine.state,
    builder: (context, st, _) {
      final dur = st.duration.inMilliseconds;
      final v = _drag ?? (dur == 0 ? 0.0 : (st.position.inMilliseconds / dur).clamp(0.0, 1.0));
      final buf = dur == 0 ? 0.0 : (st.buffered.inMilliseconds / dur).clamp(0.0, 1.0);
      return Focus(
        onFocusChange: (f) => setState(() => _focus = f),
        onKeyEvent: (_, e) {
          if (e is KeyUpEvent) return KeyEventResult.ignored;
          if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _seekRel(-widget.step);
            return KeyEventResult.handled;
          }
          if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
            _seekRel(widget.step);
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
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) => setState(() => _drag = at(d.localPosition.dx)),
                    onHorizontalDragEnd: (_) {
                      widget.engine.seek(Duration(milliseconds: (_drag! * dur).round()));
                      setState(() => _drag = null);
                      widget.onUse();
                    },
                    onTapUp: (d) {
                      widget.engine.seek(Duration(milliseconds: (at(d.localPosition.dx) * dur).round()));
                      widget.onUse();
                    },
                    child: SizedBox(
                      height: 28,
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          AnimatedContainer(
                            duration: store.anim,
                            height: _focus ? 8 : 4,
                            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
                          ),
                          FractionallySizedBox(
                            widthFactor: buf,
                            child: Container(
                              height: _focus ? 8 : 4,
                              decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(4)),
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: v,
                            child: Container(
                              height: _focus ? 8 : 4,
                              decoration: BoxDecoration(color: store.accent, borderRadius: BorderRadius.circular(4)),
                            ),
                          ),
                          Positioned(
                            left: (v * c.maxWidth - 8).clamp(0, c.maxWidth - 16),
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
                        ],
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
