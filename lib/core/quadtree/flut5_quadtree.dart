import 'dart:collection';

import 'flut5_quadtree_point.dart';

/// A rectangle of space, `width` × `height` with its top-left corner at
/// `(0, 0)`, that sorts [Flut5QuadtreePoint]s by position so [query] can find
/// the ones inside an area without checking every point.
///
/// Each area holds up to [capacity] points. Adding one more splits it into
/// four equal [children] (see [subdivide]) and moves its points straight
/// down into them, so points only ever live in the smallest areas — the
/// leaves — and an area that has been split holds none itself.
///
/// ```dart
/// final tree = Flut5Quadtree(width, height);
/// for (final p in physicsEngine.particles) {
///   tree.add(Flut5QuadtreePoint(p.x, p.y, p));
/// }
/// final nearMouse = tree.query(mouseX - 50, mouseY - 50, 100, 100);
/// ```
///
/// [T] is the payload type of the points. Leave it out and payloads are
/// `dynamic`, so any data fits.
final class Flut5Quadtree<T>._area(
  /// Left edge of this area, in the root tree's coordinates. `0` for the
  /// tree you create; its [children] are offset inside it.
  final double x,

  /// Top edge of this area, in the root tree's coordinates.
  final double y,

  /// Width of this area.
  final double width,

  /// Height of this area.
  final double height,

  /// How many points an area holds before it splits into four.
  final int capacity,

  /// How many times an area may be split below the root. A full area this
  /// deep can't split again, so [add]ing a point to it throws a [StateError]
  /// instead.
  final int maxDepth,

  /// How many splits deep this area is: `0` for the root.
  final int _depth,
) {
  /// Creates an empty tree covering `0..width` × `0..height`, `1` × `1` by
  /// default. Each area splits into four once it holds more than [capacity]
  /// points, down to [maxDepth] splits below the root.
  factory Flut5Quadtree([
    double width = 1,
    double height = 1,
    int capacity = 4,
    int maxDepth = defaultMaxDepth,
  ]) {
    if (width <= 0) {
      throw ArgumentError.value(width, 'width', 'must be greater than 0');
    }
    if (height <= 0) {
      throw ArgumentError.value(height, 'height', 'must be greater than 0');
    }
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'must be at least 1');
    }
    if (maxDepth < 0) {
      throw ArgumentError.value(maxDepth, 'maxDepth', 'must not be negative');
    }
    return Flut5Quadtree._area(0, 0, width, height, capacity, maxDepth, 0);
  }

  /// The [maxDepth] a tree gets when you don't pass one: deep enough that it
  /// never gets in the way. Each split halves an area, and a `double` reaches
  /// its smallest step after about 1100 halvings from `1`, so any two
  /// different positions — on a canvas of any size you'd use — are in
  /// different areas long before 2048 splits.
  static const int defaultMaxDepth = 2048;

  final double _centerX = x + width / 2;
  final double _centerY = y + height / 2;

  List<Flut5QuadtreePoint<T>> _points = [];

  /// Empty until [subdivide]; then top-left, top-right, bottom-left,
  /// bottom-right (row by row, as [_childContaining] indexes them).
  List<Flut5Quadtree<T>> _children = const [];

  bool get _isSubdivided => _children.isNotEmpty;

  /// The points stored directly in this area. Always empty once the area has
  /// been split — its points live in its [children] then.
  List<Flut5QuadtreePoint<T>> get points => UnmodifiableListView(_points);

  /// The four areas this one split into — top-left, top-right, bottom-left,
  /// bottom-right — or empty if it hasn't split. Walk them to draw the tree:
  ///
  /// ```dart
  /// void drawArea(Flut5Quadtree area) {
  ///   rect(area.x, area.y, area.width, area.height);
  ///   area.children.forEach(drawArea);
  /// }
  /// ```
  List<Flut5Quadtree<T>> get children => UnmodifiableListView(_children);

  /// Files [point] in the smallest area that contains it, splitting areas
  /// that go over [capacity] on the way.
  ///
  /// Returns `false`, and stores nothing, when the point is outside the tree
  /// (`0..width` × `0..height`, edges included).
  ///
  /// Throws a [StateError], and stores nothing, when the point's area is full
  /// and splitting can't make room:
  /// - the area is already [maxDepth] splits deep, or
  /// - every point in it sits at exactly the point's position — no split
  ///   ever separates those, so this throws straight away rather than
  ///   splitting down to [maxDepth] first.
  bool add(Flut5QuadtreePoint<T> point) {
    final isInside =
        point.x >= x &&
        point.x <= x + width &&
        point.y >= y &&
        point.y <= y + height;
    if (!isInside) return false;
    _insert(point);
    return true;
  }

  /// Splits this area into four equal [children] and moves every point it
  /// holds straight into the child that contains it, leaving this area
  /// empty.
  ///
  /// [add] calls this when an area is full, so you rarely need to. Does
  /// nothing if the area has already been split, and throws a [StateError]
  /// if it is already [maxDepth] splits deep.
  void subdivide() {
    if (_isSubdivided) return;
    if (_depth >= maxDepth) {
      throw StateError(
        'Flut5Quadtree: this area is already $_depth splits deep, the '
        'maxDepth of $maxDepth, so it can\'t split again. Pass a larger '
        'maxDepth to the constructor to allow deeper trees.',
      );
    }
    final halfWidth = width / 2;
    final halfHeight = height / 2;
    final childDepth = _depth + 1;
    Flut5Quadtree<T> child(double childX, double childY) =>
        Flut5Quadtree<T>._area(
          childX,
          childY,
          halfWidth,
          halfHeight,
          capacity,
          maxDepth,
          childDepth,
        );
    _children = List.of([
      child(x, y),
      child(_centerX, y),
      child(x, _centerY),
      child(_centerX, _centerY),
    ], growable: false);

    // An area never holds more than [capacity] points, so every child has
    // room for what it gets here and none of these splits again.
    final pointsToMove = _points;
    _points = List.empty();
    for (final point in pointsToMove) {
      _childContaining(point.x, point.y)._points.add(point);
    }
  }

  /// Every point inside the rectangle with its top-left corner at
  /// ([x], [y]) and size [width] × [height], in the tree's coordinates.
  /// Points on the rectangle's edges count as inside. A negative width or
  /// height reaches left or up from ([x], [y]).
  ///
  /// Areas that don't overlap the rectangle are skipped whole, which is what
  /// makes this faster than checking every point.
  List<Flut5QuadtreePoint<T>> query(
    double x,
    double y,
    double width,
    double height,
  ) {
    final queryLeft = width < 0 ? x + width : x;
    final queryTop = height < 0 ? y + height : y;
    final queryRight = queryLeft + width.abs();
    final queryBottom = queryTop + height.abs();

    final found = <Flut5QuadtreePoint<T>>[];
    // A list of areas still to look at instead of recursion, so a tree
    // thousands of splits deep can't overflow the stack.
    final areasToVisit = <Flut5Quadtree<T>>[this];
    while (areasToVisit.isNotEmpty) {
      final area = areasToVisit.removeLast();
      final overlaps =
          queryLeft <= area.x + area.width &&
          queryRight >= area.x &&
          queryTop <= area.y + area.height &&
          queryBottom >= area.y;
      if (!overlaps) continue;

      if (area._isSubdivided) {
        // Pushed last-first so the top-left child is looked at first.
        areasToVisit.addAll(area._children.reversed);
        continue;
      }
      for (final point in area._points) {
        final isInside =
            point.x >= queryLeft &&
            point.x <= queryRight &&
            point.y >= queryTop &&
            point.y <= queryBottom;
        if (isInside) found.add(point);
      }
    }
    return found;
  }

  /// Walks down to the leaf that contains the point and stores it there. A
  /// full leaf is split and the walk carries on into its children, as many
  /// times as it takes. Callers have already checked the point is inside
  /// this area.
  void _insert(Flut5QuadtreePoint<T> point) {
    var area = this;
    while (true) {
      while (area._isSubdivided) {
        area = area._childContaining(point.x, point.y);
      }
      if (area._points.length < capacity) {
        area._points.add(point);
        return;
      }
      area._throwIfSplittingCantMakeRoomFor(point);
      area.subdivide();
    }
  }

  /// Throws when this full area can't split to make room for [point] — see
  /// [add].
  void _throwIfSplittingCantMakeRoomFor(Flut5QuadtreePoint<T> point) {
    final allAtPointPosition = _points.every(
      (stored) => stored.x == point.x && stored.y == point.y,
    );
    if (allAtPointPosition) {
      throw StateError(
        'Flut5Quadtree: can\'t add a point at (${point.x}, ${point.y}): '
        '$capacity points are already at exactly that position, the capacity '
        'of one area, and no split can separate points at the same position. '
        'Pass a larger capacity to the constructor, or add the position once '
        'and keep everything that sits there in its payload.',
      );
    }
    if (_depth >= maxDepth) {
      throw StateError(
        'Flut5Quadtree: can\'t add a point at (${point.x}, ${point.y}): its '
        'area is full ($capacity points) and already $_depth splits deep, the '
        'maxDepth, so it can\'t split again. Pass a larger maxDepth or '
        'capacity to the constructor.',
      );
    }
  }

  /// The child a point inside this area belongs to. A point exactly on the
  /// center line goes right / down, so every point has exactly one child.
  Flut5Quadtree<T> _childContaining(double pointX, double pointY) {
    final column = pointX < _centerX ? 0 : 1;
    final row = pointY < _centerY ? 0 : 1;
    return _children[row * 2 + column];
  }
}
