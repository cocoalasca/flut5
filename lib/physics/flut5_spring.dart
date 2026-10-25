import '../math/flut5_vector.dart';

/// Spring physics (Hooke's law) for the Flut5 Engine.
///
/// The spring constant is engine-wide state, set once with
/// [springConstant] and shared by every [springForce] call after it:
///
/// ```dart
/// springConstant(0.05);
/// bob.applyForce(springForce(bob.position, anchor));
/// ```
mixin Flut5Spring {
  double _springK = 0.1;

  /// Get-or-set accessor for the spring constant `k` (p5-style, like
  /// [frameRate]). Called with [k] it assigns (must be >= 0); called with no
  /// argument it returns the current value. Defaults to `0.1`.
  ///
  /// Higher values make a stiffer spring that snaps back harder; `0` turns
  /// the force off.
  double springConstant([double? k]) {
    if (k != null) {
      if (k < 0) {
        throw ArgumentError.value(k, 'k', 'Spring constant must be >= 0');
      }
      _springK = k;
    }
    return _springK;
  }

  /// The force a spring exerts on a body at [position] that rests at [rest]:
  /// `F = -k * (position - rest)`, with `k` from [springConstant].
  ///
  /// The force points from [position] back toward [rest] and grows with the
  /// distance between them. Returns a new vector each call, safe to store or
  /// pass straight to `applyForce`. Neither argument is modified.
  Flut5Vector springForce(Flut5Vector position, Flut5Vector rest) =>
      Flut5Vector.subVectors(rest, position).mult(_springK);
}
