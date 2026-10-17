import 'package:cinemamax/playback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('4K auch bei Kinoformat (3840×1600) erkannt', () {
    expect(Engine.resolution(3840, 2160), '4K');
    expect(Engine.resolution(3840, 1600), '4K');
    expect(Engine.resolution(1920, 800), '1080p');
    expect(Engine.resolution(1280, 720), '720p');
    expect(Engine.resolution(null, 480), '480p');
    expect(Engine.resolution(null, null), isNull);
    expect(Engine.qualityLabel(3840, 1608, 25000000), '4K · 25.0 Mbit/s');
  });
}
