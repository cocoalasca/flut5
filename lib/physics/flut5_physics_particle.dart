import 'dart:math' as math;

import '../math/flut5_vector.dart';
import 'engine/flut5_physics_engine.dart';
import 'flut5_physics_body.dart';
import 'flut5_physics_rigid_body.dart';

// Soft bodies live in this library so they can mark the particles they are
// made of (see [Flut5PhysicsParticle.softBody]) without a public setter.
part 'flut5_physics_soft_body.dart';

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
final class Flut5PhysicsParticle(super.x, super.y)
    extends Flut5PhysicsRigidBody {
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

  /// Whether physics leaves this particle pinned in place: no gravity, no
  /// forces, and collisions or springs never push it (matching
  /// `Flut5PhysicsPolygon.isStatic`). Useful for pinned rope/cloth anchors or
  /// circular bumpers. Still moves by any explicit [velocity] /
  /// [angularVelocity] you set. Defaults to `false`.
  bool isStatic = false;

  /// `0` for a static (pinned) particle, which nothing can push.
  @override
  double get inverseMass => isStatic ? 0.0 : super.inverseMass;

  Flut5PhysicsSoftBody? _softBody;

  /// The soft body this particle is part of, or `null` for a particle on its
  /// own. Particles of the same soft body never collide with each other —
  /// its springs keep them apart.
  Flut5PhysicsSoftBody? get softBody => _softBody;

  /// Integration pass: a static particle only moves by its own [velocity] and
  /// [angularVelocity]; any other runs [euler] with the world's
  /// [Flut5PhysicsEngine.gravity], then turns per the world's
  /// [Flut5PhysicsEngine.rotationMode].
  @override
  void updatePhysics(Flut5PhysicsEngine physics) {
    if (isSleeping) {
      acceleration.setZero();
      return;
    }
    final dt = physics.stepScale;
    if (isStatic) {
      acceleration.setZero();
      if (dt == 1.0) {
        position.add(velocity);
        angle += angularVelocity;
      } else {
        position
          ..x += velocity.x * dt
          ..y += velocity.y * dt
          ..z += velocity.z * dt;
        angle += angularVelocity * dt;
      }
      return;
    }
    euler(physics.gravity, dt);
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
        final decay = dt == 1.0
            ? physics.cosmeticSpinDecay
            : math.pow(physics.cosmeticSpinDecay, dt).toDouble();
        angularVelocity = angularVelocity * decay + rollingSpin * (1 - decay);
      case .physical:
        if (damping != 1.0) {
          angularVelocity *= dt == 1.0
              ? damping
              : math.pow(damping, dt).toDouble();
        }
    }
    angle += angularVelocity * dt;
  }
}
