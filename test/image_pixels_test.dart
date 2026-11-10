import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';
import 'package:flut5/image/flut5_image_handles.dart';
import 'package:flut5/image/flut5_pixel_upload.dart';

// Runs on Skia by default, where updatePixels() takes the atlas route. Run
// with `flutter test --enable-impeller test/image_pixels_test.dart` to cover
// the decodeImageFromPixelsSync route as well.

/// Red left half, blue right half.
Flut5Image twoTone(int width, int height) {
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
  return Flut5Image.fromUiImage(image, source: 'two-tone');
}

List<int> rgbaAt(List<int> pixels, int width, int x, int y) {
  final i = (x + y * width) * 4;
  return pixels.sublist(i, i + 4);
}

Future<Uint8List> straightBytes(ui.Image image) async {
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  return data!.buffer.asUint8List();
}

/// Reference bitmap for an upload: dart:ui's own async raw-pixel decode of
/// the premultiplied buffer.
Future<ui.Image> referenceDecode(Uint8List straight, int width, int height) {
  final premultiplied = Uint8List(straight.length);
  for (var o = 0; o < straight.length; o += 4) {
    final alpha = straight[o + 3];
    for (var channel = 0; channel < 3; channel++) {
      premultiplied[o + channel] = (straight[o + channel] * alpha + 127) ~/ 255;
    }
    premultiplied[o + 3] = alpha;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    premultiplied,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Collects what [Flut5Console] prints at the end of the frame.
List<String> flushWarnings() {
  final printed = <String>[];
  final previous = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) => printed.add('$message');
  try {
    Flut5Console.flush();
  } finally {
    debugPrint = previous;
  }
  return printed;
}

/// Exercises the unprefixed createImage() forwarder.
class _CreateImageSketch extends Flut5Sketch {
  Flut5Image make(int width, int height) => createImage(width, height);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(flushWarnings);
  tearDown(() => Flut5PixelUploader.debugSyncDecodeAvailable = null);

  Flut5Engine engine() => Flut5Engine()..noStroke();

  group('loadPixels', () {
    test('pixels is empty, and says why, until loadPixels completes', () {
      final img = twoTone(8, 4);
      expect(img.pixels, isEmpty);
      expect(flushWarnings().single, contains('await img.loadPixels()'));
      img.dispose();
    });

    test('reads straight RGBA, row by row from the top-left', () async {
      final img = twoTone(8, 4);
      await img.loadPixels();

      expect(img.pixels, hasLength(8 * 4 * 4));
      expect(rgbaAt(img.pixels, 8, 0, 0), [255, 0, 0, 255]);
      expect(rgbaAt(img.pixels, 8, 3, 3), [255, 0, 0, 255]);
      expect(rgbaAt(img.pixels, 8, 4, 0), [0, 0, 255, 255]);
      expect(rgbaAt(img.pixels, 8, 7, 3), [0, 0, 255, 255]);
      img.dispose();
    });

    test('translucent pixels read back unpremultiplied', () async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 2, 2),
        Paint()..color = const Color.fromARGB(128, 100, 50, 20),
      );
      final picture = recorder.endRecording();
      final img = Flut5Image.fromUiImage(picture.toImageSync(2, 2));
      picture.dispose();

      await img.loadPixels();
      expect(rgbaAt(img.pixels, 2, 1, 1), [100, 50, 20, 128]);
      img.dispose();
    });

    test('writes clamp like p5 Uint8ClampedArray', () async {
      final img = twoTone(2, 2);
      await img.loadPixels();
      img.pixels[0] = 300;
      img.pixels[1] = -20;
      expect(img.pixels.sublist(0, 2), [255, 0]);
      img.dispose();
    });

    test('the pixels list object survives reloads and updates', () async {
      final img = twoTone(4, 4);
      await img.loadPixels();
      final held = img.pixels;

      held[0] = 7;
      img.updatePixels();
      await img.loadPixels();

      expect(identical(img.pixels, held), isTrue);
      expect(held[0], 7);
      img.dispose();
    });

    test('a reload discards unsaved edits, as in p5', () async {
      final img = twoTone(4, 4);
      await img.loadPixels();
      img.pixels[0] = 7;
      await img.loadPixels();
      expect(img.pixels[0], 255);
      img.dispose();
    });

    test('a resize during the read loads the resized bitmap', () async {
      final img = twoTone(40, 20);
      await img.loadPixels();
      final reading = img.loadPixels();
      img.resize(10, 5);
      await reading;

      expect(img.pixels, hasLength(10 * 5 * 4));
      img.dispose();
    });

    test('an update during the read is not overwritten by it', () async {
      final img = twoTone(4, 4);
      await img.loadPixels();
      final reading = img.loadPixels();
      img.pixels[0] = 7;
      img.updatePixels();
      await reading;

      expect(img.pixels[0], 7);
      img.dispose();
    });

    test('loadPixels on a disposed image warns and loads nothing', () async {
      final img = twoTone(4, 4)..dispose();
      await img.loadPixels();
      expect(flushWarnings().single, contains('disposed'));
    });
  });

  group('updatePixels', () {
    test('is synchronous: the new bitmap is in place on return', () async {
      final img = twoTone(8, 4);
      await img.loadPixels();
      final before = img.uiImage;
      for (var i = 0; i < img.pixels.length; i += 4) {
        img.pixels[i + 1] = 255; // add green everywhere
      }
      img.updatePixels();

      expect(identical(img.uiImage, before), isFalse);
      final bytes = await straightBytes(img.uiImage);
      expect(rgbaAt(bytes, 8, 0, 0), [255, 255, 0, 255]);
      expect(rgbaAt(bytes, 8, 7, 3), [0, 255, 255, 255]);
      img.dispose();
    });

    test('opaque edits round-trip exactly', () async {
      final random = math.Random(5);
      final img = twoTone(16, 16);
      await img.loadPixels();
      for (var i = 0; i < img.pixels.length; i++) {
        img.pixels[i] = i % 4 == 3 ? 255 : random.nextInt(256);
      }
      final written = Uint8List.fromList(img.pixels);
      img.updatePixels();
      await img.loadPixels();

      expect(img.pixels, written);
      img.dispose();
    });

    test('alpha edits keep the colour channels (straight alpha)', () async {
      final img = twoTone(2, 1);
      await img.loadPixels();
      img.pixels.setAll(0, [100, 50, 20, 128]);
      img.updatePixels();
      await img.loadPixels();

      final pixel = rgbaAt(img.pixels, 2, 0, 0);
      expect(pixel[3], 128);
      for (var channel = 0; channel < 3; channel++) {
        expect(pixel[channel], closeTo([100, 50, 20][channel], 1));
      }
      img.dispose();
    });

    for (final forceAtlas in [false, true]) {
      test(
        forceAtlas
            ? 'the atlas route matches dart:ui raw decoding byte for byte'
            : 'the default route matches dart:ui raw decoding byte for byte',
        () async {
          if (forceAtlas) Flut5PixelUploader.debugSyncDecodeAvailable = false;
          const width = 33, height = 17; // odd sizes catch row-stride slips
          final random = math.Random(11);
          final straight = Uint8ClampedList(width * height * 4);
          for (var i = 0; i < straight.length; i++) {
            straight[i] = random.nextInt(256);
          }

          final uploaded = Flut5PixelUploader().upload(straight, width, height);
          final reference = await referenceDecode(
            Uint8List.fromList(straight),
            width,
            height,
          );
          expect(await straightBytes(uploaded), await straightBytes(reference));
          uploaded.dispose();
          reference.dispose();
        },
      );
    }

    test('the premultiply rounding is exact for every 8-bit pair', () {
      for (var channel = 0; channel < 256; channel++) {
        for (var alpha = 0; alpha < 256; alpha++) {
          final rounded = (channel * alpha + 127) ~/ 255;
          if (Flut5PixelUploader.scaleByAlpha(channel, alpha) != rounded) {
            fail('channel $channel, alpha $alpha');
          }
        }
      }
    });

    test('without loaded pixels it warns and keeps the bitmap', () {
      final img = twoTone(4, 4);
      final before = img.uiImage;
      img.updatePixels();

      expect(identical(img.uiImage, before), isTrue);
      expect(flushWarnings().single, contains('await img.loadPixels()'));
      img.dispose();
    });

    test('resize discards loaded pixels', () async {
      final img = twoTone(8, 8);
      await img.loadPixels();
      img.resize(4, 4);

      expect(img.pixels, isEmpty);
      final before = img.uiImage;
      img.updatePixels();
      expect(identical(img.uiImage, before), isTrue);
      flushWarnings();
      img.dispose();
    });
  });

  group('handles a queued draw still needs', () {
    test('image() right after updatePixels draws the edit', () async {
      final img = twoTone(4, 4);
      await img.loadPixels();
      img.pixels.fillRange(0, img.pixels.length, 255); // opaque white
      img.updatePixels();

      final e = engine()..image(img, 0, 0);
      final recorder = ui.PictureRecorder();
      e.renderQueue.execute(Canvas(recorder));
      final picture = recorder.endRecording();
      final drawn = picture.toImageSync(4, 4);
      picture.dispose();

      expect(rgbaAt(await straightBytes(drawn), 4, 0, 0), [255, 255, 255, 255]);
      drawn.dispose();
      e.renderQueue.clear();
      img.dispose();
    });

    test('draw, update, draw again: each draw keeps its own bitmap', () async {
      final img = twoTone(4, 4);
      await img.loadPixels();
      final e = engine()..image(img, 0, 0);
      final first = img.uiImage;

      img.pixels.fillRange(0, img.pixels.length, 255);
      img.updatePixels();
      e.image(img, 4, 0);

      // Still alive: the queue has not painted it yet.
      expect(first.debugDisposed, isFalse);
      final recorder = ui.PictureRecorder();
      e.renderQueue.execute(Canvas(recorder));
      final picture = recorder.endRecording();
      final drawn = picture.toImageSync(8, 4);
      picture.dispose();
      final bytes = await straightBytes(drawn);
      drawn.dispose();

      expect(rgbaAt(bytes, 8, 0, 0), [255, 0, 0, 255]); // before the edit
      expect(rgbaAt(bytes, 8, 4, 0), [255, 255, 255, 255]); // after it

      e.renderQueue.clear();
      expect(first.debugDisposed, isTrue);
      img.dispose();
    });

    test('resize and dispose wait for queued draws too', () {
      final img = twoTone(8, 8);
      final e = engine()..image(img, 0, 0);
      final original = img.uiImage;
      img.resize(4, 4);
      final resized = img.uiImage;
      e.image(img, 10, 0);
      img.dispose();

      expect(original.debugDisposed, isFalse);
      expect(resized.debugDisposed, isFalse);
      expect(
        () => e.renderQueue.execute(Canvas(ui.PictureRecorder())),
        returnsNormally,
      );

      e.renderQueue.clear();
      expect(original.debugDisposed, isTrue);
      expect(resized.debugDisposed, isTrue);
    });

    test('an image held by two queues is freed after both clear', () {
      final img = twoTone(4, 4);
      final first = engine()..image(img, 0, 0);
      final second = engine()..image(img, 0, 0);
      final handle = img.uiImage;
      img.dispose();

      first.renderQueue.clear();
      expect(handle.debugDisposed, isFalse);
      second.renderQueue.clear();
      expect(handle.debugDisposed, isTrue);
    });

    test('an atlas run holds its bitmap once, not once per sprite', () {
      final img = twoTone(4, 4);
      final e = engine();
      for (var i = 0; i < 50; i++) {
        e.image(img, i * 4.0, 0);
      }
      final handle = img.uiImage;
      expect(Flut5ImageHandles.debugHoldCount(handle), 1);
      e.renderQueue.clear();
      expect(Flut5ImageHandles.debugHoldCount(handle), 0);
      img.dispose();
      expect(handle.debugDisposed, isTrue);
    });

    test('an unqueued bitmap is freed at once', () async {
      final img = twoTone(4, 4);
      await img.loadPixels();
      final before = img.uiImage;
      img.updatePixels();
      expect(before.debugDisposed, isTrue);
      img.dispose();
    });
  });

  group('get', () {
    test('returns the pixel colour, straight alpha', () async {
      final img = Flut5Image.create(3, 2);
      img.pixels.setAll((2 + 1 * 3) * 4, [100, 50, 20, 128]);

      expect(img.get(2, 1), const Color.fromARGB(128, 100, 50, 20));
      expect(img.get(0, 0), const Color(0x00000000));
      img.dispose();
    });

    test('reads a loaded image', () async {
      final img = twoTone(8, 4);
      await img.loadPixels();
      expect(img.get(1, 2), const Color(0xFFFF0000));
      expect(img.get(6, 2), const Color(0xFF0000FF));
      img.dispose();
    });

    test('fractional coordinates pick the pixel they fall in', () async {
      final img = twoTone(8, 4);
      await img.loadPixels();
      expect(img.get(3.99, 0.5), const Color(0xFFFF0000));
      expect(img.get(4.0, 3.7), const Color(0xFF0000FF));
      img.dispose();
    });

    test('outside the image it is transparent black, quietly', () async {
      final img = twoTone(8, 4);
      await img.loadPixels();
      for (final (x, y) in [
        (-1, 0),
        (0, -0.5),
        (8, 0),
        (0, 4),
        (double.nan, 0),
        (double.infinity, 0),
      ]) {
        expect(img.get(x, y), const Color(0x00000000), reason: '($x, $y)');
      }
      expect(flushWarnings(), isEmpty);
      img.dispose();
    });

    test('before loadPixels it warns and returns transparent', () {
      final img = twoTone(8, 4);
      expect(img.get(1, 1), const Color(0x00000000));
      expect(flushWarnings().single, contains('await img.loadPixels()'));
      img.dispose();
    });
  });

  group('set', () {
    test('writes straight RGBA into pixels without touching the bitmap', () {
      final img = Flut5Image.create(3, 2);
      final before = img.uiImage;
      img.set(1, 1, const Color.fromARGB(128, 100, 50, 20));

      expect(rgbaAt(img.pixels, 3, 1, 1), [100, 50, 20, 128]);
      expect(img.get(1, 1), const Color.fromARGB(128, 100, 50, 20));
      expect(identical(img.uiImage, before), isTrue);
      img.dispose();
    });

    test('shows on screen after updatePixels', () async {
      final img = Flut5Image.create(4, 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          img.set(x, y, x < 2 ? Colors.white : Colors.black);
        }
      }
      img.updatePixels();

      final bytes = await straightBytes(img.uiImage);
      expect(rgbaAt(bytes, 4, 1, 3), [255, 255, 255, 255]);
      expect(rgbaAt(bytes, 4, 2, 0), [0, 0, 0, 255]);
      img.dispose();
    });

    test('replaces the pixel rather than blending over it', () {
      final img = Flut5Image.create(1, 1);
      img.set(0, 0, Colors.red);
      img.set(0, 0, const Color(0x00000000));
      expect(img.pixels, [0, 0, 0, 0]);
      img.dispose();
    });

    test('outside the image it is ignored, quietly', () {
      final img = Flut5Image.create(2, 2);
      img.set(-1, 0, Colors.red);
      img.set(2, 0, Colors.red);
      img.set(0, double.nan, Colors.red);
      expect(img.pixels.every((byte) => byte == 0), isTrue);
      expect(flushWarnings(), isEmpty);
      img.dispose();
    });

    test('fractional coordinates pick the pixel they fall in', () {
      final img = Flut5Image.create(4, 4);
      img.set(2.7, 1.2, Colors.white);
      expect(rgbaAt(img.pixels, 4, 2, 1), [255, 255, 255, 255]);
      img.dispose();
    });

    test('a Display P3 colour is converted to sRGB', () {
      final img = Flut5Image.create(2, 1);
      const p3White = Color.from(
        alpha: 1,
        red: 1,
        green: 1,
        blue: 1,
        colorSpace: ui.ColorSpace.displayP3,
      );
      // P3's pure red lies outside sRGB: it clamps to sRGB's own red.
      const p3Red = Color.from(
        alpha: 1,
        red: 1,
        green: 0,
        blue: 0,
        colorSpace: ui.ColorSpace.displayP3,
      );
      img.set(0, 0, p3White);
      img.set(1, 0, p3Red);
      expect(rgbaAt(img.pixels, 2, 0, 0), [255, 255, 255, 255]);
      expect(rgbaAt(img.pixels, 2, 1, 0), [255, 0, 0, 255]);
      img.dispose();
    });

    test('before loadPixels it warns and writes nothing', () {
      final img = twoTone(4, 4);
      img.set(0, 0, Colors.white);
      expect(flushWarnings().single, contains('set() ignored'));
      expect(img.pixels, isEmpty);
      flushWarnings();
      img.dispose();
    });
  });

  group('createImage', () {
    test('is blank and transparent, with pixels ready', () async {
      final img = Flut5Image.create(5, 3);
      expect(img.width, 5);
      expect(img.height, 3);
      expect(img.pixels, hasLength(5 * 3 * 4));
      expect(img.pixels.every((byte) => byte == 0), isTrue);
      expect(
        (await straightBytes(img.uiImage)).every((byte) => byte == 0),
        isTrue,
      );
      expect(flushWarnings(), isEmpty);
      img.dispose();
    });

    test('loadPixels on a created image is harmless', () async {
      final img = Flut5Image.create(4, 4);
      final held = img.pixels;
      await img.loadPixels();
      expect(identical(img.pixels, held), isTrue);
      expect(held.every((byte) => byte == 0), isTrue);
      img.dispose();
    });

    test('a size below 1 is a RangeError', () {
      expect(() => Flut5Image.create(0, 4), throwsRangeError);
      expect(() => Flut5Image.create(4, -1), throwsRangeError);
    });

    test('draws what set() wrote', () async {
      final img = Flut5Image.create(2, 2)
        ..set(1, 1, Colors.white)
        ..updatePixels();
      final e = engine()..image(img, 0, 0);
      final recorder = ui.PictureRecorder();
      e.renderQueue.execute(Canvas(recorder));
      final picture = recorder.endRecording();
      final drawn = picture.toImageSync(2, 2);
      picture.dispose();
      final bytes = await straightBytes(drawn);
      drawn.dispose();

      expect(rgbaAt(bytes, 2, 1, 1), [255, 255, 255, 255]);
      expect(rgbaAt(bytes, 2, 0, 0), [0, 0, 0, 0]);
      e.renderQueue.clear();
      img.dispose();
    });

    group('unprefixed', () {
      tearDown(() => Flut5Engine.current = null);

      test('createImage() is forwarded to sketch authors', () {
        Flut5.instanceMode = false;
        Flut5Engine.current = null;
        final img = _CreateImageSketch().make(3, 2);
        expect(img.width, 3);
        expect(img.pixels, hasLength(3 * 2 * 4));
        img.dispose();
      });
    });
  });

  group('getRegion', () {
    /// A [width]×[height] image of random straight RGBA, translucent pixels
    /// included, pushed to the bitmap.
    Flut5Image randomImage(int width, int height, int seed) {
      final random = math.Random(seed);
      final img = Flut5Image.create(width, height);
      for (var i = 0; i < img.pixels.length; i++) {
        img.pixels[i] = random.nextInt(256);
      }
      img.updatePixels();
      return img;
    }

    /// Rows [top, top + height) × columns [left, left + width) of [bytes].
    List<int> slice(
      Uint8List bytes,
      int stride,
      int left,
      int top,
      int width,
      int height,
    ) => [
      for (var y = top; y < top + height; y++)
        ...bytes.sublist(
          (left + y * stride) * 4,
          (left + width + y * stride) * 4,
        ),
    ];

    test('copies the region exactly, translucent pixels included', () async {
      final img = randomImage(20, 12, 3);
      final region = img.getRegion(5, 3, 9, 7);

      expect(region.width, 9);
      expect(region.height, 7);
      final whole = await straightBytes(img.uiImage);
      expect(await straightBytes(region.uiImage), slice(whole, 20, 5, 3, 9, 7));
      img.dispose();
      region.dispose();
    });

    test('is synchronous and needs no loadPixels on the source', () {
      final img = twoTone(8, 4);
      final region = img.getRegion(0, 0, 2, 2);
      expect(flushWarnings(), isEmpty);
      expect(region.pixels, isEmpty); // its own pixels still need loading
      flushWarnings();
      img.dispose();
      region.dispose();
    });

    test('the part past the edge comes out transparent', () async {
      final img = twoTone(8, 4);
      final region = img.getRegion(6, -1, 4, 3);
      await region.loadPixels();

      expect(region.get(0, 0), const Color(0x00000000)); // above the image
      expect(region.get(0, 1), const Color(0xFF0000FF)); // image (6, 0)
      expect(region.get(1, 2), const Color(0xFF0000FF)); // image (7, 1)
      expect(region.get(2, 1), const Color(0x00000000)); // right of it
      img.dispose();
      region.dispose();
    });

    test('a region wholly outside the image is blank', () async {
      final img = twoTone(8, 4);
      final region = img.getRegion(100, 100, 3, 3);
      expect(
        (await straightBytes(region.uiImage)).every((byte) => byte == 0),
        isTrue,
      );
      img.dispose();
      region.dispose();
    });

    test('fractional coordinates pick the pixel they fall in', () async {
      final img = twoTone(8, 4);
      final region = img.getRegion(3.9, 0.4, 2, 1);
      await region.loadPixels();
      expect(region.get(0, 0), const Color(0xFFFF0000)); // image (3, 0)
      expect(region.get(1, 0), const Color(0xFF0000FF)); // image (4, 0)
      img.dispose();
      region.dispose();
    });

    test(
      'copies the bitmap, not edits still waiting for updatePixels',
      () async {
        final img = Flut5Image.create(2, 2)..set(0, 0, Colors.white);
        final region = img.getRegion(0, 0, 2, 2);
        await region.loadPixels();
        expect(region.get(0, 0), const Color(0x00000000));
        img.dispose();
        region.dispose();
      },
    );

    test('the copy is independent of its source', () async {
      final img = twoTone(8, 4);
      await img.loadPixels();
      final region = img.getRegion(0, 0, 4, 4);

      img.pixels.fillRange(0, img.pixels.length, 255);
      img.updatePixels();
      img.dispose();

      await region.loadPixels();
      expect(region.get(0, 0), const Color(0xFFFF0000));
      region.dispose();
    });

    test('a size below 1 is a RangeError', () {
      final img = twoTone(8, 4);
      expect(() => img.getRegion(0, 0, 0, 2), throwsRangeError);
      expect(() => img.getRegion(0, 0, 2, -3), throwsRangeError);
      img.dispose();
    });

    test('a disposed source gives a transparent image and a warning', () async {
      final img = twoTone(8, 4)..dispose();
      final region = img.getRegion(0, 0, 2, 2);
      expect(region.width, 2);
      expect(
        (await straightBytes(region.uiImage)).every((byte) => byte == 0),
        isTrue,
      );
      expect(flushWarnings().single, contains('disposed'));
      region.dispose();
    });
  });

  test('the p5 example: load, read, edit, update, draw', () async {
    final img = twoTone(6, 2);
    await img.loadPixels();
    for (var y = 0; y < img.height; y++) {
      for (var x = 0; x < img.width; x++) {
        final i = (x + y * img.width) * 4;
        final r = img.pixels[i];
        final b = img.pixels[i + 2];
        img.pixels[i] = b; // swap red and blue
        img.pixels[i + 2] = r;
      }
    }
    img.updatePixels();

    await img.loadPixels();
    expect(rgbaAt(img.pixels, 6, 0, 0), [0, 0, 255, 255]);
    expect(rgbaAt(img.pixels, 6, 5, 1), [255, 0, 0, 255]);
    img.dispose();
  });
}
