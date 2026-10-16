import 'dart:io';

import 'package:cinemamax/update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appVersion passt zu pubspec.yaml', () {
    final v = RegExp(r'^version:\s*([\d.]+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())![1];
    expect(appVersion, v);
  });

  test('Versionsvergleich', () {
    expect(isNewer('1.5.0', '1.4.0'), isTrue);
    expect(isNewer('1.10.0', '1.9.2'), isTrue);
    expect(isNewer('1.4.0', '1.4.0'), isFalse);
    expect(isNewer('1.3.9', '1.4.0'), isFalse);
    expect(isNewer('2', '1.9.9'), isTrue);
  });

  test('Passende Datei je Plattform, nur aus dem eigenen Repo', () {
    const base = 'https://github.com/Emre1001/CinemaMax/releases/download/v1.5.0';
    final urls = [
      '$base/CinemaMax-1.5.0.apk',
      '$base/CinemaMax-1.5.0-windows-setup.exe',
      '$base/CinemaMax-1.5.0-x86_64.AppImage',
      '$base/cinemamax_1.5.0_amd64.deb',
    ];
    expect(pickAsset(urls, android: true, windows: false, appImage: false), urls[0]);
    expect(pickAsset(urls, android: false, windows: true, appImage: false), urls[1]);
    expect(pickAsset(urls, android: false, windows: false, appImage: true), urls[2]);
    expect(pickAsset(urls, android: false, windows: false, appImage: false), isNull);
    expect(pickAsset(['https://evil.example/x.apk'], android: true, windows: false, appImage: false), isNull);
  });
}
