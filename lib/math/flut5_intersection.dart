import 'dart:typed_data';

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

  /// Casts a ray from ([rayX], [rayY]) along [rayDirection] and returns
  /// every point where it hits one of [walls], sorted closest-first. The list
  /// is empty when it hits nothing.
  ///
  /// Each wall is tested the same way as [rayLineIntersection] — walls
  /// behind the origin, parallel to the ray, or zero-length are skipped. The
  /// list has one point per wall hit, so a ray passing exactly through a
  /// corner where two walls meet gets the same point twice.
  ///
  /// Which hits matter is up to the sketch — a bullet that pierces two walls
  /// would use the first two:
  ///
  /// ```dart
  /// final hits = castRay(x, y, direction, walls);
  /// for (final hit in hits.take(2)) circle(hit.x, hit.y, 6);
  /// ```
  ///
  /// Every hit costs one vector, so when only the first wall matters (a
  /// classic raycaster) use [castRayClosest], which allocates just one. The
  /// distance to a hit is `dist(rayX, rayY, hit.x, hit.y)`. See
  /// [Flut5Intersection] for the coordinate space.
  List<Flut5Vector> castRay(
    double rayX,
    double rayY,
    Flut5Vector rayDirection,
    Iterable<Flut5LineSegment> walls,
  ) {
    final directionX = rayDirection.x;
    final directionY = rayDirection.y;
    var hitCount = 0;
    for (final wall in walls) {
      final distanceAlongRay = _distanceAlongRayToWall(
        rayX,
        rayY,
        directionX,
        directionY,
        wall,
      );
      if (distanceAlongRay.isFinite) {
        _insertSortedHitDistance(distanceAlongRay, hitCount);
        hitCount++;
      }
    }
    return [
      for (var hitIndex = 0; hitIndex < hitCount; hitIndex++)
        _pointAlongRay(
          rayX,
          rayY,
          directionX,
          directionY,
          _hitDistances[hitIndex],
        ),
    ];
  }

  /// Casts a ray from ([rayX], [rayY]) along [rayDirection] and returns the
  /// closest point where it hits one of [walls], or `null` if it hits none —
  /// the first wall the ray reaches, which hides every wall behind it.
  ///
  /// Gives the same point as `castRay(...).first`, but only tracks the
  /// closest distance and allocates a single vector, so it's the one to use
  /// for casting hundreds of rays per frame:
  ///
  /// ```dart
  /// final walls = [
  ///   Flut5LineSegment(300, 100, 300, 300),
  ///   Flut5LineSegment(100, 350, 400, 350),
  /// ];
  ///
  /// // in draw():
  /// for (var degree = 0.0; degree < 360; degree += 1) {
  ///   final angle = radians(degree);
  ///   final direction = Flut5Vector(cos(angle), sin(angle));
  ///   final hit = castRayClosest(mouseX, mouseY, direction, walls);
  ///   if (hit != null) line(mouseX, mouseY, hit.x, hit.y);
  /// }
  /// ```
  ///
  /// Walls are tested the same way as [castRay]. See [Flut5Intersection] for
  /// the coordinate space.
  Flut5Vector? castRayClosest(
    double rayX,
    double rayY,
    Flut5Vector rayDirection,
    Iterable<Flut5LineSegment> walls,
  ) {
    final directionX = rayDirection.x;
    final directionY = rayDirection.y;
    var closestDistanceAlongRay = double.infinity;
    for (final wall in walls) {
      final distanceAlongRay = _distanceAlongRayToWall(
        rayX,
        rayY,
        directionX,
        directionY,
        wall,
      );
      if (distanceAlongRay < closestDistanceAlongRay) {
        closestDistanceAlongRay = distanceAlongRay;
      }
    }
    if (closestDistanceAlongRay.isInfinite) return null;
    return _pointAlongRay(
      rayX,
      rayY,
      directionX,
      directionY,
      closestDistanceAlongRay,
    );
  }

  /// How many direction vectors ([directionX], [directionY]) along the ray
  /// [wall] is crossed, or [double.infinity] if the ray misses it. Every wall
  /// is measured in the same unit, so comparing these orders hits by
  /// distance — no square roots. Takes the direction as plain numbers so the
  /// per-wall loop doesn't re-read the vector each time.
  // Inlined (with [_crossingParameter]) because it runs once per wall per
  // ray: without the hint the AOT compiler left the call in and
  // [castRayClosest] measured ~40% slower (360 rays × 10–50 walls).
  @pragma('vm:prefer-inline')
  static double _distanceAlongRayToWall(
    double rayX,
    double rayY,
    double directionX,
    double directionY,
    Flut5LineSegment wall,
  ) => _crossingParameter(
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

  /// The point [distanceAlongRay] direction vectors from the ray's origin.
  static Flut5Vector _pointAlongRay(
    double rayX,
    double rayY,
    double directionX,
    double directionY,
    double distanceAlongRay,
  ) => Flut5Vector(
    rayX + distanceAlongRay * directionX,
    rayY + distanceAlongRay * directionY,
  );

  /// Hit distances of the [castRay] in progress, kept sorted as they arrive.
  /// Reused between calls so collecting them doesn't allocate; doubles in
  /// size whenever a ray hits more walls than it holds.
  Float64List _hitDistances = Float64List(16);

  /// Inserts [distanceAlongRay] into the first [hitCount] slots of
  /// [_hitDistances], keeping them in ascending order. Rays hit a handful of
  /// walls, so shifting larger entries up is cheaper than sorting at the end.
  void _insertSortedHitDistance(double distanceAlongRay, int hitCount) {
    if (hitCount == _hitDistances.length) {
      _hitDistances = Float64List(hitCount * 2)..setAll(0, _hitDistances);
    }
    var slot = hitCount;
    while (slot > 0 && _hitDistances[slot - 1] > distanceAlongRay) {
      _hitDistances[slot] = _hitDistances[slot - 1];
      slot--;
    }
    _hitDistances[slot] = distanceAlongRay;
  }

  /// Finds where `first + t·firstDelta` crosses `second + u·secondDelta` and
  /// returns `t` — how many `firstDelta`s along the first line the crossing
  /// is — or [double.infinity] when they don't cross.
  ///
  /// `u` must lie in 0‥1 (the second line is always a segment); `t` must lie
  /// in 0‥1 for a segment, or just be ≥ 0 when [firstIsRay]. Returning a plain
  /// number (not a vector) lets [castRay] and [castRayClosest] compare hits
  /// before allocating any.
  @pragma('vm:prefer-inline')
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
