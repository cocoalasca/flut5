import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A blurred or spread text shadow bakes its silhouette once per glyph
/// raster and blits it every frame after. These pin that the bake looks like
/// filtering the raster live, and that it is reused.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cache = Flut5TextCache.instance;
  setUp(cache.clear);
  tearDown(cache.clear);

  Flut5CachedText raster(String text, {double size = 40}) => cache.getOrCreate(
    text: text,
    fontFamily: '',
    fontSize: size,
    fontWeight: FontWeight.normal,
    fontStyle: FontStyle.normal,
    textLeading: null,
    align: TextAlign.left,
    paintingStyle: 0,
    strokeWidth: 0,
  );

  Rect placed(Flut5CachedText t, double x, double y) =>
      Rect.fromLTWH(x - t.leftPad, y, t.drawWidth, t.height);

  /// The shadow filtered live, every draw — what the bake stands in for.
  Paint live(Flut5ShadowSpec s) {
    final sigma = Shadow.convertRadiusToSigma(s.blur);
    final blur = ui.ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: TileMode.decal,
    );
    return Paint()
      ..colorFilter = ColorFilter.mode(s.color, BlendMode.srcIn)
      ..filterQuality = cache.textBlitQuality
      ..imageFilter = s.spread > 0
          ? ui.ImageFilter.compose(
              outer: blur,
              inner: ui.ImageFilter.dilate(
                radiusX: s.spread,
                radiusY: s.spread,
              ),
            )
          : blur;
  }

  group('Baked text shadows', () {
    for (final (blur, spread) in [(6.0, 0.0), (5.0, 3.0)]) {
      test('match the live filter — blur $blur, spread $spread', () async {
        final t = raster('Gq');
        final spec = Flut5ShadowSpec(
          const Color(0xFF6020A0),
          const Offset(4, 6),
          blur,
          spread,
        );
        // At the raster's own resolution — the screen's — the bake is the
        // live filter's output up to rounding: Impeller's downsampled blur
        // moves a few levels with where its layer starts. Off it, the
        // silhouette is resampled rather than blurred in place.
        final ratio =
            ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
        final cases = [(ratio, 0.0, 6), (1.0, 0.0, 12), (ratio, .4, 12)];
        for (final (scale, rotation, tolerance) in cases) {
          void place(Canvas c) => c
            ..scale(scale)
            ..translate(60, 40)
            ..rotate(rotation);
          final size = (200 * scale).ceil();
          final baked = await _pixels((c) {
            place(c);
            spec.paintText(c, t, placed(t, 0, 0));
          }, size);
          final expected = await _pixels((c) {
            place(c);
            c.drawImageRect(
              t.image,
              t.srcRect,
              placed(t, 0, 0).shift(spec.offset),
              live(spec),
            );
          }, size);
          expect(
            _worst(baked, expected),
            lessThanOrEqualTo(tolerance),
            reason: 'scale $scale, rotation $rotation',
          );
        }
      });
    }

    test('are actually blurred when there is no spread', () async {
      // A mask filter on an image draw only softens the destination rect's
      // edge, leaving the glyphs sharp; the bake blurs the glyphs.
      final t = raster('G');
      final spec = Flut5ShadowSpec(Colors.black, Offset.zero, 8, 0);
      final sharp = await _pixels(
        (c) => c.drawImageRect(t.image, t.srcRect, placed(t, 20, 20), Paint()),
      );
      final baked = await _pixels(
        (c) => spec.paintText(c, t, placed(t, 20, 20)),
      );
      expect(_worst(baked, sharp), greaterThan(100));
    });

    test('a hard shadow blits the raster itself and bakes nothing', () {
      final t = raster('G');
      final before = cache.cacheBytes;
      final recorder = ui.PictureRecorder();
      Flut5ShadowSpec(
        Colors.black,
        const Offset(2, 2),
        0,
        0,
      ).paintText(Canvas(recorder), t, placed(t, 0, 0));
      recorder.endRecording().dispose();
      expect(cache.cacheBytes, before);
    });

    test('bake once per blur and spread, whatever the color or offset', () {
      final t = raster('G');
      int bytesAfter(Flut5ShadowSpec s) {
        final recorder = ui.PictureRecorder();
        s.paintText(Canvas(recorder), t, placed(t, 0, 0));
        recorder.endRecording().dispose();
        return cache.cacheBytes;
      }

      final start = cache.cacheBytes;
      final first = bytesAfter(
        Flut5ShadowSpec(Colors.black, const Offset(2, 2), 6, 0),
      );
      expect(first, greaterThan(start));
      // A new spec with the same numbers — shadow() called again — and new
      // color and offset: all reuse the bake.
      expect(
        bytesAfter(Flut5ShadowSpec(Colors.black, const Offset(2, 2), 6, 0)),
        first,
      );
      expect(
        bytesAfter(Flut5ShadowSpec(Colors.red, const Offset(-5, 9), 6, 0)),
        first,
      );
      // A new blur bakes a second silhouette.
      expect(
        bytesAfter(Flut5ShadowSpec(Colors.black, Offset.zero, 9, 0)),
        greaterThan(first),
      );
    });

    test('keep at most four silhouettes per raster, and leave with it', () {
      final t = raster('G');
      final base = cache.cacheBytes;
      final sizes = <int>[];
      for (var blur = 1; blur <= 6; blur++) {
        final recorder = ui.PictureRecorder();
        Flut5ShadowSpec(
          Colors.black,
          Offset.zero,
          blur.toDouble(),
          0,
        ).paintText(Canvas(recorder), t, placed(t, 0, 0));
        recorder.endRecording().dispose();
        sizes.add(cache.cacheBytes - base);
      }
      // Bakes 5 and 6 replaced bakes 1 and 2.
      expect(t.bytes - t.image.width * t.image.height * 4, sizes.last);
      expect(sizes[5] - sizes[4], lessThan(sizes[3] - sizes[2]));
      cache.clear();
      expect(cache.cacheBytes, 0);
    });

    test('text items draw the baked shadow', () async {
      final spec = Flut5ShadowSpec(Colors.black, const Offset(3, 3), 6, 2);
      final item = TextRenderItem(
        text: 'Hi',
        x: 20,
        y: 20,
        fontFamily: '',
        fontSize: 40,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.normal,
        textAlign: TextAlign.left,
        textLeading: null,
        fillPaint: Paint()..color = Colors.white,
        shadow: spec,
      );
      final drawn = await _pixels(item.execute);
      final t = cache.getOrCreate(
        text: 'Hi',
        fontFamily: '',
        fontSize: 40,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.normal,
        textLeading: null,
        align: TextAlign.left,
        paintingStyle: 0,
        strokeWidth: 0,
      );
      final expected = await _pixels((c) {
        spec.paintText(c, t, placed(t, 20, 20));
        c.drawImageRect(
          t.image,
          t.srcRect,
          placed(t, 20, 20),
          Paint()
            ..colorFilter = const ColorFilter.mode(
              Colors.white,
              BlendMode.srcIn,
            )
            ..filterQuality = cache.textBlitQuality,
        );
      });
      expect(drawn, expected);
    });
  });
}

Future<Uint8List> _pixels(void Function(Canvas) draw, [int size = 200]) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size * 4 ~/ 5);
  final data = await image.toByteData();
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

int _worst(Uint8List a, Uint8List b) {
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > worst) worst = d;
  }
  return worst;
}
