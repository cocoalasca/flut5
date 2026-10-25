import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A batch paints all fills, then all strokes. That is only invisible while
  // no outlined shape is drawn over another one in the same batch.
  Flut5Engine outlined() => Flut5Engine()
    ..fill(Colors.white)
    ..stroke(Colors.red)
    ..strokeWeight(3);

  int items(Flut5Engine e) {
    e.renderQueue.flushPending();
    return e.renderQueue.itemCount;
  }

  group('Outlined shapes — overlap splits the batch', () {
    test('overlapping circles become separate items', () {
      final e = outlined();
      e.circle(50, 50, 40);
      e.circle(70, 50, 40);
      expect(items(e), 2);
    });

    test('the batch resumes after the split', () {
      final e = outlined();
      e.circle(50, 50, 40);
      e.circle(70, 50, 40); // lands on the first: new batch
      e.circle(200, 50, 40); // clear of the second: joins it
      expect(items(e), 2);
    });

    test('every primitive kind splits when it lands on the batch', () {
      void check(void Function(Flut5Engine e) draw) {
        final e = outlined();
        e.rect(0, 0, 100, 100);
        draw(e);
        expect(items(e), 2);
      }

      check((e) => e.rect(50, 50, 100, 100));
      check((e) => e.rect(50, 50, 100, 100, 8));
      check((e) => e.circle(100, 100, 40));
      check((e) => e.ellipse(100, 100, 60, 30));
      check((e) => e.arc(100, 100, 60, 60, 0, math.pi));
      check((e) => e.triangle(50, 50, 150, 50, 100, 150));
      check((e) => e.quad(50, 50, 150, 50, 150, 150, 50, 150));
      check((e) => e.polygon(100, 100, 6, 60));
      check((e) => e.star(100, 100, 20, 40, 5));
      check((e) {
        e.beginShape();
        e.vertex(50, 50);
        e.vertex(150, 60);
        e.vertex(90, 150);
        e.endShape(close: true);
      });
    });

    test('folded transforms are measured where the shape lands', () {
      final e = outlined();
      e.rect(0, 0, 100, 100);
      for (final draw in <void Function()>[
        () => e.rect(-20, -20, 40, 40),
        () => e.rect(-20, -20, 40, 40, 6),
        () => e.circle(0, 0, 40),
        () => e.ellipse(0, 0, 50, 30),
        () => e.triangle(-20, -20, 20, -20, 0, 20),
      ]) {
        // Away from the first rect: same batch.
        e.renderQueue.clear();
        e.rect(0, 0, 100, 100);
        e.push();
        e.translate(300, 300);
        e.rotate(.6);
        draw();
        e.pop();
        expect(items(e), 1);
        // Moved onto it: split.
        e.renderQueue.clear();
        e.rect(0, 0, 100, 100);
        e.push();
        e.translate(90, 90);
        e.rotate(.6);
        draw();
        e.pop();
        expect(items(e), 2);
      }
    });

    test('a shape drawn across a merged line splits to cover it', () {
      final e = outlined();
      e.rect(0, 0, 10, 10);
      e.line(20, 5, 80, 5);
      e.rect(40, 0, 10, 10);
      expect(items(e), 2);
    });

    test('huge and infinite coordinates neither throw nor merge', () {
      final e = outlined();
      e.circle(50, 50, 40);
      e.rect(0, 200, 1e300, 10);
      e.circle(double.infinity, 50, 40);
      e.circle(400, 400, 40);
      expect(items(e), 4);
    });
  });

  group('Outlined shapes — batches that stay whole', () {
    test('shapes apart from each other share one item', () {
      final e = outlined();
      for (var i = 0; i < 10; i++) {
        e.circle(i * 60.0, 50, 40);
      }
      expect(items(e), 1);
    });

    test('a tight grid of touching rects is one item', () {
      final e = outlined();
      for (var y = 0; y < 60; y++) {
        for (var x = 0; x < 60; x++) {
          e.rect(x * 10.0, y * 10.0, 10, 10);
        }
      }
      expect(items(e), 1);
    });

    test('thin bars packed along one axis are one item', () {
      final e = outlined();
      for (var x = 0; x < 2000; x++) {
        e.rect(x * 2.0, 0, 2, 300);
      }
      expect(items(e), 1);
    });

    test('non-overlapping circles drawn in scattered order are one item', () {
      final cells = [
        for (var y = 0; y < 50; y++)
          for (var x = 0; x < 50; x++) (x, y),
      ]..shuffle(math.Random(7));
      final e = outlined();
      for (final (x, y) in cells) {
        e.circle(x * 12.0 - 100, y * 12.0 - 100, 10);
      }
      expect(items(e), 1);
    });

    test('fill and stroke of the same colour never split', () {
      final e = Flut5Engine()
        ..fill(Colors.red)
        ..stroke(Colors.red)
        ..strokeWeight(3);
      e.circle(50, 50, 40);
      e.circle(70, 50, 40);
      expect(items(e), 1);
    });

    test('fill-only and stroke-only batches never split', () {
      final filled = Flut5Engine()
        ..fill(Colors.white)
        ..noStroke();
      filled.circle(50, 50, 40);
      filled.circle(70, 50, 40);
      expect(items(filled), 1);

      final stroked = Flut5Engine()
        ..noFill()
        ..stroke(Colors.red);
      stroked.circle(50, 50, 40);
      stroked.circle(70, 50, 40);
      expect(items(stroked), 1);
    });
  });

  group('Outlined shapes — rendered stacking', () {
    // Ground truth: each shape filled then stroked before the next one.
    Future<void> matchesPerShapeDrawing(List<Rect> ovals) async {
      final e = outlined();
      for (final o in ovals) {
        e.ellipse(o.center.dx, o.center.dy, o.width, o.height);
      }
      final actual = await _pixels((c) => e.renderQueue.execute(c));
      final fill = Paint()..color = Colors.white;
      final stroke = Paint()
        ..color = Colors.red
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      final expected = await _pixels((c) {
        for (final o in ovals) {
          final path = Path()..addOval(o);
          c.drawPath(path, fill);
          c.drawPath(path, stroke);
        }
      });
      var changed = 0;
      for (var i = 0; i < actual.length; i += 4) {
        for (var ch = 0; ch < 4; ch++) {
          if ((actual[i + ch] - expected[i + ch]).abs() > 16) {
            changed++;
            break;
          }
        }
      }
      // An earlier outline showing through a later fill moves whole arcs of
      // pixels; anti-aliasing where outlines merely meet moves almost none.
      expect(changed / (actual.length / 4), lessThan(.001));
    }

    test('two overlapping circles', () async {
      await matchesPerShapeDrawing([
        Rect.fromCircle(center: const Offset(120, 150), radius: 60),
        Rect.fromCircle(center: const Offset(180, 150), radius: 60),
      ]);
    });

    test('a scattered flood, sizes mixed, past the grid threshold', () async {
      final rnd = math.Random(3);
      await matchesPerShapeDrawing([
        for (var i = 0; i < 400; i++)
          Rect.fromCenter(
            center: Offset(rnd.nextDouble() * 300, rnd.nextDouble() * 300),
            width: 4 + rnd.nextDouble() * (i % 9 == 0 ? 90 : 18),
            height: 4 + rnd.nextDouble() * (i % 9 == 0 ? 90 : 18),
          ),
      ]);
    });

    test('a sparse flood that mostly stays batched', () async {
      final rnd = math.Random(11);
      await matchesPerShapeDrawing([
        for (var i = 0; i < 300; i++)
          Rect.fromCircle(
            center: Offset(rnd.nextDouble() * 300, rnd.nextDouble() * 300),
            radius: 4,
          ),
      ]);
    });
  });
}

Future<Uint8List> _pixels(void Function(Canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(300, 300);
  final data = await image.toByteData();
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
