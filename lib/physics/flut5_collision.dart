import 'flut5_physics_engine.dart';

/// Window edges as physics walls, for the Flut5 Engine.
///
/// Off by default. Turn them on once, usually in `setup()`:
///
/// ```dart
/// windowBoundsCollision();            // all four edges
/// windowBoundsCollision(top: false);  // open-top box
/// windowBoundsCollision(all: false, bottom: true); // floor only
/// windowBoundsRestitution(0.8);       // lose 20% of the speed per bounce
/// ```
mixin Flut5WindowBounds {
  /// The physics world, provided by [Flut5Engine]. Holds the window-bounds
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
  /// `springConstant`). Called with [e] it assigns (must be >= 0); called
  /// with no argument it returns the current value. Defaults to `1`, a
  /// bounce at full speed; `0` stops particles dead against the wall.
  double windowBoundsRestitution([double? e]) {
    if (e != null) physicsEngine.windowBoundsRestitution = e;
    return physicsEngine.windowBoundsRestitution;
  }
}
