import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.Image image;
  setUp(() async {
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    c.drawRect(
      const Rect.fromLTWH(0, 0, 24, 24),
      Paint()..color = const Color(0x8800FF00),
    );
    c.drawRect(
      const Rect.fromLTWH(4, 4, 16, 16),
      Paint()..color = const Color(0xCCFF0000),
    );
    c.drawCircle(const Offset(10, 12), 5, Paint()..color = Colors.blue);
    final p = r.endRecording();
    image = await p.toImage(24, 24);
    p.dispose();
  });
  tearDown(() => image.dispose());

  Flut5RenderQueue scene(
    bool folded, {
    BlendMode blend = BlendMode.srcOver,
    bool crop = false,
    bool clip = false,
    bool rotate = true,
  }) {
    final e = Flut5Engine();
    final q = e.renderQueue;
    if (clip) {
      q.enqueue(
        ClipRenderItem.path(
          Path()..addRect(const Rect.fromLTWH(25, 20, 95, 95)),
          antiAlias: false,
        ),
      );
    }
    for (var i = 0; i < 5; i++) {
      final x = 40 + i * 15.0, y = 40 + (i % 2) * 16.0;
      final angle = rotate ? .13 + i * .33 : 0.0;
      final scale = i == 3 ? -1.2 : .7 + i * .2;
      if (folded) {
        e.push();
        e.translate(x, y);
        e.rotate(angle);
        e.scale(scale);
      } else {
        q.enqueue(TransformRenderItem.push());
        q.enqueue(TransformRenderItem.translate(x, y));
        q.enqueue(TransformRenderItem.rotate(angle));
        q.enqueue(TransformRenderItem.scale(scale, scale));
      }
      q.appendImage(
        image,
        crop
            ? const Rect.fromLTWH(4, 4, 16, 16)
            : const Rect.fromLTWH(0, 0, 24, 24),
        const Rect.fromLTWH(-12, -12, 32, 32),
        blend,
      );
      if (folded) {
        e.pop();
      } else {
        q.enqueue(TransformRenderItem.pop());
      }
    }
    q.flushPending();
    return q;
  }

  test('individual rotations and scales coalesce in source order', () {
    final q = scene(true);
    expect(q.items, hasLength(1));
    final atlas = q.items.single as ImageAtlasRenderItem;
    expect(atlas.spriteCount, 5);
    expect(atlas.transforms[1], isNot(0));
    expect(atlas.rects, hasLength(20));
  });

  for (final blend in [BlendMode.srcOver, BlendMode.multiply, BlendMode.plus]) {
    for (final crop in [false, true]) {
      test(
        'rotated atlas preserves $blend crop=$crop pixels and overlap',
        () async {
          await _expectSimilar(
            await _pixels(scene(true, blend: blend, crop: crop)),
            await _pixels(scene(false, blend: blend, crop: crop)),
          );
        },
      );
    }
  }

  test('uniform scales without rotation retain sampled edges', () async {
    final q = scene(true, rotate: false);
    expect(
      (q.items.single as ImageAtlasRenderItem).preserveRotatedEdges,
      isFalse,
    );
    await _expectSimilar(
      await _pixels(q),
      await _pixels(scene(false, rotate: false)),
    );
  });

  test('clipping remains in canvas coordinates', () async {
    await _expectSimilar(
      await _pixels(scene(true, clip: true)),
      await _pixels(scene(false, clip: true)),
    );
  });

  test(
    'atlas arrays survive clear and reuse of queue scratch buffers',
    () async {
      final q = scene(true);
      final old = q.items.single;
      final first = await _pixels(q);
      q.clear();
      for (var i = 0; i < 10; i++) {
        q.appendImage(
          image,
          const Rect.fromLTWH(0, 0, 24, 24),
          Rect.fromLTWH(i * 5, 100, 4, 4),
          BlendMode.srcOver,
        );
      }
      q.flushPending();
      final retained = Flut5RenderQueue()..enqueue(old);
      expect(await _pixels(retained), first);
    },
  );

  test('nonuniform scale still splits sprites and preserves bounds', () {
    final e = Flut5Engine();
    e.renderQueue.appendImage(
      image,
      const Rect.fromLTWH(0, 0, 24, 24),
      const Rect.fromLTWH(0, 0, 10, 10),
      BlendMode.srcOver,
    );
    e.scale(2, 3);
    e.renderQueue.appendImage(
      image,
      const Rect.fromLTWH(0, 0, 24, 24),
      const Rect.fromLTWH(10, 0, 10, 10),
      BlendMode.srcOver,
    );
    e.renderQueue.flushPending();
    expect(e.renderQueue.items, hasLength(3));
    expect(
      e.renderQueue.contentBoundsFrom(0),
      const Rect.fromLTRB(0, 0, 40, 30),
    );
  });

  test(
    'a transformed lone sprite owns its transform after pop and clear',
    () async {
      final e = Flut5Engine();
      e.push();
      e.translate(60, 50);
      e.rotate(.4);
      e.scale(1.3);
      e.renderQueue.appendImage(
        image,
        const Rect.fromLTWH(0, 0, 24, 24),
        const Rect.fromLTWH(0, 0, 20, 20),
        BlendMode.srcOver,
      );
      e.pop();
      e.renderQueue.flushPending();
      expect(e.renderQueue.items, hasLength(1));
      final old = e.renderQueue.items.single;
      final first = await _pixels(e.renderQueue);
      e.renderQueue.clear();
      e.rotate(2);
      e.scale(4);
      expect(await _pixels(Flut5RenderQueue()..enqueue(old)), first);
    },
  );
}

Future<Uint8List> _pixels(Flut5RenderQueue q) async {
  final r = ui.PictureRecorder();
  final c = Canvas(r)..drawColor(const Color(0xFF303040), BlendMode.src);
  q.execute(c);
  final p = r.endRecording();
  final image = await p.toImage(160, 140);
  final bytes = await image.toByteData();
  image.dispose();
  p.dispose();
  return bytes!.buffer.asUint8List();
}

Future<void> _expectSimilar(Uint8List actual, Uint8List expected) async {
  var error = 0, large = 0;
  for (var i = 0; i < actual.length; i++) {
    final delta = (actual[i] - expected[i]).abs();
    error += delta;
    if (delta > 16) large++;
  }
  expect(error / actual.length, lessThan(.5));
  expect(large / actual.length, lessThan(.005));
}
