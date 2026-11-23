import '../math/flut5_vector.dart';
import 'flut5_physics_rigid_body.dart';

/// Describes a contact resolved between two rigid bodies during a
/// [Flut5PhysicsEngine.update] step.
final class Flut5PhysicsCollisionEvent({
  /// First rigid body involved in the collision.
  required final Flut5PhysicsRigidBody bodyA,

  /// Second rigid body involved in the collision.
  required final Flut5PhysicsRigidBody bodyB,

  /// Unit contact normal pointing from [bodyA] toward [bodyB].
  required final Flut5Vector normal,

  /// Penetration depth resolved along [normal], in pixels.
  required final double overlap,
});

/// Result of casting a ray against live bodies in a [Flut5PhysicsEngine].
final class Flut5PhysicsRayHit({
  /// The physics body (particle or polygon) struck by the ray.
  required final Flut5PhysicsRigidBody body,

  /// World-space coordinates where the ray struck [body].
  required final Flut5Vector point,

  /// Euclidean distance from the ray origin to [point].
  required final double distance,

  /// Unit surface normal at [point], oriented back toward the ray origin.
  required final Flut5Vector normal,
});

