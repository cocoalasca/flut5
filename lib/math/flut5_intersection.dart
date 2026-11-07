import 'flut5_vector.dart';

/// Slack allowed on each segment's 0‥1 parameter range, so a hit that lands
/// exactly on a shared endpoint (two walls meeting at a corner) is not lost
/// to floating-point rounding and a ray cannot slip through the seam.
const double _parameterTolerance = 1e-9;

/// Provides 2-D line-segment and ray intersection tests for the Flut5 Engine.
///
/// ## Coordinate space
///
/// Coordinates are read in the current drawing space — the same space
/// `line()` draws in. Inside `push()` + `translate()` / `rotate()` /
/// `scale()` the hit point therefore comes back relative to that scope's
/// origin; with no transform active it is in window pixels. Transforms keep
/// lines crossing at the same spot, so the result can be drawn straight back
/// in the same scope:
///
/// ```dart
/// push();
/// translate(width / 2, height / 2);
/// final hit = lineLineIntersection(-100, 0, 100, 0, 0, -100, 0, 100);
/// if (hit != null) circle(hit.x, hit.y, 8); // drawn at the centre
/// pop();
/// ```
///
/// `mouseX` / `mouseY` are always window pixels, so subtract a scope's
/// translation before mixing them with coordinates drawn inside it.
///
/// Both methods are 2-D: any `z` component is ignored and the returned
/// vector has `z == 0`.
mixin Flut5Intersection {
  /// Returns where segment ([x1], [y1])→([x2], [y2]) crosses segment
  /// ([x3], [y3])→([x4], [y4]), or `null` if they don't touch.
  ///
  /// Both are finite segments, endpoints included — the same lines
  /// `line(x1, y1, x2, y2)` would draw.
  ///
  /// ```dart
  /// final hit = lineLineIntersection(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2);
  /// if (hit != null) circle(hit.x, hit.y, 8);
  /// ```
  ///
  /// Parallel segments return `null`, including collinear ones that
  /// overlap (they share a whole stretch, not a single point), as does a
  /// zero-length segment. See [Flut5Intersection] for the coordinate space.
  Flut5Vector? lineLineIntersection(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    double x4,
    double y4,
  ) => _intersect(
    firstX: x1,
    firstY: y1,
    firstDeltaX: x2 - x1,
    firstDeltaY: y2 - y1,
    firstIsRay: false,
    secondX: x3,
    secondY: y3,
    secondDeltaX: x4 - x3,
    secondDeltaY: y4 - y3,
  );

  /// Casts a ray from ([rayX], [rayY]) along [rayDirection] and returns
  /// where it hits the wall segment ([wallX1], [wallY1])→([wallX2],
  /// [wallY2]), or `null` if it misses.
  ///
  /// The ray starts at its origin and runs forever in one direction, so a
  /// wall behind the origin is a miss. [rayDirection] only sets the heading —
  /// its length doesn't matter and it need not be normalized. A zero
  /// direction, a zero-length wall, or a ray running parallel to the wall
  /// (even along it) returns `null`.
  ///
  /// A typical raycaster keeps the closest hit across all walls:
  ///
  /// ```dart
  /// final direction = Flut5Vector(cos(angle), sin(angle));
  /// Flut5Vector? closest;
  /// var closestDistSq = double.infinity;
  /// for (final w in walls) {
  ///   final hit = rayLineIntersection(w.x1, w.y1, w.x2, w.y2, ox, oy, direction);
  ///   if (hit == null) continue;
  ///   final d = distSq(ox, oy, hit.x, hit.y);
  ///   if (d < closestDistSq) {
  ///     closestDistSq = d;
  ///     closest = hit;
  ///   }
  /// }
  /// if (closest != null) line(ox, oy, closest.x, closest.y);
  /// ```
  ///
  /// See [Flut5Intersection] for the coordinate space.
  Flut5Vector? rayLineIntersection(
    double wallX1,
    double wallY1,
    double wallX2,
    double wallY2,
    double rayX,
    double rayY,
    Flut5Vector rayDirection,
  ) => _intersect(
    firstX: rayX,
    firstY: rayY,
    firstDeltaX: rayDirection.x,
    firstDeltaY: rayDirection.y,
    firstIsRay: true,
    secondX: wallX1,
    secondY: wallY1,
    secondDeltaX: wallX2 - wallX1,
    secondDeltaY: wallY2 - wallY1,
  );

  /// Intersects `first + t·firstDelta` with `second + u·secondDelta`.
  ///
  /// `u` must lie in 0‥1 (the second line is always a segment); `t` must lie
  /// in 0‥1 for a segment, or just be ≥ 0 when [firstIsRay].
  static Flut5Vector? _intersect({
    required double firstX,
    required double firstY,
    required double firstDeltaX,
    required double firstDeltaY,
    required bool firstIsRay,
    required double secondX,
    required double secondY,
    required double secondDeltaX,
    required double secondDeltaY,
  }) {
    // 2-D cross product of the two directions: zero when they are parallel
    // (or either is zero-length), where no single crossing point exists.
    final denominator = firstDeltaX * secondDeltaY - firstDeltaY * secondDeltaX;
    if (denominator == 0) return null;

    final startGapX = secondX - firstX;
    final startGapY = secondY - firstY;
    final firstParameter =
        (startGapX * secondDeltaY - startGapY * secondDeltaX) / denominator;
    final secondParameter =
        (startGapX * firstDeltaY - startGapY * firstDeltaX) / denominator;

    if (firstParameter < -_parameterTolerance) return null;
    if (!firstIsRay && firstParameter > 1 + _parameterTolerance) return null;
    if (secondParameter < -_parameterTolerance ||
        secondParameter > 1 + _parameterTolerance) {
      return null;
    }

    return Flut5Vector(
      firstX + firstParameter * firstDeltaX,
      firstY + firstParameter * firstDeltaY,
    );
  }
}
