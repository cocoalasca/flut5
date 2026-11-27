// On Skia a batch of same-radius filled circles is queued as one
// CircleRunRenderItem (round points) instead of a merged path. These tests
// pin when that happens, that it draws exactly what each circle drawn alone
// draws, and that every batch it does not apply to is unchanged.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

const int _width = 240;
const int _height = 180;
const Color _ground = Color(0xFF0E1C2B);

/// Centres on a grid with sub-pixel offsets, spaced so no two circles of
/// radius up to 6 touch.
List<Offset> _centres(int count) => [
  for (var i = 0; i < count; i++)
    Offset(
      10 + (i % 14) * 16 + (i * 0.37) % 1,
      10 + (i ~/ 14) * 16 + (i * 0.61) % 1,
    ),
];

Future<Uint8List> _pixels(
  void Function(Canvas canvas) draw, {
  double scale = 1,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(_ground, BlendMode.src);
  canvas.scale(scale);
  draw(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(_width, _height);
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

/// The queue's picture of what [draw] queued on a fresh engine.
Future<Uint8List> _queued(
  void Function(Flut5Engine e) draw, {
  double scale = 1,
  List<Flut5RenderItem>? items,
}) {
  final e = Flut5Engine();
  draw(e);
  e.renderQueue.flushPending();
  items?.addAll(e.renderQueue.items);
  return _pixels(e.renderQueue.execute, scale: scale);
}

/// Circle runs are built on Skia only, the backend where a round point is
/// drawn exactly as a circle; forced on under `--enable-impeller` they would
/// not match, so pixels are compared on Skia and the structure everywhere.
final bool _skia = !ui.ImageFilter.isShaderFilterSupported;

void _expectDrawnAlone(Uint8List queued, Uint8List alone, {String? reason}) {
  if (_skia) expect(queued, alone, reason: reason);
}

/// Each circle drawn on its own, the picture a circle run must reproduce.
Future<Uint8List> _alone(
  List<Offset> centres,
  double radius,
  Color colour, {
  double scale = 1,
}) {
  final paint = Paint()..color = colour;
  return _pixels((canvas) {
    for (final c in centres) {
      canvas.drawCircle(c, radius, paint);
    }
  }, scale: scale);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => Flut5RenderQueue.debugCirclesAsPoints = true);
  tearDown(() => Flut5RenderQueue.debugCirclesAsPoints = null);

  void drawCircles(
    Flut5Engine e,
    List<Offset> centres,
    double diameter,
    Color colour,
  ) {
    e.noStroke();
    e.fill(colour);
    for (final c in centres) {
      e.circle(c.dx, c.dy, diameter);
    }
  }

  test('same-radius filled circles queue as one circle run', () async {
    final centres = _centres(120);
    final items = <Flut5RenderItem>[];
    final queued = await _queued(
      (e) => drawCircles(e, centres, 8, Colors.white),
      items: items,
    );
    expect(items, hasLength(1));
    final run = items.single as CircleRunRenderItem;
    expect(run.radius, 4);
    expect(run.centres, hasLength(240));
    _expectDrawnAlone(queued, await _alone(centres, 4, Colors.white));
  });

  test('a circle run draws each circle as it is drawn alone, at 2x', () async {
    final centres = _centres(60);
    for (final diameter in [0.5, 1.0, 3.0, 4.0, 7.0, 12.0]) {
      _expectDrawnAlone(
        await _queued(
          (e) => drawCircles(e, centres, diameter, Colors.white),
          scale: 2,
        ),
        await _alone(centres, diameter / 2, Colors.white, scale: 2),
        reason: 'diameter $diameter',
      );
    }
  });

  test(
    'translucent circles kept apart run too, unchanged per circle',
    () async {
      final centres = _centres(80);
      const colour = Color(0x80FF8040);
      final items = <Flut5RenderItem>[];
      final queued = await _queued(
        (e) => drawCircles(e, centres, 6, colour),
        items: items,
      );
      expect(items.single, isA<CircleRunRenderItem>());
      _expectDrawnAlone(queued, await _alone(centres, 3, colour));
    },
  );

  test('scaled circles fold into a run at the scaled radius', () async {
    final centres = _centres(40);
    final items = <Flut5RenderItem>[];
    final queued = await _queued((e) {
      e.noStroke();
      e.fill(Colors.white);
      for (final c in centres) {
        e.push();
        e.translate(c.dx, c.dy);
        e.scale(1.5);
        e.circle(0, 0, 4);
        e.pop();
      }
    }, items: items);
    expect(items.single, isA<CircleRunRenderItem>());
    expect((items.single as CircleRunRenderItem).radius, 3);
    _expectDrawnAlone(queued, await _alone(centres, 3, Colors.white));
  });

  test('the run bounds cover the circles, not just their centres', () {
    final e = Flut5Engine();
    e.noStroke();
    e.fill(Colors.white);
    e.circle(20, 30, 10);
    e.circle(60, 40, 10);
    e.renderQueue.flushPending();
    expect(
      e.renderQueue.items.single.bounds,
      const Rect.fromLTRB(15, 25, 65, 45),
    );
  });

  group('batches that are not a run are unchanged', () {
    /// Builds [draw] with and without circle runs: the items must match in
    /// kind and the pictures byte for byte.
    Future<void> expectUnchanged(void Function(Flut5Engine e) draw) async {
      final withRuns = <Flut5RenderItem>[];
      final runPicture = await _queued(draw, items: withRuns);
      Flut5RenderQueue.debugCirclesAsPoints = false;
      final without = <Flut5RenderItem>[];
      final pathPicture = await _queued(draw, items: without);
      Flut5RenderQueue.debugCirclesAsPoints = true;
      expect(
        withRuns.map((i) => i.runtimeType).toList(),
        without.map((i) => i.runtimeType).toList(),
      );
      expect(withRuns.whereType<CircleRunRenderItem>(), isEmpty);
      expect(runPicture, pathPicture);
    }

    test(
      'a rect joining after the circles puts them back in the path',
      () async {
        final centres = _centres(30);
        await expectUnchanged((e) {
          drawCircles(e, centres, 6, Colors.white);
          e.rect(200, 150, 20, 10);
          e.circle(5, 170, 6);
        });
      },
    );

    test('circles of different radii', () async {
      final centres = _centres(30);
      await expectUnchanged((e) {
        e.noStroke();
        e.fill(Colors.white);
        for (var i = 0; i < centres.length; i++) {
          e.circle(centres[i].dx, centres[i].dy, i.isEven ? 6 : 8);
        }
      });
    });

    test('stroked circles', () async {
      final centres = _centres(30);
      await expectUnchanged((e) {
        e.fill(Colors.white);
        e.stroke(Colors.red);
        e.strokeWeight(2);
        for (final c in centres) {
          e.circle(c.dx, c.dy, 8);
        }
      });
    });

    test('shadowed circles', () async {
      final centres = _centres(20);
      await expectUnchanged((e) {
        e.shadow(2, 2, 4);
        drawCircles(e, centres, 8, Colors.white);
      });
    });
  });

  test('with runs off (Impeller) circles keep the merged path', () async {
    Flut5RenderQueue.debugCirclesAsPoints = false;
    final items = <Flut5RenderItem>[];
    await _queued(
      (e) => drawCircles(e, _centres(20), 8, Colors.white),
      items: items,
    );
    expect(items.single, isA<PathRenderItem>());
  });
}
