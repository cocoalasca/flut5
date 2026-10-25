import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `blur()` is fill-style state: every draw under it is blurred on its own
/// and nothing batches while it is on. A plain fill carries the blur as a
/// mask filter; anything else gets a [BlurRenderItem] layer of its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Flut5Engine filled() => Flut5Engine()
    ..fill(Colors.white)
    ..noStroke();

  Flut5Engine outlined() => Flut5Engine()
    ..fill(Colors.white)
    ..stroke(Colors.red)
    ..strokeWeight(4);

  List<Flut5RenderItem> items(Flut5Engine e) {
    e.renderQueue.flushPending();
    return e.renderQueue.items;
  }

  Paint? fillOf(Flut5RenderItem item) => switch (item) {
    RectRenderItem(:final fillPaint) => fillPaint,
    CircleRenderItem(:final fillPaint) => fillPaint,
    EllipseRenderItem(:final fillPaint) => fillPaint,
    ArcRenderItem(:final fillPaint) => fillPaint,
    PathRenderItem(:final fillPaint) => fillPaint,
    _ => null,
  };

  bool maskBlurred(Flut5RenderItem item) => fillOf(item)?.maskFilter != null;

  group('Blur state', () {
    test('plain fills carry the blur as a mask filter, one item each', () {
      final e = filled()..blur(4);
      e.rect(0, 0, 10, 10);
      e.circle(50, 50, 10);
      e.ellipse(80, 50, 10, 6);
      e.arc(120, 50, 20, 20, 0, 90);
      e.triangle(0, 100, 10, 100, 5, 110);
      e.beginShape();
      e.vertex(0, 150);
      e.vertex(10, 150);
      e.vertex(5, 160);
      e.endShape();
      final queued = items(e);
      expect(queued, hasLength(6));
      for (final item in queued) {
        expect(item, isNot(isA<BlurRenderItem>()));
        expect(maskBlurred(item), isTrue, reason: '$item');
      }
    });

    test('a translucent fill takes the mask route too', () {
      final e = Flut5Engine()
        ..fill(const Color(0x80FF8000))
        ..noStroke()
        ..blur(4);
      e.circle(50, 50, 10);
      expect(maskBlurred(items(e).single), isTrue);
    });

    test('stroked shapes get a layer of their own', () {
      final e = outlined()..blur(4);
      e.rect(0, 0, 10, 10);
      e.circle(50, 50, 10);
      final queued = items(e);
      expect(queued, hasLength(2));
      for (final item in queued) {
        expect(item, isA<BlurRenderItem>());
        expect((item as BlurRenderItem).items, hasLength(1));
        expect(maskBlurred(item.items.single), isFalse);
      }
    });

    test('stroke-only shapes and shadowed fills keep the layer', () {
      final e = Flut5Engine()
        ..noFill()
        ..stroke(Colors.white)
        ..blur(4);
      e.rect(0, 0, 10, 10);
      e.fill(Colors.white);
      e.noStroke();
      e.shadow(2, 2, 4);
      e.rect(20, 0, 10, 10);
      final queued = items(e);
      expect(queued, hasLength(2));
      expect(queued.every((i) => i is BlurRenderItem), isTrue);
    });

    test('noBlur() resumes batching and keeps earlier shapes blurred', () {
      final e = filled()..blur(4);
      e.rect(0, 0, 10, 10);
      e.noBlur();
      e.rect(20, 0, 10, 10);
      e.rect(40, 0, 10, 10);
      final queued = items(e);
      expect(queued, hasLength(2));
      expect(maskBlurred(queued[0]), isTrue);
      expect(queued[1], isA<PathRenderItem>());
      expect(maskBlurred(queued[1]), isFalse);
    });

    test('blur() flushes the open batch so it stays sharp', () {
      final e = filled();
      e.rect(0, 0, 10, 10);
      e.rect(20, 0, 10, 10);
      e.blur(4);
      e.rect(40, 0, 10, 10);
      final queued = items(e);
      expect(queued, hasLength(2));
      expect(maskBlurred(queued[0]), isFalse);
      expect(maskBlurred(queued[1]), isTrue);
    });

    test('repeating the same blur() keeps the blurred paints', () {
      final e = filled()..blur(4);
      e.rect(0, 0, 10, 10);
      e.blur(4);
      e.rect(20, 0, 10, 10);
      final masked = items(e);
      expect(identical(fillOf(masked[0]), fillOf(masked[1])), isTrue);

      final o = outlined()..blur(4);
      o.rect(0, 0, 10, 10);
      o.blur(4);
      o.rect(20, 0, 10, 10);
      final layered = items(o).cast<BlurRenderItem>();
      expect(identical(layered[0].layerPaint, layered[1].layerPaint), isTrue);
    });

    test('a new radius rebuilds the mask filter', () {
      final e = filled()..blur(4);
      e.rect(0, 0, 10, 10);
      e.blur(8);
      e.rect(20, 0, 10, 10);
      final queued = items(e);
      expect(identical(fillOf(queued[0]), fillOf(queued[1])), isFalse);
    });

    test('blur(0) and invalid radii turn blur off', () {
      final e = filled()..blur(4);
      e.blur(0);
      expect(e.renderQueue.activeBlur, 0);
      e.blur(-3);
      expect(e.renderQueue.activeBlur, 0);
      e.blur(double.nan);
      expect(e.renderQueue.activeBlur, 0);
      e.rect(0, 0, 10, 10);
      e.rect(20, 0, 10, 10);
      expect(items(e).single, isA<PathRenderItem>());
    });

    test('blur survives the frame reset, like shadow()', () {
      final e = filled()..blur(4);
      e.renderQueue.clear();
      e.rect(0, 0, 10, 10);
      expect(maskBlurred(items(e).single), isTrue);
    });
  });

  group('What blur wraps', () {
    test('points and lines draw one by one', () {
      final e = Flut5Engine()
        ..stroke(Colors.white)
        ..strokeWeight(4)
        ..blur(2);
      e.point(0, 0);
      e.point(10, 0);
      e.line(0, 10, 20, 10);
      e.line(0, 20, 20, 20);
      final queued = items(e).cast<BlurRenderItem>();
      expect(queued, hasLength(4));
      expect(queued[0].items.single, isA<MultiPointRenderItem>());
      expect(
        (queued[0].items.single as MultiPointRenderItem).coords,
        hasLength(2),
      );
      expect(queued[2].items.single, isA<LineRenderItem>());
    });

    test('images skip the atlas and blur one by one', () {
      final img = Flut5Image.fromUiImage(_solidImage(8, 8));
      final e = Flut5Engine()..blur(2);
      e.image(img, 0, 0);
      e.image(img, 20, 0);
      final queued = items(e).cast<BlurRenderItem>();
      expect(queued, hasLength(2));
      expect(queued[0].items.single, isA<ImageRenderItem>());
    });

    test('a dashed shape blurs its fill and stroke as one', () {
      final e = outlined()
        ..setLineDash([4, 2])
        ..blur(2);
      e.rect(0, 0, 20, 20);
      final blurred = items(e).single as BlurRenderItem;
      expect(blurred.items, hasLength(2));
    });

    test('an explicit batch is one draw, so one layer', () {
      final e = outlined()
        ..setLineDash([4, 2])
        ..blur(2);
      e.beginBatch();
      e.rect(0, 0, 10, 10);
      e.rect(20, 0, 10, 10);
      e.endBatch();
      final blurred = items(e).single as BlurRenderItem;
      expect(blurred.items, hasLength(2));
    });

    test('backgrounds, clips and transforms are never wrapped', () {
      final e = outlined()..blur(4);
      e.background(Colors.black);
      e.push();
      e.applyMatrix([1, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
      e.clipRect(0, 0, 50, 50);
      e.rect(0, 0, 10, 10);
      e.pop();
      final queued = items(e);
      expect(queued.first, isA<BackgroundRenderItem>());
      expect(queued.whereType<ClipRenderItem>(), hasLength(1));
      expect(queued.whereType<BlurRenderItem>(), hasLength(1));
      expect(queued.last, isA<TransformRenderItem>());
    });

    test(
      'a folded rotation is put on the canvas so the blur scales with it',
      () {
        final e = filled()..blur(4);
        e.push();
        e.scale(2);
        e.rotate(math.pi / 6);
        e.rect(0, 0, 10, 10);
        e.pop();
        final queued = items(e);
        expect(queued.whereType<TransformRenderItem>(), isNotEmpty);
        final rect = queued.whereType<RectRenderItem>().single;
        // Drawn in its own local coordinates, not baked into the fold.
        expect(rect.bounds, const Rect.fromLTWH(0, 0, 10, 10));
        expect(maskBlurred(rect), isTrue);
      },
    );
  });

  group('Blur groups', () {
    test('markers bound the group and shapes inside still batch', () {
      final e = filled();
      e.rect(0, 0, 10, 10);
      e.beginBlur(4);
      e.rect(20, 0, 10, 10);
      e.rect(40, 0, 10, 10);
      e.endBlur();
      e.rect(60, 0, 10, 10);
      final queued = items(e);
      expect(queued.map((i) => i.runtimeType).toList(), [
        PathRenderItem,
        BlurBeginRenderItem,
        PathRenderItem,
        BlurEndRenderItem,
        PathRenderItem,
      ]);
      expect(
        queued.whereType<PathRenderItem>().every((i) => !maskBlurred(i)),
        isTrue,
      );
    });

    test('the group keeps its transforms to itself', () {
      final e = filled();
      e.beginBlur(4);
      e.translate(50, 0);
      e.rect(0, 0, 10, 10);
      e.endBlur();
      e.rect(0, 0, 10, 10);
      expect(items(e).last.bounds, const Rect.fromLTWH(0, 0, 10, 10));
    });

    test('repeating a radius reuses the layer paint; 0 only saves', () {
      final e = filled();
      e.beginBlur(4);
      e.endBlur();
      e.beginBlur(4);
      e.endBlur();
      e.beginBlur(0);
      e.endBlur();
      final begins = items(e).whereType<BlurBeginRenderItem>().toList();
      expect(identical(begins[0].layerPaint, begins[1].layerPaint), isTrue);
      expect(begins[2].layerPaint, isNull);
    });

    test('misuse throws, and scopes cannot cross', () {
      expect(() => filled().endBlur(), throwsFlutterError);
      expect(() => (filled()..beginBatch()).beginBlur(4), throwsFlutterError);
      final e = filled()
        ..environment = const SketchEnvironment().withSize(const Size(200, 200))
        ..beginBlur(4)
        ..beginPixelate(8);
      expect(e.endBlur, throwsFlutterError);
      e.endPixelate();
      e.endBlur();
    });

    test('an opening marker makes the split replay fall back', () {
      final e = filled();
      e.beginBlur(4);
      e.background(Colors.black);
      e.endBlur();
      expect(e.renderQueue.backgroundsPrecedeContent, isFalse);
    });
  });

  group('Blur pixels', () {
    test('a group blurs once, as one picture', () async {
      // Overlapping halos: the group must be the blur of both squares drawn
      // together, which is not what blurring each one gives.
      final e = outlined()..beginBlur(6);
      e.rect(40, 80, 40, 40);
      e.rect(90, 80, 40, 40);
      e.endBlur();
      final actual = await _pixels(e.renderQueue.execute);
      // Ground truth: the same two squares queued sharp, replayed inside one
      // blurred layer.
      final sharp = outlined();
      sharp.rect(40, 80, 40, 40);
      sharp.rect(90, 80, 40, 40);
      final expected = await _pixels((canvas) {
        canvas.saveLayer(
          null,
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: 6,
              sigmaY: 6,
              tileMode: TileMode.decal,
            ),
        );
        sharp.renderQueue.execute(canvas);
        canvas.restore();
      });
      expect(actual, expected);

      final perDraw = outlined()..blur(6);
      perDraw.rect(40, 80, 40, 40);
      perDraw.rect(90, 80, 40, 40);
      expect(await _pixels(perDraw.renderQueue.execute), isNot(expected));
    });

    test('a group left open is still drawn, closed at the end', () async {
      final e = filled()..beginBlur(6);
      e.rect(60, 60, 80, 80);
      final p = await _pixels(e.renderQueue.execute);
      expect(p[(100 * 200 + 100) * 4 + 3], 255);
      expect(p[(100 * 200 + 56) * 4 + 3], inExclusiveRange(0, 255));
      expect(e.renderQueue.items.last, isA<BlurEndRenderItem>());
    });

    test('a group inside a pixelate scope blurs, then pixelates', () async {
      final e = filled()
        ..environment = const SketchEnvironment().withSize(const Size(200, 200))
        ..beginPixelate(10)
        // Inside the scope the canvas draws at 1/10 scale, so this is a
        // 3-pixel blur there — Impeller's layer blur skips ones under a pixel.
        ..beginBlur(30);
      e.rect(60, 60, 80, 80);
      e.endBlur();
      e.endPixelate();
      final p = await _pixels(e.renderQueue.execute);
      // The halo reaches the block just outside the square, flat across it.
      final a = p[(100 * 200 + 55) * 4 + 3];
      expect(a, inExclusiveRange(0, 255));
      expect(p[(109 * 200 + 50) * 4 + 3], a);
      expect(p[(100 * 200 + 50) * 4 + 3], a);
    });

    test('each draw blurs alone, not the shapes as one picture', () async {
      // Two squares close enough for their halos to meet, the second also
      // stroked: the first is one mask-blurred fill, the second a layer of
      // its own — never one blur over both.
      void draw(Flut5Engine e) {
        e.rect(40, 80, 40, 40);
        e.stroke(Colors.red);
        e.strokeWeight(4);
        e.rect(90, 80, 40, 40);
      }

      final e = filled()..blur(6);
      draw(e);
      final actual = await _pixels(e.renderQueue.execute);
      final expected = await _pixels((canvas) {
        final white = Paint()..color = Colors.white;
        final red = Paint()
          ..color = Colors.red
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4;
        canvas.drawRect(
          const Rect.fromLTWH(40, 80, 40, 40),
          Paint.from(white)..maskFilter = const MaskFilter.blur(.normal, 6),
        );
        canvas.saveLayer(
          null,
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: 6,
              sigmaY: 6,
              tileMode: TileMode.decal,
            ),
        );
        canvas.drawRect(const Rect.fromLTWH(90, 80, 40, 40), white);
        canvas.drawRect(const Rect.fromLTWH(90, 80, 40, 40), red);
        canvas.restore();
      });
      expect(actual, expected);
    });

    test('bounding each layer to what it paints changes no pixel', () async {
      // On Skia an unbounded layer covers the canvas and is blurred whole;
      // the queue bounds it to the draw's stroke reach, shadow and halo.
      // Ground truth: the same items through an unbounded layer.
      void draw(Flut5Engine e) {
        e.strokeJoin(StrokeJoin.miter);
        e.triangle(30, 30, 90, 40, 40, 70); // sharp miter tips
        e.shadow(12, 8, 6, 3, Colors.blue);
        e.circle(130, 60, 40);
        e.noShadow();
        e.strokeWeight(9);
        e.strokeCap(StrokeCap.square);
        e.line(30, 140, 170, 170);
        e.point(100, 120);
      }

      for (final scale in [1.0, .75]) {
        final e = outlined()..blur(3);
        draw(e);
        final queued = items(e);
        expect(queued.whereType<BlurRenderItem>(), hasLength(4));
        final actual = await _pixels((canvas) {
          canvas.scale(scale);
          e.renderQueue.execute(canvas);
        });
        final expected = await _pixels((canvas) {
          canvas.scale(scale);
          for (final item in queued) {
            if (item is! BlurRenderItem) {
              item.execute(canvas);
              continue;
            }
            canvas.saveLayer(null, item.layerPaint);
            for (final inner in item.items) {
              inner.execute(canvas);
            }
            canvas.restore();
          }
        });
        expect(actual, expected, reason: 'scale $scale');
      }
    });

    test('a plain fill blurs like an exact Gaussian', () async {
      // White square on transparent: alpha is the square's coverage blurred
      // by a Gaussian of sigma = the radius, which integrates in closed form.
      const square = Rect.fromLTRB(50, 50, 150, 130);
      for (final sigma in [3.0, 6.0, 12.0]) {
        final e = filled()..blur(sigma);
        e.rect(square.left, square.top, square.width, square.height);
        final p = await _pixels(e.renderQueue.execute);
        final k = 1 / (sigma * math.sqrt2);
        var worst = 0.0;
        for (var y = 0; y < 200; y++) {
          for (var x = 0; x < 200; x++) {
            final cx = x + 0.5, cy = y + 0.5;
            final want =
                255 *
                0.25 *
                (_erf((square.right - cx) * k) - _erf((square.left - cx) * k)) *
                (_erf((square.bottom - cy) * k) - _erf((square.top - cy) * k));
            worst = math.max(worst, (p[(y * 200 + x) * 4 + 3] - want).abs());
          }
        }
        expect(worst, lessThan(8), reason: 'sigma $sigma');
      }
    });

    test('edges soften instead of clamping, on both routes', () async {
      for (final make in [filled, outlined]) {
        final e = make()..blur(6);
        e.rect(60, 60, 80, 80);
        final p = await _pixels(e.renderQueue.execute);
        // A few pixels outside the square: partly covered, not empty or solid.
        expect(p[(100 * 200 + 54) * 4 + 3], inExclusiveRange(0, 255));
        // Far outside: untouched.
        expect(p[(100 * 200 + 20) * 4 + 3], 0);
      }
    });
  });
}

ui.Image _solidImage(int width, int height) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.red,
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  picture.dispose();
  return image;
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

/// Abramowitz & Stegun 7.1.26 — |error| < 1.5e-7, far below a colour level.
double _erf(double x) {
  final t = 1 / (1 + 0.3275911 * x.abs());
  final y =
      1 -
      ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) *
                  t +
              0.254829592) *
          t *
          math.exp(-x * x);
  return x < 0 ? -y : y;
}
