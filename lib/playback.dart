import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:video_player/video_player.dart';

import 'i18n.dart';
import 'store.dart';
import 'ui/common.dart' show isAndroidTv;

class PlaybackState {
  final Duration position, duration, buffered;
  final bool playing, buffering, ready;
  final String? error;
  final Size size; // Videoauflösung, leer = nur Ton

  const PlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.playing = false,
    this.buffering = true,
    this.ready = false,
    this.error,
    this.size = Size.zero,
  });
}

typedef Track = ({String id, String label});

/// Gemeinsame Schnittstelle: Android nutzt ExoPlayer (Media3), PC libmpv.
abstract class Engine {
  final state = ValueNotifier(const PlaybackState());
  VoidCallback? onCompleted;
  String? audioId, subtitleId;

  /// Android: ExoPlayer, außer der Nutzer wählt mpv ([engine] überschreibt die Einstellung). PC: immer mpv.
  static Engine create([String url = '', String? engine]) {
    // FLV-Filme kann ExoPlayer nicht spulen: mpv
    final flv = RegExp(r'\.flv$', caseSensitive: false).hasMatch(Uri.tryParse(url)?.path ?? url);
    return Platform.isAndroid && (engine ?? store.get('engine', 'exo')) == 'exo' && !exotic(url) && !flv
        ? ExoEngine()
        : MpvEngine();
  }

  /// rtmp/udp/mms/srt kann ExoPlayer nicht: dafür immer mpv. RTSP auch: Media3 stürzt bei manchen
  /// Servern im RtspClient ab (NullPointerException im Wiedergabe-Thread beendet die ganze App).
  static bool exotic(String url) =>
      RegExp(r'^(rtmp[a-z]?|rtsps?|udp|rtp|mms[ht]?|srt)://', caseSensitive: false).hasMatch(url);

  /// Kodi-Schreibweise "url|User-Agent=x&Referer=y": Header abtrennen.
  static (String, Map<String, String>) splitHeaders(String url, Map<String, String> base) {
    final i = url.indexOf('|');
    if (i < 0) return (url, base);
    final h = {...base};
    for (final part in url.substring(i + 1).split('&')) {
      final k = part.indexOf('=');
      if (k > 0) setHeader(h, _decode(part.substring(0, k)), _decode(part.substring(k + 1)));
    }
    return (url.substring(0, i), h);
  }

  /// Kodi-Werte sind meist kodiert, manchmal nicht („100%“): dann so lassen.
  static String _decode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  /// Header ohne Doppel in anderer Schreibweise setzen („user-agent“ ersetzt „User-Agent“).
  /// Schreibweise vereinheitlicht: ExoPlayer erkennt den User-Agent nur als „User-Agent“.
  static void setHeader(Map<String, String> h, String name, String value) {
    var key = name.trim().split('-').map((p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1).toLowerCase()).join('-');
    if (key == 'Referrer') key = 'Referer';
    h.removeWhere((k, _) => k.toLowerCase() == key.toLowerCase());
    h[key] = value.trim();
  }

  Future<void> open(String url, Map<String, String> headers, {Duration? start});
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause() => state.value.playing ? pause() : play();
  Future<void> seek(Duration d);
  Future<void> setRate(double r);
  double get rate;
  Future<void> setVolume(double v); // 0..1
  Future<List<Track>> audioTracks();
  Future<void> selectAudio(String id);
  Future<List<Track>> subtitleTracks();
  Future<void> selectSubtitle(String id);

  /// Auflösungen (HLS/DASH-Varianten). Leer = nur eine Qualität. [qualityId] null = automatisch.
  Future<List<Track>> qualities() async => [];
  Future<void> selectQuality(String? id) async => qualityId = id;
  String? qualityId;

  /// Bildhöhe je Qualität (von [qualities] gefüllt), für die Datenspar-Grenze.
  final qualityHeight = <String, int>{};

  /// Beste Qualität bis [maxHeight] wählen (Daten sparen). null = Stream hat (noch) keine Stufen,
  /// '' = die beste Stufe passt schon, Automatik bleibt.
  Future<String?> capQuality(int maxHeight) async {
    final list = await qualities();
    if (list.isEmpty) return null;
    if (fits(qualityHeight[list.first.id] ?? 0, maxHeight)) return '';
    // Alles höher als erlaubt: kleinste Stufe
    final q = list.firstWhere((q) => fits(qualityHeight[q.id] ?? 0, maxHeight), orElse: () => list.last);
    if (!nativeCap) await selectQuality(q.id);
    return q.label;
  }

  /// Der Player begrenzt die Auflösung schon selbst (ExoPlayer: IptvTuning), keine feste Spur nötig.
  bool get nativeCap => false;

  /// Bildhöhe wie bei 16:9: Kinoformat (1920×800) zählt wie 1080p, 3440×1440 wie 1935p.
  static int height16x9(int width, int height) => max(height, width * 9 ~/ 16);

  /// Etwas Spielraum, damit 1920×1088 noch als 1080p gilt.
  static bool fits(int height, int maxHeight) => height <= maxHeight * 17 ~/ 16;

  static int _androidScreen = 0;

  /// Android: Bildschirm nativ abfragen. Fernseher melden Flutter oft nur die 1080p-Oberfläche statt 4K.
  static Future<void> detectScreen() async {
    if (!Platform.isAndroid) return;
    try {
      final s = await const MethodChannel('cinemamax/device').invokeListMethod<int>('displaySize');
      if (s != null && s.length == 2) _androidScreen = height16x9(max(s[0], s[1]), min(s[0], s[1]));
    } catch (_) {}
  }

  /// Bildschirmhöhe wie bei 16:9 (Handy 2400×1080 = 1350), 0 = unbekannt. PC: Bildschirm des Fensters.
  static int get screenHeight {
    if (Platform.isAndroid) return _androidScreen;
    final d = WidgetsBinding.instance.platformDispatcher;
    Size? s;
    try {
      s = d.implicitView?.display.size;
    } catch (_) {/* Bildschirm nicht gemeldet */}
    if (s == null || s.isEmpty) {
      for (final x in d.displays) {
        if (s == null || x.size.height > s.height) s = x.size;
      }
    }
    if (s == null || s.isEmpty) return 0;
    return height16x9(max(s.width, s.height).round(), min(s.width, s.height).round());
  }

  /// Höchste Bildhöhe für Streams aus „Bildschirmauflösung“: automatisch die des Bildschirms. 0 = keine Grenze.
  static int get maxHeight {
    final v = store.get('maxRes', -1);
    return v < 0 ? screenHeight : v;
  }

  /// "4K", "1080p" aus der Bildgröße. Kinofilme in 4K sind oft 3840×1600: daher auch die Breite prüfen.
  static String? resolution(int? width, int? height) {
    final w = width ?? 0, h = height ?? 0;
    if (w <= 0 && h <= 0) return null;
    if (w >= 3200 || h >= 2000) return '4K';
    if (w >= 2400 || h >= 1400) return '1440p';
    if (w >= 1800 || h >= 1000) return '1080p';
    if (w >= 1200 || h >= 700) return '720p';
    return '${h}p';
  }

  /// "1080p · 5.2 Mbit/s" aus Bildgröße und Bitrate.
  static String qualityLabel(int? width, int? height, int? bitrate) => [
        ?resolution(width, height),
        if (bitrate != null && bitrate > 0) '${(bitrate / 1e6).toStringAsFixed(1)} Mbit/s',
      ].join(' · ');

  Widget view(BoxFit fit);
  Future<void> dispose();

  /// Technische Werte für die Info-Anzeige (Decoder, Bildrate, verworfene Bilder …).
  Future<Map<String, String>> stats() async => {};

  /// Feineinstellungen (Versatz, Lautstärke über 100 %): nur mpv.
  bool get canTune => false;
  double get maxVolume => 1;
  Future<void> setAudioDelay(double seconds) async {}
  Future<void> setSubDelay(double seconds) async {}

  /// Spur passt zu einer Sprache: ganzes Wort („de“, „deu“) oder Wortanfang ab 3 Zeichen („ger“ → „German“),
  /// nicht „de“ in „Description“.
  static bool langMatch(String label, List<String> want) {
    final words = RegExp(r'\p{L}+', unicode: true).allMatches(label.toLowerCase()).map((m) => m[0]!).toList();
    return want.any((l) => words.any((w) => w == l || (l.length >= 3 && w.startsWith(l))));
  }

  /// Bevorzugte Sprachen aus den Einstellungen, z. B. ['de', 'deu', 'ger'].
  static List<String> langs(String key) =>
      store.get(key, 'de,deu,ger').split(',').where((s) => s.isNotEmpty).toList();
}

// ---------------- ExoPlayer (Android) ----------------

class ExoEngine extends Engine {
  final _ctrl = ValueNotifier<VideoPlayerController?>(null);
  bool _completedSent = false;

  VideoPlayerController? get _c => _ctrl.value;
  static const _unknownDurationMs = 9223372036854775; // Long.MAX_VALUE / 1000, wie im Plugin
  int _gen = 0;
  bool _disposed = false;

  /// Reihenfolge der Versuche: wie angegeben, ohne Endung zusätzlich als HLS,
  /// bei Xtream-Live das jeweils andere Format (.ts / .m3u8).
  static List<(String, VideoFormat?)> _candidates(String url) {
    if (url.startsWith('/') || url.startsWith('content://')) return [(url, null)];
    final hint = _hint(url);
    final path = Uri.tryParse(url)?.path ?? url;
    return [
      (url, hint),
      if (hint == null) (url, VideoFormat.hls),
      if (path.contains('/live/') && path.endsWith('.ts')) (url.replaceFirst(RegExp(r'\.ts(?=$|\?)'), '.m3u8'), VideoFormat.hls),
      if (path.contains('/live/') && path.endsWith('.m3u8')) (url.replaceFirst(RegExp(r'\.m3u8(?=$|\?)'), '.ts'), null),
      // https-Link auf einen Server, der nur http spricht
      if (url.toLowerCase().startsWith('https://')) ('http://${url.substring(8)}', hint),
    ];
  }

  /// Kurze, lesbare Fehlermeldung aus ExoPlayer-Ausnahmen.
  static String _short(Object e) {
    final m = RegExp(r'Response code: (\d+)').firstMatch('$e');
    if (m != null) return tr('Server antwortet mit HTTP {0}', [m.group(1)]);
    final t = '$e'.replaceFirst(RegExp(r'^PlatformException\([^,]*, '), '');
    return t.length > 160 ? '${t.substring(0, 160)} …' : t;
  }

  // Adaptive Streams wechseln die Auflösung, video_player meldet nur die erste: laufende Spur nachfragen
  Size? _playingSize;
  DateTime _sizeCheck = DateTime(0);

  Future<void> _checkSize(VideoPlayerController c) async {
    try {
      if (!c.isVideoTrackSupportAvailable()) return;
      final t = (await c.getVideoTracks()).where((t) => t.isSelected && (t.width ?? 0) > 0).toList();
      if (t.length != 1 || c != _c) return;
      final size = Size(t.single.width!.toDouble(), t.single.height!.toDouble());
      if (size == _playingSize) return;
      _playingSize = size;
      _sync();
    } catch (_) {/* Spuren gerade nicht abrufbar */}
  }

  void _sync() {
    final c = _c;
    final v = c?.value;
    if (c == null || v == null) return;
    if (v.isPlaying && DateTime.now().difference(_sizeCheck) > const Duration(seconds: 3)) {
      _sizeCheck = DateTime.now();
      _checkSize(c);
    }
    final err = v.hasError ? v.errorDescription : null;
    // Live-MPEG-TS ohne Länge: das Plugin meldet eine riesige Dauer (siehe UNKNOWN_DURATION_MS), hier 0 = unbekannt
    final unknown = v.duration.inMilliseconds >= _unknownDurationMs;
    state.value = PlaybackState(
      position: v.position,
      duration: unknown ? Duration.zero : v.duration,
      buffered: v.buffered.isEmpty ? Duration.zero : v.buffered.last.end,
      playing: v.isPlaying,
      buffering: v.isBuffering || !v.isInitialized,
      ready: v.isInitialized,
      error: err,
      size: _playingSize ?? v.size,
    );
    if (v.isCompleted && !_completedSent) {
      _completedSent = true;
      onCompleted?.call();
    }
  }

  // ExoPlayer erkennt HLS nur an ".m3u8"; viele IPTV-Links haben keine Endung
  static VideoFormat? _hint(String url) {
    final u = url.toLowerCase();
    if (u.contains('m3u8') || u.contains('/hls')) return VideoFormat.hls;
    if (u.contains('.mpd')) return VideoFormat.dash;
    return null;
  }

  @override
  Future<void> open(String url, Map<String, String> headers, {Duration? start}) async {
    // Alten Player zuerst freigeben: TV-Boxen haben oft nur einen Hardware-Decoder
    final old = _c;
    _ctrl.value = null;
    old?.removeListener(_sync);
    await old?.dispose();
    state.value = const PlaybackState();
    _completedSent = false;
    _playingSize = null;
    qualityId = null;

    final gen = ++_gen;
    String? lastError;
    Future<VideoPlayerController?> tryOpen(String u, VideoFormat? hint) async {
      // Fernseher: SurfaceView zeigt 4K in voller Auflösung und HDR mit richtigen Farben
      final view = store.get('surfaceView', isAndroidTv) ? VideoViewType.platformView : VideoViewType.textureView;
      // Heruntergeladene Datei oder Netzwerk-Stream
      final c = u.startsWith('/')
          ? VideoPlayerController.file(File(u), viewType: view)
          : u.startsWith('content://')
          ? VideoPlayerController.contentUri(Uri.parse(u), viewType: view)
          : VideoPlayerController.networkUrl(Uri.parse(u.contains(' ') ? Uri.encodeFull(u) : u),
              httpHeaders: headers, formatHint: hint, viewType: view);
      try {
        // Manche Server antworten nie: nicht ewig warten
        await c.initialize().timeout(const Duration(seconds: 25));
        return c;
      } catch (e) {
        lastError = e is TimeoutException ? tr('Zeitüberschreitung: Server antwortet nicht') : _short(e);
        await c.dispose();
        return null;
      }
    }

    VideoPlayerController? c;
    for (final (u, hint) in _candidates(url)) {
      c = await tryOpen(u, hint);
      // Inzwischen weitergezappt: Ergebnis verwerfen
      if (gen != _gen || _disposed) {
        await c?.dispose();
        return;
      }
      if (c != null) break;
    }
    if (c == null) {
      state.value = PlaybackState(buffering: false, error: lastError ?? tr('Stream konnte nicht geöffnet werden'));
      return;
    }
    _ctrl.value = c;
    c.addListener(_sync);
    if (start != null) await c.seekTo(start);
    await c.play();
    _pickAudio();
  }

  Future<void> _pickAudio() async {
    final want = Engine.langs('audioLang');
    if (want.isEmpty) return;
    for (final t in await audioTracks()) {
      if (Engine.langMatch(t.label, want)) return selectAudio(t.id);
    }
  }

  @override
  Future<void> play() async => _c?.play();
  @override
  Future<void> pause() async => _c?.pause();
  @override
  Future<void> seek(Duration d) async => _c?.seekTo(d);
  @override
  Future<void> setRate(double r) async => _c?.setPlaybackSpeed(r);
  @override
  double get rate => _c?.value.playbackSpeed ?? 1;
  @override
  Future<void> setVolume(double v) async => _c?.setVolume(v.clamp(0, 1).toDouble());

  @override
  Future<List<Track>> audioTracks() async {
    final c = _c;
    if (c == null) return [];
    return [
      for (final t in await c.getAudioTracks())
        (id: t.id, label: [t.label, t.language].whereType<String>().where((s) => s.isNotEmpty).join(' · ')),
    ];
  }

  @override
  Future<void> selectAudio(String id) async {
    audioId = id;
    await _c?.selectAudioTrack(id);
  }

  final _videoTracks = <String, VideoTrack>{};

  @override
  Future<List<Track>> qualities() async {
    final c = _c;
    if (c == null || !c.isVideoTrackSupportAvailable()) return [];
    _videoTracks.clear();
    final out = <Track>[];
    for (final t in (await c.getVideoTracks())
      ..sort((a, b) => (b.width ?? 0) * (b.height ?? 0) - (a.width ?? 0) * (a.height ?? 0))) {
      final label = Engine.qualityLabel(t.width, t.height, t.bitrate);
      if (label.isEmpty || out.any((o) => o.label == label)) continue;
      _videoTracks[t.id] = t;
      // Kinoformat (1920×800) zählt wie 1080p: Höhe aus der Breite ableiten
      qualityHeight[t.id] = Engine.height16x9(t.width ?? 0, t.height ?? 0);
      out.add((id: t.id, label: label));
    }
    return out.length > 1 ? out : [];
  }

  @override
  Future<void> selectQuality(String? id) async {
    qualityId = id;
    await _c?.selectVideoTrack(id == null ? null : _videoTracks[id]);
  }

  // IptvTuning begrenzt beim Erstellen des Players: HLS schaltet bei langsamem Netz weiter herunter
  @override
  bool get nativeCap => true;

  // shortcut: ExoPlayer über video_player zeigt keine eingebetteten Untertitel; dafür Engine "mpv" wählen
  @override
  Future<List<Track>> subtitleTracks() async => [];
  @override
  Future<void> selectSubtitle(String id) async {}

  @override
  Widget view(BoxFit fit) => ValueListenableBuilder(
        valueListenable: _ctrl,
        builder: (_, c, _) {
          if (c == null) return const ColoredBox(color: Colors.black);
          return ValueListenableBuilder(
            valueListenable: c,
            builder: (_, v, _) {
              if (!v.isInitialized || v.size.isEmpty) return const ColoredBox(color: Colors.black);
              // Größe per Layout statt Skalierung: eine SurfaceView (Fernseher) kennt keine Transformationen
              return ColoredBox(
                color: Colors.black,
                child: LayoutBuilder(builder: (_, box) {
                  final dest = applyBoxFit(fit, v.size, box.biggest).destination;
                  // Mindestmaße setzen: sonst erbt die Box die Bildschirmbreite als Minimum und ein schmaleres
                  // Bild (16:9 auf einem 20:9-Handy) ergibt ungültige Maße, das Video bleibt schwarz
                  return ClipRect(
                    child: OverflowBox(
                      minWidth: dest.width,
                      minHeight: dest.height,
                      maxWidth: dest.width,
                      maxHeight: dest.height,
                      child: SizedBox(width: dest.width, height: dest.height, child: VideoPlayer(c)),
                    ),
                  );
                }),
              );
            },
          );
        },
      );

  @override
  Future<void> dispose() async {
    // Noch ladende Streams verwerfen: sonst läuft der Ton nach dem Verlassen weiter
    _disposed = true;
    _gen++;
    final c = _c;
    _ctrl.value = null;
    c?.removeListener(_sync);
    await c?.dispose();
  }
}

// ---------------- libmpv (Windows, Linux, optional Android) ----------------

class MpvEngine extends Engine {
  late final mk.Player _p = mk.Player(
    configuration: mk.PlayerConfiguration(title: 'CinemaMax', bufferSize: store.get('bufferMb', 64) * 1024 * 1024),
  );
  late final mkv.VideoController _video = mkv.VideoController(
    _p,
    configuration: mkv.VideoControllerConfiguration(enableHardwareAcceleration: store.get('hwdec', true)),
  );
  final _subs = <StreamSubscription>[];
  bool _ready = false;

  MpvEngine() {
    _video; // Video-Ausgabe vor dem ersten open() anlegen
    void up() {
      final s = _p.state;
      state.value = PlaybackState(
        position: s.position,
        duration: s.duration,
        buffered: s.buffer,
        playing: s.playing,
        buffering: s.buffering,
        ready: _ready,
        // mpv meldet auch Fehler, von denen es sich selbst erholt: läuft es weiter, ist der Fehler weg
        error: _ready ? null : state.value.error,
        size: Size((s.width ?? 0).toDouble(), (s.height ?? 0).toDouble()),
      );
    }

    _subs.addAll([
      // mpv meldet „playing“ schon vor dem Laden: erst laufende Zeit oder Bild heißt bereit (auch Radio)
      _p.stream.position.listen((p) {
        if (p > Duration.zero) _ready = true;
        up();
      }),
      _p.stream.playing.listen((_) => up()),
      _p.stream.buffering.listen((_) => up()),
      _p.stream.duration.listen((_) => up()),
      _p.stream.width.listen((w) {
        if (w != null && w > 0) _ready = true;
        up();
      }),
      _p.stream.completed.listen((c) {
        if (c) onCompleted?.call();
      }),
      // 4K auf kleinerem Bildschirm: nur in Bildschirmgröße rendern, spart GPU/CPU (Android: Größe fest im Plugin)
      if (!Platform.isAndroid)
        _p.stream.videoParams.listen((p) {
          final (w, h) = (p.rotate ?? 0) % 180 == 0 ? (p.dw ?? 0, p.dh ?? 0) : (p.dh ?? 0, p.dw ?? 0);
          final screen = Engine.screenHeight, video = Engine.height16x9(w, h);
          if (w <= 0 || h <= 0) return;
          if (screen <= 0 || Engine.fits(video, screen)) {
            _video.setSize().catchError((_) {});
          } else {
            _video.setSize(width: w * screen ~/ video, height: h * screen ~/ video).catchError((_) {});
          }
        }),
      _p.stream.error.listen((e) {
        // https-Link auf einen Server, der nur http spricht: einmal mit http versuchen (wie bei ExoPlayer)
        final u = _opened;
        // Nur bei Verbindungsfehlern, nicht bei Decoder-Meldungen
        if (!_ready && u != null && u.$1.toLowerCase().startsWith('https://') &&
            RegExp(r'failed to open|tls|ssl|handshake', caseSensitive: false).hasMatch(e)) {
          _opened = null;
          _p.open(mk.Media('http://${u.$1.substring(8)}', httpHeaders: u.$2, start: u.$3));
          return;
        }
        _ready = false;
        state.value = PlaybackState(buffering: false, error: e);
      }),
    ]);
  }

  (String, Map<String, String>, Duration?)? _opened; // für den http-Rückfall, null = schon versucht

  bool _configured = false;
  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    final np = _p.platform;
    if (np is! mk.NativePlayer) return;
    Future<void> set(String k, String v) => np.setProperty(k, v).catchError((_) {});
    await set('network-timeout', '20');
    await set('volume-max', '150');
    // media_kit übergibt jeden Link als Playlist: ohne das verweigert mpv udp://, rtp:// …
    await set('load-unsafe-playlists', 'yes');
    // RTSP: erst UDP, dann TCP (ffmpeg-Standard); mpv nimmt sonst nur TCP, das viele Server ablehnen (461)
    await set('rtsp-transport', 'lavf');
    // Stream-Analyse begrenzen: HLS mit Untertitel-Spur (z. B. ARD/ZDF) wartet sonst endlos auf Untertitel-Pakete.
    // Anhängen statt ersetzen: media_kits seg_max_retry=5 (HLS-Segmente erneut laden statt Ruckler) bleibt erhalten
    await np.command(['change-list', 'demuxer-lavf-o', 'append', 'analyzeduration=3000000']).catchError((_) {});
    // Live-Streams kommen nur in Echtzeit: erst 2 s puffern, sonst läuft der Puffer bei jeder Schwankung leer (Ruckeln)
    await set('cache-pause-initial', 'yes');
    await set('cache-pause-wait', '2');
    final a = Engine.langs('audioLang'), s = Engine.langs('subLang');
    if (a.isNotEmpty) await set('alang', a.join(','));
    if (s.isNotEmpty) await set('slang', s.join(','));
    if (!store.get('subsOn', false)) await set('sid', 'no');
    if (store.get('deinterlace', false)) await set('deinterlace', 'yes');
    if (store.get('normalize', false)) await set('af', 'lavfi=[dynaudnorm=f=150:g=15]');
  }

  // Linux: die GPU-Ausgabe entsteht erst beim ersten Zeichnen der Textur. Vorher geöffnete Streams finden
  // keine Videoausgabe und hängen bei 0:00 (schnelle Server, Downloads): erst ein paar Bilder zeichnen lassen.
  late final Future<void> _outputReady = () async {
    if (!Platform.isLinux) return;
    await _video.platform.future;
    for (var i = 0; i < 3; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    await Future.delayed(const Duration(milliseconds: 150));
  }();

  @override
  Future<void> open(String url, Map<String, String> headers, {Duration? start}) async {
    await _configure();
    await _outputReady;
    _ready = false;
    qualityId = null;
    state.value = const PlaybackState();
    // Leerzeichen/Umlaute im Pfad schickt ffmpeg roh: Server antworten dann mit 400
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(url) && RegExp(r'[^\x21-\x7E]|["<>\\^`{}]').hasMatch(url)) {
      url = Uri.parse(url).toString();
    }
    _opened = (url, headers, start);
    await _p.open(mk.Media(url, httpHeaders: headers, start: start));
  }

  Future<String?> property(String k) async {
    final np = _p.platform;
    if (np is! mk.NativePlayer) return null;
    try {
      return await np.getProperty(k);
    } catch (_) {
      return null;
    }
  }

  @override
  bool get canTune => true;
  @override
  double get maxVolume => 1.5;

  Future<void> _setProp(String k, String v) async {
    final np = _p.platform;
    if (np is mk.NativePlayer) await np.setProperty(k, v).catchError((_) {});
  }

  @override
  Future<void> setAudioDelay(double seconds) => _setProp('audio-delay', seconds.toStringAsFixed(2));
  @override
  Future<void> setSubDelay(double seconds) => _setProp('sub-delay', seconds.toStringAsFixed(2));

  @override
  Future<Map<String, String>> stats() async {
    final out = <String, String>{};
    for (final (label, key) in [
      ('Decoder', 'hwdec-current'),
      ('Video-Codec', 'video-codec'),
      ('Bildrate Quelle', 'container-fps'),
      ('Bildrate angezeigt', 'estimated-display-fps'),
      ('Verworfene Bilder', 'frame-drop-count'),
      ('Verspätete Bilder', 'vo-delayed-frame-count'),
      ('Puffer (s)', 'demuxer-cache-duration'),
    ]) {
      final v = await property(key);
      if (v != null && v.isNotEmpty) out[label] = double.tryParse(v)?.toStringAsFixed(1) ?? v;
    }
    return out;
  }

  @override
  Future<void> play() => _p.play();
  @override
  Future<void> pause() => _p.pause();
  @override
  Future<void> seek(Duration d) => _p.seek(d);
  @override
  Future<void> setRate(double r) => _p.setRate(r);
  @override
  double get rate => _p.state.rate;
  @override
  Future<void> setVolume(double v) => _p.setVolume(v * 100);

  static String _label(String id, String? title, String? lang) {
    if (id == 'auto') return tr('Automatisch');
    if (id == 'no') return tr('Aus');
    final parts = [title, lang?.toUpperCase()].whereType<String>().where((s) => s.isNotEmpty);
    return parts.isEmpty ? tr('Spur {0}', [id]) : parts.join(' · ');
  }

  @override
  Future<List<Track>> audioTracks() async =>
      [for (final t in _p.state.tracks.audio) (id: t.id, label: _label(t.id, t.title, t.language))];

  @override
  Future<void> selectAudio(String id) async {
    audioId = id;
    await _p.setAudioTrack(_p.state.tracks.audio.firstWhere((t) => t.id == id));
  }

  @override
  Future<List<Track>> subtitleTracks() async =>
      [for (final t in _p.state.tracks.subtitle) (id: t.id, label: _label(t.id, t.title, t.language))];

  @override
  Future<void> selectSubtitle(String id) async {
    subtitleId = id;
    await _p.setSubtitleTrack(_p.state.tracks.subtitle.firstWhere((t) => t.id == id));
  }

  @override
  Future<List<Track>> qualities() async {
    final out = <Track>[];
    final tracks = [..._p.state.tracks.video.where((t) => t.id != 'auto' && t.id != 'no')]
      ..sort((a, b) => (b.w ?? 0) * (b.h ?? 0) - (a.w ?? 0) * (a.h ?? 0));
    for (final t in tracks) {
      final label = Engine.qualityLabel(t.w, t.h, t.bitrate);
      if (label.isEmpty || out.any((o) => o.label == label)) continue;
      qualityHeight[t.id] = Engine.height16x9(t.w ?? 0, t.h ?? 0);
      out.add((id: t.id, label: label));
    }
    return out.length > 1 ? out : [];
  }

  @override
  Future<void> selectQuality(String? id) async {
    qualityId = id;
    await _p.setVideoTrack(id == null
        ? mk.VideoTrack.auto()
        : _p.state.tracks.video.firstWhere((t) => t.id == id, orElse: mk.VideoTrack.auto));
  }

  @override
  Widget view(BoxFit fit) => mkv.Video(
        controller: _video,
        controls: mkv.NoVideoControls,
        fit: fit,
        subtitleViewConfiguration: mkv.SubtitleViewConfiguration(
          style: TextStyle(
            fontSize: store.get('subSize', 44).toDouble(),
            color: Colors.white,
            fontWeight: FontWeight.w600,
            shadows: const [Shadow(blurRadius: 6), Shadow(blurRadius: 2)],
            backgroundColor: store.get('subBg', false) ? Colors.black54 : Colors.transparent,
          ),
        ),
      );

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _p.dispose();
  }
}
