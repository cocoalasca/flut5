part of 'flut5_physics_engine.dart';

/// The soft-body side of [Flut5PhysicsEngine]: creating soft bodies and
/// pulling them back into shape. Their particles are stepped and collided
/// by the other parts like any particle.
///
/// Soft-body springs move their particles straight to where they should be
/// instead of pushing with a force: forces stiff enough to hold a body up
/// under gravity overshoot at one step per frame and blow it apart. Each
/// move is added to the particles' velocity too, so the body carries on
/// the way the springs pulled it — and since a pull never goes past the
/// rest length, the wobble dies down on its own. Areas and the rest shape
/// pull the same way.
mixin _PhysicsSoftBodies {
  // Provided by Flut5PhysicsEngine and its other parts.
  List<Flut5PhysicsSoftBody> get _softBodies;
  Set<Flut5PhysicsBody> get _registered;
  Set<Flut5PhysicsSoftBody> get _tornSoftBodies;
  void _register(Flut5PhysicsBody body);
  void _addParticle(Flut5PhysicsParticle particle);

  /// Creates a [width] × [height] [Flut5PhysicsSoftRect] centered on ([x],
  /// [y]) — a grid of particles held together by springs — registers it
  /// and its particles, and returns it.
  ///
  /// - [resolution]: particles along the longer side (default `8`, at
  ///   least `2`); the shorter side gets as many as keep the grid square.
  /// - [particleRadius]: each particle's `radius`. Defaults to half the gap
  ///   between neighbors, so they just touch.
  /// - [stiffness]: how firmly the body holds its shape, from `0` (loose
  ///   particles) to `1` (barely gives). Defaults to `0.3`.
  ///
  /// ```dart
  /// final jelly = physicsEngine.createSoftRect(
  ///   200, 100, 160, 100,
  ///   resolution: 10, particleRadius: 6, stiffness: 0.2,
  /// );
  /// ```
  Flut5PhysicsSoftRect createSoftRect(
    double x,
    double y,
    double width,
    double height, {
    int resolution = 8,
    double? particleRadius,
    double stiffness = 0.3,
  }) {
    final softRect = Flut5PhysicsSoftRect(
      x,
      y,
      width,
      height,
      resolution: resolution,
      particleRadius: particleRadius,
      stiffness: stiffness,
    );
    _addSoftBody(softRect);
    return softRect;
  }

  /// Creates a hollow soft body shaped like the closed outline through
  /// [corners], relative to ([x], [y]) — a blob, a star, a letter: any
  /// outline that doesn't cross itself — registers it and its particles,
  /// and returns it. See [Flut5PhysicsSoftBody.polygon].
  ///
  /// - [resolution]: particles around the outline. Every corner gets one;
  ///   the rest are spread along the edges. Defaults to one per corner.
  /// - [particleRadius]: each particle's `radius`. Defaults to half the
  ///   shortest gap around the outline, so neighbors just touch.
  /// - [stiffness]: how firmly it holds its shape, from `0` to `1`.
  ///   Defaults to `0.3`.
  ///
  /// ```dart
  /// final star = physicsEngine.createSoftPolygon(200, 100, [
  ///   for (var i = 0; i < 10; i++)
  ///     Flut5Vector.fromAngle(i * PI / 5, i.isEven ? 60 : 25),
  /// ], resolution: 40);
  /// ```
  Flut5PhysicsSoftBody createSoftPolygon(
    double x,
    double y,
    List<Flut5Vector> corners, {
    int? resolution,
    double? particleRadius,
    double stiffness = 0.3,
  }) => _addSoftBody(
    Flut5PhysicsSoftBody.polygon(
      x,
      y,
      corners,
      resolution: resolution,
      particleRadius: particleRadius,
      stiffness: stiffness,
    ),
  );

  /// Creates a round hollow soft body — a blob — of [radius] centered on
  /// ([x], [y]), with [resolution] particles around it (default `24`),
  /// registers it and its particles, and returns it. See
  /// [createSoftPolygon] for the rest.
  Flut5PhysicsSoftBody createSoftCircle(
    double x,
    double y,
    double radius, {
    int resolution = 24,
    double? particleRadius,
    double stiffness = 0.3,
  }) => _addSoftBody(
    Flut5PhysicsSoftBody.circle(
      x,
      y,
      radius,
      resolution: resolution,
      particleRadius: particleRadius,
      stiffness: stiffness,
    ),
  );

  /// Creates a soft body with your own structure, registers it and its
  /// particles, and returns it: a particle at each of [points] (relative to
  /// ([x], [y])), with [springs], [areas] and [outline] as indices into
  /// [points], and [keepShape] to pull it back to the shape [points] make.
  /// See [Flut5PhysicsSoftBody.new].
  Flut5PhysicsSoftBody createSoftBody(
    double x,
    double y,
    List<Flut5Vector> points, {
    List<(int, int)> springs = const [],
    List<List<int>> areas = const [],
    List<int> outline = const [],
    bool keepShape = true,
    double? particleRadius,
    double stiffness = 0.3,
  }) => _addSoftBody(
    Flut5PhysicsSoftBody(
      x,
      y,
      points,
      springs: springs,
      areas: areas,
      outline: outline,
      keepShape: keepShape,
      particleRadius: particleRadius,
      stiffness: stiffness,
    ),
  );

  /// What the solver keeps for each soft body, worked out once when it is
  /// created.
  final Expando<_SoftBodySolving> _solving = Expando('soft body solving');

  /// Registers [body] and its particles, and returns it.
  T _addSoftBody<T extends Flut5PhysicsSoftBody>(T body) {
    _register(body);
    _softBodies.add(body);
    for (final particle in body.particles) {
      _addParticle(particle);
    }
    _solving[body] = _SoftBodySolving(body, pullsPerPass: _pullsFor(body));
    return body;
  }

  /// A push spreads only a spring or two into a body per pull, so a body
  /// many springs across is pulled more often, to be about as firm as a
  /// coarse one at the same stiffness: once per four springs it takes to
  /// cross it.
  int _pullsFor(Flut5PhysicsSoftBody body) {
    var shortestSpring = double.infinity;
    for (final spring in body.springs) {
      if (spring.restLength > 0) {
        shortestSpring = math.min(shortestSpring, spring.restLength);
      }
    }
    if (!shortestSpring.isFinite) return 1;
    var left = double.infinity, right = double.negativeInfinity;
    var top = double.infinity, bottom = double.negativeInfinity;
    for (final particle in body.particles) {
      left = math.min(left, particle.x);
      right = math.max(right, particle.x);
      top = math.min(top, particle.y);
      bottom = math.max(bottom, particle.y);
    }
    final across = math.max(right - left, bottom - top);
    // A hair over, so a body exactly 8 springs across counts as 8, not 7.99…
    final springsAcross = (across / shortestSpring + 1e-6).floor();
    return math.max(1, springsAcross ~/ 4);
  }

  /// One collision pass's worth of pulling every soft body back into shape.
  void _reshapeSoftBodies() {
    final tornBodies = _tornSoftBodies;
    for (final body in _softBodies) {
      final stiffness = body.stiffness;
      if (stiffness == 0) continue;
      // Only a torn body checks whether each spring still has both ends.
      final torn = tornBodies.isNotEmpty && tornBodies.contains(body);
      final solving = _solving[body]!;
      final spin = _measureSpin(body, torn);
      for (var pull = 0; pull < solving.pullsPerPass; pull++) {
        _pullSprings(body, stiffness, torn);
        _keepAreas(body, stiffness, torn);
      }
      // Once per pass however fine the body: it moves every particle at
      // once, so it needs no time to spread.
      if (body.keepShape) _keepRestShape(body, solving, stiffness, torn);
      _restoreSpin(body, spin, torn);
    }
  }

  /// Pulls every particle of [body] toward its place in the body's rest
  /// shape, closing [stiffness] of the gap — shape matching.
  ///
  /// The rest shape is first laid over the body: moved onto its center of
  /// mass and turned to fit the particles as closely as it can. So this
  /// only undoes bending and squashing, never where the body is or which
  /// way it faces. Springs and areas only reach a step or two through the
  /// body; this holds the whole shape at once, so it can't sag, fold or
  /// turn inside out.
  void _keepRestShape(
    Flut5PhysicsSoftBody body,
    _SoftBodySolving solving,
    double stiffness,
    bool torn,
  ) {
    final particles = body.particles;
    final restX = solving.restX, restY = solving.restY;
    var mass = 0.0;
    var centerX = 0.0, centerY = 0.0;
    var restCenterX = 0.0, restCenterY = 0.0;
    for (var i = 0; i < particles.length; i++) {
      final particle = particles[i];
      if (torn && !_registered.contains(particle)) continue;
      final particleMass = particle.mass;
      mass += particleMass;
      centerX += particleMass * particle.position.x;
      centerY += particleMass * particle.position.y;
      restCenterX += particleMass * restX[i];
      restCenterY += particleMass * restY[i];
    }
    if (mass == 0) return;
    centerX /= mass;
    centerY /= mass;
    restCenterX /= mass;
    restCenterY /= mass;

    // The turn that best lays the rest shape over the particles: summed
    // over every particle, how far its offset from the center now is
    // turned from its offset at rest, weighted by mass and distance.
    var turnedSine = 0.0, turnedCosine = 0.0;
    for (var i = 0; i < particles.length; i++) {
      final particle = particles[i];
      if (torn && !_registered.contains(particle)) continue;
      final restOffsetX = restX[i] - restCenterX;
      final restOffsetY = restY[i] - restCenterY;
      final offsetX = particle.position.x - centerX;
      final offsetY = particle.position.y - centerY;
      turnedSine +=
          particle.mass * (restOffsetX * offsetY - restOffsetY * offsetX);
      turnedCosine +=
          particle.mass * (restOffsetX * offsetX + restOffsetY * offsetY);
    }
    final turn = math.atan2(turnedSine, turnedCosine);
    final cosine = math.cos(turn), sine = math.sin(turn);

    for (var i = 0; i < particles.length; i++) {
      final particle = particles[i];
      if (torn && !_registered.contains(particle)) continue;
      final restOffsetX = restX[i] - restCenterX;
      final restOffsetY = restY[i] - restCenterY;
      final goalX = centerX + restOffsetX * cosine - restOffsetY * sine;
      final goalY = centerY + restOffsetX * sine + restOffsetY * cosine;
      _nudge(
        particle,
        goalX - particle.position.x,
        goalY - particle.position.y,
        0,
        stiffness,
      );
    }
  }

  /// [body]'s center of mass and its angular momentum around it, in the
  /// screen plane, counting only particles still registered when [torn].
  _Spin _measureSpin(Flut5PhysicsSoftBody body, bool torn) {
    var mass = 0.0, centerX = 0.0, centerY = 0.0;
    for (final particle in body.particles) {
      if (torn && !_registered.contains(particle)) continue;
      mass += particle.mass;
      centerX += particle.mass * particle.position.x;
      centerY += particle.mass * particle.position.y;
    }
    if (mass == 0) return (centerX: 0, centerY: 0, angularMomentum: 0);
    centerX /= mass;
    centerY /= mass;
    return (
      centerX: centerX,
      centerY: centerY,
      angularMomentum: _angularMomentum(body, centerX, centerY, torn),
    );
  }

  /// Sets [body]'s angular momentum back to what [before] measured, by
  /// spinning it as a whole around its center of mass.
  ///
  /// Pulls only push a body's particles against each other, so like any
  /// internal force they shouldn't turn it. They come close: each pull's
  /// push is exactly balanced, but adding it to the velocity of particles
  /// already moving still nudges the total spin a little. Uncorrected, a
  /// squashed body floating free would come back into shape slowly turning
  /// and never stop.
  void _restoreSpin(Flut5PhysicsSoftBody body, _Spin before, bool torn) {
    final (:centerX, :centerY, :angularMomentum) = before;
    // The pulls never move the center of mass, so it is still the center.
    final gained =
        _angularMomentum(body, centerX, centerY, torn) - angularMomentum;
    var inertia = 0.0;
    for (final particle in body.particles) {
      if (torn && !_registered.contains(particle)) continue;
      final offsetX = particle.position.x - centerX;
      final offsetY = particle.position.y - centerY;
      inertia += particle.mass * (offsetX * offsetX + offsetY * offsetY);
    }
    if (inertia == 0) return;

    // Turning the body at this many radians per frame takes the gain back
    // out, without moving its center of mass.
    final correction = -gained / inertia;
    for (final particle in body.particles) {
      if (torn && !_registered.contains(particle)) continue;
      particle.velocity
        ..x -= correction * (particle.position.y - centerY)
        ..y += correction * (particle.position.x - centerX);
    }
  }

  /// [body]'s angular momentum around ([centerX], [centerY]), clockwise on
  /// screen.
  double _angularMomentum(
    Flut5PhysicsSoftBody body,
    double centerX,
    double centerY,
    bool torn,
  ) {
    var angularMomentum = 0.0;
    for (final particle in body.particles) {
      if (torn && !_registered.contains(particle)) continue;
      final offsetX = particle.position.x - centerX;
      final offsetY = particle.position.y - centerY;
      angularMomentum +=
          particle.mass *
          (offsetX * particle.velocity.y - offsetY * particle.velocity.x);
    }
    return angularMomentum;
  }

  /// Pulls each spring of [body] once, closing [stiffness] of the gap
  /// between its length and its rest length.
  void _pullSprings(Flut5PhysicsSoftBody body, double stiffness, bool torn) {
    for (final spring in body.springs) {
      final a = spring.a, b = spring.b;
      if (torn && !(_registered.contains(a) && _registered.contains(b))) {
        continue;
      }
      _pullSpring(a, b, spring.restLength, stiffness);
    }
  }

  /// Moves [a] and [b] along the line between them, closing [stiffness] of
  /// the gap between their distance and [restLength]. The lighter particle
  /// moves more.
  void _pullSpring(
    Flut5PhysicsParticle a,
    Flut5PhysicsParticle b,
    double restLength,
    double stiffness,
  ) {
    final positionA = a.position, positionB = b.position;
    final dx = positionB.x - positionA.x;
    final dy = positionB.y - positionA.y;
    final dz = positionB.z - positionA.z;
    final length = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (length == 0) return; // no direction to pull along

    final inverseMassA = a.inverseMass, inverseMassB = b.inverseMass;
    // Per unit of the (unnormalized) a→b vector: positive pulls them
    // together, negative pushes them apart.
    final pull =
        stiffness *
        (length - restLength) /
        (length * (inverseMassA + inverseMassB));
    _nudge(a, dx, dy, dz, pull * inverseMassA);
    _nudge(b, dx, dy, dz, -pull * inverseMassB);
  }

  /// Pulls each area of [body] once toward its starting area, closing
  /// [stiffness] of the gap.
  ///
  /// Springs alone can't tell a shape from its mirror image — a cell folded
  /// inside out has the same side lengths — so a hard landing could flip
  /// part of a body over and leave it folded. An area's sign flips with it,
  /// and this pulls it back.
  void _keepAreas(Flut5PhysicsSoftBody body, double stiffness, bool torn) {
    for (final area in body.areas) {
      final loop = area.particles;
      if (torn && !loop.every(_registered.contains)) continue;
      _keepArea(loop, area.restArea, stiffness);
    }
  }

  // How fast each corner of the loop being reshaped changes its area, per
  // pixel it moves along x and y. Grows with the longest loop.
  Float64List _areaGrowthX = Float64List(0);
  Float64List _areaGrowthY = Float64List(0);

  /// Moves the particles around [loop] (in order, either way round),
  /// closing [stiffness] of the gap between the area inside and
  /// [restArea] — signed like [Flut5PhysicsSoftArea.restArea]. The lighter
  /// particles move more.
  ///
  /// Each particle moves square to the line between its two neighbors,
  /// which changes the area fastest: by half that line's length per pixel.
  void _keepArea(
    List<Flut5PhysicsParticle> loop,
    double restArea,
    double stiffness,
  ) {
    final count = loop.length;
    if (_areaGrowthX.length < count) {
      _areaGrowthX = Float64List(count * 2);
      _areaGrowthY = Float64List(count * 2);
    }
    final growthX = _areaGrowthX, growthY = _areaGrowthY;

    var doubleArea = 0.0;
    var resistance = 0.0;
    for (var i = 0; i < count; i++) {
      final previous = loop[i == 0 ? count - 1 : i - 1].position;
      final current = loop[i].position;
      final next = loop[i == count - 1 ? 0 : i + 1].position;
      doubleArea += current.x * next.y - next.x * current.y;
      final alongX = 0.5 * (next.y - previous.y);
      final alongY = 0.5 * (previous.x - next.x);
      growthX[i] = alongX;
      growthY[i] = alongY;
      resistance += loop[i].inverseMass * (alongX * alongX + alongY * alongY);
    }
    if (resistance == 0) return; // squashed to a point: no way to grow

    final change = stiffness * (restArea - doubleArea / 2) / resistance;
    for (var i = 0; i < count; i++) {
      final particle = loop[i];
      _nudge(
        particle,
        growthX[i],
        growthY[i],
        0,
        change * particle.inverseMass,
      );
    }
  }

  /// Moves [particle] by ([x], [y], [z]) × [scale] and adds the same to its
  /// velocity, so it keeps going the way it was pulled.
  void _nudge(
    Flut5PhysicsParticle particle,
    double x,
    double y,
    double z,
    double scale,
  ) {
    final moveX = x * scale, moveY = y * scale, moveZ = z * scale;
    particle.position
      ..x += moveX
      ..y += moveY
      ..z += moveZ;
    particle.velocity
      ..x += moveX
      ..y += moveY
      ..z += moveZ;
  }
}

/// A soft body's center of mass and its angular momentum around it, taken
/// before its pulls so [_PhysicsSoftBodies._restoreSpin] can undo any spin
/// they add.
typedef _Spin = ({double centerX, double centerY, double angularMomentum});

/// What [Flut5PhysicsEngine] keeps for each soft body it pulls into shape.
final class _SoftBodySolving {
  _SoftBodySolving(Flut5PhysicsSoftBody body, {required this.pullsPerPass})
    : restX = Float64List.fromList([for (final p in body.particles) p.x]),
      restY = Float64List.fromList([for (final p in body.particles) p.y]);

  /// How many times per collision pass its springs and areas are pulled.
  final int pullsPerPass;

  /// Where each particle was when the body was made: its rest shape.
  final Float64List restX;
  final Float64List restY;
}
