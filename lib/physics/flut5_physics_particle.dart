import '../math/flut5_vector.dart';
import 'flut5_physics_body.dart';
import 'engine/flut5_physics_engine.dart';

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
  /// heavier particle responds less to the same force — and, with
  /// `particleCollision()` on, gets pushed around less by lighter particles.
  /// Defaults to `1`. For mass that grows with size, set it from the radius:
  /// `p.mass = p.radius * p.radius`.
  double mass = 1.0;

  /// Per-frame velocity multiplier. `1.0` (default) applies no damping;
  /// `0.0` fully stops velocity every frame; values in between bleed off
  /// speed over time. With [PhysicsRotationMode.physical] it slows
  /// [angularVelocity] the same way.
  double damping = 1.0;

  /// Collision radius: the particle's edge is this far from [position]. With
  /// `windowBoundsCollision()` on it bounces when its edge touches a window
  /// edge, and with `particleCollision()` on when it touches another
  /// particle's edge. Match it to the size you draw:
  /// `circle(p.x, p.y, p.radius * 2)`. Defaults to `0`, a point, which
  /// collides only with particles that have a radius.
  double radius = 0.0;

  /// How far the particle has turned, in radians, clockwise on screen — draw
  /// it with `rotate(p.angle)` (convert with `degrees(p.angle)` first under
  /// `angleMode = AngleMode.degrees`). Rotation is in the screen plane.
  /// The engine only changes it when `physicsEngine.rotationMode` isn't
  /// [PhysicsRotationMode.none].
  double angle = 0.0;

  /// How fast the particle turns, in radians per frame, clockwise on screen.
  /// Eased toward the rolling spin in [PhysicsRotationMode.cosmetic]; in
  /// [PhysicsRotationMode.physical] friction changes it and you can set it
  /// yourself to throw a spinning ball.
  double angularVelocity = 0.0;

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
  /// [Flut5PhysicsEngine.gravity], then turns the particle per the world's
  /// [Flut5PhysicsEngine.rotationMode].
  @override
  void updatePhysics(Flut5PhysicsEngine physics) {
    euler(physics.gravity);
    switch (physics.rotationMode) {
      case .none:
        return;
      case .cosmetic:
        // Keep part of the spin and take the rest from the spin of rolling
        // along a floor (one radius of travel per radian, scaled), so spin
        // follows speed with a lag and coasts to a stop when the particle
        // does.
        final rollingSpin = radius > 0
            ? velocity.x / radius * physics.cosmeticSpinScale
            : 0.0;
        final decay = physics.cosmeticSpinDecay;
        angularVelocity = angularVelocity * decay + rollingSpin * (1 - decay);
      case .physical:
        angularVelocity *= damping;
    }
    angle += angularVelocity;
  }
}
