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

  group('Palette', () {
    setUpAll(Flut5Shaders.load);

    const red = Color(0xFFFF0000);
    const blue = Color(0xFF0000FF);
    const purple = Color(0xFF800080);
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);

    test('the shader loaded', () {
      expect(Flut5Shaders.palette, isNotNull);
    });

    test('every block takes a palette colour', () async {
      const palette = [black, white, red, blue];
      final e = filled();
      e.beginPixelate(10, palette);
      e.background(const Color(0xFF202020));
      e.fill(const Color(0xFFE01010));
      e.circle(100, 100, 120);
      e.fill(const Color(0xFF3030F0));
      e.rect(10, 10, 40, 40);
      e.endPixelate();
      final p = await _pixels(e.renderQueue.execute);
      final allowed = palette.map(_packed).toSet();
      final seen = <int>{};
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 200; x++) {
          final px = _pixel(p, x, y);
          expect(allowed, contains(px), reason: '($x, $y)');
          seen.add(px);
        }
      }
      expect(seen, {_packed(black), _packed(red), _packed(blue)});
    });

    test('a block takes the colour nearest its average', () async {
      final e = filled();
      e.beginPixelate(10, const [red, blue, purple, black]);
      e.background(black);
      e.fill(red);
      e.rect(40, 40, 5, 10);
      e.fill(blue);
      e.rect(45, 40, 5, 10);
      e.endPixelate();
      final p = await _pixels(e.renderQueue.execute);
      expect(_pixel(p, 45, 45), _packed(purple));
      expect(_pixel(p, 25, 25), _packed(black));
    });

    test('nearest is judged by eye, not by RGB distance', () async {
      const target = Color(0xFF00FF66);
      const darker = Color(0xFF00CC66); // nearest in RGB
      const lighter = Color(0xFF66FF00); // nearest in OKLab: same lightness
      expect(_nearestRgb(target, const [darker, lighter]), darker);
      expect(_nearestOklab(target, const [darker, lighter]), lighter);
      final e = filled()..fill(target);
      e.beginPixelate(10, const [darker, lighter]);
      e.rect(0, 0, 200, 200);
      e.endPixelate();
      final p = await _pixels(e.renderQueue.execute);
      expect(_pixel(p, 100, 100), _packed(lighter));
    });

    test('matches a reference nearest-colour search', () async {
      const palette = [
        Color(0xFF1A1C2C),
        Color(0xFF5D275D),
        Color(0xFFB13E53),
        Color(0xFFEF7D57),
        Color(0xFFFFCD75),
        Color(0xFFA7F070),
        Color(0xFF38B764),
        Color(0xFF257179),
        Color(0xFF29366F),
        Color(0xFF3B5DC9),
        Color(0xFF41A6F6),
        Color(0xFF73EFF7),
      ];
      final rng = math.Random(7);
      final colors = <Color>[];
      final e = filled();
      e.beginPixelate(10, palette);
      for (var j = 0; j < 20; j++) {
        for (var i = 0; i < 20; i++) {
          final c = Color.fromARGB(
            255,
            rng.nextInt(256),
            rng.nextInt(256),
            rng.nextInt(256),
          );
          colors.add(c);
          e.fill(c);
          e.rect(i * 10.0, j * 10.0, 10, 10);
        }
      }
      e.endPixelate();
      final p = await _pixels(e.renderQueue.execute);
      var checked = 0;
      for (var k = 0; k < colors.length; k++) {
        // Near-ties may go either way in float32; only clear wins count.
        if (_oklabMargin(colors[k], palette) < 1e-3) continue;
        final x = (k % 20) * 10 + 5, y = (k ~/ 20) * 10 + 5;
        expect(
          _pixel(p, x, y),
          _packed(_nearestOklab(colors[k], palette)),
          reason: 'block $k, ${colors[k]}',
        );
        checked++;
      }
      expect(checked, greaterThan(380));
    });

    test('a block keeps its coverage', () async {
      final e = filled()..fill(red);
      e.beginPixelate(10, const [blue]);
      e.rect(40, 40, 5, 10); // half of the block at (40, 40)
      e.endPixelate();
      final p = await _pixels(e.renderQueue.execute);
      // Premultiplied readback: half-covered blue is (0, 0, 128, 128).
      final px = _pixel(p, 45, 45);
      expect(px >> 16, 0);
      expect(px >> 8 & 0xFF, closeTo(128, 4));
      expect(px & 0xFF, closeTo(128, 4));
      expect(_pixel(p, 25, 25) & 0xFF, 0);
    });

    test('a translucent palette colour thins the block', () async {
      final e = filled()..fill(red);
      e.beginPixelate(10, const [Color(0x80FF0000)]);
      e.rect(0, 0, 200, 200);
      e.endPixelate();
      final p = await _pixels(e.renderQueue.execute);
      // Premultiplied readback: half-alpha red is (128, 0, 0, 128).
      final px = _pixel(p, 100, 100);
      expect(px >> 24, closeTo(128, 2));
      expect(px >> 8 & 0xFFFF, 0);
      expect(px & 0xFF, closeTo(128, 2));
    });

    test('an empty palette keeps the average colour', () async {
      void draw(Flut5Engine e, List<Color>? palette) {
        e.beginPixelate(10, palette);
        e.fill(const Color(0xFF3366CC));
        e.circle(100, 100, 120);
        e.endPixelate();
      }

      final plain = filled();
      draw(plain, null);
      final empty = filled();
      draw(empty, const []);
      expect(
        await _pixels(empty.renderQueue.execute),
        await _pixels(plain.renderQueue.execute),
      );
    });

    test('changing the list afterwards leaves the frame alone', () async {
      final palette = [red];
      final e = filled()..fill(white);
      e.beginPixelate(10, palette);
      e.rect(0, 0, 200, 200);
      e.endPixelate();
      palette[0] = blue;
      final p = await _pixels(e.renderQueue.execute);
      expect(_pixel(p, 100, 100), _packed(red));
    });

    test('a fresh list each frame draws the same', () async {
      final e = filled();
      Future<Uint8List> frame() async {
        e.renderQueue.clear();
        e.beginPixelate(10, [black, red]);
        e.fill(const Color(0xFFCC2222));
        e.circle(100, 100, 120);
        e.endPixelate();
        return _pixels(e.renderQueue.execute);
      }

      final first = await frame();
      expect(await frame(), first);
      expect(await frame(), first);
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

/// [c] packed the way [_pixel] reads it — exact for opaque colours, since
/// `rawRgba` readback is premultiplied.
int _packed(Color c) =>
    (c.r * 255).round() << 24 |
    (c.g * 255).round() << 16 |
    (c.b * 255).round() << 8 |
    (c.a * 255).round();

/// sRGB → OKLab (Björn Ottosson), the shader's metric in double precision.
List<double> _oklab(Color c) {
  double lin(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = lin(c.r), g = lin(c.g), b = lin(c.b);
  double cbrt(double v) => math.pow(math.max(v, 0), 1 / 3).toDouble();
  final l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  final m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  final s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}

double _d2(List<double> a, List<double> b) =>
    (a[0] - b[0]) * (a[0] - b[0]) +
    (a[1] - b[1]) * (a[1] - b[1]) +
    (a[2] - b[2]) * (a[2] - b[2]);

List<double> _oklabDistances(Color target, List<Color> palette) {
  final t = _oklab(target);
  return [for (final c in palette) _d2(_oklab(c), t)];
}

Color _nearestOklab(Color target, List<Color> palette) {
  final d = _oklabDistances(target, palette);
  var best = 0;
  for (var i = 1; i < d.length; i++) {
    if (d[i] < d[best]) best = i;
  }
  return palette[best];
}

/// Gap between the nearest and second-nearest squared distances.
double _oklabMargin(Color target, List<Color> palette) {
  final d = _oklabDistances(target, palette)..sort();
  return d[1] - d[0];
}

Color _nearestRgb(Color target, List<Color> palette) {
  double d(Color c) =>
      (c.r - target.r) * (c.r - target.r) +
      (c.g - target.g) * (c.g - target.g) +
      (c.b - target.b) * (c.b - target.b);
  return palette.reduce((a, b) => d(b) < d(a) ? b : a);
}
