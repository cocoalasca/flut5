import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// Covers the per-frame bookkeeping smoothTrailFade and the debug HUD rely
/// on: how far the displayed snapshot has fallen behind the fade it should be
/// showing, and the smoothed frame rate the raster-load readout is measured
/// against.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A 1×1 image, enough to stand in for a captured snapshot.
  Future<ui.Image> pixel() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder, const Rect.fromLTWH(0, 0, 1, 1)).drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()..color = const Color(0xFF00FF00),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(1, 1);
    picture.dispose();
    return image;
  }

  /// Advances the engine one frame at [ms] since the previous one.
  void tick(Flut5Engine e, int atMs) {
    e.environment = e.environment.nextFrame(atMs);
    e.noteFramePainted();
  }

  group('framesSinceSnapshotApplied', () {
    test('starts at zero and ages one per painted frame', () {
      final e = Flut5Engine();
      expect(e.framesSinceSnapshotApplied, 0);
      tick(e, 16);
      expect(e.framesSinceSnapshotApplied, 1);
      tick(e, 32);
      tick(e, 48);
      expect(e.framesSinceSnapshotApplied, 3);
    });

    test('resets when a fresh snapshot is applied', () async {
      final e = Flut5Engine();
      tick(e, 16);
      tick(e, 32);
      expect(e.framesSinceSnapshotApplied, 2);

      e.setFrameSnapshot(await pixel(), const Size(1, 1));
      // A snapshot that just landed already contains every fade up to its own
      // capture, so the synthetic fade on top must start from nothing.
      expect(e.framesSinceSnapshotApplied, 0);
    });

    test('resets when the snapshot is dropped', () async {
      final e = Flut5Engine();
      e.setFrameSnapshot(await pixel(), const Size(1, 1));
      tick(e, 16);
      tick(e, 32);
      expect(e.framesSinceSnapshotApplied, 2);

      e.clearFrameSnapshot();
      expect(e.framesSinceSnapshotApplied, 0);
    });
  });

  group('smoothedFrameRate', () {
    test('null until a frame has been timed', () {
      final e = Flut5Engine();
      expect(e.smoothedFrameRate, isNull);
      // The first nextFrame has no predecessor, so deltaTime is still 0.
      tick(e, 16);
      expect(e.smoothedFrameRate, isNull);
    });

    test('converges on the true rate', () {
      final e = Flut5Engine();
      // ~16.67 ms per frame == 60 fps.
      for (var i = 0; i < 400; i++) {
        tick(e, (i * 50) ~/ 3);
      }
      expect(e.smoothedFrameRate, isNotNull);
      expect(e.smoothedFrameRate!, closeTo(60, 1.5));
    });

    test('tracks a slower rate', () {
      final e = Flut5Engine();
      // 50 ms per frame == 20 fps.
      for (var i = 0; i < 400; i++) {
        tick(e, i * 50);
      }
      expect(e.smoothedFrameRate!, closeTo(20, 0.5));
    });

    test('stays near the true rate when frame times alternate', () {
      // The snapshot-sketch shape: a slow capture frame followed by a fast
      // one. Mean frame time is 16.5 ms — 60.6 fps — but averaging the two
      // instantaneous rates (1000/25 = 40 and 1000/8 = 125) reports 82.5.
      //
      // A single-pole EMA over an alternating sequence settles into a
      // two-phase cycle rather than a point, here 16.05–16.95 ms, so the
      // reading swings a couple of fps either side of the mean. That residual
      // is bounded and symmetric; the rate-average error was neither.
      final e = Flut5Engine();
      var now = 0;
      for (var i = 0; i < 800; i++) {
        now += i.isEven ? 25 : 8;
        tick(e, now);
      }
      expect(e.smoothedFrameRate!, closeTo(60.6, 2.5));
      expect(e.smoothedFrameTimeMs!, closeTo(16.5, 0.6));
      // The point of the change: nowhere near what averaging rates gave.
      expect(e.smoothedFrameRate!, lessThan(70));
    });

    test('a 60 fps sketch does not report above its cap', () {
      // 60 fps under integer-millisecond timestamps can't be represented
      // exactly; 17/17/16 averages 16.667 ms, which is exactly 60 fps.
      final e = Flut5Engine();
      var now = 0;
      for (var i = 0; i < 800; i++) {
        now += i % 3 == 2 ? 16 : 17;
        tick(e, now);
      }
      expect(e.smoothedFrameRate!, lessThanOrEqualTo(61.0));
      expect(e.smoothedFrameRate!, closeTo(60, 1.0));
    });
  });

  group('frameSnapshotRasterLoad', () {
    test('null before any capture has completed', () {
      expect(Flut5Engine().frameSnapshotRasterLoad, isNull);
    });
  });
}
