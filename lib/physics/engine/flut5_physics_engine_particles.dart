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
    _sweepOrderStale = true;
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
  /// Particles are swept left to right, and each is only tested against the
  /// ones that start before it ends, so particles spread across the window
  /// are cheap. The cost grows with how many share the same strip of x: a
  /// crowd stacked in one column costs as much as testing every pair.
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

  // Every particle's position and radius, copied into flat lists while the
  // collision passes run. The pair loop reads two particles per test, and
  // flat lists are much faster to walk than every particle's position
  // object. Index i holds _particles[i]. They grow with the particle count.
  Float64List _collisionX = Float64List(0);
  Float64List _collisionY = Float64List(0);
  Float64List _collisionZ = Float64List(0);
  Float64List _collisionRadius = Float64List(0);

  // Particle indices sorted by left edge (x - radius), so the pair loop can
  // stop looking for partners once they start past a particle's right edge.
  // Kept between passes: particles barely move in one, so the last order
  // needs only a few swaps to be right again.
  Int32List _sweepOrder = Int32List(0);

  /// Set when a particle is created, so [_sortByLeftEdge] starts over even
  /// if a removal in the same frame kept the count the same.
  bool _sweepOrderStale = true;

  /// Separates every overlapping pair of particles and bounces the ones that
  /// are approaching each other, testing each pair that could touch once.
  void _collideParticles() {
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

    for (var i = 0; i < count; i++) {
      final particle = particles[i];
      positionX[i] = particle.position.x;
      positionY[i] = particle.position.y;
      positionZ[i] = particle.position.z;
      radius[i] = particle.radius;
    }

    _sortByLeftEdge(count);
    final order = _sweepOrder;
    for (var i = 0; i < count; i++) {
      final a = order[i];
      // Particle a's position and radius, held in locals while it is tested
      // against the particles that start to its right.
      var aX = positionX[a], aY = positionY[a], aZ = positionZ[a];
      final aRadius = radius[a];
      final aSoftBody = particles[a].softBody;
      var aRightEdge = aX + aRadius;
      for (var j = i + 1; j < count; j++) {
        final b = order[j];
        final bX = positionX[b];
        final bRadius = radius[b];
        // b and every particle after it start past a's right edge.
        if (bX - bRadius > aRightEdge) break;
        final dx = bX - aX;
        final dy = positionY[b] - aY;
        final dz = positionZ[b] - aZ;
        final touchingDistance = aRadius + bRadius;
        // Squared lengths: no square root for the pairs that overlap in x
        // but are nowhere near each other.
        final distanceSquared = dx * dx + dy * dy + dz * dz;
        if (distanceSquared < touchingDistance * touchingDistance) {
          // A soft body's springs hold its particles apart; colliding them
          // too would fight the springs wherever neighbors overlap.
          if (aSoftBody != null &&
              identical(aSoftBody, particles[b].softBody)) {
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
          aRightEdge = aX + aRadius;
        }
      }
    }

    for (var i = 0; i < count; i++) {
      particles[i].position.setValues(positionX[i], positionY[i], positionZ[i]);
    }
  }

  /// Sorts [_sweepOrder] by each particle's left edge where it is now.
  ///
  /// After particles are created or removed the indices it holds shift onto
  /// other particles, leaving it too scrambled for a quick fix, so it is
  /// rebuilt and fully sorted. Otherwise last pass's order is nearly right,
  /// and an insertion sort fixes it by moving the few particles that
  /// overtook a neighbor.
  void _sortByLeftEdge(int count) {
    final positionX = _collisionX;
    final radius = _collisionRadius;
    if (_sweepOrderStale || _sweepOrder.length != count) {
      _sweepOrderStale = false;
      final order = _sweepOrder = Int32List(count);
      for (var i = 0; i < count; i++) {
        order[i] = i;
      }
      order.sort(
        (p, q) =>
            (positionX[p] - radius[p]).compareTo(positionX[q] - radius[q]),
      );
      return;
    }

    final order = _sweepOrder;
    for (var i = 1; i < count; i++) {
      final moving = order[i];
      final leftEdge = positionX[moving] - radius[moving];
      var slot = i;
      while (slot > 0) {
        final previous = order[slot - 1];
        if (positionX[previous] - radius[previous] <= leftEdge) break;
        order[slot] = previous;
        slot--;
      }
      order[slot] = moving;
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
    _bounceApart(_particles[a], _particles[b], normal);
  }

  /// Moves particles [a] and [b] apart along [normal] by [overlap] in total,
  /// so they end up just touching. The distance is split by mass: the
  /// lighter particle moves more.
  void _correctOverlap(int a, int b, Flut5Vector normal, double overlap) {
    final inverseMassA = 1 / _particles[a].mass;
    final inverseMassB = 1 / _particles[b].mass;
    final inverseMassSum = inverseMassA + inverseMassB;
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
    final velocityA = a.velocity;
    final velocityB = b.velocity;
    // How fast b moves away from a along the normal (a dot product).
    final separatingSpeed =
        (velocityB.x - velocityA.x) * normal.x +
        (velocityB.y - velocityA.y) * normal.y +
        (velocityB.z - velocityA.z) * normal.z;
    if (separatingSpeed >= 0) return; // already moving apart

    final inverseMassA = 1 / a.mass;
    final inverseMassB = 1 / b.mass;
    final impulse =
        -(1 + _particleRestitution) *
        separatingSpeed /
        (inverseMassA + inverseMassB);
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
