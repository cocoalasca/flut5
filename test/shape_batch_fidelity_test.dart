import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Draw = void Function(Flut5Engine e);

/// A batch must look exactly like its shapes drawn one at a time. These pin
/// the cases where one merged path would not: fills that wind opposite ways,
/// gradients under a folded translate, and the paths that used to skip the
/// batch altogether.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Flut5Engine filled() => Flut5Engine()
    ..fill(Colors.white)
    ..noStroke();

  int items(Flut5Engine e) {
    e.renderQueue.flushPending();
    return e.renderQueue.itemCount;
  }

  /// Draws [shapes] through one queue and, as ground truth, each through a
  /// queue of its own; the two pictures must match. Returns the item count
  /// of the shared queue.
  Future<int> matchesOneByOne(
    List<_Draw> shapes, {
    Flut5Engine Function()? style,
  }) async {
    final make = style ?? filled;
    final together = make();
    for (final draw in shapes) {
      draw(together);
    }
    final count = items(together);
    final actual = await _pixels(together.renderQueue.execute);
    final expected = await _pixels((canvas) {
      for (final draw in shapes) {
        final alone = make();
        draw(alone);
        alone.renderQueue.execute(canvas);
      }
    });
    // A hole where two shapes overlap is thousands of pixels; where their
    // edges merely cross, anti-aliasing moves a handful.
    expect(_changed(actual, expected), lessThan(40));
    return count;
  }

  void polygonThrough(Flut5Engine e, List<double> xy, {bool close = true}) {
    e.beginShape();
    for (var i = 0; i < xy.length; i += 2) {
      e.vertex(xy[i], xy[i + 1]);
    }
    e.endShape(close: close);
  }

  group('Fill batches — shapes wound opposite ways', () {
    // Each pair overlaps and is given in opposite directions. Merged as-is
    // their windings cancel and the overlap turns into a hole.
    final oneBatch = <String, List<_Draw>>{
      'triangles': [
        (e) => e.triangle(20, 20, 120, 20, 70, 120),
        (e) => e.triangle(60, 40, 110, 140, 160, 40),
      ],
      'rect with negative width': [
        (e) => e.rect(20, 20, 100, 100),
        (e) => e.rect(160, 60, -100, 100),
      ],
      'rect with negative height': [
        (e) => e.rect(20, 20, 100, 100),
        (e) => e.rect(60, 160, 100, -100),
      ],
      'rect with both negative': [
        (e) => e.rect(20, 20, 100, 100),
        (e) => e.rect(160, 160, -100, -100),
      ],
      'ellipse with negative width': [
        (e) => e.ellipse(70, 70, 100, 100),
        (e) => e.ellipse(110, 110, -100, 80),
      ],
      'circle with negative diameter': [
        (e) => e.circle(70, 70, 100),
        (e) => e.circle(110, 110, -100),
      ],
      'quads': [
        (e) => e.quad(20, 20, 120, 20, 120, 120, 20, 120),
        (e) => e.quad(60, 60, 60, 160, 160, 160, 160, 60),
      ],
      'polygon and triangle': [
        (e) => e.polygon(80, 80, 6, 120),
        (e) => e.triangle(60, 60, 100, 170, 170, 60),
      ],
      'star and quad': [
        (e) => e.star(80, 80, 50, 120, 5),
        (e) => e.quad(70, 70, 70, 170, 170, 170, 170, 70),
      ],
      'vertex polygons': [
        (e) => polygonThrough(e, [20, 20, 120, 20, 120, 120, 20, 120]),
        (e) => polygonThrough(e, [60, 60, 60, 160, 160, 160, 160, 60]),
      ],
      'open vertex polygons': [
        (e) => polygonThrough(e, [20, 20, 120, 20, 70, 120], close: false),
        (e) => polygonThrough(e, [60, 40, 110, 140, 160, 40], close: false),
      ],
      'rotated triangle over a rect': [
        (e) => e.rect(20, 20, 100, 100),
        (e) {
          e.push();
          e.translate(110, 110);
          e.rotate(.5);
          e.triangle(-50, -40, 0, 50, 50, -40);
          e.pop();
        },
      ],
      'TRIANGLES mode, mixed directions in one shape': [
        (e) {
          e.beginShape(ShapeMode.triangles);
          e.vertex(20, 20);
          e.vertex(120, 20);
          e.vertex(70, 120);
          e.vertex(60, 40);
          e.vertex(110, 140);
          e.vertex(160, 40);
          e.endShape();
        },
      ],
      'triangle strip over a rect': [
        (e) => e.rect(40, 40, 100, 60),
        (e) {
          e.beginShape(ShapeMode.triangleStrip);
          for (var i = 0; i < 6; i++) {
            e.vertex(20 + i * 30.0, i.isEven ? 60 : 130);
          }
          e.endShape();
        },
      ],
      'triangle fan over a rect': [
        (e) => e.rect(40, 40, 100, 60),
        (e) {
          e.beginShape(ShapeMode.triangleFan);
          e.vertex(90, 110);
          e.vertex(150, 70);
          e.vertex(110, 60);
          e.vertex(60, 70);
          e.vertex(40, 130);
          e.endShape();
        },
      ],
      'QUADS mode over a rect': [
        (e) => e.rect(20, 20, 100, 100),
        (e) {
          e.beginShape(ShapeMode.quads);
          e.vertex(60, 60);
          e.vertex(60, 160);
          e.vertex(160, 160);
          e.vertex(160, 60);
          e.endShape();
        },
      ],
    };
    for (final MapEntry(key: name, value: shapes) in oneBatch.entries) {
      test('$name fill their overlap and stay one item', () async {
        expect(await matchesOneByOne(shapes), 1);
      });
    }

    // No single direction describes these, so the batch has to close instead.
    final mustSplit = <String, List<_Draw>>{
      'a bow-tie quad': [
        (e) => e.rect(40, 40, 120, 80),
        (e) => e.quad(20, 20, 180, 140, 180, 20, 20, 140),
      ],
      'a self-crossing vertex polygon': [
        (e) => e.rect(40, 40, 120, 80),
        (e) => polygonThrough(e, [20, 20, 180, 140, 180, 20, 20, 140]),
      ],
      'a pie swept backwards': [
        (e) => e.rect(20, 20, 100, 100),
        (e) => e.arc(110, 110, 120, 120, 4.5, 3.2, ArcMode.pie),
      ],
      'a chord swept backwards': [
        (e) => e.rect(20, 20, 100, 100),
        (e) => e.arc(110, 110, 120, 120, 5.5, 2.5, ArcMode.chord),
      ],
      'a counter-clockwise bezier shape': [
        (e) => e.rect(20, 20, 100, 100),
        (e) {
          e.beginShape();
          e.vertex(60, 60);
          e.bezierVertex(40, 120, 60, 170, 110, 170);
          e.bezierVertex(160, 170, 170, 110, 160, 60);
          e.endShape(close: true);
        },
      ],
      'a shape with a contour': [
        (e) => e.rect(20, 20, 100, 100),
        (e) {
          e.beginShape();
          e.vertex(60, 60);
          e.vertex(180, 60);
          e.vertex(180, 180);
          e.vertex(60, 180);
          e.beginContour();
          e.vertex(80, 80);
          e.vertex(80, 110);
          e.vertex(110, 110);
          e.vertex(110, 80);
          e.endContour();
          e.endShape(close: true);
        },
      ],
      'a rounded rect with negative width': [
        (e) => e.rect(20, 20, 100, 100),
        (e) => e.rect(160, 60, -100, 100, 12),
      ],
    };
    for (final MapEntry(key: name, value: shapes) in mustSplit.entries) {
      test('$name over another shape draws on its own', () async {
        expect(await matchesOneByOne(shapes), 2);
      });
    }

    test('shapes that cannot be measured still batch while apart', () {
      final e = filled();
      for (var i = 0; i < 40; i++) {
        final x = (i % 8) * 40.0, y = (i ~/ 8) * 40.0;
        e.beginShape();
        e.vertex(x, y);
        e.bezierVertex(x + 10, y + 30, x + 20, y + 30, x + 30, y);
        e.endShape(close: true);
      }
      expect(items(e), 1);
    });

    test('a clockwise shape only avoids the unmeasured ones', () {
      final e = filled();
      e.beginShape();
      e.vertex(300, 300);
      e.bezierVertex(310, 330, 320, 330, 330, 300);
      e.endShape(close: true);
      // These overlap each other, not the curve: they simply add up.
      e.rect(0, 0, 100, 100);
      e.rect(50, 50, 100, 100);
      expect(items(e), 1);
      // This one lands on the curve.
      e.rect(290, 290, 60, 60);
      expect(items(e), 2);
    });

    test('stroke-only shapes never split, whichever way they wind', () async {
      Flut5Engine stroked() => Flut5Engine()
        ..noFill()
        ..stroke(Colors.white)
        ..strokeWeight(3);
      final count = await matchesOneByOne([
        (e) => e.triangle(20, 20, 120, 20, 70, 120),
        (e) => e.triangle(60, 40, 110, 140, 160, 40),
        (e) => e.quad(20, 20, 180, 140, 180, 20, 20, 140),
      ], style: stroked);
      expect(count, 1);
    });

    test('stroked shapes are never rewritten — they split instead', () async {
      // A stroke anti-aliases differently when its path runs the other way,
      // so a stroked counter-clockwise shape keeps its direction and stays
      // off the shapes it overlaps. Same colour for fill and stroke, so the
      // outline-stacking rule is not what splits these.
      Flut5Engine oneColour() => Flut5Engine()
        ..fill(Colors.white)
        ..stroke(Colors.white)
        ..strokeWeight(4);
      final pairs = <List<_Draw>>[
        [
          (e) => e.triangle(20, 20, 120, 20, 70, 120),
          (e) => e.triangle(60, 40, 110, 140, 160, 40),
        ],
        [
          (e) => e.rect(20, 20, 100, 100),
          (e) => e.rect(160, 60, -100, 100),
        ],
        [
          (e) => e.ellipse(70, 70, 100, 100),
          (e) => e.ellipse(110, 110, -100, 80),
        ],
        [
          (e) => polygonThrough(e, [20, 20, 120, 20, 120, 120, 20, 120]),
          (e) => polygonThrough(e, [60, 60, 60, 160, 160, 160, 160, 60]),
        ],
      ];
      for (final pair in pairs) {
        expect(await matchesOneByOne(pair, style: oneColour), 2);
      }
      // Wound the same way they simply add up.
      expect(
        await matchesOneByOne([
          (e) => e.triangle(20, 20, 120, 20, 70, 120),
          (e) => e.triangle(60, 40, 160, 40, 110, 140),
        ], style: oneColour),
        1,
      );
    });

    test('a counter-clockwise polygon renders the same written backwards',
        () async {
      // The queue reverses these; lone shapes must not move a pixel for it.
      for (final style in <Flut5Engine Function()>[
        filled,
        () => Flut5Engine()
          ..fill(Colors.white)
          ..stroke(Colors.red)
          ..strokeWeight(5)
          ..strokeJoin(StrokeJoin.miter),
      ]) {
        final e = style();
        e.triangle(30.5, 20.25, 90.75, 160.5, 170.25, 40.5);
        final forward = Path()
          ..moveTo(30.5, 20.25)
          ..lineTo(90.75, 160.5)
          ..lineTo(170.25, 40.5)
          ..close();
        final fill = e.snapshotFillPaint(), stroke = e.snapshotStrokePaint();
        final actual = await _pixels(e.renderQueue.execute);
        final expected = await _pixels((c) {
          c.drawPath(forward, fill!);
          if (stroke != null) c.drawPath(forward, stroke);
        });
        expect(actual, expected);
      }
    });
  });

  group('Gradients under a folded translate', () {
    const gradient = LinearGradient(colors: [Colors.red, Colors.blue]);

    /// The same drawing under `translate()` and under a real canvas
    /// translate must match: the gradient moves with its shape.
    Future<void> followsTranslate(_Draw style, _Draw draw) async {
      final folded = Flut5Engine();
      style(folded);
      folded.push();
      folded.translate(60, 30);
      draw(folded);
      folded.pop();

      final raw = Flut5Engine();
      style(raw);
      raw.renderQueue.enqueue(TransformRenderItem.push());
      raw.renderQueue.enqueue(TransformRenderItem.translate(60, 30));
      draw(raw);
      raw.renderQueue.enqueue(TransformRenderItem.pop());

      final actual = await _pixels(folded.renderQueue.execute);
      final expected = await _pixels(raw.renderQueue.execute);
      expect(_changed(actual, expected), 0);
      // And the gradient is really there, not one flat colour.
      expect(_pixel(actual, 65, 60), isNot(_pixel(actual, 150, 60)));
    }

    test('auto-sized fill gradient', () async {
      await followsTranslate(
        (e) => e
          ..noStroke()
          ..fill(gradient),
        (e) => e.rect(0, 0, 100, 60),
      );
    });

    test('fill gradient with an explicit rect', () async {
      await followsTranslate(
        (e) => e
          ..noStroke()
          ..fill(gradient, 0, 0, 100, 60),
        (e) => e.ellipse(50, 30, 100, 60),
      );
    });

    test('stroke gradient', () async {
      await followsTranslate(
        (e) => e
          ..noFill()
          ..strokeWeight(12)
          ..stroke(gradient),
        (e) => e.line(0, 30, 100, 30),
      );
    });

    test('solid shapes still fold the translate away', () {
      final e = filled();
      for (var i = 0; i < 10; i++) {
        e.push();
        e.translate(i * 20.0, 0);
        e.rect(0, 0, 10, 10);
        e.pop();
      }
      expect(items(e), 1);
    });
  });

  group('Chord arcs', () {
    void chord(Flut5Engine e, double x) =>
        e.arc(x, 50, 30, 30, 0, 2, ArcMode.chord);

    test('batch like the other arc modes', () {
      final e = filled();
      for (var i = 0; i < 10; i++) {
        chord(e, i * 40.0);
      }
      expect(items(e), 1);
    });

    test('fold push/translate/rotate instead of emitting transforms', () {
      final e = filled();
      for (var i = 0; i < 10; i++) {
        e.push();
        e.translate(i * 40.0, 0);
        e.rotate(.3);
        chord(e, 0);
        e.pop();
      }
      expect(items(e), 1);
      expect(e.renderQueue.items.single, isA<PathRenderItem>());
    });

    test('cast the active shadow', () {
      final e = filled()..shadow(2, 2, 4);
      chord(e, 50);
      e.renderQueue.flushPending();
      expect((e.renderQueue.items.single as PathRenderItem).shadow, isNotNull);
    });

    test('look the same as before, drawn alone', () async {
      final e = filled();
      chord(e, 50);
      final path = Path()
        ..arcTo(Rect.fromCenter(center: const Offset(50, 50), width: 30, height: 30), 0, 2, true)
        ..close();
      final paint = e.snapshotFillPaint()!;
      expect(
        await _pixels(e.renderQueue.execute),
        await _pixels((c) => c.drawPath(path, paint)),
      );
    });
  });

  group('Style calls that change nothing', () {
    int restyled(_Draw restyle) {
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..stroke(Colors.red)
        ..strokeWeight(2)
        ..strokeCap(StrokeCap.square)
        ..strokeJoin(StrokeJoin.bevel);
      for (var i = 0; i < 10; i++) {
        restyle(e);
        e.rect(i * 30.0, 0, 10, 10);
      }
      return items(e);
    }

    test('keep the batch', () {
      expect(restyled((e) => e.fill(Colors.white)), 1);
      expect(restyled((e) => e.stroke(Colors.red)), 1);
      expect(restyled((e) => e.strokeWeight(2)), 1);
      expect(restyled((e) => e.strokeCap(StrokeCap.square)), 1);
      expect(restyled((e) => e.strokeJoin(StrokeJoin.bevel)), 1);
      expect(restyled((e) => e.noLineDash()), 1);
      expect(restyled((e) => e.setLineDash([])), 1);
      expect(
        restyled((e) {
          e.fill(Colors.white);
          e.stroke(Colors.red);
          e.strokeWeight(2);
        }),
        1,
      );
    });

    test('noFill and noStroke repeated keep the batch', () {
      final e = Flut5Engine()
        ..noFill()
        ..stroke(Colors.red);
      for (var i = 0; i < 10; i++) {
        e.noFill();
        e.rect(i * 30.0, 0, 10, 10);
      }
      expect(items(e), 1);
      final f = filled();
      for (var i = 0; i < 10; i++) {
        f.noStroke();
        f.rect(i * 30.0, 0, 10, 10);
      }
      expect(items(f), 1);
    });

    test('real changes still split it', () {
      var flip = false;
      expect(
        restyled((e) => e.fill((flip = !flip) ? Colors.blue : Colors.white)),
        10,
      );
      var w = 2.0;
      expect(restyled((e) => e.strokeWeight(w += 1)), 10);
      flip = false;
      expect(
        restyled(
          (e) => e.strokeCap((flip = !flip) ? StrokeCap.butt : StrokeCap.round),
        ),
        10,
      );
    });

    test('a value assigned to the public field still reaches the paint', () {
      final e = filled()..stroke(Colors.white);
      e.fillColor = Colors.red; // bypasses fill(): the paint is still white
      e.fill(Colors.red);
      expect(e.snapshotFillPaint()!.color.toARGB32(), Colors.red.toARGB32());
      e.strokeColor = Colors.blue;
      e.stroke(Colors.blue);
      expect(e.snapshotStrokePaint()!.color.toARGB32(), Colors.blue.toARGB32());
      e.strokeWeightVal = 7;
      e.strokeWeight(7);
      expect(e.snapshotStrokePaint()!.strokeWidth, 7);
    });

    test('re-applying a gradient keeps its per-shape paints', () {
      const gradient = LinearGradient(colors: [Colors.red, Colors.blue]);
      const rect = Rect.fromLTWH(10, 10, 50, 50);
      final e = Flut5Engine()
        ..noStroke()
        ..fill(gradient);
      final paint = e.snapshotFillPaintForShape(rect);
      // A sketch calls fill() every frame, often with a freshly built but
      // equal gradient. The shader must not be rebuilt for it.
      e.fill(LinearGradient(colors: [Colors.red, Colors.blue].toList()));
      expect(identical(e.snapshotFillPaintForShape(rect), paint), isTrue);
      e.fill(const LinearGradient(colors: [Colors.red, Colors.green]));
      expect(identical(e.snapshotFillPaintForShape(rect), paint), isFalse);
    });
  });

  group('Vertex shapes the queue keeps', () {
    // Batched shapes are built in one reused path and copied out. Shapes the
    // queue holds on to (unbatchable paint, dashes) must each get their own.
    void blob(Flut5Engine e, double x) {
      e.beginShape();
      e.vertex(x, 10);
      e.vertex(x + 30, 10);
      e.vertex(x + 15, 40);
      e.endShape(close: true);
    }

    test('translucent shapes keep their own geometry', () {
      final e = Flut5Engine()
        ..fill(Colors.white.withValues(alpha: .5))
        ..noStroke();
      blob(e, 0);
      blob(e, 100);
      e.renderQueue.flushPending();
      final bounds = [for (final item in e.renderQueue.items) item.bounds];
      expect(bounds, const [
        Rect.fromLTRB(0, 10, 30, 40),
        Rect.fromLTRB(100, 10, 130, 40),
      ]);
    });

    test('dashed shapes keep their own geometry', () {
      final e = Flut5Engine()
        ..noFill()
        ..stroke(Colors.white)
        ..setLineDash([4, 4]);
      blob(e, 0);
      blob(e, 100);
      e.renderQueue.flushPending();
      final lefts = [for (final item in e.renderQueue.items) item.bounds!.left];
      expect(lefts, [0, 100]);
    });

    test('batched shapes land where they were drawn', () {
      final e = filled();
      for (var i = 0; i < 5; i++) {
        blob(e, i * 50.0);
      }
      expect(items(e), 1);
      expect(
        e.renderQueue.items.single.bounds,
        const Rect.fromLTRB(0, 10, 230, 40),
      );
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

/// Pixels whose colour differs by more than anti-aliasing noise.
int _changed(Uint8List a, Uint8List b) {
  var changed = 0;
  for (var i = 0; i < a.length; i += 4) {
    for (var ch = 0; ch < 4; ch++) {
      if ((a[i + ch] - b[i + ch]).abs() > 16) {
        changed++;
        break;
      }
    }
  }
  return changed;
}

int _pixel(Uint8List p, int x, int y) {
  final o = (y * 200 + x) * 4;
  return p[o] << 24 | p[o + 1] << 16 | p[o + 2] << 8 | p[o + 3];
}
