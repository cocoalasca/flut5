import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' hide Colors;

/// Provides vector creation for the Flut5 Engine.
mixin Flut5VectorMixin {
  /// Creates a new [Flut5Vector]. All components default to 0.
  Flut5Vector createVector([double x = 0.0, double y = 0.0, double z = 0.0]) {
    return Flut5Vector(x, y, z);
  }
}

/// A 3D vector for the Flut5 Engine, extending [Vector3].
///
/// All mutation methods return `this` for chaining:
/// ```dart
/// v.add(other).mult(2).limit(5);
/// ```
final class Flut5Vector extends Vector3 {
  /// Creates a vector at ([x], [y], [z]).
  Flut5Vector(double x, double y, [double z = 0.0]) : super.zero() {
    setValues(x, y, z);
  }

  /// Creates a zero vector.
  Flut5Vector.zero() : super.zero();

  // ── Magnitude ───────────────────────────────────────────────────────────

  /// Returns the magnitude (length).
  double mag() => length;

  /// Returns the squared magnitude. Faster than [mag] for comparisons.
  double magSq() => length2;

  /// Sets the magnitude to [len] in-place.
  Flut5Vector setMag(double len) {
    if (length == 0.0) return this;
    length = len;
    return this;
  }

  /// Clamps the magnitude to [max] in-place.
  Flut5Vector limit(double max) {
    if (length2 > max * max) {
      normalize();
      scale(max);
    }
    return this;
  }

  // ── Arithmetic (in-place, chainable) ──────────────────────────────────

  /// Adds [other] in-place.
  @override
  Flut5Vector add(Vector3 other) {
    super.add(other);
    return this;
  }

  /// Subtracts [other] in-place.
  @override
  Flut5Vector sub(Vector3 other) {
    super.sub(other);
    return this;
  }

  /// Multiplies by [scalar] in-place.
  Flut5Vector mult(double scalar) {
    scale(scalar);
    return this;
  }

  /// Divides by [scalar] in-place. No-op if [scalar] is zero.
  Flut5Vector div(double scalar) {
    if (scalar == 0) return this;
    scale(1.0 / scalar);
    return this;
  }

  // ── Products ──────────────────────────────────────────────────────────

  /// Returns the dot product with [other].
  @override
  double dot(Vector3 other) => super.dot(other);

  /// Returns the cross product with [other] as a new [Flut5Vector].
  Flut5Vector crossProduct(Vector3 other) {
    final result = super.cross(other);
    return Flut5Vector(result.x, result.y, result.z);
  }

  // ── Geometry ──────────────────────────────────────────────────────────

  /// Returns the Euclidean distance to [other].
  double dist(Vector3 other) => distanceTo(other);

  /// Returns the 2D heading angle in radians.
  double heading() => math.atan2(y, x);

  /// Rotates this 2D vector by [angle] radians in-place.
  Flut5Vector rotate2D(double angle) {
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    final nx = x * cosA - y * sinA;
    final ny = x * sinA + y * cosA;
    x = nx;
    y = ny;
    return this;
  }

  /// Linearly interpolates toward [other] by [t] (0–1) in-place.
  Flut5Vector lerp(Vector3 other, double t) {
    x += (other.x - x) * t;
    y += (other.y - y) * t;
    z += (other.z - z) * t;
    return this;
  }

  /// Normalises to unit length in-place. No-op if zero-length.
  Flut5Vector normalizeVec() {
    if (length == 0.0) return this;
    normalize();
    return this;
  }

  // ── Copying & Factory ─────────────────────────────────────────────────

  /// Returns an exact copy of this vector.
  Flut5Vector copy() => Flut5Vector(x, y, z);

  /// Creates a unit vector from a random 2D angle.
  static Flut5Vector random2D() {
    final angle = math.Random().nextDouble() * math.pi * 2;
    return Flut5Vector(math.cos(angle), math.sin(angle));
  }

  /// Creates a new [Flut5Vector]. Defaults to zero.
  static Flut5Vector createVector([double x = 0.0, double y = 0.0, double z = 0.0]) {
    return Flut5Vector(x, y, z);
  }

  /// Creates a unit vector from a random 3D direction.
  static Flut5Vector random3D() {
    final rng = math.Random();
    final angle = rng.nextDouble() * math.pi * 2;
    final vz = rng.nextDouble() * 2 - 1;
    final vzBase = math.sqrt(1 - vz * vz);
    return Flut5Vector(vzBase * math.cos(angle), vzBase * math.sin(angle), vz);
  }

  /// Creates a vector from an [angle] (radians) with optional [length]. 2D only.
  static Flut5Vector fromAngle(double angle, [double length = 1.0]) {
    return Flut5Vector(length * math.cos(angle), length * math.sin(angle));
  }

  // ── Static helpers ────────────────────────────────────────────────────

  /// Returns a new vector: [a] + [b].
  static Flut5Vector addVectors(Vector3 a, Vector3 b) {
    return Flut5Vector(a.x + b.x, a.y + b.y, a.z + b.z);
  }

  /// Returns a new vector: [a] - [b].
  static Flut5Vector subVectors(Vector3 a, Vector3 b) {
    return Flut5Vector(a.x - b.x, a.y - b.y, a.z - b.z);
  }


  @override
  String toString() => 'Flut5Vector($x, $y, $z)';
}
