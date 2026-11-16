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

  /// Returns Euler's number *e* (2.71828...) raised to the power [n].
  ///
  /// ```dart
  /// exp(0);  // 1.0
  /// exp(1);  // 2.718281828459045
  /// exp(-1); // 0.36787944117144233
  /// ```
  ///
  /// It grows quickly: `exp(710)` is already too large for a double and
  /// returns `double.infinity`.
  double exp(num n) => math.exp(n);

  /// Normalizes [values] into probabilities that sum to 1, using the softmax
  /// function: each entry becomes `exp(x / temperature)`, divided by the sum
  /// of all of them.
  ///
  /// The result has the same length and order as [values], and a larger
  /// input always gets a larger share.
  ///
  /// ```dart
  /// softmax([1, 2, 3]);      // [0.090, 0.245, 0.665]
  /// softmax([1, 2, 3], 0.5); // [0.016, 0.117, 0.867] (sharper)
  /// softmax([1, 2, 3], 5);   // [0.269, 0.329, 0.402] (flatter)
  /// ```
  ///
  /// [temperature] sets how strongly the largest input wins. The default of
  /// 1 is the standard softmax. Below 1 the largest input takes more of the
  /// total, and at 0 it takes all of it (inputs tied for largest split it
  /// evenly). Above 1 the shares even out, approaching a uniform split as
  /// [temperature] grows. Throws an [ArgumentError] if [temperature] is
  /// negative or NaN.
  ///
  /// Only the differences between inputs matter. Adding the same constant to
  /// every entry leaves the result unchanged, and that is what keeps large
  /// inputs safe: the maximum is subtracted before exponentiating, so
  /// `softmax([1000, 1001])` works instead of overflowing.
  ///
  /// An empty list returns an empty list. An entry of `-double.infinity`
  /// gets probability 0, which is useful for ruling an option out, as long
  /// as some entry is larger. Entries of `double.infinity` split the whole
  /// total between them. `double.nan` anywhere makes every result `NaN`.
  List<double> softmax(List<num> values, [num temperature = 1]) {
    if (temperature.isNaN || temperature < 0) {
      throw ArgumentError.value(
        temperature,
        'temperature',
        'must be 0 or greater',
      );
    }
    if (values.isEmpty) return <double>[];

    final largest = _largestOf(values);
    // At temperature 0, or with an infinite entry, softmax is at its limit:
    // the largest entries share everything and the rest get nothing.
    final winnerTakesAll = temperature == 0 || largest == double.infinity;

    final probabilities = List<double>.filled(values.length, 0);
    var total = 0.0;
    for (var index = 0; index < values.length; index++) {
      final value = values[index];
      final weight = winnerTakesAll
          ? (value == largest ? 1.0 : 0.0)
          : exp((value - largest) / temperature);
      probabilities[index] = weight;
      total += weight;
    }
    for (var index = 0; index < probabilities.length; index++) {
      probabilities[index] /= total;
    }
    return probabilities;
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

  /// Picks a random index from [weights], where each entry is the weight of
  /// its index: the larger the weight, the more often that index comes back.
  ///
  /// ```dart
  /// randomWeightedIndex([1, 3]);    // 1 three times as often as 0
  /// randomWeightedIndex([5, 0, 5]); // 0 or 2, never 1
  ///
  /// // Pick an option by score, letting softmax turn scores into weights.
  /// final pick = options[randomWeightedIndex(softmax(scores, 0.7))];
  /// ```
  ///
  /// The weights don't need to sum to 1: index `i` comes back with
  /// probability `weights[i] / sum(weights)`, so a weight of 0 is never
  /// picked. It draws a random number between 0 and the sum of the weights,
  /// then subtracts the weights in order until the number drops below 0; the
  /// index whose weight does that is the pick.
  ///
  /// Uses the same generator as [random], so [randomSeed] makes the picks
  /// reproducible.
  ///
  /// Throws an [ArgumentError] if [weights] is empty, has a negative, NaN,
  /// or infinite weight, or adds up to 0.
  int randomWeightedIndex(List<num> weights) {
    var remaining = random(_totalWeightOf(weights));
    for (var index = 0; index < weights.length; index++) {
      remaining -= weights[index];
      if (remaining < 0) return index;
    }
    // Rounding can leave a sliver above 0 after the last subtraction. It
    // belongs to the last index that can be picked.
    return weights.lastIndexWhere((weight) => weight > 0);
  }

  /// Picks a random index from [values], favouring larger values: the
  /// values go through [softmax] with [temperature] and the result is
  /// picked from with [randomWeightedIndex].
  ///
  /// ```dart
  /// softmaxWeightedSelection([1, 2, 3]);      // usually 2, sometimes 0 or 1
  /// softmaxWeightedSelection([1, 2, 3], 0.2); // almost always 2
  /// softmaxWeightedSelection([1, 2, 3], 0);   // always 2
  /// softmaxWeightedSelection([1, 2, 3], 10);  // close to uniform
  /// ```
  ///
  /// Unlike [randomWeightedIndex], [values] can be any scores, including
  /// negative ones. With the default [temperature] of 1, index `i` comes back
  /// with probability `softmax(values)[i]`. See [softmax] for how
  /// [temperature] sharpens or flattens that.
  ///
  /// Follows [randomSeed]. Throws an [ArgumentError] if [values] is empty or
  /// contains NaN, or if [temperature] is negative or NaN.
  int softmaxWeightedSelection(List<num> values, [num temperature = 1]) =>
      randomWeightedIndex(softmax(values, temperature));

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

  /// Seeds the random generator so [random], [randomChoice],
  /// [randomWeightedIndex], and [randomGaussian] produce a reproducible
  /// sequence.
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

/// Returns the largest entry of a non-empty [values], or NaN if any entry is
/// NaN.
///
/// A loop rather than `values.reduce(math.max)`: a `List<double>` passed in
/// as `List<num>` rejects reduce's `(num, num)` callback at runtime.
num _largestOf(List<num> values) {
  var largest = values.first;
  for (final value in values) {
    if (value > largest || value.isNaN) largest = value;
  }
  return largest;
}

/// Returns the sum of [weights] for [Flut5Math.randomWeightedIndex], after
/// checking there is something to pick from.
double _totalWeightOf(List<num> weights) {
  if (weights.isEmpty) {
    throw ArgumentError.value(weights, 'weights', 'must not be empty');
  }
  var total = 0.0;
  for (var index = 0; index < weights.length; index++) {
    final weight = weights[index];
    if (weight.isNaN || weight.isInfinite || weight < 0) {
      throw ArgumentError(
        'randomWeightedIndex: the weight at index $index is $weight. '
        'Weights must be finite and 0 or greater.',
      );
    }
    total += weight;
  }
  if (total == 0) {
    throw ArgumentError(
      'randomWeightedIndex: every weight is 0, so there is nothing to pick. '
      'Give at least one entry a weight above 0.',
    );
  }
  if (total.isInfinite) {
    throw ArgumentError(
      'randomWeightedIndex: the weights add up to more than a double can '
      'hold. Scale them down; only their ratios matter.',
    );
  }
  return total;
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
