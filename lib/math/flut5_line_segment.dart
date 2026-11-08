import 'flut5_vector.dart';

/// A straight line between two points — a wall for `castRay` and
/// `castRayClosest`.
///
/// Built from four numbers, the same way `line(x1, y1, x2, y2)` takes them,
/// and stores its ends as [start] and [end] vectors so they can be moved
/// with vector math:
///
/// ```dart
/// final wall = Flut5LineSegment(100, 50, 100, 250);
/// wall.start.add(Flut5Vector(5, 0)); // slide the top end right
/// line(wall.start.x, wall.start.y, wall.end.x, wall.end.y);
/// ```
///
/// Coordinates are in whatever drawing space the wall is used in — see
/// `Flut5Intersection`. Ray tests are 2-D, so `z` is ignored.
final class Flut5LineSegment {
  /// Creates a segment from ([x1], [y1]) to ([x2], [y2]).
  Flut5LineSegment(double x1, double y1, double x2, double y2)
    : start = Flut5Vector(x1, y1),
      end = Flut5Vector(x2, y2);

  /// The first end of the segment.
  Flut5Vector start;

  /// The second end of the segment.
  Flut5Vector end;

  @override
  String toString() =>
      'Flut5LineSegment((${start.x}, ${start.y}) → (${end.x}, ${end.y}))';
}
