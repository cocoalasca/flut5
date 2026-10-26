import '../math/flut5_vector.dart';
import 'flut5_physics_body.dart';
import 'flut5_physics_engine.dart';

/// A point mass with position, velocity and acceleration.
///
/// Create one with `physicsEngine.createParticle(x, y)` so it is registered
/// and stepped every frame; tweak its properties from wherever you hold the
/// reference:
///
/// ```dart
/// final p = physicsEngine.createParticle(100, 100)..mass = 2;
/// // in draw():
/// p.applyForce(springForce(p.position, anchor));
/// circle(p.x, p.y, 20);
/// ```
final class Flut5PhysicsParticle(double x, double y) extends Flut5PhysicsBody {
  /// Current position.
  final Flut5Vector position = Flut5Vector(x, y);

  /// Current velocity.
  final Flut5Vector velocity = Flut5Vector.zero();

  /// Current acceleration. Reset to zero after each [updatePhysics].
  final Flut5Vector acceleration = Flut5Vector.zero();

  /// Mass. Forces passed to [applyForce] are divided by it (`a = F / m`), so a
  /// heavier particle responds less to the same force. Defaults to `1`.
  double mass = 1.0;

  /// Per-frame velocity multiplier. `1.0` (default) applies no damping;
  /// `0.0` fully stops velocity every frame; values in between bleed off
  /// speed over time.
  double damping = 1.0;

  /// Collision radius. With `windowBoundsCollision()` on, the particle bounces
  /// when its edge — this far from [position] — touches a window edge, so
  /// match it to the size you draw: `circle(p.x, p.y, p.radius * 2)`.
  /// Defaults to `0`, a point.
  double radius = 0.0;

  /// Shorthand for `position.x`.
  double get x => position.x;
  set x(double v) => position.x = v;

  /// Shorthand for `position.y`.
  double get y => position.y;
  set y(double v) => position.y = v;

  /// Accumulates [force] into [acceleration], scaled by `1 / mass`
  /// (`a = F / m`). Every force reaching a particle goes through here —
  /// yours, and those of springs attached to it. [force] is not modified.
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
  /// The physics engine calls this for every particle once all forces of the
  /// frame are applied; call it yourself only for particles you step by hand.
  void euler([Flut5Vector? gravity]) {
    velocity.add(acceleration);
    if (gravity != null) velocity.add(gravity);
    velocity.mult(damping);
    position.add(velocity);
    acceleration.setZero();
  }

  /// Integration pass: runs [euler] with the world's
  /// [Flut5PhysicsEngine.gravity].
  @override
  void updatePhysics(Flut5PhysicsEngine physics) => euler(physics.gravity);
}
