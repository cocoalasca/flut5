import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// Builds a solid [width]×[height] bitmap synchronously — enough for the
/// queue/geometry assertions below, which never look at pixels.
ui.Image solidImage(int width, int height, [Color color = Colors.red]) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  picture.dispose();
  return image;
}

Flut5Image testImage(int width, int height) =>
    Flut5Image.fromUiImage(solidImage(width, height), source: 'test');

/// Red left half, blue right half — a resample that only changed the reported
/// dimensions, or that sampled the wrong region, shows up as a wrong colour.
ui.Image twoToneImage(int width, int height) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width / 2, height.toDouble()),
    Paint()..color = const Color(0xFFFF0000),
  );
  canvas.drawRect(
    Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()),
    Paint()..color = const Color(0xFF0000FF),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  picture.dispose();
  return image;
}

Color pixelAt(ByteData rgba, int width, int x, int y) {
  final offset = (y * width + x) * 4;
  return Color.fromARGB(
    rgba.getUint8(offset + 3),
    rgba.getUint8(offset),
    rgba.getUint8(offset + 1),
    rgba.getUint8(offset + 2),
  );
}

/// Exercises the unprefixed forwarders sketch authors actually write.
class _ImageSketch extends Flut5Sketch {
  void paint(Flut5Image img) => image(img, 7, 9);
}

class _ImageOnlySketch(final Flut5Image tile) extends Flut5Sketch {
  @override
  void draw() {
    image(tile, 0, 0);
    image(tile, 8, 0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Flut5Engine engine() => Flut5Engine()
    ..fill(Colors.white)
    ..noStroke();

  ImageRenderItem? soleImageItem(Flut5Engine e) {
    e.renderQueue.flushPending();
    final items = e.renderQueue.items.whereType<ImageRenderItem>().toList();
    return items.length == 1 ? items.single : null;
  }

  group('image() geometry', () {
    test('draws at natural size from the top-left corner', () {
      final e = engine();
      final img = testImage(40, 30);
      e.image(img, 10, 20);

      final item = soleImageItem(e)!;
      expect(item.src, const Rect.fromLTWH(0, 0, 40, 30));
      expect(item.dst, const Rect.fromLTWH(10, 20, 40, 30));
      img.dispose();
    });

    test('an explicit size scales the destination only', () {
      final e = engine();
      final img = testImage(40, 30);
      e.image(img, 0, 0, 120, 60);

      final item = soleImageItem(e)!;
      expect(item.src, const Rect.fromLTWH(0, 0, 40, 30));
      expect(item.dst, const Rect.fromLTWH(0, 0, 120, 60));
      img.dispose();
    });

    test('the sprite-sheet form selects a source sub-rectangle', () {
      final e = engine();
      final sheet = testImage(128, 64);
      e.image(sheet, 5, 5, 64, 64, 96, 32, 32, 32);

      final item = soleImageItem(e)!;
      expect(item.src, const Rect.fromLTWH(96, 32, 32, 32));
      expect(item.dst, const Rect.fromLTWH(5, 5, 64, 64));
      sheet.dispose();
    });

    test('a source rectangle past the edge is clamped, not sampled', () {
      final e = engine();
      final img = testImage(40, 30);
      e.image(img, 0, 0, 10, 10, 20, 20, 100, 100);

      final item = soleImageItem(e)!;
      expect(item.src, const Rect.fromLTWH(20, 20, 20, 10));
      expect(item.dst, const Rect.fromLTWH(0, 0, 10, 10));
      img.dispose();
    });

    test('a zero or negative draw size queues nothing', () {
      final e = engine();
      final img = testImage(40, 30);
      e.image(img, 0, 0, 0, 50);
      e.image(img, 0, 0, 50, -1);

      e.renderQueue.flushPending();
      expect(e.renderQueue.items.whereType<ImageRenderItem>(), isEmpty);
      img.dispose();
    });

    test('a disposed image warns instead of crashing the frame', () {
      final e = engine();
      final img = testImage(40, 30)..dispose();
      e.image(img, 0, 0);

      e.renderQueue.flushPending();
      expect(e.renderQueue.items.whereType<ImageRenderItem>(), isEmpty);
    });

    test('bounds report the destination rect so containers can size', () {
      final e = engine();
      final img = testImage(40, 30);
      e.image(img, 10, 20, 100, 50);

      expect(soleImageItem(e)!.bounds, const Rect.fromLTWH(10, 20, 100, 50));
      img.dispose();
    });
  });

  group('image() engine state', () {
    test('a folded translate bakes into dst without a transform item', () {
      final e = engine();
      final img = testImage(40, 30);
      e.push();
      e.translate(100, 50);
      e.image(img, 5, 5);
      e.pop();

      e.renderQueue.flushPending();
      final item = soleImageItem(e)!;
      expect(item.dst, const Rect.fromLTWH(105, 55, 40, 30));
      expect(e.renderQueue.items.whereType<TransformRenderItem>(), isEmpty);
      img.dispose();
    });

    test('an active shadow rides along on the item', () {
      final e = engine();
      final img = testImage(40, 30);
      e.shadow(4, 4, 8);
      e.image(img, 0, 0);

      expect(soleImageItem(e)!.shadow, isNotNull);
      img.dispose();
    });

    test('blendMode is captured at queue time', () {
      final e = engine();
      final img = testImage(40, 30);
      e.blendMode(BlendMode.plus);
      e.image(img, 0, 0);

      expect(soleImageItem(e)!.blendMode, BlendMode.plus);
      img.dispose();
    });

    test('image() inside beginBatch/endBatch throws', () {
      final e = engine();
      final img = testImage(40, 30);
      e.beginBatch();
      expect(() => e.image(img, 0, 0), throwsA(isA<FlutterError>()));
      e.endBatch();
      img.dispose();
    });
  });

  group('Flut5Image.resize', () {
    test('resizes the bitmap in place', () {
      final img = testImage(400, 300);
      img.resize(200, 100);

      expect(img.width, 200);
      expect(img.height, 100);
      img.dispose();
    });

    test(
      'matches the p5 reference example: 500x300 resize(50, 0) -> 50x30',
      () {
        // https://p5js.org/reference/p5.Image/resize/
        final img = testImage(500, 300)..resize(50, 0);
        expect(img.width, 50);
        expect(img.height, 30);
        img.dispose();
      },
    );

    test('a 0 derives the missing dimension from the aspect ratio', () {
      final wide = testImage(400, 300)..resize(200, 0);
      expect(wide.width, 200);
      expect(wide.height, 150);
      wide.dispose();

      final tall = testImage(400, 300)..resize(0, 150);
      expect(tall.width, 200);
      expect(tall.height, 150);
      tall.dispose();
    });

    test('the resized bitmap is what image() then draws at natural size', () {
      final e = engine();
      final img = testImage(400, 300)..resize(100, 0);
      e.image(img, 0, 0);

      expect(soleImageItem(e)!.dst, const Rect.fromLTWH(0, 0, 100, 75));
      img.dispose();
    });

    test('resizing to the current size is a no-op', () {
      final img = testImage(64, 64);
      final before = img.uiImage;
      img.resize(64, 64);

      expect(identical(img.uiImage, before), isTrue);
      img.dispose();
    });

    test('two zeros are refused rather than guessed at', () {
      final img = testImage(64, 48);
      img.resize(0, 0);

      expect(img.width, 64);
      expect(img.height, 48);
      img.dispose();
    });

    test('resamples the pixels, not just the reported size', () async {
      final img = Flut5Image.fromUiImage(twoToneImage(400, 400));
      img.resize(40, 0);

      final rgba = await img.uiImage.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final left = pixelAt(rgba!, 40, 5, 20);
      final right = pixelAt(rgba, 40, 34, 20);
      expect(left.r, greaterThan(0.9));
      expect(left.b, lessThan(0.1));
      expect(right.b, greaterThan(0.9));
      expect(right.r, lessThan(0.1));
      expect(left.a, closeTo(1.0, 0.01));
      img.dispose();
    });

    test('a resized image replays onto a real canvas', () {
      // `toImageSync` rasterizes lazily: a failure surfaces at draw time, not
      // at resize() time, so the queue has to actually execute to prove it.
      final e = engine();
      final img = Flut5Image.fromUiImage(twoToneImage(400, 400))
        ..resize(50, 50);
      e.image(img, 10, 10);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      expect(() => e.renderQueue.execute(canvas), returnsNormally);
      recorder.endRecording().dispose();
      img.dispose();
    });

    test('resize after dispose is ignored', () {
      final img = testImage(64, 48)..dispose();
      img.resize(10, 10);

      expect(img.isDisposed, isTrue);
      expect(img.width, 0);
    });
  });

  group('Flut5Image.load', () {
    test('decodes encoded bytes', () async {
      final source = solidImage(8, 6, Colors.blue);
      final png = await source.toByteData(format: ui.ImageByteFormat.png);
      source.dispose();

      final img = await Flut5Image.load(png!.buffer.asUint8List());
      expect(img.width, 8);
      expect(img.height, 6);
      img.dispose();
    });

    test('wraps an already-decoded ui.Image', () async {
      final img = await Flut5Image.load(solidImage(12, 9));
      expect(img.width, 12);
      expect(img.height, 9);
      img.dispose();
    });

    test('rejects an unsupported source type', () {
      expect(() => Flut5Image.load(42), throwsA(isA<ArgumentError>()));
    });

    test('reports the missing asset instead of failing silently', () async {
      Flut5Image.debugResetAssetIndex();
      await expectLater(
        Flut5Image.load('definitely-not-an-asset.png'),
        throwsA(
          isA<FlutterError>().having(
            (e) => e.message,
            'message',
            contains('definitely-not-an-asset.png'),
          ),
        ),
      );
    });

    test('a Uint8List that is not an image surfaces the decode failure', () {
      final garbage = Uint8List.fromList(List<int>.filled(32, 7));
      expect(Flut5Image.load(garbage), throwsA(isA<FlutterError>()));
    });
  });

  group('image() atlas batching', () {
    test(
      'painter displays an image-only frame with an unflushed atlas',
      () async {
        final tile = testImage(8, 8);
        final previousEngine = Flut5Engine.current;
        final sketch = _ImageOnlySketch(tile)..isReady = true;
        final e = sketch.flut5;
        // First paint is off the capture tick: inspect the foreground directly.
        e.frameSnapshotInterval = 2;
        e.adaptiveSnapshotThrottle = false;
        addTearDown(() {
          tile.dispose();
          sketch.dispose();
          Flut5Engine.current = previousEngine;
        });
        final recorder = ui.PictureRecorder();
        Flut5Painter(sketch: sketch).paint(Canvas(recorder), const Size(16, 8));
        final picture = recorder.endRecording();
        final output = await picture.toImage(16, 8);
        final pixels = (await output.toByteData())!;
        expect(pixelAt(pixels, 16, 4, 4).toARGB32(), Colors.red.toARGB32());
        expect(pixelAt(pixels, 16, 12, 4).toARGB32(), Colors.red.toARGB32());
        expect(e.renderQueue.isEmpty, isTrue);
        output.dispose();
        picture.dispose();
      },
    );

    test('pending images make the queue nonempty before any flush', () {
      final e = engine();
      final tile = testImage(32, 32);
      addTearDown(tile.dispose);
      expect(e.renderQueue.isEmpty, isTrue);
      e.image(tile, 0, 0);
      expect(e.renderQueue.isEmpty, isFalse);
      e.image(tile, 40, 0);
      expect(e.renderQueue.isEmpty, isFalse);
      e.renderQueue.clear();
      expect(e.renderQueue.isEmpty, isTrue);
    });

    List<Flut5RenderItem> itemsOf(Flut5Engine e) {
      e.renderQueue.flushPending();
      return e.renderQueue.items;
    }

    test('same source, same size: a mosaic collapses to one atlas item', () {
      final e = engine();
      final tile = testImage(32, 32);
      for (var row = 0; row < 4; row++) {
        for (var col = 0; col < 5; col++) {
          e.image(tile, col * 32.0, row * 32.0);
        }
      }

      final items = itemsOf(e);
      expect(items, hasLength(1));
      expect((items.single as ImageAtlasRenderItem).spriteCount, 20);
      tile.dispose();
    });

    test('same source, different sizes: still one atlas item', () {
      final e = engine();
      final tile = testImage(32, 32);
      e.image(tile, 0, 0); // 1.0
      e.image(tile, 40, 0, 64, 64); // 2.0
      e.image(tile, 110, 0, 16, 16); // 0.5
      e.image(tile, 10, 70, 48, 48); // 1.5

      final items = itemsOf(e);
      expect(items, hasLength(1));
      expect((items.single as ImageAtlasRenderItem).spriteCount, 4);
      tile.dispose();
    });

    test('a non-proportional stretch drops out of the run', () {
      final e = engine();
      final tile = testImage(32, 32);
      e.image(tile, 0, 0);
      e.image(tile, 40, 0, 64, 16); // stretched — no RSTransform for this
      e.image(tile, 110, 0);

      final items = itemsOf(e);
      // run of 1, the stretched blit, run of 1 — order preserved
      expect(items.map((i) => i.runtimeType).toList(), [
        ImageRenderItem,
        ImageRenderItem,
        ImageRenderItem,
      ]);
      expect(
        (items[1] as ImageRenderItem).dst,
        const Rect.fromLTWH(40, 0, 64, 16),
      );
      tile.dispose();
    });

    test('a different source image closes the run', () {
      final e = engine();
      final a = testImage(32, 32);
      final b = testImage(32, 32);
      e.image(a, 0, 0);
      e.image(a, 40, 0);
      e.image(b, 80, 0);
      e.image(b, 120, 0);

      final items = itemsOf(e);
      expect(items, hasLength(2));
      expect((items[0] as ImageAtlasRenderItem).spriteCount, 2);
      expect((items[1] as ImageAtlasRenderItem).spriteCount, 2);
      expect(
        identical((items[0] as ImageAtlasRenderItem).image, a.uiImage),
        isTrue,
      );
      a.dispose();
      b.dispose();
    });

    test('a blendMode change closes the run', () {
      final e = engine();
      final tile = testImage(32, 32);
      e.image(tile, 0, 0);
      e.image(tile, 40, 0);
      e.blendMode(BlendMode.plus);
      e.image(tile, 80, 0);
      e.image(tile, 120, 0);

      final items = itemsOf(e);
      expect(items, hasLength(2));
      expect((items[0] as ImageAtlasRenderItem).blendMode, BlendMode.srcOver);
      expect((items[1] as ImageAtlasRenderItem).blendMode, BlendMode.plus);
      tile.dispose();
    });

    test('an intervening shape preserves draw order', () {
      final e = engine();
      final tile = testImage(32, 32);
      e.image(tile, 0, 0);
      e.image(tile, 40, 0);
      e.rect(0, 60, 10, 10);
      e.image(tile, 80, 0);
      e.image(tile, 120, 0);

      final items = itemsOf(e);
      expect(items.map((i) => i.runtimeType).toList(), [
        ImageAtlasRenderItem,
        PathRenderItem,
        ImageAtlasRenderItem,
      ]);
      tile.dispose();
    });

    test('an active shadow opts out of batching', () {
      final e = engine();
      final tile = testImage(32, 32);
      e.shadow(4, 4, 8);
      e.image(tile, 0, 0);
      e.image(tile, 40, 0);

      final items = itemsOf(e);
      expect(items, hasLength(2));
      expect(items.every((i) => i is ImageRenderItem), isTrue);
      expect((items.first as ImageRenderItem).shadow, isNotNull);
      tile.dispose();
    });

    test('a lone image stays a plain blit, not a one-sprite atlas', () {
      final e = engine();
      final tile = testImage(32, 32);
      e.image(tile, 5, 7);

      final items = itemsOf(e);
      expect(items.single, isA<ImageRenderItem>());
      expect(
        (items.single as ImageRenderItem).dst,
        const Rect.fromLTWH(5, 7, 32, 32),
      );
      tile.dispose();
    });

    test('the canonical push/translate/pop mosaic batches, no transforms', () {
      final e = engine();
      final tile = testImage(32, 32);
      for (var row = 0; row < 4; row++) {
        for (var col = 0; col < 5; col++) {
          e.push();
          e.translate(col * 32.0, row * 32.0);
          e.image(tile, 0, 0);
          e.pop();
        }
      }

      final items = itemsOf(e);
      expect(items, hasLength(1));
      final atlas = items.single as ImageAtlasRenderItem;
      expect(atlas.spriteCount, 20);
      // Fold offsets landed in the sprite translates, not in transform items.
      expect(atlas.transforms[2], 0.0); // first tile tx
      expect(atlas.transforms[3], 0.0);
      expect(atlas.transforms[4 * 5 + 2], 0.0); // row 1, col 0 -> tx 0
      expect(atlas.transforms[4 * 5 + 3], 32.0); // ty 32
      expect(e.renderQueue.items.whereType<TransformRenderItem>(), isEmpty);
      tile.dispose();
    });

    test('bounds are the union of every sprite destination', () {
      final e = engine();
      final tile = testImage(32, 32);
      e.image(tile, 0, 0);
      e.image(tile, 100, 50, 64, 64);

      final atlas = itemsOf(e).single as ImageAtlasRenderItem;
      expect(atlas.bounds, const Rect.fromLTRB(0, 0, 164, 114));
      tile.dispose();
    });

    test('clear() drops an unflushed run instead of leaking it', () {
      final e = engine();
      final tile = testImage(32, 32);
      e.image(tile, 0, 0);
      e.image(tile, 40, 0); // run still open — never flushed
      e.renderQueue.clear();

      e.image(tile, 80, 0);
      final items = itemsOf(e);
      expect(items.single, isA<ImageRenderItem>());
      expect(
        (items.single as ImageRenderItem).dst,
        const Rect.fromLTWH(80, 0, 32, 32),
      );
      tile.dispose();
    });

    test('batched output is pixel-identical to unbatched', () async {
      final source = twoToneImage(32, 32);
      final tile = Flut5Image.fromUiImage(source);
      const placements = <List<double>>[
        [0, 0, 32, 32],
        [40, 0, 64, 64],
        [110, 0, 16, 16],
        [10, 70, 48, 48],
      ];

      Future<Uint8List> rasterize(void Function(Canvas) body) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 200, 140),
          Paint()..color = const Color(0xFF000000),
        );
        body(canvas);
        final picture = recorder.endRecording();
        final image = picture.toImageSync(200, 140);
        picture.dispose();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      }

      // Reference: what the queue produced before batching existed.
      final reference = await rasterize((canvas) {
        final paint = Paint()..filterQuality = FilterQuality.medium;
        for (final p in placements) {
          canvas.drawImageRect(
            source,
            const Rect.fromLTWH(0, 0, 32, 32),
            Rect.fromLTWH(p[0], p[1], p[2], p[3]),
            paint,
          );
        }
      });

      final e = engine();
      for (final p in placements) {
        e.image(tile, p[0], p[1], p[2], p[3]);
      }
      expect(itemsOf(e).single, isA<ImageAtlasRenderItem>());
      final batched = await rasterize(e.renderQueue.execute);

      var differing = 0;
      for (var i = 0; i < reference.length; i++) {
        if (reference[i] != batched[i]) differing++;
      }
      expect(differing, 0);
      tile.dispose();
    });
  });

  group('Flut5 forwarders', () {
    tearDown(() {
      Flut5Engine.current = null;
    });

    test('the unprefixed image() reaches the sketch engine queue', () {
      Flut5.instanceMode = false;
      Flut5Engine.current = null;
      final sketch = _ImageSketch();
      final img = testImage(20, 10);
      sketch.paint(img);

      sketch.flut5.renderQueue.flushPending();
      final item = sketch.flut5.renderQueue.items
          .whereType<ImageRenderItem>()
          .single;
      expect(item.dst, const Rect.fromLTWH(7, 9, 20, 10));
      img.dispose();
    });

    test('the unprefixed loadImage() is exposed too', () {
      Flut5.instanceMode = false;
      Flut5Engine.current = null;
      final sketch = _ImageSketch();
      expect(sketch.loadImage, isNotNull);
    });
  });
}
