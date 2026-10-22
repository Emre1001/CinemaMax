import 'package:cinemamax/playback.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Engine mit festen Qualitätsstufen (beste zuerst, wie qualities() sie liefert).
class _Fake extends Engine {
  final List<(String, int)> steps;
  final bool native;
  String? picked;
  _Fake(this.steps, {this.native = false});

  @override
  Future<List<Track>> qualities() async {
    for (final (id, h) in steps) {
      qualityHeight[id] = h;
    }
    return [for (final (id, h) in steps) (id: id, label: '${h}p')];
  }

  @override
  Future<void> selectQuality(String? id) async => picked = id;
  @override
  bool get nativeCap => native;

  @override
  Future<void> open(String url, Map<String, String> headers, {Duration? start}) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration d) async {}
  @override
  Future<void> setRate(double r) async {}
  @override
  double get rate => 1;
  @override
  Future<void> setVolume(double v) async {}
  @override
  Future<List<Track>> audioTracks() async => [];
  @override
  Future<void> selectAudio(String id) async {}
  @override
  Future<List<Track>> subtitleTracks() async => [];
  @override
  Future<void> selectSubtitle(String id) async {}
  @override
  Widget view(BoxFit fit) => const SizedBox();
  @override
  Future<void> dispose() async {}
}

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

  test('Bildschirmhöhe wie bei 16:9, 1920×1088 gilt als 1080p', () {
    expect(Engine.height16x9(2560, 1440), 1440);
    expect(Engine.height16x9(2400, 1080), 1350); // Handy
    expect(Engine.height16x9(3440, 1440), 1935); // Ultrawide
    expect(Engine.height16x9(3840, 1600), 2160); // Kinoformat-4K
    expect(Engine.fits(1088, 1080), isTrue);
    expect(Engine.fits(2160, 1440), isFalse);
    expect(Engine.fits(1080, 1350), isTrue);
    expect(Engine.fits(1440, 1350), isFalse);
  });

  test('4K-Stream auf 2K-Bildschirm: beste Stufe bis 1440p, sonst kleinste', () async {
    final e = _Fake([('a', 2160), ('b', 1440), ('c', 1080)]);
    expect(await e.capQuality(1440), '1440p');
    expect(e.picked, 'b');

    final low = _Fake([('a', 2160), ('b', 1080)]);
    expect(await low.capQuality(144), '1080p');
    expect(low.picked, 'b');
  });

  test('Passt die beste Stufe schon, bleibt die Automatik', () async {
    final e = _Fake([('a', 1080), ('b', 720)]);
    expect(await e.capQuality(2160), '');
    expect(e.picked, isNull);
    expect(await _Fake([]).capQuality(1080), isNull);
  });

  test('ExoPlayer begrenzt nativ: nur melden, keine feste Spur', () async {
    final e = _Fake([('a', 2160), ('b', 1080)], native: true);
    expect(await e.capQuality(1080), '1080p');
    expect(e.picked, isNull);
  });
}
