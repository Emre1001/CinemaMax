import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:video_player/video_player.dart';

import 'i18n.dart';
import 'store.dart';

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

  /// Android: ExoPlayer, außer der Nutzer wählt mpv. PC: immer mpv.
  static Engine create([String url = '']) {
    // rtmp/udp/mms kann ExoPlayer nicht: dafür immer mpv
    final exotic = RegExp(r'^(rtmp|rtmps|udp|rtp|mms|mmsh|srt)://', caseSensitive: false).hasMatch(url);
    return Platform.isAndroid && store.get('engine', 'exo') == 'exo' && !exotic ? ExoEngine() : MpvEngine();
  }

  /// Kodi-Schreibweise "url|User-Agent=x&Referer=y": Header abtrennen.
  static (String, Map<String, String>) splitHeaders(String url, Map<String, String> base) {
    final i = url.indexOf('|');
    if (i < 0) return (url, base);
    final h = {...base};
    for (final part in url.substring(i + 1).split('&')) {
      final k = part.indexOf('=');
      if (k > 0) h[Uri.decodeComponent(part.substring(0, k))] = Uri.decodeComponent(part.substring(k + 1));
    }
    return (url.substring(0, i), h);
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
  Widget view(BoxFit fit);
  Future<void> dispose();

  /// Technische Werte für die Info-Anzeige (Decoder, Bildrate, verworfene Bilder …).
  Future<Map<String, String>> stats() async => {};

  /// Feineinstellungen (Versatz, Lautstärke über 100 %): nur mpv.
  bool get canTune => false;
  double get maxVolume => 1;
  Future<void> setAudioDelay(double seconds) async {}
  Future<void> setSubDelay(double seconds) async {}

  /// Bevorzugte Sprachen aus den Einstellungen, z. B. ['de', 'deu', 'ger'].
  static List<String> langs(String key) =>
      store.get(key, 'de,deu,ger').split(',').where((s) => s.isNotEmpty).toList();
}

// ---------------- ExoPlayer (Android) ----------------

class ExoEngine extends Engine {
  final _ctrl = ValueNotifier<VideoPlayerController?>(null);
  bool _completedSent = false;

  VideoPlayerController? get _c => _ctrl.value;
  int _gen = 0;

  /// Reihenfolge der Versuche: wie angegeben, ohne Endung zusätzlich als HLS,
  /// bei Xtream-Live das jeweils andere Format (.ts / .m3u8).
  static List<(String, VideoFormat?)> _candidates(String url) {
    if (url.startsWith('/')) return [(url, null)];
    final hint = _hint(url);
    final path = Uri.tryParse(url)?.path ?? url;
    return [
      (url, hint),
      if (hint == null) (url, VideoFormat.hls),
      if (path.contains('/live/') && path.endsWith('.ts')) (url.replaceFirst(RegExp(r'\.ts(?=$|\?)'), '.m3u8'), VideoFormat.hls),
      if (path.contains('/live/') && path.endsWith('.m3u8')) (url.replaceFirst(RegExp(r'\.m3u8(?=$|\?)'), '.ts'), null),
    ];
  }

  /// Kurze, lesbare Fehlermeldung aus ExoPlayer-Ausnahmen.
  static String _short(Object e) {
    final m = RegExp(r'Response code: (\d+)').firstMatch('$e');
    if (m != null) return tr('Server antwortet mit HTTP {0}', [m.group(1)]);
    final t = '$e'.replaceFirst(RegExp(r'^PlatformException\([^,]*, '), '');
    return t.length > 160 ? '${t.substring(0, 160)} …' : t;
  }

  void _sync() {
    final v = _c?.value;
    if (v == null) return;
    final err = v.hasError ? v.errorDescription : null;
    state.value = PlaybackState(
      position: v.position,
      duration: v.duration,
      buffered: v.buffered.isEmpty ? Duration.zero : v.buffered.last.end,
      playing: v.isPlaying,
      buffering: v.isBuffering || !v.isInitialized,
      ready: v.isInitialized,
      error: err,
      size: v.size,
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

    final gen = ++_gen;
    String? lastError;
    Future<VideoPlayerController?> tryOpen(String u, VideoFormat? hint) async {
      final view = store.get('surfaceView', false) ? VideoViewType.platformView : VideoViewType.textureView;
      // Heruntergeladene Datei oder Netzwerk-Stream
      final c = u.startsWith('/')
          ? VideoPlayerController.file(File(u), viewType: view)
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
      if (gen != _gen) {
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
      if (want.any((l) => t.label.toLowerCase().contains(l))) return selectAudio(t.id);
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
              return ColoredBox(
                color: Colors.black,
                child: SizedBox.expand(
                  child: FittedBox(
                    fit: fit,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(width: v.size.width, height: v.size.height, child: VideoPlayer(c)),
                  ),
                ),
              );
            },
          );
        },
      );

  @override
  Future<void> dispose() async {
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
        error: state.value.error,
        size: Size((s.width ?? 0).toDouble(), (s.height ?? 0).toDouble()),
      );
    }

    _subs.addAll([
      _p.stream.position.listen((_) => up()),
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
      _p.stream.error.listen((e) {
        state.value = PlaybackState(buffering: false, error: e);
      }),
    ]);
  }

  bool _configured = false;
  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    final np = _p.platform;
    if (np is! mk.NativePlayer) return;
    Future<void> set(String k, String v) => np.setProperty(k, v).catchError((_) {});
    await set('network-timeout', '20');
    await set('volume-max', '150');
    final a = Engine.langs('audioLang'), s = Engine.langs('subLang');
    if (a.isNotEmpty) await set('alang', a.join(','));
    if (s.isNotEmpty) await set('slang', s.join(','));
    if (!store.get('subsOn', false)) await set('sid', 'no');
    if (store.get('deinterlace', false)) await set('deinterlace', 'yes');
    if (store.get('normalize', false)) await set('af', 'lavfi=[dynaudnorm=f=150:g=15]');
  }

  @override
  Future<void> open(String url, Map<String, String> headers, {Duration? start}) async {
    await _configure();
    _ready = false;
    state.value = const PlaybackState();
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
