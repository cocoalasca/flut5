import 'engine/flut5_physics_engine.dart';
import 'flut5_physics_rigid_body.dart';

/// A disc: a point mass with a [radius]. Moves, turns and collides like any
/// [Flut5PhysicsRigidBody].
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
final class Flut5PhysicsParticle extends Flut5PhysicsRigidBody {
  Flut5PhysicsParticle(super.x, super.y);

  /// Collision radius: the particle's edge is this far from [position]. With
  /// `windowBoundsCollision()` on it bounces when its edge touches a window
  /// edge, and with `particleCollision()` on when it touches another
  /// particle's edge. Match it to the size you draw:
  /// `circle(p.x, p.y, p.radius * 2)`. Defaults to `0`, a point, which
  /// collides only with particles that have a radius (and with polygons).
  ///
  /// For mass that grows with size, set it from the radius:
  /// `p.mass = p.radius * p.radius`.
  double radius = 0.0;

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
