// A sketch that changes colour with every shape used to get one draw call
// per shape. The render queue now leaves a batch open when another colour
// starts, and a later shape of its colour goes back into it when it keeps
// clear of everything drawn since. These tests pin that the frame comes
// out as its shapes drawn one by one, and that circles, ellipses and
// rounded rects — whose edges depend on what shares their path — batch
// exactly as they did before.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const int _width = 320;
const int _height = 240;

const _palette = [
  Color(0xFFE4572E),
  Color(0xFF17BEBB),
  Color(0xFFFFC914),
  Color(0xFF2E282A),
  Color(0xFF76B041),
  Color(0xFF8F5BD9),
];

/// How a scene is drawn: as the queue batches it, or as ground truth with
/// the batch closed after every shape or at every change of colour.
enum _Closing { never, afterEveryShape, atEveryColourChange }

/// One drawing of a scene. Scenes set colours through [fill] and call
/// [shapeDone] after each shape, so the ground-truth runs can close the
/// batch where they need to.
final class _Run(final Flut5Engine e, final _Closing closing) {
  Color? _lastFill;

  void fill(Color colour) {
    if (closing == .atEveryColourChange && colour != _lastFill) {
      e.renderQueue.flushPending();
    }
    _lastFill = colour;
    e.fill(colour);
  }

  void shapeDone() {
    if (closing == .afterEveryShape) e.renderQueue.flushPending();
  }
}

typedef _Scene = void Function(_Run run);

Future<(Uint8List, int)> _draw(_Scene scene, _Closing closing) async {
  final e = Flut5Engine();
  scene(_Run(e, closing));
  e.renderQueue.flushPending();
  final items = e.renderQueue.itemCount;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFFFFFFF), BlendMode.src);
  e.renderQueue.execute(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(_width, _height);
  picture.dispose();
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  return (bytes, items);
}

/// Draws [scene] batched and as [truth], expects the very same bytes, and
/// returns how many items the batched run took.
Future<int> _expectExactly(_Scene scene, _Closing truth) async {
  final (pixels, items) = await _draw(scene, .never);
  final (expected, _) = await _draw(scene, truth);
  expect(pixels, expected);
  return items;
}

/// [_expectExactly] against every shape drawn one by one, for scenes with
/// anti-aliased edges.
///
/// On Impeller a straight-edged shape rasterizes the same in a path of its
/// own as in one shared with others, so the bytes must match. Skia's
/// software rasterizer, which plain `flutter test` runs on, picks its
/// anti-aliasing by what else is in the path, so there the pixels along an
/// edge may differ — as they do for any batch. Every pixel away from an
/// edge must still match: a shape drawn in the wrong order would change
/// those.
Future<int> _expectSameShapes(_Scene scene) async {
  if (ui.ImageFilter.isShaderFilterSupported) {
    return _expectExactly(scene, .afterEveryShape);
  }
  final (pixels, items) = await _draw(scene, .never);
  final (expected, _) = await _draw(scene, .afterEveryShape);
  var compared = 0;
  for (var y = 1; y < _height - 1; y++) {
    for (var x = 1; x < _width - 1; x++) {
      if (!_awayFromEdges(expected, x, y)) continue;
      compared++;
      final offset = (y * _width + x) * 4;
      for (var channel = 0; channel < 4; channel++) {
        if (pixels[offset + channel] != expected[offset + channel]) {
          fail('pixel ($x, $y) differs away from any edge');
        }
      }
    }
  }
  expect(compared, greaterThan(_width * _height ~/ 4));
  return items;
}

/// Whether the pixel at ([x], [y]) and the eight around it are one colour.
bool _awayFromEdges(Uint8List pixels, int x, int y) {
  final center = (y * _width + x) * 4;
  for (var dy = -1; dy <= 1; dy++) {
    for (var dx = -1; dx <= 1; dx++) {
      final offset = ((y + dy) * _width + x + dx) * 4;
      for (var channel = 0; channel < 4; channel++) {
        if (pixels[offset + channel] != pixels[center + channel]) return false;
      }
    }
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shapes that keep apart draw as one batch per colour', () async {
    void scene(_Run run) {
      final random = math.Random(1);
      run.e.noStroke();
      for (var i = 0; i < 150; i++) {
        run.fill(_palette[random.nextInt(4)]);
        final x = 6.3 + (i % 15) * 20.0, y = 6.7 + (i ~/ 15) * 20.0;
        if (i.isEven) {
          run.e.rect(x, y, 9.5, 8.25);
        } else {
          run.e.triangle(x, y + 9, x + 5, y, x + 10, y + 9);
        }
        run.shapeDone();
      }
    }

    expect(await _expectSameShapes(scene), 4);
  });

  test('a shape touching one drawn since stays on top of it', () async {
    void scene(_Run run, double thirdX) {
      run.e.noStroke();
      run.fill(_palette[0]);
      run.e.rect(20, 20, 60, 60);
      run.shapeDone();
      run.fill(_palette[1]);
      run.e.rect(50, 50, 60, 60);
      run.shapeDone();
      run.fill(_palette[0]);
      run.e.rect(thirdX, 80, 60, 60);
      run.shapeDone();
    }

    // Over the second rect: a batch of its own, on top.
    expect(await _expectExactly((r) => scene(r, 80), .afterEveryShape), 3);
    // Clear of it: back into the first rect's batch.
    expect(await _expectExactly((r) => scene(r, 200), .afterEveryShape), 2);
  });

  test('shapes go back into a batch only when a few pixels clear', () async {
    void scene(_Run run, double gap) {
      run.e.noStroke();
      run.fill(_palette[0]);
      run.e.rect(20, 20, 40, 40);
      run.shapeDone();
      run.fill(_palette[1]);
      run.e.rect(100, 20, 40, 40);
      run.shapeDone();
      run.fill(_palette[0]);
      run.e.rect(140 + gap, 20, 40, 40);
      run.shapeDone();
    }

    // Edge anti-aliasing reaches past a shape's outline, so nearly touching
    // counts as touching.
    expect(await _expectExactly((r) => scene(r, 2), .afterEveryShape), 3);
    expect(await _expectExactly((r) => scene(r, 4), .afterEveryShape), 2);
  });

  test('overlapping shapes of many colours keep their order', () async {
    for (var seed = 0; seed < 8; seed++) {
      // Whole-pixel rects, so same-coloured ones overlapping in one path
      // fill exactly what they fill one by one, on any renderer.
      void scene(_Run run) {
        final random = math.Random(seed);
        run.e.noStroke();
        for (var i = 0; i < 400; i++) {
          run.fill(_palette[random.nextInt(_palette.length)]);
          run.e.rect(
            random.nextInt(_width - 20).toDouble(),
            random.nextInt(_height - 20).toDouble(),
            4.0 + random.nextInt(seed.isEven ? 30 : 8),
            4.0 + random.nextInt(seed.isEven ? 30 : 8),
          );
          run.shapeDone();
        }
      }

      final items = await _expectExactly(scene, .afterEveryShape);
      expect(items, lessThan(400), reason: 'seed $seed');
    }
  });

  test('anti-aliased, rotated and arc shapes come out the same', () async {
    for (var seed = 0; seed < 6; seed++) {
      // Shapes of one colour keep clear of each other — two overlapping in
      // one path are anti-aliased as one outline — while shapes of
      // different colours land wherever they like.
      void scene(_Run run) {
        final e = run.e;
        final random = math.Random(100 + seed);
        final placed = <(int, double, double)>[];
        e.noStroke();
        var drawn = 0;
        while (drawn < 220) {
          final colour = random.nextInt(_palette.length);
          final x = 12 + random.nextDouble() * (_width - 24);
          final y = 12 + random.nextDouble() * (_height - 24);
          final crowded = placed.any(
            (other) =>
                other.$1 == colour &&
                (other.$2 - x).abs() < 22 &&
                (other.$3 - y).abs() < 22,
          );
          if (crowded) continue;
          placed.add((colour, x, y));
          run.fill(_palette[colour]);
          switch (drawn % 6) {
            case 0:
              e.polygon(x, y, 5 + random.nextInt(4), 14);
            case 1:
              e.arc(x, y, 14, 12, 0.3, 4, ArcMode.pie);
            case 2:
              e.triangle(x - 6, y + 5, x, y - 6, x + 6, y + 5);
            case 3:
              e.arc(x, y, 14, 12, 0.3, 4, ArcMode.chord);
            case 4:
              e.star(x, y, 3, 7, 5);
            default:
              e.push();
              e.translate(x, y);
              e.rotate(random.nextDouble() * math.pi);
              e.rect(-5, -4, 10, 8);
              e.pop();
          }
          drawn++;
          run.shapeDone();
        }
      }

      final items = await _expectSameShapes(scene);
      expect(items, lessThan(220), reason: 'seed $seed');
    }
  });

  group('Circles, ellipses and rounded rects', () {
    // In a path of its own the canvas draws one with its renderer for that
    // shape, whose edges differ from a path's. So they must share a path
    // with exactly the shapes they always did: the ones of their colour
    // drawn right before and after.
    void curvedShape(Flut5Engine e, int kind, double x, double y) {
      switch (kind % 3) {
        case 0:
          e.circle(x, y, 9);
        case 1:
          e.ellipse(x, y, 12, 7);
        default:
          e.rect(x - 5, y - 4, 10, 8, 3);
      }
    }

    test('batch exactly as they did before', () async {
      void scene(_Run run) {
        final random = math.Random(2);
        run.e.noStroke();
        for (var i = 0; i < 150; i++) {
          run.fill(_palette[random.nextInt(3)]);
          curvedShape(run.e, i, 12 + (i % 15) * 20.0, 12 + (i ~/ 15) * 20.0);
          run.shapeDone();
        }
      }

      final items = await _expectExactly(scene, .atEveryColourChange);
      final (_, itemsBefore) = await _draw(scene, .atEveryColourChange);
      expect(items, itemsBefore);
    });

    test('rotated or scaled, too', () async {
      void scene(_Run run) {
        final random = math.Random(3);
        run.e.noStroke();
        for (var i = 0; i < 90; i++) {
          run.fill(_palette[random.nextInt(3)]);
          run.e.push();
          run.e.translate(14 + (i % 10) * 30.0, 14 + (i ~/ 10) * 25.0);
          run.e.rotate(i * 0.2);
          run.e.scale(1.3);
          curvedShape(run.e, i, 0, 0);
          run.e.pop();
          run.shapeDone();
        }
      }

      final items = await _expectExactly(scene, .atEveryColourChange);
      final (_, itemsBefore) = await _draw(scene, .atEveryColourChange);
      expect(items, itemsBefore);
    });

    test('nothing goes back into a batch that holds one', () async {
      void scene(_Run run, {required bool circleFirst}) {
        run.e.noStroke();
        run.fill(_palette[0]);
        if (circleFirst) {
          run.e.circle(40, 40, 30);
        } else {
          run.e.rect(25, 25, 30, 30);
        }
        run.shapeDone();
        run.fill(_palette[1]);
        run.e.rect(100, 25, 30, 30);
        run.shapeDone();
        run.fill(_palette[0]);
        run.e.rect(200, 25, 30, 30);
        run.shapeDone();
      }

      expect(
        await _expectExactly(
          (r) => scene(r, circleFirst: true),
          .atEveryColourChange,
        ),
        3,
      );
      expect(
        await _expectExactly(
          (r) => scene(r, circleFirst: false),
          .afterEveryShape,
        ),
        2,
      );
    });

    test('one joining the newest batch closes it at the next colour', () async {
      void scene(_Run run) {
        run.e.noStroke();
        run.fill(_palette[0]);
        run.e.rect(20, 20, 20, 20);
        run.shapeDone();
        run.fill(_palette[1]);
        run.e.rect(60, 20, 20, 20);
        run.shapeDone();
        // Same colour as the newest batch: shares its path, as before.
        run.e.circle(110, 30, 20);
        run.shapeDone();
        run.fill(_palette[0]);
        run.e.rect(150, 20, 20, 20);
        run.shapeDone();
        run.fill(_palette[1]);
        run.e.rect(190, 20, 20, 20);
        run.shapeDone();
      }

      // Two rects and a circle in one path, then the last two rects.
      expect(await _expectExactly(scene, .atEveryColourChange), 4);
    });
  });

  test('outlined, translucent and line shapes in between', () async {
    void scene(_Run run) {
      final e = run.e;
      final random = math.Random(9);
      for (var i = 0; i < 160; i++) {
        final x = (10 + random.nextDouble() * (_width - 40)).roundToDouble();
        final y = (10 + random.nextDouble() * (_height - 40)).roundToDouble();
        run.fill(_palette[random.nextInt(_palette.length)]);
        switch (i % 8) {
          case 3:
            e.stroke(_palette[3]);
            e.strokeWeight(2);
            e.rect(x, y, 18, 14);
            e.noStroke();
          case 5:
            run.fill(_palette[1].withValues(alpha: 0.5));
            e.rect(x, y, 22, 22);
          case 7:
            e.stroke(_palette[4]);
            e.strokeWeight(1);
            e.line(x, y, x + 20, y + 9);
            e.noStroke();
          default:
            e.noStroke();
            e.rect(x, y, 16, 12);
        }
        run.shapeDone();
      }
    }

    await _expectExactly(scene, .afterEveryShape);
  });

  test('shapes under a shadow close the batch at every colour', () async {
    void scene(_Run run) {
      run.e.noStroke();
      run.e.shadow(3, 4, 2, const Color(0x88000000));
      for (var i = 0; i < 12; i++) {
        run.fill(_palette[i % 3]);
        run.e.rect(10 + i * 25.0, 20, 14, 14);
        run.shapeDone();
      }
    }

    expect(await _expectExactly(scene, .atEveryColourChange), 12);
  });

  test('a colour of its own per shape still draws every shape', () async {
    void scene(_Run run) {
      run.e.noStroke();
      for (var i = 0; i < 300; i++) {
        run.fill(Color.fromARGB(255, i % 256, (i * 7) % 256, 255 - i % 200));
        run.e.rect((i % 20) * 14.0, (i ~/ 20) * 14.0, 16, 16);
        run.shapeDone();
      }
    }

    expect(await _expectExactly(scene, .afterEveryShape), 300);
  });

  test('colours batch again after a stretch of one-off colours', () async {
    void scene(_Run run) {
      final random = math.Random(6);
      run.e.noStroke();
      // More one-off colours in a row than the queue keeps batches open
      // for: it stops trying for a while.
      for (var i = 0; i < 400; i++) {
        run.fill(Color.fromARGB(255, i % 256, 255 - i ~/ 2, (i * 9) % 256));
        run.e.rect((i % 40) * 8.0, (i ~/ 40) * 3.0, 6, 2);
        run.shapeDone();
      }
      for (var i = 0; i < 6000; i++) {
        run.fill(_palette[random.nextInt(_palette.length)]);
        run.e.rect((i % 40) * 8.0, 40 + (i ~/ 40) * 8.0, 2, 2);
        run.shapeDone();
      }
    }

    // Every shape its own item would be 6400.
    final items = await _expectExactly(scene, .afterEveryShape);
    expect(items, lessThan(3000));
  });

  test('a palette of many colours fits the open batches', () async {
    void scene(_Run run) {
      run.e.noStroke();
      for (var i = 0; i < 3000; i++) {
        final colour = (i * 37) % 200;
        run.fill(Color.fromARGB(255, colour, 255 - colour, (colour * 5) % 256));
        run.e.rect((i % 40) * 8.0, (i ~/ 40) * 8.0, 2, 2);
        run.shapeDone();
      }
    }

    expect(await _expectExactly(scene, .afterEveryShape), 200);
  });

  test('the same fill colour comes back as the same paint', () {
    final e = Flut5Engine();
    e.fill(_palette[0]);
    final first = e.snapshotFillPaint();
    e.fill(_palette[1]);
    final other = e.snapshotFillPaint();
    e.fill(_palette[0]);
    expect(identical(e.snapshotFillPaint(), first), isTrue);
    expect(identical(other, first), isFalse);
    expect(first!.color.toARGB32(), _palette[0].toARGB32());
    expect(other!.color.toARGB32(), _palette[1].toARGB32());

    // A snapshot carries the blend mode, so a new mode means new paints.
    e.blendMode(BlendMode.multiply);
    final blended = e.snapshotFillPaint();
    expect(identical(blended, first), isFalse);
    expect(blended!.blendMode, BlendMode.multiply);
    expect(first.blendMode, BlendMode.srcOver);
  });
}
