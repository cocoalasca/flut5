import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

class _RecordingGradient() extends LinearGradient {
  this : super(colors: [Colors.red, Colors.blue]);

  final shaderRects = <Rect>[];

  @override
  ui.Shader createShader(Rect rect, {TextDirection? textDirection}) {
    shaderRects.add(rect);
    return super.createShader(rect, textDirection: textDirection);
  }
}

/// Pins the behavior of the beginShape/vertex/endShape pipeline over the
/// flattened vertex storage: geometry must land in the render queue as the
/// same items, with the same (control-point-inclusive) path bounds, as the
/// previous one-object-per-vertex storage produced.
void main() {
  Flut5RenderItem singleItem(Flut5Engine engine) {
    engine.renderQueue.flushPending();
    final items = engine.renderQueue.items;
    expect(items, hasLength(1));
    return items.single;
  }

  for (final useFill in [true, false]) {
    for (final explicitRect in [true, false]) {
      test('vertex ${useFill ? 'fill' : 'stroke'} gradient keeps '
          '${explicitRect ? 'explicit' : 'automatic'} bounds', () {
        final engine = Flut5Engine();
        final gradient = _RecordingGradient();
        if (useFill) {
          if (explicitRect) {
            engine.fill(gradient, 0, 0, 100, 100);
          } else {
            engine.fill(gradient);
          }
        } else {
          if (explicitRect) {
            engine.stroke(gradient, 0, 0, 100, 100);
          } else {
            engine.stroke(gradient);
          }
        }
        engine.beginShape();
        engine.vertex(10, 20);
        engine.vertex(60, 20);
        engine.vertex(60, 70);
        engine.vertex(10, 70);
        engine.endShape(close: true);
        expect(singleItem(engine).bounds, const Rect.fromLTRB(10, 20, 60, 70));
        expect(
          gradient.shaderRects.last,
          explicitRect
              ? const Rect.fromLTWH(0, 0, 100, 100)
              : const Rect.fromLTRB(10, 20, 60, 70),
        );
      });
    }
  }

  test('polygon mode builds a closed path with the vertex bounds', () {
    final engine = Flut5Engine();
    engine.beginShape();
    engine.vertex(10, 10);
    engine.vertex(60, 10);
    engine.vertex(60, 60);
    engine.vertex(10, 60);
    engine.endShape(close: true);

    final item = singleItem(engine);
    expect(item, isA<PathRenderItem>());
    expect(item.bounds, const Rect.fromLTRB(10, 10, 60, 60));
  });

  test('bezier and quadratic vertices contribute control-point bounds', () {
    final engine = Flut5Engine();
    engine.beginShape();
    engine.vertex(0, 0);
    engine.bezierVertex(10, -20, 30, 40, 50, 0);
    engine.quadraticVertex(70, 60, 90, 10);
    engine.endShape();

    // Path.getBounds is control-point inclusive: the union of every anchor
    // and control coordinate above.
    final item = singleItem(engine);
    expect(item.bounds, const Rect.fromLTRB(0, -20, 90, 60));
  });

  test('curveVertex run converts to Catmull-Rom bezier segments', () {
    final engine = Flut5Engine();
    engine.beginShape();
    engine.vertex(0, 0);
    engine.curveVertex(0, 0);
    engine.curveVertex(10, 10);
    engine.curveVertex(20, 10);
    engine.curveVertex(30, 0);
    engine.endShape();

    // One segment between P1(10,10) and P2(20,10) with controls
    // cp1 = P1 + (P2 - P0)/6 = (13.33.., 11.66..) and
    // cp2 = P2 - (P3 - P1)/6 = (16.66.., 11.66..).
    final b = singleItem(engine).bounds!;
    expect(b.left, 0);
    expect(b.top, 0);
    expect(b.right, 20);
    // Path points are stored as float32 inside Skia, so compare at that
    // precision rather than double precision.
    expect(b.bottom, closeTo(10 + 10 / 6, 1e-5));
  });

  test('contours merge into the outer shape as one path item', () {
    final engine = Flut5Engine();
    engine.beginShape();
    engine.vertex(0, 0);
    engine.vertex(100, 0);
    engine.vertex(100, 100);
    engine.vertex(0, 100);
    engine.beginContour();
    engine.vertex(25, 25);
    engine.vertex(75, 25);
    engine.vertex(75, 75);
    engine.vertex(25, 75);
    engine.endContour();
    engine.endShape(close: true);

    final item = singleItem(engine);
    expect(item, isA<PathRenderItem>());
    expect(item.bounds, const Rect.fromLTRB(0, 0, 100, 100));
  });

  test('points mode coalesces vertices into one multi-point item', () {
    final engine = Flut5Engine();
    engine.beginShape(ShapeMode.points);
    engine.vertex(5, 6);
    engine.vertex(50, 40);
    engine.vertex(20, 90);
    engine.endShape();

    final item = singleItem(engine);
    expect(item, isA<MultiPointRenderItem>());
    expect(item.bounds, const Rect.fromLTRB(5, 6, 50, 90));
  });

  test('lines mode pairs vertices into segments', () {
    final engine = Flut5Engine();
    engine.beginShape(ShapeMode.lines);
    engine.vertex(0, 0);
    engine.vertex(10, 10);
    engine.vertex(40, 5);
    engine.vertex(60, 25);
    engine.endShape();

    final item = singleItem(engine);
    expect(item, isA<MultiLineRenderItem>());
    expect(item.bounds, const Rect.fromLTRB(0, 0, 60, 25));
  });

  test('triangles mode groups every three vertices', () {
    final engine = Flut5Engine();
    engine.beginShape(ShapeMode.triangles);
    engine.vertex(0, 0);
    engine.vertex(20, 0);
    engine.vertex(10, 20);
    engine.vertex(40, 40);
    engine.vertex(60, 40);
    engine.vertex(50, 60);
    engine.endShape();

    final item = singleItem(engine);
    expect(item, isA<PathRenderItem>());
    expect(item.bounds, const Rect.fromLTRB(0, 0, 60, 60));
  });

  test('quadStrip mode reorders each quad pair correctly', () {
    final engine = Flut5Engine();
    engine.beginShape(ShapeMode.quadStrip);
    engine.vertex(0, 0);
    engine.vertex(0, 30);
    engine.vertex(20, 0);
    engine.vertex(20, 30);
    engine.endShape();

    final item = singleItem(engine);
    expect(item, isA<PathRenderItem>());
    expect(item.bounds, const Rect.fromLTRB(0, 0, 20, 30));
  });

  test('buffers reset between shapes — no leakage across endShape', () {
    final engine = Flut5Engine();
    engine.beginShape();
    engine.vertex(0, 0);
    engine.vertex(500, 500);
    engine.vertex(0, 500);
    engine.endShape(close: true);
    engine.renderQueue.flushPending();
    engine.renderQueue.clear();

    // A second, smaller shape must not inherit any geometry (or contour
    // state) from the first — pins the clear()/pool reuse path.
    engine.beginShape();
    engine.vertex(1, 2);
    engine.vertex(3, 2);
    engine.vertex(3, 4);
    engine.endShape(close: true);

    final item = singleItem(engine);
    expect(item.bounds, const Rect.fromLTRB(1, 2, 3, 4));
  });

  test('contour buffers are pooled and reused without stale vertices', () {
    final engine = Flut5Engine();
    void ring(Rect outer, Rect hole) {
      engine.beginShape();
      engine.vertex(outer.left, outer.top);
      engine.vertex(outer.right, outer.top);
      engine.vertex(outer.right, outer.bottom);
      engine.vertex(outer.left, outer.bottom);
      engine.beginContour();
      engine.vertex(hole.left, hole.top);
      engine.vertex(hole.right, hole.top);
      engine.vertex(hole.right, hole.bottom);
      engine.vertex(hole.left, hole.bottom);
      engine.endContour();
      engine.endShape(close: true);
    }

    ring(
      const Rect.fromLTRB(0, 0, 200, 200),
      const Rect.fromLTRB(50, 50, 150, 150),
    );
    engine.renderQueue.flushPending();
    engine.renderQueue.clear();

    ring(
      const Rect.fromLTRB(0, 0, 40, 40),
      const Rect.fromLTRB(10, 10, 30, 30),
    );
    final item = singleItem(engine);
    expect(item.bounds, const Rect.fromLTRB(0, 0, 40, 40));
  });

  test('endShape inside beginBatch merges into the batch path', () {
    final engine = Flut5Engine();
    engine.beginBatch();
    engine.beginShape();
    engine.vertex(10, 10);
    engine.vertex(90, 10);
    engine.vertex(50, 80);
    engine.endShape(close: true);
    engine.endBatch();

    final item = singleItem(engine);
    expect(item, isA<PathRenderItem>());
    expect(item.bounds, const Rect.fromLTRB(10, 10, 90, 80));
  });

  test('empty shape enqueues nothing', () {
    final engine = Flut5Engine();
    engine.beginShape();
    engine.endShape();
    engine.renderQueue.flushPending();
    expect(engine.renderQueue.items, isEmpty);
  });
}
