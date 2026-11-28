// A beginBatch()/endBatch() batch of plain stroked rects keeps its geometry
// across frames and strokes the merged lines of its edges wherever that
// draws exactly what the rects draw. These tests pin when each happens and
// that the picture never changes.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

const int _width = 360;
const int _height = 260;

/// Whether this run renders with Impeller (`--enable-impeller`).
final bool _impeller = ui.ImageFilter.isShaderFilterSupported;

/// Cells of a [cols]×[rows] grid of [cell]-sized squares from ([x0], [y0]).
List<Rect> _grid(
  int cols,
  int rows,
  double cell, {
  double x0 = 0,
  double y0 = 0,
}) => [
  for (var r = 0; r < rows; r++)
    for (var c = 0; c < cols; c++)
      Rect.fromLTWH(x0 + c * cell, y0 + r * cell, cell, cell),
];

void _batchRects(Flut5Engine e, List<Rect> rects) {
  e.beginBatch();
  for (final r in rects) {
    e.rect(r.left, r.top, r.width, r.height);
  }
  e.endBatch();
}

Flut5Engine _strokedGrid(
  List<Rect> rects, {
  double weight = 1,
  bool filled = false,
}) {
  final e = Flut5Engine();
  if (filled) {
    e.fill(const Color(0xFF204060));
  } else {
    e.noFill();
  }
  e.stroke(Colors.white);
  e.strokeWeight(weight);
  _batchRects(e, rects);
  e.renderQueue.flushPending();
  return e;
}

Future<Uint8List> _pixels(
  void Function(Canvas c) draw,
  void Function(Canvas c) transform,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFF0E1C2B), BlendMode.src);
  transform(canvas);
  draw(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(_width, _height);
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

/// The rects stroked as one path, the way the batch drew them before.
void Function(Canvas c) _asRectPath(
  List<Rect> rects,
  double weight, {
  bool filled = false,
}) {
  final path = Path();
  for (final r in rects) {
    path.addRect(r);
  }
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = weight
    ..color = Colors.white;
  final fill = Paint()..color = const Color(0xFF204060);
  return (canvas) {
    if (filled) canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
  };
}

/// The rects path the batch's single item draws from, whichever kind it is.
Path _rectsOf(Flut5Engine e) => switch (e.renderQueue.items.single) {
  RectOutlineRenderItem item => item.geometry.rects,
  PathRenderItem item => item.path,
  final other => throw StateError('unexpected ${other.runtimeType}'),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final transforms = <String, void Function(Canvas)>{
    '1x': (c) {},
    '1.5x': (c) => c.scale(1.5),
    '2x': (c) => c.scale(2),
    'rotated': (c) {
      c.translate(180, 130);
      c.rotate(0.3);
      c.translate(-180, -130);
    },
  };

  group('where lines are allowed (Impeller rule forced on)', () {
    setUp(() => RectOutlineRenderItem.debugImpeller = true);
    tearDown(() => RectOutlineRenderItem.debugImpeller = null);

    test('a grid batch becomes one outline item with merged lines', () {
      final e = _strokedGrid(_grid(80, 60, 4));
      final item = e.renderQueue.items.single as RectOutlineRenderItem;
      // 81 vertical + 61 horizontal walls.
      expect(item.geometry.outlineLines!.length ~/ 4, 142);
    });

    test('a sketch rotation on the canvas strokes the rects instead', () {
      final item =
          _strokedGrid(_grid(20, 10, 4)).renderQueue.items.single
              as RectOutlineRenderItem;
      Object? drawn;
      void draw(void Function(Canvas) transform) {
        final recorder = ui.PictureRecorder();
        final canvas = _CountingCanvas(Canvas(recorder), (p) => drawn = p);
        transform(canvas);
        item.execute(canvas);
        recorder.endRecording().dispose();
      }

      draw((c) => c.scale(2));
      expect(identical(drawn, item.geometry.outline), isTrue);
      draw((c) => c.rotate(0.3));
      expect(identical(drawn, item.geometry.rects), isTrue);
    });

    test('a canvas rotated on screen keeps the plain path', () {
      final e = Flut5Engine()
        ..screenUpright = false
        ..noFill()
        ..stroke(Colors.white);
      _batchRects(e, _grid(20, 10, 4));
      e.renderQueue.flushPending();
      expect(e.renderQueue.items.single, isA<PathRenderItem>());
    });
  });

  test('Skia keeps the plain path (lines are Impeller only)', () {
    RectOutlineRenderItem.debugImpeller = false;
    addTearDown(() => RectOutlineRenderItem.debugImpeller = null);
    final e = _strokedGrid(_grid(20, 10, 4));
    expect(e.renderQueue.items.single, isA<PathRenderItem>());
  });

  for (final entry in transforms.entries) {
    test('the grid draws exactly as its rects did, ${entry.key}', () async {
      final rects = _grid(80, 60, 4);
      final e = _strokedGrid(rects);
      expect(
        await _pixels(e.renderQueue.execute, entry.value),
        await _pixels(_asRectPath(rects, 1), entry.value),
      );
    });
  }

  test(
    'fractional cells, filled, every transform: picture unchanged',
    () async {
      final rects = _grid(60, 40, 3.7, x0: 5.3, y0: 7.3);
      final e = _strokedGrid(rects, weight: 2, filled: true);
      if (_impeller) {
        expect(e.renderQueue.items.single, isA<RectOutlineRenderItem>());
      }
      for (final entry in transforms.entries) {
        expect(
          await _pixels(e.renderQueue.execute, entry.value),
          await _pixels(_asRectPath(rects, 2, filled: true), entry.value),
          reason: entry.key,
        );
      }
    },
  );

  test('nested cells (quadtree): picture unchanged', () async {
    final rects = [
      for (var depth = 0; depth < 5; depth++)
        for (var i = 0; i < (1 << depth); i++)
          for (var j = 0; j < (1 << depth); j++)
            Rect.fromLTWH(
              10 + i * 160 / (1 << depth),
              10 + j * 160 / (1 << depth),
              160 / (1 << depth),
              160 / (1 << depth),
            ),
    ];
    final e = _strokedGrid(rects, weight: 1.5);
    if (_impeller) {
      expect(e.renderQueue.items.single, isA<RectOutlineRenderItem>());
    }
    for (final entry in transforms.entries) {
      expect(
        await _pixels(e.renderQueue.execute, entry.value),
        await _pixels(_asRectPath(rects, 1.5), entry.value),
        reason: entry.key,
      );
    }
  });

  group('geometry kept across frames', () {
    test('the same rects next frame reuse the same paths', () {
      final rects = _grid(30, 20, 4);
      final e = _strokedGrid(rects);
      final first = _rectsOf(e);
      e.renderQueue.clear();
      _batchRects(e, rects);
      e.renderQueue.flushPending();
      expect(identical(first, _rectsOf(e)), isTrue);
    });

    test('a moved rect rebuilds the geometry', () {
      final rects = _grid(30, 20, 4);
      final e = _strokedGrid(rects);
      final first = _rectsOf(e);
      e.renderQueue.clear();
      _batchRects(e, [...rects.skip(1), const Rect.fromLTWH(200, 200, 4, 4)]);
      e.renderQueue.flushPending();
      expect(identical(first, _rectsOf(e)), isFalse);
    });
  });

  group('batches that keep the plain path', () {
    PathRenderItem pathItem(Flut5Engine e) =>
        e.renderQueue.items.single as PathRenderItem;

    test('another shape joining keeps the rects first, in order', () async {
      final e = Flut5Engine()
        ..noFill()
        ..stroke(Colors.white)
        ..strokeWeight(2);
      e.beginBatch();
      e.rect(10, 10, 40, 30);
      e.rect(60, 10, 40, 30);
      e.circle(150, 40, 40);
      e.rect(110, 10, 40, 30);
      e.endBatch();
      e.renderQueue.flushPending();
      final expected = Path()
        ..addRect(const Rect.fromLTWH(10, 10, 40, 30))
        ..addRect(const Rect.fromLTWH(60, 10, 40, 30))
        ..addOval(Rect.fromCircle(center: const Offset(150, 40), radius: 20))
        ..addRect(const Rect.fromLTWH(110, 10, 40, 30));
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white;
      expect(
        await _pixels((c) => pathItem(e).execute(c), (c) {}),
        await _pixels((c) => c.drawPath(expected, paint), (c) {}),
      );
    });

    test('scattered rects whose edges do not merge', () {
      final rng = math.Random(3);
      final rects = [
        for (var i = 0; i < 60; i++)
          Rect.fromLTWH(
            rng.nextDouble() * 300,
            rng.nextDouble() * 200,
            5 + rng.nextDouble() * 30,
            5 + rng.nextDouble() * 30,
          ),
      ];
      expect(pathItem(_strokedGrid(rects)), isA<PathRenderItem>());
    });

    test('round corners', () {
      final e = Flut5Engine()
        ..noFill()
        ..stroke(Colors.white)
        ..strokeJoin(StrokeJoin.round);
      _batchRects(e, _grid(20, 10, 4));
      e.renderQueue.flushPending();
      expect(pathItem(e), isA<PathRenderItem>());
    });

    test('a rect without width', () {
      expect(
        pathItem(
          _strokedGrid([..._grid(20, 10, 4), const Rect.fromLTWH(5, 5, 0, 10)]),
        ),
        isA<PathRenderItem>(),
      );
    });

    test('a dashed stroke', () {
      final e = Flut5Engine()
        ..noFill()
        ..stroke(Colors.white)
        ..setLineDash([4, 2]);
      _batchRects(e, _grid(20, 10, 4));
      e.renderQueue.flushPending();
      expect(e.renderQueue.items.whereType<RectOutlineRenderItem>(), isEmpty);
    });

    test('fill only: kept geometry, no outline', () {
      final e = Flut5Engine()
        ..noStroke()
        ..fill(Colors.white);
      _batchRects(e, _grid(20, 10, 4));
      e.renderQueue.flushPending();
      expect(pathItem(e), isA<PathRenderItem>());
    });
  });

  autoBatchTests();
}

void _autoRects(Flut5Engine e, List<Rect> rects) {
  for (final r in rects) {
    e.rect(r.left, r.top, r.width, r.height);
  }
  e.renderQueue.flushPending();
}

Flut5Engine _autoStrokedGrid(List<Rect> rects, {double weight = 1}) {
  final e = Flut5Engine()
    ..noFill()
    ..stroke(Colors.white)
    ..strokeWeight(weight);
  _autoRects(e, rects);
  return e;
}

void autoBatchTests() {
  final transforms = <String, void Function(Canvas)>{
    '1x': (c) {},
    '1.5x': (c) => c.scale(1.5),
    '2x': (c) => c.scale(2),
    'rotated': (c) {
      c.translate(180, 130);
      c.rotate(0.3);
      c.translate(-180, -130);
    },
  };

  group('automatic batches (no beginBatch)', () {
    test('a long run of stroked rects becomes one outline item', () {
      RectOutlineRenderItem.debugImpeller = true;
      addTearDown(() => RectOutlineRenderItem.debugImpeller = null);
      final e = _autoStrokedGrid(_grid(80, 60, 4));
      final item = e.renderQueue.items.single as RectOutlineRenderItem;
      expect(item.geometry.outlineLines!.length ~/ 4, 142);
    });

    for (final entry in transforms.entries) {
      test('the grid draws exactly as its rects did, ${entry.key}', () async {
        final rects = _grid(60, 40, 3.7, x0: 5.3, y0: 7.3);
        final e = _autoStrokedGrid(rects, weight: 2);
        expect(
          await _pixels(e.renderQueue.execute, entry.value),
          await _pixels(_asRectPath(rects, 2), entry.value),
        );
      });
    }

    test('the same run next frame reuses the same paths', () {
      final rects = _grid(30, 20, 4);
      final e = _autoStrokedGrid(rects);
      final first = _rectsOf(e);
      e.renderQueue.clear();
      _autoRects(e, rects);
      expect(identical(first, _rectsOf(e)), isTrue);
    });

    test('fill-only runs reuse their geometry too', () {
      final rects = _grid(30, 20, 4);
      final e = Flut5Engine()
        ..noStroke()
        ..fill(Colors.white);
      _autoRects(e, rects);
      final first = _rectsOf(e);
      e.renderQueue.clear();
      _autoRects(e, rects);
      expect(identical(first, _rectsOf(e)), isTrue);
    });

    test('short runs keep the plain path', () {
      RectOutlineRenderItem.debugImpeller = true;
      addTearDown(() => RectOutlineRenderItem.debugImpeller = null);
      final e = _autoStrokedGrid(_grid(5, 2, 4));
      expect(e.renderQueue.items.single, isA<PathRenderItem>());
    });

    test('another shape joining puts the rects back in order', () async {
      RectOutlineRenderItem.debugImpeller = true;
      addTearDown(() => RectOutlineRenderItem.debugImpeller = null);
      final rects = _grid(20, 2, 8, x0: 10, y0: 10);
      final e = Flut5Engine()
        ..noFill()
        ..stroke(Colors.white)
        ..strokeWeight(2);
      for (final r in rects) {
        e.rect(r.left, r.top, r.width, r.height);
      }
      e.triangle(40, 120, 90, 60, 140, 120);
      e.rect(200, 80, 60, 40);
      e.renderQueue.flushPending();
      expect(e.renderQueue.items.single, isA<PathRenderItem>());
      final expected = Path();
      for (final r in rects) {
        expected.addRect(r);
      }
      expected
        ..moveTo(40, 120)
        ..lineTo(90, 60)
        ..lineTo(140, 120)
        ..close()
        ..addRect(const Rect.fromLTWH(200, 80, 60, 40));
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white;
      expect(
        await _pixels(e.renderQueue.execute, (c) {}),
        await _pixels((c) => c.drawPath(expected, paint), (c) {}),
      );
    });

    test('rects under a folded rotation are not a run', () {
      RectOutlineRenderItem.debugImpeller = true;
      addTearDown(() => RectOutlineRenderItem.debugImpeller = null);
      final e = Flut5Engine()
        ..noFill()
        ..stroke(Colors.white);
      for (final r in _grid(20, 10, 6)) {
        e.push();
        e.translate(r.center.dx, r.center.dy);
        e.rotate(0.2);
        e.rect(-3, -3, 6, 6);
        e.pop();
      }
      e.renderQueue.flushPending();
      expect(e.renderQueue.items.whereType<RectOutlineRenderItem>(), isEmpty);
    });
  });
}

/// Passes draws through to [inner], reporting each path drawn.
class _CountingCanvas(final Canvas inner, final void Function(Path path) onPath)
    implements Canvas {
  @override
  void drawPath(Path path, Paint paint) {
    onPath(path);
    inner.drawPath(path, paint);
  }

  @override
  Float64List getTransform() => inner.getTransform();

  @override
  void scale(double sx, [double? sy]) => inner.scale(sx, sy);

  @override
  void rotate(double radians) => inner.rotate(radians);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
