import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;

import '../store.dart';
import 'common.dart';
import 'setup.dart';

/// Startanimation: das App-Zeichen (Balken + Play-Dreieck) wird zum Schriftzug „CinemaMax“.
/// Ablauf passend zum Startton: Luftzug (Balken wächst), Bass-Schlag (Dreieck landet),
/// Akkord (Dreieck fährt los, Schriftzug öffnet sich hinter dem Balken).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  mk.Player? _sound;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    if (store.get('introSound', true)) {
      try {
        _sound = mk.Player(configuration: const mk.PlayerConfiguration(title: 'CinemaMax'))
          ..open(mk.Media('asset:///assets/sound/intro.ogg'));
      } catch (_) {
        /* ohne Ton weiter */
      }
    }
    _c.forward().whenComplete(_leave);
  }

  void _leave() {
    if (_left || !mounted) return;
    _left = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 380),
        pageBuilder: (_, _, _) => firstScreen(),
        transitionsBuilder: (_, a, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
    // Ton ausklingen lassen, dann freigeben
    Timer(const Duration(seconds: 2), () => _sound?.dispose());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Wert 0..1 innerhalb eines Abschnitts der Gesamtzeit.
  double _p(double from, double to, [Curve curve = Curves.linear]) =>
      curve.transform(((_c.value - from) / (to - from)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final accent = store.accent;
    final size = MediaQuery.sizeOf(context);
    final unit = math.min(size.width, size.height) / 9; // Höhe des Balkens
    return Scaffold(
      backgroundColor: bg,
      body: Focus(
        autofocus: true,
        // Jede Taste / jeder Tipp überspringt
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent) _leave();
          return KeyEventResult.handled;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _leave,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final bar = _p(0, .21, Curves.easeOutCubic); // Balken wächst
              final land = _p(.10, .21, Curves.easeOutBack); // Dreieck landet
              final fire = _p(.30, .42, Curves.easeInCubic); // Dreieck fährt los
              final reveal = _p(.33, .64, Curves.easeOutQuart); // Schriftzug öffnet sich
              final out = _p(.86, 1, Curves.easeInCubic); // Ausblenden

              final tri = SizedBox(
                width: unit * .82,
                height: unit,
                child: CustomPaint(painter: PlayTriangle(fg)),
              );

              return Opacity(
                opacity: 1 - out,
                child: Transform.scale(
                  scale: 1 + out * .06,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Balken
                          Transform.scale(
                            scaleY: bar,
                            child: Container(
                              width: unit * .19,
                              height: unit,
                              decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(unit * .07)),
                            ),
                          ),
                          SizedBox(width: unit * .2),
                          // Platz für Dreieck bzw. Schriftzug
                          Stack(
                            alignment: Alignment.centerLeft,
                            children: [
                              ClipRect(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: reveal,
                                  child: Opacity(
                                    opacity: reveal,
                                    child: Text(
                                      'CinemaMax',
                                      style: TextStyle(
                                        fontSize: unit * .78,
                                        fontWeight: FontWeight.w800,
                                        height: 1,
                                        letterSpacing: -2 + (1 - reveal) * 10,
                                        color: fg,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // Dreieck: landet mit leichter Drehung, fährt dann nach rechts aus dem Bild
                              if (fire < 1)
                                Transform.translate(
                                  offset: Offset(fire * unit * 9, 0),
                                  child: Opacity(
                                    opacity: (land * (1 - fire)).clamp(0, 1),
                                    child: Transform.rotate(
                                      angle: (1 - land) * -.5,
                                      child: Transform.scale(
                                        scaleX: 1 + fire * 1.8,
                                        scaleY: (.4 + .6 * land) * (1 - fire * .55),
                                        child: tri,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Play-Dreieck des App-Zeichens (auch in der Einrichtung).
class PlayTriangle extends CustomPainter {
  final Color color;
  PlayTriangle(this.color);

  @override
  void paint(Canvas canvas, Size s) {
    final r = s.width * .06; // leicht abgerundete Ecken
    final path = Path()
      ..moveTo(r, 0)
      ..lineTo(s.width - r, s.height / 2 - r * .6)
      ..quadraticBezierTo(s.width, s.height / 2, s.width - r, s.height / 2 + r * .6)
      ..lineTo(r, s.height)
      ..quadraticBezierTo(0, s.height, 0, s.height - r)
      ..lineTo(0, r)
      ..quadraticBezierTo(0, 0, r, 0)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(PlayTriangle old) => old.color != color;
}
