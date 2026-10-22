import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../device_check.dart';
import '../perf.dart';
import '../i18n.dart';
import '../playback.dart';
import '../store.dart';
import 'common.dart';
import 'fx.dart';
import 'settings.dart' show accentColors;
import 'splash.dart' show PlayTriangle;
import 'start.dart';

/// Erster Bildschirm nach der Startanimation: die Einrichtung, bis sie einmal beendet oder übersprungen wurde.
Widget firstScreen() => store.get('setupDone', false) ? const StartScreen() : const SetupScreen();


const _green = Color(0xFF30A46C), _amber = Color(0xFFE5A23A), _red = Color(0xFFE5484D);

Route<void> _fade(Widget page) => PageRouteBuilder(
      transitionDuration: fxMs(500),
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, a, _, child) =>
          FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: child),
    );

/// Gerätetyp ohne die Einstellung „Oberfläche“ (wie [formFactor] bei „Automatisch“).
Ff _detected(BuildContext c) {
  if (isAndroidTv) return Ff.tv;
  if (!Platform.isAndroid && !Platform.isIOS) return Ff.desktop;
  return MediaQuery.sizeOf(c).shortestSide < 600 ? Ff.phone : Ff.tablet;
}

String _deviceName(Ff f) => switch (f) {
      Ff.tv => tr('Fernseher'),
      Ff.phone => tr('Handy'),
      Ff.tablet => tr('Tablet'),
      Ff.desktop => tr('PC'),
    };

IconData _deviceIcon(Ff f) => switch (f) {
      Ff.tv => Icons.tv_rounded,
      Ff.phone => Icons.smartphone_rounded,
      Ff.tablet => Icons.tablet_rounded,
      Ff.desktop => Icons.computer_rounded,
    };

// ---------------- Einrichtung ----------------

/// Einrichtung beim ersten Start: Sprache, Aussehen, Leistung, Bildschirm, Geräte-Check. Überspringbar,
/// später unter Einstellungen → Start erneut aufrufbar.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  // Sprachwechsel baut die ganze App neu auf: Seite merken
  static int _resume = 0;
  static const _count = 7;
  late int _page = _resume;
  bool _forward = true;
  // Früh starten: die Bildschirm-Seite braucht die echte Auflösung, der Check ist dann schon fertig
  final Future<DeviceInfo> _device = DeviceCheck.run();

  void _go(int to) {
    if (to < 0 || to >= _count || to == _page) return;
    // Fokus der alten Seite lösen: sonst greift der Autofokus der neuen Seite nicht
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _forward = to > _page;
      _page = _resume = to;
    });
  }

  /// Fertig oder übersprungen: zum Start, optional gleich weiter nach [then].
  void _finish([Widget? then]) {
    store.set('setupDone', true);
    _resume = 0;
    final nav = Navigator.of(context);
    nav.pushReplacement(_fade(const StartScreen()));
    if (then != null) nav.push(MaterialPageRoute(builder: (_) => then));
  }

  Widget _pageAt(int i) => switch (i) {
        0 => _Welcome(onStart: () => _go(1)),
        1 => const _LanguagePage(),
        2 => const _LookPage(),
        3 => const _PerfPage(),
        4 => _ScreenPage(device: _device),
        5 => _CheckPage(device: _device),
        _ => _DonePage(device: _device, onDone: _finish),
      };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => PopScope(
          canPop: _page == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _go(_page - 1);
          },
          child: Scaffold(
            backgroundColor: bg,
            body: Stack(children: [
              Positioned.fill(child: Backdrop(page: _page.toDouble())),
              SafeArea(
                child: Column(children: [
                  _TopBar(page: _page, count: _count, onSkip: _page < _count - 1 ? () => _finish() : null),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: fxMs(620),
                      reverseDuration: fxMs(360),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (cur, prev) => Stack(fit: StackFit.expand, children: [...prev, ?cur]),
                      transitionBuilder: (child, a) {
                        // Neue Seite kommt aus Laufrichtung, alte geht zur anderen Seite
                        final incoming = child.key == ValueKey(_page);
                        final dx = (_forward ? 1 : -1) * (incoming ? .14 : -.14);
                        // Schwaches Gerät: alte Seite sofort weg, neue gleitet nur (ohne bildschirmgroße
                        // Überblend-Ebene); ihre Teile blenden einzeln ein
                        if (Perf.lite) {
                          if (!incoming) return const SizedBox();
                          return SlideTransition(
                            position: Tween(begin: Offset(dx * .5, 0), end: Offset.zero).animate(a),
                            child: child,
                          );
                        }
                        return ExcludeFocus(
                          excluding: !incoming,
                          child: IgnorePointer(
                            ignoring: !incoming,
                            child: FadeTransition(
                              opacity: a,
                              child: SlideTransition(
                                position: Tween(begin: Offset(dx, 0), end: Offset.zero).animate(a),
                                child: Perf.lite ? child : ScaleTransition(scale: Tween(begin: .94, end: 1.0).animate(a), child: child),
                              ),
                            ),
                          ),
                        );
                      },
                      child: KeyedSubtree(key: ValueKey(_page), child: _pageAt(_page)),
                    ),
                  ),
                  if (_page > 0 && _page < _count - 1)
                    // Pro Seite neu: auf dem Geräte-Check (nichts zum Auswählen) bekommt „Weiter“ den Fokus
                    KeyedSubtree(
                      key: ValueKey('bar$_page'),
                      child: _BottomBar(onBack: () => _go(_page - 1), onNext: () => _go(_page + 1), focusNext: _page == 5),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      );
}

/// Geräte-Check allein (Einstellungen → Start).
class DeviceCheckScreen extends StatefulWidget {
  const DeviceCheckScreen({super.key});

  @override
  State<DeviceCheckScreen> createState() => _DeviceCheckScreenState();
}

class _DeviceCheckScreenState extends State<DeviceCheckScreen> {
  final Future<DeviceInfo> _device = DeviceCheck.run();

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: bg,
        appBar: AppBar(backgroundColor: Colors.transparent),
        extendBodyBehindAppBar: true,
        body: Stack(children: [
          const Positioned.fill(child: Backdrop(page: 5)),
          SafeArea(child: Padding(padding: const EdgeInsets.only(top: 40), child: _CheckPage(device: _device))),
        ]),
      );
}

// ---------------- Rahmen ----------------

class _TopBar extends StatelessWidget {
  final int page, count;
  final VoidCallback? onSkip;
  const _TopBar({required this.page, required this.count, this.onSkip});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 14, 0),
      child: Column(children: [
        Row(children: [
          const Wordmark(),
          const Spacer(),
          AnimatedSwitcher(
            duration: fxMs(320),
            transitionBuilder: (c, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(position: Tween(begin: const Offset(0, .6), end: Offset.zero).animate(a), child: c),
            ),
            child: Text('${page + 1} / $count',
                key: ValueKey(page), style: const TextStyle(color: textDim, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 6),
          AnimatedOpacity(
            opacity: onSkip == null ? 0 : 1,
            duration: fxMs(250),
            child: Tap(
              radius: 100,
              onTap: onSkip,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(tr('Überspringen'), style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          for (var i = 0; i < count; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 4,
                    color: Colors.white12,
                    child: AnimatedFractionallySizedBox(
                      duration: fxMs(700),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.centerLeft,
                      widthFactor: i <= page ? 1 : 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [accent, Color.lerp(accent, Colors.white, .35)!]),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final VoidCallback onBack, onNext;
  final bool focusNext;
  const _BottomBar({required this.onBack, required this.onNext, this.focusNext = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 6, 24, 16),
        child: Row(children: [
          GlowButton(label: tr('Zurück'), icon: Icons.arrow_back_rounded, leading: true, onTap: onBack),
          const Spacer(),
          GlowButton(label: tr('Weiter'), icon: Icons.arrow_forward_rounded, primary: true, autofocus: focusNext, onTap: onNext),
        ]),
      );
}

/// Seite: Titel, Untertitel, Inhalt; zentriert, auf kleinen Bildschirmen scrollbar.
class _PageFrame extends StatelessWidget {
  final String? title, subtitle;
  final Widget child;
  final bool center;
  const _PageFrame({this.title, this.subtitle, required this.child, this.center = false});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final compact = box.maxHeight < 440; // Fernseher (960×540) und Handy quer
        final wide = box.maxWidth >= 760;
        final pad = compact ? 8.0 : 20.0;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: wide ? 48 : 20, vertical: pad),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: math.max(0, box.maxHeight - pad * 2)),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      Rise(0,
                          child: Text(title!,
                              style: TextStyle(
                                  fontSize: compact ? 26 : (wide ? 38 : 28),
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1.2))),
                    if (subtitle != null && !compact) ...[
                      const SizedBox(height: 8),
                      Rise(1,
                          child: Text(subtitle!, style: const TextStyle(color: textDim, fontSize: 15.5, height: 1.45))),
                    ],
                    if (title != null) SizedBox(height: compact ? 14 : 28),
                    child,
                  ],
                ),
              ),
            ),
          ),
        );
      });
}

// ---------------- 1. Willkommen ----------------

class _Welcome extends StatelessWidget {
  final VoidCallback onStart;
  const _Welcome({required this.onStart});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final short = MediaQuery.sizeOf(context).height < 560;
    final features = [
      (Icons.live_tv_rounded, tr('Live-TV & TV-Guide')),
      (Icons.movie_outlined, tr('Filme & Serien')),
      (Icons.four_k_rounded, tr('4K & HDR')),
      (Icons.settings_remote_rounded, tr('Fernbedienung')),
      (Icons.download_rounded, tr('Downloads')),
    ];
    return _PageFrame(
      center: true,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _LogoHero(size: short ? 46 : (wide ? 74 : 60)),
        SizedBox(height: short ? 6 : 18),
        Rise(1, child: Text(tr('Willkommen bei'), style: const TextStyle(color: textDim, fontSize: 18, fontWeight: FontWeight.w600))),
        Rise(2,
            child: Shimmer(
              child: Text('CinemaMax',
                  style: TextStyle(fontSize: short ? 40 : (wide ? 64 : 46), fontWeight: FontWeight.w900, letterSpacing: -2.4, height: 1.1)),
            )),
        const SizedBox(height: 10),
        Rise(3,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Text(
                tr('In einer Minute eingerichtet: Sprache, Aussehen, Bildschirm und ein Check, was dein Gerät alles abspielt.'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: textDim, fontSize: 16, height: 1.5),
              ),
            )),
        SizedBox(height: short ? 14 : 24),
        Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 10, children: [
          for (final (i, (icon, text)) in features.indexed) Rise(4 + i, distance: 16, child: _Feature(icon, text)),
        ]),
        SizedBox(height: short ? 18 : 34),
        Rise(9,
            child: Shine(
              child: GlowButton(label: tr("Los geht's"), icon: Icons.arrow_forward_rounded, primary: true, big: true, autofocus: true, onTap: onStart),
            )),
        const SizedBox(height: 12),
        Rise(10, child: Text(tr('Dauert weniger als eine Minute'), style: const TextStyle(color: textDim, fontSize: 12.5))),
      ]),
    );
  }
}

class _Feature extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Feature(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: surface.withValues(alpha: .7),
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 17, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// App-Zeichen baut sich auf (Balken wächst, Dreieck landet), dann pulsieren Ringe.
class _LogoHero extends StatefulWidget {
  final double size;
  const _LogoHero({required this.size});

  @override
  State<_LogoHero> createState() => _LogoHeroState();
}

class _LogoHeroState extends State<_LogoHero> with TickerProviderStateMixin {
  late final _in = AnimationController(vsync: this, duration: fxMs(1500))..forward();
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));

  @override
  void initState() {
    super.initState();
    if (fxRich) _pulse.repeat();
  }

  @override
  void dispose() {
    _in.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final u = widget.size;
    return AnimatedBuilder(
      animation: Listenable.merge([_in, _pulse]),
      builder: (_, _) {
        double seg(double from, double to, Curve c) => c.transform(((_in.value - from) / (to - from)).clamp(0.0, 1.0));
        final bar = seg(0, .45, Curves.easeOutCubic);
        final land = seg(.3, .8, Curves.easeOutBack);
        final rings = seg(.6, 1, Curves.easeOut);
        return SizedBox(
          width: u * 4.4,
          height: u * 2.6,
          child: Stack(alignment: Alignment.center, children: [
            for (var k = 0; k < 3; k++)
              () {
                final v = (_pulse.value + k / 3) % 1;
                return Opacity(
                  opacity: ((1 - v) * .45 * rings).clamp(0.0, 1.0),
                  child: Container(
                    width: u * (1.5 + v * 2.8),
                    height: u * (1.5 + v * 2.8),
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: accent, width: 1.6)),
                  ),
                );
              }(),
            if (!Perf.speed)
             Container(
              width: u * 2.6,
              height: u * 2.6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  accent.withValues(alpha: (.38 * land).clamp(0.0, 1.0)),
                  accent.withValues(alpha: 0),
                ]),
              ),
            ),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Transform.scale(
                scaleY: bar,
                child: Container(
                  width: u * .19,
                  height: u,
                  decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(u * .07)),
                ),
              ),
              SizedBox(width: u * .2),
              Opacity(
                opacity: land.clamp(0.0, 1.0),
                child: Transform.rotate(
                  angle: (1 - land) * -.6,
                  child: Transform.scale(
                    scale: .3 + .7 * land,
                    child: SizedBox(width: u * .82, height: u, child: CustomPaint(painter: PlayTriangle(Colors.white))),
                  ),
                ),
              ),
            ]),
          ]),
        );
      },
    );
  }
}

// ---------------- Auswahl-Bausteine ----------------

/// Kachel zum Auswählen; gewählt: Akzentrahmen und Haken, der hineinspringt.
class _ChoiceCard extends StatelessWidget {
  final int index;
  final Widget lead;
  final String title;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceCard({
    required this.index,
    required this.lead,
    required this.title,
    this.detail,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Rise(
      index,
      child: Tap(
        autofocus: selected,
        onTap: onTap,
        radius: 18,
        scale: 1.04,
        child: AnimatedContainer(
          duration: fxMs(280),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: .16) : surface.withValues(alpha: .75),
            border: Border.all(color: selected ? accent : line, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(children: [
            lead,
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(detail!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: textDim, fontSize: 13)),
                ],
              ]),
            ),
            const SizedBox(width: 8),
            AnimatedScale(
              scale: selected ? 1 : 0,
              duration: fxMs(520),
              curve: selected ? Curves.elasticOut : Curves.easeIn,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                child: Icon(Icons.check_rounded, size: 17, color: store.onAccent),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Rundes Symbol vor einer Auswahl.
class _Lead extends StatelessWidget {
  final Widget child;
  const _Lead(this.child);

  @override
  Widget build(BuildContext context) => Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: .15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );
}

/// Kacheln gleich breit in so vielen Spalten, wie Platz ist.
class _Grid extends StatelessWidget {
  final List<Widget> children;
  final double minWidth;
  const _Grid({required this.children, this.minWidth = 240});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        var cols = (box.maxWidth / minWidth).floor().clamp(1, math.min(4, children.length));
        // Gleich volle Reihen: 4 Kacheln lieber 2 × 2 als 3 + 1
        while (cols > 2 && children.length % cols != 0) {
          cols--;
        }
        final w = (box.maxWidth - (cols - 1) * 14) / cols;
        return Wrap(spacing: 14, runSpacing: 14, children: [for (final c in children) SizedBox(width: w, child: c)]);
      });
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Tap(
      autofocus: selected,
      onTap: onTap,
      radius: 100,
      scale: 1.08,
      child: AnimatedContainer(
        duration: fxMs(260),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? accent : Colors.white.withValues(alpha: .07),
          border: Border.all(color: selected ? accent : Colors.white12),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? store.onAccent : Colors.white, fontWeight: FontWeight.w700, fontSize: 14.5)),
      ),
    );
  }
}

// ---------------- 2. Sprache ----------------

class _LanguagePage extends StatelessWidget {
  const _LanguagePage();

  @override
  Widget build(BuildContext context) {
    final cur = store.get('lang', 'system');
    final sys = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    final auto = const {'de', 'tr', 'en'}.contains(sys) ? sys : 'en';
    return _PageFrame(
      title: tr('Welche Sprache?'),
      subtitle: tr('Die App wechselt sofort. Später änderbar unter Einstellungen → Darstellung.'),
      child: _Grid(children: [
        for (final (i, MapEntry(key: code, value: name)) in languages.entries.indexed)
          _ChoiceCard(
            index: 2 + i,
            selected: code == cur,
            onTap: () => store.set('lang', code),
            lead: _Lead(code == 'system'
                ? Icon(Icons.language_rounded, color: Theme.of(context).colorScheme.primary)
                : Text(code.toUpperCase(),
                    style: TextStyle(
                        fontWeight: FontWeight.w900, fontSize: 16, color: Theme.of(context).colorScheme.primary))),
            title: code == 'system' ? tr('Wie das Gerät') : name,
            detail: code == 'system' ? languages[auto] : null,
          ),
      ]),
    );
  }
}

// ---------------- 3. Aussehen ----------------

class _LookPage extends StatelessWidget {
  const _LookPage();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final detected = _detected(context);
    final cur = store.layout;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final current = formFactor(context);
    final options = [
      ('auto', tr('Automatisch'), tr('Erkannt: {0}', [_deviceName(detected)]), Icons.auto_awesome_rounded),
      ('tv', tr('Fernseher'), tr('Große Kacheln, Fernbedienung'), Icons.tv_rounded),
      ('phone', tr('Handy'), tr('Kompakt, Wischen und Tippen'), Icons.smartphone_rounded),
      ('desktop', tr('PC / Tablet'), tr('Maus, Tastatur, viel Platz'), Icons.computer_rounded),
    ];
    final cards = _Grid(minWidth: 250, children: [
      for (final (i, (key, title, detail, icon)) in options.indexed)
        _ChoiceCard(
          index: 2 + i,
          selected: cur == key,
          onTap: () => store.set('layout', key),
          lead: _Lead(Icon(icon, color: accent)),
          title: title,
          detail: detail,
        ),
    ]);
    final swatches = Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final (i, color) in accentColors.keys.cast<int>().indexed)
        Rise(8 + i, distance: 14, child: _Swatch(Color(color), selected: store.accent.toARGB32() == color)),
    ]);
    // Großes Gerät, das bei jeder Wahl mit Schwung wechselt
    final preview = AnimatedSwitcher(
      duration: fxMs(520),
      transitionBuilder: (c, a) => ScaleTransition(
        scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
        child: RotationTransition(turns: Tween(begin: -.08, end: 0.0).animate(a), child: FadeTransition(opacity: a, child: c)),
      ),
      child: Container(
        key: ValueKey(current),
        width: wide ? 210 : 120,
        height: wide ? 210 : 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [accent.withValues(alpha: .35), accent.withValues(alpha: .04)]),
          border: Border.all(color: accent.withValues(alpha: .5), width: 1.5),
        ),
        child: Icon(_deviceIcon(current), size: wide ? 96 : 56, color: Colors.white),
      ),
    );
    final colors = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Rise(7, child: Text(tr('Akzentfarbe'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
      const SizedBox(height: 12),
      swatches,
    ]);
    return _PageFrame(
      title: tr('Wie schaust du?'),
      subtitle: tr('Die Oberfläche passt sich an: Fernbedienung, Touch oder Maus.'),
      child: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [cards, const SizedBox(height: 26), colors])),
              const SizedBox(width: 40),
              Rise(3, child: preview),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: Rise(2, child: preview)),
              const SizedBox(height: 20),
              cards,
              const SizedBox(height: 22),
              colors,
            ]),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  const _Swatch(this.color, {required this.selected});

  @override
  Widget build(BuildContext context) => Tap(
        radius: 100,
        scale: 1.18,
        onTap: () => store.set('accent', color.toARGB32()),
        child: AnimatedContainer(
          duration: fxMs(320),
          curve: Curves.easeOutBack,
          width: selected ? 44 : 36,
          height: selected ? 44 : 36,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 3),
          ),
          child: selected
              ? Icon(Icons.check_rounded,
                  size: 20,
                  color: ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black)
              : null,
        ),
      );
}

// ---------------- 4. Leistung ----------------

/// Schwaches Gerät? Auswahl mit Live-Messung der Bildrate.
class _PerfPage extends StatelessWidget {
  const _PerfPage();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final cur = Perf.mode;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final options = [
      (
        'auto',
        tr('Automatisch'),
        switch (Perf.effective) {
          'speed' => tr('Erkannt: sehr schwaches Gerät, Speed'),
          'lite' => tr('Erkannt: schwaches Gerät, Flüssig'),
          _ => tr('Erkannt: starkes Gerät, alle Effekte'),
        },
        Icons.auto_awesome_rounded,
      ),
      ('full', tr('Alle Effekte'), tr('Bewegter Hintergrund, Glanz und Lichter'), Icons.auto_fix_high_rounded),
      ('lite', tr('Flüssig'), tr('Für TV-Boxen und ältere Handys: ruhiger und schneller'), Icons.speed_rounded),
      ('speed', tr('Speed'), tr('Keine Animationen, kein Hintergrund, keine Effekte: am schnellsten'), Icons.bolt_rounded),
    ];
    void choose(String k) => store.set('perf', k);

    final cards = _Grid(minWidth: 250, children: [
      for (final (i, (key, title, detail, icon)) in options.indexed)
        _ChoiceCard(
          index: 2 + i,
          selected: cur == key,
          onTap: () => choose(key),
          lead: _Lead(Icon(icon, color: accent)),
          title: title,
          detail: detail,
        ),
    ]);
    return _PageFrame(
      title: tr('Wie stark ist dein Gerät?'),
      subtitle: tr('TV-Boxen und ältere Handys laufen mit weniger Effekten flüssig. Die Bedienung bleibt gleich.'),
      child: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(child: cards),
              const SizedBox(width: 32),
              const Rise(3, child: SizedBox(width: 250, child: _FpsMeter())),
            ])
          : Column(children: [const Rise(2, child: _FpsMeter()), const SizedBox(height: 18), cards]),
    );
  }
}

/// Gemessene Bildrate mit Verlauf der Bildzeiten. Ein kleiner Kreisel läuft immer, damit gemessen wird.
class _FpsMeter extends StatefulWidget {
  const _FpsMeter();

  @override
  State<_FpsMeter> createState() => _FpsMeterState();
}

class _FpsMeterState extends State<_FpsMeter> with SingleTickerProviderStateMixin {
  // Speed-Modus: steht still (gemessen wird dann nur bei Bewegung auf dem Bildschirm)
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 2));

  @override
  void initState() {
    super.initState();
    if (!Perf.speed) _spin.repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: surface.withValues(alpha: .7),
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(18),
      ),
      child: ValueListenableBuilder<double>(
        valueListenable: Perf.fps,
        builder: (_, fps, _) {
          final color = fps >= 50 ? _green : (fps >= 30 ? _amber : _red);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              RotationTransition(
                turns: _spin,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(colors: [accent.withValues(alpha: 0), accent]),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Text('${fps.round()}', style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900, color: color, height: 1)),
              const SizedBox(width: 6),
              const Text('fps', style: TextStyle(color: textDim, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            Text(tr('Bilder pro Sekunde gerade'), style: const TextStyle(color: textDim, fontSize: 12.5)),
            const SizedBox(height: 12),
            SizedBox(height: 46, width: double.infinity, child: CustomPaint(painter: _FramesPainter(List.of(Perf.frameMs), accent))),
            const SizedBox(height: 6),
            Text(tr('Linie: 60 fps. Balken darunter sind flüssig.'), style: const TextStyle(color: textDim, fontSize: 11.5)),
          ]);
        },
      ),
    );
  }
}

/// Bildzeiten als Balken, Linie bei 16,7 ms (60 fps).
class _FramesPainter extends CustomPainter {
  final List<double> ms;
  final Color accent;
  _FramesPainter(this.ms, this.accent);

  @override
  void paint(Canvas canvas, Size s) {
    const top = 33.4; // 30 fps ganz oben
    final bw = s.width / 120;
    final p = Paint();
    for (final (i, m) in ms.indexed) {
      final h = (m / top).clamp(.04, 1.0) * s.height;
      p.color = m > 33.4 ? _red : (m > 16.7 ? _amber : accent);
      canvas.drawRect(Rect.fromLTWH(i * bw, s.height - h, math.max(1, bw - 1), h), p);
    }
    final y = s.height * (1 - 16.7 / top);
    canvas.drawLine(Offset(0, y), Offset(s.width, y), Paint()..color = Colors.white38..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_FramesPainter old) => true;
}

// ---------------- 5. Bildschirm ----------------

class _ScreenPage extends StatelessWidget {
  final Future<DeviceInfo> device;
  const _ScreenPage({required this.device});

  static String _res(int h) => h <= 0 ? tr('Keine Grenze') : Engine.resolution(0, h)!;

  @override
  Widget build(BuildContext context) {
    final cur = store.get('maxRes', -1);
    final screen = Engine.screenHeight;
    final eff = Engine.maxHeight;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final options = <(int, String)>[
      (-1, screen > 0 ? tr('Automatisch · {0}', [_res(screen)]) : tr('Automatisch')),
      (2160, '4K'),
      (1440, '1440p'),
      (1080, '1080p'),
      (720, '720p'),
      (480, '480p'),
      (360, '360p'),
      (240, '240p'),
      (144, '144p'),
      (0, tr('Keine Grenze')),
    ];
    final explain = switch (cur) {
      -1 when screen > 0 => tr('Passt sich dem Bildschirm an: Streams höchstens in {0}. Schärfer kann er nicht zeigen.', [_res(screen)]),
      -1 => tr('Bildschirm nicht erkannt: Streams in bester Qualität.'),
      0 => tr('Immer die höchste Qualität, auch wenn dein Bildschirm sie nicht zeigen kann.'),
      _ when screen > 0 && !Engine.fits(cur, screen) => tr('Höher als dein Bildschirm: kostet Daten, ohne schärfer zu wirken.'),
      _ when cur <= 480 => tr('Spart viele Daten: gut für mobiles Internet oder langsames WLAN.'),
      _ => tr('Streams höchstens in {0}: spart Daten und Leistung.', [_res(cur)]),
    };
    final chips = Wrap(spacing: 10, runSpacing: 10, children: [
      for (final (i, (v, label)) in options.indexed)
        Rise(3 + i, distance: 14, child: _Chip(label: label, selected: cur == v, onTap: () => store.set('maxRes', v))),
    ]);
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AnimatedSwitcher(
        duration: fxMs(360),
        transitionBuilder: (c, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(position: Tween(begin: const Offset(0, .25), end: Offset.zero).animate(a), child: c),
        ),
        layoutBuilder: (cur, prev) => Stack(alignment: Alignment.topLeft, children: [...prev, ?cur]),
        child: Text(explain, key: ValueKey(explain), style: const TextStyle(fontSize: 15.5, height: 1.45)),
      ),
      const SizedBox(height: 8),
      Text(tr('Gilt für Streams mit mehreren Qualitäten (meist HLS). Am PC wird 4K zusätzlich nur in Bildschirmgröße gezeichnet.'),
          style: const TextStyle(color: textDim, fontSize: 12.5, height: 1.4)),
    ]);
    final viz = FutureBuilder<DeviceInfo>(
      future: device,
      builder: (_, snap) => _ScreenViz(
        screen: screen,
        cap: eff,
        width: snap.data?.width ?? 0,
        height: snap.data?.height ?? 0,
        refresh: snap.data?.refresh ?? 0,
      ),
    );
    return _PageFrame(
      title: tr('Dein Bildschirm'),
      subtitle: tr('Streams werden nie größer geladen, als dein Bildschirm zeigt. Das spart Daten und Leistung.'),
      child: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(flex: 5, child: Rise(2, child: viz)),
              const SizedBox(width: 36),
              Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [chips, const SizedBox(height: 22), text])),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Rise(2, child: viz),
              const SizedBox(height: 22),
              chips,
              const SizedBox(height: 18),
              text,
            ]),
    );
  }
}

/// Auflösungen als ineinander liegende Rahmen (4K außen); Bildschirm leuchtet, Grenze ist gefüllt.
class _ScreenViz extends StatefulWidget {
  final int screen, cap, width, height;
  final double refresh;
  const _ScreenViz({required this.screen, required this.cap, required this.width, required this.height, required this.refresh});

  @override
  State<_ScreenViz> createState() => _ScreenVizState();
}

class _ScreenVizState extends State<_ScreenViz> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  @override
  void initState() {
    super.initState();
    if (fxRich) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final w = math.max(widget.width, widget.height), h = math.min(widget.width, widget.height);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        decoration: BoxDecoration(
          color: surface.withValues(alpha: .65),
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.all(14),
        child: Stack(children: [
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: (widget.cap <= 0 ? 2160 : widget.cap).toDouble()),
              duration: fxMs(700),
              curve: Curves.easeOutCubic,
              builder: (_, cap, _) => AnimatedBuilder(
                animation: _pulse,
                builder: (_, _) => CustomPaint(
                  painter: _ResPainter(screen: widget.screen.toDouble(), cap: cap, accent: accent, pulse: _pulse.value),
                ),
              ),
            ),
          ),
          // Echte Auflösung und Bildrate, zählen hoch
          Positioned(
            right: 4,
            top: 2,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: fxMs(1300),
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(
                  w > 0 ? '${(w * v).round()} × ${(h * v).round()}' : tr('Unbekannt'),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -.8),
                ),
                if (widget.refresh > 0)
                  Text('${(widget.refresh * v).round()} Hz',
                      style: TextStyle(color: accent, fontSize: 14, fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ResPainter extends CustomPainter {
  final double screen, cap, pulse;
  final Color accent;
  _ResPainter({required this.screen, required this.cap, required this.accent, required this.pulse});

  static const _levels = [(2160, '4K'), (1440, '1440p'), (1080, '1080p'), (720, '720p'), (480, '480p')];

  Rect _rect(Size s, double height) {
    final f = (height / 2160).clamp(.0, 1.0);
    return Rect.fromLTWH(0, s.height * (1 - f), s.width * f, s.height * f);
  }

  @override
  void paint(Canvas canvas, Size s) {
    final r = Radius.circular(10);
    // Grenze: gefüllt
    canvas.drawRRect(RRect.fromRectAndRadius(_rect(s, cap), r), Paint()..color = accent.withValues(alpha: .28));
    // Bildschirm: leuchtender Rahmen
    if (screen > 0) {
      final sr = RRect.fromRectAndRadius(_rect(s, math.min(screen, 2160)), r);
      // Leuchten ohne Unschärfe-Filter: der Puls zeichnet jedes Bild neu
      for (final (w, a) in [(12.0, .08), (7.0, .14)]) {
        canvas.drawRRect(
          sr,
          Paint()
            ..color = accent.withValues(alpha: a + a * pulse)
            ..style = PaintingStyle.stroke
            ..strokeWidth = w,
        );
      }
      canvas.drawRRect(
        sr,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
    }
    for (final (lvl, label) in _levels) {
      final rect = _rect(s, lvl.toDouble());
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, r),
        Paint()
          ..color = Colors.white.withValues(alpha: .16)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      final on = cap >= lvl - 1;
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
              color: on ? Colors.white : Colors.white38,
              fontSize: lvl >= 1080 ? 12.5 : 10.5,
              fontWeight: FontWeight.w800),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (rect.width > tp.width + 12 && rect.height > tp.height + 8) {
        tp.paint(canvas, rect.topLeft + const Offset(9, 6));
      }
    }
  }

  @override
  bool shouldRepaint(_ResPainter old) =>
      old.screen != screen || old.cap != cap || old.pulse != pulse || old.accent != accent;
}

// ---------------- 6. Geräte-Check ----------------

class _CheckPage extends StatefulWidget {
  final Future<DeviceInfo> device;
  const _CheckPage({required this.device});

  @override
  State<_CheckPage> createState() => _CheckPageState();
}

class _CheckPageState extends State<_CheckPage> with SingleTickerProviderStateMixin {
  late final _scan = AnimationController(vsync: this);
  DeviceInfo? _info;
  Object? _error;

  @override
  void initState() {
    super.initState();
    widget.device.then((i) {
      if (!mounted) return;
      setState(() => _info = i);
      // Zeile für Zeile „prüfen“: kurz Spinner, dann springt das Ergebnis hinein
      _scan.duration = fxMs(600 + i.items.length * 170);
      _scan.forward();
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PageFrame(
        title: tr('Was kann dein Gerät?'),
        subtitle: tr('Bild, Ton und Bildschirm im Test: was direkt läuft und wo ein anderer Player einspringt.'),
        child: _error != null
            ? Text(tr('Check nicht möglich: {0}', ['$_error']), style: const TextStyle(color: _red))
            : AnimatedBuilder(animation: _scan, builder: (context, _) => _results(context)),
      );

  Widget _results(BuildContext context) {
    final items = _info?.items ?? const <CheckItem>[];
    final shown = _info == null ? 0.0 : (_scan.isCompleted ? items.length + 1.0 : _scan.value * (items.length + .4));
    final done = _info != null && _scan.isCompleted;
    final (okAll, total) = DeviceCheck.score(items);
    final (ok, _) = DeviceCheck.score(items.take(shown.floor()).toList());
    final alt = items.where((i) => i.level == Level.alt).length, fail = items.where((i) => i.level == Level.fail).length;
    final verdict = fail > 0
        ? tr('{0} Formate gehen auf diesem Gerät nicht.', [fail])
        : alt > 0
            ? tr('Alles abspielbar. {0} Formate laufen über mpv.', [alt])
            : tr('Alles bereit: dein Gerät spielt alle geprüften Formate ab.');
    final width = MediaQuery.sizeOf(context).width;
    // Fernseher (960 breit): drei Spalten, damit alles ohne Scrollen passt (Zeilen sind nicht fokussierbar)
    final cols = width >= 900 ? 3 : (width >= 600 ? 2 : 1);
    final groups = <String, List<(int, CheckItem)>>{};
    for (final (i, it) in items.indexed) {
      (groups[it.group] ??= []).add((i, it));
    }
    Widget group(String name) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4, top: 2),
            child: Text(tr(name).toUpperCase(),
                style: const TextStyle(color: textDim, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
          ),
          for (final (i, it) in groups[name]!) _CheckRow(item: it, state: shown - i),
        ]);
    final names = groups.keys.toList();
    final columns = switch (cols) {
      3 => [for (final n in names) [n]],
      2 => [names.take(1).toList(), names.skip(1).toList()],
      _ => [names],
    };
    final ring = _ScoreRing(ok: ok, total: total, done: done, allOk: done && alt == 0 && fail == 0);
    final summary = AnimatedOpacity(
      opacity: done ? 1 : 0,
      duration: fxMs(500),
      child: AnimatedSlide(
        offset: done ? Offset.zero : const Offset(0, .3),
        duration: fxMs(500),
        curve: Curves.easeOutCubic,
        child: Text(verdict, textAlign: cols == 1 ? TextAlign.start : TextAlign.center, style: const TextStyle(fontSize: 14.5, height: 1.4, fontWeight: FontWeight.w600)),
      ),
    );
    final list = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (i, col) in columns.indexed) ...[
        if (i > 0) const SizedBox(width: 22),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (j, n) in col.indexed) ...[if (j > 0) const SizedBox(height: 14), group(n)],
        ])),
      ],
    ]);
    if (_info == null) {
      return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
    }
    if (cols == 1) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [SizedBox(width: 130, child: ring), const SizedBox(width: 18), Expanded(child: summary)]),
        const SizedBox(height: 18),
        list,
        const SizedBox(height: 8),
        Text(tr('Ergebnis: {0} von {1} Formaten laufen.', [okAll, total]), style: const TextStyle(color: textDim, fontSize: 12.5)),
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: width < 1100 ? 150 : 190, child: Column(children: [ring, const SizedBox(height: 14), summary])),
      const SizedBox(width: 30),
      Expanded(child: list),
    ]);
  }
}

/// Zeile im Check. [state] < 0: wartet, 0..1: wird geprüft, ≥ 1: Ergebnis.
class _CheckRow extends StatelessWidget {
  final CheckItem item;
  final double state;
  const _CheckRow({required this.item, required this.state});

  @override
  Widget build(BuildContext context) {
    final done = state >= 1;
    final (icon, color) = switch (item.level) {
      Level.ok => (Icons.check_circle_rounded, _green),
      Level.alt => (Icons.change_circle_rounded, _amber),
      Level.info => (Icons.info_rounded, Theme.of(context).colorScheme.primary),
      Level.fail => (Icons.cancel_rounded, _red),
    };
    return AnimatedOpacity(
      opacity: state < 0 ? .35 : 1,
      duration: fxMs(250),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: done
                  ? TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: fxMs(560),
                      curve: Curves.elasticOut,
                      builder: (_, v, child) => Transform.scale(scale: v, child: child),
                      child: Icon(icon, color: color, size: 22),
                    )
                  : state >= 0
                      ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                      : Container(width: 7, height: 7, decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(tr(item.label), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              AnimatedSwitcher(
                duration: fxMs(260),
                child: Text(
                  done ? item.detail : (state >= 0 ? tr('prüfe …') : ' '),
                  key: ValueKey(done),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: done && item.level != Level.ok ? color : textDim, fontSize: 11.5),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Ring füllt sich mit jedem lauffähigen Format, Zahl zählt mit.
class _ScoreRing extends StatelessWidget {
  final int ok, total;
  final bool done, allOk;
  const _ScoreRing({required this.ok, required this.total, required this.done, required this.allOk});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final color = allOk ? _green : accent;
    return AspectRatio(
      aspectRatio: 1,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: total == 0 ? 0 : ok / total),
        duration: fxMs(420),
        curve: Curves.easeOutCubic,
        builder: (_, v, _) => CustomPaint(
          painter: _RingPainter(v, color),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FittedBox(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '$ok', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: -1.5)),
                  TextSpan(text: ' / $total', style: const TextStyle(fontSize: 16, color: textDim, fontWeight: FontWeight.w700)),
                ])),
              ),
              Text(done ? tr('laufen') : tr('prüfe …'), style: TextStyle(color: done ? color : textDim, fontSize: 12.5, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double v;
  final Color color;
  _RingPainter(this.v, this.color);

  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero), r = s.shortestSide / 2 - 8;
    canvas.drawCircle(c, r, Paint()..color = Colors.white10..style = PaintingStyle.stroke..strokeWidth = 9);
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * v,
      false,
      Paint()
        ..color = color.withValues(alpha: .18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 18
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * v,
      false,
      Paint()
        ..shader = SweepGradient(
          startAngle: -math.pi / 2,
          endAngle: 3 * math.pi / 2,
          colors: [Color.lerp(color, Colors.white, .35)!, color],
        ).createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.v != v || old.color != color;
}

// ---------------- 7. Fertig ----------------

class _DonePage extends StatelessWidget {
  final Future<DeviceInfo> device;
  final void Function([Widget? then]) onDone;
  const _DonePage({required this.device, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final l = store.get('lang', 'system');
    final f = formFactor(context);
    final chips = [
      (Icons.language_rounded, l == 'system' ? tr('Sprache wie das Gerät') : languages[l] ?? l),
      (_deviceIcon(f), _deviceName(f)),
      (Icons.high_quality_rounded, Engine.maxHeight > 0 ? tr('Bis {0}', [Engine.resolution(0, Engine.maxHeight)]) : tr('Keine Grenze')),
    ];
    return Stack(children: [
      const Positioned.fill(child: IgnorePointer(child: _Confetti())),
      _PageFrame(
        center: true,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const _CheckBadge(),
          const SizedBox(height: 20),
          Rise(2,
              child: Text(tr('Alles bereit!'),
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900, letterSpacing: -1.6))),
          const SizedBox(height: 8),
          Rise(3,
              child: Text(tr('Viel Spaß mit CinemaMax. Alles lässt sich später in den Einstellungen ändern.'),
                  textAlign: TextAlign.center, style: const TextStyle(color: textDim, fontSize: 15.5, height: 1.45))),
          const SizedBox(height: 20),
          Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 10, children: [
            for (final (i, (icon, text)) in chips.indexed) Rise(4 + i, distance: 14, child: _Feature(icon, text)),
            Rise(
              7,
              distance: 14,
              child: FutureBuilder<DeviceInfo>(
                future: device,
                builder: (_, s) {
                  if (!s.hasData) return const SizedBox();
                  final (ok, total) = DeviceCheck.score(s.data!.items);
                  return _Feature(Icons.verified_rounded, tr('{0} von {1} Formaten', [ok, total]));
                },
              ),
            ),
          ]),
          const SizedBox(height: 30),
          Rise(
            8,
            child: Wrap(alignment: WrapAlignment.center, spacing: 14, runSpacing: 12, children: [
              Shine(
                child: GlowButton(
                  label: tr('Freie Sender entdecken'),
                  icon: Icons.satellite_alt_rounded,
                  leading: true,
                  primary: true,
                  autofocus: true,
                  onTap: () => onDone(const SourcesScreen(iptv: true)),
                ),
              ),
              GlowButton(label: tr('Eigenen Server hinzufügen'), icon: Icons.dns_rounded, leading: true, onTap: () => onDone(const SourcesScreen())),
              GlowButton(label: tr('Zum Start'), icon: Icons.home_rounded, leading: true, onTap: () => onDone()),
            ]),
          ),
        ]),
      ),
    ]);
  }
}

/// Kreis springt auf, Haken zeichnet sich.
class _CheckBadge extends StatefulWidget {
  const _CheckBadge();

  @override
  State<_CheckBadge> createState() => _CheckBadgeState();
}

class _CheckBadgeState extends State<_CheckBadge> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: fxMs(1300))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final pop = Curves.elasticOut.transform((_c.value / .55).clamp(0.0, 1.0));
        final draw = Curves.easeInOutCubic.transform(((_c.value - .3) / .5).clamp(0.0, 1.0));
        return Transform.scale(
          scale: pop,
          child: Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [accent, Color.lerp(accent, Colors.white, .3)!]),
              boxShadow: fxRich ? [BoxShadow(color: accent.withValues(alpha: .5), blurRadius: 28, spreadRadius: 2)] : null,
            ),
            child: CustomPaint(painter: _TickPainter(draw, store.onAccent)),
          ),
        );
      },
    );
  }
}

class _TickPainter extends CustomPainter {
  final double v;
  final Color color;
  _TickPainter(this.v, this.color);

  @override
  void paint(Canvas canvas, Size s) {
    final path = Path()
      ..moveTo(s.width * .28, s.height * .52)
      ..lineTo(s.width * .44, s.height * .67)
      ..lineTo(s.width * .73, s.height * .36);
    for (final m in path.computeMetrics()) {
      canvas.drawPath(
        m.extractPath(0, m.length * v),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(_TickPainter old) => old.v != v || old.color != color;
}

/// Konfetti-Explosion in Akzentfarben, fällt mit Schwerkraft.
class _Confetti extends StatefulWidget {
  const _Confetti();

  @override
  State<_Confetti> createState() => _ConfettiState();
}

class _ConfettiState extends State<_Confetti> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));

  @override
  void initState() {
    super.initState();
    if (!store.reduceMotion) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => store.reduceMotion
      ? const SizedBox()
      : RepaintBoundary(child: CustomPaint(painter: _ConfettiPainter(_c, Theme.of(context).colorScheme.primary)));
}

class _ConfettiPainter extends CustomPainter {
  final Animation<double> t;
  final Color accent;
  _ConfettiPainter(this.t, this.accent) : super(repaint: t);

  static final _bits = () {
    final r = math.Random(3);
    return [
      for (var i = 0; i < 110; i++)
        (
          angle: -math.pi / 2 + (r.nextDouble() - .5) * math.pi * 1.25,
          speed: .55 + r.nextDouble() * .75,
          spin: (r.nextDouble() - .5) * 18,
          size: 5 + r.nextDouble() * 7,
          kind: r.nextInt(4),
          delay: r.nextDouble() * .12,
        ),
    ];
  }();

  @override
  void paint(Canvas canvas, Size s) {
    if (t.value == 0 || t.isCompleted) return;
    final colors = [accent, Colors.white, Color.lerp(accent, Colors.white, .5)!, const Color(0xFFE5A23A), HSLColor.fromColor(accent).withHue((HSLColor.fromColor(accent).hue + 50) % 360).toColor()];
    final origin = Offset(s.width / 2, s.height * .3);
    final unit = math.max(s.width, s.height);
    final p = Paint();
    // Schwaches Gerät: ein Drittel der Teile
    for (final b in Perf.lite ? _bits.take(36) : _bits) {
      final tt = ((t.value - b.delay) / (1 - b.delay)).clamp(0.0, 1.0);
      if (tt <= 0) continue;
      final time = tt * 2.2;
      // Wurf mit Luftwiderstand, dann Schwerkraft
      final drag = (1 - math.exp(-time * 2.2)) / 2.2;
      final pos = origin +
          Offset(math.cos(b.angle), math.sin(b.angle)) * (b.speed * unit * .55 * drag) +
          Offset(0, .5 * .55 * unit * time * time * .32);
      p.color = colors[b.kind % colors.length].withValues(alpha: (1 - Curves.easeIn.transform(tt)).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(b.spin * time);
      // Flattern: Breite schwankt wie bei sich drehendem Papier
      final flutter = math.cos(time * b.spin).abs() * .8 + .2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: b.size * flutter, height: b.size * .55), const Radius.circular(1.5)),
        p,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.accent != accent;
}
