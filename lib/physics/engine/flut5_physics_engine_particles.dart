part of 'flut5_physics_engine.dart';

/// The particle side of [Flut5PhysicsEngine]: creating particles and
/// colliding them with each other.
mixin _PhysicsParticles {
  // Provided by Flut5PhysicsEngine and its other parts.
  List<Flut5PhysicsParticle> get _particles;
  void _register(Flut5PhysicsBody body);
  PhysicsRotationMode get rotationMode;
  double get friction;
  set collisionIterations(int iterations);
  void _notifyCollision(
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double normalX,
    double normalY,
    double normalZ,
    double overlap,
  );

  /// Creates a [Flut5PhysicsParticle] at ([x], [y]), registers it and
  /// returns it.
  Flut5PhysicsParticle createParticle(double x, double y) {
    final particle = Flut5PhysicsParticle(x, y);
    _addParticle(particle);
    return particle;
  }

  /// Registers [particle] and adds it to the particle list.
  void _addParticle(Flut5PhysicsParticle particle) {
    _register(particle);
    _particles.add(particle);
  }

  bool _particleCollision = false;

  /// Makes particles bounce off each other. Off by default.
  ///
  /// Two particles touch when the distance between their centers is less
  /// than the sum of their `radius`es, so a particle with radius `0` only
  /// collides with ones that have a radius. On contact they are pushed apart
  /// until they just touch — the lighter one moving more — and, if they were
  /// approaching, exchange an impulse along the line between their centers:
  /// heavier particles push lighter ones around, and how much of their
  /// approach speed bounces back is [particleRestitution]. Particles of the
  /// same soft body never collide with each other — its springs keep them
  /// apart.
  ///
  /// Particles are sorted into a grid of cells about one particle wide, and
  /// each is only tested against the ones in its own cell and the cells
  /// around it, so the cost grows with how many particles actually touch,
  /// not with how many there are. A few particles much bigger than the rest
  /// are tested against every other instead.
  /// [iterations], if given, sets
  /// [Flut5PhysicsEngine.collisionIterations]: how many collision passes run
  /// per frame (default `2`). Turn collisions off again with
  /// [noParticleCollision].
  void particleCollision({int? iterations}) {
    if (iterations != null) collisionIterations = iterations;
    _particleCollision = true;
  }

  /// Turns off collisions between particles.
  void noParticleCollision() => _particleCollision = false;

  double _particleRestitution = 1.0;

  /// How bouncy collisions between particles are: the share of their
  /// approach speed that bounces back. `1` (default) is a perfectly elastic
  /// bounce, `0` makes them stick together along the hit; above `1` every
  /// hit adds energy. Must be >= 0. Sketches usually set it with
  /// `particleRestitution(e)`.
  double get particleRestitution => _particleRestitution;
  set particleRestitution(double restitution) {
    if (restitution < 0) {
      throw ArgumentError.value(
        restitution,
        'restitution',
        'Restitution must be >= 0',
      );
    }
    _particleRestitution = restitution;
  }

  // Every particle's position and radius, copied into flat lists while a
  // collision pass runs. The pair loop reads two particles per test, and
  // flat lists are much faster to walk than every particle's position
  // object. Index i holds _particles[i]. They grow with the particle count.
  Float64List _collisionX = Float64List(0);
  Float64List _collisionY = Float64List(0);
  Float64List _collisionZ = Float64List(0);
  Float64List _collisionRadius = Float64List(0);
  bool _collisionHasZ = false;

  /// Where the particles are, for finding the ones near each other — and,
  /// in the polygons part, the ones near a polygon.
  final _ParticleGrid _particleGrid = _ParticleGrid();

  /// Copies every particle's position and radius into the collision lists,
  /// files them in [_particleGrid] and returns it.
  _ParticleGrid _fileParticles() {
    final particles = _particles;
    final count = particles.length;
    if (_collisionX.length < count) {
      final capacity = count * 2;
      _collisionX = Float64List(capacity);
      _collisionY = Float64List(capacity);
      _collisionZ = Float64List(capacity);
      _collisionRadius = Float64List(capacity);
    }
    final positionX = _collisionX;
    final positionY = _collisionY;
    final positionZ = _collisionZ;
    final radius = _collisionRadius;
    var hasZ = false;
    for (var i = 0; i < count; i++) {
      final particle = particles[i];
      final pos = particle.position;
      positionX[i] = pos.x;
      positionY[i] = pos.y;
      final z = pos.z;
      positionZ[i] = z;
      if (z != 0.0) hasZ = true;
      radius[i] = particle.radius;
    }
    _collisionHasZ = hasZ;
    return _particleGrid..file(count, positionX, positionY, radius);
  }

  /// Separates every overlapping pair of particles and bounces the ones that
  /// are approaching each other, testing each pair that could touch once.
  ///
  /// Returns `true` when [_particleGrid] remained accurate enough (no particle
  /// was pushed past half a cell) for [_PhysicsPolygons] to reuse without
  /// re-filing.
  bool _collideParticles() {
    final grid = _fileParticles();
    // Without a radius anywhere, no two particles can touch.
    if (grid.largestRadius == 0) return true;

    if (grid.isHashed) {
      _collideNeighborsHashed(grid);
    } else {
      _collideNeighbors(grid);
    }
    _collideLargeParticles(grid);

    final particles = _particles;
    final positionX = _collisionX;
    final positionY = _collisionY;
    final positionZ = _collisionZ;
    final maxShift = grid.cellSize * 0.45;
    var gridFresh = true;
    for (var i = 0; i < particles.length; i++) {
      final pos = particles[i].position;
      final nx = positionX[i], ny = positionY[i], nz = positionZ[i];
      if (gridFresh &&
          ((nx - pos.x).abs() > maxShift || (ny - pos.y).abs() > maxShift)) {
        gridFresh = false;
      }
      pos.setValues(nx, ny, nz);
    }
    return gridFresh;
  }

  /// Collides every filed particle in a hashed [_ParticleGrid] with the rest
  /// of its own cell and the four forward neighbor cells — each pair once.
  void _collideNeighborsHashed(_ParticleGrid grid) {
    final filedParticles = grid.filedParticles;
    final filedCount = grid.filedCount;
    final cellX = grid.cellX;
    final cellY = grid.cellY;
    final hashHeads = grid.hashHeads;
    final hashNext = grid.hashNext;
    for (var slot = 0; slot < filedCount; slot++) {
      final a = filedParticles[slot];
      final cx = cellX[a], cy = cellY[a];
      // Same cell: bucket chains are in ascending creation order, so every
      // later particle in (cx, cy) sits strictly after `a` along hashNext.
      for (var b = hashNext[a]; b >= 0; b = hashNext[b]) {
        if (cellX[b] == cx && cellY[b] == cy) _collideIfTouching(a, b);
      }
      _collideHashedCell(a, grid, hashHeads, hashNext, cellX, cellY, cx + 1, cy);
      _collideHashedCell(
        a,
        grid,
        hashHeads,
        hashNext,
        cellX,
        cellY,
        cx - 1,
        cy + 1,
      );
      _collideHashedCell(a, grid, hashHeads, hashNext, cellX, cellY, cx, cy + 1);
      _collideHashedCell(
        a,
        grid,
        hashHeads,
        hashNext,
        cellX,
        cellY,
        cx + 1,
        cy + 1,
      );
    }
  }

  void _collideHashedCell(
    int a,
    _ParticleGrid grid,
    Int32List hashHeads,
    Int32List hashNext,
    Int32List cellX,
    Int32List cellY,
    int nx,
    int ny,
  ) {
    for (var b = hashHeads[grid.hashSlot(nx, ny)]; b >= 0; b = hashNext[b]) {
      if (cellX[b] == nx && cellY[b] == ny) _collideIfTouching(a, b);
    }
  }

  /// Collides every particle filed in [grid] with the ones in its own cell
  /// and in the cells around it.
  ///
  /// Each pair of cells is visited from one side only: a particle looks at
  /// the rest of its own cell, the cell to its right and the three cells
  /// below. The cells above and to its left have already looked at it.
  void _collideNeighbors(_ParticleGrid grid) {
    final columns = grid.columns;
    final rows = grid.rows;
    final cellStarts = grid.cellStarts;
    final filedParticles = grid.filedParticles;
    for (var row = 0; row < rows; row++) {
      final hasRowBelow = row + 1 < rows;
      for (var column = 0; column < columns; column++) {
        final cell = row * columns + column;
        final cellStart = cellStarts[cell];
        final cellEnd = cellStarts[cell + 1];
        if (cellStart == cellEnd) continue;

        // Cells side by side are side by side in the list too, so the rest
        // of this cell and the cell to its right are one run, and the three
        // cells below are another.
        final hasColumnRight = column + 1 < columns;
        final rightEnd = hasColumnRight ? cellStarts[cell + 2] : cellEnd;
        var belowStart = 0, belowEnd = 0;
        if (hasRowBelow) {
          final cellBelow = cell + columns;
          belowStart = cellStarts[column > 0 ? cellBelow - 1 : cellBelow];
          belowEnd =
              cellStarts[(hasColumnRight ? cellBelow + 1 : cellBelow) + 1];
        }

        for (var slot = cellStart; slot < cellEnd; slot++) {
          final particle = filedParticles[slot];
          _collideWithRun(particle, filedParticles, slot + 1, rightEnd);
          if (belowStart < belowEnd) {
            _collideWithRun(particle, filedParticles, belowStart, belowEnd);
          }
        }
      }
    }
  }

  /// Collides particle [a] with each of `others[from]` up to, not
  /// including, `others[to]`.
  void _collideWithRun(int a, Int32List others, int from, int to) {
    final particles = _particles;
    final positionX = _collisionX;
    final positionY = _collisionY;
    final radius = _collisionRadius;
    var aX = positionX[a], aY = positionY[a];
    final aRadius = radius[a];
    if (!_collisionHasZ) {
      for (var slot = from; slot < to; slot++) {
        final b = others[slot];
        final dx = positionX[b] - aX;
        final dy = positionY[b] - aY;
        final touchingDistance = aRadius + radius[b];
        if (dx * dx + dy * dy < touchingDistance * touchingDistance) {
          final aSoftBody = particles[a].softBody;
          if (aSoftBody != null && identical(aSoftBody, particles[b].softBody)) {
            continue;
          }
          if (a < b) {
            _resolveCollision(a, b);
          } else {
            _resolveCollision(b, a);
          }
          aX = positionX[a];
          aY = positionY[a];
        }
      }
      return;
    }
    final positionZ = _collisionZ;
    var aZ = positionZ[a];
    for (var slot = from; slot < to; slot++) {
      final b = others[slot];
      final dx = positionX[b] - aX;
      final dy = positionY[b] - aY;
      final dz = positionZ[b] - aZ;
      final touchingDistance = aRadius + radius[b];
      // Squared lengths: no square root for the neighbors that aren't
      // touching.
      final distanceSquared = dx * dx + dy * dy + dz * dz;
      if (distanceSquared < touchingDistance * touchingDistance) {
        // A soft body's springs hold its particles apart; colliding them
        // too would fight the springs wherever neighbors overlap.
        final aSoftBody = particles[a].softBody;
        if (aSoftBody != null && identical(aSoftBody, particles[b].softBody)) {
          continue;
        }
        // Older particle first, so two exactly on top of each other always
        // split the same way.
        if (a < b) {
          _resolveCollision(a, b);
        } else {
          _resolveCollision(b, a);
        }
        // The collision moved a; keep testing from where it is now.
        aX = positionX[a];
        aY = positionY[a];
        aZ = positionZ[a];
      }
    }
  }

  /// Collides each particle too big for [grid]'s cells with the filed
  /// particles around it, and then the big ones with each other.
  void _collideLargeParticles(_ParticleGrid grid) {
    if (grid.largeCount == 0) return;
    final largeParticles = grid.largeParticles;
    for (var slot = 0; slot < grid.largeCount; slot++) {
      _collideLargeWithFiled(largeParticles[slot], grid);
    }
    _collideLargeWithLarge(grid);
  }

  /// Collides the large particle [large] with the filed particles in the
  /// cells it can reach.
  void _collideLargeWithFiled(int large, _ParticleGrid grid) {
    final x = _collisionX[large], y = _collisionY[large];
    // A filed particle's edge is at most half a cell from its center. The
    // other half is for particles that pushes earlier in this pass moved
    // since they were filed.
    final reach = _collisionRadius[large] + grid.cellSize;
    if (!grid.isHashed) {
      final firstColumn = grid.columnAt(x - reach);
      final lastColumn = grid.columnAt(x + reach);
      final lastRow = grid.rowAt(y + reach);
      final cellStarts = grid.cellStarts;
      final columns = grid.columns;
      for (var row = grid.rowAt(y - reach); row <= lastRow; row++) {
        // Cells side by side are side by side in the list too.
        final runStart = cellStarts[row * columns + firstColumn];
        final runEnd = cellStarts[row * columns + lastColumn + 1];
        if (runStart < runEnd) {
          _collideWithRun(large, grid.filedParticles, runStart, runEnd);
        }
      }
      return;
    }
    if (!grid.hashedBoxIsWalkable(x - reach, y - reach, x + reach, y + reach)) {
      final filed = grid.filedParticles;
      for (var slot = 0; slot < grid.filedCount; slot++) {
        _collideIfTouching(large, filed[slot]);
      }
      return;
    }
    final firstColumn = grid.hashColumnAt(x - reach);
    final lastColumn = grid.hashColumnAt(x + reach);
    final lastRow = grid.hashRowAt(y + reach);
    final hashHeads = grid.hashHeads;
    final hashNext = grid.hashNext;
    final cellX = grid.cellX;
    final cellY = grid.cellY;
    for (var row = grid.hashRowAt(y - reach); row <= lastRow; row++) {
      for (var column = firstColumn; column <= lastColumn; column++) {
        for (
          var filed = hashHeads[grid.hashSlot(column, row)];
          filed >= 0;
          filed = hashNext[filed]
        ) {
          if (cellX[filed] == column && cellY[filed] == row) {
            _collideIfTouching(large, filed);
          }
        }
      }
    }
  }

  /// The large particles, kept in order along [_largeSweepsAlongY]'s axis
  /// between passes so re-sorting them is close to one walk of the list.
  Int32List _largeSweepOrder = Int32List(0);
  Float64List _largeSweepMin = Float64List(0);
  int _largeSweepCount = 0;
  bool _largeSweepsAlongY = false;

  /// Collides the large particles with each other, sweeping along whichever
  /// axis they are more spread out on so a tall column stays cheap too.
  void _collideLargeWithLarge(_ParticleGrid grid) {
    final count = grid.largeCount;
    if (count < 2) return;
    _refreshLargeSweepOrder(grid);
    final order = _largeSweepOrder;
    final radius = _collisionRadius;
    final along = _largeSweepsAlongY ? _collisionY : _collisionX;
    if (_largeSweepMin.length < count) {
      _largeSweepMin = Float64List(order.length);
    }
    final minEdge = _largeSweepMin;
    for (var i = 1; i < count; i++) {
      final particle = order[i];
      final start = along[particle] - radius[particle];
      var j = i - 1;
      while (j >= 0 && along[order[j]] - radius[order[j]] > start) {
        order[j + 1] = order[j];
        j--;
      }
      order[j + 1] = particle;
    }
    // Snapshot pre-sweep leading edges: resolving earlier pairs mutates
    // positions in place, so the break guard subtracts the maximum leftward
    // displacement observed so far instead of assuming sorted order holds.
    for (var i = 0; i < count; i++) {
      final particle = order[i];
      minEdge[i] = along[particle] - radius[particle];
    }
    var maxLeftShift = 0.0;
    for (var i = 0; i < count; i++) {
      final a = order[i];
      final minA = minEdge[i];
      for (var j = i + 1; j < count; j++) {
        if (minEdge[j] - maxLeftShift > along[a] + radius[a]) break;
        final b = order[j];
        _collideIfTouching(a, b);
        final shiftA = minA - (along[a] - radius[a]);
        if (shiftA > maxLeftShift) maxLeftShift = shiftA;
        final shiftB = minEdge[j] - (along[b] - radius[b]);
        if (shiftB > maxLeftShift) maxLeftShift = shiftB;
      }
    }
  }

  /// Brings [_largeSweepOrder] in line with [grid]'s large particles, and
  /// picks the sweep axis. Swaps axis only on a clear difference: every swap
  /// costs a full re-sort.
  void _refreshLargeSweepOrder(_ParticleGrid grid) {
    final count = grid.largeCount;
    final large = grid.largeParticles;
    var lowX = double.infinity, highX = double.negativeInfinity;
    var lowY = double.infinity, highY = double.negativeInfinity;
    for (var slot = 0; slot < count; slot++) {
      final particle = large[slot];
      final x = _collisionX[particle], y = _collisionY[particle];
      if (x < lowX) lowX = x;
      if (x > highX) highX = x;
      if (y < lowY) lowY = y;
      if (y > highY) highY = y;
    }
    final spreadX = highX - lowX, spreadY = highY - lowY;
    var orderIsStale = _largeSweepCount != count;
    if (_largeSweepsAlongY ? spreadX > spreadY * 1.25 : spreadY > spreadX * 1.25) {
      _largeSweepsAlongY = !_largeSweepsAlongY;
      orderIsStale = true;
    }
    if (!orderIsStale) {
      // Removing a particle shifts the indices after it, so an old entry can
      // point past the end of the list.
      final particleCount = _particles.length;
      for (var i = 0; i < count; i++) {
        final particle = _largeSweepOrder[i];
        if (particle >= particleCount || !grid.isLarge(particle)) {
          orderIsStale = true;
          break;
        }
      }
    }
    if (!orderIsStale) return;
    if (_largeSweepOrder.length < count) {
      _largeSweepOrder = Int32List(count * 2);
    }
    _largeSweepOrder.setRange(0, count, large);
    _largeSweepCount = count;
    final radius = _collisionRadius;
    final along = _largeSweepsAlongY ? _collisionY : _collisionX;
    // A full sort: insertion sort from creation order would be quadratic.
    Int32List.sublistView(_largeSweepOrder, 0, count).sort(
      (a, b) => (along[a] - radius[a]).compareTo(along[b] - radius[b]),
    );
  }

  /// Resolves the collision between particles [a] and [b] if they overlap.
  void _collideIfTouching(int a, int b) {
    final dx = _collisionX[b] - _collisionX[a];
    final dy = _collisionY[b] - _collisionY[a];
    final dz = _collisionZ[b] - _collisionZ[a];
    final touchingDistance = _collisionRadius[a] + _collisionRadius[b];
    final distanceSquared = dx * dx + dy * dy + dz * dz;
    if (distanceSquared >= touchingDistance * touchingDistance) return;
    final aSoftBody = _particles[a].softBody;
    if (aSoftBody != null && identical(aSoftBody, _particles[b].softBody)) {
      return;
    }
    if (a < b) {
      _resolveCollision(a, b);
    } else {
      _resolveCollision(b, a);
    }
  }

  /// Unit vector from a colliding pair's first particle to its second.
  /// Reused for every collision so resolving one allocates nothing.
  final Flut5Vector _collisionNormal = Flut5Vector.zero();

  /// Resolves overlapping particles [a] and [b] (indices into [_particles]
  /// and the collision lists) in two steps: [_correctOverlap] pushes them
  /// apart, then [_bounceApart] changes their velocities if they were
  /// approaching each other.
  void _resolveCollision(int a, int b) {
    final pa = _particles[a];
    final pb = _particles[b];
    final aImmobile =
        pa.isSleeping || (pa.isStatic && pa.velocity.length2 == 0.0);
    final bImmobile =
        pb.isSleeping || (pb.isStatic && pb.velocity.length2 == 0.0);
    if (aImmobile && bImmobile) return;
    if (pa.isSleeping) pa.wake();
    if (pb.isSleeping) pb.wake();

    final dx = _collisionX[b] - _collisionX[a];
    final dy = _collisionY[b] - _collisionY[a];
    final dz = _collisionZ[b] - _collisionZ[a];
    final distance = math.sqrt(dx * dx + dy * dy + dz * dz);

    final normal = _collisionNormal;
    if (distance > 0) {
      normal.setValues(dx / distance, dy / distance, dz / distance);
    } else {
      // Exactly on top of each other there is no direction between them;
      // split them along x so they don't stay stuck together.
      normal.setValues(1, 0, 0);
    }

    final overlap = _collisionRadius[a] + _collisionRadius[b] - distance;
    _correctOverlap(a, b, normal, overlap);
    _bounceApart(pa, pb, normal);
    _notifyCollision(pa, pb, normal.x, normal.y, normal.z, overlap);
  }

  /// Moves particles [a] and [b] apart along [normal] by [overlap] in total,
  /// so they end up just touching. The distance is split by mass: the
  /// lighter particle moves more.
  void _correctOverlap(int a, int b, Flut5Vector normal, double overlap) {
    final inverseMassA = _particles[a].inverseMass;
    final inverseMassB = _particles[b].inverseMass;
    final inverseMassSum = inverseMassA + inverseMassB;
    if (inverseMassSum == 0) return;
    final moveA = overlap * inverseMassA / inverseMassSum;
    final moveB = overlap * inverseMassB / inverseMassSum;

    _collisionX[a] -= normal.x * moveA;
    _collisionY[a] -= normal.y * moveA;
    _collisionZ[a] -= normal.z * moveA;
    _collisionX[b] += normal.x * moveB;
    _collisionY[b] += normal.y * moveB;
    _collisionZ[b] += normal.z * moveB;
  }

  /// If [a] and [b] are closing in along [normal], bounces them off each
  /// other: an equal and opposite impulse along [normal], sized by their
  /// masses and [particleRestitution]. Only the velocity along [normal]
  /// changes, so particles that graze each other keep sliding past — unless
  /// [rotationMode] is [PhysicsRotationMode.physical], where friction then
  /// grips them and sets them spinning.
  void _bounceApart(
    Flut5PhysicsParticle a,
    Flut5PhysicsParticle b,
    Flut5Vector normal,
  ) {
    final inverseMassA = a.inverseMass;
    final inverseMassB = b.inverseMass;
    final inverseMassSum = inverseMassA + inverseMassB;
    if (inverseMassSum == 0) return;

    final velocityA = a.velocity;
    final velocityB = b.velocity;
    // How fast b moves away from a along the normal (a dot product).
    final separatingSpeed =
        (velocityB.x - velocityA.x) * normal.x +
        (velocityB.y - velocityA.y) * normal.y +
        (velocityB.z - velocityA.z) * normal.z;
    if (separatingSpeed >= 0) return; // already moving apart

    final impulse =
        -(1 + _particleRestitution) * separatingSpeed / inverseMassSum;
    final changeA = impulse * inverseMassA;
    final changeB = impulse * inverseMassB;
    velocityA
      ..x -= normal.x * changeA
      ..y -= normal.y * changeA
      ..z -= normal.z * changeA;
    velocityB
      ..x += normal.x * changeB
      ..y += normal.y * changeB
      ..z += normal.z * changeB;

    if (rotationMode == .physical) {
      _rubParticles(a, b, normal, impulse, friction);
    }
  }
}
