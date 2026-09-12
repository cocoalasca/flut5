import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flut5/flut5.dart';
import 'package:flut5/text/flut5_expiring_cache.dart';

class _Helper({super.flut5}) extends Flut5;

class _EmptySketch extends Flut5Sketch {
  @override
  void draw() => background(Colors.black);
}

Flut5CachedText _texture(String text) => Flut5TextCache.instance.getOrCreate(
  text: text,
  fontFamily: '',
  fontSize: 12,
  fontWeight: FontWeight.normal,
  fontStyle: FontStyle.normal,
  textLeading: null,
  align: TextAlign.left,
  paintingStyle: 0,
  strokeWidth: 0,
);

Flut5TextLayout _layout() => Flut5TextCache.instance.getOrCreateLayout(
  text: 'AV test',
  fontFamily: '',
  fontSize: 12,
  fontWeight: FontWeight.normal,
  fontStyle: FontStyle.normal,
  letterSpacing: 0,
);

void _measure() {
  final cache = Flut5TextCache.instance;
  cache.measureWidth(
    text: 'measurement only',
    fontFamily: '',
    fontSize: 12,
    fontWeight: FontWeight.normal,
    fontStyle: FontStyle.normal,
  );
  cache.measureLineHeight(
    fontFamily: '',
    fontSize: 12,
    fontWeight: FontWeight.normal,
    fontStyle: FontStyle.normal,
  );
  cache.measureAscentDescent(
    fontFamily: '',
    fontSize: 12,
    fontWeight: FontWeight.normal,
    fontStyle: FontStyle.normal,
  );
  cache.getKernOffset(
    a: 'A',
    b: 'V',
    fontFamily: '',
    fontSize: 12,
    fontWeight: FontWeight.normal,
    fontStyle: FontStyle.normal,
  );
}

void _unusedFrames(int count) {
  for (var i = 0; i < count; i++) {
    Flut5TextCache.instance.finishFrame();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = Flut5TextCache.instance;

  setUp(() {
    cache.clear();
    cache.timeoutFrames = 600;
  });
  tearDown(() {
    cache.clear();
    cache.timeoutFrames = 600;
    Flut5Engine.current = null;
  });

  test('all cache categories expire after exactly 600 unused frames', () {
    final texture = _texture('texture');
    _layout();
    _measure();
    expect(cache.debugEntryCounts.values, everyElement(greaterThan(0)));
    cache.finishFrame(); // Finish the frame that used these entries.
    _unusedFrames(599);
    expect(cache.debugEntryCounts.values, everyElement(greaterThan(0)));
    expect(texture.image.debugDisposed, isFalse);
    _unusedFrames(1);
    expect(cache.debugEntryCounts.values, everyElement(0));
    expect(cache.cacheBytes, 0);
    expect(texture.image.debugDisposed, isTrue);
  });

  test('texture and layout hits refresh their individual lifetimes', () {
    cache.timeoutFrames = 3;
    final hot = _texture('hot');
    final cold = _texture('cold');
    final layout = _layout();
    cache.finishFrame();
    _unusedFrames(2);
    expect(_texture('hot'), same(hot));
    expect(_layout(), same(layout));
    cache.finishFrame();
    expect(cold.image.debugDisposed, isTrue);
    expect(hot.image.debugDisposed, isFalse);
    expect(cache.layoutCacheLength, 1);
    _unusedFrames(2);
    expect(hot.image.debugDisposed, isFalse);
    _unusedFrames(1);
    expect(hot.image.debugDisposed, isTrue);
    expect(cache.layoutCacheLength, 0);
  });

  test('measurement hits refresh age while unused measurements expire', () {
    cache.timeoutFrames = 2;
    _measure();
    cache.finishFrame();
    _unusedFrames(1);
    _measure();
    cache.finishFrame();
    for (final category in [
      'widths',
      'lineHeights',
      'ascentDescent',
      'kerning',
    ]) {
      expect(cache.debugEntryCounts[category], greaterThan(0));
    }
    _unusedFrames(2);
    expect(cache.debugEntryCounts.values, everyElement(0));
  });

  test('measuring a rasterized entry refreshes its texture lifetime', () {
    cache.timeoutFrames = 2;
    final texture = _texture('rasterized');
    cache.finishFrame();
    _unusedFrames(1);
    cache.measureWidth(
      text: 'rasterized',
      fontFamily: '',
      fontSize: 12,
      fontWeight: FontWeight.normal,
      fontStyle: FontStyle.normal,
    );
    cache.finishFrame();
    expect(texture.image.debugDisposed, isFalse);
    _unusedFrames(2);
    expect(texture.image.debugDisposed, isTrue);
  });

  test('forwarder changes shared timeout and rejects invalid values', () {
    final a = _EmptySketch();
    final b = _Helper(flut5: a.flut5);
    expect(a.textCacheTimeout(), 600);
    expect(b.textCacheTimeout(1200), 1200);
    expect(a.flut5.textCacheTimeout(), 1200);
    expect(() => a.textCacheTimeout(0), throwsRangeError);
    expect(() => a.flut5.textCacheTimeout(-1), throwsRangeError);
    expect(a.textCacheTimeout(), 1200);
    b.dispose();
    a.dispose();
  });

  test('timeout changes affect existing entries at next cleanup', () {
    final texture = _texture('older');
    cache.finishFrame();
    _unusedFrames(10);
    cache.timeoutFrames = 2;
    expect(texture.image.debugDisposed, isFalse);
    cache.finishFrame();
    expect(texture.image.debugDisposed, isTrue);
    expect(cache.cacheBytes, 0);
  });

  test('a one-frame timeout retains an entry used every frame', () {
    cache.timeoutFrames = 1;
    final texture = _texture('active');
    for (var i = 0; i < 10; i++) {
      expect(_texture('active'), same(texture));
      cache.finishFrame();
      expect(texture.image.debugDisposed, isFalse);
    }
    cache.finishFrame();
    expect(texture.image.debugDisposed, isTrue);
  });

  test(
    'extending the timeout preserves existing entries for the new lifetime',
    () {
      cache.timeoutFrames = 3;
      final texture = _texture('extended');
      cache.finishFrame();
      _unusedFrames(2);
      cache.timeoutFrames = 6;
      _unusedFrames(3);
      expect(texture.image.debugDisposed, isFalse);
      _unusedFrames(1);
      expect(texture.image.debugDisposed, isTrue);
    },
  );

  test(
    'clear releases images and resets expiration lists without double disposal',
    () {
      cache.timeoutFrames = 1;
      final old = _texture('clear');
      cache.clear();
      expect(old.image.debugDisposed, isTrue);
      final replacement = _texture('clear');
      cache.finishFrame();
      expect(replacement.image.debugDisposed, isFalse);
      cache.finishFrame();
      expect(replacement.image.debugDisposed, isTrue);
      expect(cache.cacheBytes, 0);
    },
  );

  testWidgets(
    'multiple canvases age the cache once per Flutter frame without text',
    (tester) async {
      cache.timeoutFrames = 3;
      final a = _EmptySketch();
      final b = _EmptySketch();
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              SizedBox(width: 100, height: 100, child: Flut5Canvas(sketch: a)),
              SizedBox(width: 100, height: 100, child: Flut5Canvas(sketch: b)),
            ],
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final texture = _texture('no longer drawn');
      await tester.pump(); // Finish its frame of use.
      await tester.pump();
      await tester.pump();
      expect(texture.image.debugDisposed, isFalse);
      await tester.pump();
      expect(texture.image.debugDisposed, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'expiration continues on existing app frames after the last canvas is removed',
    (tester) async {
      cache.timeoutFrames = 2;
      await tester.pumpWidget(
        MaterialApp(home: Flut5Canvas(sketch: _EmptySketch())),
      );
      await tester.pump();
      final texture = _texture('leaving');
      await tester.pumpWidget(const SizedBox());
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(texture.image.debugDisposed, isFalse);
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(texture.image.debugDisposed, isTrue);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  test(
    'ordered expiration handles hits, updates, removal and read-only iteration',
    () {
      var frame = 0;
      final disposed = <int>[];
      final map = Flut5ExpiringCache<String, int>(
        () => frame,
        onExpire: disposed.add,
      );
      map['a'] = 1;
      map['b'] = 2;
      frame = 2;
      expect(map['a'], 1); // Move a behind b without allocating a new entry.
      map['a'] = 3;
      map['temporary'] = 9;
      map.remove('temporary');
      expect(map.entries.length, 2);
      expect(map.values.toList(), containsAll([2, 3]));
      expect(map.containsKey('b'), isTrue);
      frame = 3;
      map.expire(3);
      expect(disposed, [2]);
      frame = 5;
      map.expire(3);
      expect(disposed, [2, 3]);
      expect(map, isEmpty);
    },
  );
}
