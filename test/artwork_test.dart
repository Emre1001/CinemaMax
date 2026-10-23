import 'package:cinemamax/store.dart';
import 'package:cinemamax/ui/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Bild-Fehler: zweimal neu versuchen, dann Platzhalter', (t) async {
    SharedPreferences.setMockInitialValues({});
    await store.init();
    final log = <String>[];
    final old = debugPrint;
    debugPrint = (m, {wrapWidth}) => log.add(m ?? '');

    // Im Test antwortet jede Bild-Anfrage mit HTTP 400
    await t.pumpWidget(const MaterialApp(home: Artwork('https://example.com/logo.png', 'Logo')));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await t.pump(const Duration(seconds: 5));
    }
    debugPrint = old;
    expect(log.where((m) => m.startsWith('Bild nicht geladen')).length, 2);
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
  });
}
