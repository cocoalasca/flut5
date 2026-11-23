import 'dart:collection';

import 'package:flutter/foundation.dart' show visibleForTesting;

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
  var double _x,
  var double _y,
  var double _width,
  var double _height,

  /// How many points an area holds before it splits into four.
  final int capacity,

  /// How many times an area may be split below the root. When [allowOverflow]
  /// is `false` (default), a full area this deep can't split again and [add]ing
  /// a point to it throws a [StateError]; when `true`, the leaf overflows and
  /// stores the extra point instead of throwing.
  final int maxDepth,

  /// How many splits deep this area is: `0` for the root.
  var int _depth,

  /// Whether a full leaf that cannot split further (at [maxDepth] or with all
  /// points at identical coordinates) stores extra points in place instead of
  /// throwing a [StateError]. Defaults to `false`.
  final bool allowOverflow,

  /// Shared node pool owned by the root tree so [clear] recycles child nodes
  /// and subsequent frames rebuild the tree without per-node allocations.
  final List<Flut5Quadtree<T>> _nodePool,
) {
  /// Creates an empty tree covering `0..width` × `0..height`, `1` × `1` by
  /// default. Each area splits into four once it holds more than [capacity]
  /// points, down to [maxDepth] splits below the root.
  ///
  /// Pass `allowOverflow = true` (the 5th positional argument) for dynamic
  /// particle/agent sketches where more than [capacity] items may temporarily
  /// occupy the exact same coordinate or reach [maxDepth]: full leaves will
  /// accept overflow points instead of throwing [StateError].
  factory Flut5Quadtree([
    double width = 1,
    double height = 1,
    int capacity = 4,
    int maxDepth = defaultMaxDepth,
    bool allowOverflow = false,
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
    return Flut5Quadtree._area(
      0,
      0,
      width,
      height,
      capacity,
      maxDepth,
      0,
      allowOverflow,
      <Flut5Quadtree<T>>[],
    );
  }

  /// The [maxDepth] a tree gets when you don't pass one: deep enough that it
  /// never gets in the way. Each split halves an area, and a `double` reaches
  /// its smallest step after about 1100 halvings from `1`, so any two
  /// different positions — on a canvas of any size you'd use — are in
  /// different areas long before 2048 splits.
  static const int defaultMaxDepth = 2048;

  /// Upper bound on recycled child nodes kept by [clear] so a single extreme
  /// frame doesn't pin unbounded memory.
  static const int _maxPooledNodes = 4096;

  /// Left edge of this area, in the root tree's coordinates. `0` for the
  /// tree you create; its [children] are offset inside it.
  double get x => _x;

  /// Top edge of this area, in the root tree's coordinates.
  double get y => _y;

  /// Width of this area.
  double get width => _width;

  /// Height of this area.
  double get height => _height;

  double _centerX = _x + _width / 2;
  double _centerY = _y + _height / 2;

  final List<Flut5QuadtreePoint<T>> _points = [];

  /// Lazily allocated on first [subdivide] and cleared (retaining its backing
  /// 4-element buffer) on [clear]; top-left, top-right, bottom-left,
  /// bottom-right (row by row, as [_childContaining] indexes them).
  List<Flut5Quadtree<T>>? _children;

  /// Reusable traversal stack for [query], [queryCircle], and [clear],
  /// avoiding a fresh list allocation per operation.
  List<Flut5Quadtree<T>>? _visitStack;

  bool get _isSubdivided => _children != null && _children!.isNotEmpty;

  /// Number of recycled child nodes currently cached for reuse by [subdivide].
  @visibleForTesting
  int get debugPooledNodeCount => _nodePool.length;

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
  List<Flut5Quadtree<T>> get children =>
      _children == null ? const [] : UnmodifiableListView(_children!);

  void _reset(
    double newX,
    double newY,
    double newWidth,
    double newHeight,
    int newDepth,
  ) {
    _x = newX;
    _y = newY;
    _width = newWidth;
    _height = newHeight;
    _depth = newDepth;
    _centerX = newX + newWidth / 2;
    _centerY = newY + newHeight / 2;
    _points.clear();
    _children?.clear();
  }

  /// Files [point] in the smallest area that contains it, splitting areas
  /// that go over [capacity] on the way.
  ///
  /// Returns `false`, and stores nothing, when the point is outside the tree
  /// (`0..width` × `0..height`, edges included).
  ///
  /// When [allowOverflow] is `false` (default), throws a [StateError] and
  /// stores nothing when the point's area is full and splitting can't make
  /// room:
  /// - the area is already [maxDepth] splits deep, or
  /// - every point in it sits at exactly the point's position — no split
  ///   ever separates those, so this throws straight away rather than
  ///   splitting down to [maxDepth] first.
  ///
  /// When [allowOverflow] is `true`, the full leaf accepts the extra point
  /// instead of throwing.
  bool add(Flut5QuadtreePoint<T> point) {
    final isInside =
        point.x >= _x &&
        point.x <= _x + _width &&
        point.y >= _y &&
        point.y <= _y + _height;
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
    final halfWidth = _width / 2;
    final halfHeight = _height / 2;
    final childDepth = _depth + 1;
    Flut5Quadtree<T> child(double childX, double childY) {
      if (_nodePool.isNotEmpty) {
        return _nodePool.removeLast()
          .._reset(childX, childY, halfWidth, halfHeight, childDepth);
      }
      return Flut5Quadtree<T>._area(
        childX,
        childY,
        halfWidth,
        halfHeight,
        capacity,
        maxDepth,
        childDepth,
        allowOverflow,
        _nodePool,
      );
    }

    final children = _children ??= <Flut5Quadtree<T>>[];
    children
      ..add(child(_x, _y))
      ..add(child(_centerX, _y))
      ..add(child(_x, _centerY))
      ..add(child(_centerX, _centerY));

    // Move every stored point down into its child and leave this split area
    // empty while keeping its backing list for reuse after [clear].
    for (var i = 0; i < _points.length; i++) {
      final point = _points[i];
      _childContaining(point.x, point.y)._points.add(point);
    }
    _points.clear();
  }

  /// Removes every point stored under this area and collapses its [children],
  /// recycling child nodes into an internal pool so subsequent frames rebuild
  /// the tree without per-node allocations.
  void clear() {
    if (!_isSubdivided) {
      _points.clear();
      return;
    }
    final stack = (_visitStack ??= <Flut5Quadtree<T>>[]);
    final ownChildren = _children!;
    for (var i = 0; i < ownChildren.length; i++) {
      stack.add(ownChildren[i]);
    }
    ownChildren.clear();
    _points.clear();
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      final nodeChildren = node._children;
      if (nodeChildren != null && nodeChildren.isNotEmpty) {
        for (var i = 0; i < nodeChildren.length; i++) {
          stack.add(nodeChildren[i]);
        }
        nodeChildren.clear();
      }
      node._points.clear();
      if (_nodePool.length < _maxPooledNodes) {
        _nodePool.add(node);
      }
    }
  }

  /// Every point inside the rectangle with its top-left corner at
  /// ([x], [y]) and size [width] × [height], in the tree's coordinates.
  /// Points on the rectangle's edges count as inside. A negative width or
  /// height reaches left or up from ([x], [y]).
  ///
  /// When [into] is provided, matching points are appended to it and [into]
  /// is returned, avoiding a per-query list allocation in hot loops.
  ///
  /// Areas that don't overlap the rectangle are skipped whole, which is what
  /// makes this faster than checking every point.
  List<Flut5QuadtreePoint<T>> query(
    double x,
    double y,
    double width,
    double height, {
    List<Flut5QuadtreePoint<T>>? into,
  }) {
    final queryLeft = width < 0 ? x + width : x;
    final queryTop = height < 0 ? y + height : y;
    final queryRight = queryLeft + width.abs();
    final queryBottom = queryTop + height.abs();

    final found = into ?? <Flut5QuadtreePoint<T>>[];
    // Reuse one traversal stack instead of recursion (so deep trees can't
    // overflow the call stack) and without allocating per query.
    final areasToVisit = (_visitStack ??= <Flut5Quadtree<T>>[])..add(this);
    while (areasToVisit.isNotEmpty) {
      final area = areasToVisit.removeLast();
      final overlaps =
          queryLeft <= area._x + area._width &&
          queryRight >= area._x &&
          queryTop <= area._y + area._height &&
          queryBottom >= area._y;
      if (!overlaps) continue;

      if (area._isSubdivided) {
        // Push last-first directly so the top-left child is visited first
        // without allocating a reversed iterable.
        final children = area._children!;
        areasToVisit
          ..add(children[3])
          ..add(children[2])
          ..add(children[1])
          ..add(children[0]);
        continue;
      }
      final points = area._points;
      for (var i = 0; i < points.length; i++) {
        final point = points[i];
        if (point.x >= queryLeft &&
            point.x <= queryRight &&
            point.y >= queryTop &&
            point.y <= queryBottom) {
          found.add(point);
        }
      }
    }
    return found;
  }

  /// Every point within [radius] of ([cx], [cy]), boundary included.
  ///
  /// Rejects areas using a tight circle-vs-AABB test before checking
  /// individual points, skipping corner quadrants that a bounding square would
  /// have searched. Pass [into] to reuse a caller-owned result buffer.
  List<Flut5QuadtreePoint<T>> queryCircle(
    double cx,
    double cy,
    double radius, {
    List<Flut5QuadtreePoint<T>>? into,
  }) {
    final found = into ?? <Flut5QuadtreePoint<T>>[];
    if (radius < 0.0) return found;

    final radiusSq = radius * radius;
    final minX = cx - radius;
    final maxX = cx + radius;
    final minY = cy - radius;
    final maxY = cy + radius;

    final areasToVisit = (_visitStack ??= <Flut5Quadtree<T>>[])..add(this);
    while (areasToVisit.isNotEmpty) {
      final area = areasToVisit.removeLast();
      final ax0 = area._x;
      final ay0 = area._y;
      final ax1 = ax0 + area._width;
      final ay1 = ay0 + area._height;
      if (maxX < ax0 || minX > ax1 || maxY < ay0 || minY > ay1) continue;

      final clampedX = cx < ax0 ? ax0 : (cx > ax1 ? ax1 : cx);
      final clampedY = cy < ay0 ? ay0 : (cy > ay1 ? ay1 : cy);
      final dx = cx - clampedX;
      final dy = cy - clampedY;
      if (dx * dx + dy * dy > radiusSq) continue;

      if (area._isSubdivided) {
        final children = area._children!;
        areasToVisit
          ..add(children[3])
          ..add(children[2])
          ..add(children[1])
          ..add(children[0]);
        continue;
      }
      final points = area._points;
      for (var i = 0; i < points.length; i++) {
        final point = points[i];
        final px = point.x - cx;
        final py = point.y - cy;
        if (px * px + py * py <= radiusSq) {
          found.add(point);
        }
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
      if (area._allPointsAt(point.x, point.y)) {
        if (allowOverflow) {
          area._points.add(point);
          return;
        }
        throw StateError(
          'Flut5Quadtree: can\'t add a point at (${point.x}, ${point.y}): '
          '$capacity points are already at exactly that position, the capacity '
          'of one area, and no split can separate points at the same position. '
          'Pass a larger capacity to the constructor, enable allowOverflow, '
          'or add the position once and keep everything that sits there in its '
          'payload.',
        );
      }
      if (area._depth >= maxDepth) {
        if (allowOverflow) {
          area._points.add(point);
          return;
        }
        throw StateError(
          'Flut5Quadtree: can\'t add a point at (${point.x}, ${point.y}): its '
          'area is full ($capacity points) and already ${area._depth} splits '
          'deep, the maxDepth, so it can\'t split again. Pass a larger '
          'maxDepth or capacity to the constructor, or enable allowOverflow.',
        );
      }
      area.subdivide();
    }
  }

  bool _allPointsAt(double px, double py) {
    for (var i = 0; i < _points.length; i++) {
      final stored = _points[i];
      if (stored.x != px || stored.y != py) return false;
    }
    return true;
  }

  /// The child a point inside this area belongs to. A point exactly on the
  /// center line goes right / down, so every point has exactly one child.
  Flut5Quadtree<T> _childContaining(double pointX, double pointY) {
    final column = pointX < _centerX ? 0 : 1;
    final row = pointY < _centerY ? 0 : 1;
    return _children![row * 2 + column];
  }
}
