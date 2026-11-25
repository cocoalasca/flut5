import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flut5/widgets/flut5_style_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final class _TestSketch() extends Flut5;

List<String> _flushWarnings() {
  final lines = <String>[];
  final prev = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) lines.add(message);
  };
  try {
    Flut5Console.flush();
  } finally {
    debugPrint = prev;
  }
  return lines;
}

Future<Uint8List> _renderEngine(
  Flut5Engine engine, {
  int width = 20,
  int height = 20,
}) async {
  engine.updateEnvironmentSize(Size(width.toDouble(), height.toDouble()));
  engine.renderQueue.flushPending();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  engine.renderQueue.execute(canvas);
  final picture = recorder.endRecording();
  final img = await picture.toImage(width, height);
  picture.dispose();
  final bytes = (await img.toByteData())!.buffer.asUint8List();
  img.dispose();
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // Keep Flut5Console clean between tests.
    _flushWarnings();
  });

  group('color() — p5 numeric, hex/CSS string, list, and Color inputs', () {
    late Flut5Engine e;
    setUp(() => e = Flut5Engine());

    test('parses 1–4 numeric arguments (int and double, with clamping)', () {
      expect(e.color(0), const Color(0xFF000000));
      expect(e.color(128), const Color(0xFF808080));
      expect(e.color(255), const Color(0xFFFFFFFF));

      expect(e.color(200, 100), const Color.fromARGB(100, 200, 200, 200));
      expect(e.color(255, 100, 50), const Color.fromARGB(255, 255, 100, 50));
      expect(
        e.color(255, 100, 50, 128),
        const Color.fromARGB(128, 255, 100, 50),
      );

      // Works with int variables (not just literals) and doubles.
      final int r = 10, g = 20, b = 30, a = 40;
      expect(e.color(r, g, b, a), const Color.fromARGB(40, 10, 20, 30));
      expect(e.color(127.6, 0.4, 254.6), const Color.fromARGB(255, 128, 0, 255));

      // Clamps out-of-range values and handles NaN/infinity safely.
      expect(e.color(-50, 300, double.infinity, double.nan),
          const Color.fromARGB(0, 0, 255, 255));
      expect(e.color(double.negativeInfinity), const Color(0xFF000000));
    });

    test('parses #RGB, #RGBA, #RRGGBB, #RRGGBBAA hex strings', () {
      expect(e.color('#f0a'), const Color(0xFFFF00AA));
      expect(e.color('#F0A'), const Color(0xFFFF00AA));
      expect(e.color('#f0a8'), const Color(0x88FF00AA));
      expect(e.color('#123456'), const Color(0xFF123456));
      expect(e.color('#12345680'), const Color(0x80123456));
      expect(e.color('  #AbCdEf  '), const Color(0xFFABCDEF));

      // Optional alpha override on hex strings.
      expect(e.color('#ff0000', 128), const Color(0x80FF0000));
      expect(e.color('#ff000040', 200), const Color(0xC8FF0000));
    });

    test('parses CSS rgb() and rgba() strings', () {
      expect(e.color('rgb(255, 100, 50)'), const Color(0xFFFF6432));
      expect(e.color('RGB( 10 , 20 , 30 )'), const Color(0xFF0A141E));
      expect(e.color('rgba(255, 0, 128, 0.5)'), const Color(0x80FF0080));
      expect(e.color('rgb(100%, 0%, 50%)'), const Color(0xFFFF0080));
      expect(e.color('rgba(255, 0, 0, 50%)'), const Color(0x80FF0000));
      expect(e.color('rgb(255, 0, 0)', 64), const Color(0x40FF0000));
    });

    test('parses 1–4 element numeric lists and Color objects', () {
      expect(e.color([128]), const Color(0xFF808080));
      expect(e.color([128, 64]), const Color(0x40808080));
      expect(e.color([255, 100, 50]), const Color(0xFFFF6432));
      expect(e.color([255, 100, 50, 128]), const Color(0x80FF6432));
      expect(e.color([255, 0, 0], 99), const Color.fromARGB(99, 255, 0, 0));

      expect(e.color(Colors.red), Colors.red);
      expect(e.color(Colors.red, 128), Colors.red.withAlpha(128));
    });

    test('rejects invalid inputs with ArgumentError', () {
      expect(() => e.color(''), throwsArgumentError);
      expect(() => e.color('#12'), throwsArgumentError);
      expect(() => e.color('#12345'), throwsArgumentError);
      expect(() => e.color('#1234567'), throwsArgumentError);
      expect(() => e.color('#gggggg'), throwsArgumentError);
      expect(() => e.color('bad'), throwsArgumentError);
      expect(() => e.color('ff0000'), throwsArgumentError);
      expect(() => e.color('rgb(1, 2)'), throwsArgumentError);
      expect(() => e.color('rgba(1, 2, 3, NaN)'), throwsArgumentError);
      expect(() => e.color([]), throwsArgumentError);
      expect(() => e.color([1, 2, 3, 4, 5]), throwsArgumentError);
      expect(() => e.color(['#fff']), throwsArgumentError);
      expect(() => e.color(true), throwsArgumentError);
      expect(() => e.color(255, null, 100), throwsArgumentError);
      expect(() => e.color(Colors.red, 10, 20), throwsArgumentError);
    });
  });

  group('fill(), stroke(), background()', () {
    late Flut5Engine e;
    setUp(() => e = Flut5Engine());

    test('fill() accepts Color, numeric channels, hex/rgb strings, lists, and Gradients', () {
      e.fill(200);
      expect(e.fillColor, const Color(0xFFC8C8C8));
      expect(e.fillGradient, isNull);

      e.fill(200, 100);
      expect(e.fillColor, const Color(0x64C8C8C8));

      e.fill(255, 100, 50);
      expect(e.fillColor, const Color(0xFFFF6432));

      e.fill(255, 100, 50, 128);
      expect(e.fillColor, const Color(0x80FF6432));

      e.fill('#0f8');
      expect(e.fillColor, const Color(0xFF00FF88));

      e.fill('#11223344');
      expect(e.fillColor, const Color(0x44112233));

      e.fill('#ff0000', 80);
      expect(e.fillColor, const Color(0x50FF0000));

      e.fill([10, 20, 30, 40]);
      expect(e.fillColor, const Color.fromARGB(40, 10, 20, 30));

      e.fill(Colors.blue);
      expect(e.fillColor, Colors.blue);

      e.fill(Colors.blue, 128);
      expect(e.fillColor, Colors.blue.withAlpha(128));

      const grad = LinearGradient(colors: [Colors.red, Colors.blue]);
      e.fill(grad, 1, 2, 30, 40);
      expect(e.fillGradient, grad);
      expect(e.fillGradientRect, const Rect.fromLTWH(1, 2, 30, 40));
    });

    test('fill() preserves paint identity & version when equivalent color repeats', () {
      e.fill(255, 0, 128);
      final v1 = e.fillVersion;
      final p1 = e.snapshotFillPaint();

      // Same color via numeric, hex, list, and Color must not bump version.
      e.fill(255, 0, 128);
      e.fill('#ff0080');
      e.fill([255, 0, 128]);
      e.fill(const Color(0xFFFF0080));
      expect(e.fillVersion, v1);
      expect(identical(e.snapshotFillPaint(), p1), isTrue);
    });

    test('stroke() accepts Color, numeric channels, hex/rgb strings, lists, and preserves identity', () {
      e.stroke(128);
      expect(e.strokeColor, const Color(0xFF808080));

      e.stroke(10, 20, 30, 40);
      expect(e.strokeColor, const Color.fromARGB(40, 10, 20, 30));
      final v1 = e.strokeVersion;
      final p1 = e.snapshotStrokePaint();

      e.stroke('#0a141e28');
      e.stroke([10, 20, 30, 40]);
      e.stroke(const Color.fromARGB(40, 10, 20, 30));
      expect(e.strokeVersion, v1);
      expect(identical(e.snapshotStrokePaint(), p1), isTrue);

      e.stroke(Colors.green, 100);
      expect(e.strokeColor, Colors.green.withAlpha(100));
    });

    test('invalid fill/stroke/background inputs warn and leave state unchanged', () {
      e.fill('#ff0000');
      e.stroke('#00ff00');
      final fillVer = e.fillVersion;
      final strokeVer = e.strokeVersion;

      e.fill('not-a-hex');
      e.stroke(true);
      e.background('#12345');

      expect(e.fillColor, const Color(0xFFFF0000));
      expect(e.fillVersion, fillVer);
      expect(e.strokeColor, const Color(0xFF00FF00));
      expect(e.strokeVersion, strokeVer);

      final warnings = _flushWarnings();
      expect(warnings.length, 3);
      expect(warnings[0], contains('fill()'));
      expect(warnings[1], contains('stroke()'));
      expect(warnings[2], contains('background()'));
    });

    test('extra trailing args on Color or 5 numeric args warn gracefully', () {
      e.fill(Colors.red, 10, 20, 30, 40);
      expect(e.fillColor, Colors.red);

      e.stroke(10, 20, 30, 40, 50);
      expect(e.strokeColor, const Color.fromARGB(40, 10, 20, 30));

      final warnings = _flushWarnings();
      expect(warnings.length, 2);
      expect(warnings[0], contains('extra arguments are ignored'));
      expect(warnings[1], contains('5th argument ignored'));
    });

    test('background() renders numeric and hex colors accurately', () async {
      e.background('#112233');
      final px = await _renderEngine(e, width: 4, height: 4);
      expect(px.sublist(0, 4), [0x11, 0x22, 0x33, 0xFF]);

      final e2 = Flut5Engine()..background(10, 200, 50);
      final px2 = await _renderEngine(e2, width: 4, height: 4);
      expect(px2.sublist(0, 4), [10, 200, 50, 255]);

      // Translucent background reports trailFadeColor as expected.
      final e3 = Flut5Engine()..background(0, 40);
      expect(e3.renderQueue.trailFadeColor, const Color.fromARGB(40, 0, 0, 0));
    });
  });

  group('lerpColor(), shadow(), shadowFill(), tint(), beginPixelate(), Flut5Image.set()', () {
    late Flut5Engine e;
    setUp(() => e = Flut5Engine());

    test('lerpColor() accepts Color, hex, grayscale num, and RGB lists', () {
      expect(
        e.lerpColor('#ff0000', '#0000ff', 0.5),
        Color.lerp(const Color(0xFFFF0000), const Color(0xFF0000FF), 0.5),
      );
      expect(
        e.lerpColor(0, 255, 0.5),
        Color.lerp(const Color(0xFF000000), const Color(0xFFFFFFFF), 0.5),
      );
      expect(
        e.lerpColor([255, 0, 0], Colors.blue, 0.25),
        Color.lerp(const Color(0xFFFF0000), Colors.blue, 0.25),
      );
      expect(() => e.lerpColor('invalid', '#fff', 0.5), throwsArgumentError);
      expect(() => e.lerpColor('#fff', 'invalid', 0.5), throwsArgumentError);
    });

    test('shadow() and shadowFill() accept Color, hex, lists, and p5 numeric args', () {
      // 4th arg as spread (num) still sets spread, not color.
      e.shadow(2, 3, 4, 5);
      expect(e.renderQueue.activeShadow!.spread, 5.0);
      expect(e.renderQueue.activeShadow!.color, const Color(0xFF000000));

      // 4th arg as hex string sets color with spread 0.
      e.shadow(2, 3, 4, '#00ffff80');
      expect(e.renderQueue.activeShadow!.spread, 0.0);
      expect(e.renderQueue.activeShadow!.color, const Color(0x8000FFFF));

      // 4th arg as RGB list sets color with spread 0.
      e.shadow(2, 3, 4, [255, 128, 0]);
      expect(e.renderQueue.activeShadow!.spread, 0.0);
      expect(e.renderQueue.activeShadow!.color, const Color(0xFFFF8000));

      // 4th arg spread + 5th arg hex / grayscale / list.
      e.shadow(1, 2, 6, 3, '#ff00ff');
      expect(e.renderQueue.activeShadow!.spread, 3.0);
      expect(e.renderQueue.activeShadow!.color, const Color(0xFFFF00FF));

      e.shadow(1, 2, 6, 3, 128);
      expect(e.renderQueue.activeShadow!.color, const Color(0xFF808080));

      e.shadow(1, 2, 6, 3, [10, 20, 30, 200]);
      expect(e.renderQueue.activeShadow!.color, const Color.fromARGB(200, 10, 20, 30));

      // shadowFill() accepts all multi-arg forms.
      e.shadowFill(255, 0, 0, 128);
      expect(e.renderQueue.activeShadow!.color, const Color(0x80FF0000));

      e.shadowFill('#123456', 90);
      expect(e.renderQueue.activeShadow!.color, const Color.fromARGB(90, 0x12, 0x34, 0x56));

      // Duplicate color args or invalid values throw on shadow(), warn on shadowFill().
      expect(() => e.shadow(1, 1, 4, '#ff0000', '#00ff00'), throwsArgumentError);
      expect(() => e.shadow(1, 1, 4, 'bad-hex'), throwsArgumentError);
      expect(() => e.shadow(1, 1, 4, 2, 'bad-hex'), throwsArgumentError);

      e.shadowFill('bad-hex');
      expect(_flushWarnings().single, contains('shadowFill()'));
    });

    test('tint() applies p5 numeric and hex colors to rendered images', () async {
      final whiteImg = Flut5Image.create(4, 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          whiteImg.set(x, y, 255);
        }
      }
      whiteImg.updatePixels();
      addTearDown(whiteImg.dispose);

      e
        ..background(0)
        ..tint('#ff8000')
        ..image(whiteImg, 0, 0);
      final px = await _renderEngine(e, width: 4, height: 4);
      expect(px.sublist(0, 4), [0xFF, 0x80, 0x00, 0xFF]);

      final e2 = Flut5Engine()
        ..background(0)
        ..tint(255, 128) // white at 50% opacity
        ..image(whiteImg, 0, 0);
      final px2 = await _renderEngine(e2, width: 4, height: 4);
      expect(px2[0], inInclusiveRange(127, 129));
      expect(px2[1], inInclusiveRange(127, 129));
      expect(px2[2], inInclusiveRange(127, 129));
      expect(px2[3], 255);

      e2.tint('invalid');
      expect(_flushWarnings().single, contains('tint()'));
    });

    test('Flut5Image.set() accepts Color, numeric channels, hex strings, and lists', () {
      final img = Flut5Image.create(6, 1);
      addTearDown(img.dispose);

      img.set(0, 0, 128);
      img.set(1, 0, 128, 64);
      img.set(2, 0, 255, 100, 50);
      img.set(3, 0, 255, 100, 50, 200);
      img.set(4, 0, '#11223344');
      img.set(5, 0, [10, 20, 30, 40]);

      expect(img.get(0, 0), const Color(0xFF808080));
      expect(img.get(1, 0), const Color(0x40808080));
      expect(img.get(2, 0), const Color(0xFFFF6432));
      expect(img.get(3, 0), const Color.fromARGB(200, 255, 100, 50));
      expect(img.get(4, 0), const Color(0x44112233));
      expect(img.get(5, 0), const Color.fromARGB(40, 10, 20, 30));

      img.set(0, 0, 'not-a-color');
      expect(img.get(0, 0), const Color(0xFF808080)); // unchanged
      expect(_flushWarnings().single, contains('Flut5Image.set()'));
    });

    test('beginPixelate() accepts hex strings, lists, grayscale, and Color in palette', () async {
      await Flut5Shaders.load();
      e.updateEnvironmentSize(const Size(20, 20));
      e.noStroke();
      e.beginPixelate(10, ['#ff0000', [0, 0, 255], 0]);
      e.background(0);
      e.fill('#e01010');
      e.rect(0, 0, 10, 10);
      e.fill('#1010e0');
      e.rect(10, 0, 10, 10);
      e.endPixelate();

      final px = await _renderEngine(e, width: 20, height: 20);
      // Top-left block snaps to #ff0000, top-right block snaps to #0000ff.
      final tl = (5 * 20 + 5) * 4;
      final tr = (5 * 20 + 15) * 4;
      expect(px.sublist(tl, tl + 4), [255, 0, 0, 255]);
      expect(px.sublist(tr, tr + 4), [0, 0, 255, 255]);

      expect(
        () => e.beginPixelate(4, ['#ff0000', 'not-a-color']),
        throwsArgumentError,
      );
    });
  });

  group('Flut5 forwarders', () {
    test('bare Flut5 subclass methods forward all color forms identically', () {
      final sketch = _TestSketch();
      addTearDown(sketch.dispose);

      expect(sketch.color('#ff8800'), const Color(0xFFFF8800));
      expect(sketch.color(10, 20, 30, 40), const Color.fromARGB(40, 10, 20, 30));
      expect(
        sketch.lerpColor('#000000', '#ffffff', 0.5),
        Color.lerp(const Color(0xFF000000), const Color(0xFFFFFFFF), 0.5),
      );

      sketch.fill(255, 100, 50);
      expect(sketch.fillColor, const Color(0xFFFF6432));

      sketch.stroke('#123456', 128);
      expect(sketch.strokeColor, const Color(0x80123456));

      sketch.background(240);
      expect(sketch.renderQueue.itemCount, greaterThanOrEqualTo(0));

      sketch.shadow(2, 2, 4, '#ff000080');
      expect(sketch.renderQueue.activeShadow!.color, const Color(0x80FF0000));

      sketch.shadowFill(0, 255, 0);
      expect(sketch.renderQueue.activeShadow!.color, const Color(0xFF00FF00));

      sketch.tint(255, 128);
      sketch.noTint();

      sketch.beginPixelate(4, ['#000', '#fff']);
      sketch.endPixelate();
    });
  });

  group('Widget style color builders', () {
    test('resolveColor, buildDecoration, buildTextStyle, resolveShadows, resolveLinearGradient', () {
      expect(resolveColor('#ff0080'), const Color(0xFFFF0080));
      expect(resolveColor(200), const Color(0xFFC8C8C8));
      expect(resolveColor([10, 20, 30, 40]), const Color.fromARGB(40, 10, 20, 30));
      expect(resolveColor(Colors.teal), Colors.teal);
      expect(resolveColor('invalid'), isNull);

      final dec = buildDecoration({
        'backgroundColor': '#112233',
        'borderColor': [255, 0, 0],
        'borderWeight': 2,
        'shadow': {'color': '#00000080', 'blur': 6},
      });
      expect(dec.color, const Color(0xFF112233));
      expect((dec.border! as Border).top.color, const Color(0xFFFF0000));
      expect(dec.boxShadow!.single.color, const Color(0x80000000));

      final textStyle = buildTextStyle({'color': '#abcdef', 'fontSize': 14});
      expect(textStyle!.color, const Color(0xFFABCDEF));

      // Flat numeric list is a single solid color, NOT a gradient.
      expect(resolveLinearGradient([255, 0, 128]), isNull);
      expect(resolveLinearGradient([255, 0, 128, 200]), isNull);
      expect(resolveLinearGradient('#ff0000'), isNull);

      // Lists of hex strings, nested RGB lists, or color maps become gradients.
      final hexGrad = resolveLinearGradient(['#ff0000', '#0000ff']);
      expect(hexGrad, isNotNull);
      expect(hexGrad!.colors, [const Color(0xFFFF0000), const Color(0xFF0000FF)]);

      final listGrad = resolveLinearGradient([
        [255, 0, 0],
        [0, 255, 0],
      ]);
      expect(listGrad, isNotNull);
      expect(listGrad!.colors, [const Color(0xFFFF0000), const Color(0xFF00FF00)]);

      final stopGrad = resolveLinearGradient([
        {'color': '#ff0000', 'stop': 0.0},
        {'color': [0, 0, 255], 'stop': 1.0},
      ]);
      expect(stopGrad, isNotNull);
      expect(stopGrad!.colors, [const Color(0xFFFF0000), const Color(0xFF0000FF)]);
      expect(stopGrad.stops, [0.0, 1.0]);
    });

    testWidgets('toggle, checkbox, and slider render cleanly with hex and numeric list styles', (tester) async {
      final widgets = Flut5Widgets();
      addTearDown(widgets.dispose);

      final toggle = widgets.createToggle(true)
        ..style({
          'backgroundColor': '#333333',
          'activeBackgroundColor': [0, 200, 100],
          'thumbColor': 255,
          'borderColor': '#ffffff80',
        });
      final checkbox = widgets.createCheckbox(true)
        ..style({
          'activeBackgroundColor': '#0066ff',
          'checkColor': '#fff',
          'borderColor': [100, 100, 100],
        });
      final slider = widgets.createSlider(0, 10, 5)
        ..style({
          'thumbColor': '#ff5500',
          'thumbBorderColor': 255,
          'trackColor': ['#222222', '#888888'],
          'activeTrackColor': [255, 85, 0],
          'trackBorderColor': '#00000040',
        });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Builder(builder: toggle.buildInteractiveListenable),
                Builder(builder: checkbox.buildInteractiveListenable),
                Builder(builder: slider.buildInteractiveListenable),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
