import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `beginPixelate()`/`endPixelate()` render their scope at one pixel per
/// block and draw it back with nearest-neighbour sampling: flat, averaged
/// blocks on a grid anchored at the canvas origin.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Flut5Engine filled() => Flut5Engine()
    ..environment = const SketchEnvironment().withSize(const Size(200, 200))
    ..fill(Colors.white)
    ..noStroke();

  List<Flut5RenderItem> items(Flut5Engine e) {
    e.renderQueue.flushPending();
    return e.renderQueue.items;
  }

  group('Queue', () {
    test('markers bound the scope and shapes inside still batch', () {
      final e = filled();
      e.rect(0, 0, 10, 10);
      e.beginPixelate(8);
      e.rect(20, 0, 10, 10);
      e.rect(40, 0, 10, 10);
      e.endPixelate();
      e.rect(60, 0, 10, 10);
      final queued = items(e);
      expect(queued.map((i) => i.runtimeType).toList(), [
        PathRenderItem,
        PixelateBeginRenderItem,
        PathRenderItem,
        PixelateEndRenderItem,
        PathRenderItem,
      ]);
    });

    test('the scope keeps its transforms to itself', () {
      final e = filled();
      e.beginPixelate(8);
      e.translate(50, 0);
      e.rect(0, 0, 10, 10);
      e.endPixelate();
      e.rect(0, 0, 10, 10);
      expect(items(e).last.bounds, const Rect.fromLTWH(0, 0, 10, 10));
    });

    test('a pop() with no push() inside the scope is ignored', () async {
      final e = filled();
      e.push();
      e.translate(30, 0);
      e.beginPixelate(8);
      e.pop(); // belongs to the outer push — must not close the scope
      e.endPixelate();
      e.rect(0, 100, 10, 10);
      e.pop();
      e.rect(0, 150, 10, 10);
      final p = await _pixels(e.renderQueue.execute);
      // Still translated after the scope, plain after the real pop().
      expect(_pixel(p, 35, 105) & 0xFF, 255);
      expect(_pixel(p, 5, 105) & 0xFF, 0);
      expect(_pixel(p, 5, 155) & 0xFF, 255);
    });

    test('a push() left open inside the scope is closed by endPixelate()', () {
      final e = filled();
      e.beginPixelate(8);
      e.push();
      e.translate(50, 0);
      e.endPixelate();
      e.rect(0, 0, 10, 10);
      expect(items(e).last.bounds, const Rect.fromLTWH(0, 0, 10, 10));
    });

    test('misuse throws', () {
      expect(() => filled().endPixelate(), throwsFlutterError);
      final e = filled()..beginBatch();
      expect(() => e.beginPixelate(8), throwsFlutterError);
    });

    test('an opening marker makes the split replay fall back', () {
      final e = filled();
      e.beginPixelate(8);
      e.background(Colors.black);
      e.endPixelate();
      expect(e.renderQueue.backgroundsPrecedeContent, isFalse);
    });
  });

  group('Pixels', () {
    test('blocks are flat and anchored at the canvas origin', () async {
      for (final size in [8.0, 10.0]) {
        final e = filled();
        // A folded translate before the scope must move the shapes, not
        // the grid.
        e.translate(3, 7);
        e.beginPixelate(size);
        e.circle(100, 100, 120);
        e.stroke(Colors.red);
        e.strokeWeight(3);
        e.line(10, 10, 180, 60);
        e.endPixelate();
        final p = await _pixels(e.renderQueue.execute);
        final s = size.toInt();
        var partial = 0;
        for (var by = 0; by + s <= 200; by += s) {
          for (var bx = 0; bx + s <= 200; bx += s) {
            final first = _pixel(p, bx, by);
            for (var y = by; y < by + s; y++) {
              for (var x = bx; x < bx + s; x++) {
                expect(_pixel(p, x, y), first, reason: 'block $bx,$by @$size');
              }
            }
            final a = first & 0xFF;
            if (a > 0 && a < 255) partial++;
          }
        }
        // Edge blocks carry averaged coverage, not just on/off.
        expect(partial, greaterThan(0));
      }
    });

    test('a block averages what is drawn in it', () async {
      final e = filled();
      e.beginPixelate(10);
      e.rect(40, 40, 5, 10); // left half of the block at (40, 40)
      e.endPixelate();
      final p = await _pixels(e.renderQueue.execute);
      expect(_pixel(p, 42, 42) & 0xFF, closeTo(128, 4));
      expect(_pixel(p, 48, 48) & 0xFF, closeTo(128, 4));
    });

    test('transforms before and inside the scope land the shape', () async {
      void draw(Flut5Engine e) {
        e.translate(50, 30);
        e.push();
        e.translate(40, 60);
        e.rotate(math.pi / 5);
        e.scale(1.5, 1); // nonuniform: put on the canvas
        e.rect(-20, -10, 40, 20);
        e.pop();
      }

      final sharp = filled();
      draw(sharp);
      final reference = await _pixels(sharp.renderQueue.execute);

      final e = filled();
      e.translate(50, 30);
      e.beginPixelate(6);
      e.push();
      e.translate(40, 60);
      e.rotate(math.pi / 5);
      e.scale(1.5, 1);
      e.rect(-20, -10, 40, 20);
      e.pop();
      e.endPixelate();
      // The translate from before the scope still applies after it.
      e.rect(0, 0, 4, 4);
      final p = await _pixels(e.renderQueue.execute);

      final (rx, ry, rMass) = _centroid(reference, exclude: null);
      final (px, py, pMass) = _centroid(
        p,
        exclude: const Rect.fromLTWH(48, 28, 8, 8),
      );
      expect(px, closeTo(rx, 1.5));
      expect(py, closeTo(ry, 1.5));
      expect(pMass, closeTo(rMass, rMass * 0.03));
      expect(_pixel(p, 52, 32) & 0xFF, 255, reason: 'rect after the scope');
    });

    test('nested scopes pixelate on their own grids', () async {
      final e = filled();
      e.beginPixelate(4);
      e.rect(0, 0, 60, 60);
      e.beginPixelate(12);
      e.circle(130, 130, 90);
      e.endPixelate();
      e.endPixelate();
      final p = await _pixels(e.renderQueue.execute);
      for (var by = 84; by + 12 <= 180; by += 12) {
        for (var bx = 84; bx + 12 <= 180; bx += 12) {
          final first = _pixel(p, bx, by);
          for (var y = by; y < by + 12; y++) {
            for (var x = bx; x < bx + 12; x++) {
              expect(_pixel(p, x, y), first);
            }
          }
        }
      }
    });

    test('a scope left open is still drawn, closed at the end', () async {
      final e = filled();
      e.beginPixelate(10);
      e.rect(40, 40, 40, 40);
      final p = await _pixels(e.renderQueue.execute);
      expect(_pixel(p, 60, 60) & 0xFF, 255);
    });

    test('a block below one pixel draws the scope unpixelated', () async {
      final sharp = filled();
      sharp.circle(100, 100, 90);
      final e = filled();
      e.beginPixelate(0.5);
      e.circle(100, 100, 90);
      e.endPixelate();
      expect(
        await _pixels(e.renderQueue.execute),
        await _pixels(sharp.renderQueue.execute),
      );
    });

    test('blur inside a scope blurs, then pixelates', () async {
      final e = filled();
      e.beginPixelate(10);
      e.blur(6);
      e.rect(60, 60, 80, 80);
      e.noBlur();
      e.endPixelate();
      final p = await _pixels(e.renderQueue.execute);
      // The halo reaches the block just outside the square.
      expect(_pixel(p, 55, 100) & 0xFF, inExclusiveRange(0, 255));
    });
  });
}

Future<Uint8List> _pixels(void Function(Canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(200, 200);
  final data = await image.toByteData();
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

int _pixel(Uint8List p, int x, int y) {
  final o = (y * 200 + x) * 4;
  return p[o] << 24 | p[o + 1] << 16 | p[o + 2] << 8 | p[o + 3];
}

/// Alpha-weighted centre and total alpha, skipping [exclude].
(double, double, double) _centroid(Uint8List p, {required Rect? exclude}) {
  double sx = 0, sy = 0, mass = 0;
  for (var y = 0; y < 200; y++) {
    for (var x = 0; x < 200; x++) {
      if (exclude != null && exclude.contains(Offset(x + 0.5, y + 0.5))) {
        continue;
      }
      final a = p[(y * 200 + x) * 4 + 3].toDouble();
      sx += a * x;
      sy += a * y;
      mass += a;
    }
  }
  return (sx / mass, sy / mass, mass);
}
