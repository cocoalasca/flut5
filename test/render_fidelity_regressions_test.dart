// Pins rendering that must stay faithful and the speedups that rely on it:
// text against Flutter's own text renderer, shadows, scroll containers,
// pixelate crops, cross-kind batching, and the physics broadphases.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flut5/core/render/flut5_paint_bounds.dart';
import 'package:flut5/flut5.dart';
import 'package:flut5/image/flut5_image_shadows.dart';
import 'package:flut5/text/flut5_text_shaping.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const String _family = 'RegressionFont';
const Color _white = Color(0xFFFFFFFF);
const Color _black = Color(0xFF000000);

double get _ratio => TestWidgetsFlutterBinding
    .instance
    .platformDispatcher
    .views
    .first
    .devicePixelRatio;

/// The software GPU of `flutter test --enable-impeller` samples a large
/// atlas page a few levels off on steep edges; real Metal doesn't.
int get _textTolerance => ui.ImageFilter.isShaderFilterSupported ? 4 : 1;

Future<Uint8List> _render(
  int width,
  int height,
  void Function(Canvas) draw, {
  double scale = 1,
  Color clear = _black,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(clear, BlendMode.src);
  if (scale != 1) canvas.scale(scale);
  draw(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  return bytes;
}

int _worst(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final difference = (a[i] - b[i]).abs();
    if (difference > worst) worst = difference;
  }
  return worst;
}

TextPainter _native(String text, double size, {Paint? foreground}) =>
    TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: _family,
          fontSize: size,
          color: foreground == null ? _white : null,
          foreground: foreground,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

Flut5Engine _textEngine(double size) => Flut5Engine()
  ..noStroke()
  ..fill(_white)
  ..textFont(_family)
  ..textSize(size);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = Flut5TextCache.instance;

  setUpAll(() async {
    final bytes = await File('agent_assets/Gambarino-Regular.otf')
        .readAsBytes();
    final loader = FontLoader(_family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  });
  setUp(cache.clear);
  tearDown(cache.clear);

  group('Text comes out as Flutter draws it', () {
    test('at fractional positions, glyph for glyph', () async {
      final rng = math.Random(3);
      for (final size in [14.0, 22.0, 34.0]) {
        for (var i = 0; i < 4; i++) {
          final x = 4 + rng.nextDouble() * 3, y = 4 + rng.nextDouble() * 3;
          final width = ((size * 11 + 16) * _ratio).round();
          final height = ((size * 2 + 12) * _ratio).round();
          final engine = _textEngine(size)..text('Hamburg quick', x, y);
          final drawn = await _render(
            width,
            height,
            engine.renderQueue.execute,
            scale: _ratio,
          );
          final expected = await _render(
            width,
            height,
            (c) => _native('Hamburg quick', size).paint(c, Offset(x, y)),
            scale: _ratio,
          );
          expect(
            _worst(drawn, expected),
            lessThanOrEqualTo(_textTolerance),
            reason: 'size $size at ($x, $y)',
          );
        }
      }
    });

    test('ligatures stay one glyph', () async {
      final line = cache
          .getOrCreateLayout(
            text: 'first',
            fontFamily: _family,
            fontSize: 30,
            fontWeight: FontWeight.normal,
            fontStyle: FontStyle.normal,
            letterSpacing: 0,
          )
          .lines
          .single;
      expect(line.glyphs, contains('fi'));
      expect(line.sourceText, 'first');

      final width = (240 * _ratio).round(), height = (70 * _ratio).round();
      final engine = _textEngine(30)..text('first office', 6, 6);
      final drawn = await _render(
        width,
        height,
        engine.renderQueue.execute,
        scale: _ratio,
      );
      final expected = await _render(
        width,
        height,
        (c) => _native('first office', 30).paint(c, const Offset(6, 6)),
        scale: _ratio,
      );
      expect(_worst(drawn, expected), lessThanOrEqualTo(_textTolerance));
    });

    test('scripts that join or reorder are drawn as a whole string', () {
      for (final text in [
        'مرحبا',
        'שלום',
        'नमस्ते',
        'สวัสดี',
        'café',
        '👨‍👩‍👧',
        '🇨🇴',
      ]) {
        expect(flut5TextNeedsShaping(text), isTrue, reason: text);
        final engine = _textEngine(20)..text(text, 0, 0);
        engine.renderQueue.flushPending();
        expect(engine.renderQueue.items.single, isA<TextRenderItem>());
      }
      for (final text in ['Hello', 'Ñandú', 'Привет', 'Γειά', '漢字', '😀']) {
        expect(flut5TextNeedsShaping(text), isFalse, reason: text);
      }
    });

    test('a thick stroke keeps its descenders', () async {
      const size = 60.0, weight = 14.0;
      final width = (300 * _ratio).round(), height = (170 * _ratio).round();
      final outline = Paint()
        ..color = _white
        ..style = PaintingStyle.stroke
        ..strokeWidth = weight;
      final expected = await _render(
        width,
        height,
        (c) => _native(
          'Hgjy',
          size,
          foreground: outline,
        ).paint(c, const Offset(24, 24)),
        scale: _ratio,
      );
      for (final draw in <void Function(Flut5Engine)>[
        (e) => e.textDynamic('Hgjy', 24, 24),
        (e) => e.textStatic('Hgjy', 24, 24),
      ]) {
        final engine = _textEngine(size)
          ..noFill()
          ..stroke(_white)
          ..strokeWeight(weight);
        draw(engine);
        final drawn = await _render(
          width,
          height,
          engine.renderQueue.execute,
          scale: _ratio,
        );
        int lastInkRow(Uint8List px) {
          for (var y = height - 1; y >= 0; y--) {
            for (var x = 0; x < width; x++) {
              if (px[(y * width + x) * 4] > 128) return y;
            }
          }
          return -1;
        }

        expect(lastInkRow(drawn), lastInkRow(expected));
      }
    });

    test('text under scale() is rasterized at that scale', () async {
      final width = (320 * _ratio).round(), height = (90 * _ratio).round();
      final engine = _textEngine(12)
        ..translate(10, 10)
        ..scale(3)
        ..text('Scaled', 0, 0);
      final drawn = await _render(
        width,
        height,
        engine.renderQueue.execute,
        scale: _ratio,
      );
      final expected = await _render(width, height, (c) {
        c
          ..translate(10, 10)
          ..scale(3);
        _native('Scaled', 12).paint(c, Offset.zero);
      }, scale: _ratio);
      expect(_worst(drawn, expected), lessThanOrEqualTo(_textTolerance));
    });

    test('static text with a shadow draws without debug-only APIs', () async {
      // Reading Image.debugDisposed throws in profile and release builds.
      final source = File('lib/core/render/items/flut5_text_render_item.dart')
          .readAsStringSync();
      expect(source, isNot(contains('debugDisposed')));
      final engine = _textEngine(20)
        ..shadow(2, 2, 3, const Color(0xFF3060FF))
        ..textStatic('Shadow', 10, 10);
      final drawn = await _render(200, 60, engine.renderQueue.execute);
      expect(drawn.any((byte) => byte > 0), isTrue);
    });
  });

  group('Glyph atlas', () {
    test('a batch that overflows it keeps every glyph', () async {
      final chars = [
        for (var c = 0x21; c < 0x7F; c++) String.fromCharCode(c),
        for (var c = 0xC0; c < 0x100; c++) String.fromCharCode(c),
      ];
      const columns = 26, cell = 96;
      final draws = [
        for (final size in [48.0, 46.0])
          for (final ch in chars) (ch, size),
      ];
      final rows = (draws.length / columns).ceil();
      final width = columns * cell, height = rows * cell;
      Offset place(int i) =>
          Offset((i % columns) * cell + 4.0, (i ~/ columns) * cell + 4.0);

      final expected = await _render(width, height, (c) {
        for (var i = 0; i < draws.length; i++) {
          _native(draws[i].$1, draws[i].$2).paint(c, place(i));
        }
      });
      bool hasInk(Uint8List px, int i) {
        final left = (i % columns) * cell, top = (i ~/ columns) * cell;
        for (var y = top; y < top + cell; y++) {
          for (var x = left; x < left + cell; x++) {
            if (px[(y * width + x) * 4] > 128) return true;
          }
        }
        return false;
      }

      // The first frame overflows the page limit; the second has grown it.
      for (var frame = 0; frame < 2; frame++) {
        final engine = _textEngine(48);
        for (var i = 0; i < draws.length; i++) {
          engine
            ..textSize(draws[i].$2)
            ..text(draws[i].$1, place(i).dx, place(i).dy);
        }
        final drawn = await _render(width, height, engine.renderQueue.execute);
        for (var i = 0; i < draws.length; i++) {
          if (!hasInk(expected, i)) continue;
          expect(
            hasInk(drawn, i),
            isTrue,
            reason: 'frame $frame, "${draws[i].$1}" at ${draws[i].$2}',
          );
        }
        cache.finishFrame();
      }
    });

    test('sizes that animate stop minting glyph textures', () {
      void frame(int f) {
        final engine = _textEngine(16);
        for (var i = 0; i < 12; i++) {
          engine
            ..textSize(16 + (f + 1) * 0.37 + i)
            ..text('Kinetic', 4, 4.0 + i * 20);
        }
        final recorder = ui.PictureRecorder();
        engine.renderQueue.execute(Canvas(recorder));
        recorder.endRecording().dispose();
        engine.renderQueue.clear();
        cache.finishFrame();
      }

      for (var f = 0; f < 5; f++) {
        frame(f);
      }
      final settled = cache.cacheLength;
      for (var f = 5; f < 30; f++) {
        frame(f);
      }
      expect(cache.cacheLength, settled);
    });

    test('sizes that animate skip the per-glyph layout', () {
      void frame(int f) {
        final engine = _textEngine(16);
        for (var i = 0; i < 12; i++) {
          engine
            ..textSize(16 + (f + 1) * 0.37 + i)
            ..text('Kinetic', 4, 4.0 + i * 20);
        }
        final recorder = ui.PictureRecorder();
        engine.renderQueue.execute(Canvas(recorder));
        recorder.endRecording().dispose();
        engine.renderQueue.clear();
        cache.finishFrame();
      }

      for (var f = 0; f < 5; f++) {
        frame(f);
      }
      final layouts = cache.debugEntryCounts['layouts'];
      final pairs = cache.debugEntryCounts['kerning'];
      for (var f = 5; f < 30; f++) {
        frame(f);
      }
      expect(cache.debugEntryCounts['kerning'], pairs);
      expect(cache.debugEntryCounts['layouts'], lessThanOrEqualTo(layouts!));
    });

    test('aligned, spaced lines land the same on both routes', () async {
      final width = (260 * _ratio).round(), height = (220 * _ratio).round();
      Future<Uint8List> draw(
        TextAlign align,
        double? maxWidth, {
        required bool native,
        required int copies,
      }) async {
        cache.clear();
        if (native) {
          for (var f = 0; f < 5; f++) {
            final warm = _textEngine(14 + f * 0.31)..text('warm', 2, 2);
            final recorder = ui.PictureRecorder();
            warm.renderQueue.execute(Canvas(recorder));
            recorder.endRecording().dispose();
            cache.finishFrame();
          }
        }
        final engine = _textEngine(18.3)
          ..textAlign(align)
          ..letterSpacing(0.75);
        // One label draws on its own, several as a batch.
        for (var copy = 0; copy < copies; copy++) {
          engine.text(
            'First line\n\nlonger second  ',
            120.4,
            6.6 + copy * 105,
            maxWidth,
          );
        }
        return _render(
          width,
          height,
          engine.renderQueue.execute,
          scale: _ratio,
        );
      }

      for (final align in [TextAlign.left, TextAlign.center, TextAlign.right]) {
        for (final maxWidth in <double?>[null, 90]) {
          for (final copies in [1, 2]) {
            expect(
              _worst(
                await draw(align, maxWidth, native: true, copies: copies),
                await draw(align, maxWidth, native: false, copies: copies),
              ),
              lessThanOrEqualTo(_textTolerance),
              reason: '$align, maxWidth $maxWidth, $copies labels',
            );
          }
        }
      }
    });

    test('text drawn natively matches the cached route', () async {
      void animate() {
        for (var f = 0; f < 5; f++) {
          final engine = _textEngine(14 + f * 0.31)..text('warm', 2, 2);
          final recorder = ui.PictureRecorder();
          engine.renderQueue.execute(Canvas(recorder));
          recorder.endRecording().dispose();
          cache.finishFrame();
        }
      }

      animate();
      final width = (200 * _ratio).round(), height = (60 * _ratio).round();
      final engine = _textEngine(19.7)
        ..fill(const Color(0xCC40C0FF))
        ..text('Native first', 6.3, 7.8);
      final drawn = await _render(
        width,
        height,
        engine.renderQueue.execute,
        scale: _ratio,
      );
      final expected = await _render(width, height, (c) {
        final painter = TextPainter(
          text: const TextSpan(
            text: 'Native first',
            style: TextStyle(
              fontFamily: _family,
              fontSize: 19.7,
              color: Color(0xCC40C0FF),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(c, const Offset(6.3, 7.8));
      }, scale: _ratio);
      expect(_worst(drawn, expected), lessThanOrEqualTo(_textTolerance));
    });
  });

  group('Text measures its real box', () {
    test('a wrapped paragraph reports every line', () {
      final paragraph = List.filled(40, 'lorem ipsum dolor').join(' ');
      final engine = _textEngine(16)..text(paragraph, 0, 0, 200);
      engine.renderQueue.flushPending();
      final bounds = engine.renderQueue.contentBoundsFrom(0)!;
      final layout = cache.getOrCreateLayout(
        text: paragraph,
        fontFamily: _family,
        fontSize: 16,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.normal,
        letterSpacing: 0,
        maxWidth: 200,
      );
      final lineHeight = cache.measureLineHeight(
        fontFamily: _family,
        fontSize: 16,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.normal,
      );
      expect(layout.lines.length, greaterThan(5));
      expect(bounds.height, closeTo(layout.lines.length * lineHeight, 1e-6));
    });

    test('wide text reports its width', () {
      final engine = _textEngine(30)..text('WWWWWWWWWWWW', 0, 0);
      engine.renderQueue.flushPending();
      final bounds = engine.renderQueue.contentBoundsFrom(0)!;
      expect(bounds.width, closeTo(_native('WWWWWWWWWWWW', 30).width, 1));
    });

    test('shadowed labels that really overlap keep their order', () async {
      void style(Flut5Engine e) => e
        ..noStroke()
        ..fill(const Color(0xFFE53935))
        ..textFont(_family)
        ..textSize(30)
        ..shadow(4, 4, 0, const Color(0xFF1E88E5));
      const text = 'WWWWWWWW', secondX = 150.0;
      final batched = Flut5Engine();
      style(batched);
      batched
        ..text(text, 10, 10)
        ..text(text, secondX, 10);
      final merged = await _render(460, 70, batched.renderQueue.execute);
      final first = Flut5Engine();
      final second = Flut5Engine();
      style(first);
      style(second);
      first.text(text, 10, 10);
      second.text(text, secondX, 10);
      final inOrder = await _render(460, 70, (c) {
        first.renderQueue.execute(c);
        second.renderQueue.execute(c);
      });
      expect(_worst(merged, inOrder), lessThanOrEqualTo(_textTolerance));
    });

    test('blurred text can bound its layer', () {
      final engine = _textEngine(20)..textStatic('Blur', 10, 10);
      engine.renderQueue.flushPending();
      expect(flut5PaintBounds(engine.renderQueue.items.single, 2), isNotNull);
    });
  });

  group('Images', () {
    Future<ui.Image> disc(int size, double radius) async {
      final recorder = ui.PictureRecorder();
      Canvas(
        recorder,
      ).drawCircle(Offset(size / 2, size / 2), radius, Paint()..color = _white);
      final picture = recorder.endRecording();
      final image = await picture.toImage(size, size);
      picture.dispose();
      return image;
    }

    test('a soft shadow follows the shape of a transparent PNG', () async {
      final raw = await disc(80, 10);
      final image = Flut5Image.fromUiImage(raw);
      for (var frame = 0; frame < 2; frame++) {
        final engine = Flut5Engine()..shadow(0, 0, 16, _white);
        engine.image(image, 40, 40);
        final px = await _render(160, 160, engine.renderQueue.execute);
        // 6 pixels outside the disc: inside the bitmap, in the halo.
        final halo = px[(80 * 160 + 64) * 4];
        expect(halo, greaterThan(20), reason: 'frame $frame');
        engine.renderQueue.clear();
      }
      Flut5ImageShadows.clear();
      image.dispose();
    });

    test('loading detects a transparent border', () async {
      Future<Uint8List> png(ui.Image image) async {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      }

      final clear = await disc(32, 10);
      final loadedClear = await Flut5Image.load(await png(clear));
      expect(loadedClear.hasTransparentBorder, isTrue);

      final recorder = ui.PictureRecorder();
      Canvas(recorder)
          .drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = _white);
      final picture = recorder.endRecording();
      final opaque = await picture.toImage(32, 32);
      picture.dispose();
      final loadedOpaque = await Flut5Image.load(await png(opaque));
      expect(loadedOpaque.hasTransparentBorder, isFalse);
      clear.dispose();
      opaque.dispose();
      loadedClear.dispose();
      loadedOpaque.dispose();
    });

    test(
      'more rotated images than the first limit are not re-copied',
      () async {
        ImageAtlasRenderItem.clearPaddedCache();
        final images = <Flut5Image>[];
        for (var i = 0; i < 40; i++) {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, 16, 16),
            Paint()..color = Color(0xFF000000 | (i * 6113 + 0x204060)),
          );
          final picture = recorder.endRecording();
          images.add(Flut5Image.fromUiImage(await picture.toImage(16, 16)));
          picture.dispose();
        }
        for (var frame = 0; frame < 3; frame++) {
          final engine = Flut5Engine();
          for (var i = 0; i < images.length; i++) {
            for (final offset in [0.0, 30.0]) {
              engine
                ..push()
                ..translate(20.0 + i * 24, 20 + offset)
                ..rotate(0.4)
                ..image(images[i], -8, -8)
                ..pop();
            }
          }
          final recorder = ui.PictureRecorder();
          engine.renderQueue.execute(Canvas(recorder));
          recorder.endRecording().dispose();
          engine.renderQueue.clear();
          expect(ImageAtlasRenderItem.debugPaddedCopyCount, 40);
        }
        ImageAtlasRenderItem.clearPaddedCache();
        for (final image in images) {
          image.dispose();
        }
      },
    );
  });

  group('Scroll containers', () {
    PointerScrollEvent wheel(double dy) => PointerScrollEvent(
      position: const Offset(50, 50),
      scrollDelta: Offset(0, dy),
    );

    double scrollY(Flut5Engine engine) {
      TransformRenderItem? last;
      for (final item in engine.renderQueue.items) {
        if (item is TransformRenderItem &&
            item.type == TransformType.translate) {
          last = item;
        }
      }
      return last!.dy!;
    }

    test('one that moves without an id keeps its scroll position', () {
      final engine = Flut5Engine()
        ..containerOverflow(Flut5ContainerOverflow.scroll)
        ..containerOverscrollMode(Flut5ContainerOverscroll.clamp);
      var now = 0;
      double frame(double x) {
        engine.advanceEnvironmentFrame(now += 16);
        engine.renderQueue.clear();
        engine.beginContainer(x, 0, 100, 100);
        engine.rect(0, 0, 100, 400);
        engine.endContainer();
        final offset = scrollY(engine);
        engine.events.clearPendingWheel();
        return offset;
      }

      frame(0);
      engine.events.addPointerScroll(wheel(50));
      expect(frame(0), -50);
      for (var x = 1; x <= 30; x++) {
        expect(frame(x * 0.5), -50);
      }
      expect(engine.debugAutoScrollStateCount, 1);
      engine.events.dispose();
    });

    test('states of containers that are gone are let go of', () {
      final engine = Flut5Engine()
        ..containerOverflow(Flut5ContainerOverflow.scroll);
      var now = 0;
      for (var f = 0; f < 800; f++) {
        engine.advanceEnvironmentFrame(now += 16);
        engine.renderQueue.clear();
        // A new rect and a new place in the draw order, every frame.
        for (var skip = 0; skip < f % 2; skip++) {
          engine.beginContainer(-50, -50, 10, 10);
          engine.endContainer();
        }
        engine.beginContainer(f * 3.0, f * 2.0, 100, 100);
        engine.rect(0, 0, 10, 10);
        engine.endContainer();
      }
      expect(engine.debugAutoScrollStateCount, lessThan(700));
      engine.events.dispose();
    });

    test(
      'rows outside the view are dropped, and the picture is the same',
      () async {
        void list(Flut5Engine engine) {
          engine
            ..noStroke()
            ..textFont(_family)
            ..textSize(12)
            ..beginContainer(20, 20, 220, 160, {'id': 'list'});
          for (var i = 0; i < 400; i++) {
            engine
              ..fill(
                i.isEven ? const Color(0xFF37474F) : const Color(0xFF546E7A),
              )
              ..rect(0, i * 20.0, 220, 18)
              ..fill(_white)
              ..text('Row $i', 6, i * 20.0 + 1);
          }
          engine.endContainer();
        }

        Flut5Engine scrolled(Flut5ContainerOverflow overflow) {
          final engine = Flut5Engine()
            ..containerOverflow(overflow)
            ..containerOverscrollMode(Flut5ContainerOverscroll.clamp);
          engine.events.addPointerScroll(
            const PointerScrollEvent(
              position: Offset(50, 50),
              scrollDelta: Offset(0, 1370),
            ),
          );
          list(engine);
          engine.renderQueue.flushPending();
          return engine;
        }

        final culled = scrolled(Flut5ContainerOverflow.scroll);
        expect(culled.renderQueue.itemCount, lessThan(60));

        // The same content, shifted by hand and only clipped.
        final whole = Flut5Engine()
          ..containerOverflow(Flut5ContainerOverflow.hidden);
        whole
          ..noStroke()
          ..textFont(_family)
          ..textSize(12)
          ..beginContainer(20, 20, 220, 160, {'id': 'list'})
          ..translate(0, -1370);
        for (var i = 0; i < 400; i++) {
          whole
            ..fill(i.isEven ? const Color(0xFF37474F) : const Color(0xFF546E7A))
            ..rect(0, i * 20.0, 220, 18)
            ..fill(_white)
            ..text('Row $i', 6, i * 20.0 + 1);
        }
        whole.endContainer();
        final width = (280 * _ratio).round(), height = (210 * _ratio).round();
        final drawn = await _render(
          width,
          height,
          culled.renderQueue.execute,
          scale: _ratio,
        );
        final expected = await _render(
          width,
          height,
          whole.renderQueue.execute,
          scale: _ratio,
        );
        expect(_worst(drawn, expected), lessThanOrEqualTo(_textTolerance));
        culled.events.dispose();
        whole.events.dispose();
      },
    );
  });

  group('Pixelate passes', () {
    test('a cropped pass is the same blocks as a full one', () async {
      await Flut5Shaders.load();
      for (final palette in <List<Color>?>[
        null,
        const [Color(0xFF0F380F), Color(0xFF9BBC0F)],
      ]) {
        void scene(Flut5Engine e, {required bool forceFull}) {
          e
            ..noStroke()
            ..fill(const Color(0xFF40C0FF));
          for (var i = 0; i < 4; i++) {
            e.beginPixelate(6, palette);
            // A clear background paints nothing but can't be cropped to.
            if (forceFull) e.background(const Color(0x00000000));
            e.circle(40.0 + i * 70, 50.0 + i * 20, 34);
            e.endPixelate();
          }
        }

        final cropped = Flut5Engine()
          ..updateEnvironmentSize(const Size(360, 200));
        scene(cropped, forceFull: false);
        final full = Flut5Engine()..updateEnvironmentSize(const Size(360, 200));
        scene(full, forceFull: true);
        final width = (360 * _ratio).round(), height = (200 * _ratio).round();
        final drawn = await _render(
          width,
          height,
          cropped.renderQueue.execute,
          scale: _ratio,
        );
        final expected = await _render(
          width,
          height,
          full.renderQueue.execute,
          scale: _ratio,
        );
        expect(_worst(drawn, expected), lessThanOrEqualTo(1));
      }
    });
  });

  group('Shapes and labels batch together', () {
    Future<void> expectSameAsOneByOne(
      void Function(Flut5Engine, int) draw,
      int count,
    ) async {
      final batched = _textEngine(11);
      for (var i = 0; i < count; i++) {
        draw(batched, i);
      }
      final inOrder = <Flut5Engine>[];
      for (var i = 0; i < count; i++) {
        inOrder.add(_textEngine(11));
        draw(inOrder.last, i);
      }
      final width = (360 * _ratio).round(), height = (260 * _ratio).round();
      final merged = await _render(
        width,
        height,
        batched.renderQueue.execute,
        scale: _ratio,
      );
      final expected = await _render(width, height, (c) {
        for (final engine in inOrder) {
          engine.renderQueue.execute(c);
        }
      }, scale: _ratio);
      expect(_worst(merged, expected), lessThanOrEqualTo(_textTolerance));
    }

    void labelled(Flut5Engine e, int i) => e
      ..fill(const Color(0xFFFF9800))
      ..rect((i % 8) * 42.0 + 6, (i ~/ 8) * 46.0 + 6, 34, 10)
      ..fill(_white)
      ..text('n$i', (i % 8) * 42.0 + 6, (i ~/ 8) * 46.0 + 17);

    test('labelled rects draw in two calls', () async {
      final engine = _textEngine(11);
      for (var i = 0; i < 40; i++) {
        labelled(engine, i);
      }
      engine.renderQueue.flushPending();
      expect(engine.renderQueue.itemCount, 2);
      await expectSameAsOneByOne(labelled, 40);
    });

    test('a label on its own shape stays on top', () async {
      await expectSameAsOneByOne(
        (e, i) => e
          ..fill(const Color(0xFF1E88E5))
          ..rect((i % 8) * 42.0 + 6, (i ~/ 8) * 30.0 + 6, 36, 22)
          ..fill(_white)
          ..text('n$i', (i % 8) * 42.0 + 10, (i ~/ 8) * 30.0 + 8),
        32,
      );
    });

    test('a shape drawn over an earlier label covers it', () async {
      await expectSameAsOneByOne((e, i) {
        e
          ..fill(_white)
          ..text('Cover', 20.0 + i * 8, 30)
          ..fill(i.isEven ? const Color(0xFFE53935) : const Color(0xFF43A047))
          ..rect(16.0 + i * 8, 34, 30, 8);
      }, 12);
    });

    test('labels too close to share a batch stay in order', () async {
      // Each shape lands on the label before it, more than enough times for
      // the queue to stop trying and later start again. Rows wrap around, so
      // later shapes cover earlier labels.
      void packed(Flut5Engine e, int i) => e
        ..fill(i.isEven ? const Color(0xFFFF9800) : const Color(0xFF00897B))
        ..rect((i % 16) * 20.0 + 4, ((i ~/ 16) % 17) * 15.0 + 4, 14, 7)
        ..fill(_white)
        ..text('n$i', (i % 16) * 20.0 + 4, ((i ~/ 16) % 17) * 15.0 + 8);
      final batched = _textEngine(9);
      final inOrder = _textEngine(9);
      for (var i = 0; i < 1400; i++) {
        packed(batched, i);
        packed(inOrder, i);
        inOrder.renderQueue.flushPending();
      }
      final width = (340 * _ratio).round(), height = (270 * _ratio).round();
      final merged = await _render(
        width,
        height,
        batched.renderQueue.execute,
        scale: _ratio,
      );
      final expected = await _render(
        width,
        height,
        inOrder.renderQueue.execute,
        scale: _ratio,
      );
      expect(_worst(merged, expected), lessThanOrEqualTo(_textTolerance));
    });

    test('text after a transform lands on the new one', () async {
      // One queue reads the canvas once per run of items that leave its
      // transform alone. Each draw of the reference has a replay to itself.
      void plain(Flut5Engine e, int i) =>
          e.text('plain $i', (i % 4) * 88.0 + 4.25, (i ~/ 4) * 44.0 + 4.6);
      void sheared(Flut5Engine e, int i) => e
        ..push()
        ..translate((i % 4) * 88.0 + 8.5, (i ~/ 4) * 44.0 + 22.5)
        ..shearX(0.3)
        ..scale(1.25, 0.8)
        ..text('sheared', 0, 0)
        ..pop();
      final together = _textEngine(11);
      final separately = <Flut5Engine>[];
      for (var i = 0; i < 16; i++) {
        plain(together, i);
        sheared(together, i);
        separately.add(_textEngine(11));
        plain(separately.last, i);
        separately.add(_textEngine(11));
        sheared(separately.last, i);
      }
      final width = (360 * _ratio).round(), height = (200 * _ratio).round();
      final drawn = await _render(
        width,
        height,
        together.renderQueue.execute,
        scale: _ratio,
      );
      final expected = await _render(width, height, (c) {
        for (final engine in separately) {
          engine.renderQueue.execute(c);
        }
      }, scale: _ratio);
      expect(_worst(drawn, expected), lessThanOrEqualTo(_textTolerance));
    });

    test('text in a scope too fine to pixelate reads the canvas', () async {
      // Such a scope draws on its parent's canvas but isn't snapped to it,
      // so what was read for the text before it can't be reused inside it.
      final together = _textEngine(11);
      final outside = _textEngine(11);
      final inside = _textEngine(11);
      for (var i = 0; i < 8; i++) {
        final outX = (i % 4) * 88.0 + 4.25, outY = (i ~/ 4) * 44.0 + 4.6;
        final inX = (i % 4) * 88.0 + 8.3, inY = (i ~/ 4) * 44.0 + 22.4;
        together
          ..text('out $i', outX, outY)
          ..beginPixelate(0.5)
          ..text('in $i', inX, inY)
          ..endPixelate();
        outside.text('out $i', outX, outY);
        inside
          ..beginPixelate(0.5)
          ..text('in $i', inX, inY)
          ..endPixelate();
      }
      final width = (360 * _ratio).round(), height = (120 * _ratio).round();
      final drawn = await _render(
        width,
        height,
        together.renderQueue.execute,
        scale: _ratio,
      );
      final expected = await _render(width, height, (c) {
        outside.renderQueue.execute(c);
        inside.renderQueue.execute(c);
      }, scale: _ratio);
      expect(_worst(drawn, expected), lessThanOrEqualTo(_textTolerance));
    });

    test('circles keep their own edges between labels', () async {
      void dots(Flut5Engine e, int i) => e
        ..fill(const Color(0xFF8E24AA))
        ..circle((i % 8) * 42.0 + 22, (i ~/ 8) * 46.0 + 12, 16)
        ..fill(_white)
        ..text('c', (i % 8) * 42.0 + 18, (i ~/ 8) * 46.0 + 21);
      final engine = _textEngine(11);
      for (var i = 0; i < 16; i++) {
        dots(engine, i);
      }
      engine.renderQueue.flushPending();
      // One draw per circle, as without batching, and one for all the labels.
      expect(engine.renderQueue.itemCount, 17);
      await expectSameAsOneByOne(dots, 16);
    });
  });

  group('Physics broadphase', () {
    int overlaps(List<Flut5PhysicsParticle> particles) {
      var count = 0;
      for (var i = 0; i < particles.length; i++) {
        for (var j = i + 1; j < particles.length; j++) {
          final a = particles[i], b = particles[j];
          final dx = a.position.x - b.position.x;
          final dy = a.position.y - b.position.y;
          final reach = a.radius + b.radius - 0.05;
          if (dx * dx + dy * dy < reach * reach) count++;
        }
      }
      return count;
    }

    test('big particles collide with everything near them', () {
      final rng = math.Random(11);
      final world = Flut5PhysicsEngine()..particleCollision(iterations: 6);
      for (var i = 0; i < 900; i++) {
        final particle = world.createParticle(
          rng.nextDouble() * 500,
          rng.nextDouble() * 400,
        );
        particle.radius = i % 5 == 0 ? 14 : 2;
      }
      for (var f = 0; f < 40; f++) {
        world.update();
      }
      expect(overlaps(world.particles.toList()), 0);
    });

    test('a big particle reaches filed ones past its own cell', () {
      final world = Flut5PhysicsEngine()..particleCollision();
      for (var i = 0; i < 60; i++) {
        world.createParticle(i * 8.0, 0).radius = 1;
      }
      final big = world.createParticle(240, 30)..radius = 40;
      world.update();
      expect(big.position.y, greaterThan(30));
    });

    test('boxes in a tall column still find each other', () {
      final world = Flut5PhysicsEngine();
      final pairs = [
        for (var i = 0; i < 40; i++)
          (
            world.createRect(0, i * 100.0, 10, 10),
            world.createRect(0, i * 100.0 + 7, 10, 10),
          ),
      ];
      for (var f = 0; f < 30; f++) {
        world.update();
      }
      for (final (upper, lower) in pairs) {
        expect(lower.position.y - upper.position.y, greaterThan(9.5));
      }
    });
  });
}
