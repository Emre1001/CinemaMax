import 'dart:ui';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'downloads.dart';
import 'errors.dart';
import 'links.dart';
import 'perf.dart';
import 'playback.dart';
import 'store.dart';
import 'ui/common.dart';
import 'ui/fx.dart';
import 'ui/setup.dart';
import 'ui/splash.dart';
import 'i18n.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Fehler melden statt abstürzen: kurze deutsche Meldung, Details nur im Protokoll
  FlutterError.onError = (d) {
    FlutterError.presentError(d);
    reportError(d.exception, d.stack);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    reportError(e, st);
    return true;
  };
  ErrorWidget.builder = friendlyErrorWidget;
  // Ohne libmpv (Linux: Paket fehlt) trotzdem starten und erklären, statt still nichts anzuzeigen
  Object? mpvMissing;
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    mpvMissing = e;
  }
  if (Platform.isAndroid) {
    // Alte Android-Versionen kennen ISRG Root X1 (Let's Encrypt) nicht: für Playlists/EPG nachrüsten
    try {
      final pem = await rootBundle.load('assets/certs/isrgrootx1.pem');
      SecurityContext.defaultContext.setTrustedCertificatesBytes(pem.buffer.asUint8List());
    } catch (_) {
      /* schon bekannt */
    }
  }
  await store.init();
  await Perf.init();
  await downloads.init();
  await Links.init(args);
  if (Platform.isAndroid) {
    try {
      isAndroidTv = await const MethodChannel('cinemamax/device').invokeMethod<bool>('isTv') ?? false;
    } catch (_) {}
    await Engine.detectScreen();
  }
  runApp(const App());
  if (mpvMissing != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => reportError(
        StateError(tr('Videowiedergabe nicht möglich: libmpv fehlt. Installieren mit: sudo apt install libmpv2')),
        StackTrace.current));
  }
}

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  ThemeData? _theme;
  Color? _accent;
  String _lang = lang;
  static bool _introShown = false;

  @override
  void initState() {
    super.initState();
    // Nur bei Akzentfarben-Wechsel neu bauen, nicht bei jeder Store-Änderung
    store.addListener(() {
      if (store.accent != _accent || lang != _lang) setState(() => _lang = lang);
    });
  }

  ThemeData get theme {
    if (_accent == store.accent && _theme != null) return _theme!;
    _accent = store.accent;
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent!,
      brightness: Brightness.dark,
    ).copyWith(primary: _accent, onPrimary: store.onAccent, surface: bg, onSurface: Colors.white);
    // Fernbedienung: gewählter Knopf in Dialogen klar sichtbar (Hervorhebung ist sonst abgeschaltet)
    final ring = ButtonStyle(
      side: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused) ? const BorderSide(color: Colors.white, width: 2.5) : null),
    );
    return _theme = ThemeData(
      useMaterial3: true,
      focusColor: Colors.white24,
      textButtonTheme: TextButtonThemeData(style: ring),
      filledButtonTheme: FilledButtonThemeData(style: ring),
      outlinedButtonTheme: OutlinedButtonThemeData(style: ring),
      iconButtonTheme: IconButtonThemeData(style: ring),
      colorScheme: scheme,
      // Seiten durchsichtig: darunter liegt der gemeinsame Hintergrund (MaterialApp.builder)
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      dialogTheme: const DialogThemeData(backgroundColor: surface),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surface2,
        contentTextStyle: TextStyle(color: Colors.white),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: _accent!, width: 2),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FxPageTransitions(),
          TargetPlatform.linux: FxPageTransitions(),
          TargetPlatform.windows: FxPageTransitions(),
        },
      ),
    );
  }

  @override
  // Sprachwechsel baut die App neu auf (Key), damit alle Texte neu übersetzt werden
  Widget build(BuildContext context) {
    final app = MaterialApp(
      key: ValueKey(_lang),
      title: 'CinemaMax',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: theme,
      // Ruhender Farbwolken-Hintergrund unter allen Seiten (Speed-Modus: schlicht)
      builder: (_, child) => Stack(children: [const Positioned.fill(child: Backdrop(moving: false)), ?child]),
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse, PointerDeviceKind.trackpad},
      ),
      // Startanimation nur beim ersten Aufbau, nicht bei Sprachwechsel
      home: store.get('intro', true) && !store.reduceMotion && !_introShown
          ? const SplashScreen()
          : firstScreen(),
    );
    _introShown = true;
    return app;
  }
}
