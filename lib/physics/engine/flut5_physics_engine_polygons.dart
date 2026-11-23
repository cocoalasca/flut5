part of 'flut5_physics_engine.dart';

/// The polygon side of [Flut5PhysicsEngine]: creating rects and convex
/// polygons, and finding where they touch each other, particles and the
/// window edges. Pushing them apart once they touch is
/// [_ContactManifold.resolve].
mixin _PhysicsPolygons {
  // Provided by Flut5PhysicsEngine and its other parts.
  List<Flut5PhysicsPolygon> get _polygons;
  List<Flut5PhysicsParticle> get _particles;
  void _register(Flut5PhysicsBody body);
  Flut5Vector get gravity;
  PhysicsRotationMode get rotationMode;
  double get friction;
  double get windowBoundsRestitution;
  _WindowLimits? _windowLimits();
  _ParticleGrid _fileParticles();
  _ParticleGrid get _particleGrid;
  void _notifyCollision(
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double normalX,
    double normalY,
    double normalZ,
    double overlap,
  );

  /// Creates a [width] × [height] [Flut5PhysicsRect] centered on ([x], [y]),
  /// registers it and returns it. Make it a platform with
  /// `..isStatic = true`.
  Flut5PhysicsRect createRect(double x, double y, double width, double height) {
    final rect = Flut5PhysicsRect(x, y, width, height);
    _register(rect);
    _polygons.add(rect);
    return rect;
  }

  /// Creates a convex [Flut5PhysicsPolygon] at ([x], [y]) with [corners]
  /// relative to that point, registers it and returns it. Corners can go
  /// either way around; a concave shape throws an [ArgumentError] naming
  /// the corner that makes the dent.
  ///
  /// The polygon turns around its center of mass, so its `position` is
  /// moved there if [corners] aren't centered on ([x], [y]).
  Flut5PhysicsPolygon createPolygon(
    double x,
    double y,
    List<Flut5Vector> corners,
  ) {
    final polygon = Flut5PhysicsPolygon(x, y, corners);
    _register(polygon);
    _polygons.add(polygon);
    return polygon;
  }

  double _polygonRestitution = 1.0;

  /// How bouncy hits involving a polygon are — polygon against polygon or
  /// against a particle: the share of their approach speed that bounces
  /// back. `1` (default) is a perfectly elastic bounce, `0` stops them dead
  /// along the hit; above `1` every hit adds energy. Must be >= 0. Hits
  /// against the window edges use `windowBoundsRestitution` instead.
  double get polygonRestitution => _polygonRestitution;
  set polygonRestitution(double restitution) {
    if (restitution < 0) {
      throw ArgumentError.value(
        restitution,
        'restitution',
        'Restitution must be >= 0',
      );
    }
    _polygonRestitution = restitution;
  }

  /// Every polygon's shape where it is now; index i belongs to
  /// `_polygons[i]`. Refreshed at the start of each collision pass.
  final List<_PolygonShape> _polygonShapes = [];

  /// Sweep-and-prune view of [_polygonShapes], kept sorted by `minX` via
  /// insertion sort for O(N + K) polygon–polygon broadphase.
  final List<_PolygonShape> _sapShapes = [];

  final _ContactManifold _manifold = _ContactManifold();
  final _Segment _clippedEdge = _Segment();

  /// The window, as a body nothing moves, for polygons hitting its edges.
  final Flut5PhysicsRect _window = Flut5PhysicsRect(0, 0, 1, 1)
    ..isStatic = true;

  /// How much shallower the second polygon's best edge must be before it is
  /// used as the reference edge instead of the first's. Without this, two
  /// nearly equal edges would take turns frame to frame and the contact
  /// would jitter.
  static const double _referenceTolerance = 0.05;

  /// Whether [_sapShapes] is sorted along y rather than x.
  bool _sweepsAlongY = false;

  /// Picks the sweep axis: the one the polygons are more spread out on, so
  /// a tall column doesn't test every polygon against every other. Swaps
  /// only on a clear difference, since a swap costs a full re-sort.
  void _chooseSweepAxis(List<_PolygonShape> shapes) {
    var lowX = double.infinity, highX = double.negativeInfinity;
    var lowY = double.infinity, highY = double.negativeInfinity;
    for (var i = 0; i < shapes.length; i++) {
      final shape = shapes[i];
      if (shape.minX < lowX) lowX = shape.minX;
      if (shape.maxX > highX) highX = shape.maxX;
      if (shape.minY < lowY) lowY = shape.minY;
      if (shape.maxY > highY) highY = shape.maxY;
    }
    final spreadX = highX - lowX, spreadY = highY - lowY;
    if (_sweepsAlongY ? spreadX > spreadY * 1.25 : spreadY > spreadX * 1.25) {
      _sweepsAlongY = !_sweepsAlongY;
    }
  }

  /// One collision pass for polygons: every polygon against every other via
  /// 1D sweep-and-prune along the wider axis (two static ones never), then
  /// every polygon against the particles around it.
  void _collidePolygons({bool reuseParticleGrid = false}) {
    _refreshPolygonShapes();
    final shapes = _polygonShapes;
    final count = shapes.length;
    if (count > 1) {
      final sap = _sapShapes;
      _chooseSweepAxis(sap);
      final alongY = _sweepsAlongY;
      // Insertion sort by the leading edge — O(N) on coherent frames.
      for (var i = 1; i < count; i++) {
        final key = sap[i];
        final keyStart = alongY ? key.minY : key.minX;
        var j = i - 1;
        while (j >= 0 && (alongY ? sap[j].minY : sap[j].minX) > keyStart) {
          sap[j + 1] = sap[j];
          j--;
        }
        sap[j + 1] = key;
      }
      for (var a = 0; a < count; a++) {
        final shapeA = sap[a];
        final polyA = shapeA.polygon;
        final aStatic = polyA.isStatic;
        final aImmobile =
            polyA.isSleeping ||
            (aStatic && polyA.velocity.length2 == 0.0 && polyA.angularVelocity == 0.0);
        for (var b = a + 1; b < count; b++) {
          final shapeB = sap[b];
          if (alongY
              ? shapeB.minY > shapeA.maxY
              : shapeB.minX > shapeA.maxX) {
            break;
          }
          final polyB = shapeB.polygon;
          if (aStatic && polyB.isStatic) continue;
          if (aImmobile &&
              (polyB.isSleeping ||
                  (polyB.isStatic &&
                      polyB.velocity.length2 == 0.0 &&
                      polyB.angularVelocity == 0.0))) {
            continue;
          }
          if (!shapeA.boundsOverlap(shapeB)) continue;
          // Keep creation-order tie-breaking for reference edge selection.
          if (shapeA.index < shapeB.index) {
            _collidePolygonPair(shapeA, shapeB);
          } else {
            _collidePolygonPair(shapeB, shapeA);
          }
        }
      }
    }
    if (shapes.isEmpty || _particles.isEmpty) return;
    final grid = reuseParticleGrid ? _particleGrid : _fileParticles();
    for (var i = 0; i < shapes.length; i++) {
      _collidePolygonWithNearbyParticles(shapes[i], grid);
    }
  }

  /// Collides [shape] with the particles [grid] has filed around it, and
  /// with the particles too big for its cells.
  void _collidePolygonWithNearbyParticles(
    _PolygonShape shape,
    _ParticleGrid grid,
  ) {
    final particles = _particles;
    // A filed particle's edge is at most half a cell from its center. The
    // other half is for particles that pushes earlier in this pass moved
    // since they were filed.
    final reach = grid.cellSize;
    if (grid.isHashed) {
      final c0 = grid.hashColumnAt(shape.minX - reach);
      final c1 = grid.hashColumnAt(shape.maxX + reach);
      final r0 = grid.hashRowAt(shape.minY - reach);
      final r1 = grid.hashRowAt(shape.maxY + reach);
      final spanCells = (c1 - c0 + 1) * (r1 - r0 + 1);
      if (spanCells > grid.filedCount) {
        final filed = grid.filedParticles;
        for (var slot = 0; slot < grid.filedCount; slot++) {
          _collidePolygonWithParticleIfNear(shape, particles[filed[slot]]);
        }
      } else {
        final hashHeads = grid.hashHeads;
        final hashNext = grid.hashNext;
        final cellX = grid.cellX;
        final cellY = grid.cellY;
        for (var row = r0; row <= r1; row++) {
          for (var col = c0; col <= c1; col++) {
            for (
              var p = hashHeads[grid.hashSlot(col, row)];
              p >= 0;
              p = hashNext[p]
            ) {
              if (cellX[p] == col && cellY[p] == row) {
                _collidePolygonWithParticleIfNear(shape, particles[p]);
              }
            }
          }
        }
      }
    } else {
      final firstColumn = grid.columnAt(shape.minX - reach);
      final lastColumn = grid.columnAt(shape.maxX + reach);
      final firstRow = grid.rowAt(shape.minY - reach);
      final lastRow = grid.rowAt(shape.maxY + reach);
      final cellStarts = grid.cellStarts;
      final filedParticles = grid.filedParticles;
      for (var row = firstRow; row <= lastRow; row++) {
        // The cells of one row are one run of the list.
        final rowStart = row * grid.columns;
        final runEnd = cellStarts[rowStart + lastColumn + 1];
        for (
          var slot = cellStarts[rowStart + firstColumn];
          slot < runEnd;
          slot++
        ) {
          _collidePolygonWithParticleIfNear(
            shape,
            particles[filedParticles[slot]],
          );
        }
      }
    }
    final largeParticles = grid.largeParticles;
    for (var slot = 0; slot < grid.largeCount; slot++) {
      _collidePolygonWithParticleIfNear(shape, particles[largeParticles[slot]]);
    }
  }

  /// Collides [shape] with [particle] if the boxes around them overlap — a
  /// cheap test that rules out most particles before the exact one.
  void _collidePolygonWithParticleIfNear(
    _PolygonShape shape,
    Flut5PhysicsParticle particle,
  ) {
    final poly = shape.polygon;
    final polyImmobile =
        poly.isSleeping ||
        (poly.isStatic &&
            poly.velocity.length2 == 0.0 &&
            poly.angularVelocity == 0.0);
    final partImmobile =
        particle.isSleeping ||
        (particle.isStatic && particle.velocity.length2 == 0.0);
    if (polyImmobile && partImmobile) return;
    final position = particle.position;
    if (!shape.boundsTouchCircle(position.x, position.y, particle.radius)) {
      return;
    }
    _collidePolygonWithParticle(shape, particle);
  }

  /// Brings [_polygonShapes] in line with [_polygons] and refreshes each.
  void _refreshPolygonShapes() {
    final polygons = _polygons;
    final shapes = _polygonShapes;
    final sap = _sapShapes;
    var membershipChanged = shapes.length != polygons.length;
    if (shapes.length > polygons.length) shapes.length = polygons.length;
    for (var i = 0; i < polygons.length; i++) {
      if (i == shapes.length) {
        shapes.add(_PolygonShape(polygons[i])..index = i);
        membershipChanged = true;
      } else {
        if (!identical(shapes[i].polygon, polygons[i])) {
          shapes[i].bind(polygons[i]);
          membershipChanged = true;
        }
        shapes[i].index = i;
      }
      shapes[i].refresh();
    }
    if (membershipChanged || sap.length != shapes.length) {
      sap
        ..clear()
        ..addAll(shapes);
    }
  }

  /// Polygon against polygon, with the separating axis test (SAT).
  ///
  /// 1. **Do they touch?** Each edge's outward direction is a candidate
  ///    gap. If the other polygon lies wholly outside any edge, they don't.
  /// 2. **Which way apart?** The edge the other polygon sinks into least is
  ///    the shortest way out: its normal, and how deep it sinks.
  /// 3. **Where?** [_findContactPoints] clips the edge that hit it.
  void _collidePolygonPair(_PolygonShape a, _PolygonShape b) {
    final (edgeA, separationA) = _shallowestEdge(a, b);
    if (separationA > 0) return;
    final (edgeB, separationB) = _shallowestEdge(b, a);
    if (separationB > 0) return;

    final referenceIsB = separationB > separationA + _referenceTolerance;
    final reference = referenceIsB ? b : a;
    final referenceEdge = referenceIsB ? edgeB : edgeA;
    final incident = referenceIsB ? a : b;
    if (!_findContactPoints(reference, referenceEdge, incident)) return;
    if (referenceIsB) _manifold.flipNormal(); // keep it pointing from a to b

    if (a.polygon.isSleeping) a.polygon.wake();
    if (b.polygon.isSleeping) b.polygon.wake();
    final overlap = _manifold.pointCount == 2
        ? math.max(_manifold.depth[0], _manifold.depth[1])
        : _manifold.depth[0];
    final nx = _manifold.normalX;
    final ny = _manifold.normalY;
    _resolve(a.polygon, b.polygon, _polygonRestitution);
    if (!a.polygon.isStatic) a.refresh();
    if (!b.polygon.isStatic) b.refresh();
    _notifyCollision(a.polygon, b.polygon, nx, ny, 0.0, overlap);
  }

  /// The edge of [shape] that [other] sinks into least, and how far: for
  /// each edge, how far [other]'s deepest corner lies outside it (negative
  /// = behind it). A positive answer means a gap — they don't touch — and
  /// the search stops there.
  (int, double) _shallowestEdge(_PolygonShape shape, _PolygonShape other) {
    var bestEdge = 0;
    var bestSeparation = double.negativeInfinity;
    for (var i = 0; i < shape.count; i++) {
      final normalX = shape.normalX[i], normalY = shape.normalY[i];
      final edgeX = shape.cornerX[i], edgeY = shape.cornerY[i];
      var deepest = double.infinity;
      for (var j = 0; j < other.count; j++) {
        final outside =
            normalX * (other.cornerX[j] - edgeX) +
            normalY * (other.cornerY[j] - edgeY);
        if (outside < deepest) deepest = outside;
      }
      if (deepest > 0) return (i, deepest);
      if (deepest > bestSeparation) {
        bestSeparation = deepest;
        bestEdge = i;
      }
    }
    return (bestEdge, bestSeparation);
  }

  /// Fills [_manifold] with where [incident] touches [reference]'s
  /// [referenceEdge], returning whether it touches at all.
  ///
  /// The incident polygon's edge that faces the reference edge most
  /// directly is cut down to the reference edge's length; its ends that
  /// have sunk behind the reference edge are the contact points. A corner
  /// poking into a face gives one point, two flat faces give two.
  bool _findContactPoints(
    _PolygonShape reference,
    int referenceEdge,
    _PolygonShape incident,
  ) {
    final normalX = reference.normalX[referenceEdge];
    final normalY = reference.normalY[referenceEdge];
    final referenceEnd = (referenceEdge + 1) % reference.count;
    final startX = reference.cornerX[referenceEdge];
    final startY = reference.cornerY[referenceEdge];
    final endX = reference.cornerX[referenceEnd];
    final endY = reference.cornerY[referenceEnd];

    var incidentEdge = 0;
    var mostFacing = double.infinity;
    for (var i = 0; i < incident.count; i++) {
      final facing =
          incident.normalX[i] * normalX + incident.normalY[i] * normalY;
      if (facing < mostFacing) {
        mostFacing = facing;
        incidentEdge = i;
      }
    }
    final incidentEnd = (incidentEdge + 1) % incident.count;
    final edge = _clippedEdge
      ..startX = incident.cornerX[incidentEdge]
      ..startY = incident.cornerY[incidentEdge]
      ..endX = incident.cornerX[incidentEnd]
      ..endY = incident.cornerY[incidentEnd];

    // Cut it to the stretch between the lines across the reference edge
    // through its two ends. The tangent runs along the edge, start to end.
    final tangentX = -normalY, tangentY = normalX;
    final startAlong = tangentX * startX + tangentY * startY;
    final endAlong = tangentX * endX + tangentY * endY;
    if (!edge.keepBehind(-tangentX, -tangentY, -startAlong)) return false;
    if (!edge.keepBehind(tangentX, tangentY, endAlong)) return false;

    _manifold.start(normalX, normalY);
    _addIfSunk(edge.startX, edge.startY, normalX, normalY, startX, startY);
    _addIfSunk(edge.endX, edge.endY, normalX, normalY, startX, startY);
    return _manifold.pointCount > 0;
  }

  /// Adds ([x], [y]) to [_manifold] if it lies behind the reference edge
  /// through ([edgeX], [edgeY]) with outward normal ([normalX], [normalY]).
  void _addIfSunk(
    double x,
    double y,
    double normalX,
    double normalY,
    double edgeX,
    double edgeY,
  ) {
    final depth = normalX * (edgeX - x) + normalY * (edgeY - y);
    if (depth >= 0) _manifold.addPoint(x, y, depth);
  }

  /// Polygon against particle: the closest point on the polygon's outline
  /// to the particle's center.
  ///
  /// The edge the center lies farthest outside of decides it. If the center
  /// is behind every edge it is inside the polygon, and leaves through the
  /// nearest edge. Otherwise the closest point is on that edge — the
  /// center's shadow on it, clamped to its ends, so past an end it is a
  /// corner.
  void _collidePolygonWithParticle(
    _PolygonShape shape,
    Flut5PhysicsParticle particle,
  ) {
    final centerX = particle.position.x, centerY = particle.position.y;
    final radius = particle.radius;

    var nearestEdge = 0;
    var outside = double.negativeInfinity;
    for (var i = 0; i < shape.count; i++) {
      final distance =
          shape.normalX[i] * (centerX - shape.cornerX[i]) +
          shape.normalY[i] * (centerY - shape.cornerY[i]);
      if (distance > radius) return; // the whole circle is past this edge
      if (distance > outside) {
        outside = distance;
        nearestEdge = i;
      }
    }
    final edgeNormalX = shape.normalX[nearestEdge];
    final edgeNormalY = shape.normalY[nearestEdge];

    if (outside <= 0) {
      // Center inside: push it out through the nearest edge.
      _manifold
        ..start(edgeNormalX, edgeNormalY)
        ..addPoint(
          centerX - edgeNormalX * outside,
          centerY - edgeNormalY * outside,
          radius - outside,
        );
    } else {
      final edgeEnd = (nearestEdge + 1) % shape.count;
      final startX = shape.cornerX[nearestEdge];
      final startY = shape.cornerY[nearestEdge];
      final edgeX = shape.cornerX[edgeEnd] - startX;
      final edgeY = shape.cornerY[edgeEnd] - startY;
      final along =
          (((centerX - startX) * edgeX + (centerY - startY) * edgeY) /
                  (edgeX * edgeX + edgeY * edgeY))
              .clamp(0.0, 1.0);
      final closestX = startX + edgeX * along;
      final closestY = startY + edgeY * along;
      final offsetX = centerX - closestX, offsetY = centerY - closestY;
      final distance = math.sqrt(offsetX * offsetX + offsetY * offsetY);
      if (distance > radius) return; // near a corner, but not touching it

      final normalX = distance > 0 ? offsetX / distance : edgeNormalX;
      final normalY = distance > 0 ? offsetY / distance : edgeNormalY;
      _manifold
        ..start(normalX, normalY)
        ..addPoint(closestX, closestY, radius - distance);
    }

    if (shape.polygon.isSleeping) shape.polygon.wake();
    if (particle.isSleeping) particle.wake();
    final overlap = _manifold.depth[0];
    final nx = _manifold.normalX;
    final ny = _manifold.normalY;
    _resolve(shape.polygon, particle, _polygonRestitution);
    if (!shape.polygon.isStatic) shape.refresh();
    _notifyCollision(shape.polygon, particle, nx, ny, 0.0, overlap);
  }

  /// Bounces every moving polygon off the enabled window edges it crossed.
  /// Runs after [_collidePolygons] in the same pass, so the shapes are
  /// fresh.
  void _collidePolygonsWithWindow() {
    final limits = _windowLimits();
    if (limits == null) return;
    for (final shape in _polygonShapes) {
      if (shape.polygon.isStatic || shape.polygon.isSleeping) continue;
      if (shape.minX < limits.left) {
        _collideWithWindowEdge(shape, .left, limits.left);
      }
      if (shape.maxX > limits.right) {
        _collideWithWindowEdge(shape, .right, limits.right);
      }
      if (shape.minY < limits.top) {
        _collideWithWindowEdge(shape, .top, limits.top);
      }
      if (shape.maxY > limits.bottom) {
        _collideWithWindowEdge(shape, .bottom, limits.bottom);
      }
    }
  }

  /// Pushes [shape] back from [edge] at [wall]: its corners past the wall
  /// are the contact points — the two deepest, so a box lying flat on the
  /// floor is held at both ends.
  void _collideWithWindowEdge(
    _PolygonShape shape,
    _WindowEdge edge,
    double wall,
  ) {
    final outward = edge.outward;
    final isSideWall = edge.axis == 0;
    _manifold.start(isSideWall ? outward : 0, isSideWall ? 0 : outward);
    for (var i = 0; i < shape.count; i++) {
      final cornerX = shape.cornerX[i], cornerY = shape.cornerY[i];
      final overshoot = ((isSideWall ? cornerX : cornerY) - wall) * outward;
      if (overshoot > 0) _manifold.addPoint(cornerX, cornerY, overshoot);
    }
    if (_manifold.pointCount == 0) return;
    _resolve(shape.polygon, _window, windowBoundsRestitution);
    shape.refresh();
  }

  /// Resolves the contact in [_manifold] between [a] and [b] with the
  /// world's settings.
  void _resolve(
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double restitution,
  ) => _manifold.resolve(
    a,
    b,
    restitution: restitution,
    friction: friction,
    rotationMode: rotationMode,
    gravity: gravity,
  );
}

/// A polygon's corners and edge normals where it is now, plus the box
/// around them. Refreshed from its position and angle before each
/// collision pass and after every push. Edge i runs from corner i to
/// corner i + 1, and normal i points out of it.
final class _PolygonShape(var Flut5PhysicsPolygon polygon) {
  this {
    _measure();
  }

  late Float64List cornerX, cornerY, normalX, normalY;
  late Float64List _localNormalX, _localNormalY;
  double minX = 0, minY = 0, maxX = 0, maxY = 0;
  int index = 0;
  double _lastX = double.nan;
  double _lastY = double.nan;
  double _lastAngle = double.nan;

  int get count => cornerX.length;

  /// Points this shape at [polygon], re-measuring if it is a different one.
  void bind(Flut5PhysicsPolygon polygon) {
    if (identical(polygon, this.polygon)) return;
    this.polygon = polygon;
    _lastX = double.nan;
    _measure();
  }

  /// Sizes the lists for [polygon] and works out its edge normals before
  /// rotation, which never change.
  void _measure() {
    final local = polygon.localCorners;
    final count = local.length;
    cornerX = Float64List(count);
    cornerY = Float64List(count);
    normalX = Float64List(count);
    normalY = Float64List(count);
    _localNormalX = Float64List(count);
    _localNormalY = Float64List(count);
    for (var i = 0; i < count; i++) {
      final start = local[i], end = local[(i + 1) % count];
      final edgeX = end.x - start.x, edgeY = end.y - start.y;
      final length = math.sqrt(edgeX * edgeX + edgeY * edgeY);
      // Corners run clockwise on screen, so the edge turned a quarter
      // counter-clockwise points out of the shape.
      _localNormalX[i] = edgeY / length;
      _localNormalY[i] = -edgeX / length;
    }
  }

  /// Turns and moves the corners and normals to where [polygon] is now.
  /// Skips all work when position and angle haven't changed (e.g. static or
  /// resting bodies) and avoids trig when [polygon.angle] is 0.
  void refresh() {
    final centerX = polygon.position.x, centerY = polygon.position.y;
    final angle = polygon.angle;
    if (centerX == _lastX && centerY == _lastY && angle == _lastAngle) return;
    _lastX = centerX;
    _lastY = centerY;
    _lastAngle = angle;

    final local = polygon.localCorners;
    minX = minY = double.infinity;
    maxX = maxY = double.negativeInfinity;
    if (angle == 0.0) {
      for (var i = 0; i < count; i++) {
        final corner = local[i];
        final x = centerX + corner.x;
        final y = centerY + corner.y;
        cornerX[i] = x;
        cornerY[i] = y;
        normalX[i] = _localNormalX[i];
        normalY[i] = _localNormalY[i];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
      return;
    }
    final cos = math.cos(angle), sin = math.sin(angle);
    for (var i = 0; i < count; i++) {
      final corner = local[i];
      final x = centerX + corner.x * cos - corner.y * sin;
      final y = centerY + corner.x * sin + corner.y * cos;
      cornerX[i] = x;
      cornerY[i] = y;
      normalX[i] = _localNormalX[i] * cos - _localNormalY[i] * sin;
      normalY[i] = _localNormalX[i] * sin + _localNormalY[i] * cos;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }

  /// Whether the boxes around this shape and [other] overlap — a cheap
  /// test that rules out most pairs before the exact one.
  bool boundsOverlap(_PolygonShape other) =>
      minX <= other.maxX &&
      maxX >= other.minX &&
      minY <= other.maxY &&
      maxY >= other.minY;

  /// Whether the box around this shape overlaps the box around a circle.
  bool boundsTouchCircle(double x, double y, double radius) =>
      x + radius >= minX &&
      x - radius <= maxX &&
      y + radius >= minY &&
      y - radius <= maxY;
}

/// A stretch of edge being cut down to where two polygons overlap.
final class _Segment() {
  double startX = 0, startY = 0, endX = 0, endY = 0;

  /// Cuts away the part of the segment in front of the line
  /// `normal · point = offset` (where `normal · point > offset`). Returns
  /// `false` if nothing is left.
  bool keepBehind(double normalX, double normalY, double offset) {
    final startAhead = normalX * startX + normalY * startY - offset;
    final endAhead = normalX * endX + normalY * endY - offset;
    if (startAhead > 0 && endAhead > 0) return false;
    if (startAhead > 0) {
      final cut = startAhead / (startAhead - endAhead);
      startX += (endX - startX) * cut;
      startY += (endY - startY) * cut;
    } else if (endAhead > 0) {
      final cut = endAhead / (endAhead - startAhead);
      endX += (startX - endX) * cut;
      endY += (startY - endY) * cut;
    }
    return true;
  }
}
