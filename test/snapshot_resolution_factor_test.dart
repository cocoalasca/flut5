import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// Covers the two knobs that decide how much the trail snapshot costs per
/// capture: the window-relative resolution factor, and whether the blit
/// kernel is fixed or picked per draw.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('frameSnapshotResolutionFactor', () {
    test('defaults per build mode and platform', () {
      // The host VM is native, not JavaScript web, so the higher pair
      // applies. JS web gets 0.7/0.9 instead — no raster thread to overlap
      // capture with, plus CanvasKit's per-call toImage cost.
      final e = Flut5Engine();
      expect(e.frameSnapshotResolutionFactorDebug, 0.8);
      expect(e.frameSnapshotResolutionFactorProd, 0.95);
      // `flutter test` runs the debug JIT, so the debug value is the one that
      // resolves. Either sits below the 1.0 ceiling, which is what makes
      // startup calibration active out of the box.
      expect(e.frameSnapshotResolutionFactor, 0.8);
      expect(e.frameSnapshotResolutionFactorIsExplicit, isFalse);
    });

    test('an explicit factor outranks both per-mode defaults', () {
      final e = Flut5Engine()..frameSnapshotResolutionFactor = 0.45;
      expect(e.frameSnapshotResolutionFactor, 0.45);
      expect(e.frameSnapshotResolutionFactorIsExplicit, isTrue);
      // Changing either default must not disturb an explicit choice.
      e.frameSnapshotResolutionFactorDebug = 0.3;
      e.frameSnapshotResolutionFactorProd = 1.0;
      expect(e.frameSnapshotResolutionFactor, 0.45);
    });

    test('clearing the explicit factor hands the choice back to the mode', () {
      final e = Flut5Engine()..frameSnapshotResolutionFactor = 0.45;
      e.clearFrameSnapshotResolutionFactor();
      expect(e.frameSnapshotResolutionFactorIsExplicit, isFalse);
      expect(e.frameSnapshotResolutionFactor, 0.8);
    });

    test('changing the active mode default changes the resolved factor', () {
      final e = Flut5Engine()..frameSnapshotResolutionFactorDebug = 0.55;
      expect(e.frameSnapshotResolutionFactor, 0.55);
    });

    test('changing the inactive mode default does not', () {
      final e = Flut5Engine()..frameSnapshotResolutionFactorProd = 0.35;
      expect(e.frameSnapshotResolutionFactorProd, 0.35);
      expect(e.frameSnapshotResolutionFactor, 0.8);
    });

    test('per-mode setters reject percentages too', () {
      final e = Flut5Engine();
      expect(() => e.frameSnapshotResolutionFactorDebug = 70,
          throwsArgumentError);
      expect(() => e.frameSnapshotResolutionFactorProd = 0, throwsArgumentError);
    });

    test('per-mode method and p5-style accessor forms agree', () {
      final e = Flut5Engine();
      e.setFrameSnapshotResolutionFactorDebug(0.6);
      expect(e.snapshotResolutionFactorDebug(), 0.6);
      expect(e.snapshotResolutionFactorDebug(0.65), 0.65);
      e.setFrameSnapshotResolutionFactorProd(0.95);
      expect(e.snapshotResolutionFactorProd(), 0.95);
      expect(e.snapshotResolutionFactorProd(1.0), 1.0);
    });

    test('accepts the documented range', () {
      final e = Flut5Engine();
      for (final v in [0.5, 0.75, 0.9, 1.0]) {
        e.frameSnapshotResolutionFactor = v;
        expect(e.frameSnapshotResolutionFactor, v);
      }
    });

    test('rejects zero, negatives, and anything above 1', () {
      final e = Flut5Engine();
      expect(() => e.frameSnapshotResolutionFactor = 0, throwsArgumentError);
      expect(() => e.frameSnapshotResolutionFactor = -0.5, throwsArgumentError);
      expect(() => e.frameSnapshotResolutionFactor = 1.01, throwsArgumentError);
      // The rejected assignments must not have taken effect.
      expect(e.frameSnapshotResolutionFactor, 0.8);
    });

    test('method and p5-style accessor forms agree', () {
      final e = Flut5Engine();
      e.setFrameSnapshotResolutionFactor(0.6);
      expect(e.frameSnapshotResolutionFactor, 0.6);
      expect(e.snapshotResolutionFactor(), 0.6);
      expect(e.snapshotResolutionFactor(0.8), 0.8);
      expect(e.frameSnapshotResolutionFactor, 0.8);
    });
  });

  group('effectiveFrameSnapshotResolutionFactor', () {
    /// Pins the factor at 1.0 so the caps are the only thing that can bind —
    /// otherwise the per-mode default (0.8 under test) is tighter than either
    /// cap in these scenarios and nothing would be measured.
    Flut5Engine sized(Size size, double dpr) {
      final e = Flut5Engine();
      e.environment = e.environment.withSize(size);
      e.devicePixelRatio = dpr;
      e.frameSnapshotResolutionFactor = 1.0;
      return e;
    }

    test('equals the request while both caps have slack', () {
      // 1175 logical × dpr 2 = 2350 native, under the 3600 edge cap, and
      // 1175×740×4 = 3.5 MP native, under the 8 MP budget.
      final e = sized(const Size(1175, 740), 2.0);
      expect(e.effectiveFrameSnapshotResolutionFactor, 1.0);
      expect(e.frameSnapshotCapBinding, isNull);
      e.frameSnapshotResolutionFactor = 0.6;
      expect(e.effectiveFrameSnapshotResolutionFactor, closeTo(0.6, 1e-9));
      expect(e.frameSnapshotCapBinding, isNull);
    });

    test('the edge cap binds first on a wide canvas', () {
      // 2560 logical wide × dpr 2 = 5120 native — a 5K iMac fullscreen.
      // edge: 3600 / 5120        = 0.703
      // px:   sqrt(8M/(2560×1440))/2 = 0.737  → edge is tighter
      final e = sized(const Size(2560, 1440), 2.0);
      expect(
        e.effectiveFrameSnapshotResolutionFactor,
        closeTo(3600 / 5120, 1e-9),
      );
      expect(e.frameSnapshotCapBinding, 'edge');
    });

    test('the pixel budget binds on a square canvas the edge cap would miss',
        () {
      // 2000×2000 logical at dpr 2 = 4000×4000 = 16 MP native.
      // edge: 3600 / 4000            = 0.900
      // px:   sqrt(8M/4M)/2 = 1.414/2 = 0.707  → pixels are tighter
      final e = sized(const Size(2000, 2000), 2.0);
      expect(
        e.effectiveFrameSnapshotResolutionFactor,
        closeTo(math.sqrt(8000000 / 4000000) / 2, 1e-9),
      );
      expect(e.frameSnapshotCapBinding, 'px');
    });

    test('the request wins when it is already below what the caps allow', () {
      final e = sized(const Size(2400, 1400), 2.0)
        ..frameSnapshotResolutionFactor = 0.3;
      expect(e.effectiveFrameSnapshotResolutionFactor, closeTo(0.3, 1e-9));
      expect(e.frameSnapshotCapBinding, isNull);
    });

    test('caps that are unset never bind', () {
      final e = sized(const Size(4000, 3000), 3.0)
        ..frameSnapshotMaxResolution = null
        ..frameSnapshotMaxPixels = null
        ..frameSnapshotResolutionFactor = 0.9;
      expect(e.effectiveFrameSnapshotResolutionFactor, closeTo(0.9, 1e-9));
      expect(e.frameSnapshotCapBinding, isNull);
    });
  });

  group('frameSnapshotMaxPixels', () {
    test('defaults to an 8 MP budget', () {
      expect(Flut5Engine().frameSnapshotMaxPixels, 8000000);
    });

    test('rejects zero and negatives but accepts null', () {
      final e = Flut5Engine();
      expect(() => e.frameSnapshotMaxPixels = 0, throwsArgumentError);
      expect(() => e.frameSnapshotMaxPixels = -1, throwsArgumentError);
      expect(e.frameSnapshotMaxPixels, 8000000);
      e.frameSnapshotMaxPixels = null;
      expect(e.frameSnapshotMaxPixels, isNull);
    });

    test('method and p5-style accessor forms agree', () {
      final e = Flut5Engine();
      e.setFrameSnapshotMaxPixels(4000000);
      expect(e.frameSnapshotMaxPixels, 4000000);
      expect(e.snapshotMaxPixels(), 4000000);
      expect(e.snapshotMaxPixels(2000000), 2000000);
    });
  });

  group('frameSnapshotMaxResolution', () {
    test('defaults to a 3600 edge, covering a maximized desktop window', () {
      expect(Flut5Engine().frameSnapshotMaxResolution, 3600);
    });
  });

  group('snapshot blit filter quality', () {
    test('defaults to bilinear at every upscale', () {
      final e = Flut5Engine();
      expect(e.adaptiveSnapshotFilterQuality, isFalse);
      // 2.5× would have escalated to bicubic under the old default. Holding
      // bilinear here is the whole point: bicubic engages exactly when the
      // snapshot is already downscaled to save time.
      for (final ratio in [1.0, 1.4, 1.68, 2.5]) {
        expect(
          e.effectiveFrameSnapshotFilterQuality(upscaleRatio: ratio),
          FilterQuality.low,
        );
      }
    });

    test('escalates past ~1.4x once adaptive selection is enabled', () {
      final e = Flut5Engine()..adaptiveSnapshotFilterQuality = true;
      expect(
        e.effectiveFrameSnapshotFilterQuality(upscaleRatio: 1.0),
        FilterQuality.low,
      );
      expect(
        e.effectiveFrameSnapshotFilterQuality(upscaleRatio: 1.39),
        FilterQuality.low,
      );
      expect(
        e.effectiveFrameSnapshotFilterQuality(upscaleRatio: 1.68),
        FilterQuality.high,
      );
    });

    test('an explicit quality wins over adaptive selection', () {
      final e = Flut5Engine()
        ..adaptiveSnapshotFilterQuality = true
        ..frameSnapshotFilterQuality = FilterQuality.none;
      expect(
        e.effectiveFrameSnapshotFilterQuality(upscaleRatio: 3.0),
        FilterQuality.none,
      );
    });

    test('reading the p5-style accessor does not mark the quality explicit',
        () {
      final e = Flut5Engine()..adaptiveSnapshotFilterQuality = true;
      expect(e.snapshotFilterQuality(), FilterQuality.low);
      // Still adaptive — a bare read must not pin the kernel.
      expect(
        e.effectiveFrameSnapshotFilterQuality(upscaleRatio: 2.0),
        FilterQuality.high,
      );
    });
  });
}
