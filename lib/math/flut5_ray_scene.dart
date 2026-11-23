import 'dart:math' as math;
import 'dart:typed_data';

import '../physics/flut5_physics_polygon.dart';
import 'flut5_line_segment.dart';
import 'flut5_vector.dart';

/// Matches [Flut5Intersection]'s segment endpoint tolerance so rays aimed at
/// shared corners never slip through the seam between two walls.
const double _raySceneParamTolerance = 1e-9;

/// Small AABB inflation so BVH slab tests never reject a seam hit accepted by
/// [_raySceneParamTolerance].
const double _bvhBoundsPad = 1e-7;

/// Maximum segments per BVH leaf before subdividing.
const int _bvhLeafSize = 4;

/// Detailed result of a ray striking a wall inside a [Flut5RayScene].
final class Flut5RayHit({
  /// World-space coordinates where the ray struck the wall.
  required final Flut5Vector point,

  /// Euclidean distance from the ray origin to [point].
  required final double distance,

  /// Parametric position along [wall] in `0..1` (`0` at `wall.start`, `1` at
  /// `wall.end`).
  required final double segmentT,

  /// Unit normal of [wall] oriented back toward the ray origin.
  required final Flut5Vector normal,

  /// Index of [wall] in [Flut5RayScene.walls].
  required final int wallIndex,

  /// The wall segment that was struck.
  required final Flut5LineSegment wall,
}) {
  /// Returns the normalized reflection direction for an incoming ray heading
  /// `(dirX, dirY)` bouncing off [normal].
  Flut5Vector reflect(double dirX, double dirY) {
    final len = math.sqrt(dirX * dirX + dirY * dirY);
    if (len == 0.0 || !len.isFinite) return Flut5Vector.zero();
    final dx = dirX / len;
    final dy = dirY / len;
    final dot = dx * normal.x + dy * normal.y;
    return Flut5Vector(dx - 2.0 * dot * normal.x, dy - 2.0 * dot * normal.y);
  }
}

/// BVH-accelerated 2-D raycasting scene for fast multi-ray queries, light fans,
/// bounces, and visibility polygons over static or periodically updated walls.
///
/// Build once from a list of [Flut5LineSegment]s (or from physics polygons via
/// [Flut5RayScene.fromPolygons]), then cast hundreds or thousands of rays per
/// frame in `O(log W)` average time per ray instead of scanning every wall:
///
/// ```dart
/// final scene = createRayScene(walls);
/// final poly = scene.visibilityPolygon(mouseX, mouseY, maxRadius: 400);
/// beginShape();
/// for (final p in poly) vertex(p.x, p.y);
/// endShape(close: true);
/// ```
///
/// If wall endpoints are mutated in place, call [rebuild] before casting rays.
final class Flut5RayScene(Iterable<Flut5LineSegment> walls) {
  /// Builds an accelerated ray scene from [walls].
  this : _walls = List<Flut5LineSegment>.unmodifiable(walls) {
    rebuild();
  }

  /// Builds a ray scene from the edges of [polygons] (using each polygon's
  /// current [Flut5PhysicsPolygon.corners]) plus any [extraWalls] such as
  /// canvas boundaries.
  factory Flut5RayScene.fromPolygons(
    Iterable<Flut5PhysicsPolygon> polygons, {
    Iterable<Flut5LineSegment> extraWalls = const [],
  }) {
    final segments = <Flut5LineSegment>[];
    for (final polygon in polygons) {
      final corners = polygon.corners;
      final count = corners.length;
      for (var i = 0; i < count; i++) {
        final a = corners[i];
        final b = corners[(i + 1) % count];
        segments.add(Flut5LineSegment(a.x, a.y, b.x, b.y));
      }
    }
    segments.addAll(extraWalls);
    return Flut5RayScene(segments);
  }

  final List<Flut5LineSegment> _walls;

  /// Read-only list of wall segments indexed by this scene.
  List<Flut5LineSegment> get walls => _walls;

  /// Number of wall segments in this scene.
  int get wallCount => _walls.length;

  // Flat-packed segments ordered by BVH leaf layout.
  Float64List _segX1 = Float64List(0);
  Float64List _segY1 = Float64List(0);
  Float64List _segDx = Float64List(0);
  Float64List _segDy = Float64List(0);
  Int32List _segOriginalIndex = Int32List(0);

  // Flat BVH nodes.
  // Bounds stored as 4 consecutive doubles per node: minX, minY, maxX, maxY.
  Float64List _nodeBounds = Float64List(0);
  // Leaf: first segment index. Internal: left child node index.
  Int32List _nodeLeftOrStart = Int32List(0);
  // Leaf: > 0 segment count. Internal: -rightChildNodeIndex (< 0).
  Int32List _nodeRightOrCount = Int32List(0);
  int _nodeCount = 0;

  // Reusable traversal stack to avoid allocations during raycasts.
  Int32List _stack = Int32List(64);

  /// Rebuilds the internal BVH from the current positions of [walls].
  ///
  /// Call this if you mutate `wall.start` or `wall.end` in place after
  /// constructing the scene.
  void rebuild() {
    final n = _walls.length;
    if (n == 0) {
      _nodeCount = 0;
      return;
    }

    // Extract temporary per-wall data before reordering into leaf layout.
    final rawX1 = Float64List(n);
    final rawY1 = Float64List(n);
    final rawDx = Float64List(n);
    final rawDy = Float64List(n);
    final minX = Float64List(n);
    final minY = Float64List(n);
    final maxX = Float64List(n);
    final maxY = Float64List(n);
    final centX = Float64List(n);
    final centY = Float64List(n);
    final order = Int32List(n);

    for (var i = 0; i < n; i++) {
      final w = _walls[i];
      final x1 = w.start.x;
      final y1 = w.start.y;
      final x2 = w.end.x;
      final y2 = w.end.y;
      rawX1[i] = x1;
      rawY1[i] = y1;
      rawDx[i] = x2 - x1;
      rawDy[i] = y2 - y1;
      final loX = x1 < x2 ? x1 : x2;
      final hiX = x1 < x2 ? x2 : x1;
      final loY = y1 < y2 ? y1 : y2;
      final hiY = y1 < y2 ? y2 : y1;
      minX[i] = loX - _bvhBoundsPad;
      minY[i] = loY - _bvhBoundsPad;
      maxX[i] = hiX + _bvhBoundsPad;
      maxY[i] = hiY + _bvhBoundsPad;
      centX[i] = (x1 + x2) * 0.5;
      centY[i] = (y1 + y2) * 0.5;
      order[i] = i;
    }

    final maxNodes = n * 2;
    if (_nodeBounds.length < maxNodes * 4) {
      _nodeBounds = Float64List(maxNodes * 4);
      _nodeLeftOrStart = Int32List(maxNodes);
      _nodeRightOrCount = Int32List(maxNodes);
    }
    _nodeCount = 0;

    // Iterative top-down build using an explicit task stack:
    // triples of (nodeIndex, start, count).
    var taskCap = 128;
    var tasks = Int32List(taskCap);
    var taskTop = 0;

    int allocNode() => _nodeCount++;

    void pushTask(int nodeIdx, int start, int count) {
      if (taskTop + 3 > taskCap) {
        taskCap *= 2;
        tasks = Int32List(taskCap)..setRange(0, taskTop, tasks);
      }
      tasks[taskTop++] = nodeIdx;
      tasks[taskTop++] = start;
      tasks[taskTop++] = count;
    }

    final root = allocNode();
    pushTask(root, 0, n);

    while (taskTop > 0) {
      final count = tasks[--taskTop];
      final start = tasks[--taskTop];
      final nodeIdx = tasks[--taskTop];
      final end = start + count;

      var bMinX = double.infinity;
      var bMinY = double.infinity;
      var bMaxX = double.negativeInfinity;
      var bMaxY = double.negativeInfinity;
      var cMinX = double.infinity;
      var cMinY = double.infinity;
      var cMaxX = double.negativeInfinity;
      var cMaxY = double.negativeInfinity;

      for (var i = start; i < end; i++) {
        final s = order[i];
        if (minX[s] < bMinX) bMinX = minX[s];
        if (minY[s] < bMinY) bMinY = minY[s];
        if (maxX[s] > bMaxX) bMaxX = maxX[s];
        if (maxY[s] > bMaxY) bMaxY = maxY[s];
        final cx = centX[s];
        final cy = centY[s];
        if (cx < cMinX) cMinX = cx;
        if (cy < cMinY) cMinY = cy;
        if (cx > cMaxX) cMaxX = cx;
        if (cy > cMaxY) cMaxY = cy;
      }

      final bo = nodeIdx * 4;
      _nodeBounds[bo] = bMinX;
      _nodeBounds[bo + 1] = bMinY;
      _nodeBounds[bo + 2] = bMaxX;
      _nodeBounds[bo + 3] = bMaxY;

      if (count <= _bvhLeafSize) {
        _nodeLeftOrStart[nodeIdx] = start;
        _nodeRightOrCount[nodeIdx] = count;
        continue;
      }

      // Partition along the longest centroid axis at its midpoint.
      final extentX = cMaxX - cMinX;
      final extentY = cMaxY - cMinY;
      var mid = start;
      if (extentX > 0.0 || extentY > 0.0) {
        final splitX = extentX >= extentY;
        final pivot = splitX ? (cMinX + cMaxX) * 0.5 : (cMinY + cMaxY) * 0.5;
        final cents = splitX ? centX : centY;
        var i = start;
        var j = end - 1;
        while (i <= j) {
          if (cents[order[i]] < pivot) {
            i++;
          } else {
            final tmp = order[i];
            order[i] = order[j];
            order[j] = tmp;
            j--;
          }
        }
        mid = i;
      }

      // Guard against degenerate splits where all centroids fell on one side.
      if (mid == start || mid == end) {
        mid = start + (count >> 1);
      }

      final leftIdx = allocNode();
      final rightIdx = allocNode();
      _nodeLeftOrStart[nodeIdx] = leftIdx;
      _nodeRightOrCount[nodeIdx] = -rightIdx;

      pushTask(rightIdx, mid, end - mid);
      pushTask(leftIdx, start, mid - start);
    }

    // Reorder segment buffers to match leaf layout for sequential cache access.
    if (_segX1.length < n) {
      _segX1 = Float64List(n);
      _segY1 = Float64List(n);
      _segDx = Float64List(n);
      _segDy = Float64List(n);
      _segOriginalIndex = Int32List(n);
    }
    for (var i = 0; i < n; i++) {
      final orig = order[i];
      _segX1[i] = rawX1[orig];
      _segY1[i] = rawY1[orig];
      _segDx[i] = rawDx[orig];
      _segDy[i] = rawDy[orig];
      _segOriginalIndex[i] = orig;
    }
  }

  /// Casts a ray from ([rayX], [rayY]) along ([dirX], [dirY]) and returns the
  /// closest [Flut5RayHit] within [maxDistance], or `null` if nothing is hit.
  ///
  /// The direction vector does not need to be normalized. A zero direction or
  /// non-positive [maxDistance] returns `null`.
  Flut5RayHit? castRayClosest(
    double rayX,
    double rayY,
    double dirX,
    double dirY, {
    double maxDistance = double.infinity,
  }) {
    if (_nodeCount == 0 || maxDistance < 0.0) return null;
    final lenSq = dirX * dirX + dirY * dirY;
    if (lenSq == 0.0 || !lenSq.isFinite) return null;
    final invLen = 1.0 / math.sqrt(lenSq);
    final ndx = dirX * invLen;
    final ndy = dirY * invLen;
    return _castClosestNormalized(rayX, rayY, ndx, ndy, maxDistance);
  }

  /// Casts a ray from ([rayX], [rayY]) along ([dirX], [dirY]) and returns
  /// every [Flut5RayHit] within [maxDistance], sorted closest-first.
  List<Flut5RayHit> castRay(
    double rayX,
    double rayY,
    double dirX,
    double dirY, {
    double maxDistance = double.infinity,
  }) {
    if (_nodeCount == 0 || maxDistance < 0.0) return const [];
    final lenSq = dirX * dirX + dirY * dirY;
    if (lenSq == 0.0 || !lenSq.isFinite) return const [];
    final invLen = 1.0 / math.sqrt(lenSq);
    final ndx = dirX * invLen;
    final ndy = dirY * invLen;
    final invDx = ndx == 0.0 ? double.infinity : 1.0 / ndx;
    final invDy = ndy == 0.0 ? double.infinity : 1.0 / ndy;

    final bounds = _nodeBounds;
    if (_slabDistance(
      rayX,
      rayY,
      invDx,
      invDy,
      bounds[0],
      bounds[1],
      bounds[2],
      bounds[3],
      maxDistance,
    ).isInfinite) {
      return const [];
    }

    final hits = <Flut5RayHit>[];
    var stackTop = 0;
    _stack[stackTop++] = 0;

    final leftOrStart = _nodeLeftOrStart;
    final rightOrCount = _nodeRightOrCount;
    final segX1 = _segX1;
    final segY1 = _segY1;
    final segDx = _segDx;
    final segDy = _segDy;

    while (stackTop > 0) {
      final node = _stack[--stackTop];
      final rc = rightOrCount[node];
      if (rc > 0) {
        final start = leftOrStart[node];
        final end = start + rc;
        for (var i = start; i < end; i++) {
          final dx = segDx[i];
          final dy = segDy[i];
          final den = ndx * dy - ndy * dx;
          if (den == 0.0) continue;

          final gx = segX1[i] - rayX;
          final gy = segY1[i] - rayY;
          double t;
          double u;
          if (den > 0.0) {
            final tolDen = _raySceneParamTolerance * den;
            final uNum = gx * ndy - gy * ndx;
            if (uNum < -tolDen || uNum > den + tolDen) continue;
            final tNum = gx * dy - gy * dx;
            if (tNum < -tolDen) continue;
            if (maxDistance.isFinite && tNum > maxDistance * den) continue;
            t = tNum / den;
            u = uNum / den;
          } else {
            final negDen = -den;
            final tolDen = _raySceneParamTolerance * negDen;
            final uNum = -(gx * ndy - gy * ndx);
            if (uNum < -tolDen || uNum > negDen + tolDen) continue;
            final tNum = -(gx * dy - gy * dx);
            if (tNum < -tolDen) continue;
            if (maxDistance.isFinite && tNum > maxDistance * negDen) continue;
            t = tNum / negDen;
            u = uNum / negDen;
          }
          if (!t.isFinite) continue;
          hits.add(_buildHit(rayX, rayY, ndx, ndy, i, t, u));
        }
      } else {
        final left = leftOrStart[node];
        final right = -rc;
        final lo = left * 4;
        final ro = right * 4;
        final tLeft = _slabDistance(
          rayX,
          rayY,
          invDx,
          invDy,
          bounds[lo],
          bounds[lo + 1],
          bounds[lo + 2],
          bounds[lo + 3],
          maxDistance,
        );
        final tRight = _slabDistance(
          rayX,
          rayY,
          invDx,
          invDy,
          bounds[ro],
          bounds[ro + 1],
          bounds[ro + 2],
          bounds[ro + 3],
          maxDistance,
        );
        if (stackTop + 2 > _stack.length) {
          _stack = Int32List(_stack.length * 2)..setRange(0, stackTop, _stack);
        }
        if (tRight.isFinite) _stack[stackTop++] = right;
        if (tLeft.isFinite) _stack[stackTop++] = left;
      }
    }

    if (hits.length > 1) {
      hits.sort((a, b) => a.distance.compareTo(b.distance));
    }
    return hits;
  }

  /// Casts [rayCount] evenly spaced rays starting at [startAngle] (in radians)
  /// across [sweepAngle] (default `2π`) from ([originX], [originY]).
  ///
  /// Each entry in the returned list is the closest hit for that ray, or `null`
  /// if that ray missed every wall within [maxDistance].
  List<Flut5RayHit?> castRayFan(
    double originX,
    double originY,
    int rayCount, {
    double startAngle = 0.0,
    double sweepAngle = math.pi * 2.0,
    double maxDistance = double.infinity,
  }) {
    if (rayCount <= 0) return const [];
    final step = sweepAngle / rayCount;
    return List<Flut5RayHit?>.generate(rayCount, (i) {
      final angle = startAngle + i * step;
      return _castClosestNormalized(
        originX,
        originY,
        math.cos(angle),
        math.sin(angle),
        maxDistance,
      );
    }, growable: false);
  }

  /// Computes the 2-D visibility polygon seen from ([originX], [originY]) in
  /// `O(W log W)` time by casting rays toward every unique wall endpoint
  /// (offset by `±1e-5` rad to peek past corners) and sorting by angle.
  ///
  /// When [maxRadius] is finite, rays are clamped to that distance and
  /// perimeter sample rays are added so open space curves smoothly at
  /// [maxRadius]. Returns vertices in counter-clockwise angular order ready
  /// for `beginShape()` / `vertex()`.
  List<Flut5Vector> visibilityPolygon(
    double originX,
    double originY, {
    double maxRadius = double.infinity,
    int openArcSteps = 48,
  }) {
    if (maxRadius <= 0.0) return const [];
    final hasCap = maxRadius.isFinite;
    final wallLen = _walls.length;
    if (wallLen == 0 && !hasCap) return const [];

    const eps = 1e-5;
    final angles = <double>[];

    // Collect angles to every wall endpoint, plus ±eps offsets to see past
    // silhouette corners.
    for (var i = 0; i < wallLen; i++) {
      final w = _walls[i];
      final ax = w.start.x - originX;
      final ay = w.start.y - originY;
      if (ax != 0.0 || ay != 0.0) {
        final a = math.atan2(ay, ax);
        angles
          ..add(a - eps)
          ..add(a)
          ..add(a + eps);
      }
      final bx = w.end.x - originX;
      final by = w.end.y - originY;
      if (bx != 0.0 || by != 0.0) {
        final b = math.atan2(by, bx);
        angles
          ..add(b - eps)
          ..add(b)
          ..add(b + eps);
      }
    }

    if (hasCap && openArcSteps > 0) {
      final step = (math.pi * 2.0) / openArcSteps;
      for (var i = 0; i < openArcSteps; i++) {
        angles.add(-math.pi + i * step);
      }
    }

    if (angles.isEmpty) return const [];

    // Wrap into [-pi, pi) so angles near ±pi sort cleanly across the seam.
    for (var i = 0; i < angles.length; i++) {
      var a = angles[i];
      if (a >= math.pi) {
        a -= math.pi * 2.0;
      } else if (a < -math.pi) {
        a += math.pi * 2.0;
      }
      angles[i] = a;
    }
    angles.sort();

    final polygon = <Flut5Vector>[];
    var lastAngle = double.nan;
    for (var i = 0; i < angles.length; i++) {
      final a = angles[i];
      if (lastAngle == lastAngle && (a - lastAngle).abs() < 1e-9) continue;
      lastAngle = a;
      final dx = math.cos(a);
      final dy = math.sin(a);
      final hit = _castClosestNormalized(originX, originY, dx, dy, maxRadius);
      if (hit != null) {
        polygon.add(hit.point);
      } else if (hasCap) {
        polygon.add(
          Flut5Vector(originX + dx * maxRadius, originY + dy * maxRadius),
        );
      }
    }
    return polygon;
  }

  /// Core closest-hit BVH traversal for an already-normalized ray direction.
  Flut5RayHit? _castClosestNormalized(
    double rayX,
    double rayY,
    double ndx,
    double ndy,
    double maxDistance,
  ) {
    if (_nodeCount == 0) return null;
    final invDx = ndx == 0.0 ? double.infinity : 1.0 / ndx;
    final invDy = ndy == 0.0 ? double.infinity : 1.0 / ndy;
    final bounds = _nodeBounds;

    var bestT = maxDistance;
    if (_slabDistance(
      rayX,
      rayY,
      invDx,
      invDy,
      bounds[0],
      bounds[1],
      bounds[2],
      bounds[3],
      bestT,
    ).isInfinite) {
      return null;
    }

    var bestSlot = -1;
    var bestU = 0.0;

    var stackTop = 0;
    _stack[stackTop++] = 0;

    final leftOrStart = _nodeLeftOrStart;
    final rightOrCount = _nodeRightOrCount;
    final segX1 = _segX1;
    final segY1 = _segY1;
    final segDx = _segDx;
    final segDy = _segDy;

    while (stackTop > 0) {
      final node = _stack[--stackTop];
      final rc = rightOrCount[node];
      if (rc > 0) {
        final start = leftOrStart[node];
        final end = start + rc;
        for (var i = start; i < end; i++) {
          final dx = segDx[i];
          final dy = segDy[i];
          final den = ndx * dy - ndy * dx;
          if (den == 0.0) continue;

          final gx = segX1[i] - rayX;
          final gy = segY1[i] - rayY;
          if (den > 0.0) {
            final tolDen = _raySceneParamTolerance * den;
            final uNum = gx * ndy - gy * ndx;
            if (uNum < -tolDen || uNum > den + tolDen) continue;
            final tNum = gx * dy - gy * dx;
            if (tNum < -tolDen) continue;
            if (bestT.isFinite && tNum >= bestT * den) continue;
            final t = tNum / den;
            if (t < bestT) {
              bestT = t;
              bestU = uNum / den;
              bestSlot = i;
            }
          } else {
            final negDen = -den;
            final tolDen = _raySceneParamTolerance * negDen;
            final uNum = -(gx * ndy - gy * ndx);
            if (uNum < -tolDen || uNum > negDen + tolDen) continue;
            final tNum = -(gx * dy - gy * dx);
            if (tNum < -tolDen) continue;
            if (bestT.isFinite && tNum >= bestT * negDen) continue;
            final t = tNum / negDen;
            if (t < bestT) {
              bestT = t;
              bestU = uNum / negDen;
              bestSlot = i;
            }
          }
        }
      } else {
        final left = leftOrStart[node];
        final right = -rc;
        final lo = left * 4;
        final ro = right * 4;
        final tLeft = _slabDistance(
          rayX,
          rayY,
          invDx,
          invDy,
          bounds[lo],
          bounds[lo + 1],
          bounds[lo + 2],
          bounds[lo + 3],
          bestT,
        );
        final tRight = _slabDistance(
          rayX,
          rayY,
          invDx,
          invDy,
          bounds[ro],
          bounds[ro + 1],
          bounds[ro + 2],
          bounds[ro + 3],
          bestT,
        );

        final hitLeft = tLeft <= bestT;
        final hitRight = tRight <= bestT;
        if (hitLeft && hitRight) {
          if (stackTop + 2 > _stack.length) {
            _stack = Int32List(_stack.length * 2)
              ..setRange(0, stackTop, _stack);
          }
          // Push the farther child first so the nearer child is popped first
          // and tightens `bestT` earlier.
          if (tLeft < tRight) {
            _stack[stackTop++] = right;
            _stack[stackTop++] = left;
          } else {
            _stack[stackTop++] = left;
            _stack[stackTop++] = right;
          }
        } else if (hitLeft) {
          if (stackTop + 1 > _stack.length) {
            _stack = Int32List(_stack.length * 2)
              ..setRange(0, stackTop, _stack);
          }
          _stack[stackTop++] = left;
        } else if (hitRight) {
          if (stackTop + 1 > _stack.length) {
            _stack = Int32List(_stack.length * 2)
              ..setRange(0, stackTop, _stack);
          }
          _stack[stackTop++] = right;
        }
      }
    }

    if (bestSlot < 0) return null;
    return _buildHit(rayX, rayY, ndx, ndy, bestSlot, bestT, bestU);
  }

  Flut5RayHit _buildHit(
    double rayX,
    double rayY,
    double ndx,
    double ndy,
    int slot,
    double t,
    double u,
  ) {
    final dist = t < 0.0 ? 0.0 : t;
    final segT = u.clamp(0.0, 1.0);
    final dx = _segDx[slot];
    final dy = _segDy[slot];
    final segLen = math.sqrt(dx * dx + dy * dy);
    var nx = 0.0;
    var ny = 0.0;
    if (segLen > 0.0) {
      nx = -dy / segLen;
      ny = dx / segLen;
      // Orient normal to face back against the incoming ray.
      if (nx * ndx + ny * ndy > 0.0) {
        nx = -nx;
        ny = -ny;
      }
    }
    final origIdx = _segOriginalIndex[slot];
    return Flut5RayHit(
      point: Flut5Vector(rayX + t * ndx, rayY + t * ndy),
      distance: dist,
      segmentT: segT,
      normal: Flut5Vector(nx, ny),
      wallIndex: origIdx,
      wall: _walls[origIdx],
    );
  }

  @pragma('vm:prefer-inline')
  static double _slabDistance(
    double rayX,
    double rayY,
    double invDx,
    double invDy,
    double minX,
    double minY,
    double maxX,
    double maxY,
    double maxDist,
  ) {
    var tMin = 0.0;
    var tMax = maxDist;
    if (invDx.isFinite) {
      final t1 = (minX - rayX) * invDx;
      final t2 = (maxX - rayX) * invDx;
      final lo = t1 < t2 ? t1 : t2;
      final hi = t1 < t2 ? t2 : t1;
      if (lo > tMin) tMin = lo;
      if (hi < tMax) tMax = hi;
      if (tMax < tMin) return double.infinity;
    } else if (rayX < minX || rayX > maxX) {
      return double.infinity;
    }
    if (invDy.isFinite) {
      final t1 = (minY - rayY) * invDy;
      final t2 = (maxY - rayY) * invDy;
      final lo = t1 < t2 ? t1 : t2;
      final hi = t1 < t2 ? t2 : t1;
      if (lo > tMin) tMin = lo;
      if (hi < tMax) tMax = hi;
      if (tMax < tMin) return double.infinity;
    } else if (rayY < minY || rayY > maxY) {
      return double.infinity;
    }
    return tMin;
  }
}
