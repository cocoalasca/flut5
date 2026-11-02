part of 'flut5_physics_engine.dart';

/// The particle side of [Flut5PhysicsEngine]: creating particles and
/// colliding them with each other.
mixin _PhysicsParticles {
  // Provided by Flut5PhysicsEngine and its other parts.
  List<Flut5PhysicsParticle> get _particles;
  void _register(Flut5PhysicsBody body);
  PhysicsRotationMode get rotationMode;
  double get friction;

  /// Creates a [Flut5PhysicsParticle] at ([x], [y]), registers it and
  /// returns it.
  Flut5PhysicsParticle createParticle(double x, double y) {
    final particle = Flut5PhysicsParticle(x, y);
    _register(particle);
    _particles.add(particle);
    return particle;
  }

  bool _particleCollision = false;
  int _collisionIterations = 2;

  /// Makes particles bounce off each other. Off by default.
  ///
  /// Two particles touch when the distance between their centers is less
  /// than the sum of their `radius`es, so a particle with radius `0` only
  /// collides with ones that have a radius. On contact they are pushed apart
  /// until they just touch — the lighter one moving more — and, if they were
  /// approaching, exchange an impulse along the line between their centers:
  /// heavier particles push lighter ones around, and how much of their
  /// approach speed bounces back is [particleRestitution].
  ///
  /// Every pair is tested each frame, so the cost grows with the square of
  /// the particle count. [iterations] repeats the collision pass (and the
  /// window walls, if on) that many times per frame: piles and stacks
  /// overlap less and settle faster with more, at that many times the cost.
  /// Defaults to `2`; `1` is the plain single pass. Turn collisions off again
  /// with [noParticleCollision].
  void particleCollision({int iterations = 2}) {
    if (iterations < 1) {
      throw ArgumentError.value(iterations, 'iterations', 'Must be >= 1');
    }
    _particleCollision = true;
    _collisionIterations = iterations;
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

  /// Separates every overlapping pair of particles and bounces the ones that
  /// are approaching each other, testing each pair once.
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

    for (var a = 0; a < count; a++) {
      // Particle a's position and radius, held in locals while it is tested
      // against every later particle.
      var aX = positionX[a], aY = positionY[a], aZ = positionZ[a];
      final aRadius = radius[a];
      for (var b = a + 1; b < count; b++) {
        final dx = positionX[b] - aX;
        final dy = positionY[b] - aY;
        final dz = positionZ[b] - aZ;
        final touchingDistance = aRadius + radius[b];
        // Squared lengths: no square root for the many pairs that are
        // nowhere near each other.
        final distanceSquared = dx * dx + dy * dy + dz * dz;
        if (distanceSquared < touchingDistance * touchingDistance) {
          _resolveCollision(a, b);
          // The collision moved a; keep testing from where it is now.
          aX = positionX[a];
          aY = positionY[a];
          aZ = positionZ[a];
        }
      }
    }

    for (var i = 0; i < count; i++) {
      particles[i].position.setValues(positionX[i], positionY[i], positionZ[i]);
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
