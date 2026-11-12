import 'dart:async';

import 'package:flutter/material.dart';

import '../epg.dart';
import '../i18n.dart';
import '../models.dart';
import '../perf.dart';
import '../playback.dart';
import '../repo.dart';
import '../store.dart';
import 'common.dart';

/// Fernseher: der Sender unter dem Fokus läuft oben rechts über der Senderliste, links daneben Name und
/// laufende Sendung. Mit OK übernimmt das Vollbild denselben Player ([take]): kein neuer Verbindungsaufbau,
/// das Bild wächst aus der Vorschau heraus.
class LivePreview extends StatefulWidget {
  final Source source;
  const LivePreview({super.key, required this.source});

  static _LivePreviewState? _active;

  /// Nur in der Fernseher-Oberfläche und wenn eingeschaltet (Einstellungen › Live-TV). Nicht auf sehr
  /// schwachen Geräten (Speed-Modus): ein zweites Video neben der Liste schaffen sie nicht.
  static bool enabled(BuildContext c) => formFactor(c) == Ff.tv && store.get('livePreview', true) && !Perf.speed;

  /// Sender hat den Fokus bekommen: nach kurzer Ruhe in der Vorschau zeigen.
  static void focus(MediaItem m) => _active?._focus(m);

  /// Das Vollbild öffnet [m]. Ergebnis null = keine Vorschau sichtbar. Sonst das Rechteck der Vorschau (für
  /// das Wachsen zum Vollbild) und, wenn [m] dort schon läuft, ihr Player zum Weiterverwenden. Läuft etwas
  /// anderes, ist die Vorschau danach beendet: viele Anbieter erlauben nur eine Verbindung.
  static Future<({Engine? engine, Rect from})?> take(MediaItem m) async => _active?._take(m);

  @override
  State<LivePreview> createState() => _LivePreviewState();
}

class _LivePreviewState extends State<LivePreview> with WidgetsBindingObserver {
  final _box = GlobalKey();
  MediaItem? _item; // Sender unter dem Fokus
  Engine? _e;
  String? _playing; // ID des Senders, den der Player geöffnet hat
  Timer? _wait;
  int _id = 0;
  bool _counted = false; // Perf.paused erhöht

  @override
  void initState() {
    super.initState();
    LivePreview._active = this;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    if (identical(LivePreview._active, this)) LivePreview._active = null;
    WidgetsBinding.instance.removeObserver(this);
    _wait?.cancel();
    _drop();
    super.dispose();
  }

  // Andere Seite liegt darüber (Einstellungen, Film, Vollbild): nicht unsichtbar weiterspielen
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!(ModalRoute.isCurrentOf(context) ?? true)) _stop();
  }

  // App im Hintergrund (Home-Taste): Verbindung freigeben
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _stop();
    if (mounted) setState(() {});
  }

  void _focus(MediaItem m) {
    if (m.id == _item?.id && (_wait?.isActive == true || _playing == m.id)) return;
    _wait?.cancel();
    _e?.pause(); // Ton des vorigen Senders nicht unter dem neuen Namen weiterlaufen lassen
    setState(() => _item = m);
    // Erst wenn der Fokus kurz ruht: beim Durchblättern nicht jeden Sender beim Anbieter anfragen
    _wait = Timer(const Duration(milliseconds: 700), () => _open(m));
  }

  Future<void> _open(MediaItem m) async {
    final raw = m.url;
    if (!mounted || raw == null || !(ModalRoute.isCurrentOf(context) ?? true)) return;
    final id = ++_id;
    var url = raw;
    if (url.startsWith('stalker:')) {
      try {
        url = await Repo.stalkerResolve(widget.source, url);
      } catch (_) {
        return; // das Vollbild zeigt den Fehler
      }
      if (!mounted || id != _id) return;
    }
    final (clean, headers) = Engine.splitHeaders(url, Repo.streamHeaders(widget.source));
    var e = _e;
    final exo = Engine.usesExo(raw);
    if (e == null || (e is ExoEngine) != exo) {
      _drop();
      // Texture statt SurfaceView: neben der Liste flüssiger, das kleine Bild braucht kein echtes 4K
      e = _e = exo ? ExoEngine(surface: false) : MpvEngine();
      _counted = true;
      Perf.paused++; // Videobilder nicht als langsame App-Bilder werten
    }
    setState(() => _playing = m.id);
    await e.open(clean, headers);
  }

  void _drop() {
    _e?.dispose();
    _e = null;
    _playing = null;
    _uncount();
  }

  void _uncount() {
    if (_counted) Perf.paused--;
    _counted = false;
  }

  void _stop() {
    _wait?.cancel();
    _id++;
    _drop();
  }

  Future<({Engine? engine, Rect from})?> _take(MediaItem m) async {
    final box = _box.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      _stop();
      return null;
    }
    final from = box.localToGlobal(Offset.zero) & box.size;
    final e = _e;
    _wait?.cancel();
    _id++;
    // Gleicher Sender, kein Fehler und das Vollbild nutzt dieselbe Videoausgabe: Player weitergeben.
    // Fernseher mit SurfaceView (echtes 4K/HDR) öffnen im Vollbild neu
    final keep = e != null &&
        _playing == m.id &&
        e.state.value.error == null &&
        !(e is ExoEngine && store.get('surfaceView', isAndroidTv));
    _e = null;
    _playing = null;
    _uncount(); // nach der Übergabe zählt der Player selbst
    setState(() {});
    if (keep) return (engine: e, from: from);
    // Erst die alte Verbindung schließen, dann öffnet das Vollbild die neue
    await e?.dispose().timeout(const Duration(seconds: 2), onTimeout: () {});
    return (engine: null, from: from);
  }

  @override
  Widget build(BuildContext context) {
    final m = _item;
    final e = _e;
    // Fernseher haben oft nur 540 logische Pixel Höhe: Vorschau höchstens ein gutes Viertel davon
    final h = (MediaQuery.sizeOf(context).height * .27).clamp(110.0, 190.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 24, 4),
      child: Row(children: [
        Expanded(child: m == null ? const SizedBox.shrink() : _Info(source: widget.source, item: m)),
        const SizedBox(width: 20),
        // Kein runder Zuschnitt: das Rechteck ist genau die Fläche, aus der das Vollbild wächst
        Container(
          key: _box,
          width: h * 16 / 9,
          height: h,
          decoration: BoxDecoration(color: Colors.black, border: Border.all(color: line)),
          child: m == null
              ? Icon(Icons.live_tv_rounded, color: Colors.white24, size: h * .3)
              : Stack(fit: StackFit.expand, children: [
                  if (e != null && _playing == m.id) e.view(BoxFit.contain),
                  // Bis das Bild da ist (und bei Radio oder Fehler): Senderlogo
                  if (e == null || _playing != m.id)
                    _logo(m, busy: _wait?.isActive == true)
                  else
                    ValueListenableBuilder(
                      valueListenable: e.state,
                      builder: (_, s, _) => s.ready && s.error == null && !s.size.isEmpty
                          ? const SizedBox.shrink()
                          : _logo(m, busy: s.error == null && !s.ready),
                    ),
                ]),
        ),
      ]),
    );
  }

  Widget _logo(MediaItem m, {required bool busy}) => ColoredBox(
        color: Colors.black,
        child: Stack(fit: StackFit.expand, children: [
          Padding(padding: const EdgeInsets.all(28), child: Artwork(m.logo, m.name, fit: BoxFit.contain, width: 200)),
          if (busy)
            const Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)),
              ),
            ),
        ]),
      );
}

/// Name des Senders, laufende und nächste Sendung.
class _Info extends StatelessWidget {
  final Source source;
  final MediaItem item;
  const _Info({required this.source, required this.item});

  String _time(BuildContext c, DateTime d) =>
      MaterialLocalizations.of(c).formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: true);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: epg,
        builder: (context, _) {
          final now = epg.now(source, item.epgId), next = epg.next(source, item.epgId);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.5)),
            const SizedBox(height: 4),
            Text(now == null ? item.group : '${_time(context, now.start)} – ${_time(context, now.stop)}   ${now.title}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: ink(.8), fontSize: 15)),
            if (now != null) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                      value: now.progress, minHeight: 3, color: store.accent, backgroundColor: ink(.12)),
                ),
              ),
              if (now.desc != null) ...[
                const SizedBox(height: 8),
                Text(now.desc!,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: textDim, fontSize: 13, height: 1.35)),
              ],
            ],
            if (next != null) ...[
              const SizedBox(height: 6),
              Text('${tr('Danach')} ${_time(context, next.start)}  ${next.title}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: textDim, fontSize: 13)),
            ],
          ]);
        },
      );
}
