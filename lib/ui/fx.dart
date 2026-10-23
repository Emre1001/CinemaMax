import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../perf.dart';
import '../store.dart';
import 'common.dart';

/// Gemeinsame Effekte der Oberfläche (Einrichtung und App). Alle achten auf „Animationen reduzieren“
/// und den Leistungsmodus „Flüssig“ ([Perf.lite]).

/// Animationsdauer: bei „Animationen reduzieren“ sofort, im Modus „Flüssig“ kürzer.
Duration fxMs(int ms) =>
    store.reduceMotion ? Duration.zero : Duration(milliseconds: Perf.lite ? (ms * .6).round() : ms);

/// Dauer-Animationen (Glanz, Pulsieren, ziehender Hintergrund) nur bei voller Leistung.
bool get fxRich => !store.reduceMotion && !Perf.lite;

// ---------------- Hintergrund ----------------

/// Farbwolken in der Akzentfarbe. Einmal klein vorgerendert und nur verschoben: kostet pro Bild
/// eine Textur statt mehrerer bildschirmgroßer Verläufe (wichtig für TV-Boxen).
/// [moving]: zieht langsam und zeigt aufsteigende Lichtpunkte (nur bei voller Leistung).
class Backdrop extends StatefulWidget {
  final double page;
  final bool moving;
  const Backdrop({super.key, this.page = 0, this.moving = true});

  @override
  State<Backdrop> createState() => _BackdropState();
}

class _BackdropState extends State<Backdrop> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 30));
  ui.Image? _img;
  Color? _imgColor;
  bool? _imgLight;

  bool get _run => widget.moving && fxRich;

  void _sync() {
    if (_run && !_c.isAnimating) {
      _c.repeat();
    } else if (!_run && _c.isAnimating) {
      _c.stop();
    }
  }

  // Leistungsmodus kann sich jederzeit ändern (Einstellung, Erkennung)
  bool _speed = Perf.speed;

  void _onStore() {
    if (!mounted) return;
    if (_run != _c.isAnimating || _speed != Perf.speed) {
      _speed = Perf.speed;
      setState(_sync);
    }
  }

  @override
  void initState() {
    super.initState();
    store.addListener(_onStore);
    _sync();
  }

  @override
  void didUpdateWidget(Backdrop old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    _c.dispose();
    _img?.dispose();
    super.dispose();
  }

  // Lage im Bild (deckt 140 % des Bildschirms ab: Platz zum Verschieben), Farbton-Versatz, Größe, Deckkraft
  static const _blobs = [
    (x: .26, y: .24, hue: -38.0, r: .42, a: .34),
    (x: .8, y: .42, hue: 0.0, r: .36, a: .26),
    (x: .5, y: .86, hue: 42.0, r: .48, a: .24),
  ];

  /// Wolken in 192 × 108 Pixeln: weich genug, dass das Hochskalieren nicht auffällt.
  static ui.Image _render(Color accent) {
    const w = 192, h = 108;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final hsl = HSLColor.fromColor(accent);
    // Deckend: beim Zeichnen keine zweite Füllfläche und kein Überblenden nötig
    c.drawRect(const Rect.fromLTWH(0, 0, w + 0.0, h + 0.0), Paint()..color = bg);
    for (final b in _blobs) {
      final center = Offset(b.x * w, b.y * h), radius = b.r * w;
      final color = hsl.withHue((hsl.hue + b.hue) % 360).withLightness(hsl.lightness.clamp(.45, .6)).toColor();
      c.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [color.withValues(alpha: b.a), color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    // Ränder abdunkeln: Text bleibt lesbar
    const rect = Rect.fromLTWH(0, 0, w + 0.0, h + 0.0);
    c.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(radius: .75, colors: [bg.withValues(alpha: 0), bg.withValues(alpha: .75)])
            .createShader(rect),
    );
    final pic = rec.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    return img;
  }

  @override
  Widget build(BuildContext context) {
    // Speed-Modus: schlichter Hintergrund
    if (Perf.speed) return ColoredBox(color: bg);
    final accent = Theme.of(context).colorScheme.primary;
    if (_img == null || _imgColor != accent || _imgLight != isLight) {
      _img?.dispose();
      _img = _render(accent);
      _imgColor = accent;
      _imgLight = isLight;
    }
    final img = _img!;
    return RepaintBoundary(
      child: ClipRect(
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: widget.page),
          duration: fxMs(1400),
          curve: Curves.easeInOutCubic,
          builder: (_, p, _) => CustomPaint(painter: _BackdropPainter(img, _c, p, _run), size: Size.infinite),
        ),
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  final ui.Image img;
  final Animation<double> t;
  final double page;
  final bool dots;
  _BackdropPainter(this.img, this.t, this.page, this.dots) : super(repaint: t);

  static final _dots = () {
    final r = math.Random(7);
    return [for (var i = 0; i < 40; i++) (x: r.nextDouble(), y: r.nextDouble(), s: .4 + r.nextDouble(), v: .3 + r.nextDouble())];
  }();

  @override
  void paint(Canvas canvas, Size s) {
    final a = t.value * 2 * math.pi;
    // Je Seite ein anderer Ausschnitt, dazu langsames Ziehen
    final dx = (.08 * math.sin(page * .9) + .03 * math.cos(a)) * s.width;
    final dy = (.06 * math.cos(page * .7) + .03 * math.sin(a * 2)) * s.height;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromCenter(center: s.center(Offset(dx, dy)), width: s.width * 1.4, height: s.height * 1.4),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..blendMode = BlendMode.src,
    );
    if (!dots) return;
    // Lichtpunkte steigen langsam auf und funkeln
    final p = Paint();
    for (final (i, d) in _dots.indexed) {
      final y = (d.y - t.value * d.v * 1.4) % 1.0;
      final tw = math.pow(math.sin(a * 6 * d.v + i), 2).toDouble();
      p.color = ink(.05 + .2 * tw);
      canvas.drawCircle(Offset(d.x * s.width, y * s.height), 1.1 * d.s, p);
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.img != img || old.page != page || old.dots != dots;
}

// ---------------- Bausteine ----------------

/// Taucht nach [index] Schritten von unten auf (gestaffelter Seitenaufbau).
class Rise extends StatefulWidget {
  final int index;
  final Widget child;
  final double distance;
  const Rise(this.index, {super.key, required this.child, this.distance = 28});

  @override
  State<Rise> createState() => _RiseState();
}

class _RiseState extends State<Rise> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: fxMs(700));
  Timer? _t;

  @override
  void initState() {
    super.initState();
    if (store.reduceMotion) {
      _c.value = 1;
    } else {
      // Höchstens ~1 s Staffelung: lange Listen sollen nicht warten
      final step = Perf.lite ? 40 : 75;
      _t = Timer(Duration(milliseconds: 90 + math.min(widget.index, 12) * step), _c.forward);
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (_, child) {
          final v = Curves.easeOutCubic.transform(_c.value);
          // Fertig: ohne Opacity-Ebene zeichnen (spart eine Ebene je Element)
          if (v == 1) return child!;
          return Opacity(
            opacity: v,
            child: Transform.translate(offset: Offset(0, (1 - v) * widget.distance), child: child),
          );
        },
      );
}

/// Knopf: [primary] mit Verlauf in Akzentfarbe, sonst hell umrandet.
class GlowButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool primary, autofocus, big, leading;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  const GlowButton({
    super.key,
    required this.label,
    required this.onTap,
    this.focusNode,
    this.icon,
    this.primary = false,
    this.autofocus = false,
    this.big = false,
    this.leading = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final fg = primary ? store.onAccent : ink(1);
    final i = icon == null ? null : Icon(icon, size: big ? 22 : 19, color: fg);
    return Tap(
      autofocus: autofocus,
      focusNode: focusNode,
      onTap: onTap,
      radius: 14,
      scale: 1.06,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: big ? 32 : 20, vertical: big ? 18 : 13),
        decoration: BoxDecoration(
          gradient: primary && !Perf.speed ? LinearGradient(colors: [accent, Color.lerp(accent, Colors.white, .22)!]) : null,
          color: primary ? (Perf.speed ? accent : null) : ink(.07),
          border: primary ? null : Border.all(color: ink(.12)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (leading && i != null) ...[i, const SizedBox(width: 10)],
          Text(label, style: TextStyle(color: fg, fontSize: big ? 18 : 15, fontWeight: FontWeight.w700)),
          if (!leading && i != null) ...[const SizedBox(width: 10), i],
        ]),
      ),
    );
  }
}

/// Lichtstreifen, der regelmäßig über [child] läuft (nur bei voller Leistung).
class Shine extends StatefulWidget {
  final Widget child;
  const Shine({super.key, required this.child});

  @override
  State<Shine> createState() => _ShineState();
}

class _ShineState extends State<Shine> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));

  @override
  void initState() {
    super.initState();
    if (fxRich) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!fxRich) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (_, child) {
        // Erstes Drittel: Streifen läuft durch, danach Pause ohne Shader-Ebene
        final v = (_c.value * 3).clamp(0.0, 1.0);
        if (v == 1) return child!;
        final x = -1.6 + 3.2 * v;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (r) => LinearGradient(
            begin: Alignment(x - .45, -.4),
            end: Alignment(x + .45, .4),
            colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: .42), Colors.white.withValues(alpha: 0)],
          ).createShader(r),
          child: child,
        );
      },
    );
  }
}

/// Text mit wanderndem Glanz in der Akzentfarbe (nur bei voller Leistung).
class Shimmer extends StatefulWidget {
  final Widget child;
  const Shimmer({super.key, required this.child});

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 4200));

  @override
  void initState() {
    super.initState();
    if (fxRich) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!fxRich) return widget.child;
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (_, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) => LinearGradient(
          begin: Alignment(-1 + 4 * _c.value - 1.5, 0),
          end: Alignment(1 + 4 * _c.value - 1.5, 0),
          colors: [fg, Color.lerp(accent, fg, .25)!, fg],
          stops: const [.2, .5, .8],
        ).createShader(r),
        child: child,
      ),
    );
  }
}

/// Seitenwechsel wie in der Einrichtung: neue Seite gleitet und blendet ein, leicht vergrößert.
class FxPageTransitions extends PageTransitionsBuilder {
  const FxPageTransitions();

  @override
  Duration get transitionDuration => fxMs(420);

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (store.reduceMotion) return child;
    // Fade-Through: die alte Seite ist im ersten Drittel weg, erst danach kommt die neue.
    // Seiten sind durchsichtig (gemeinsamer Hintergrund): so sieht man nie beide übereinander.
    const inPart = Interval(.3, 1, curve: Curves.easeOutCubic), outPart = Interval(0, .3, curve: Curves.easeIn);
    // Gleiche Kurve auch beim Zurück: oben liegende Seite geht zuerst, die darunter kommt danach
    final shown = CurvedAnimation(parent: animation, curve: inPart);
    final hidden = CurvedAnimation(parent: secondaryAnimation, curve: outPart);
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.0).animate(hidden),
      child: FadeTransition(
        opacity: shown,
        child: Perf.lite ? child : ScaleTransition(scale: Tween(begin: .97, end: 1.0).animate(shown), child: child),
      ),
    );
  }
}
