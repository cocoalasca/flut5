import 'package:flut5/math/flut5_vector.dart';

/// Core physics state and integration for steering objects.
///
/// Use directly for position/velocity/acceleration without behaviors.
/// For the full API (seek, arrive, flee), use [Flut5Steering] instead.
mixin Flut5SteeringNavigation {
  // ── Physics properties ────────────────────────────────────────────────

  /// Current position.
  final Flut5Vector position = Flut5Vector.createVector();

  /// Current velocity.
  final Flut5Vector velocity = Flut5Vector.createVector();

  /// Current acceleration. Reset to zero after [updateNavigation].
  final Flut5Vector acceleration = Flut5Vector.createVector();

  // ── Limits ────────────────────────────────────────────────────────────

  /// Maximum speed.
  double maxVelocity = 4.0;

  /// Maximum steering force per frame.
  double maxForce = 0.1;

  /// Per-frame velocity multiplier. `1.0` (default) applies no damping;
  /// `0.0` fully stops velocity every frame; values in between bleed off
  /// speed over time. Set via [setDamping].
  double damping = 1.0;

  // ── API ───────────────────────────────────────────────────────────────

  /// Sets [maxVelocity] and [maxForce]. Both are optional — omit one to leave
  /// it as it was.
  ///
  /// The two interact: [maxForce] caps how much velocity can change per frame,
  /// so raising [maxVelocity] alone makes a body slower to reach its new top
  /// speed rather than more responsive. Prefer passing both when retuning.
  void configSteering({double? maxVelocity, double? maxForce}) {
    if (maxVelocity != null) this.maxVelocity = maxVelocity;
    if (maxForce != null) this.maxForce = maxForce;
  }

  /// Sets [damping]. Call as `boid.setDamping(0.98)` from your sketch.
  void setDamping(double damping) => this.damping = damping;

  /// Accumulates [force] into [acceleration].
  void applyForce(Flut5Vector force) {
    acceleration.add(force);
  }

  /// Sugar for [updateNavigation].
  void updateSteering() => updateNavigation();

  /// Integrates one frame: acceleration → velocity → position, then
  /// clears acceleration.
  void updateNavigation() {
    velocity.add(acceleration);
    velocity.mult(damping);
    velocity.limit(maxVelocity);
    position.add(velocity);
    acceleration.mult(0);
  }
}
