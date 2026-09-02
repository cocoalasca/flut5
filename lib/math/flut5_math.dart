import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' show Vector3;

/// A mixin that provides mathematical utilities for the Flut5 Engine.
mixin Flut5Math {
  /// Re-maps a number from one range to another.
  ///
  /// Takes a [value] between [start1] and [stop1], and maps it to
  /// an equivalent value between [start2] and [stop2].
  ///
  /// Useful for proportional scaling.
  double map(
    double value,
    double start1,
    double stop1,
    double start2,
    double stop2,
  ) {
    return (value - start1) / (stop1 - start1) * (stop2 - start2) + start2;
  }

  /// Linearly interpolates between [start] and [stop] by [amt] (0.0–1.0).
  double lerp(double start, double stop, double amt) {
    return start + (stop - start) * amt;
  }

  /// Returns the Euclidean distance between two points.
  ///
  /// Takes either form, mirroring p5:
  ///
  /// ```dart
  /// dist(x1, y1, x2, y2);   // two 2-D points, as numbers
  /// dist(v1, v2);           // two vectors — 3-D, z included
  /// ```
  ///
  /// ```dart
  /// if (dist(mouseX, mouseY, cx, cy) < radius) { /* inside */ }
  /// ```
  ///
  /// The vector form measures in 3-D, matching `Flut5Vector.dist`; the number
  /// form is flat by construction. Because the two shapes cannot be told
  /// apart at compile time, the first two arguments are typed [Object] and
  /// checked on the way in — anything that is neither four numbers nor two
  /// [Vector3]s throws an [ArgumentError].
  ///
  /// Comparing distances is cheaper through [distSq], which skips the square
  /// root.
  double dist(Object a, Object b, [num? x2, num? y2]) {
    if (a is Vector3 && b is Vector3) {
      if (x2 != null || y2 != null) _badDistArgs('dist', a, b, x2, y2);
      return a.distanceTo(b);
    }
    if (a is num && b is num && x2 != null && y2 != null) {
      final dx = x2 - a;
      final dy = y2 - b;
      return math.sqrt(dx * dx + dy * dy);
    }
    _badDistArgs('dist', a, b, x2, y2);
  }

  /// Returns the *squared* distance between two points.
  ///
  /// Takes the same two forms as [dist] and orders results identically, but
  /// skips the square root — so it is the one to reach for in per-frame
  /// comparisons. Square the threshold rather than rooting the distance:
  ///
  /// ```dart
  /// if (distSq(mouseX, mouseY, cx, cy) < radius * radius) { /* inside */ }
  /// ```
  double distSq(Object a, Object b, [num? x2, num? y2]) {
    if (a is Vector3 && b is Vector3) {
      if (x2 != null || y2 != null) _badDistArgs('distSq', a, b, x2, y2);
      return a.distanceToSquared(b);
    }
    if (a is num && b is num && x2 != null && y2 != null) {
      final dx = (x2 - a).toDouble();
      final dy = (y2 - b).toDouble();
      return dx * dx + dy * dy;
    }
    _badDistArgs('distSq', a, b, x2, y2);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ── Random ────────────────────────────────────────────────────────────
  // ═══════════════════════════════════════════════════════════════════════

  math.Random? _rng;
  double? _gaussianSpare;

  /// The active generator, created unseeded on first use.
  math.Random get _random => _rng ??= math.Random();

  /// Returns a random floating-point number.
  ///
  /// * `random()`         → `[0, 1)`
  /// * `random(max)`      → `[0, max)`
  /// * `random(min, max)` → `[min, max)`
  ///
  /// Use [randomSeed] for a reproducible sequence.
  double random([num? min, num? max]) {
    if (min == null) return _random.nextDouble();
    if (max == null) return _random.nextDouble() * min;
    return min.toDouble() + _random.nextDouble() * (max - min);
  }

  /// Returns a random element from [items].
  ///
  /// Throws an [ArgumentError] if [items] is empty.
  T randomChoice<T>(List<T> items) {
    if (items.isEmpty) {
      throw ArgumentError.value(items, 'items', 'must not be empty');
    }
    return items[_random.nextInt(items.length)];
  }

  /// Returns a random number from a Gaussian (normal) distribution with the
  /// given [mean] and standard deviation [sd].
  ///
  /// About 68% of results fall within one [sd] of [mean], and 95% within two.
  double randomGaussian([double mean = 0.0, double sd = 1.0]) {
    // Marsaglia polar method — generates two values per pass, so the unused
    // one is cached for the next call.
    final spare = _gaussianSpare;
    if (spare != null) {
      _gaussianSpare = null;
      return mean + spare * sd;
    }

    double u, v, s;
    do {
      u = _random.nextDouble() * 2 - 1;
      v = _random.nextDouble() * 2 - 1;
      s = u * u + v * v;
    } while (s >= 1 || s == 0);

    final mul = math.sqrt(-2 * math.log(s) / s);
    _gaussianSpare = v * mul;
    return mean + u * mul * sd;
  }

  /// Seeds the random generator so [random], [randomChoice], and
  /// [randomGaussian] produce a reproducible sequence.
  void randomSeed(int seed) {
    _rng = math.Random(seed);
    _gaussianSpare = null;
  }

  /// Resets the random state so the next call generates a fresh, unseeded
  /// sequence.
  void resetRandom() {
    _rng = null;
    _gaussianSpare = null;
  }
}

/// Reports a call to [Flut5Math.dist] / [Flut5Math.distSq] that matched
/// neither accepted shape. Returns [Never], so callers need no fallthrough.
Never _badDistArgs(String name, Object a, Object b, num? x2, num? y2) {
  final got = [a, b, ?x2, ?y2].join(', ');
  throw ArgumentError(
    '$name takes either four numbers or two vectors:\n'
    '  $name(x1, y1, x2, y2)  — two 2-D points\n'
    '  $name(v1, v2)          — two vectors, measured in 3-D\n'
    'Got $name($got).',
  );
}
