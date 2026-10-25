import 'flut5_physics_engine.dart';

/// Base type for everything the engine's physics registry steps each frame.
///
/// Each [Flut5PhysicsEngine.update] runs two passes over every registered
/// body: [accumulateForces] on all of them, then [updatePhysics] on all of
/// them. Force generators (springs) push in the first pass and movers
/// (particles) integrate in the second, so the result never depends on the
/// order bodies were created in.
abstract class Flut5PhysicsBody {
  /// First pass: add this body's forces to the bodies it acts on. No-op by
  /// default.
  void accumulateForces(Flut5PhysicsEngine physics) {}

  /// Second pass: advance this body by one frame. Read world settings such as
  /// [Flut5PhysicsEngine.gravity] from [physics]. No-op by default.
  void updatePhysics(Flut5PhysicsEngine physics) {}
}
