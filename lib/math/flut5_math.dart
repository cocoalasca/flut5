import 'dart:math' as math;

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
