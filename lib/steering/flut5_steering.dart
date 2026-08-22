import 'package:flut5/core/flut5_console.dart';
import 'package:flut5/math/flut5_vector.dart';

/// Whether steering methods return a copy or a direct reference.
enum SteeringReturnMode {
  /// Returns a new copy each call. Safe to store.
  copy,

  /// Returns the internal reference. Zero allocations but overwritten
  /// on the next steering call — consume immediately.
  ref,
}

/// Steering behaviors (seek, arrive, flee) with built-in physics.
///
/// Includes position, velocity, acceleration, and integration —
/// no additional mixin required.
///
/// ```dart
/// boid.applyForce(boid.seek(target));
/// boid.applyForce(boid.flee(predator));
/// boid.updateSteering();
/// ```
mixin Flut5Steering {
  // ── Physics properties ────────────────────────────────────────────────

  /// Current position.
  final Flut5Vector position = Flut5Vector.createVector();

  /// Current velocity.
  final Flut5Vector velocity = Flut5Vector.createVector();

  /// Current acceleration. Reset to zero after [updateNavigation].
  final Flut5Vector acceleration = Flut5Vector.createVector();

  // ── Limits ────────────────────────────────────────────────────────────

  /// Maximum speed.
  double maxVelocity = 4.0;

  /// Maximum steering force per frame.
  double maxForce = 0.1;

  /// Per-frame velocity multiplier. `1.0` (default) applies no damping;
  /// `0.0` fully stops velocity every frame; values in between bleed off
  /// speed over time. Set via [setDamping].
  double damping = 1.0;

  // ── Navigation API ────────────────────────────────────────────────────

  /// Sets [maxVelocity] and [maxForce]. Both are optional — omit one to leave
  /// it as it was.
  ///
  /// The two interact: [maxForce] caps how much velocity can change per frame,
  /// so raising [maxVelocity] alone makes a body slower to reach its new top
  /// speed rather than more responsive. Prefer passing both when retuning.
  void configSteering({double? maxVelocity, double? maxForce}) {
    if (maxVelocity != null) this.maxVelocity = maxVelocity;
    if (maxForce != null) this.maxForce = maxForce;
  }

  /// Sets [damping]. Call as `boid.setDamping(0.98)` from your sketch.
  void setDamping(double damping) => this.damping = damping;

  /// Accumulates [force] into [acceleration].
  void applyForce(Flut5Vector force) {
    acceleration.add(force);
  }

  /// Sugar for [updateNavigation].
  void updateSteering() => updateNavigation();

  /// Integrates one frame: acceleration → velocity → position, then
  /// clears acceleration.
  void updateNavigation() {
    velocity.add(acceleration);
    velocity.mult(damping);
    velocity.limit(maxVelocity);
    position.add(velocity);
    acceleration.mult(0);
  }

  // ── Return mode (global) ──────────────────────────────────────────────

  /// Global return mode shared by every object mixing in [Flut5Steering].
  ///
  /// Static by design: turbo mode is a single, process-wide switch rather than
  /// a per-instance setting. Flipping it affects every boid/particle at once.
  static SteeringReturnMode _steeringReturnMode = SteeringReturnMode.copy;

  /// Sets the global return mode for all steering methods, across every
  /// instance. Call as `Flut5Steering.steeringReturnMode(...)`.
  static void steeringReturnMode(SteeringReturnMode mode) =>
      _steeringReturnMode = mode;

  /// Global shortcut: `true` enables [SteeringReturnMode.ref] (faster, zero
  /// allocs) for every instance. Call as `Flut5Steering.steeringTurboMode(...)`.
  ///
  /// ⚠ In turbo mode, consume results immediately:
  /// ```dart
  /// // OK:
  /// boid.applyForce(boid.seek(target));
  ///
  /// // BAD — f1 is overwritten by flee():
  /// final f1 = boid.seek(target);
  /// boid.flee(predator); // f1 is now wrong
  /// ```
  static void steeringTurboMode(bool turbo) {
    if (turbo) {
      Flut5Console.printLater(
        'Turbo mode ON (global) — steering returns refs, not copies for every '
        'instance. Consume each result immediately; never store the reference.',
      );
    }
    steeringReturnMode(
      turbo ? SteeringReturnMode.ref : SteeringReturnMode.copy,
    );
  }

  /// Resets the global return mode to [SteeringReturnMode.copy]. Since the mode
  /// is a process-wide static, call this in test `tearDown` (or between sketches)
  /// so turbo mode set by one context does not leak into the next.
  static void resetSteeringMode() =>
      _steeringReturnMode = SteeringReturnMode.copy;

  // ── Internal cached vectors ───────────────────────────────────────────

  final Flut5Vector _desired = Flut5Vector.createVector();
  final Flut5Vector _steer = Flut5Vector.createVector();

  bool _shouldCopy(bool? returnCopy) =>
      returnCopy ?? (_steeringReturnMode == .copy);

  /// Steers toward [target] at max speed.
  ///
  /// [returnCopy] overrides the global mode for this call.
  Flut5Vector seek(Flut5Vector target, {bool? returnCopy}) {
    _desired.setValues(target.x, target.y, target.z);
    _desired.sub(position);
    _desired.setMag(maxVelocity);

    _steer.setValues(_desired.x, _desired.y, _desired.z);
    _steer.sub(velocity);
    _steer.limit(maxForce);
    return _shouldCopy(returnCopy) ? _steer.copy() : _steer;
  }

  /// Steers toward [target], slowing within [slowingRadius].
  ///
  /// [returnCopy] overrides the global mode for this call.
  Flut5Vector arrive(
    Flut5Vector target, {
    double slowingRadius = 100.0,
    bool? returnCopy,
  }) {
    _desired.setValues(target.x, target.y, target.z);
    _desired.sub(position);

    final double dist = _desired.mag();
    _desired.setMag(
      dist < slowingRadius ? dist / slowingRadius * maxVelocity : maxVelocity,
    );

    _steer.setValues(_desired.x, _desired.y, _desired.z);
    _steer.sub(velocity);
    _steer.limit(maxForce);

    return _shouldCopy(returnCopy) ? _steer.copy() : _steer;
  }

  /// Steers away from [target] — [seek] with the desired velocity reversed.
  ///
  /// Note this is *not* `seek(target) * -1`: negating the whole steering force
  /// would flip the `- velocity` correction term too, and a body already moving
  /// straight at [target] at [maxVelocity] would then get zero force — no
  /// avoidance in exactly the case that matters most. Only the desired velocity
  /// is reversed.
  ///
  /// [fleeRadius] is optional. When omitted (the default) the force is always
  /// produced, no matter how far away [target] is. When given, the force is
  /// only produced while [target] is closer than the radius; beyond it the
  /// returned vector is zero.
  ///
  /// [returnCopy] overrides the global mode for this call.
  Flut5Vector flee(
    Flut5Vector target, {
    double? fleeRadius,
    bool? returnCopy,
  }) {
    if (fleeRadius != null &&
        position.distanceToSquared(target) > fleeRadius * fleeRadius) {
      _steer.setValues(0.0, 0.0, 0.0);
      return _shouldCopy(returnCopy) ? _steer.copy() : _steer;
    }

    _desired.setValues(position.x, position.y, position.z);
    _desired.sub(target); // note the reversal — seek does target - position
    _desired.setMag(maxVelocity);

    _steer.setValues(_desired.x, _desired.y, _desired.z);
    _steer.sub(velocity);
    _steer.limit(maxForce);

    return _shouldCopy(returnCopy) ? _steer.copy() : _steer;
  }
}
