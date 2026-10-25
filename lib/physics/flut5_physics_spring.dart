import 'dart:math' as math;

import '../math/flut5_vector.dart';
import 'flut5_physics_body.dart';
import 'flut5_physics_engine.dart';
import 'flut5_physics_particle.dart';

/// A spring linking two particles (Hooke's law).
///
/// Its [restLength] is the distance between [a] and [b] when the spring is
/// created, so the spring starts relaxed. Every frame it pulls the two
/// together when stretched past [restLength] and pushes them apart when
/// compressed, with equal and opposite forces (each scaled by its particle's
/// mass).
///
/// ```dart
/// final a = physicsEngine.createParticle(100, 100);
/// final b = physicsEngine.createParticle(200, 100);
/// final s = physicsEngine.createSpring(a, b)..k = 0.05;
/// // in draw():
/// line(s.a.x, s.a.y, s.b.x, s.b.y);
/// ```
final class Flut5PhysicsSpring(
  final Flut5PhysicsParticle a,
  final Flut5PhysicsParticle b,
) extends Flut5PhysicsBody {
  /// Length at which the spring exerts no force. Starts as the distance
  /// between [a] and [b] at creation; assign to retune.
  double restLength = a.position.distanceTo(b.position);

  /// This spring's own stiffness. `null` (default) follows the global
  /// [Flut5PhysicsEngine.springConstant] (set with `springConstant(k)`), so
  /// changing the global retunes every spring that hasn't overridden it.
  double? k;

  /// The stiffness actually applied: [k] if set, otherwise the global
  /// constant of [physics].
  double effectiveK(Flut5PhysicsEngine physics) => k ?? physics.springConstant;

  /// Scratch vector reused every frame so stepping a spring allocates
  /// nothing.
  final Flut5Vector _force = Flut5Vector.zero();

  /// Applies `k * (length - restLength)` along the a→b axis to [a], and the
  /// opposite to [b], through each particle's `applyForce`. Particles sitting
  /// exactly on top of each other have no axis to push along, so the spring
  /// skips that frame.
  @override
  void accumulateForces(Flut5PhysicsEngine physics) {
    final dx = b.position.x - a.position.x;
    final dy = b.position.y - a.position.y;
    final dz = b.position.z - a.position.z;
    final length = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (length == 0) return;

    // Force magnitude per unit of the (unnormalized) a→b vector.
    final s = effectiveK(physics) * (length - restLength) / length;
    _force.setValues(dx * s, dy * s, dz * s);
    a.applyForce(_force);
    b.applyForce(_force..negate());
  }
}
