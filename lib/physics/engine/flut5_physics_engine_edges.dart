part of 'flut5_physics_engine.dart';

/// The window-edge side of [Flut5PhysicsEngine]: the window's edges as walls
/// particles bounce off.
mixin _PhysicsEdges {
  // Provided by Flut5PhysicsEngine and its other parts.
  List<Flut5PhysicsParticle> get _particles;
  Size Function()? get _windowSize;
  Flut5Vector get gravity;
  PhysicsRotationMode get rotationMode;
  double get friction;

  bool _boundsLeft = false;
  bool _boundsTop = false;
  bool _boundsRight = false;
  bool _boundsBottom = false;

  /// Makes particles bounce off the edges of the window. Off by default.
  ///
  /// Called with no arguments it enables all four edges; pass `false` for an
  /// edge to leave it open, so particles fly out through it. [all] switches
  /// every edge at once, and any edge you also name overrides it:
  ///
  /// ```dart
  /// physicsEngine.windowBoundsCollision();              // closed box
  /// physicsEngine.windowBoundsCollision(all: false);    // no walls
  /// physicsEngine.windowBoundsCollision(top: false);    // open-top box
  /// physicsEngine.windowBoundsCollision(all: false, bottom: true); // floor only
  /// ```
  ///
  /// Each call replaces the previous selection. A particle's edge — its
  /// `radius` away from its center — is what touches the wall, and how much
  /// speed survives the bounce is [windowBoundsRestitution]. Turn the walls
  /// off again with [noWindowBoundsCollision].
  void windowBoundsCollision({
    bool all = true,
    bool? left,
    bool? top,
    bool? right,
    bool? bottom,
  }) {
    _boundsLeft = left ?? all;
    _boundsTop = top ?? all;
    _boundsRight = right ?? all;
    _boundsBottom = bottom ?? all;
  }

  /// Turns off every window edge, same as `windowBoundsCollision(all: false)`.
  void noWindowBoundsCollision() => windowBoundsCollision(all: false);

  /// Whether any window edge is enabled.
  bool get _hasWindowEdges =>
      _boundsLeft || _boundsTop || _boundsRight || _boundsBottom;

  double _windowBoundsRestitution = 1.0;

  /// How bouncy the window edges are: the share of a particle's speed into
  /// a wall that it keeps, reversed, after hitting it. `1` (default) bounces
  /// back at full speed, `0.5` at half, `0` stops dead against the wall;
  /// above `1` every bounce adds energy. Must be >= 0. Sketches usually set
  /// it with `windowBoundsRestitution(e)`.
  double get windowBoundsRestitution => _windowBoundsRestitution;
  set windowBoundsRestitution(double restitution) {
    if (restitution < 0) {
      throw ArgumentError.value(
        restitution,
        'restitution',
        'Restitution must be >= 0',
      );
    }
    _windowBoundsRestitution = restitution;
  }

  /// Bounces every particle that crossed an enabled window edge this frame.
  ///
  /// The overshoot is mirrored back inside (scaled by the restitution), not
  /// clamped onto the wall: clamping drops the part of the step spent past
  /// the wall, so under gravity a ball with restitution `1` would sink lower
  /// every bounce. A particle reaching a wall with no more speed than one
  /// frame of gravity toward it is resting on it — it stops there instead of
  /// hopping in place forever.
  void _collideWindowBounds() {
    final size = _windowSize?.call();
    if (size == null || size.isEmpty) return;

    // A disabled edge sits at infinity, so no particle ever crosses it.
    final left = _boundsLeft ? 0.0 : double.negativeInfinity;
    final top = _boundsTop ? 0.0 : double.negativeInfinity;
    final right = _boundsRight ? size.width : double.infinity;
    final bottom = _boundsBottom ? size.height : double.infinity;

    for (final particle in _particles) {
      // A particle touches an edge when its center is one radius away.
      final radius = particle.radius;
      final x = particle.position.x;
      if (x < left + radius) {
        _bounceOffEdge(particle, .left, left + radius);
      } else if (x > right - radius) {
        _bounceOffEdge(particle, .right, right - radius);
      }
      final y = particle.position.y;
      if (y < top + radius) {
        _bounceOffEdge(particle, .top, top + radius);
      } else if (y > bottom - radius) {
        _bounceOffEdge(particle, .bottom, bottom - radius);
      }
    }
  }

  /// Bounces [particle] off [edge], which it has crossed. [touching] is the
  /// coordinate its center has when it just touches the edge.
  void _bounceOffEdge(
    Flut5PhysicsParticle particle,
    _WindowEdge edge,
    double touching,
  ) {
    final axis = edge.axis;
    final outward = edge.outward;
    final position = particle.position;
    final velocity = particle.velocity;
    final outwardSpeed = velocity[axis] * outward;
    final outwardGravity = gravity[axis] * outward;

    if (outwardSpeed <= 0) {
      // Already heading back inside, e.g. the window shrank past it.
      position[axis] = touching;
      return;
    }

    // How much the hit changes its speed into the edge.
    final double normalSpeedChange;
    if (outwardSpeed <= outwardGravity) {
      // No faster than one frame of gravity: it is resting on the edge.
      position[axis] = touching;
      velocity[axis] = 0;
      normalSpeedChange = outwardSpeed;
    } else {
      // Mirror the overshoot back inside, but never by more than this
      // frame's movement, so a particle a resize left far outside isn't
      // flung deep into the window.
      final restitution = _windowBoundsRestitution;
      final overshoot = (position[axis] - touching) * outward;
      final bounceBack = math.min(overshoot, outwardSpeed) * restitution;
      position[axis] = touching - bounceBack * outward;
      velocity[axis] = -velocity[axis] * restitution;
      normalSpeedChange = outwardSpeed * (1 + restitution);
    }

    if (rotationMode == .physical) {
      _rubAgainstEdge(particle, edge, normalSpeedChange, friction);
    }
  }
}

/// A window edge: the coordinate it blocks and which way is out through it.
enum _WindowEdge {
  left(axis: 0, outward: -1),
  top(axis: 1, outward: -1),
  right(axis: 0, outward: 1),
  bottom(axis: 1, outward: 1);

  const _WindowEdge({required this.axis, required this.outward});

  /// The coordinate the edge blocks, as a vector index: `0` for x, `1` for y.
  final int axis;

  /// `1` if leaving through this edge increases that coordinate (right,
  /// bottom), `-1` if it decreases it (left, top).
  final double outward;

  /// The coordinate the edge runs along: y for left and right, x for top and
  /// bottom.
  int get alongAxis => 1 - axis;

  /// Which way a clockwise spin moves a particle's surface along the edge
  /// where it touches: `1` toward increasing [alongAxis], `-1` toward
  /// decreasing. On the floor the touching surface is the bottom of the
  /// ball, which a clockwise spin moves left.
  double get spinDirection => axis == 0 ? outward : -outward;
}
