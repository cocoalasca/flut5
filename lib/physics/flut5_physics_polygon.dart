import 'dart:math' as math;

import '../math/flut5_vector.dart';
import 'engine/flut5_physics_engine.dart';
import 'flut5_physics_rigid_body.dart';

/// A rigid convex polygon — a triangle, a rect, a hexagon, any shape whose
/// corners all point outward. Create one with `physicsEngine.createPolygon`
/// or `physicsEngine.createRect` so it is registered, stepped and collided.
///
/// It moves like any [Flut5PhysicsRigidBody] and collides with other
/// polygons, with particles and with the window edges. With
/// `physicsEngine.rotationMode = .physical` hits off its center make it
/// turn; otherwise only you turn it (set [angle] or [angularVelocity]).
/// Polygons are flat shapes in the screen plane.
///
/// ```dart
/// final ground = physicsEngine.createRect(width / 2, height - 20, width, 40)
///   ..isStatic = true;
/// final box = physicsEngine.createRect(200, 100, 40, 40);
/// // in draw():
/// for (final p in physicsEngine.polygons) {
///   beginShape();
///   for (final corner in p.corners) vertex(corner.x, corner.y);
///   endShape(close: true);
/// }
/// ```
final class Flut5PhysicsPolygon extends Flut5PhysicsRigidBody {
  /// A polygon at ([x], [y]) with [corners] relative to that point, in
  /// either direction around the shape.
  ///
  /// The polygon turns around its center of mass, so if [corners] aren't
  /// centered on ([x], [y]) the body's [position] is moved to where that
  /// center is, and [localCorners] are relative to it.
  ///
  /// Throws an [ArgumentError] if [corners] don't make a convex shape:
  /// fewer than 3, two in the same place, no area, or a dent. Build
  /// concave shapes from several convex ones.
  factory Flut5PhysicsPolygon(double x, double y, List<Flut5Vector> corners) {
    final shape = _ConvexShape.from(corners);
    return Flut5PhysicsPolygon._(
      x + shape.centerX,
      y + shape.centerY,
      shape.corners,
      shape.inertiaPerMass,
    );
  }

  Flut5PhysicsPolygon._(
    super.x,
    super.y,
    List<Flut5Vector> localCorners,
    this._inertiaPerMass,
  ) : localCorners = List.unmodifiable(localCorners);

  /// The corners relative to [position] before rotation, clockwise on
  /// screen. They never change; [corners] gives them moved and turned.
  final List<Flut5Vector> localCorners;

  /// Moment of inertia per unit of mass, from the shape alone.
  final double _inertiaPerMass;

  /// Whether physics leaves this body where it is: no gravity, no forces,
  /// and collisions never push or turn it — a platform, a wall, the ground.
  /// It still moves by any [velocity] and [angularVelocity] you give it, so
  /// a static body with a velocity is a moving platform that pushes things
  /// without being pushed back. Defaults to `false`.
  bool isStatic = false;

  /// How hard it is to turn the polygon: `mass` times how far its area lies
  /// from its center. A long plank resists turning more than a square of
  /// the same mass.
  double get momentOfInertia => mass * _inertiaPerMass;

  /// `0` for a static body, which nothing can push.
  @override
  double get inverseMass => isStatic ? 0 : 1 / mass;

  /// The corners where they are now — [localCorners] turned by [angle] and
  /// moved to [position]. A new list each call, ready for `vertex()`.
  List<Flut5Vector> get corners {
    final cos = math.cos(angle), sin = math.sin(angle);
    return [
      for (final corner in localCorners)
        Flut5Vector(
          position.x + corner.x * cos - corner.y * sin,
          position.y + corner.x * sin + corner.y * cos,
        ),
    ];
  }

  /// Integration pass. A static body just moves by its own [velocity] and
  /// [angularVelocity]. Any other runs [euler] with the world's gravity and
  /// turns by [angularVelocity], which only collisions in
  /// [PhysicsRotationMode.physical] change (and slow by [damping]).
  @override
  void updatePhysics(Flut5PhysicsEngine physics) {
    if (isStatic) {
      acceleration.setZero();
      position.add(velocity);
    } else {
      euler(physics.gravity);
      if (physics.rotationMode == .physical) angularVelocity *= damping;
    }
    angle += angularVelocity;
  }
}

/// A rectangular [Flut5PhysicsPolygon] that remembers its [width] and
/// [height], so you can draw it with `rect()`:
///
/// ```dart
/// push();
/// translate(r.x, r.y);
/// rotate(r.angle);
/// rect(-r.width / 2, -r.height / 2, r.width, r.height);
/// pop();
/// ```
final class Flut5PhysicsRect extends Flut5PhysicsPolygon {
  /// A [width] × [height] rect centered on ([x], [y]). Both must be > 0.
  Flut5PhysicsRect(double x, double y, this.width, this.height)
    : super._(x, y, _corners(width, height), _inertia(width, height));

  /// Width before rotation.
  final double width;

  /// Height before rotation.
  final double height;

  static List<Flut5Vector> _corners(double width, double height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError(
        'A rect needs a width and height > 0, got $width × $height',
      );
    }
    final halfWidth = width / 2, halfHeight = height / 2;
    return [
      Flut5Vector(-halfWidth, -halfHeight),
      Flut5Vector(halfWidth, -halfHeight),
      Flut5Vector(halfWidth, halfHeight),
      Flut5Vector(-halfWidth, halfHeight),
    ];
  }

  static double _inertia(double width, double height) =>
      (width * width + height * height) / 12;
}

/// A convex outline checked and measured once: its corners centered on its
/// center of mass and ordered clockwise on screen, and how its area spreads
/// around that center.
final class _ConvexShape {
  _ConvexShape._(this.corners, this.centerX, this.centerY, this.inertiaPerMass);

  /// Validates [given] and measures it. See [Flut5PhysicsPolygon.new] for
  /// what is rejected.
  factory _ConvexShape.from(List<Flut5Vector> given) {
    if (given.length < 3) {
      throw ArgumentError(
        'A polygon needs at least 3 corners, got ${given.length}',
      );
    }
    final count = given.length;
    for (var i = 0; i < count; i++) {
      final next = given[(i + 1) % count];
      if (given[i].x == next.x && given[i].y == next.y) {
        throw ArgumentError(
          'Polygon corners $i and ${(i + 1) % count} are the same point',
        );
      }
    }

    // Twice the signed area: positive when the corners run clockwise on
    // screen (y down), the order every edge normal below assumes.
    var doubleArea = 0.0;
    for (var i = 0; i < count; i++) {
      doubleArea += _cross(given[i], given[(i + 1) % count]);
    }
    if (doubleArea.abs() < 1e-9) {
      throw ArgumentError('Polygon corners enclose no area');
    }
    final ordered = doubleArea > 0 ? given : given.reversed.toList();

    // A dent is a corner where the outline turns the other way.
    for (var i = 0; i < count; i++) {
      final a = ordered[i];
      final b = ordered[(i + 1) % count];
      final c = ordered[(i + 2) % count];
      final turn = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (turn < -1e-9) {
        throw ArgumentError(
          'Polygons must be convex, but the corner at '
          '(${b.x}, ${b.y}) makes a dent. Build concave shapes from '
          'several convex polygons.',
        );
      }
    }

    // Center of mass: the area-weighted center of the triangles fanning out
    // from the origin to each edge.
    var centerX = 0.0, centerY = 0.0;
    for (var i = 0; i < count; i++) {
      final a = ordered[i], b = ordered[(i + 1) % count];
      final triangleArea = _cross(a, b);
      centerX += (a.x + b.x) * triangleArea;
      centerY += (a.y + b.y) * triangleArea;
    }
    final absoluteArea = doubleArea.abs();
    centerX /= 3 * absoluteArea;
    centerY /= 3 * absoluteArea;

    final centered = [
      for (final corner in ordered)
        Flut5Vector(corner.x - centerX, corner.y - centerY),
    ];

    // Moment of inertia per unit mass around the center: the same fan of
    // triangles, each weighted by its area.
    var inertiaSum = 0.0;
    for (var i = 0; i < count; i++) {
      final a = centered[i], b = centered[(i + 1) % count];
      inertiaSum += _cross(a, b) * (a.dot(a) + a.dot(b) + b.dot(b));
    }
    final inertiaPerMass = inertiaSum / (6 * absoluteArea);

    return _ConvexShape._(centered, centerX, centerY, inertiaPerMass);
  }

  final List<Flut5Vector> corners;
  final double centerX;
  final double centerY;
  final double inertiaPerMass;

  /// The z part of `a × b` for two flat vectors.
  static double _cross(Flut5Vector a, Flut5Vector b) => a.x * b.y - a.y * b.x;
}
