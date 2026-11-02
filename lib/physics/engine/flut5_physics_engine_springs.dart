part of 'flut5_physics_engine.dart';

/// The spring side of [Flut5PhysicsEngine]: creating springs and the global
/// spring constant they share.
mixin _PhysicsSprings {
  // Provided by Flut5PhysicsEngine.
  List<Flut5PhysicsSpring> get _springs;
  Set<Flut5PhysicsParticle> get _removedParticles;
  void _register(Flut5PhysicsBody body);
  void _compact();

  double _springConstant = 0.1;

  /// Global spring stiffness `k`, used by `springForce` and by every
  /// [Flut5PhysicsSpring] whose own `k` is unset. Must be >= 0; defaults to
  /// `0.1`. Sketches usually set it with `springConstant(k)`.
  double get springConstant => _springConstant;
  set springConstant(double k) {
    if (k < 0) {
      throw ArgumentError.value(k, 'k', 'Spring constant must be >= 0');
    }
    _springConstant = k;
  }

  /// Creates a [Flut5PhysicsSpring] between [a] and [b], registers it and
  /// returns it. Its rest length is their current distance.
  Flut5PhysicsSpring createSpring(
    Flut5PhysicsParticle a,
    Flut5PhysicsParticle b,
  ) {
    // A spring to a particle removed this frame would be dropped with it by
    // the pending compaction — settle that first.
    if (_removedParticles.contains(a) || _removedParticles.contains(b)) {
      _compact();
    }
    final spring = Flut5PhysicsSpring(a, b);
    _register(spring);
    _springs.add(spring);
    return spring;
  }

  /// Whether neither end of [spring] has been removed since the last
  /// [_compact].
  bool _springAttached(Flut5PhysicsSpring spring) =>
      !_removedParticles.contains(spring.a) &&
      !_removedParticles.contains(spring.b);
}
