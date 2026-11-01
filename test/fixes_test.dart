import 'dart:convert';
import 'dart:io';

import 'package:cinemamax/models.dart';
import 'package:cinemamax/repo.dart';
import 'package:cinemamax/store.dart';
import 'package:cinemamax/ui/browse.dart';
import 'package:cinemamax/ui/common.dart';
import 'package:cinemamax/ui/fx.dart';
import 'package:cinemamax/ui/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = Directory.systemTemp.createTempSync('cmfix');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    SharedPreferences.setMockInitialValues({'defaultRate': 2});
    await store.init();
  });

  group('Server-Last', () {
    test('Folgen und Details einer Serie: eine Anfrage, auch doppelt geöffnet', () async {
      final s = Source(id: 'xc', name: 'X', type: SourceType.xtream, url: 'http://h.tv', user: 'u', pass: 'p');
      var calls = 0;
      await http.runWithClient(() async {
        final a = Repo.xtreamEpisodes(s, '5');
        final b = Repo.xtreamInfo(s, const MediaItem(id: '5', name: 'S', kind: Kind.series, group: 'g'));
        expect((await a).single.title, 'Pilot');
        expect((await b)['plot'], 'P');
        expect((await Repo.xtreamEpisodes(s, '5')).length, 1);
      }, () => MockClient((r) async {
            calls++;
            return http.Response(
                jsonEncode({
                  'info': {'plot': 'P'},
                  'episodes': {
                    '1': [
                      {'id': '9', 'season': 1, 'episode_num': 1, 'title': 'Pilot', 'container_extension': 'mkv'},
                    ],
                  },
                }),
                200);
          }));
      expect(calls, 1);
    });

    test('Fehler werden nicht zwischengespeichert', () async {
      final s = Source(id: 'xf', name: 'X', type: SourceType.xtream, url: 'http://h.tv', user: 'u', pass: 'p');
      var calls = 0;
      await http.runWithClient(() async {
        await expectLater(Repo.xtreamEpisodes(s, '1'), throwsA(anything));
        expect(await Repo.xtreamEpisodes(s, '1'), isEmpty);
      }, () => MockClient((r) async => ++calls == 1 ? http.Response('kaputt', 500) : http.Response('{}', 200)));
      expect(calls, 2);
    });

    test('Gleichzeitiges Laden einer Playlist: nur ein Download', () async {
      final s = Source(id: 'm3u-dup', name: 'M', type: SourceType.m3u, url: 'http://h.tv/list.m3u');
      var calls = 0;
      await http.runWithClient(() async {
        final libs = await Future.wait([Repo.load(s, force: true), Repo.load(s, force: true)]);
        expect(identical(libs[0], libs[1]), isTrue);
        expect(Repo.loaded(s), same(libs[0]));
      }, () => MockClient((r) async {
            calls++;
            return http.Response('#EXTM3U\n#EXTINF:-1 group-title="News",Sender\nhttp://h.tv/1.ts\n', 200);
          }));
      expect(calls, 1);
    });

    test('M3U-Serie aus Verlauf/Favoriten (ohne gespeicherte Folgen) findet ihre Folgen', () async {
      final s = Source(id: 'm3u-eps', name: 'M', type: SourceType.m3u, url: 'http://h.tv/series.m3u');
      await http.runWithClient(() async {
        final lib = await Repo.load(s, force: true);
        final show = lib.of(Kind.series).single;
        final slim = MediaItem.fromJson(show.toJson(episodes: false));
        expect(slim.episodes, isNull);
        expect((await Repo.episodes(s, slim)).map((e) => e.number), [1, 2]);
      }, () => MockClient((r) async => http.Response(
          '#EXTM3U\n'
          '#EXTINF:-1 group-title="Serien",Show S01E01\nhttp://h.tv/series/1.mkv\n'
          '#EXTINF:-1 group-title="Serien",Show S01E02\nhttp://h.tv/series/2.mkv\n',
          200)));
    });
  });

  group('Store', () {
    test('Falscher Typ aus alter Sicherung stürzt nicht ab', () {
      expect(store.get('defaultRate', 1.0), 2.0);
    });

    test('Unveränderter Wert und stille Merker bauen nichts neu auf', () {
      var n = 0;
      void l() => n++;
      store.addListener(l);
      store.set('clock', false);
      store.set('clock', false);
      store.set('lastGroup_x', 'a', notify: false);
      store.removeListener(l);
      expect(n, 1);
    });

    test('Verlauf speichert keine Folgenlisten', () {
      final s = Source(id: 'h', name: 'H', type: SourceType.m3u, url: '');
      const ep = Episode(id: 'e', season: 1, number: 1, title: 't', url: 'http://h/e.mkv');
      const show = MediaItem(id: 'sh', name: 'Show', kind: Kind.series, group: 'g', episodes: [ep]);
      store.saveProgress(s, show, ep.url, 't', const Duration(minutes: 5), const Duration(minutes: 40));
      expect((store.history[ep.url]!['item'] as Map).containsKey('eps'), isFalse);
    });
  });

  group('Fernbedienung', () {
    testWidgets('Lange Auswahlliste: gewählter Eintrag ganz unten bekommt den Fokus', (t) async {
      late BuildContext ctx;
      await t.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      final options = {for (var i = 0; i < 40; i++) 'k$i': 'Sprache $i'};
      pick(ctx, 'Sprache', options, current: 'k39');
      await t.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(find.descendant(of: find.byWidget(focused.widget), matching: find.text('Sprache 39')), findsOneWidget);
      // und sichtbar gescrollt
      final r = t.getRect(find.text('Sprache 39'));
      expect(r.bottom, lessThanOrEqualTo(t.view.physicalSize.height / t.view.devicePixelRatio));
    });

    testWidgets('Einstellungen am Fernseher: bleiben zweispaltig, Fokus landet in der Kategorie', (t) async {
      store.set('layout', 'tv');
      t.view.physicalSize = const Size(1920, 1080);
      t.view.devicePixelRatio = 2; // 960 × 540 wie ein 1080p-Fernseher
      addTearDown(t.view.reset);
      // Inhalt schmaler als 760 (Seitenleiste offen): früher Wechsel auf die Handy-Ansicht
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: Row(children: [SizedBox(width: 228), Expanded(child: SettingsBody(focusOnOpen: true))]))));
      await t.pumpAndSettle();
      expect(find.byType(VerticalDivider), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<SettingsBody>(), isNotNull);
      store.set('layout', 'auto');
    });

    testWidgets('TV-Seitenleiste klappt über dem Inhalt auf, statt ihn zu verschieben', (t) async {
      store.set('layout', 'tv');
      store.set('startTab', 'live');
      t.view.physicalSize = const Size(1920, 1080);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final s = Source(id: 'm3u-tv', name: 'IPTV · Großbritannien mit sehr langem Namen', type: SourceType.m3u, url: 'http://h.tv/tv.m3u');
      await t.runAsync(() => http.runWithClient(() => Repo.load(s, force: true),
          () => MockClient((r) async => http.Response('#EXTM3U\n#EXTINF:-1 group-title="News",Sender\nhttp://h.tv/1.ts\n', 200))));
      await t.pumpWidget(MaterialApp(home: BrowseScreen(source: s)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      // Fokus liegt in der Leiste (offen): Inhalt beginnt trotzdem bei der schmalen Leiste
      final open = t.getTopLeft(find.text('Live TV').last).dx;
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump(const Duration(milliseconds: 500));
      final closed = t.getTopLeft(find.text('Live TV').last).dx;
      expect(open, closed);
      expect(closed, lessThan(150));
      expect(t.takeException(), isNull); // langer Quellenname sprengt die Kopfzeile nicht
      store.set('layout', 'auto');
      store.set('startTab', 'mine');
    });

    testWidgets('Seitenwechsel nach Startbild/Einrichtung: alte und neue Seite nie übereinander', (t) async {
      store.set('perf', 'full');
      double opacityOf(String text) {
        var o = 1.0;
        t.element(find.text(text, skipOffstage: false)).visitAncestorElements((e) {
          final w = e.widget;
          if (w is FadeTransition) o *= w.opacity.value;
          return true;
        });
        return o;
      }

      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        theme: ThemeData(pageTransitionsTheme: const PageTransitionsTheme(builders: {
          TargetPlatform.android: FxPageTransitions(),
        })),
        home: const Text('Startbild'),
      ));
      // Wie Splash → Startbildschirm
      nav.currentState!.pushReplacement(fxFadeRoute(const Scaffold(body: Text('Start'))));
      await t.pumpAndSettle();
      // Startbildschirm → IPTV-/Serverliste
      nav.currentState!.push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Listen'))));
      for (final ms in [60, 120, 200, 300, 400]) {
        await t.pump(const Duration(milliseconds: 60));
        final a = opacityOf('Start'), b = opacityOf('Listen');
        expect(a == 0 || b == 0, isTrue, reason: 'nach ${ms}ms: Start $a, Listen $b');
      }
      await t.pumpAndSettle();
      // Zurück: ebenso
      nav.currentState!.pop();
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 60));
        final a = opacityOf('Start'), b = opacityOf('Listen');
        expect(a == 0 || b == 0, isTrue, reason: 'zurück ${i * 60}ms: Start $a, Listen $b');
      }
      await t.pumpAndSettle();
      store.set('perf', 'auto');
    });
  });
}
