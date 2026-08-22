import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// Covers the split-replay capture path: on a layered capture frame the
/// painter records the foreground once and replays it into both the snapshot
/// recording and the screen, instead of walking the item list twice. That is
/// only sound when every background precedes all content, so both halves of
/// the contract are pinned here — the ordering predicate, and the pixel
/// equivalence it licenses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const w = 64;
  const h = 48;
  const canvasSize = Size(64, 48);

  Flut5Engine engine() {
    final e = Flut5Engine();
    e.environment = e.environment.withSize(canvasSize);
    e.noStroke();
    return e;
  }

  Future<ByteData> rasterize(void Function(Canvas) paint) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    );
    paint(canvas);
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    picture.dispose();
    final bytes = await image.toByteData();
    image.dispose();
    return bytes!;
  }

  /// Replays [queue] the way the split path does: backgrounds as a group,
  /// then a separately recorded foreground picture.
  void splitReplay(Canvas canvas, Flut5RenderQueue queue) {
    final recorder = ui.PictureRecorder();
    final foregroundCanvas = Canvas(recorder);
    queue.executeForeground(foregroundCanvas);
    final foreground = recorder.endRecording();
    queue.executeBackground(canvas);
    canvas.drawPicture(foreground);
    foreground.dispose();
  }

  group('backgroundsPrecedeContent', () {
    test('true for the p5 shape: background() then drawing', () {
      final e = engine();
      e.background(const Color(0x22000000));
      e.fill(Colors.red);
      e.circle(20, 20, 10);
      e.renderQueue.flushPending();
      expect(e.renderQueue.backgroundsPrecedeContent, isTrue);
    });

    test('true with no background at all', () {
      final e = engine();
      e.fill(Colors.red);
      e.circle(20, 20, 10);
      e.renderQueue.flushPending();
      expect(e.renderQueue.backgroundsPrecedeContent, isTrue);
    });

    test('false when a background lands after content', () {
      final e = engine();
      e.fill(Colors.red);
      e.circle(20, 20, 10);
      e.background(const Color(0x22000000));
      e.renderQueue.flushPending();
      expect(e.renderQueue.backgroundsPrecedeContent, isFalse);
    });
  });

  group('trailFadeColor', () {
    test('returns the translucent full-canvas fill', () {
      final e = engine();
      e.background(const Color(0x22112233));
      expect(e.renderQueue.trailFadeColor, const Color(0x22112233));
    });

    test('null for an opaque background — that clears rather than fades', () {
      final e = engine();
      e.background(const Color(0xFF112233));
      expect(e.renderQueue.trailFadeColor, isNull);
    });

    test('null for a gradient background — no closed-form compounding', () {
      final e = engine();
      e.background(
        const LinearGradient(colors: [Color(0x22000000), Color(0x22FFFFFF)]),
      );
      expect(e.renderQueue.trailFadeColor, isNull);
    });

    test('tracks the last background enqueued in the frame', () {
      final e = engine();
      e.background(const Color(0x22112233));
      e.background(const Color(0x44445566));
      expect(e.renderQueue.trailFadeColor, const Color(0x44445566));
    });
  });

  group('split replay equals in-order replay', () {
    test('translucent background then shapes is pixel-identical', () async {
      final e = engine();
      e.background(const Color(0x33204060));
      e.fill(Colors.red);
      e.circle(20, 20, 12);
      e.fill(Colors.green);
      e.rect(30, 10, 20, 20);
      e.renderQueue.flushPending();

      final inOrder = await rasterize((c) => e.renderQueue.execute(c));
      final split = await rasterize((c) => splitReplay(c, e.renderQueue));

      expect(split.buffer.asUint8List(), inOrder.buffer.asUint8List());
    });

    test('survives transforms and an unbalanced push()', () async {
      final e = engine();
      e.background(const Color(0x33204060));
      e.push();
      e.translate(10, 10);
      e.rotate(0.5);
      e.fill(Colors.amber);
      e.rect(0, 0, 18, 18);
      // Deliberately no pop(): both paths must rebalance the save stack the
      // same way, since executeForeground owns the baseline in the split.
      e.renderQueue.flushPending();

      final inOrder = await rasterize((c) => e.renderQueue.execute(c));
      final split = await rasterize((c) => splitReplay(c, e.renderQueue));

      expect(split.buffer.asUint8List(), inOrder.buffer.asUint8List());
    });

    test('diverges when a background follows content — hence the guard',
        () async {
      final e = engine();
      e.fill(Colors.red);
      e.circle(20, 20, 12);
      e.background(const Color(0xAA204060));
      e.renderQueue.flushPending();

      expect(e.renderQueue.backgroundsPrecedeContent, isFalse);

      final inOrder = await rasterize((c) => e.renderQueue.execute(c));
      final split = await rasterize((c) => splitReplay(c, e.renderQueue));

      // The split hoists the background above the circle, so it paints over
      // it instead of under it. This is exactly what the predicate exists to
      // prevent the painter from doing.
      expect(
        split.buffer.asUint8List(),
        isNot(inOrder.buffer.asUint8List()),
      );
    });
  });
}
