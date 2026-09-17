import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Flut5Engine engine() => Flut5Engine()
    ..fill(Colors.white)
    ..noStroke();

  group('Translate folding — batching', () {
    test('push/translate/shape/pop loops coalesce into one path item', () {
      final e = engine();
      for (var i = 0; i < 10; i++) {
        e.push();
        e.translate(i * 10.0, 5);
        e.circle(0, 0, 4);
        e.pop();
      }
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
      expect(e.renderQueue.items.single, isA<PathRenderItem>());
    });

    test('bare translate between shapes does not break the batch', () {
      final e = engine();
      e.rect(0, 0, 5, 5);
      e.translate(20, 0);
      e.rect(0, 0, 5, 5);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
    });

    test('a rotation folds into the shape geometry', () {
      final e = engine();
      e.push();
      e.translate(10, 10);
      e.rotate(math.pi / 4);
      e.rect(0, 0, 5, 5);
      e.pop();
      e.renderQueue.flushPending();
      expect(e.renderQueue.items, hasLength(1));
      expect(e.renderQueue.items.single, isA<PathRenderItem>());
    });

    test('contentBoundsFrom sees folded geometry at baked coordinates', () {
      final e = engine();
      e.renderQueue.flushPending();
      final slot = e.renderQueue.itemCount;
      e.push();
      e.translate(100, 50);
      e.rect(0, 0, 10, 10);
      e.pop();
      e.renderQueue.flushPending();
      expect(
        e.renderQueue.contentBoundsFrom(slot),
        const Rect.fromLTRB(100, 50, 110, 60),
      );
    });
  });

  group('Translate folding — rendered positions', () {
    test(
      'folded translate positions geometry like a canvas translate',
      () async {
        final e = engine();
        e.push();
        e.translate(30, 40);
        e.rect(0, 0, 10, 10);
        e.pop();
        final b = await _alphaBounds(e, 100, 100);
        expect(b.minX, inInclusiveRange(29, 31));
        expect(b.minY, inInclusiveRange(39, 41));
        expect(b.maxX, inInclusiveRange(38, 40));
        expect(b.maxY, inInclusiveRange(48, 50));
      },
    );

    test('pop restores the folded offset', () async {
      final e = engine();
      e.push();
      e.translate(50, 50);
      e.pop();
      e.rect(0, 0, 10, 10);
      final b = await _alphaBounds(e, 100, 100);
      expect(b.minX, inInclusiveRange(0, 1));
      expect(b.maxX, inInclusiveRange(9, 10));
    });

    test('nested folded pushes restore level by level', () async {
      final e = engine();
      e.push();
      e.translate(20, 0);
      e.push();
      e.translate(0, 30);
      e.pop(); // back to (20, 0)
      e.rect(0, 0, 10, 10);
      e.pop();
      final b = await _alphaBounds(e, 100, 100);
      expect(b.minX, inInclusiveRange(19, 21));
      expect(b.minY, inInclusiveRange(0, 1));
    });

    test(
      'rotation after a folded translate rotates about the right origin',
      () async {
        // A 10×10 rect centered on the rotated origin at (50, 50) becomes a
        // diamond with extent ±(5√2) ≈ ±7.07 around (50, 50).
        final e = engine();
        e.push();
        e.translate(50, 50);
        e.rotate(math.pi / 4);
        e.rect(-5, -5, 10, 10);
        e.pop();
        final b = await _alphaBounds(e, 100, 100);
        expect(b.minX, inInclusiveRange(41, 44));
        expect(b.maxX, inInclusiveRange(56, 58));
        expect(b.minY, inInclusiveRange(41, 44));
        expect(b.maxY, inInclusiveRange(56, 58));
      },
    );

    test('translate after a rotation folds in local (rotated) space', () async {
      // T(50,50) · R(90°) · T(10,0) applied to rect(0,0,10,10):
      // local (10..20, 0..10) → rotated (-10..0, 10..20) → +50 → (40..50, 60..70).
      final e = engine();
      e.push();
      e.translate(50, 50);
      e.rotate(math.pi / 2);
      e.translate(10, 0);
      e.rect(0, 0, 10, 10);
      e.pop();
      final b = await _alphaBounds(e, 100, 100);
      expect(b.minX, inInclusiveRange(39, 41));
      expect(b.maxX, inInclusiveRange(49, 51));
      expect(b.minY, inInclusiveRange(59, 61));
      expect(b.maxY, inInclusiveRange(69, 71));
    });

    test(
      'a shape after popping a rotated scope is unrotated and unshifted',
      () async {
        final e = engine();
        e.push();
        e.translate(50, 50);
        e.rotate(math.pi / 4);
        e.pop();
        e.rect(0, 0, 10, 10);
        final b = await _alphaBounds(e, 100, 100);
        expect(b.minX, inInclusiveRange(0, 1));
        expect(b.minY, inInclusiveRange(0, 1));
        expect(b.maxX, inInclusiveRange(9, 10));
        expect(b.maxY, inInclusiveRange(9, 10));
      },
    );

    test('unbalanced translate-only push leaks nothing to the canvas', () {
      final e = engine();
      e.push();
      e.translate(30, 30);
      e.rect(0, 0, 10, 10); // leaked push — never popped
      final canvas = Canvas(ui.PictureRecorder());
      final baseline = canvas.getSaveCount();
      e.renderQueue.execute(canvas);
      expect(canvas.getSaveCount(), baseline);
    });
  });

  group('Shadowed point/line batching', () {
    test('shadowed points coalesce into a single shadowed batch', () {
      final e = Flut5Engine()
        ..stroke(Colors.white)
        ..strokeWeight(4)
        ..shadow(2, 2, 4);
      for (var i = 0; i < 20; i++) {
        e.point(i * 3.0, 10);
      }
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
      final item = e.renderQueue.items.single as MultiPointRenderItem;
      expect(item.shadow, isNotNull);
      expect(item.coords.length, 40);
    });

    test('shadowed lines coalesce into a single shadowed batch', () {
      final e = Flut5Engine()
        ..stroke(Colors.white)
        ..strokeWeight(2)
        ..shadow(2, 2, 4);
      for (var i = 0; i < 10; i++) {
        e.line(0, i * 5.0, 20, i * 5.0);
      }
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
      final item = e.renderQueue.items.single as MultiLineRenderItem;
      expect(item.shadow, isNotNull);
      expect(item.coords.length, 40);
    });

    test('noShadow splits the batch so earlier points keep their shadow', () {
      final e = Flut5Engine()
        ..stroke(Colors.white)
        ..strokeWeight(4)
        ..shadow(2, 2, 4);
      e.point(0, 0);
      e.noShadow();
      e.point(10, 10);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 2);
      final first = e.renderQueue.items[0] as MultiPointRenderItem;
      final second = e.renderQueue.items[1] as MultiPointRenderItem;
      expect(first.shadow, isNotNull);
      expect(second.shadow, isNull);
    });
  });

  group('Shadowed shape batching', () {
    test('shadowed shapes coalesce into a single shadowed path batch', () {
      final e = engine()..shadow(2, 2, 4);
      for (var i = 0; i < 10; i++) {
        e.rect(i * 20.0, 0, 10, 10);
      }
      e.circle(300, 5, 4);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
      final item = e.renderQueue.items.single as PathRenderItem;
      expect(item.shadow, isNotNull);
    });

    test('redundant shadow() calls keep the spec identity-stable', () {
      final e = engine()..shadow(2, 2, 4);
      final spec = e.renderQueue.activeShadow;
      e.rect(0, 0, 10, 10);
      e.shadow(2, 2, 4); // same values — must not split the batch
      e.rect(20, 0, 10, 10);
      expect(identical(e.renderQueue.activeShadow, spec), isTrue);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
    });

    test('changing shadow values splits the batch', () {
      final e = engine()..shadow(2, 2, 4);
      e.rect(0, 0, 10, 10);
      e.shadow(4, 4, 8);
      e.rect(20, 0, 10, 10);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 2);
      final first = e.renderQueue.items[0] as PathRenderItem;
      final second = e.renderQueue.items[1] as PathRenderItem;
      expect(identical(first.shadow, second.shadow), isFalse);
    });

    test('noShadow splits the batch so earlier shapes keep their shadow', () {
      final e = engine()..shadow(2, 2, 4);
      e.rect(0, 0, 10, 10);
      e.noShadow();
      e.rect(20, 0, 10, 10);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 2);
      final first = e.renderQueue.items[0] as PathRenderItem;
      final second = e.renderQueue.items[1] as PathRenderItem;
      expect(first.shadow, isNotNull);
      expect(second.shadow, isNull);
    });

    test('a line does not merge into a filled shadowed batch', () {
      // A filled batch casts its shadow from the fill silhouette; a zero-area
      // line sub-path adds nothing to it, so the line must stay in the line
      // buffer where it casts its own stroke shadow.
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..stroke(Colors.red)
        ..strokeWeight(2)
        ..shadow(2, 2, 4);
      e.rect(0, 0, 10, 10);
      e.line(20, 0, 30, 10);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 2);
      final shapes = e.renderQueue.items[0] as PathRenderItem;
      final lines = e.renderQueue.items[1] as MultiLineRenderItem;
      expect(shapes.shadow, isNotNull);
      expect(lines.shadow, isNotNull);
    });

    test('a line still merges into a stroke-only shadowed batch', () {
      // Stroke-only batches shadow via the stroke outline, which covers the
      // merged line too — one item, one shadow.
      final e = Flut5Engine()
        ..noFill()
        ..stroke(Colors.red)
        ..strokeWeight(2)
        ..shadow(2, 2, 4);
      e.rect(0, 0, 10, 10);
      e.line(20, 0, 30, 10);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
      final item = e.renderQueue.items.single as PathRenderItem;
      expect(item.shadow, isNotNull);
    });
  });

  group('Cross-kind batching', () {
    test('a line merges into an open shape batch with the same stroke', () {
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..stroke(Colors.red)
        ..strokeWeight(2);
      e.rect(0, 0, 10, 10);
      e.line(20, 0, 30, 10);
      e.rect(40, 0, 10, 10);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
      expect(e.renderQueue.items.single, isA<PathRenderItem>());
    });

    test('a line with a different stroke paint still splits the batch', () {
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..stroke(Colors.red)
        ..strokeWeight(2);
      e.rect(0, 0, 10, 10);
      e.stroke(Colors.blue);
      e.line(20, 0, 30, 10);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 2);
    });

    test('merged lines render at folded positions', () async {
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..stroke(Colors.white)
        ..strokeWeight(2);
      e.push();
      e.translate(40, 40);
      e.rect(0, 0, 10, 10);
      e.line(0, 20, 10, 20);
      e.pop();
      final b = await _alphaBounds(e, 100, 100);
      // Rect top at ~40, merged line at y ≈ 60 (±1 for stroke width).
      expect(b.minY, inInclusiveRange(38, 41));
      expect(b.maxY, inInclusiveRange(59, 62));
    });

    test('triangles batch through the scratch-buffer path', () {
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..noStroke();
      e.triangle(0, 0, 10, 0, 5, 10);
      e.triangle(20, 0, 30, 0, 25, 10);
      e.quad(40, 0, 50, 0, 50, 10, 40, 10);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
    });

    test('folded translate positions triangles correctly', () async {
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..noStroke();
      e.push();
      e.translate(30, 40);
      e.triangle(0, 0, 10, 0, 5, 10);
      e.pop();
      final b = await _alphaBounds(e, 100, 100);
      expect(b.minX, inInclusiveRange(29, 31));
      expect(b.minY, inInclusiveRange(39, 41));
      expect(b.maxX, inInclusiveRange(38, 40));
      expect(b.maxY, inInclusiveRange(48, 50));
    });
  });

  group('Rotate transform item', () {
    test('contentBoundsFrom accounts for rotate items', () {
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..noStroke();
      e.renderQueue.flushPending();
      final slot = e.renderQueue.itemCount;
      e.push();
      e.translate(50, 50);
      e.rotate(math.pi / 2);
      e.rect(0, 0, 10, 10);
      e.pop();
      e.renderQueue.flushPending();
      // Local (0..10, 0..10) rotated 90° → (-10..0, 0..10), then +(50, 50).
      final b = e.renderQueue.contentBoundsFrom(slot)!;
      expect(b.left, closeTo(40, 0.01));
      expect(b.top, closeTo(50, 0.01));
      expect(b.right, closeTo(50, 0.01));
      expect(b.bottom, closeTo(60, 0.01));
    });
  });

  group('Background flag tracking', () {
    test('flags update incrementally and reset on clear', () {
      final e = Flut5Engine();
      expect(e.renderQueue.hasOpaqueFullCanvasBackground, isFalse);
      expect(e.renderQueue.lastBackgroundIsOpaqueFullCanvas, isFalse);

      e.background(Colors.black);
      expect(e.renderQueue.lastBackgroundIsOpaqueFullCanvas, isTrue);
      expect(e.renderQueue.hasOpaqueFullCanvasBackground, isTrue);

      e.background(Colors.black.withValues(alpha: 0.5));
      expect(e.renderQueue.lastBackgroundIsOpaqueFullCanvas, isFalse);
      // The earlier opaque clear still counts for the whole frame.
      expect(e.renderQueue.hasOpaqueFullCanvasBackground, isTrue);

      e.renderQueue.clear();
      expect(e.renderQueue.lastBackgroundIsOpaqueFullCanvas, isFalse);
      expect(e.renderQueue.hasOpaqueFullCanvasBackground, isFalse);
    });
  });
}

class const _AlphaBounds(
  final int minX,
  final int minY,
  final int maxX,
  final int maxY,
);

Future<_AlphaBounds> _alphaBounds(
  Flut5Engine engine,
  int width,
  int height,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  engine.renderQueue.execute(canvas);
  final image = await recorder.endRecording().toImage(width, height);
  addTearDown(image.dispose);
  final bytes = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );

  var minX = width;
  var minY = height;
  var maxX = -1;
  var maxY = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final alpha = bytes!.getUint8((y * width + x) * 4 + 3);
      if (alpha == 0) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }

  if (maxX < 0) {
    throw StateError('Rendered image has no non-transparent pixels.');
  }
  return _AlphaBounds(minX, minY, maxX, maxY);
}
