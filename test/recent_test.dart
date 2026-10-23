import 'package:cinemamax/models.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Weiterschauen: Serie nur einmal, mit der zuletzt gesehenen Folge', () async {
    SharedPreferences.setMockInitialValues({});
    await store.init();
    final s = Source(id: 'a', name: 'A', type: SourceType.values.first, url: 'http://x');
    const show = MediaItem(id: 's1', name: 'Show', kind: Kind.series, group: 'g');
    const film = MediaItem(id: 'f1', name: 'Film', kind: Kind.movie, group: 'g');
    const min = Duration(minutes: 1);
    store.saveProgress(s, show, 'http://x/e1', 'Folge 1', min, min * 40);
    await Future.delayed(const Duration(milliseconds: 5));
    store.saveProgress(s, film, 'http://x/f1', 'Film', min, min * 90);
    await Future.delayed(const Duration(milliseconds: 5));
    store.saveProgress(s, show, 'http://x/e2', 'Folge 2', min, min * 40);

    expect([for (final e in store.recent(s)) e.value['title']], ['Folge 2', 'Film']);
    // Fortschritt je Folge bleibt erhalten
    expect(store.history.containsKey('http://x/e1'), isTrue);
  });
}
