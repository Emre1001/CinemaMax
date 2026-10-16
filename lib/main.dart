import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'downloads.dart';
import 'store.dart';
import 'ui/common.dart';
import 'ui/splash.dart';
import 'ui/start.dart';
import 'i18n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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
  await downloads.init();
  if (Platform.isAndroid) {
    try {
      isAndroidTv = await const MethodChannel('cinemamax/device').invokeMethod<bool>('isTv') ?? false;
    } catch (_) {}
  }
  runApp(const App());
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
    return _theme = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
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
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
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
      theme: theme,
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse, PointerDeviceKind.trackpad},
      ),
      // Startanimation nur beim ersten Aufbau, nicht bei Sprachwechsel
      home: store.get('intro', true) && !store.reduceMotion && !_introShown
          ? const SplashScreen()
          : const StartScreen(),
    );
    _introShown = true;
    return app;
  }
}
