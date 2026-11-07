import 'flut5_line_segment.dart';
import 'flut5_vector.dart';

/// Slack allowed on each segment's 0‥1 parameter range, so a hit that lands
/// exactly on a shared endpoint (two walls meeting at a corner) is not lost
/// to floating-point rounding and a ray cannot slip through the seam.
const double _parameterTolerance = 1e-9;

/// Provides 2-D line-segment and ray intersection tests for the Flut5 Engine,
/// including [castRay] for raycasting against a list of walls.
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
/// All of these are 2-D: any `z` component is ignored and the returned
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
  ) {
    final deltaX = x2 - x1;
    final deltaY = y2 - y1;
    final distanceAlongFirst = _crossingParameter(
      firstX: x1,
      firstY: y1,
      firstDeltaX: deltaX,
      firstDeltaY: deltaY,
      firstIsRay: false,
      secondX: x3,
      secondY: y3,
      secondDeltaX: x4 - x3,
      secondDeltaY: y4 - y3,
    );
    if (distanceAlongFirst.isInfinite) return null;
    return Flut5Vector(
      x1 + distanceAlongFirst * deltaX,
      y1 + distanceAlongFirst * deltaY,
    );
  }

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
  ) {
    final distanceAlongRay = _crossingParameter(
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
    if (distanceAlongRay.isInfinite) return null;
    return Flut5Vector(
      rayX + distanceAlongRay * rayDirection.x,
      rayY + distanceAlongRay * rayDirection.y,
    );
  }

  /// Casts a ray from ([rayX], [rayY]) along [rayDirection] and returns the
  /// closest point where it hits any of [walls], or `null` if it hits none.
  ///
  /// Each wall is tested the same way as [rayLineIntersection] — walls
  /// behind the origin, parallel to the ray, or zero-length are skipped — and
  /// the hit nearest the origin wins. Only that one hit allocates a vector,
  /// so casting hundreds of rays per frame stays cheap.
  ///
  /// ```dart
  /// final walls = [
  ///   Flut5LineSegment(300, 100, 300, 300),
  ///   Flut5LineSegment(100, 350, 400, 350),
  /// ];
  ///
  /// // in draw():
  /// for (var angle = 0.0; angle < 360; angle += 1) {
  ///   final direction = Flut5Vector(cos(angle), sin(angle));
  ///   final hit = castRay(mouseX, mouseY, direction, walls);
  ///   if (hit != null) line(mouseX, mouseY, hit.x, hit.y);
  /// }
  /// ```
  ///
  /// The distance to the hit is `dist(rayX, rayY, hit.x, hit.y)`. See
  /// [Flut5Intersection] for the coordinate space.
  Flut5Vector? castRay(
    double rayX,
    double rayY,
    Flut5Vector rayDirection,
    Iterable<Flut5LineSegment> walls,
  ) {
    final directionX = rayDirection.x;
    final directionY = rayDirection.y;
    // Every wall is measured along the same direction vector, so the
    // smallest parameter is also the smallest distance — no square roots.
    var closestDistanceAlongRay = double.infinity;
    for (final wall in walls) {
      final distanceAlongRay = _crossingParameter(
        firstX: rayX,
        firstY: rayY,
        firstDeltaX: directionX,
        firstDeltaY: directionY,
        firstIsRay: true,
        secondX: wall.start.x,
        secondY: wall.start.y,
        secondDeltaX: wall.end.x - wall.start.x,
        secondDeltaY: wall.end.y - wall.start.y,
      );
      if (distanceAlongRay < closestDistanceAlongRay) {
        closestDistanceAlongRay = distanceAlongRay;
      }
    }
    if (closestDistanceAlongRay.isInfinite) return null;
    return Flut5Vector(
      rayX + closestDistanceAlongRay * directionX,
      rayY + closestDistanceAlongRay * directionY,
    );
  }

  /// Finds where `first + t·firstDelta` crosses `second + u·secondDelta` and
  /// returns `t` — how many `firstDelta`s along the first line the crossing
  /// is — or [double.infinity] when they don't cross.
  ///
  /// `u` must lie in 0‥1 (the second line is always a segment); `t` must lie
  /// in 0‥1 for a segment, or just be ≥ 0 when [firstIsRay]. Returning a plain
  /// number (not a vector) lets [castRay] compare walls without allocating.
  static double _crossingParameter({
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
    const noCrossing = double.infinity;

    // 2-D cross product of the two directions: zero when they are parallel
    // (or either is zero-length), where no single crossing point exists.
    final denominator = firstDeltaX * secondDeltaY - firstDeltaY * secondDeltaX;
    if (denominator == 0) return noCrossing;

    final startGapX = secondX - firstX;
    final startGapY = secondY - firstY;
    final firstParameter =
        (startGapX * secondDeltaY - startGapY * secondDeltaX) / denominator;
    final secondParameter =
        (startGapX * firstDeltaY - startGapY * firstDeltaX) / denominator;

    if (firstParameter < -_parameterTolerance) return noCrossing;
    if (!firstIsRay && firstParameter > 1 + _parameterTolerance) {
      return noCrossing;
    }
    if (secondParameter < -_parameterTolerance ||
        secondParameter > 1 + _parameterTolerance) {
      return noCrossing;
    }
    return firstParameter;
  }
}
