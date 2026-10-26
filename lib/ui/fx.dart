import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../perf.dart';
import '../store.dart';
import 'common.dart';

/// Gemeinsame Effekte der Oberfläche (Einrichtung und App). Alle achten auf „Animationen reduzieren“
/// und den Leistungsmodus „Flüssig“ ([Perf.lite]).

/// Animationsdauer: bei „Animationen reduzieren“ sofort, im Modus „Flüssig“ kürzer.
Duration fxMs(int ms) =>
    store.reduceMotion ? Duration.zero : Duration(milliseconds: Perf.lite ? (ms * .6).round() : ms);

/// Dauer-Animationen (Pulsieren) nur bei voller Leistung.
bool get fxRich => !store.reduceMotion && !Perf.lite;

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

/// Knopf: [primary] in Akzentfarbe, sonst hell umrandet.
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
          color: primary ? accent : ink(.07),
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
