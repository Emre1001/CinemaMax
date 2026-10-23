import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n.dart';
import '../store.dart';

// ---------------- Farben ----------------
/// Helles Erscheinungsbild aktiv (Einstellung „Erscheinungsbild“, „system“ folgt dem Gerät). Von der App gesetzt.
bool isLight = false;

/// Hell oder dunkel nach Einstellung und Gerät.
bool resolveLight() {
  final t = store.get('theme', 'system');
  return t == 'light' || (t == 'system' && PlatformDispatcher.instance.platformBrightness == Brightness.light);
}

Color get bg => isLight ? const Color(0xFFF4F4F7) : kBg;
Color get surface => isLight ? const Color(0xFFFFFFFF) : kSurface;
Color get surface2 => isLight ? const Color(0xFFE9E9EF) : kSurface2;
Color get line => isLight ? const Color(0xFFD9D9E0) : kLine;
Color get textDim => isLight ? const Color(0xFF66666F) : kDim;

/// Schrift- und Symbolfarbe auf dem Hintergrund.
Color get fg => isLight ? const Color(0xFF111114) : Colors.white;

/// [fg] mit Deckkraft [a] (Rahmen, Flächen, gedimmte Schrift): ersetzt ink(.1) … white70.
Color ink(double a) => fg.withValues(alpha: a);

// Immer dunkel: Player über dem Video
const kBg = Color(0xFF0A0A0B);
const kSurface = Color(0xFF141416);
const kSurface2 = Color(0xFF1D1D21);
const kLine = Color(0xFF2A2A30);
const kDim = Color(0xFF8E8E96);

// ---------------- Gerätetyp ----------------
enum Ff { phone, tablet, tv, desktop }

/// Wird beim Start per Platform-Channel gesetzt (Android TV / Leanback).
bool isAndroidTv = false;

Ff formFactor(BuildContext c) {
  switch (store.layout) {
    case 'phone': return Ff.phone;
    case 'tv': return Ff.tv;
    case 'desktop': return Ff.desktop;
  }
  if (isAndroidTv) return Ff.tv;
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) return Ff.desktop;
  return MediaQuery.sizeOf(c).shortestSide < 600 ? Ff.phone : Ff.tablet;
}

bool isWide(BuildContext c) => formFactor(c) != Ff.phone;

// ---------------- Fokussierbares Element (Touch, Maus, D-Pad) ----------------
final _activate = {
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.gameButtonA,
};

/// Fokussierbare Fläche: skaliert und umrandet sich bei Fokus.
/// OK = [onTap], OK lange halten / Menü-Taste = [onLongPress].
class Tap extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onFocus;
  final bool autofocus;
  final FocusNode? focusNode;
  final double radius;
  final double scale;
  final bool fill; // Hintergrund bei Fokus aufhellen statt nur Rahmen

  const Tap({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onFocus,
    this.autofocus = false,
    this.focusNode,
    this.radius = 10,
    this.scale = 1.05,
    this.fill = false,
  });

  @override
  State<Tap> createState() => _TapState();
}

class _TapState extends State<Tap> {
  bool _focus = false, _hover = false, _longFired = false, _down = false, _autofocused = false;
  FocusNode? _own;
  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());

  // Autofokus nur auf der obersten Seite: Flutters eigener Autofokus holt sich den Fokus auch
  // hinter einem offenen Dialog (z. B. Update-Hinweis, während die Liste lädt) und die
  // Fernbedienung steuert dann etwas Unsichtbares. Sonst wartet er, bis der Dialog zu ist.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.autofocus || _autofocused || !(ModalRoute.isCurrentOf(context) ?? true)) return;
    _autofocused = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && FocusScope.of(context).focusedChild == null) _node.requestFocus();
    });
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_mode);
  }

  void _mode(FocusHighlightMode _) {
    if (_focus && mounted) setState(() {});
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_mode);
    _own?.dispose();
    super.dispose();
  }

  /// Fokus sichtbar machen: Fernseher immer, sonst nur nach Tastatur-/Pfeil-Eingabe (nicht nach Tippen).
  bool get _ring => _focus && (isAndroidTv || FocusManager.instance.highlightMode == FocusHighlightMode.traditional);

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.contextMenu && e is KeyDownEvent && widget.onLongPress != null) {
      widget.onLongPress!();
      return KeyEventResult.handled;
    }
    if (!_activate.contains(k)) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      _longFired = false;
      _down = true;
    } else if (e is KeyRepeatEvent) {
      if (!_longFired && widget.onLongPress != null) {
        _longFired = true;
        widget.onLongPress!();
      }
    } else if (e is KeyUpEvent) {
      // Nur auslösen, wenn der Tastendruck hier begann (nicht nach Fokuswechsel/Seitenwechsel)
      if (_down && !_longFired) widget.onTap?.call();
      _down = false;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final r = BorderRadius.circular(widget.radius);
    return Focus(
      focusNode: _node,
      onKeyEvent: _key,
      onFocusChange: (v) {
        setState(() => _focus = v);
        if (!v) _down = false;
        widget.onFocus?.call(v);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: AnimatedScale(
            scale: _ring ? widget.scale : (_hover ? 1 + (widget.scale - 1) / 2 : 1),
            duration: store.anim,
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: store.anim,
              decoration: BoxDecoration(
                borderRadius: r,
                color: widget.fill && (_ring || _hover) ? ink(_ring ? .12 : .06) : null,
                boxShadow: _ring && !widget.fill
                    ? [BoxShadow(color: Colors.black.withValues(alpha: isLight ? .18 : .6), blurRadius: 24, offset: const Offset(0, 10))]
                    : null,
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: r,
                border: Border.all(
                  color: _ring ? (widget.fill ? accent : fg) : Colors.transparent,
                  width: 2,
                ),
              ),
              child: ClipRRect(borderRadius: r, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- Bild mit Platzhalter ----------------
class Artwork extends StatelessWidget {
  final String? url;
  final String label;
  final BoxFit fit;
  final double width;

  const Artwork(this.url, this.label, {super.key, this.fit = BoxFit.cover, this.width = 200});

  @override
  Widget build(BuildContext context) {
    // Ohne Bild: ruhiges Symbol statt Buchstaben-Kürzel (Name steht ohnehin unter der Kachel)
    final placeholder = Container(
      color: surface2,
      alignment: Alignment.center,
      child: Icon(fit == BoxFit.contain ? Icons.tv_rounded : Icons.movie_outlined,
          color: ink(.24), size: fit == BoxFit.contain ? 30 : 38),
    );
    if (url == null || !store.get('showLogos', true)) return placeholder;
    final img = Image.network(
      url!,
      fit: fit,
      // Manche Logo-Server liefern nur an bekannte Player aus
      headers: {'User-Agent': store.userAgent},
      // Bild auf Anzeigegröße dekodieren: spart RAM, scrollt flüssig auf TV-Boxen
      cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => placeholder,
      frameBuilder: (_, child, frame, sync) => sync || store.reduceMotion
          ? child
          : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 220), child: child),
    );
    // Dunkle Senderlogos sind auf dunklem Grund unsichtbar: optional heller Hintergrund
    if (fit == BoxFit.contain && store.get('logoBg', 'dark') == 'light') {
      return DecoratedBox(
        decoration: BoxDecoration(color: const Color(0xFFE9E9EC), borderRadius: BorderRadius.circular(6)),
        child: Padding(padding: const EdgeInsets.all(6), child: img),
      );
    }
    return img;
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
        child: Row(children: [
          Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -.2)),
          const Spacer(),
          ?trailing,
        ]),
      );
}

/// Kleine Pille-Schaltfläche, z. B. für Kategorien und Aktionen.
class Pill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onTap;
  final bool autofocus;
  final bool primary;
  final FocusNode? focusNode;

  const Pill(this.label,
      {super.key,
      this.icon,
      this.selected = false,
      this.onTap,
      this.autofocus = false,
      this.primary = false,
      this.focusNode});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final on = selected || primary;
    return Tap(
      onTap: onTap,
      autofocus: autofocus,
      focusNode: focusNode,
      radius: 100,
      scale: 1.06,
      child: AnimatedContainer(
        duration: store.anim,
        padding: EdgeInsets.symmetric(horizontal: primary ? 22 : 14, vertical: primary ? 12 : 8),
        color: on ? (primary ? accent : fg) : surface2,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: on ? (primary ? store.onAccent : bg) : fg),
            const SizedBox(width: 6),
          ],
          Text(label,
              style: TextStyle(
                  color: on ? (primary ? store.onAccent : bg) : fg,
                  fontWeight: FontWeight.w600,
                  fontSize: primary ? 15 : 13)),
        ]),
      ),
    );
  }
}

void toast(BuildContext c, String msg) => ScaffoldMessenger.of(c)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating, width: 420));

/// Auswahlliste als Dialog, D-Pad-tauglich. Gibt gewählten Wert zurück.
Future<T?> pick<T>(BuildContext c, String title, Map<T, String> options, {T? current, Widget Function(T)? leading}) =>
    showDialog<T>(
      context: c,
      builder: (c) => Dialog(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                children: [
                  for (final (i, e) in options.entries.indexed)
                    Tap(
                      fill: true,
                      scale: 1,
                      autofocus: current == null ? i == 0 : e.key == current,
                      onTap: () => Navigator.pop(c, e.key),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                        child: Row(children: [
                          if (leading != null) ...[leading(e.key), const SizedBox(width: 14)],
                          Expanded(child: Text(e.value, style: const TextStyle(fontSize: 15))),
                          if (e.key == current) Icon(Icons.check, size: 20, color: Theme.of(c).colorScheme.primary),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );

/// Textfelder geben Pfeil hoch/runter an die Fokus-Navigation weiter (sonst bleibt die Fernbedienung im Feld hängen).
Widget dpadField(Widget field) => Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
      },
      child: field,
    );

/// Textfeld für alle Geräte. Auf TV ein fokussierbares Feld, das mit OK einen Eingabedialog öffnet:
/// eine dauerhaft offene Tastatur-Verbindung würde sonst die Pfeiltasten der Fernbedienung schlucken.
class InputBox extends StatelessWidget {
  final TextEditingController controller;
  final InputDecoration decoration;
  final bool secret, autofocus;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged, onSubmitted;
  final FocusNode? focusNode;
  final TextStyle? style;

  const InputBox({
    super.key,
    required this.controller,
    this.decoration = const InputDecoration(),
    this.secret = false,
    this.autofocus = false,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.style,
  });

  Future<void> _edit(BuildContext context) async {
    final c = TextEditingController(text: controller.text);
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(decoration.labelText ?? decoration.hintText ?? ''),
        content: SizedBox(
          width: 520,
          child: dpadField(TextField(
            controller: c,
            autofocus: true,
            obscureText: secret,
            keyboardType: keyboardType,
            autocorrect: false,
            onSubmitted: (v) => Navigator.pop(d, v),
          )),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: Text(tr('OK'))),
        ],
      ),
    );
    c.dispose();
    if (v == null) return;
    controller.text = v;
    onChanged?.call(v);
    onSubmitted?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    if (formFactor(context) != Ff.tv) {
      return dpadField(TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        obscureText: secret,
        keyboardType: keyboardType,
        autocorrect: false,
        style: style,
        textInputAction: onSubmitted != null ? TextInputAction.search : TextInputAction.next,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        decoration: decoration,
      ));
    }
    return Tap(
      focusNode: focusNode,
      autofocus: autofocus,
      scale: 1.01,
      radius: 10,
      onTap: () => _edit(context),
      child: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => InputDecorator(
          // Unterstrich statt Rahmen: die schwebende Beschriftung bleibt im Feld, statt auf dem
          // (vom Fokus-Rahmen abgeschnittenen) Rand zu sitzen
          decoration: decoration.copyWith(
            suffixIcon: const Icon(Icons.keyboard_rounded),
            border: const UnderlineInputBorder(borderSide: BorderSide.none),
            enabledBorder: const UnderlineInputBorder(borderSide: BorderSide.none),
            focusedBorder: const UnderlineInputBorder(borderSide: BorderSide.none),
          ),
          isEmpty: controller.text.isEmpty,
          child: Text(secret ? '•' * controller.text.length : controller.text, style: style),
        ),
      ),
    );
  }
}

String hexColor(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Wunschfarbe: Farbton, Sättigung, Helligkeit (Schieberegler, mit Pfeiltasten bedienbar) oder Hex-Code.
class ColorPickerDialog extends StatefulWidget {
  final Color initial;
  const ColorPickerDialog({super.key, required this.initial});

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final _hex = TextEditingController(text: hexColor(widget.initial));

  void _set(HSVColor h) => setState(() {
        _hsv = h;
        _hex.text = hexColor(h.toColor());
      });

  Widget _slider(String label, double value, double max, ValueChanged<double> onChanged, List<Color> track) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: textDim, fontSize: 13)),
          const SizedBox(height: 6),
          Container(
            height: 10,
            margin: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), gradient: LinearGradient(colors: track)),
          ),
          Slider(value: value, max: max, onChanged: onChanged, activeColor: Colors.white, inactiveColor: Colors.transparent),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final c = _hsv.toColor();
    return AlertDialog(
      title: Text(tr('Eigene Farbe')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(width: 56, height: 56, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(14))),
              const SizedBox(width: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(100)),
                child: Text(tr('Vorschau'),
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: ThemeData.estimateBrightnessForColor(c) == Brightness.dark ? Colors.white : Colors.black)),
              ),
            ]),
            _slider(tr('Farbton'), _hsv.hue, 360, (v) => _set(_hsv.withHue(v)),
                [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor()]),
            _slider(tr('Sättigung'), _hsv.saturation, 1, (v) => _set(_hsv.withSaturation(v)),
                [_hsv.withSaturation(0).toColor(), _hsv.withSaturation(1).toColor()]),
            // Mindesthelligkeit, damit Texte und Fokus sichtbar bleiben
            _slider(tr('Helligkeit'), _hsv.value, 1, (v) => _set(_hsv.withValue(v.clamp(.35, 1))),
                [_hsv.withValue(.35).toColor(), _hsv.withValue(1).toColor()]),
            const SizedBox(height: 8),
            InputBox(
              controller: _hex,
              decoration: const InputDecoration(labelText: 'Hex (#3E8BFF)'),
              onChanged: (v) {
                final n = int.tryParse(v.replaceAll('#', '').trim(), radix: 16);
                if (n != null && v.replaceAll('#', '').trim().length == 6) {
                  setState(() => _hsv = HSVColor.fromColor(Color(0xFF000000 | n)));
                }
              },
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Abbrechen'))),
        FilledButton(onPressed: () => Navigator.pop(context, c), child: Text(tr('Übernehmen'))),
      ],
    );
  }
}
