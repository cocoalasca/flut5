import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// Covers the startup resolution search: the factor is a guaranteed floor,
/// the engine climbs toward [Flut5Engine.frameSnapshotResolutionFactorMax]
/// while measured captures stay inside budget, and it locks once it stops
/// finding headroom — deliberately not continuing to adapt afterwards, since
/// every resolution change resamples the accumulated trail.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Runs [captures] snapshot captures on a simulated device where a
  /// full-resolution capture costs [msAtFullRes].
  ///
  /// Cost is scaled by the square of the rung currently being tried, because
  /// capture time tracks pixel count and pixels go as the square of the
  /// factor. Feeding a constant instead would let the search climb forever —
  /// the projection it makes before each step is precisely that cost grows
  /// with area, so a device whose cost didn't grow would always look
  /// affordable.
  ///
  /// `completeFrameSnapshotCapture` times the real interval between begin and
  /// complete, so cost is injected through the calibration entry point
  /// directly rather than by trying to make wall-clock cooperate.
  void feed(Flut5Engine e, double msAtFullRes, int captures) {
    for (var i = 0; i < captures; i++) {
      final f = e.frameSnapshotCalibratedFactor;
      e.debugFeedCalibrationSample(msAtFullRes * f * f);
    }
  }

  Flut5Engine ranged(double floor, double ceiling) => Flut5Engine()
    ..frameSnapshotResolutionFactor = floor
    ..frameSnapshotResolutionFactorMax = ceiling;

  group('defaults', () {
    test('the mode floor under a 1.0 ceiling means calibration runs by default',
        () {
      final e = Flut5Engine();
      // `flutter test` is a native debug build, so the debug default for
      // non-JS-web targets applies (0.8; JavaScript web would be 0.7).
      expect(e.frameSnapshotResolutionFactor, 0.8);
      expect(e.frameSnapshotResolutionFactorMax, 1.0);
      // Every sketch starts conservative for its build mode and climbs.
      expect(e.frameSnapshotCalibrating, isTrue);
      expect(e.frameSnapshotCalibratedFactor, 0.8);
    });

    test('a capable device reaches full resolution from the defaults', () {
      final e = Flut5Engine();
      feed(e, 0.05, 48);
      expect(e.frameSnapshotCalibratedFactor, 1.0);
      expect(e.frameSnapshotCalibrating, isFalse);
    });

    test('a slow device stays at the mode floor', () {
      final e = Flut5Engine();
      feed(e, 500.0, 48);
      expect(e.frameSnapshotCalibratedFactor, 0.8);
    });

    test('setting both to 1.0 opts out of calibration entirely', () {
      final e = ranged(1.0, 1.0);
      expect(e.frameSnapshotCalibrating, isFalse);
      expect(e.frameSnapshotCalibratedFactor, 1.0);
      feed(e, 500.0, 48);
      expect(e.frameSnapshotCalibratedFactor, 1.0);
    });

    test('a factor with no headroom above it is used verbatim', () {
      final e = ranged(0.5, 0.5);
      expect(e.frameSnapshotCalibrating, isFalse);
      expect(e.frameSnapshotCalibratedFactor, 0.5);
      // Even a flood of cheap captures cannot raise it past the ceiling.
      feed(e, 0.1, 100);
      expect(e.frameSnapshotCalibratedFactor, 0.5);
    });
  });

  group('climbing', () {
    test('starts at the floor, never below it', () {
      final e = ranged(0.5, 1.0);
      expect(e.frameSnapshotCalibratedFactor, 0.5);
      expect(e.frameSnapshotCalibrating, isTrue);
      // Ruinously expensive captures must not push below the guarantee.
      feed(e, 5000, 40);
      expect(e.frameSnapshotCalibratedFactor, 0.5);
    });

    test('reaches the ceiling when captures are cheap', () {
      final e = ranged(0.5, 1.0);
      feed(e, 0.05, 48);
      expect(e.frameSnapshotCalibratedFactor, 1.0);
      expect(e.frameSnapshotCalibrating, isFalse);
    });

    test('settles between floor and ceiling on a marginal device', () {
      // Ladder is [0.5, 0.625, 0.75, 0.875, 1.0]; budget 12 ms judged against
      // the amortized per-frame share, so at interval 2 a rung is left behind
      // only while measured/2 stays under 12 × 0.8 = 9.6.
      // On a device where full resolution would cost 40 ms:
      //   0.5   → 10.00 ms,  5.00 per frame → climb
      //   0.625 → 15.63 ms,  7.81 per frame → climb
      //   0.75  → 22.50 ms, 11.25 per frame → under 12, past 9.6 → stop here
      final e = ranged(0.5, 1.0);
      feed(e, 40.0, 48);
      expect(e.frameSnapshotCalibratedFactor, 0.75);
      expect(e.frameSnapshotCalibrating, isFalse);
    });

    test('a device costing one budget at full res keeps full res', () {
      // 8 ms per capture at interval 2 is 4 ms per frame — 24% raster load.
      // Plainly affordable, so there is no reason to give up resolution.
      final e = ranged(0.5, 1.0);
      feed(e, 8.0, 48);
      expect(e.frameSnapshotCalibratedFactor, 1.0);
    });

    test('locks and stays locked — no continuous re-adaptation', () {
      final e = ranged(0.5, 1.0);
      feed(e, 0.05, 48);
      expect(e.frameSnapshotCalibratedFactor, 1.0);
      // Cost collapsing or exploding afterwards must not move it: resolution
      // changes resample the trail, and by now the trail has content.
      feed(e, 500.0, 200);
      expect(e.frameSnapshotCalibratedFactor, 1.0);
      feed(e, 0.001, 200);
      expect(e.frameSnapshotCalibratedFactor, 1.0);
    });

    test('respects a raised budget', () {
      final e = ranged(0.5, 1.0)..frameSnapshotBudgetMs = 100;
      feed(e, 4.0, 48);
      // With a 100 ms budget a 4 ms capture has room to climb all the way.
      expect(e.frameSnapshotCalibratedFactor, 1.0);
    });
  });

  group('why the search stopped', () {
    test('reaching the ceiling reports it', () {
      final e = ranged(0.5, 1.0);
      feed(e, 0.05, 48);
      expect(e.frameSnapshotCalibratedFactor, 1.0);
      expect(e.frameSnapshotCalibrationOutcome, 'ceiling');
    });

    test('stopping mid-ladder reports no headroom', () {
      final e = ranged(0.5, 1.0);
      feed(e, 40.0, 48);
      expect(e.frameSnapshotCalibratedFactor, 0.75);
      expect(e.frameSnapshotCalibrationOutcome, 'no headroom');
    });

    test('a longer interval buys resolution, since capture amortizes further',
        () {
      // Same device, same budget: at interval 2 the per-frame share of a
      // capture is half its cost, at interval 4 a quarter. The search should
      // find the longer interval affords more resolution — the trade the
      // amortized comparison exists to expose.
      final slow = ranged(0.5, 1.0)..frameSnapshotInterval = 2;
      feed(slow, 40.0, 48);
      final fast = ranged(0.5, 1.0)..frameSnapshotInterval = 4;
      feed(fast, 40.0, 48);
      expect(
        fast.frameSnapshotCalibratedFactor,
        greaterThan(slow.frameSnapshotCalibratedFactor),
      );
    });

    test('a fixed per-call cost no longer pins the search to the floor', () {
      // The web shape: 5.5 ms of resolution-independent overhead plus a small
      // area-scaled part. Predicting the next rung by area ratio said 8.9 ms
      // against a 6.4 ms threshold and never left the floor; measuring each
      // rung instead finds the device can carry far more resolution for
      // almost no extra cost.
      final e = ranged(0.2, 1.0);
      for (var i = 0; i < 48; i++) {
        final f = e.frameSnapshotCalibratedFactor;
        e.debugFeedCalibrationSample(5.5 + 7.5 * f * f);
      }
      expect(e.frameSnapshotCalibratedFactor, greaterThan(0.2));
    });

    test('a floor that is itself over budget reports over budget', () {
      // Cost dominated by a resolution-independent term — CanvasKit toImage
      // overhead is the real-world case. No factor in range can fit, and the
      // outcome must say so rather than look like a normal stop at the floor.
      final e = ranged(0.2, 1.0);
      for (var i = 0; i < 48; i++) {
        final f = e.frameSnapshotCalibratedFactor;
        e.debugFeedCalibrationSample(30.0 + 11.0 * f * f);
      }
      expect(e.frameSnapshotCalibratedFactor, 0.2);
      expect(e.frameSnapshotCalibrationOutcome, 'over budget');
    });

    test('the same device climbs once the budget admits it', () {
      // Identical cost curve, budget raised past the fixed overhead: the
      // search now has something to work with, proving the floor result above
      // was the budget talking and not a stuck ladder.
      final e = ranged(0.2, 1.0)..frameSnapshotBudgetMs = 60;
      for (var i = 0; i < 48; i++) {
        final f = e.frameSnapshotCalibratedFactor;
        e.debugFeedCalibrationSample(30.0 + 11.0 * f * f);
      }
      expect(e.frameSnapshotCalibratedFactor, 1.0);
      expect(e.frameSnapshotCalibrationOutcome, 'ceiling');
    });

    test('null while still searching, and again after a reset', () {
      final e = ranged(0.5, 1.0);
      expect(e.frameSnapshotCalibrationOutcome, isNull);
      feed(e, 0.05, 48);
      expect(e.frameSnapshotCalibrationOutcome, isNotNull);
      e.resetSnapshotCalibration();
      expect(e.frameSnapshotCalibrationOutcome, isNull);
    });
  });

  group('reset', () {
    test('resetSnapshotCalibration restarts the search from the floor', () {
      final e = ranged(0.5, 1.0);
      feed(e, 0.05, 48);
      expect(e.frameSnapshotCalibratedFactor, 1.0);
      e.resetSnapshotCalibration();
      expect(e.frameSnapshotCalibratedFactor, 0.5);
      expect(e.frameSnapshotCalibrating, isTrue);
    });

    test('changing the floor restarts the search', () {
      final e = ranged(0.5, 1.0);
      feed(e, 0.05, 48);
      expect(e.frameSnapshotCalibrating, isFalse);
      e.frameSnapshotResolutionFactor = 0.25;
      expect(e.frameSnapshotCalibrating, isTrue);
      expect(e.frameSnapshotCalibratedFactor, 0.25);
    });

    test('changing the ceiling restarts the search', () {
      final e = ranged(0.5, 0.75);
      feed(e, 0.05, 48);
      expect(e.frameSnapshotCalibrating, isFalse);
      e.frameSnapshotResolutionFactorMax = 1.0;
      expect(e.frameSnapshotCalibrating, isTrue);
    });

    test('changing a resolution cap restarts the search', () {
      final e = ranged(0.5, 1.0);
      feed(e, 0.05, 48);
      expect(e.frameSnapshotCalibrating, isFalse);
      e.frameSnapshotMaxPixels = 2000000;
      expect(e.frameSnapshotCalibrating, isTrue);
    });
  });

  group('ceiling below floor', () {
    test('is ignored rather than rejected, so order does not matter', () {
      final e = Flut5Engine()
        ..frameSnapshotResolutionFactorMax = 0.5
        ..frameSnapshotResolutionFactor = 0.8;
      // The ceiling can never sit below the guaranteed floor.
      expect(e.frameSnapshotCalibratedFactor, 0.8);
      expect(e.frameSnapshotCalibrating, isFalse);
    });

    test('rejects percentages on both knobs', () {
      final e = Flut5Engine();
      expect(() => e.frameSnapshotResolutionFactorMax = 100,
          throwsArgumentError);
      expect(() => e.frameSnapshotResolutionFactorMax = 0, throwsArgumentError);
    });
  });

  group('effective factor reflects calibration', () {
    test('reported factor follows the calibrated value, not the floor', () {
      final e = ranged(0.5, 1.0);
      e.environment = e.environment.withSize(const Size(400, 300));
      e.devicePixelRatio = 2.0;
      expect(e.effectiveFrameSnapshotResolutionFactor, 0.5);
      feed(e, 0.05, 48);
      expect(e.effectiveFrameSnapshotResolutionFactor, 1.0);
    });
  });

  group('showSnapshotPerformanceInfo', () {
    test('a bare call turns the HUD on', () {
      final e = Flut5Engine();
      expect(e.showFrameSnapshotDebug, isFalse);
      e.showSnapshotPerformanceInfo();
      expect(e.showFrameSnapshotDebug, isTrue);
    });

    test('false turns it off, and so does the no- form', () {
      final e = Flut5Engine()..showSnapshotPerformanceInfo();
      e.showSnapshotPerformanceInfo(false);
      expect(e.showFrameSnapshotDebug, isFalse);
      e.showSnapshotPerformanceInfo(true);
      e.noSnapshotPerformanceInfo();
      expect(e.showFrameSnapshotDebug, isFalse);
    });

    test('stays in sync with the underlying field', () {
      final e = Flut5Engine()..showFrameSnapshotDebug = true;
      expect(e.showFrameSnapshotDebug, isTrue);
      e.noSnapshotPerformanceInfo();
      expect(e.showFrameSnapshotDebug, isFalse);
    });
  });

  group('snapshot lifecycle is unaffected', () {
    test('a calibrated engine still stores and clears snapshots', () async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder, const Rect.fromLTWH(0, 0, 1, 1)).drawRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..color = const Color(0xFF00FF00),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(1, 1);
      picture.dispose();

      final e = ranged(0.5, 1.0);
      e.setFrameSnapshot(image, const Size(1, 1));
      expect(e.frameSnapshot, isNotNull);
      e.clearFrameSnapshot();
      expect(e.frameSnapshot, isNull);
    });
  });
}
