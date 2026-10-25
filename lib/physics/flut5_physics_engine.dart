import 'dart:collection';

import '../math/flut5_vector.dart';
import 'flut5_physics_body.dart';
import 'flut5_physics_particle.dart';
import 'flut5_physics_spring.dart';

/// When the engine runs [Flut5PhysicsEngine.update] each frame.
enum PhysicsUpdateTiming {
  /// Step right before `draw()` (default), like a game loop's update →
  /// render. Draw always shows this frame's state, and forces applied from
  /// event handlers between frames are visible on the very next frame.
  beforeDraw,

  /// Step right after `draw()`. Same cadence as [beforeDraw] in steady
  /// state, but forces applied from event handlers wait one extra frame.
  afterDraw,

  /// Never step automatically; call `physicsEngine.update()` yourself
  /// (substeps, pausing, custom ordering).
  manual,
}

/// The sketch's physics world: creates bodies, keeps them in global lists
/// and steps all of them once per frame, before or after `draw()` per
/// [updateTiming].
///
/// Bodies are plain objects you keep a reference to and edit locally; the
/// physics engine owns the lists and the global update pass.
///
/// ```dart
/// void setup() {
///   physicsEngine.setGravity(0.2);
///   for (var i = 0; i < 10; i++) {
///     physicsEngine.createParticle(random(width), random(height));
///   }
/// }
///
/// void draw() {
///   for (final p in physicsEngine.particles) {
///     p.applyForce(springForce(p.position, anchor));
///     circle(p.x, p.y, 24);
///   }
///   // physicsEngine.update() runs before the next draw() (default)
/// }
/// ```
final class Flut5PhysicsEngine {
  final List<Flut5PhysicsBody> _bodies = [];
  final List<Flut5PhysicsParticle> _particles = [];
  final List<Flut5PhysicsSpring> _springs = [];

  // Removal is deferred so a frame that retires many particles pays one pass
  // over the lists instead of one per particle: [remove] only unregisters
  // the body here, and [_compact] drops it from the lists before they are
  // next read (the public views compact on access) or stepped.
  final Set<Flut5PhysicsBody> _registered = HashSet.identity();

  /// Particles removed since the last [_compact]. A spring attached to one is
  /// already gone, though it still sits in the lists.
  final Set<Flut5PhysicsParticle> _removedParticles = HashSet.identity();
  bool _pendingRemoval = false;

  /// When [update] runs each frame: before `draw()` (default), after it, or
  /// never ([PhysicsUpdateTiming.manual]).
  PhysicsUpdateTiming updateTiming = .beforeDraw;

  /// World gravity, added to every body's velocity each [update] — an
  /// acceleration in pixels per frame², so it pulls light and heavy bodies
  /// alike (unlike forces passed to `applyForce`, which divide by mass).
  /// Defaults to zero. For plain downward gravity use [setGravity]; for any
  /// other direction assign a vector: `physicsEngine.gravity =
  /// createVector(0.05, 0.2);`
  Flut5Vector gravity = Flut5Vector.zero();

  /// Sets [gravity] to straight down (`0, y`) with strength [y]. Negative
  /// values pull up; `0` turns gravity off. Replaces any custom x component.
  void setGravity(double y) => gravity = Flut5Vector(0, y);

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

  /// Every registered body of any kind, in creation order. Read-only view —
  /// add bodies with the `create…` methods and drop them with [remove].
  late final List<Flut5PhysicsBody> bodies = _BodyListView(this, _bodies);

  /// Every registered particle, in creation order. Read-only view, safe to
  /// iterate in `draw()`.
  late final List<Flut5PhysicsParticle> particles = _BodyListView(
    this,
    _particles,
  );

  /// Every registered spring, in creation order. Read-only view, safe to
  /// iterate in `draw()`.
  late final List<Flut5PhysicsSpring> springs = _BodyListView(this, _springs);

  /// Creates a [Flut5PhysicsParticle] at ([x], [y]), registers it and
  /// returns it.
  Flut5PhysicsParticle createParticle(double x, double y) {
    final particle = Flut5PhysicsParticle(x, y);
    _registered.add(particle);
    _bodies.add(particle);
    _particles.add(particle);
    return particle;
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
    _registered.add(spring);
    _bodies.add(spring);
    _springs.add(spring);
    return spring;
  }

  /// Unregisters [body] so [update] stops stepping it. Returns whether it was
  /// registered.
  ///
  /// Removing a particle also removes every spring attached to it, so no
  /// spring keeps tugging toward a particle that no longer moves.
  ///
  /// Constant time, so retiring many particles a frame stays cheap: the
  /// lists drop removed bodies in one pass, the next time they are read or
  /// stepped. Like any list, they can't be changed while being iterated —
  /// collect what to remove, then remove it after the loop.
  bool remove(Flut5PhysicsBody body) {
    if (body is Flut5PhysicsSpring && !_springAttached(body)) return false;
    if (!_registered.remove(body)) return false;
    if (body is Flut5PhysicsParticle) _removedParticles.add(body);
    _pendingRemoval = true;
    return true;
  }

  /// Whether neither end of [spring] has been removed since the last
  /// [_compact].
  bool _springAttached(Flut5PhysicsSpring spring) =>
      !_removedParticles.contains(spring.a) &&
      !_removedParticles.contains(spring.b);

  /// Drops removed bodies — and springs attached to removed particles — from
  /// the lists, keeping creation order. One pass however many were removed.
  void _compact() {
    if (!_pendingRemoval) return;
    _pendingRemoval = false;
    if (_removedParticles.isNotEmpty) {
      for (final spring in _springs) {
        if (!_springAttached(spring)) _registered.remove(spring);
      }
      _removedParticles.clear();
    }
    _bodies.removeWhere((b) => !_registered.contains(b));
    _particles.removeWhere((p) => !_registered.contains(p));
    _springs.removeWhere((s) => !_registered.contains(s));
  }

  /// Unregisters every body. The framework calls this before each `setup()`
  /// run so hot reload doesn't duplicate bodies.
  void clear() {
    _bodies.clear();
    _particles.clear();
    _springs.clear();
    _registered.clear();
    _removedParticles.clear();
    _pendingRemoval = false;
  }

  /// Steps every registered body by one frame in two passes: first every
  /// body's `accumulateForces` (springs call `applyForce` on their
  /// particles), then every body's `updatePhysics` (each particle runs its
  /// `euler` step with [gravity] and resets its acceleration). Runs automatically before or
  /// after `draw()` per [updateTiming]; call it yourself when that is
  /// [PhysicsUpdateTiming.manual].
  void update() {
    _compact();
    for (final body in _bodies) {
      body.accumulateForces(this);
    }
    for (final body in _bodies) {
      body.updatePhysics(this);
    }
  }
}

/// Read-only view of one of the engine's body lists that drops removed
/// bodies before every read — see [Flut5PhysicsEngine.remove].
final class _BodyListView<T extends Flut5PhysicsBody> extends ListBase<T> {
  _BodyListView(this._engine, this._list);

  final Flut5PhysicsEngine _engine;
  final List<T> _list;

  @override
  int get length {
    _engine._compact();
    return _list.length;
  }

  @override
  set length(int newLength) =>
      throw UnsupportedError('Cannot change the length of a read-only list');

  @override
  T operator [](int index) {
    _engine._compact();
    return _list[index];
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Cannot modify a read-only list');
}
