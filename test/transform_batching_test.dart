import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Flut5Engine engine() => Flut5Engine()
    ..fill(Colors.white)
    ..noStroke();

  group('Automatic transform batching', () {
    test('different rotations and uniform scales share a fill batch', () {
      final e = engine();
      for (var i = 0; i < 12; i++) {
        e.push();
        e.translate(i * 25.0, 30);
        e.rotate(i * .17);
        e.scale(1 + i * .1);
        e.rect(-4, -4, 8, 8);
        e.circle(10, 0, 3);
        e.pop();
      }
      e.renderQueue.flushPending();
      expect(e.renderQueue.items, hasLength(1));
      expect(e.renderQueue.items.single, isA<PathRenderItem>());
    });

    test('rotated strokes at the same scale reuse one paint', () {
      final e = engine()
        ..stroke(Colors.red)
        ..strokeWeight(2);
      for (var i = 0; i < 10; i++) {
        e.push();
        e.translate(i * 25.0, 30);
        e.scale(2);
        e.rotate(i * .13);
        e.rect(0, 0, 6, 6);
        e.pop();
      }
      e.renderQueue.flushPending();
      expect(e.renderQueue.items, hasLength(1));
      final item = e.renderQueue.items.single as PathRenderItem;
      expect(item.strokePaint!.strokeWidth, 4);
    });

    test(
      'different scaled stroke widths split batches without mutating paint',
      () {
        final e = engine()
          ..stroke(Colors.red)
          ..strokeWeight(2);
        e.rect(0, 0, 5, 5);
        e.push();
        e.scale(3);
        e.rect(10, 0, 5, 5);
        e.pop();
        e.rect(50, 0, 5, 5);
        e.renderQueue.flushPending();
        expect(e.renderQueue.items, hasLength(3));
        expect(
          e.renderQueue.items.whereType<PathRenderItem>().map(
            (item) => item.strokePaint!.strokeWidth,
          ),
          [2, 6, 2],
        );
      },
    );

    test('nonuniform and zero scale still materialize canvas transforms', () {
      for (final (x, y) in [(2.0, 3.0), (0.0, 0.0), (-1.0, 1.0)]) {
        final e = engine();
        e.rect(0, 0, 4, 4);
        e.scale(x, y);
        e.rect(10, 0, 4, 4);
        e.renderQueue.flushPending();
        expect(e.renderQueue.items, hasLength(3));
        final transform = e.renderQueue.items[1] as TransformRenderItem;
        expect(transform.type, TransformType.scale);
        expect(transform.scaleX, x);
        expect(transform.scaleY, y);
      }
    });

    test('lines and round points fold coordinates and stroke widths', () {
      final q = Flut5RenderQueue();
      final paint = Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 2; i++) {
        q.pushTransform();
        q.translateTransform(i * 20.0, 10);
        q.applyTransform(TransformRenderItem.rotate(math.pi / 2));
        q.applyTransform(TransformRenderItem.scale(2, 2));
        q.appendLine(0, 0, 5, 0, paint);
        q.popTransform();
      }
      q.flushPending();
      expect(q.items, hasLength(1));
      final lines = q.items.single as MultiLineRenderItem;
      expect(lines.coords, hasLength(8));
      final expected = [0, 10, 0, 20, 20, 10, 20, 20];
      for (var i = 0; i < expected.length; i++) {
        expect(lines.coords[i], closeTo(expected[i], 1e-5));
      }
      q.clear();
      q.applyTransform(TransformRenderItem.scale(2, 2));
      q.appendPoint(2, 3, paint);
      q.appendPoints(Float32List.fromList([4, 5]), paint);
      q.flushPending();
      final points = q.items.single as MultiPointRenderItem;
      expect(points.coords, [4, 6, 8, 10]);
      expect(points.pointPaint.strokeWidth, 4);
      expect(paint.strokeWidth, 2);
    });

    test('clear resets pending rotation and scale', () {
      final e = engine();
      e.translate(60, 70);
      e.rotate(.7);
      e.scale(3);
      e.renderQueue.clear();
      e.rect(0, 0, 10, 10);
      e.renderQueue.flushPending();
      expect(
        e.renderQueue.contentBoundsFrom(0),
        const Rect.fromLTWH(0, 0, 10, 10),
      );
    });

    test('unpainted transformed shapes produce no items', () {
      final e = engine()..noFill();
      e.rotate(.3);
      e.rect(0, 0, 10, 10);
      e.circle(20, 20, 8);
      e.renderQueue.flushPending();
      expect(e.renderQueue.items, isEmpty);
    });
  });

  group('Folded output matches canvas transforms', () {
    test(
      'all shape paths, nested scopes, and negative uniform scales',
      () async {
        await _compare((s) {
          s.translate(70, 60);
          s.rotate(.27);
          s.scale(1.3);
          s.push();
          s.translate(-30, -25);
          s.e.rect(-6, -4, 12, 8, 2);
          s.rotate(.32);
          s.e.ellipse(20, 0, 12, 6);
          s.push();
          s.translate(25, 25);
          s.scale(-1.4);
          s.e.circle(0, 0, 10);
          s.e.triangle(15, 0, 25, 0, 20, 8);
          s.pop();
          s.e.arc(5, 30, 12, 10, 0, math.pi);
          s.pop();
          s.e.quad(0, 25, 8, 25, 10, 35, 2, 35);
          s.e.polygon(25, 25, 8, 5);
          s.e.star(45, 25, 4, 8, 5);
          s.e.beginShape();
          s.e.vertex(-30, 15);
          s.e.vertex(-20, 15);
          s.e.vertex(-25, 25);
          s.e.endShape(close: true);
        });
      },
    );

    test('uniformly scaled and rotated solid strokes', () async {
      await _compare((s) {
        s.e.noFill();
        s.e.stroke(Colors.white);
        s.e.strokeWeight(2);
        for (var i = 0; i < 3; i++) {
          s.push();
          s.translate(30 + i * 45.0, 40);
          s.rotate(.2 + i * .1);
          s.scale(1 + i * .5);
          s.e.rect(-5, -5, 10, 10);
          s.e.line(-5, 15, 5, 15);
          s.e.circle(0, 30, 8);
          s.pop();
        }
      });
    });

    test(
      'nested materialization restores outer scopes around opaque items',
      () async {
        await _compare((s) {
          s.translate(40, 30);
          s.rotate(.2);
          s.push();
          s.scale(1.5);
          s.translate(10, 5);
          s.push();
          s.rotate(-.4);
          s.e.rect(0, 0, 8, 8);
          s.e.renderQueue.enqueue(
            RectRenderItem(
              const Rect.fromLTWH(15, 0, 8, 8),
              null,
              Paint()..color = Colors.red,
              null,
            ),
          );
          s.translate(0, 20);
          s.e.circle(0, 0, 8);
          s.pop();
          s.e.rect(0, 30, 8, 8);
          s.pop();
          s.e.rect(50, 0, 8, 8);
        });
      },
    );

    test(
      'nonuniform scale boundary preserves composition and later folding',
      () async {
        await _compare((s) {
          s.push();
          s.translate(70, 50);
          s.rotate(.3);
          s.e.rect(-25, -15, 8, 8);
          s.push();
          s.scale(2, .7);
          s.rotate(.5);
          s.scale(1.2);
          s.e.rect(0, 0, 10, 10);
          s.pop();
          s.e.circle(0, 25, 10);
          s.pop();
          s.e.rect(10, 10, 10, 10);
        });
      },
    );

    test(
      'images retain their canvas transforms between folded shapes',
      () async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 8, 8),
          Paint()..color = Colors.blue,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(8, 8);
        picture.dispose();
        addTearDown(image.dispose);
        await _compare((s) {
          s.push();
          s.translate(50, 30);
          s.rotate(.4);
          s.scale(1.4);
          s.e.rect(-15, 0, 8, 8);
          s.e.renderQueue.appendImage(
            image,
            const Rect.fromLTWH(0, 0, 8, 8),
            const Rect.fromLTWH(0, 0, 16, 16),
            BlendMode.srcOver,
          );
          // A new folded scope inside an already materialized scope.
          s.push();
          s.translate(0, 30);
          s.rotate(-.2);
          s.scale(1.3);
          s.e.circle(0, 0, 8);
          s.pop();
          s.e.rect(30, 0, 8, 8);
          s.pop();
          s.e.rect(10, 100, 8, 8);
        });
      },
    );

    for (final cap in [StrokeCap.round, StrokeCap.square]) {
      test('scaled and rotated $cap points retain their footprint', () async {
        await _compare((s) {
          final paint = Paint()
            ..color = Colors.white
            ..strokeWidth = 7
            ..strokeCap = cap;
          s.push();
          s.translate(60, 40);
          s.rotate(.4);
          s.scale(2);
          s.e.renderQueue.appendPoint(0, 0, paint);
          s.e.renderQueue.appendPoints(
            Float32List.fromList([20, 0, 20, 20]),
            paint,
          );
          s.pop();
          s.e.renderQueue.appendPoint(10, 100, paint);
        });
      });
    }

    test('clip materializes rotation and scale and pop lifts it', () async {
      await _compare((s) {
        s.push();
        s.translate(50, 40);
        s.rotate(.3);
        s.scale(1.5);
        s.e.clip(() => s.e.rect(0, 0, 15, 15));
        s.e.rect(-10, -10, 40, 40);
        s.pop();
        s.e.rect(100, 100, 10, 10);
      });
    });

    for (final effect in ['shadow', 'dash', 'shader', 'translucent']) {
      test('$effect retains canvas-local rendering', () async {
        await _compare((s) {
          s.push();
          s.translate(60, 50);
          s.rotate(.4);
          s.scale(1.7);
          final fill = Paint()..color = Colors.white;
          Paint? stroke;
          switch (effect) {
            case 'shadow':
              s.e.shadow(5, 2, 3);
            case 'dash':
              stroke = Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2;
              s.e.renderQueue.setDashState([3, 2], 1);
            case 'shader':
              fill.shader = ui.Gradient.linear(
                Offset.zero,
                const Offset(20, 0),
                [Colors.red, Colors.blue],
              );
            case 'translucent':
              fill.color = const Color(0x80FFFFFF);
          }
          s.e.renderQueue.appendRect(
            const Rect.fromLTWH(0, 0, 20, 15),
            null,
            fill,
            stroke,
          );
          s.pop();
          s.e.noShadow();
          s.e.renderQueue.setDashState(null, 0);
          s.e.rect(10, 100, 10, 10);
        });
      });
    }
  });
}

// The reference sends real transforms through enqueue, bypassing folding.
// Geometry and styles use the same public API in both scenes.
class _Scene(final bool raw) {
  final Flut5Engine e = Flut5Engine()
    ..fill(Colors.white)
    ..noStroke();

  void push() =>
      raw ? e.renderQueue.enqueue(TransformRenderItem.push()) : e.push();
  void pop() =>
      raw ? e.renderQueue.enqueue(TransformRenderItem.pop()) : e.pop();
  void translate(double x, double y) => raw
      ? e.renderQueue.enqueue(TransformRenderItem.translate(x, y))
      : e.translate(x, y);
  void rotate(double angle) => raw
      ? e.renderQueue.enqueue(TransformRenderItem.rotate(angle))
      : e.rotate(angle);
  void scale(double x, [double? y]) => raw
      ? e.renderQueue.enqueue(TransformRenderItem.scale(x, y ?? x))
      : e.scale(x, y);
}

Future<Uint8List> _pixels(Flut5Engine e) async {
  final recorder = ui.PictureRecorder();
  e.renderQueue.execute(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(180, 150);
  final data = await image.toByteData();
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _compare(void Function(_Scene) draw) async {
  final folded = _Scene(false), reference = _Scene(true);
  draw(folded);
  draw(reference);
  final actual = await _pixels(folded.e);
  final expected = await _pixels(reference.e);
  var error = 0;
  var changedPixels = 0;
  for (var i = 0; i < actual.length; i += 4) {
    var maxDelta = 0;
    for (var channel = 0; channel < 4; channel++) {
      final delta = (actual[i + channel] - expected[i + channel]).abs();
      error += delta;
      maxDelta = math.max(maxDelta, delta);
    }
    if (maxDelta > 16) changedPixels++;
  }
  // Small edge differences are expected when transforming path coordinates
  // instead of letting the rasterizer transform a primitive.
  expect(error / actual.length, lessThan(.5));
  // CanvasKit's primitive/path curve edges already differ at just over 0.5%
  // in this scene before allocation optimizations; keep a bounded 0.6% edge
  // allowance alongside the stricter mean channel-error check above.
  expect(changedPixels / (actual.length / 4), lessThan(.006));
}
