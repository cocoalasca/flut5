import 'engine/flut5_physics_engine.dart';

/// Collisions for the Flut5 Engine's particles: against the window edges
/// and against each other.
///
/// Both are off by default. Turn them on once, usually in `setup()`:
///
/// ```dart
/// windowBoundsCollision();            // all four edges
/// windowBoundsCollision(top: false);  // open-top box
/// windowBoundsCollision(all: false, bottom: true); // floor only
/// windowBoundsRestitution(0.8);       // lose 20% of the speed per bounce
///
/// particleCollision();                // particles bounce off each other
/// particleRestitution(0.9);
/// polygonRestitution(0.3);            // rects and polygons always collide
/// ```
mixin Flut5Collision {
  /// The physics world, provided by [Flut5Engine]. Holds the collision
  /// settings.
  Flut5PhysicsEngine get physicsEngine;

  /// Makes particles bounce off the window edges. With no arguments all four
  /// edges collide; pass `false` for an edge to leave it open, or [all] to
  /// switch every edge at once (named edges override it). Each call replaces
  /// the previous selection. See [Flut5PhysicsEngine.windowBoundsCollision].
  void windowBoundsCollision({
    bool all = true,
    bool? left,
    bool? top,
    bool? right,
    bool? bottom,
  }) => physicsEngine.windowBoundsCollision(
    all: all,
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  );

  /// Turns the window edges back into open space, same as
  /// `windowBoundsCollision(all: false)`.
  void noWindowBoundsCollision() => physicsEngine.noWindowBoundsCollision();

  /// Get-or-set accessor for the window edges' restitution (p5-style, like
  /// `springConstant`). Called with [restitution] it assigns (must be >= 0);
  /// called with no argument it returns the current value. Defaults to `1`, a
  /// bounce at full speed; `0` stops particles dead against the wall.
  double windowBoundsRestitution([double? restitution]) {
    if (restitution != null) {
      physicsEngine.windowBoundsRestitution = restitution;
    }
    return physicsEngine.windowBoundsRestitution;
  }

  /// Makes particles bounce off each other — every particle with a `radius`
  /// against every other. [iterations], if given, sets how many collision
  /// passes run per frame (default `2`): steadier piles, at that many times
  /// the cost. See [Flut5PhysicsEngine.particleCollision].
  void particleCollision({int? iterations}) =>
      physicsEngine.particleCollision(iterations: iterations);

  /// Lets particles pass through each other again.
  void noParticleCollision() => physicsEngine.noParticleCollision();

  /// Get-or-set accessor for the restitution of collisions between
  /// particles (p5-style, like `springConstant`). Called with [restitution]
  /// it assigns (must be >= 0); called with no argument it returns the
  /// current value. Defaults to `1`, a perfectly elastic bounce; `0` stops
  /// them dead along the hit.
  double particleRestitution([double? restitution]) {
    if (restitution != null) physicsEngine.particleRestitution = restitution;
    return physicsEngine.particleRestitution;
  }

  /// Get-or-set accessor for the restitution of hits involving a polygon
  /// (p5-style, like `springConstant`). Called with [restitution] it
  /// assigns (must be >= 0); called with no argument it returns the current
  /// value. Defaults to `1`, a perfectly elastic bounce; `0` stops them dead
  /// along the hit.
  double polygonRestitution([double? restitution]) {
    if (restitution != null) physicsEngine.polygonRestitution = restitution;
    return physicsEngine.polygonRestitution;
  }
}
