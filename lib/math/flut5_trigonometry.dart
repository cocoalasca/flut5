import 'dart:math' as math;

/// The unit system used to measure angles.
enum AngleMode {
  /// Radians are a unit of angular measure where a full circle is 2*pi.
  radians,

  /// Degrees are a unit of angular measure where a full circle is 360.
  degrees,
}

/// A mixin that provides trigonometric utilities for the Flut5 Engine.
mixin Flut5Trigonometry {
  AngleMode _currentAngleMode = .radians;

  /// Gets the current unit system used to measure angles.
  AngleMode get angleMode => _currentAngleMode;

  /// Changes the unit system used to measure angles.
  ///
  /// Functions such as [rotate] and [sin] expect angles measured in
  /// [AngleMode.radians] by default. Setting this to [AngleMode.degrees]
  /// switches to degrees.
  set angleMode(AngleMode mode) {
    if (_currentAngleMode == mode) return;

    // TODO: Adjust rotation related variables when changed if needed like p5 does.
    // e.g., pRotationX, pRotationY, pRotationZ (for 3D or device orientation)

    _currentAngleMode = mode;
  }

  /// Calculates the arc cosine of a number.
  ///
  /// Returns values in the range 0 to pi.
  /// If the [angleMode] is [AngleMode.degrees], returns 0 to 180.
  double acos(double ratio) {
    return _fromRadians(math.acos(ratio));
  }

  /// Calculates the arc sine of a number.
  ///
  /// Returns values in the range -pi/2 to pi/2.
  /// If the [angleMode] is [AngleMode.degrees], returns -90 to 90.
  double asin(double ratio) {
    return _fromRadians(math.asin(ratio));
  }

  /// Calculates the arc tangent of a number.
  ///
  /// Returns values in the range -pi/2 to pi/2.
  /// If the [angleMode] is [AngleMode.degrees], returns -90 to 90.
  double atan(double ratio) {
    return _fromRadians(math.atan(ratio));
  }

  /// Calculates the angle formed by a point, the origin, and the positive x-axis.
  ///
  /// Returns values in the range -pi to pi.
  /// If the [angleMode] is [AngleMode.degrees], returns -180 to 180.
  double atan2(double y, double x) {
    return _fromRadians(math.atan2(y, x));
  }

  /// Calculates the cosine of an angle.
  ///
  /// Oscillates between -1 and 1 as the input angle increases.
  double cos(double angle) {
    return math.cos(toRadians(angle));
  }

  /// Calculates the sine of an angle.
  ///
  /// Oscillates between -1 and 1 as the input angle increases.
  double sin(double angle) {
    return math.sin(toRadians(angle));
  }

  /// Calculates the tangent of an angle.
  ///
  /// Ranges from -infinity to infinity and repeats periodically.
  double tan(double angle) {
    return math.tan(toRadians(angle));
  }

  /// Converts an angle measured in radians to its value in degrees.
  double degrees(double radians) => radians * (180.0 / math.pi);

  /// Converts an angle measured in degrees to its value in radians.
  double radians(double degrees) => degrees * (math.pi / 180.0);

  /// Converts an angle from the current [angleMode] to radians.
  ///
  /// Used internally by the engine and by the [Flut5Transform] mixin
  /// to ensure rotations and shears respect the active [AngleMode].
  double toRadians(double angle) {
    if (_currentAngleMode == .degrees) {
      return angle * (math.pi / 180.0);
    }
    return angle;
  }

  double _fromRadians(double angle) {
    if (_currentAngleMode == .degrees) {
      return angle * (180.0 / math.pi);
    }
    return angle;
  }
}
