import 'package:flut5/core/flut5_console.dart';
import 'package:flut5/math/flut5_vector.dart';

/// Whether steering methods return a copy or a direct reference.
enum SteeringReturnMode() {
  /// Returns a new copy each call. Safe to store.
  copy,

  /// Returns the engine's internal scratch vector. Zero allocations, but it
  /// is overwritten by the next steering call — consume immediately.
  ref,
}

/// Steering behaviors (seek, arrive, flee, separation, cohesion) for the
/// Flut5 Engine.
///
/// The behaviors are stateless: the body being steered passes in its own
/// [Flut5Vector] position and velocity, and gets back the steering force to
/// apply. Nothing has to be mixed into the body, so any object that has a
/// position and a velocity can be steered — a `Flut5PhysicsParticle`, or a
/// class of your own:
///
/// ```dart
/// // A physics particle already integrates its own velocity.
/// ball.applyForce(seek(ball.position, ball.velocity, target));
///
/// // A hand-rolled body integrates itself.
/// acceleration.add(
///   arrive(position, velocity, target, maxVelocity: 6, maxForce: 0.3),
/// );
/// velocity.add(acceleration).limit(6);
/// position.add(velocity);
/// acceleration.mult(0);
/// ```
///
/// Every behavior computes the classic Reynolds force
/// `limit(desired - velocity, maxForce)`, where the desired velocity has
/// length [maxVelocity]. The limits are per call, so different bodies in the
/// same sketch can steer with different limits.
mixin Flut5Steering {
  // ── Return mode ───────────────────────────────────────────────────────

  SteeringReturnMode _steeringReturnMode = SteeringReturnMode.copy;

  /// Sets the return mode for every steering call on this engine — which in
  /// global mode means every caller in the sketch.
  void steeringReturnMode(SteeringReturnMode mode) =>
      _steeringReturnMode = mode;

  /// Shortcut: `true` switches to [SteeringReturnMode.ref] (faster, zero
  /// allocations), `false` back to [SteeringReturnMode.copy].
  ///
  /// ⚠ In turbo mode every call returns the same engine-owned vector, so
  /// consume each result immediately:
  /// ```dart
  /// // OK:
  /// ball.applyForce(seek(ball.position, ball.velocity, target));
  ///
  /// // BAD — f1 is overwritten by flee():
  /// final f1 = seek(ball.position, ball.velocity, target);
  /// flee(ball.position, ball.velocity, predator); // f1 is now wrong
  /// ```
  void steeringTurboMode(bool turbo) {
    if (turbo) {
      Flut5Console.printLater(
        'Steering turbo mode ON — seek/arrive/flee return a shared reference, '
        'not a copy. Consume each result immediately; never store it.',
      );
    }
    steeringReturnMode(
      turbo ? SteeringReturnMode.ref : SteeringReturnMode.copy,
    );
  }

  /// Resets the return mode to [SteeringReturnMode.copy].
  void resetSteeringMode() => _steeringReturnMode = SteeringReturnMode.copy;

  // ── Behaviors ─────────────────────────────────────────────────────────

  final Flut5Vector _desiredVelocity = Flut5Vector.zero();
  final Flut5Vector _steeringForce = Flut5Vector.zero();
  final Flut5Vector _awayFromNeighbor = Flut5Vector.zero();
  final Flut5Vector _neighborCenter = Flut5Vector.zero();

  /// The force that steers a body at [position], moving at [velocity],
  /// straight toward [target] at full speed.
  ///
  /// [maxVelocity] is the speed the body wants to travel at; [maxForce] caps
  /// the returned force. [returnCopy] overrides the [steeringReturnMode] for
  /// this call. None of the vectors passed in are modified.
  Flut5Vector seek(
    Flut5Vector position,
    Flut5Vector velocity,
    Flut5Vector target, {
    double maxVelocity = 4.0,
    double maxForce = 0.1,
    bool? returnCopy,
  }) {
    _desiredVelocity
      ..setValues(target.x, target.y, target.z)
      ..sub(position)
      ..setMag(maxVelocity);
    return _steeringForceToward(velocity, maxForce, returnCopy);
  }

  /// Like [seek], but the body slows down once it is within [slowingRadius]
  /// of [target], easing to a stop on it instead of overshooting.
  ///
  /// Inside the radius the desired speed scales linearly from [maxVelocity]
  /// at the edge to zero at [target]. [returnCopy] overrides the
  /// [steeringReturnMode] for this call. None of the vectors passed in are
  /// modified.
  Flut5Vector arrive(
    Flut5Vector position,
    Flut5Vector velocity,
    Flut5Vector target, {
    double slowingRadius = 100.0,
    double maxVelocity = 4.0,
    double maxForce = 0.1,
    bool? returnCopy,
  }) {
    _desiredVelocity
      ..setValues(target.x, target.y, target.z)
      ..sub(position);
    final double distance = _desiredVelocity.mag();
    _desiredVelocity.setMag(
      distance < slowingRadius
          ? distance / slowingRadius * maxVelocity
          : maxVelocity,
    );
    return _steeringForceToward(velocity, maxForce, returnCopy);
  }

  /// The force that steers a body at [position], moving at [velocity],
  /// directly away from [target] — [seek] with the desired velocity reversed.
  ///
  /// Note this is *not* `seek(...) * -1`: negating the whole steering force
  /// would flip the `- velocity` correction term too, and a body already
  /// moving straight at [target] at [maxVelocity] would then get zero force —
  /// no avoidance in exactly the case that matters most. Only the desired
  /// velocity is reversed.
  ///
  /// [fleeRadius] is optional. When omitted (the default) the force is always
  /// produced, no matter how far away [target] is. When given, the force is
  /// only produced while [target] is closer than the radius; beyond it the
  /// returned vector is zero.
  ///
  /// [returnCopy] overrides the [steeringReturnMode] for this call. None of
  /// the vectors passed in are modified.
  Flut5Vector flee(
    Flut5Vector position,
    Flut5Vector velocity,
    Flut5Vector target, {
    double? fleeRadius,
    double maxVelocity = 4.0,
    double maxForce = 0.1,
    bool? returnCopy,
  }) {
    if (fleeRadius != null &&
        position.distanceToSquared(target) > fleeRadius * fleeRadius) {
      return _noForce(returnCopy);
    }

    _desiredVelocity
      ..setValues(position.x, position.y, position.z)
      ..sub(target) // the reversal — seek does target - position
      ..setMag(maxVelocity);
    return _steeringForceToward(velocity, maxForce, returnCopy);
  }

  /// The force that steers a body at [position], moving at [velocity], away
  /// from crowding [neighbors] — the separation rule of a flock.
  ///
  /// Every neighbor within [separationRadius] pushes the body directly away
  /// from itself, weighted by `1 / distance`, so the closest neighbors push
  /// hardest. The summed push, at [maxVelocity], is the desired velocity, and
  /// the returned force is `limit(desired - velocity, maxForce)` like [seek].
  ///
  /// [neighbors] can include the body's own position — a neighbor at
  /// distance zero is skipped, since there is no direction to push away from
  /// it. That makes it safe to pass every body's position:
  ///
  /// ```dart
  /// final positions = boids.map((boid) => boid.position);
  /// for (final boid in boids) {
  ///   boid.applyForce(
  ///     separation(boid.position, boid.velocity, positions,
  ///         separationRadius: 25),
  ///   );
  /// }
  /// ```
  ///
  /// [separationRadius] is optional, like flee's `fleeRadius`. When omitted,
  /// every neighbor counts, however far away. When no neighbor counts, the
  /// returned vector is zero. If the pushes cancel out exactly (neighbors
  /// evenly on both sides) the desired velocity is zero, so the force brakes
  /// the body instead.
  ///
  /// [returnCopy] overrides the [steeringReturnMode] for this call. None of
  /// the vectors passed in are modified.
  Flut5Vector separation(
    Flut5Vector position,
    Flut5Vector velocity,
    Iterable<Flut5Vector> neighbors, {
    double? separationRadius,
    double maxVelocity = 4.0,
    double maxForce = 0.1,
    bool? returnCopy,
  }) {
    bool anyNeighborInRange = false;
    _desiredVelocity.setValues(0.0, 0.0, 0.0);

    for (final Flut5Vector neighbor in neighbors) {
      _awayFromNeighbor
        ..setValues(position.x, position.y, position.z)
        ..sub(neighbor);
      final double distanceSquared = _awayFromNeighbor.length2;
      if (!_isNeighborInRange(distanceSquared, separationRadius)) continue;

      // (position - neighbor) / distance² has length 1 / distance: a unit
      // push away, weighted so the closer neighbor pushes harder.
      _desiredVelocity.add(_awayFromNeighbor..scale(1.0 / distanceSquared));
      anyNeighborInRange = true;
    }

    if (!anyNeighborInRange) return _noForce(returnCopy);

    // No need to average the pushes first: setMag only keeps the direction.
    _desiredVelocity.setMag(maxVelocity);
    return _steeringForceToward(velocity, maxForce, returnCopy);
  }

  /// The force that steers a body at [position], moving at [velocity], toward
  /// the center of its [neighbors] — the cohesion rule of a flock.
  ///
  /// The center is the average of every neighbor within [cohesionRadius], and
  /// the force is [seek] toward it: full speed, so a body that reaches the
  /// center overshoots and swings back rather than settling.
  ///
  /// [neighbors] can include the body's own position — a neighbor at
  /// distance zero is skipped, like in [separation], so the same list can be
  /// passed to both:
  ///
  /// ```dart
  /// final positions = boids.map((boid) => boid.position);
  /// for (final boid in boids) {
  ///   boid.applyForce(
  ///     separation(boid.position, boid.velocity, positions,
  ///         separationRadius: 25),
  ///   );
  ///   boid.applyForce(
  ///     cohesion(boid.position, boid.velocity, positions,
  ///         cohesionRadius: 50),
  ///   );
  /// }
  /// ```
  ///
  /// [cohesionRadius] is optional. When omitted, every neighbor counts, so the
  /// center is that of the whole group. When no neighbor counts, the returned
  /// vector is zero. If the body already sits exactly on the center, the
  /// desired velocity is zero, so the force brakes the body instead.
  ///
  /// [returnCopy] overrides the [steeringReturnMode] for this call. None of
  /// the vectors passed in are modified.
  Flut5Vector cohesion(
    Flut5Vector position,
    Flut5Vector velocity,
    Iterable<Flut5Vector> neighbors, {
    double? cohesionRadius,
    double maxVelocity = 4.0,
    double maxForce = 0.1,
    bool? returnCopy,
  }) {
    int neighborsInRange = 0;
    _neighborCenter.setValues(0.0, 0.0, 0.0);

    for (final Flut5Vector neighbor in neighbors) {
      final double distanceSquared = position.distanceToSquared(neighbor);
      if (!_isNeighborInRange(distanceSquared, cohesionRadius)) continue;
      _neighborCenter.add(neighbor);
      neighborsInRange++;
    }

    if (neighborsInRange == 0) return _noForce(returnCopy);

    _neighborCenter.div(neighborsInRange.toDouble());
    return seek(
      position,
      velocity,
      _neighborCenter,
      maxVelocity: maxVelocity,
      maxForce: maxForce,
      returnCopy: returnCopy,
    );
  }

  // ── Internals ─────────────────────────────────────────────────────────

  /// Whether a neighbor [distanceSquared] away counts for [separation] and
  /// [cohesion]: it is not the body itself (distance zero) and, when a
  /// [radius] is given, it is within it.
  bool _isNeighborInRange(double distanceSquared, double? radius) =>
      distanceSquared > 0.0 &&
      (radius == null || distanceSquared <= radius * radius);

  /// Hands back a zero force, for when a behavior has nothing to react to.
  Flut5Vector _noForce(bool? returnCopy) {
    _steeringForce.setValues(0.0, 0.0, 0.0);
    return _deliver(_steeringForce, returnCopy);
  }

  /// Turns the desired velocity the caller left in [_desiredVelocity] into
  /// the steering force `limit(desired - velocity, maxForce)`.
  Flut5Vector _steeringForceToward(
    Flut5Vector velocity,
    double maxForce,
    bool? returnCopy,
  ) {
    _steeringForce
      ..setValues(_desiredVelocity.x, _desiredVelocity.y, _desiredVelocity.z)
      ..sub(velocity)
      ..limit(maxForce);
    return _deliver(_steeringForce, returnCopy);
  }

  /// Hands [force] back as a copy or as the shared reference, per
  /// [returnCopy] or, when that is null, the engine's return mode.
  Flut5Vector _deliver(Flut5Vector force, bool? returnCopy) {
    final bool shouldCopy =
        returnCopy ?? _steeringReturnMode == SteeringReturnMode.copy;
    return shouldCopy ? force.copy() : force;
  }
}
