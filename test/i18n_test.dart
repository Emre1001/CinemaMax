import 'package:cinemamax/i18n.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('Übersetzung mit Platzhaltern, Fallback auf Deutsch', () async {
    SharedPreferences.setMockInitialValues({'lang': 'tr'});
    await store.init();
    expect(tr('Staffel {0}', [2]), 'Sezon 2');
    expect(tr('Noch keine Favoriten.\nOK lange drücken zum Hinzufügen.'), startsWith('Henüz favori yok.\n'));
    store.set('lang', 'en');
    expect(tr('{0} Dateien · {1}', [3, '1 GB']), '3 files · 1 GB');
    expect(tr('Unbekannter Text'), 'Unbekannter Text');
    store.set('lang', 'de');
    expect(tr('Staffel {0}', [2]), 'Staffel 2');
  });
}
