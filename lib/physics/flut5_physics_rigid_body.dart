import 'dart:math' as math;

import '../math/flut5_vector.dart';
import 'flut5_physics_body.dart';

/// A body with mass that moves and turns: what [Flut5PhysicsParticle] (a
/// disc) and [Flut5PhysicsPolygon] share, and what the engine's contact
/// solver pushes around.
///
/// Rotation is in the screen plane: [angle] and [angularVelocity] are in
/// radians, clockwise on screen, like `rotate()`.
abstract class Flut5PhysicsRigidBody(double x, double y)
    extends Flut5PhysicsBody {
  this : position = Flut5Vector(x, y);

  /// Current position — for a polygon, its center of mass.
  final Flut5Vector position;

  /// Current velocity.
  final Flut5Vector velocity = Flut5Vector.zero();

  /// Current acceleration. Reset to zero after each `updatePhysics`.
  final Flut5Vector acceleration = Flut5Vector.zero();

  double _mass = 1.0;
  double _inverseMass = 1.0;

  /// Mass. Forces passed to [applyForce] are divided by it (`a = F / m`), so
  /// a heavier body responds less to the same force — and gets pushed around
  /// less by lighter bodies in collisions. Defaults to `1`. Must be > 0 and
  /// finite.
  double get mass => _mass;
  set mass(double value) {
    if (!(value > 0) || !value.isFinite) {
      throw ArgumentError.value(value, 'mass', 'Mass must be finite and > 0');
    }
    _mass = value;
    _inverseMass = 1.0 / value;
  }

  /// Per-frame velocity multiplier. `1.0` (default) applies no damping;
  /// `0.0` fully stops velocity every frame; values in between bleed off
  /// speed over time. With `PhysicsRotationMode.physical` it slows
  /// [angularVelocity] the same way.
  double damping = 1.0;

  /// How far the body has turned, in radians, clockwise on screen — draw it
  /// with `rotate(body.angle)` (convert with `degrees(body.angle)` first
  /// under `angleMode = AngleMode.degrees`).
  double angle = 0.0;

  /// How fast the body turns, in radians per frame, clockwise on screen.
  double angularVelocity = 0.0;

  /// Shorthand for `position.x`.
  double get x => position.x;
  set x(double v) {
    if (position.x != v) wake();
    position.x = v;
  }

  /// Shorthand for `position.y`.
  double get y => position.y;
  set y(double v) {
    if (position.y != v) wake();
    position.y = v;
  }

  bool _sleeping = false;
  int _stillFrames = 0;

  /// Whether this body is currently asleep (when `physicsEngine.sleeping` is
  /// enabled). Sleeping bodies skip integration and sleeping-vs-sleeping/static
  /// collision pairs until woken by [wake], [applyForce], or an awake body
  /// colliding with them.
  bool get isSleeping => _sleeping;

  /// Wakes a sleeping body immediately and resets its calm-frame counter.
  void wake() {
    _sleeping = false;
    _stillFrames = 0;
  }

  /// Internal sleep-state update driven by `Flut5PhysicsEngine` when sleeping
  /// is enabled.
  void updateSleepCounter(bool isCalm, int requiredFrames) {
    if (!isCalm) {
      _sleeping = false;
      _stillFrames = 0;
      return;
    }
    if (_sleeping) return;
    if (++_stillFrames >= requiredFrames) {
      _sleeping = true;
      velocity.setZero();
      acceleration.setZero();
      angularVelocity = 0.0;
    }
  }

  /// How much a push changes this body's velocity: `1 / mass`, or `0` for a
  /// body nothing can push.
  double get inverseMass => _inverseMass;

  /// Accumulates [force] into [acceleration], scaled by [inverseMass]
  /// (`a = F / m`). Every force reaching a body goes through here — yours,
  /// and those of springs attached to it. [force] is not modified.
  void applyForce(Flut5Vector force) {
    final inv = inverseMass;
    if (inv == 0) return;
    if (force.x != 0 || force.y != 0 || force.z != 0) wake();
    acceleration
      ..x += force.x * inv
      ..y += force.y * inv
      ..z += force.z * inv;
  }

  /// One explicit Euler step: adds [gravity] (an acceleration, independent of
  /// mass) and the accumulated [acceleration] to [velocity], applies
  /// [damping], moves [position] by [velocity], then resets [acceleration]
  /// so next frame's forces start from zero.
  ///
  /// When [dt] is `1.0` (the default), runs one full frame step with no extra
  /// multiplies; when `physicsEngine.substeps > 1`, scales acceleration,
  /// gravity, damping, and displacement by [dt] (`1 / substeps`).
  void euler([Flut5Vector? gravity, double dt = 1.0]) {
    if (dt == 1.0) {
      velocity.add(acceleration);
      if (gravity != null) velocity.add(gravity);
      if (damping != 1.0) velocity.mult(damping);
      position.add(velocity);
      acceleration.setZero();
      return;
    }
    velocity
      ..x += acceleration.x * dt
      ..y += acceleration.y * dt
      ..z += acceleration.z * dt;
    if (gravity != null) {
      velocity
        ..x += gravity.x * dt
        ..y += gravity.y * dt
        ..z += gravity.z * dt;
    }
    if (damping != 1.0) {
      velocity.mult(math.pow(damping, dt).toDouble());
    }
    position
      ..x += velocity.x * dt
      ..y += velocity.y * dt
      ..z += velocity.z * dt;
    acceleration.setZero();
  }
}
