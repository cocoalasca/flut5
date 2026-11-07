/// A position in a [Flut5Quadtree] carrying any data you want to find again
/// by area.
///
/// [x] and [y] are in the tree's own coordinates (`0..width`, `0..height`).
/// [payload] is whatever the point stands for — a particle, an index, a
/// color, a record. Its type is up to you: leave it out and it is `dynamic`,
/// or name it to keep the payload typed through [Flut5Quadtree.query]:
///
/// ```dart
/// final tree = Flut5Quadtree<Flut5PhysicsParticle>(width, height);
/// for (final p in physicsEngine.particles) {
///   tree.add(Flut5QuadtreePoint(p.x, p.y, p));
/// }
/// ```
///
/// The position is fixed: the tree files a point by where it was when it was
/// added, so a point that moves has to go into a fresh tree. Rebuilding the
/// tree each frame is the usual way.
final class Flut5QuadtreePoint<T>(
  /// Horizontal position in the tree's coordinates.
  final double x,

  /// Vertical position in the tree's coordinates.
  final double y,

  /// The data this point stands for.
  final T payload,
) {
  @override
  String toString() => 'Flut5QuadtreePoint($x, $y, $payload)';
}
