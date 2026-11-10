// How the cached text rasters reach the canvas:
// * drawn at their own pixel size, so text comes out exactly as Flutter's
//   text painter draws it instead of slightly squeezed and resampled;
// * rasterized again when the device pixel ratio changes;
// * fetched from the cache once per line rather than once per glyph per
//   frame, without ever drawing a texture the cache has let go of.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const String _family = 'GlyphBlitFont';
const Color _white = Color(0xFFFFFFFF);

/// A real font: unlike the test environment's, its glyphs have fractional
/// widths, which is what exposes a raster drawn at the wrong size.
Future<void> _loadFont() async {
  final bytes = await File('agent_assets/Gambarino-Regular.otf').readAsBytes();
  final loader = FontLoader(_family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

double get _pixelRatio => TestWidgetsFlutterBinding
    .instance
    .platformDispatcher
    .views
    .first
    .devicePixelRatio;

/// Renders [draw] at device resolution into a [width] × [height] pixel image.
Future<Uint8List> _pixels(
  int width,
  int height,
  void Function(Canvas) draw,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(_pixelRatio);
  draw(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  return bytes;
}

/// Expects [drawn] to be [expected], pixel for pixel. The raster is tinted
/// on its way to the canvas, which on Impeller rounds an edge pixel's alpha
/// one level differently now and then; on Skia the bytes are identical. A
/// raster drawn at the wrong size is off by a hundred levels or more.
void _expectSamePixels(Uint8List drawn, Uint8List expected, {String? reason}) {
  expect(drawn.length, expected.length);
  var worst = 0;
  for (var i = 0; i < drawn.length; i++) {
    final difference = (drawn[i] - expected[i]).abs();
    if (difference > worst) worst = difference;
  }
  expect(worst, lessThanOrEqualTo(1), reason: reason);
}

Flut5CachedText _glyph(String text, double size, {double strokeWidth = 0}) =>
    Flut5TextCache.instance.getOrCreate(
      text: text,
      fontFamily: _family,
      fontSize: size,
      fontWeight: FontWeight.normal,
      fontStyle: FontStyle.normal,
      textLeading: null,
      align: TextAlign.left,
      paintingStyle: strokeWidth == 0 ? 0 : 1,
      strokeWidth: strokeWidth,
    );

TextPainter _painter(String text, double size) => TextPainter(
  text: TextSpan(
    text: text,
    style: TextStyle(fontFamily: _family, fontSize: size, color: _white),
  ),
  textDirection: TextDirection.ltr,
)..layout();

Flut5Engine _engine(double size) => Flut5Engine()
  ..textFont(_family)
  ..textSize(size)
  ..fill(_white)
  ..noStroke();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = Flut5TextCache.instance;

  setUpAll(_loadFont);
  setUp(cache.clear);
  tearDown(() {
    cache.clear();
    cache.maxCacheSize = 1024;
    cache.autoGrow = true;
    cache.timeoutFrames = 600;
  });

  group('Rasters are drawn at their own pixel size', () {
    test('the blit size is the image size over the pixel ratio', () {
      var fractional = 0;
      for (final size in [13.0, 16.0, 22.0, 40.0]) {
        for (final ch in 'AgRe8mWit'.split('')) {
          final cached = _glyph(ch, size);
          expect(cached.blitWidth * _pixelRatio, cached.image.width);
          expect(cached.blitHeight * _pixelRatio, cached.image.height);
          if (cached.blitWidth != cached.drawWidth) fractional++;
        }
      }
      // The font really has glyphs whose width is not a whole pixel count.
      expect(fractional, greaterThan(20));
    });

    test('a glyph comes out exactly as the text painter draws it', () async {
      for (final size in [13.0, 22.0, 40.0]) {
        for (final ch in 'AgRe8mWi'.split('')) {
          final cached = _glyph(ch, size);
          // Put the raster's corner on a whole device pixel: the glyph's
          // pen position is then leftPad to its right.
          final x = 2 / _pixelRatio + cached.leftPad;
          final y = 2 / _pixelRatio;
          final width = cached.image.width + 8;
          final height = cached.image.height + 8;

          final engine = _engine(size)..text(ch, x, y);
          final drawn = await _pixels(
            width,
            height,
            engine.renderQueue.execute,
          );
          final expected = await _pixels(
            width,
            height,
            (canvas) => _painter(ch, size).paint(canvas, Offset(x, y)),
          );
          _expectSamePixels(drawn, expected, reason: '"$ch" at size $size');
        }
      }
    });

    test('static text does too', () async {
      const text = 'Waffle gym';
      final cached = cache.getOrCreate(
        text: text,
        fontFamily: _family,
        fontSize: 22,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.normal,
        textLeading: null,
        letterSpacing: null,
        align: TextAlign.left,
        paintingStyle: 0,
        strokeWidth: 0,
      );
      expect(cached.blitWidth, isNot(cached.drawWidth));
      final x = 2 / _pixelRatio + cached.leftPad;
      final y = 2 / _pixelRatio;
      final width = cached.image.width + 8;
      final height = cached.image.height + 8;

      final engine = _engine(22)..textStatic(text, x, y);
      final drawn = await _pixels(width, height, engine.renderQueue.execute);
      final expected = await _pixels(
        width,
        height,
        (canvas) => _painter(text, 22).paint(canvas, Offset(x, y)),
      );
      _expectSamePixels(drawn, expected);
    });
  });

  testWidgets('a new device pixel ratio rasterizes the text again', (
    tester,
  ) async {
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      cache.finishFrame();
    });
    tester.view.devicePixelRatio = 3;
    cache.finishFrame();
    final atThree = _glyph('W', 40);
    final widthBefore = cache.measureWidth(
      text: 'W',
      fontFamily: _family,
      fontSize: 40,
      fontWeight: FontWeight.normal,
      fontStyle: FontStyle.normal,
    );

    // The window moves to a display with another ratio; the next frame
    // notices.
    tester.view.devicePixelRatio = 2;
    cache.finishFrame();
    expect(atThree.image.debugDisposed, isTrue);

    final atTwo = _glyph('W', 40);
    expect(atTwo.image.width, lessThan(atThree.blitWidth * 3));
    expect(atTwo.blitWidth * 2, atTwo.image.width);
    // Logical measurements don't depend on the ratio.
    expect(atTwo.width, widthBefore);
  });

  group('Glyph rasters kept with the line', () {
    Flut5TextLine lineOf(String text, double size) => cache
        .getOrCreateLayout(
          text: text,
          fontFamily: _family,
          fontSize: size,
          fontWeight: FontWeight.normal,
          fontStyle: FontStyle.normal,
          letterSpacing: 0,
        )
        .lines
        .single;

    Future<Uint8List> draw(Flut5Engine engine, String text) {
      engine.text(text, 4, 4);
      final pixels = _pixels(600, 120, engine.renderQueue.execute);
      engine.renderQueue.clear();
      return pixels;
    }

    test('are the ones the cache holds, after the first draw', () async {
      const text = 'Waffle';
      final engine = _engine(22);
      expect(cache.resolvedGlyphs(lineOf(text, 22), 0, 0), isNull);
      await draw(engine, text);

      final kept = cache.resolvedGlyphs(lineOf(text, 22), 0, 0)!;
      expect(kept, hasLength(6));
      for (var i = 0; i < kept.length; i++) {
        expect(kept[i], same(_glyph(text[i], 22)));
      }
      // The stroke pass keeps its own, per stroke width.
      expect(cache.resolvedGlyphs(lineOf(text, 22), 1, 2), isNull);
      engine
        ..stroke(_white)
        ..strokeWeight(2);
      await draw(engine, text);
      final stroked = cache.resolvedGlyphs(lineOf(text, 22), 1, 2)!;
      expect(stroked.first, same(_glyph('W', 22, strokeWidth: 2)));
      expect(cache.resolvedGlyphs(lineOf(text, 22), 1, 3), isNull);
    });

    test('draw the same picture as fetching every glyph', () async {
      const text = 'Waffle gym 2026';
      final engine = _engine(22);
      final first = await draw(engine, text); // fetches and keeps
      final second = await draw(engine, text); // draws from the kept ones
      expect(second, first);
    });

    test('count as used, so text on screen never expires', () async {
      const text = 'Waffle';
      cache.timeoutFrames = 3;
      final engine = _engine(22);
      await draw(engine, text);
      final raster = _glyph('W', 22);
      for (var frame = 0; frame < 12; frame++) {
        cache.finishFrame();
        await draw(engine, text);
        expect(raster.image.debugDisposed, isFalse);
      }
      // No longer drawn: gone after the timeout, like any other.
      for (var frame = 0; frame < 4; frame++) {
        cache.finishFrame();
      }
      expect(raster.image.debugDisposed, isTrue);
    });

    test('are let go of when the cache drops a texture', () async {
      const text = 'Waffle';
      cache.timeoutFrames = 2;
      final engine = _engine(22);
      final first = await draw(engine, text);
      final line = lineOf(text, 22);
      expect(cache.resolvedGlyphs(line, 0, 0), isNotNull);

      // An unrelated texture expires: any kept raster might be the one.
      _glyph('unrelated', 30);
      for (var frame = 0; frame < 3; frame++) {
        cache.finishFrame();
        cache.resolvedGlyphs(line, 0, 0); // keeps the line's own glyphs used
      }
      expect(cache.resolvedGlyphs(line, 0, 0), isNull);

      // Drawing fetches them afresh and the picture is unchanged.
      expect(await draw(engine, text), first);
      expect(cache.resolvedGlyphs(lineOf(text, 22), 0, 0), isNotNull);
    });

    test('a cache too small for the line still draws every glyph', () async {
      const text = 'Waffle gym 2026';
      final engine = _engine(22);
      final expected = await draw(engine, text);

      cache.clear();
      cache.autoGrow = false;
      cache.maxCacheSize = 4;
      // Textures are evicted while the line is being drawn, every time.
      for (var frame = 0; frame < 3; frame++) {
        expect(await draw(engine, text), expected);
        expect(cache.resolvedGlyphs(lineOf(text, 22), 0, 0), isNull);
        cache.finishFrame();
      }
    });
  });
}
