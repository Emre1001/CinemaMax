import 'package:cinemamax/device_check.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({'lang': 'de'});
    await store.init();
  });

  CheckItem find(List<CheckItem> items, String label) => items.firstWhere((i) => i.label == label);

  test('Android: Gerätedecoder, Durchreichen, FFmpeg und mpv als Rückfall', () {
    final r = {
      'codecs': {'video/avc': 'hw', 'video/hevc': 'sw', 'audio/mp4a-latm': 'hw'},
      'passthrough': ['audio/eac3'],
      'uhd': false,
      'hdr': [2, 3],
      'width': 1920,
      'height': 1080,
      'refresh': 60.0,
    };
    final i = DeviceCheck.android(r, exo: true, ffmpeg: true, autoMpv: true);
    expect(find(i.items, 'H.264 (AVC)').level, Level.ok);
    expect(find(i.items, 'H.265 (HEVC)').detail, 'Software');
    expect(find(i.items, 'Dolby Digital Plus (E-AC3)').detail, 'An Fernseher/Anlage durchgereicht');
    expect(find(i.items, 'DTS').detail, 'FFmpeg (Software)');
    expect(find(i.items, 'AV1').level, Level.alt); // kein Decoder: mpv springt ein
    expect(find(i.items, '4K').level, Level.alt);
    expect(find(i.items, 'HDR').detail, 'HDR10, HLG');
    expect(i.width, 1920);

    // Ohne Rückfälle geht AV1 nicht, Opus ohne FFmpeg-Unterstützung ebenso
    final strict = DeviceCheck.android(r, exo: true, ffmpeg: false, autoMpv: false);
    expect(find(strict.items, 'AV1').level, Level.fail);
    expect(find(strict.items, 'DTS').level, Level.fail);
  });

  test('PC: Decoder aus libmpv, fehlende libmpv', () {
    final ok = DeviceCheck.desktop({'h264', 'hevc', 'aac'}, hwdec: true);
    expect(find(ok, 'H.264 (AVC)').detail, 'Grafikkarte, sonst Software');
    expect(find(ok, 'AAC').detail, 'Software');
    expect(find(ok, 'AV1').level, Level.fail);
    expect(DeviceCheck.desktop(null, hwdec: true).every((i) => i.level == Level.fail), isTrue);
  });

  test('Wertung zählt Hinweise nicht mit', () {
    final items = <CheckItem>[
      (group: 'Bild', label: 'a', level: Level.ok, detail: ''),
      (group: 'Bild', label: 'b', level: Level.alt, detail: ''),
      (group: 'Bild', label: 'c', level: Level.fail, detail: ''),
      (group: 'Gerät', label: 'd', level: Level.info, detail: ''),
    ];
    expect(DeviceCheck.score(items), (2, 3));
  });
}
