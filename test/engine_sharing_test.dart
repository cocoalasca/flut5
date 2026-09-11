import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

class _RootSketch extends Flut5Sketch;

class _Helper({super.flut5}) extends Flut5;

class _EagerFieldSketch extends Flut5Sketch {
  // Non-late field initializer: runs BEFORE the sketch's engine exists.
  final _Helper eager = _Helper();
  late final _Helper lazy = _Helper();
}

void main() {
  setUp(() {
    Flut5.instanceMode = false;
    Flut5Engine.current = null;
  });

  group('global mode engine sharing', () {
    test('root sketch registers its engine as Flut5Engine.current', () {
      final sketch = _RootSketch();
      expect(Flut5Engine.current, same(sketch.flut5));
    });

    test('helper without explicit engine adopts the current one', () {
      final sketch = _RootSketch();
      final helper = _Helper();
      expect(helper.flut5, same(sketch.flut5));
    });

    test('explicit engine wins over the shared one', () {
      _RootSketch();
      final own = Flut5Engine();
      final helper = _Helper(flut5: own);
      expect(helper.flut5, same(own));
    });

    test('helper with no sketch running falls back to a fresh engine '
        'and never registers it', () {
      final helper = _Helper();
      expect(helper.flut5, isNotNull);
      expect(Flut5Engine.current, isNull);
    });

    test('root sketches never adopt — each owns a fresh engine', () {
      final a = _RootSketch();
      final b = _RootSketch();
      expect(a.flut5, isNot(same(b.flut5)));
      expect(Flut5Engine.current, same(b.flut5));
    });

    test('disposing an adopting helper leaves the shared engine intact', () {
      final sketch = _RootSketch();
      final helper = _Helper();
      helper.dispose();
      expect(Flut5Engine.current, same(sketch.flut5));
      // Shared engine still usable after the helper is gone.
      sketch.flut5.fill(const Color(0xFF112233));
      expect(sketch.flut5.fillColor, const Color(0xFF112233));
    });

    test('disposing the owning root sketch clears Flut5Engine.current', () {
      final sketch = _RootSketch();
      sketch.dispose();
      expect(Flut5Engine.current, isNull);
    });

    test('disposing an older root sketch does not clear a newer current', () {
      final a = _RootSketch();
      final b = _RootSketch();
      a.dispose();
      expect(Flut5Engine.current, same(b.flut5));
    });

    test('eager field initializers run too early and get standalone engines; '
        'late ones adopt', () {
      final sketch = _EagerFieldSketch();
      expect(sketch.eager.flut5, isNot(same(sketch.flut5)));
      // `late` defers construction until first access, when the sketch's
      // engine is already registered.
      expect(sketch.lazy.flut5, same(sketch.flut5));
    });
  });

  group('instance mode', () {
    test('helper without explicit engine throws even while a sketch runs', () {
      Flut5.instanceMode = true;
      _RootSketch();
      expect(() => _Helper(), throwsStateError);
    });

    test('helper with explicit engine works', () {
      Flut5.instanceMode = true;
      final sketch = _RootSketch();
      final helper = _Helper(flut5: sketch.flut5);
      expect(helper.flut5, same(sketch.flut5));
    });

    test('root sketches keep creating their own engines', () {
      Flut5.instanceMode = true;
      final a = _RootSketch();
      final b = _RootSketch();
      expect(a.flut5, isNot(same(b.flut5)));
    });
  });
}
