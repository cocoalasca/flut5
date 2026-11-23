import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Renders a [Flut5RenderQueue] to raw premultiplied RGBA8 pixels.
Future<Uint8List> _renderQueue(
  Flut5RenderQueue queue, {
  int width = 160,
  int height = 160,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  queue.execute(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  return bytes;
}

/// Checks pixel equality allowing at most [tolerance] per channel (0 = bit-exact).
void _expectPixelsMatch(
  Uint8List actual,
  Uint8List expected, {
  int tolerance = 0,
  String? reason,
}) {
  expect(actual.length, expected.length, reason: reason);
  var maxDiff = 0;
  var diffPixels = 0;
  for (var i = 0; i < actual.length; i += 4) {
    final dr = (actual[i] - expected[i]).abs();
    final dg = (actual[i + 1] - expected[i + 1]).abs();
    final db = (actual[i + 2] - expected[i + 2]).abs();
    final da = (actual[i + 3] - expected[i + 3]).abs();
    final d = math.max(math.max(dr, dg), math.max(db, da));
    if (d > maxDiff) maxDiff = d;
    if (d > tolerance) diffPixels++;
  }
  expect(
    diffPixels,
    0,
    reason:
        '${reason ?? 'pixel mismatch'}: $diffPixels pixels differed by > $tolerance (maxDiff=$maxDiff)',
  );
}

Future<ui.Image> _makeTestImage(Color primary, Color accent) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 20, 20), Paint()..color = primary);
  canvas.drawCircle(const Offset(10, 10), 6, Paint()..color = accent);
  final picture = recorder.endRecording();
  final image = await picture.toImage(20, 20);
  picture.dispose();
  return image;
}

class _LoopControlSketch({final bool stopInSetup = false}) extends Flut5Sketch {
  int setupCount = 0;
  int drawCount = 0;
  bool lastMousePressed = false;

  @override
  void setup() {
    setupCount++;
    if (stopInSetup) noLoop();
  }

  @override
  void draw() {
    drawCount++;
    lastMousePressed = mouseIsPressed;
    background(Colors.black);
    fill(Colors.white);
    circle(20 + drawCount.toDouble(), 20, 10);
  }
}

class _ForwarderSmokeHelper(Flut5Engine engine) extends Flut5 {
  this : super(flut5: engine);

  void exerciseForwarders() {
    tint(const Color(0xCCFF8800));
    noTint();
    expect(imageFilterQuality(FilterQuality.low), FilterQuality.low);
    expect(imageFilterQuality(), FilterQuality.low);

    final circleHit = rayCircleIntersection(
      10,
      0,
      5,
      0,
      0,
      Flut5Vector(1, 0),
    );
    expect(circleHit, isNotNull);
    expect(circleHit!.x, closeTo(5, 1e-12));

    final scene = createRayScene([Flut5LineSegment(10, -5, 10, 5)]);
    expect(scene.castRayClosest(0, 0, 1, 0)?.distance, closeTo(10, 1e-12));

    final alignForce = alignment(
      Flut5Vector(0, 0),
      Flut5Vector(0, 0),
      [Flut5Vector(5, 0)],
      [Flut5Vector(0, 4)],
      alignmentRadius: 20,
      maxForce: 10,
    );
    expect(alignForce.y, closeTo(4, 1e-12));

    expect(mouseIsPressed, isFalse);
    expect(isLooping, isTrue);
    noLoop();
    expect(isLooping, isFalse);
    redraw();
    loop();
    expect(isLooping, isTrue);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 1 — Stroke cache, open batching & transforms', () {
    test('stroke paint snapshots reuse identical instances across swaps', () {
      final e = Flut5Engine()..strokeWeight(3);
      e.stroke(Colors.red);
      final red1 = e.snapshotStrokePaint();
      final redPt1 = e.snapshotPointPaint();
      e.stroke(Colors.blue);
      final blue1 = e.snapshotStrokePaint();
      e.stroke(Colors.red);
      final red2 = e.snapshotStrokePaint();
      final redPt2 = e.snapshotPointPaint();

      expect(identical(red1, red2), isTrue);
      expect(identical(redPt1, redPt2), isTrue);
      expect(identical(red1, blue1), isFalse);

      // BlendMode change invalidates the snapshot table.
      e.blendMode(BlendMode.multiply);
      final redMultiply = e.snapshotStrokePaint();
      expect(identical(red1, redMultiply), isFalse);
      expect(redMultiply!.blendMode, BlendMode.multiply);
    });

    test('non-overlapping multi-color points coalesce and match pixels', () async {
      final batched = Flut5Engine()..strokeWeight(4);
      final reference = Flut5Engine()..strokeWeight(4);
      for (var i = 0; i < 20; i++) {
        final color = i.isEven ? Colors.red : Colors.blue;
        final x = 12.0 + (i % 5) * 28.0;
        final y = 16.0 + (i ~/ 5) * 32.0;

        batched
          ..stroke(color)
          ..point(x, y);

        reference.renderQueue.enqueue(
          MultiPointRenderItem(
            Float32List.fromList([x, y]),
            (reference..stroke(color)).snapshotPointPaint()!,
          ),
        );
      }
      batched.renderQueue.flushPending();
      expect(batched.renderQueue.items, hasLength(2));
      expect(
        batched.renderQueue.items.every((item) => item is MultiPointRenderItem),
        isTrue,
      );

      _expectPixelsMatch(
        await _renderQueue(batched.renderQueue),
        await _renderQueue(reference.renderQueue),
      );
    });

    test('multi-color lines coalesce when apart and preserve z-order on overlap', () async {
      // Disjoint alternating lines -> 2 MultiLineRenderItems.
      final apart = Flut5Engine()..strokeWeight(3);
      for (var i = 0; i < 12; i++) {
        final y = 10.0 + i * 12.0;
        apart
          ..stroke(i.isEven ? Colors.red : Colors.blue)
          ..line(10, y, 140, y);
      }
      apart.renderQueue.flushPending();
      expect(apart.renderQueue.items, hasLength(2));
      expect(
        apart.renderQueue.items.every((item) => item is MultiLineRenderItem),
        isTrue,
      );

      // Crossing alternating lines -> exact z-order preserved against reference.
      final crossing = Flut5Engine()..strokeWeight(6);
      final reference = Flut5Engine()..strokeWeight(6);
      final segs = [
        (Colors.red, 20.0, 20.0, 140.0, 140.0),
        (Colors.blue, 140.0, 20.0, 20.0, 140.0),
        (Colors.red, 20.0, 80.0, 140.0, 80.0),
        (Colors.blue, 80.0, 20.0, 80.0, 140.0),
      ];
      for (final (color, x1, y1, x2, y2) in segs) {
        crossing
          ..stroke(color)
          ..line(x1, y1, x2, y2);
        reference.renderQueue.enqueue(
          LineRenderItem(
            Offset(x1, y1),
            Offset(x2, y2),
            (reference..stroke(color)).snapshotStrokePaint()!,
          ),
        );
      }
      crossing.renderQueue.flushPending();
      _expectPixelsMatch(
        await _renderQueue(crossing.renderQueue),
        await _renderQueue(reference.renderQueue),
      );
    });

    test('deep nested folded transforms match explicit canvas transforms', () async {
      final folded = Flut5Engine()
        ..fill(Colors.indigo)
        ..noStroke();
      final explicit = Flut5Engine()
        ..fill(Colors.indigo)
        ..noStroke();
      final fillPaint = explicit.snapshotFillPaint()!;

      // 20 nested push/translate/rotate/scale/pop scopes (grows the flat fold
      // stack beyond its initial capacity) with non-overlapping pentagons.
      for (var i = 0; i < 20; i++) {
        folded.push();
        folded.translate(10, 4);
        folded.rotate(0.06);
        folded.scale(0.98);
        folded.polygon(0, 0, 5, 7);

        explicit.renderQueue.enqueue(TransformRenderItem.push());
        explicit.renderQueue.enqueue(TransformRenderItem.translate(10, 4));
        explicit.renderQueue.enqueue(TransformRenderItem.rotate(0.06));
        explicit.renderQueue.enqueue(TransformRenderItem.scale(0.98, 0.98));
        final p = Path();
        for (var k = 0; k < 5; k++) {
          final a = (math.pi * 2 * k) / 5 - math.pi / 2;
          final vx = 3.5 * math.cos(a), vy = 3.5 * math.sin(a);
          if (k == 0) {
            p.moveTo(vx, vy);
          } else {
            p.lineTo(vx, vy);
          }
        }
        p.close();
        explicit.renderQueue.enqueue(PathRenderItem(p, fillPaint, null));
      }
      for (var i = 0; i < 20; i++) {
        folded.pop();
        explicit.renderQueue.enqueue(TransformRenderItem.pop());
      }
      folded.renderQueue.flushPending();
      expect(folded.renderQueue.items, hasLength(1));

      // Verify all 20 pops unwound the resized flat fold stack back to exact
      // identity (draw a rect after popping and check its bounds).
      folded.fill(Colors.red);
      folded.rect(5, 130, 16, 16);
      explicit.renderQueue.enqueue(
        RectRenderItem(
          const Rect.fromLTWH(5, 130, 16, 16),
          null,
          Paint()..color = Colors.red,
          null,
        ),
      );
      folded.renderQueue.flushPending();
      expect(
        folded.renderQueue.items.last.bounds,
        const Rect.fromLTWH(5, 130, 16, 16),
      );

      // Small edge differences (<= 8/255) occur because Skia accumulates 60
      // float32 matrix multiplies while folded transforms accumulate in float64.
      _expectPixelsMatch(
        await _renderQueue(folded.renderQueue),
        await _renderQueue(explicit.renderQueue),
        tolerance: 12,
      );
    });
  });

  group('Phase 2 — Dynamic text glyph atlas & batching', () {
    final cache = Flut5TextCache.instance;
    setUp(cache.clear);
    tearDown(cache.clear);

    test('multi-color rotated/scaled textDynamic coalesces into 1 batch item', () async {
      final batched = Flut5Engine()
        ..noStroke()
        ..textSize(18);
      final single = Flut5Engine()
        ..noStroke()
        ..textSize(18);

      final calls = [
        ('Alpha', Colors.red, 12.0, 20.0, 0.0, 1.0),
        ('Beta', Colors.blue, 24.0, 56.0, 0.15, 1.2),
        ('Gamma 123', Colors.green, 18.0, 102.0, -0.1, 0.9),
      ];

      for (final (str, color, x, y, angle, sc) in calls) {
        batched
          ..push()
          ..translate(x, y)
          ..rotate(angle)
          ..scale(sc)
          ..fill(color)
          ..textDynamic(str, 0, 0)
          ..pop();

        single.renderQueue
          ..enqueue(TransformRenderItem.push())
          ..enqueue(TransformRenderItem.translate(x, y))
          ..enqueue(TransformRenderItem.rotate(angle))
          ..enqueue(TransformRenderItem.scale(sc, sc))
          ..enqueue(
            TextDynamicRenderItem(
              text: str,
              x: 0,
              y: 0,
              fontFamily: 'sans-serif',
              fontSize: 18,
              fontWeight: FontWeight.normal,
              fontStyle: FontStyle.normal,
              textAlign: TextAlign.left,
              textLeading: null,
              fillPaint: Paint()..color = color,
            ),
          )
          ..enqueue(TransformRenderItem.pop());
      }

      batched.renderQueue.flushPending();
      expect(batched.renderQueue.items, hasLength(1));
      expect(batched.renderQueue.items.single, isA<TextDynamicBatchRenderItem>());

      _expectPixelsMatch(
        await _renderQueue(batched.renderQueue),
        await _renderQueue(single.renderQueue),
        tolerance: 2,
      );
    });

    test('animated letterSpacing & textLeading keep glyph cache size flat', () {
      final engine = Flut5Engine()
        ..fill(Colors.black)
        ..noStroke()
        ..textSize(20);

      // Warm up frame 0.
      engine
        ..letterSpacing(0.0)
        ..textLeading(24.0)
        ..textDynamic('Hello\nWorld', 10, 10);
      final recorder0 = ui.PictureRecorder();
      engine.renderQueue.execute(Canvas(recorder0));
      recorder0.endRecording().dispose();
      engine.renderQueue.clear();

      final initialGlyphs = engine.textCacheLength;
      final initialBytes = engine.textCacheBytes;
      final initialLayouts = engine.textLayoutCacheLength;
      expect(initialGlyphs, greaterThan(0));

      for (var frame = 1; frame <= 80; frame++) {
        engine
          ..letterSpacing(frame * 0.17)
          ..textLeading(20.0 + frame * 0.25)
          ..textDynamic('Hello\nWorld', 10, 10);
        final recorder = ui.PictureRecorder();
        engine.renderQueue.execute(Canvas(recorder));
        recorder.endRecording().dispose();
        engine.renderQueue.clear();
      }

      // Spacing moves glyphs across subpixel positions, so a glyph may gain
      // its other phases — but never a raster per animation value.
      final warmGlyphs = engine.textCacheLength;
      final warmBytes = engine.textCacheBytes;
      expect(
        warmGlyphs,
        lessThanOrEqualTo(initialGlyphs * Flut5TextCache.subpixelPhases),
      );
      expect(warmBytes, greaterThanOrEqualTo(initialBytes));
      expect(engine.textLayoutCacheLength, initialLayouts);

      for (var frame = 1; frame <= 80; frame++) {
        engine
          ..letterSpacing(frame * 0.17)
          ..textLeading(20.0 + frame * 0.25)
          ..textDynamic('Hello\nWorld', 10, 10);
        final recorder = ui.PictureRecorder();
        engine.renderQueue.execute(Canvas(recorder));
        recorder.endRecording().dispose();
        engine.renderQueue.clear();
      }
      expect(engine.textCacheLength, warmGlyphs);
      expect(engine.textCacheBytes, warmBytes);
    });

    test('textLeading called before textSize keeps exact pixel spacing', () async {
      Future<Uint8List> drawOrder(bool leadingFirst) async {
        final e = Flut5Engine()
          ..fill(Colors.black)
          ..noStroke();
        if (leadingFirst) {
          e
            ..textLeading(34)
            ..textSize(20);
        } else {
          e
            ..textSize(20)
            ..textLeading(34);
        }
        e.textDynamic('Top\nBottom', 12, 12);
        return _renderQueue(e.renderQueue);
      }

      // Warm the glyph atlas first, so both draws sample the same pages.
      await drawOrder(true);
      _expectPixelsMatch(await drawOrder(true), await drawOrder(false));
    });
  });

  group('Phase 3 — Image tinting, filter quality & open image batching', () {
    late ui.Image imgA;
    late ui.Image imgB;

    setUp(() async {
      imgA = await _makeTestImage(Colors.white, const Color(0xFFCCCCCC));
      imgB = await _makeTestImage(const Color(0xFFEEEEEE), Colors.grey);
    });

    tearDown(() {
      imgA.dispose();
      imgB.dispose();
    });

    test('multi-tinted sprites coalesce into 1 atlas and match unbatched items', () async {
      final batched = Flut5Engine();
      final reference = Flut5Engine();
      final flImg = Flut5Image.fromUiImage(imgA.clone());
      final tints = [null, Colors.red, const Color(0xAA00FF88), Colors.blue];

      for (var i = 0; i < tints.length; i++) {
        final x = 10.0 + i * 35.0;
        final y = 30.0 + (i.isOdd ? 10.0 : 0.0);
        final angle = i * 0.2;

        if (tints[i] == null) {
          batched.noTint();
        } else {
          batched.tint(tints[i]!);
        }
        batched
          ..push()
          ..translate(x, y)
          ..rotate(angle)
          ..image(flImg, 0, 0, 24, 24)
          ..pop();

        reference.renderQueue
          ..enqueue(TransformRenderItem.push())
          ..enqueue(TransformRenderItem.translate(x, y))
          ..enqueue(TransformRenderItem.rotate(angle))
          ..enqueue(
            ImageRenderItem(
              image: imgA,
              src: const Rect.fromLTWH(0, 0, 20, 20),
              dst: const Rect.fromLTWH(0, 0, 24, 24),
              blendMode: BlendMode.srcOver,
              tint: tints[i],
            ),
          )
          ..enqueue(TransformRenderItem.pop());
      }

      batched.renderQueue.flushPending();
      expect(batched.renderQueue.items, hasLength(1));
      final atlas = batched.renderQueue.items.single as ImageAtlasRenderItem;
      expect(atlas.spriteCount, 4);
      expect(atlas.colors, isNotNull);

      _expectPixelsMatch(
        await _renderQueue(batched.renderQueue),
        await _renderQueue(reference.renderQueue),
        tolerance: 2,
      );
      flImg.dispose();
    });

    test('interleaved disjoint images coalesce into 2 atlases and match pixels', () async {
      final batched = Flut5Engine();
      final reference = Flut5Engine();
      final fa = Flut5Image.fromUiImage(imgA.clone());
      final fb = Flut5Image.fromUiImage(imgB.clone());

      for (var i = 0; i < 8; i++) {
        final x = 6.0 + (i % 4) * 36.0;
        final y = 12.0 + (i ~/ 4) * 44.0;
        final fl = i.isEven ? fa : fb;
        final raw = i.isEven ? imgA : imgB;

        batched.image(fl, x, y, 24, 24);
        reference.renderQueue.enqueue(
          ImageRenderItem(
            image: raw,
            src: const Rect.fromLTWH(0, 0, 20, 20),
            dst: Rect.fromLTWH(x, y, 24, 24),
            blendMode: BlendMode.srcOver,
          ),
        );
      }

      batched.renderQueue.flushPending();
      expect(batched.renderQueue.items, hasLength(2));
      expect(
        batched.renderQueue.items.every((i) => i is ImageAtlasRenderItem),
        isTrue,
      );

      _expectPixelsMatch(
        await _renderQueue(batched.renderQueue),
        await _renderQueue(reference.renderQueue),
      );
      fa.dispose();
      fb.dispose();
    });

    test('imageFilterQuality controls queued ImageRenderItem filterQuality', () {
      final e = Flut5Engine();
      expect(e.imageFilterQuality(), FilterQuality.medium);
      expect(e.imageFilterQuality(FilterQuality.none), FilterQuality.none);

      final fl = Flut5Image.fromUiImage(imgA.clone());
      e.image(fl, 0, 0, 40, 20); // non-uniform -> ImageRenderItem
      e.renderQueue.flushPending();
      final item = e.renderQueue.items.single as ImageRenderItem;
      expect(item.filterQuality, FilterQuality.none);
      fl.dispose();
    });

    test('repeated Flut5Image.updatePixels reuses scratch buffers accurately', () async {
      final e = Flut5Engine();
      final img = e.createImage(16, 16);
      img.loadPixels();
      for (var step = 0; step < 3; step++) {
        final color = [Colors.red, Colors.green, Colors.blue][step];
        for (var y = 0; y < 16; y++) {
          for (var x = 0; x < 16; x++) {
            img.set(x, y, color);
          }
        }
        img.updatePixels();
        final data = await img.uiImage.toByteData();
        final bytes = data!.buffer.asUint8List();
        expect(bytes[0], (color.r * 255).round());
        expect(bytes[1], (color.g * 255).round());
        expect(bytes[2], (color.b * 255).round());
        expect(bytes[3], 255);
      }
      img.dispose();
    });
  });

  group('Phase 4 — Physics broadphase, static particles & caches', () {
    test('particle spatial hash handles extreme outlier without losing collisions', () {
      // 1) Isolated colliding pairs inside a 60-particle scene match bit-for-bit
      //    whether or not an extreme outlier triggers spatial hashing.
      Flut5PhysicsEngine buildPairsWorld({required bool withOutlier}) {
        final world = Flut5PhysicsEngine(windowSize: () => const Size(800, 800))
          ..particleCollision()
          ..particleRestitution = 1.0;
        for (var i = 0; i < 30; i++) {
          final bx = 40.0 + (i % 6) * 100.0;
          final by = 40.0 + (i ~/ 6) * 100.0;
          final a = world.createParticle(bx, by)..radius = 10.0;
          final b = world.createParticle(bx + 15.0, by)..radius = 10.0;
          a.velocity.setValues(3.0, 0.0, 0.0);
          b.velocity.setValues(-3.0, 0.0, 0.0);
        }
        if (withOutlier) {
          world.createParticle(1e6, 1e6).radius = 10.0;
        }
        return world;
      }

      final clean = buildPairsWorld(withOutlier: false);
      final outlier = buildPairsWorld(withOutlier: true);
      for (var step = 0; step < 5; step++) {
        clean.update();
        outlier.update();
      }
      for (var i = 0; i < 60; i++) {
        expect(outlier.particles[i].x, closeTo(clean.particles[i].x, 1e-12));
        expect(outlier.particles[i].y, closeTo(clean.particles[i].y, 1e-12));
        expect(
          outlier.particles[i].velocity.x,
          closeTo(clean.particles[i].velocity.x, 1e-12),
        );
      }

      // 2) Dense 80-particle cluster + extreme outlier still resolves every
      //    touching pair cleanly without NaN or missed overlaps.
      final cluster = Flut5PhysicsEngine(windowSize: () => const Size(400, 400))
        ..particleCollision(iterations: 6)
        ..particleRestitution = 0.5;
      for (var i = 0; i < 80; i++) {
        final col = i % 10;
        final row = i ~/ 10;
        cluster.createParticle(50 + col * 14.0, 50 + row * 14.0).radius = 8.0;
      }
      cluster.createParticle(1e6, 1e6).radius = 8.0;
      for (var step = 0; step < 15; step++) {
        cluster.update();
      }
      for (var i = 0; i < 80; i++) {
        for (var j = i + 1; j < 80; j++) {
          final dx = cluster.particles[i].x - cluster.particles[j].x;
          final dy = cluster.particles[i].y - cluster.particles[j].y;
          expect(math.sqrt(dx * dx + dy * dy), greaterThan(15.5));
        }
      }
    });

    test('static particle ignores gravity, collisions, and anchors a spring', () {
      final world = Flut5PhysicsEngine(windowSize: () => const Size(300, 300))
        ..setGravity(0.5)
        ..particleCollision();
      final anchor = world.createParticle(100, 50)
        ..radius = 10
        ..isStatic = true;
      final bob = world.createParticle(100, 120)..radius = 10;
      world.createSpring(anchor, bob)
        ..k = 0.1
        ..restLength = 40;

      // Throw a third particle directly at the static anchor.
      final striker = world.createParticle(100, 20)..radius = 10;
      striker.velocity.setValues(0, 15, 0);

      for (var i = 0; i < 20; i++) {
        world.update();
      }

      expect(anchor.x, 100.0);
      expect(anchor.y, 50.0);
      expect(anchor.inverseMass, 0.0);
      expect(bob.y, lessThan(130.0));
      expect(striker.y, lessThan(50.0));
    });

    test('1D SAP polygon broadphase resolves many colliding boxes cleanly', () {
      final world = Flut5PhysicsEngine(windowSize: () => const Size(600, 400))
        ..setGravity(0.3)
        ..polygonRestitution = 0.2;
      world.createRect(300, 380, 580, 30).isStatic = true;
      for (var i = 0; i < 24; i++) {
        final col = i % 6;
        final row = i ~/ 6;
        world.createRect(80 + col * 80.0, 40 + row * 40.0, 28, 28);
      }

      for (var step = 0; step < 60; step++) {
        world.update();
      }

      for (final poly in world.polygons) {
        expect(poly.x.isFinite, isTrue);
        expect(poly.y.isFinite, isTrue);
        expect(poly.y, lessThan(385.0));
      }
    });

    test('polygon corners cache returns identical list until moved or rotated', () {
      final rect = Flut5PhysicsRect(50, 60, 20, 10);
      final first = rect.corners;
      final second = rect.corners;
      expect(identical(first, second), isTrue);

      rect.position.x = 70;
      final moved = rect.corners;
      expect(identical(first, moved), isFalse);
      expect(moved[0].x, closeTo(60, 1e-12));

      rect.angle = math.pi / 2;
      final rotated = rect.corners;
      expect(identical(moved, rotated), isFalse);
    });

    test('rigid body rejects non-positive or non-finite mass and updates inverseMass', () {
      final p = Flut5PhysicsParticle(0, 0);
      expect(() => p.mass = 0, throwsArgumentError);
      expect(() => p.mass = -2, throwsArgumentError);
      expect(() => p.mass = double.nan, throwsArgumentError);
      expect(() => p.mass = double.infinity, throwsArgumentError);
      p.mass = 4.0;
      expect(p.inverseMass, closeTo(0.25, 1e-12));
    });
  });

  group('Phase 5 — Ray scene BVH, quadtree, noise, steering & loop control', () {
    test('Flut5RayScene matches brute-force castRayClosest on 200 random walls', () {
      final rng = math.Random(42);
      final walls = [
        for (var i = 0; i < 200; i++)
          Flut5LineSegment(
            rng.nextDouble() * 400 - 200,
            rng.nextDouble() * 400 - 200,
            rng.nextDouble() * 400 - 200,
            rng.nextDouble() * 400 - 200,
          ),
      ];
      final engine = Flut5Engine();
      final scene = engine.createRayScene(walls);

      for (var deg = 0; deg < 360; deg += 2) {
        final a = deg * math.pi / 180.0;
        final dx = math.cos(a);
        final dy = math.sin(a);
        final expected = engine.castRayClosest(
          5,
          -7,
          Flut5Vector(dx, dy),
          walls,
        );
        final actual = scene.castRayClosest(5, -7, dx, dy);
        if (expected == null) {
          expect(actual, isNull, reason: 'deg=$deg');
        } else {
          expect(actual, isNotNull, reason: 'deg=$deg');
          expect(actual!.point.x, closeTo(expected.x, 1e-9));
          expect(actual.point.y, closeTo(expected.y, 1e-9));
          expect(
            actual.distance,
            closeTo(
              math.sqrt(
                (expected.x - 5) * (expected.x - 5) +
                    (expected.y + 7) * (expected.y + 7),
              ),
              1e-9,
            ),
          );
          expect(actual.segmentT, inInclusiveRange(0.0, 1.0));
          expect(actual.normal.mag(), closeTo(1.0, 1e-9));
          // Normal must face back toward the incoming ray.
          expect(actual.normal.x * dx + actual.normal.y * dy, lessThanOrEqualTo(1e-9));
          expect(identical(actual.wall, walls[actual.wallIndex]), isTrue);
        }
      }
    });

    test('Flut5RayScene castRay, castRayFan, reflect, visibilityPolygon & fromPolygons', () {
      final box = Flut5PhysicsRect(50, 0, 20, 20);
      final room = [
        Flut5LineSegment(-100, -100, 100, -100),
        Flut5LineSegment(100, -100, 100, 100),
        Flut5LineSegment(100, 100, -100, 100),
        Flut5LineSegment(-100, 100, -100, -100),
      ];
      final scene = Flut5RayScene.fromPolygons([box], extraWalls: room);

      // Ray along +X hits box front (x=40), box back (x=60), then room wall (x=100).
      final allHits = scene.castRay(0, 0, 1, 0);
      expect(allHits.map((h) => h.point.x), [
        closeTo(40, 1e-9),
        closeTo(60, 1e-9),
        closeTo(100, 1e-9),
      ]);

      // Reflection off vertical wall at x=40 reverses X component.
      final reflected = allHits.first.reflect(1, 1);
      expect(reflected.x, closeTo(-math.sqrt1_2, 1e-9));
      expect(reflected.y, closeTo(math.sqrt1_2, 1e-9));

      final fan = scene.castRayFan(0, 0, 36);
      expect(fan, hasLength(36));
      expect(fan.every((h) => h != null), isTrue);

      final vis = scene.visibilityPolygon(0, 0);
      expect(vis.length, greaterThanOrEqualTo(8));
      // Every visibility vertex should lie within the room bounds.
      for (final p in vis) {
        expect(p.x, inInclusiveRange(-100.01, 100.01));
        expect(p.y, inInclusiveRange(-100.01, 100.01));
      }

      final capped = scene.visibilityPolygon(0, 0, maxRadius: 30);
      for (final p in capped) {
        expect(math.sqrt(p.x * p.x + p.y * p.y), lessThanOrEqualTo(30.01));
      }

      // Mutating a wall + rebuild updates hits.
      final dynamicWall = Flut5LineSegment(10, -10, 10, 10);
      final dynamicScene = Flut5RayScene([dynamicWall]);
      expect(dynamicScene.castRayClosest(0, 0, 1, 0)!.distance, closeTo(10, 1e-9));
      dynamicWall.start.x = 25;
      dynamicWall.end.x = 25;
      dynamicScene.rebuild();
      expect(dynamicScene.castRayClosest(0, 0, 1, 0)!.distance, closeTo(25, 1e-9));
    });

    test('rayCircleIntersection covers front hit, inside exit, tangent & misses', () {
      final e = Flut5Engine();
      // Hit from outside.
      final front = e.rayCircleIntersection(20, 0, 5, 0, 0, Flut5Vector(1, 0))!;
      expect(front.x, closeTo(15, 1e-12));
      expect(front.y, closeTo(0, 1e-12));

      // Hit from inside returns exit point ahead of origin.
      final exit = e.rayCircleIntersection(0, 0, 10, 0, 0, Flut5Vector(0, 1))!;
      expect(exit.x, closeTo(0, 1e-12));
      expect(exit.y, closeTo(10, 1e-12));

      // Behind ray, zero dir, negative radius -> null.
      expect(
        e.rayCircleIntersection(-20, 0, 5, 0, 0, Flut5Vector(1, 0)),
        isNull,
      );
      expect(
        e.rayCircleIntersection(20, 0, 5, 0, 0, Flut5Vector.zero()),
        isNull,
      );
      expect(
        e.rayCircleIntersection(20, 0, -5, 0, 0, Flut5Vector(1, 0)),
        isNull,
      );
    });

    test('Flut5Quadtree queryCircle, reusable into buffer & clear()', () {
      final rng = math.Random(19);
      final tree = Flut5Quadtree<int>(400, 400);
      final points = <Flut5QuadtreePoint<int>>[];
      for (var i = 0; i < 800; i++) {
        final pt = Flut5QuadtreePoint(
          rng.nextDouble() * 400,
          rng.nextDouble() * 400,
          i,
        );
        points.add(pt);
        tree.add(pt);
      }

      final reusable = <Flut5QuadtreePoint<int>>[];
      for (var q = 0; q < 40; q++) {
        final cx = rng.nextDouble() * 400;
        final cy = rng.nextDouble() * 400;
        final r = rng.nextDouble() * 90;
        reusable.clear();
        final found = tree.queryCircle(cx, cy, r, into: reusable);
        expect(identical(found, reusable), isTrue);

        final expected = {
          for (final p in points)
            if ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy) <= r * r)
              p.payload,
        };
        expect(found.map((p) => p.payload).toSet(), expected);
        expect(found, hasLength(expected.length));
      }

      // clear() collapses and lets the tree be rebuilt cleanly.
      tree.clear();
      expect(tree.children, isEmpty);
      expect(tree.points, isEmpty);
      expect(tree.query(0, 0, 400, 400), isEmpty);
      tree.add(Flut5QuadtreePoint(20, 30, 999));
      expect(tree.queryCircle(20, 30, 1).single.payload, 999);
    });

    test('Simplex noise single-octave fast path and multi-octave stay deterministic', () {
      final a = Flut5Engine()
        ..noiseSeed(1234)
        ..noiseDetail(1);
      final b = Flut5Engine()
        ..noiseSeed(1234)
        ..noiseDetail(1);
      for (var i = 0; i < 25; i++) {
        final v = a.noise(i * 0.13, i * 0.07, i * 0.03);
        expect(v, inInclusiveRange(-1.0, 1.0));
        expect(v, b.noise(i * 0.13, i * 0.07, i * 0.03));
      }
      a.noiseDetail(4, 0.5);
      b.noiseDetail(4, 0.5);
      expect(a.noise(1.2, 3.4, 5.6), b.noise(1.2, 3.4, 5.6));
    });

    test('Steering alignment() matches Reynolds rule & separation() guards tiny dist', () {
      final e = Flut5Engine();
      final pos = Flut5Vector(0, 0);
      final vel = Flut5Vector(1, 0);
      final positions = [
        pos, // self -> skipped
        Flut5Vector(10, 0), // in range
        Flut5Vector(0, 20), // in range
        Flut5Vector(200, 0), // outside radius
      ];
      final velocities = [
        Flut5Vector(-99, -99),
        Flut5Vector(0, 2),
        Flut5Vector(0, 6),
        Flut5Vector(100, 0),
      ];
      final force = e.alignment(
        pos,
        vel,
        positions,
        velocities,
        alignmentRadius: 50,
        maxVelocity: 4.0,
        maxForce: 100.0,
      );
      // Desired = (0, 4), minus velocity (1, 0) => (-1, 4).
      expect(force.x, closeTo(-1.0, 1e-12));
      expect(force.y, closeTo(4.0, 1e-12));

      // Near-coincident separation does not produce NaN or Inf.
      final sep = e.separation(Flut5Vector(0, 0), Flut5Vector(1, 0), [
        Flut5Vector(1e-160, 0),
        Flut5Vector(10, 0),
      ]);
      expect(sep.x.isFinite, isTrue);
      expect(sep.y.isFinite, isTrue);
      expect(sep.x, lessThan(0.0));
    });

    testWidgets('noLoop(), redraw(), loop(), and mouseIsPressed work on Flut5Canvas', (
      tester,
    ) async {
      final sketch = _LoopControlSketch(stopInSetup: true);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 120,
            height: 120,
            child: Flut5Canvas(sketch: sketch),
          ),
        ),
      );
      // Let post-frame setup + initial single draw settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(sketch.setupCount, 1);
      expect(sketch.isLooping, isFalse);
      final initialDraws = sketch.drawCount;
      expect(initialDraws, 1);

      // Advancing time while paused does not trigger more draw() calls.
      await tester.pump(const Duration(milliseconds: 200));
      expect(sketch.drawCount, initialDraws);

      // redraw() triggers exactly one additional draw().
      sketch.redraw();
      await tester.pump();
      expect(sketch.drawCount, initialDraws + 1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(sketch.drawCount, initialDraws + 1);

      // Pointer press sets mouseIsPressed.
      final gesture = await tester.startGesture(
        const Offset(40, 40),
        kind: PointerDeviceKind.mouse,
      );
      sketch.redraw();
      await tester.pump();
      expect(sketch.mouseIsPressed, isTrue);
      expect(sketch.lastMousePressed, isTrue);
      await gesture.up();
      expect(sketch.mouseIsPressed, isFalse);

      // loop() resumes continuous ticks.
      sketch.loop();
      expect(sketch.isLooping, isTrue);
      final beforeResume = sketch.drawCount;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(sketch.drawCount, greaterThan(beforeResume));
    });

    test('Flut5 unprefixed forwarders expose every new API cleanly', () {
      final engine = Flut5Engine();
      final helper = _ForwarderSmokeHelper(engine);
      helper.exerciseForwarders();
    });
  });

  group('Wave 2 — Optional optimizations', () {
    final cache = Flut5TextCache.instance;

    setUp(cache.clear);
    tearDown(() {
      cache.clear();
      ImageAtlasRenderItem.clearPaddedCache();
    });

    test('1px padded & transparent-border rotated sprite atlases match fidelity', () async {
      final raw = await _makeTestImage(Colors.red, Colors.yellow);
      final flImg = Flut5Image.fromUiImage(raw.clone());

      // 1) Native 1:1 rotated opaque-edged sprites take the 1px transparent-
      //    padded single-drawRawAtlas fast path cleanly.
      final nativeBatched = Flut5Engine();
      final nativeRef = Flut5Engine();
      final nativeSpecs = [
        (34.0, 34.0, 0.35, 1.0, null),
        (90.0, 42.0, -0.5, 1.0, const Color(0xCC66CCFF)),
        (46.0, 108.0, 0.8, -1.0, Colors.lime),
        (114.0, 112.0, -0.25, 1.0, null),
      ];
      for (final (x, y, angle, s, tintColor) in nativeSpecs) {
        if (tintColor == null) {
          nativeBatched.noTint();
        } else {
          nativeBatched.tint(tintColor);
        }
        nativeBatched
          ..push()
          ..translate(x, y)
          ..rotate(angle)
          ..scale(s)
          ..image(flImg, -10, -10)
          ..pop();
        nativeRef.renderQueue
          ..enqueue(TransformRenderItem.push())
          ..enqueue(TransformRenderItem.translate(x, y))
          ..enqueue(TransformRenderItem.rotate(angle))
          ..enqueue(TransformRenderItem.scale(s, s))
          ..enqueue(
            ImageRenderItem(
              image: raw,
              src: const Rect.fromLTWH(0, 0, 20, 20),
              dst: const Rect.fromLTWH(-10, -10, 20, 20),
              blendMode: BlendMode.srcOver,
              tint: tintColor,
            ),
          )
          ..enqueue(TransformRenderItem.pop());
      }
      nativeBatched.renderQueue.flushPending();
      expect(nativeBatched.renderQueue.items, hasLength(1));
      expect(nativeBatched.renderQueue.items.single, isA<ImageAtlasRenderItem>());
      final paddedBefore = ImageAtlasRenderItem.debugPaddedAtlasDraws;
      final nativePx = await _renderQueue(nativeBatched.renderQueue);
      expect(
        ImageAtlasRenderItem.debugPaddedAtlasDraws,
        greaterThan(paddedBefore),
      );
      final nativeRefPx = await _renderQueue(nativeRef.renderQueue);
      var channelErr = 0;
      var largeDiffs = 0;
      for (var i = 0; i < nativePx.length; i++) {
        final d = (nativePx[i] - nativeRefPx[i]).abs();
        channelErr += d;
        if (d > 16) largeDiffs++;
      }
      expect(channelErr / nativePx.length, lessThan(0.5));
      expect(largeDiffs / nativePx.length, lessThan(0.005));

      // 2) Transparent-bordered procedural sprites batch directly into 1
      //    unpadded drawRawAtlas call at ANY scale (0.7×..1.8×) with exact AA!
      final disc = Flut5Image.create(24, 24);
      for (var y = 3; y < 21; y++) {
        for (var x = 3; x < 21; x++) {
          final dx = x - 11.5;
          final dy = y - 11.5;
          if (dx * dx + dy * dy <= 64) {
            disc.set(x, y, Colors.purple);
          }
        }
      }
      disc.updatePixels();
      expect(disc.hasTransparentBorder, isTrue);

      final discBatched = Flut5Engine();
      final discRef = Flut5Engine();
      final discSpecs = [
        (34.0, 34.0, 0.3, 0.8),
        (96.0, 44.0, -0.6, 1.4),
        (46.0, 114.0, 0.9, -1.2),
        (114.0, 110.0, -0.2, 1.7),
      ];
      for (final (x, y, angle, s) in discSpecs) {
        discBatched
          ..push()
          ..translate(x, y)
          ..rotate(angle)
          ..scale(s)
          ..image(disc, -12, -12)
          ..pop();
        discRef.renderQueue
          ..enqueue(TransformRenderItem.push())
          ..enqueue(TransformRenderItem.translate(x, y))
          ..enqueue(TransformRenderItem.rotate(angle))
          ..enqueue(TransformRenderItem.scale(s, s))
          ..enqueue(
            ImageRenderItem(
              image: disc.uiImage,
              src: const Rect.fromLTWH(0, 0, 24, 24),
              dst: const Rect.fromLTWH(-12, -12, 24, 24),
              blendMode: BlendMode.srcOver,
            ),
          )
          ..enqueue(TransformRenderItem.pop());
      }
      discBatched.renderQueue.flushPending();
      final discAtlas =
          discBatched.renderQueue.items.single as ImageAtlasRenderItem;
      expect(discAtlas.preserveRotatedEdges, isFalse);
      _expectPixelsMatch(
        await _renderQueue(discBatched.renderQueue),
        await _renderQueue(discRef.renderQueue),
        tolerance: 2,
      );

      // 3) Scaled opaque-edged & cropped rotated sprites bypass padded atlas
      //    and preserve crisp 1px geometric AA via drawImageRect.
      final croppedBatched = Flut5Engine();
      final croppedRef = Flut5Engine();
      for (var i = 0; i < 3; i++) {
        final x = 32.0 + i * 44.0;
        final angle = 0.25 * (i + 1);
        croppedBatched
          ..push()
          ..translate(x, 80)
          ..rotate(angle)
          ..image(flImg, -10, -10, 20, 20, 3, 3, 14, 14)
          ..pop();
        croppedRef.renderQueue
          ..enqueue(TransformRenderItem.push())
          ..enqueue(TransformRenderItem.translate(x, 80))
          ..enqueue(TransformRenderItem.rotate(angle))
          ..enqueue(
            ImageRenderItem(
              image: raw,
              src: const Rect.fromLTWH(3, 3, 14, 14),
              dst: const Rect.fromLTWH(-10, -10, 20, 20),
              blendMode: BlendMode.srcOver,
            ),
          )
          ..enqueue(TransformRenderItem.pop());
      }
      croppedBatched.renderQueue.flushPending();
      final paddedBeforeCrop = ImageAtlasRenderItem.debugPaddedAtlasDraws;
      final cropBatchedPx = await _renderQueue(croppedBatched.renderQueue);
      expect(ImageAtlasRenderItem.debugPaddedAtlasDraws, paddedBeforeCrop);
      _expectPixelsMatch(
        cropBatchedPx,
        await _renderQueue(croppedRef.renderQueue),
        tolerance: 2,
      );

      // Disposing releases handles & evicts the padded copy cleanly.
      disc.dispose();
      flImg.dispose();
      raw.dispose();
    });

    test('shadowed textDynamic batches into 1 item and preserves overlap z-order', () async {
      // 1) Disjoint hard & soft/spread shadowed texts coalesce into 1 batch item.
      final batched = Flut5Engine()
        ..noStroke()
        ..textSize(18);
      final reference = Flut5Engine()
        ..noStroke()
        ..textSize(18);

      final hardShadow = Flut5ShadowSpec(
        const Color(0xCC000000),
        const Offset(3, 3),
        0,
        0,
      );
      final softShadow = Flut5ShadowSpec(
        const Color(0xAA220066),
        const Offset(4, 5),
        4,
        1.5,
      );

      final disjoint = [
        ('Hard', Colors.red, 12.0, 20.0, 0.0, 1.0, hardShadow),
        ('Soft', Colors.blue, 18.0, 68.0, 0.12, 1.1, softShadow),
        ('Spread', Colors.teal, 14.0, 120.0, -0.08, 0.95, softShadow),
      ];

      for (final (str, color, x, y, angle, sc, sh) in disjoint) {
        batched
          ..push()
          ..translate(x, y)
          ..rotate(angle)
          ..scale(sc)
          ..fill(color)
          ..shadow(sh.offset.dx, sh.offset.dy, sh.blur, sh.spread, sh.color)
          ..textDynamic(str, 0, 0)
          ..noShadow()
          ..pop();

        reference.renderQueue
          ..enqueue(TransformRenderItem.push())
          ..enqueue(TransformRenderItem.translate(x, y))
          ..enqueue(TransformRenderItem.rotate(angle))
          ..enqueue(TransformRenderItem.scale(sc, sc))
          ..enqueue(
            TextDynamicRenderItem(
              text: str,
              x: 0,
              y: 0,
              fontFamily: 'sans-serif',
              fontSize: 18,
              fontWeight: FontWeight.normal,
              fontStyle: FontStyle.normal,
              textAlign: TextAlign.left,
              textLeading: null,
              fillPaint: Paint()..color = color,
              shadow: sh,
            ),
          )
          ..enqueue(TransformRenderItem.pop());
      }

      batched.renderQueue.flushPending();
      expect(batched.renderQueue.items, hasLength(1));
      expect(batched.renderQueue.items.single, isA<TextDynamicBatchRenderItem>());
      _expectPixelsMatch(
        await _renderQueue(batched.renderQueue),
        await _renderQueue(reference.renderQueue),
        tolerance: 2,
      );

      // 2) Overlapping shadowed texts flush between layers so the second text's
      //    shadow paints above the first text's fill (exact painter's order).
      final overlapBatched = Flut5Engine()
        ..noStroke()
        ..textSize(24);
      final overlapRef = Flut5Engine()
        ..noStroke()
        ..textSize(24);

      final overlapCalls = [
        ('ABCD', Colors.red, 18.0, 44.0, hardShadow),
        ('WXYZ', Colors.green, 24.0, 48.0, softShadow),
      ];
      for (final (str, color, x, y, sh) in overlapCalls) {
        overlapBatched
          ..fill(color)
          ..shadow(sh.offset.dx, sh.offset.dy, sh.blur, sh.spread, sh.color)
          ..textDynamic(str, x, y);
        overlapRef.renderQueue.enqueue(
          TextDynamicRenderItem(
            text: str,
            x: x,
            y: y,
            fontFamily: 'sans-serif',
            fontSize: 24,
            fontWeight: FontWeight.normal,
            fontStyle: FontStyle.normal,
            textAlign: TextAlign.left,
            textLeading: null,
            fillPaint: Paint()..color = color,
            shadow: sh,
          ),
        );
      }

      overlapBatched.renderQueue.flushPending();
      expect(overlapBatched.renderQueue.items, hasLength(1));
      _expectPixelsMatch(
        await _renderQueue(overlapBatched.renderQueue),
        await _renderQueue(overlapRef.renderQueue),
        tolerance: 2,
      );
    });

    test('variable font fontVariations flow into rasterized text cache keys', () async {
      final engine = Flut5Engine()
        ..fill(Colors.black)
        ..noStroke()
        ..textSize(20);

      // Standard integer-hundred weight uses empty variation key (zero overhead).
      engine
        ..textWeight(400)
        ..textDynamic('Var', 10, 10);
      engine.renderQueue.flushPending();
      final standardItem =
          engine.renderQueue.items.single as TextDynamicRenderItem;
      expect(standardItem.fontVariationKey, isEmpty);
      expect(standardItem.fontVariations, isNull);
      await _renderQueue(engine.renderQueue);
      final countAfterStandard = engine.textCacheLength;
      engine.renderQueue.clear();

      // Fractional weight populates fontVariations & distinct cache entries,
      // and consecutive varied draws coalesce into TextDynamicBatchRenderItem.
      engine
        ..textWeight(450)
        ..textDynamic('Var', 10, 40)
        ..textDynamic('Axis', 10, 70);
      engine.renderQueue.flushPending();
      final variedBatch =
          engine.renderQueue.items.single as TextDynamicBatchRenderItem;
      expect(variedBatch.entries.first.fontVariationKey, contains('wght:450'));
      expect(variedBatch.entries.first.fontVariations, isNotNull);
      await _renderQueue(engine.renderQueue);
      expect(engine.textCacheLength, greaterThan(countAfterStandard));
      engine.renderQueue.clear();

      // Static text mode also renders cleanly with variable font weight.
      engine.textStatic('VarStatic', 10, 80);
      await _renderQueue(engine.renderQueue);
      expect(engine.textCacheLength, greaterThan(countAfterStandard));
    });

    test('soft-body precomputed rest offsets adapt to mass changes and pins', () {
      final world = Flut5PhysicsEngine(windowSize: () => const Size(300, 300))
        ..setGravity(0.25);
      final body = world.createSoftRect(
        150,
        80,
        60,
        40,
        resolution: 3,
      );

      for (var i = 0; i < 15; i++) {
        world.update();
      }
      for (final p in body.particles) {
        expect(p.x.isFinite, isTrue);
        expect(p.y.isFinite, isTrue);
      }

      // Mutate mass mid-simulation -> cached rest offsets recompute cleanly.
      body.particles.first.mass = 5.0;
      for (var i = 0; i < 15; i++) {
        world.update();
      }
      for (final p in body.particles) {
        expect(p.x.isFinite, isTrue);
        expect(p.y.isFinite, isTrue);
      }

      // Pin one corner particle -> stays fixed while others hang cleanly.
      final pinned = body.particles.first
        ..isStatic = true
        ..velocity.setZero();
      final pinX = pinned.x;
      final pinY = pinned.y;
      for (var i = 0; i < 20; i++) {
        world.update();
      }
      expect(pinned.x, pinX);
      expect(pinned.y, pinY);
      expect(body.particles.last.y, greaterThan(pinY));
    });

    test('physics sleeping settles resting bodies and wakes on impulse or contact', () {
      final world = Flut5PhysicsEngine(windowSize: () => const Size(400, 300))
        ..setGravity(0.35)
        ..particleCollision()
        ..polygonRestitution = 0.0
        ..particleRestitution = 0.0
        ..sleeping = true
        ..sleepFrames = 10
        ..sleepSpeedThreshold = 0.35
        ..sleepAngularThreshold = 0.05;

      // Static floor.
      world.createRect(200, 260, 380, 30).isStatic = true;

      // Dynamic box and dynamic particle resting on the floor.
      final box = world.createRect(140, 220, 30, 30);
      final ball = world.createParticle(240, 230)..radius = 10;

      for (var step = 0; step < 180; step++) {
        world.update();
      }
      expect(box.isSleeping, isTrue);
      expect(ball.isSleeping, isTrue);

      // Explicit applyForce wakes the sleeping ball immediately.
      ball.applyForce(Flut5Vector(0, -4));
      expect(ball.isSleeping, isFalse);

      // Dropping an awake striker onto the sleeping box wakes it on contact.
      final striker = world.createRect(140, 160, 26, 26);
      striker.velocity.setValues(0, 8, 0);
      for (var step = 0; step < 15; step++) {
        world.update();
      }
      expect(box.isSleeping, isFalse);
      expect(box.y.isFinite, isTrue);
    });

    test('physics substeps prevent fast particle tunneling through thin walls', () {
      expect(
        () => Flut5PhysicsEngine(windowSize: () => const Size(200, 200))
          ..substeps = 0,
        throwsArgumentError,
      );

      Flut5PhysicsParticle runShot(int substeps) {
        final world = Flut5PhysicsEngine(windowSize: () => const Size(300, 200))
          ..substeps = substeps
          ..particleRestitution = 0.5;
        world.createRect(120, 100, 8, 120).isStatic = true;
        final bullet = world.createParticle(90, 100)..radius = 4;
        bullet.velocity.setValues(40, 0, 0);
        for (var i = 0; i < 4; i++) {
          world.update();
        }
        return bullet;
      }

      final tunneled = runShot(1);
      final stopped = runShot(6);
      expect(tunneled.x, greaterThan(124.0));
      expect(stopped.x, lessThan(118.0));
      expect(stopped.velocity.x, lessThanOrEqualTo(0.0));
    });

    test('physics onCollision fires once per pair across all body types', () {
      final events = <Flut5PhysicsCollisionEvent>[];
      final world = Flut5PhysicsEngine(windowSize: () => const Size(400, 300))
        ..particleCollision(iterations: 3)
        ..windowBoundsCollision()
        ..onCollision = events.add;

      // 1) Overlapping particle–particle pair.
      final p1 = world.createParticle(60, 60)..radius = 12;
      final p2 = world.createParticle(76, 60)..radius = 12;

      // 2) Overlapping polygon–polygon pair.
      final r1 = world.createRect(180, 60, 30, 30);
      final r2 = world.createRect(204, 60, 30, 30);

      // 3) Overlapping polygon–particle pair.
      final r3 = world.createRect(300, 60, 30, 30);
      final p3 = world.createParticle(318, 60)..radius = 10;

      // 4) Particle hitting the canvas right edge (should NOT emit a bogus
      //    synthetic window-body collision event).
      final edgeP = world.createParticle(395, 220)..radius = 10;
      edgeP.velocity.setValues(5, 0, 0);

      world.update();

      bool hasPair(Flut5PhysicsBody x, Flut5PhysicsBody y) => events.any(
        (e) =>
            (identical(e.bodyA, x) && identical(e.bodyB, y)) ||
            (identical(e.bodyA, y) && identical(e.bodyB, x)),
      );
      int countPair(Flut5PhysicsBody x, Flut5PhysicsBody y) => events
          .where(
            (e) =>
                (identical(e.bodyA, x) && identical(e.bodyB, y)) ||
                (identical(e.bodyA, y) && identical(e.bodyB, x)),
          )
          .length;

      expect(countPair(p1, p2), 1);
      expect(countPair(r1, r2), 1);
      expect(countPair(r3, p3), 1);
      expect(events, hasLength(3));
      expect(hasPair(p1, p2), isTrue);
      for (final e in events) {
        expect(e.overlap, greaterThan(0.0));
        expect(e.normal.mag(), closeTo(1.0, 1e-9));
      }
    });

    test('physicsEngine.castRayClosest & castRay hit polygons and particles accurately', () {
      final world = Flut5PhysicsEngine(windowSize: () => const Size(300, 200));
      final box = world.createRect(60, 0, 20, 20)
        ..isStatic = true
        ..angle = math.pi / 4;
      final nearBall = world.createParticle(110, 0)..radius = 10;
      final farBall = world.createParticle(160, 0)..radius = 10;

      // Closest hit along +X is the rotated square's left vertex at 60 - 10*sqrt(2).
      final closest = world.castRayClosest(0, 0, 1, 0);
      expect(closest, isNotNull);
      expect(identical(closest!.body, box), isTrue);
      expect(closest.distance, closeTo(60 - 10 * math.sqrt2, 1e-6));
      expect(closest.normal.mag(), closeTo(1.0, 1e-9));
      expect(closest.normal.x, lessThan(0.0));

      // All hits are sorted by distance and include box + both particles.
      final hits = world.castRay(0, 0, 1, 0);
      expect(hits.length, greaterThanOrEqualTo(3));
      for (var i = 1; i < hits.length; i++) {
        expect(hits[i].distance, greaterThanOrEqualTo(hits[i - 1].distance));
      }
      expect(hits.any((h) => identical(h.body, box)), isTrue);
      expect(hits.any((h) => identical(h.body, nearBall)), isTrue);
      expect(hits.any((h) => identical(h.body, farBall)), isTrue);

      // Particle-only filter skips the box and hits nearBall at x = 100.
      final ballOnly = world.castRayClosest(
        0,
        0,
        1,
        0,
        includePolygons: false,
      );
      expect(ballOnly, isNotNull);
      expect(identical(ballOnly!.body, nearBall), isTrue);
      expect(ballOnly.distance, closeTo(100.0, 1e-9));
      expect(ballOnly.normal.x, closeTo(-1.0, 1e-9));
      expect(ballOnly.normal.y, closeTo(0.0, 1e-9));

      // maxDistance caps hits beyond range.
      expect(world.castRayClosest(0, 0, 1, 0, maxDistance: 30), isNull);
    });

    test('Flut5Quadtree pools nodes across clear() and supports allowOverflow', () {
      // 1) Node pooling across frame rebuilds.
      final rng = math.Random(101);
      final tree = Flut5Quadtree<int>(200, 200);
      for (var i = 0; i < 200; i++) {
        tree.add(
          Flut5QuadtreePoint(
            rng.nextDouble() * 200,
            rng.nextDouble() * 200,
            i,
          ),
        );
      }
      expect(tree.children, isNotEmpty);
      expect(tree.debugPooledNodeCount, 0);

      tree.clear();
      final pooledAfterClear = tree.debugPooledNodeCount;
      expect(pooledAfterClear, greaterThan(0));
      expect(tree.query(0, 0, 200, 200), isEmpty);

      for (var i = 0; i < 200; i++) {
        tree.add(
          Flut5QuadtreePoint(
            rng.nextDouble() * 200,
            rng.nextDouble() * 200,
            i,
          ),
        );
      }
      expect(tree.debugPooledNodeCount, lessThan(pooledAfterClear));
      expect(tree.query(0, 0, 200, 200), hasLength(200));

      // 2) allowOverflow accepts coincident points and maxDepth overflow cleanly.
      final overflowTree = Flut5Quadtree<int>(100, 100, 2, 4, true);
      expect(overflowTree.allowOverflow, isTrue);
      for (var i = 0; i < 20; i++) {
        expect(overflowTree.add(Flut5QuadtreePoint(50, 50, i)), isTrue);
      }
      expect(overflowTree.query(49, 49, 2, 2), hasLength(20));
      expect(overflowTree.queryCircle(50, 50, 1), hasLength(20));

      // Adding a separate point splits the leaf and keeps all 21 points.
      expect(overflowTree.add(Flut5QuadtreePoint(10, 10, 100)), isTrue);
      expect(overflowTree.query(0, 0, 100, 100), hasLength(21));

      // Exceeding maxDepth = 4 in a tight cluster stores overflow without throwing.
      for (var i = 0; i < 12; i++) {
        expect(
          overflowTree.add(Flut5QuadtreePoint(10.0 + i * 0.01, 10.0, 200 + i)),
          isTrue,
        );
      }
      expect(overflowTree.query(0, 0, 100, 100), hasLength(33));

      // Default remains strict (allowOverflow == false).
      final strictTree = Flut5Quadtree<int>(100, 100, 2, 4);
      expect(strictTree.allowOverflow, isFalse);
      strictTree.add(Flut5QuadtreePoint(50, 50, 0));
      strictTree.add(Flut5QuadtreePoint(50, 50, 1));
      expect(() => strictTree.add(Flut5QuadtreePoint(50, 50, 2)), throwsStateError);
    });

    test('zero-alloc engine environment stays lazy until snapshot is read', () {
      final engine = Flut5Engine();

      expect(engine.updateEnvironmentSize(const Size(320, 240)), isTrue);
      expect(engine.updateEnvironmentSize(const Size(320, 240)), isFalse);
      engine.events.addPointerHover(
        const PointerHoverEvent(position: Offset(42, 84)),
      );
      engine.advanceEnvironmentFrame(100);
      engine.advanceEnvironmentFrame(116);
      engine.setAvgMouseFrames(5);

      // None of the hot updates allocated a SketchEnvironment wrapper.
      expect(engine.debugHasCachedEnvironmentSnapshot, isFalse);
      expect(engine.width, 320.0);
      expect(engine.height, 240.0);
      expect(engine.mouseX, 42.0);
      expect(engine.mouseY, 84.0);
      expect(engine.frameCount, 2);
      expect(engine.deltaTime, 16.0);
      expect(engine.frameRate(), closeTo(62.5, 1e-9));
      expect(engine.avgMouseFrames, 5);

      // Reading `environment` lazily materializes and caches a matching snapshot.
      final snap = engine.environment;
      expect(engine.debugHasCachedEnvironmentSnapshot, isTrue);
      expect(snap.size, const Size(320, 240));
      expect(snap.mouseX, 42.0);
      expect(snap.mouseY, 84.0);
      expect(snap.frameCount, 2);
      expect(snap.deltaTime, 16.0);
      expect(snap.avgMouseFrames, 5);
      expect(identical(engine.environment, snap), isTrue);

      // Assigning `environment` syncs all mutable scalar fields back.
      engine.environment = const SketchEnvironment().withSize(
        const Size(640, 480),
      );
      expect(engine.width, 640.0);
      expect(engine.height, 480.0);
      expect(engine.frameCount, 0);
      expect(engine.mouseX, 0.0);
    });
  });
}
