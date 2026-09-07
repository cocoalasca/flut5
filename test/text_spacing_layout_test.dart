import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = Flut5TextCache.instance;
  setUp(cache.clear);
  tearDown(cache.clear);

  Flut5TextLayout layout(String text, double spacing) =>
      cache.getOrCreateLayout(
        text: text,
        fontFamily: 'sans-serif',
        fontSize: 21,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.italic,
        letterSpacing: spacing,
      );

  test('composed spacing matches measured offsets including whitespace', () {
    for (final text in [
      '',
      'A',
      'AV Hello  World',
      '  A\tB  ',
      '\nA\n\nB\n',
      ' \t ',
      'A\u00a0B\u2003C',
      'A😀B',
      'e\u0301AV',
    ]) {
      final base = layout(text, 0);
      for (final spacing in [-4.75, 0.0, .0137, 2.5, 31.12345]) {
        final expected = layout(text, spacing);
        expect(base.lines.length, expected.lines.length);
        for (var i = 0; i < base.lines.length; i++) {
          final a = base.lines[i];
          final b = expected.lines[i];
          expect(a.glyphs, b.glyphs);
          expect(a.hasChars, b.hasChars);
          expect(a.widthWithSpacing(spacing), closeTo(b.width, 1e-9));
          for (var j = 0; j < a.glyphs.length; j++) {
            expect(
              a.offsetWithSpacing(j, spacing),
              closeTo(b.offsets[j], 1e-9),
            );
          }
        }
      }
    }
  });

  TextDynamicRenderItem item({
    required double spacing,
    double? maxWidth,
    TextAlign align = TextAlign.left,
    bool decorated = false,
    bool strokeOnly = false,
  }) => TextDynamicRenderItem(
    text: 'AV Hello  World\nSecond line',
    x: 180,
    y: 16,
    maxWidth: maxWidth,
    maxHeight: 70,
    fontFamily: 'sans-serif',
    fontSize: 21,
    fontWeight: FontWeight.normal,
    fontStyle: FontStyle.italic,
    textAlign: align,
    textLeading: 1.2,
    letterSpacing: spacing,
    fillPaint: strokeOnly ? null : (Paint()..color = const Color(0x998844EE)),
    strokePaint: decorated
        ? (Paint()
            ..strokeWidth = 1.5
            ..color = Colors.orange)
        : null,
    fillGradient: decorated && !strokeOnly
        ? const LinearGradient(colors: [Colors.blue, Colors.red])
        : null,
    strokeGradient: decorated
        ? const LinearGradient(colors: [Colors.green, Colors.orange])
        : null,
    shadow: decorated
        ? Flut5ShadowSpec(const Color(0x88000000), const Offset(2, 3), 2, 0)
        : null,
  );

  Future<Uint8List> pixels(TextDynamicRenderItem text) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    canvas.translate(11.3, 7.1);
    canvas.rotate(.037);
    text.execute(canvas);
    final picture = recorder.endRecording();
    final image = await picture.toImage(500, 140);
    picture.dispose();
    final data = (await image.toByteData())!.buffer.asUint8List();
    image.dispose();
    return data;
  }

  test(
    'rendering matches baked spacing for alignment, gradients and shadows',
    () async {
      for (final align in [TextAlign.left, TextAlign.center, TextAlign.right]) {
        for (final style in [0, 1, 2]) {
          for (final spacing in [-2.25, .0137, 3.125]) {
            // Infinite width uses the original spacing-baked pipeline without
            // introducing any line breaks. No line starts with whitespace here.
            final reference = await pixels(
              item(
                spacing: spacing,
                maxWidth: double.infinity,
                align: align,
                decorated: style > 0,
                strokeOnly: style == 2,
              ),
            );
            final actual = await pixels(
              item(
                spacing: spacing,
                align: align,
                decorated: style > 0,
                strokeOnly: style == 2,
              ),
            );
            expect(
              actual,
              reference,
              reason: '$align style=$style spacing=$spacing',
            );
          }
        }
      }
    },
  );

  test('unwrapped spacing animation retains one layout without quantizing', () {
    for (var i = 0; i < 300; i++) {
      final recorder = ui.PictureRecorder();
      item(spacing: i * .0137).execute(Canvas(recorder));
      recorder.endRecording().dispose();
    }
    expect(cache.layoutCacheLength, 1);
  });

  test('finite-width wrapping still keys layouts by exact spacing', () {
    for (final spacing in [0.0, 2.5, 9.0]) {
      final recorder = ui.PictureRecorder();
      item(spacing: spacing, maxWidth: 130).execute(Canvas(recorder));
      recorder.endRecording().dispose();
    }
    expect(cache.layoutCacheLength, 3);
  });

  test('public spacing and line-height animations reuse warmed caches', () async {
    final engine = Flut5Engine();
    engine.textSize(21);
    engine.noStroke();
    engine.fill(Colors.white);

    Future<Uint8List> render(double spacing, double lineHeight) async {
      engine.letterSpacing(spacing);
      engine.textLeading(lineHeight);
      engine.textDynamic('Hello\nWorld', 20, 10);
      final recorder = ui.PictureRecorder();
      engine.renderQueue.execute(Canvas(recorder));
      engine.renderQueue.clear();
      final picture = recorder.endRecording();
      final image = await picture.toImage(400, 180);
      picture.dispose();
      final data = (await image.toByteData())!.buffer.asUint8List();
      image.dispose();
      return data;
    }

    final original = await render(0, 30);
    final textureCount = cache.cacheLength;
    final textureBytes = cache.cacheBytes;
    expect(textureCount, greaterThan(0));
    expect(cache.layoutCacheLength, 1);

    // Each attribute must independently change the rendered result.
    final wider = await render(3.125, 30);
    expect(wider, isNot(orderedEquals(original)));
    final taller = await render(3.125, 47.375);
    expect(taller, isNot(orderedEquals(wider)));

    for (var i = 0; i < 20; i++) {
      await render(-1.25 + i * .137, 25.5 + i * .713);
      expect(cache.layoutCacheLength, 1);
      expect(cache.cacheLength, textureCount);
      expect(cache.cacheBytes, textureBytes);
    }
    expect(await render(0, 30), orderedEquals(original));
  });

  test('texture eviction leaves reusable layout geometry valid', () {
    final oldCap = cache.maxCacheSize;
    final oldGrow = cache.autoGrow;
    cache.maxCacheSize = 2;
    cache.autoGrow = false;
    try {
      for (var i = 0; i < 4; i++) {
        final recorder = ui.PictureRecorder();
        item(spacing: i * .13).execute(Canvas(recorder));
        recorder.endRecording().dispose();
      }
      expect(cache.layoutCacheLength, 1);
      expect(cache.cacheLength, lessThanOrEqualTo(2));
    } finally {
      cache.maxCacheSize = oldCap;
      cache.autoGrow = oldGrow;
      Flut5Console.flush();
    }
  });
}
