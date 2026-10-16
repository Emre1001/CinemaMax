import 'dart:ui';

import 'store.dart';
import 'i18n_strings.dart';

const languages = {'system': 'System', 'de': 'Deutsch', 'en': 'English', 'tr': 'Türkçe'};

/// Aktive Sprache: Einstellung oder Systemsprache (de/tr, sonst Englisch).
String get lang {
  final l = store.get('lang', 'system');
  if (l != 'system') return l;
  final sys = PlatformDispatcher.instance.locale.languageCode;
  return const {'de', 'tr', 'en'}.contains(sys) ? sys : 'en';
}

/// Übersetzt einen deutschen Text. Platzhalter {0}, {1} … werden durch [args] ersetzt.
String tr(String de, [List<Object?> args = const []]) {
  var s = lang == 'de' ? de : (strings[lang]?[de] ?? de);
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}
