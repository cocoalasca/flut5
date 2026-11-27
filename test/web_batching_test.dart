// On the web, stroked and translucent shapes draw alone and colour batches
// are not kept open, because a merged path there costs a coverage mask of
// its whole bounds. These tests pin the rules (forced on, since `flutter
// test` is not web) and that opaque one-colour fills still merge.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

const int _width = 240;
const int _height = 180;

List<Offset> _spots(int count) => [
  for (var i = 0; i < count; i++)
    Offset(10 + (i % 14) * 16 + (i * 0.37) % 1, 10 + (i ~/ 14) * 16),
];

Future<Uint8List> _pixels(void Function(Canvas canvas) draw) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFF0E1C2B), BlendMode.src);
  draw(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(_width, _height);
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

List<Flut5RenderItem> _items(void Function(Flut5Engine e) draw) {
  final e = Flut5Engine();
  draw(e);
  e.renderQueue.flushPending();
  return [...e.renderQueue.items];
}

Future<Uint8List> _queued(void Function(Flut5Engine e) draw) {
  final e = Flut5Engine();
  draw(e);
  e.renderQueue.flushPending();
  return _pixels(e.renderQueue.execute);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Flut5RenderQueue.debugWebBatching = true;
    Flut5RenderQueue.debugCirclesAsPoints = true;
  });
  tearDown(() {
    Flut5RenderQueue.debugWebBatching = null;
    Flut5RenderQueue.debugCirclesAsPoints = null;
  });

  test('stroked shapes draw alone, as each draws on its own', () async {
    final spots = _spots(40);
    void draw(Flut5Engine e) {
      e.fill(Colors.white);
      e.stroke(Colors.red);
      e.strokeWeight(1.5);
      for (final s in spots) {
        e.circle(s.dx, s.dy, 8);
      }
    }

    expect(_items(draw), everyElement(isA<CircleRenderItem>()));
    expect(_items(draw), hasLength(spots.length));
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    expect(
      await _queued(draw),
      await _pixels((canvas) {
        for (final s in spots) {
          canvas.drawCircle(s, 4, fill);
          canvas.drawCircle(s, 4, stroke);
        }
      }),
    );
  });

  test('stroke-only rects draw alone', () {
    final items = _items((e) {
      e.noFill();
      e.stroke(Colors.white);
      for (final s in _spots(30)) {
        e.rect(s.dx, s.dy, 6, 6);
      }
    });
    expect(items, hasLength(30));
    expect(items, everyElement(isA<RectRenderItem>()));
  });

  test('translucent rects draw alone, as each draws on its own', () async {
    final spots = _spots(40);
    const colour = Color(0x80FFFFFF);
    void draw(Flut5Engine e) {
      e.noStroke();
      e.fill(colour);
      for (final s in spots) {
        e.rect(s.dx, s.dy, 6, 6);
      }
    }

    expect(_items(draw), everyElement(isA<RectRenderItem>()));
    final paint = Paint()..color = colour;
    expect(
      await _queued(draw),
      await _pixels((canvas) {
        for (final s in spots) {
          canvas.drawRect(Rect.fromLTWH(s.dx, s.dy, 6, 6), paint);
        }
      }),
    );
  });

  test('translucent filled circles still run as points', () {
    final items = _items((e) {
      e.noStroke();
      e.fill(const Color(0x80FFFFFF));
      for (final s in _spots(30)) {
        e.circle(s.dx, s.dy, 6);
      }
    });
    expect(items.single, isA<CircleRunRenderItem>());
  });

  test('a change of colour closes the batch instead of keeping it open', () {
    const red = Color(0xFFFF0000), blue = Color(0xFF0000FF);
    final items = _items((e) {
      e.noStroke();
      final spots = _spots(12);
      for (var i = 0; i < spots.length; i++) {
        e.fill(i.isEven ? red : blue);
        e.rect(spots[i].dx, spots[i].dy, 6, 6);
      }
    });
    // Twelve alternating colours: twelve batches, none reopened.
    expect(items, hasLength(12));
  });

  test('opaque one-colour fills still merge into one path', () {
    final items = _items((e) {
      e.noStroke();
      e.fill(Colors.white);
      for (final s in _spots(30)) {
        e.rect(s.dx, s.dy, 6, 6);
        e.triangle(s.dx, s.dy + 12, s.dx + 6, s.dy + 12, s.dx + 3, s.dy + 8);
      }
    });
    expect(items.single, isA<PathRenderItem>());
  });

  test('off the web the rules are off', () {
    Flut5RenderQueue.debugWebBatching = false;
    final items = _items((e) {
      e.noFill();
      e.stroke(Colors.white);
      for (final s in _spots(30)) {
        e.rect(s.dx, s.dy, 6, 6);
      }
    });
    expect(items.single, isA<PathRenderItem>());
  });
}
