import '../math/flut5_vector.dart';
import 'flut5_physics_body.dart';

/// A body with mass that moves and turns: what [Flut5PhysicsParticle] (a
/// disc) and [Flut5PhysicsPolygon] share, and what the engine's contact
/// solver pushes around.
///
/// Rotation is in the screen plane: [angle] and [angularVelocity] are in
/// radians, clockwise on screen, like `rotate()`.
abstract class Flut5PhysicsRigidBody extends Flut5PhysicsBody {
  Flut5PhysicsRigidBody(double x, double y) : position = Flut5Vector(x, y);

  /// Current position — for a polygon, its center of mass.
  final Flut5Vector position;

  /// Current velocity.
  final Flut5Vector velocity = Flut5Vector.zero();

  /// Current acceleration. Reset to zero after each `updatePhysics`.
  final Flut5Vector acceleration = Flut5Vector.zero();

  /// Mass. Forces passed to [applyForce] are divided by it (`a = F / m`), so
  /// a heavier body responds less to the same force — and gets pushed around
  /// less by lighter bodies in collisions. Defaults to `1`.
  double mass = 1.0;

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
  set x(double v) => position.x = v;

  /// Shorthand for `position.y`.
  double get y => position.y;
  set y(double v) => position.y = v;

  /// How much a push changes this body's velocity: `1 / mass`, or `0` for a
  /// body nothing can push.
  double get inverseMass => 1 / mass;

  /// Accumulates [force] into [acceleration], scaled by `1 / mass`
  /// (`a = F / m`). Every force reaching a body goes through here — yours,
  /// and those of springs attached to it. [force] is not modified.
  void applyForce(Flut5Vector force) {
    acceleration
      ..x += force.x / mass
      ..y += force.y / mass
      ..z += force.z / mass;
  }

  /// One explicit Euler step: adds [gravity] (an acceleration, independent of
  /// mass) and the accumulated [acceleration] to [velocity], applies
  /// [damping], moves [position] by [velocity], then resets [acceleration]
  /// so next frame's forces start from zero.
  ///
  /// The physics engine calls this for every body once all forces of the
  /// frame are applied; call it yourself only for bodies you step by hand.
  void euler([Flut5Vector? gravity]) {
    velocity.add(acceleration);
    if (gravity != null) velocity.add(gravity);
    velocity.mult(damping);
    position.add(velocity);
    acceleration.setZero();
  }
}
