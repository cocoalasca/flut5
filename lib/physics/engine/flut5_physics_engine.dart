import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import '../../math/flut5_vector.dart';
import '../flut5_physics_body.dart';
import '../flut5_physics_particle.dart';
import '../flut5_physics_polygon.dart';
import '../flut5_physics_rigid_body.dart';
import '../flut5_physics_spring.dart';

// The engine's API is split by category, one part file each, as private
// mixins applied to [Flut5PhysicsEngine]. This file keeps what they share:
// the body registry, gravity, and the per-frame [Flut5PhysicsEngine.update].
part 'flut5_physics_engine_particles.dart';
part 'flut5_physics_engine_particle_grid.dart';
part 'flut5_physics_engine_springs.dart';
part 'flut5_physics_engine_edges.dart';
part 'flut5_physics_engine_rotation.dart';
part 'flut5_physics_engine_polygons.dart';
part 'flut5_physics_engine_contacts.dart';
part 'flut5_physics_engine_soft_bodies.dart';

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
///
/// [windowSize] reports the sketch's canvas size for
/// [windowBoundsCollision]; the sketch's engine wires it up. Without it the
/// window bounds never collide.
final class Flut5PhysicsEngine({Size Function()? windowSize})
    with
        _PhysicsParticles,
        _PhysicsSprings,
        _PhysicsEdges,
        _PhysicsRotation,
        _PhysicsPolygons,
        _PhysicsSoftBodies {
  @override
  final Size Function()? _windowSize = windowSize;

  final List<Flut5PhysicsBody> _bodies = [];
  @override
  final List<Flut5PhysicsParticle> _particles = [];
  @override
  final List<Flut5PhysicsSpring> _springs = [];
  @override
  final List<Flut5PhysicsPolygon> _polygons = [];
  @override
  final List<Flut5PhysicsSoftBody> _softBodies = [];

  // Removal is deferred so a frame that retires many particles pays one pass
  // over the lists instead of one per particle: [remove] only unregisters
  // the body here, and [_compact] drops it from the lists before they are
  // next read (the public views compact on access) or stepped.
  @override
  final Set<Flut5PhysicsBody> _registered = HashSet.identity();

  /// Particles removed since the last [_compact]. A spring attached to one is
  /// already gone, though it still sits in the lists.
  @override
  final Set<Flut5PhysicsParticle> _removedParticles = HashSet.identity();
  bool _pendingRemoval = false;

  /// Soft bodies that lost a particle to [remove] while staying registered.
  /// Only these check, as they pull themselves back into shape, which of
  /// their particles are still there.
  @override
  final Set<Flut5PhysicsSoftBody> _tornSoftBodies = HashSet.identity();

  /// When [update] runs each frame: before `draw()` (default), after it, or
  /// never ([PhysicsUpdateTiming.manual]).
  PhysicsUpdateTiming updateTiming = .beforeDraw;

  /// World gravity, added to every body's velocity each [update] — an
  /// acceleration in pixels per frame², so it pulls light and heavy bodies
  /// alike (unlike forces passed to `applyForce`, which divide by mass).
  /// Defaults to zero. For plain downward gravity use [setGravity]; for any
  /// other direction assign a vector: `physicsEngine.gravity =
  /// createVector(0.05, 0.2);`
  @override
  Flut5Vector gravity = Flut5Vector.zero();

  /// Sets [gravity] to straight down (`0, y`) with strength [y]. Negative
  /// values pull up; `0` turns gravity off. Replaces any custom x component.
  void setGravity(double y) => gravity = Flut5Vector(0, y);

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

  /// Every registered polygon — rects included — in creation order.
  /// Read-only view, safe to iterate in `draw()`.
  late final List<Flut5PhysicsPolygon> polygons = _BodyListView(
    this,
    _polygons,
  );

  /// Every registered soft body, in creation order. Their particles are
  /// also in [particles]. Read-only view, safe to iterate in `draw()`.
  late final List<Flut5PhysicsSoftBody> softBodies = _BodyListView(
    this,
    _softBodies,
  );

  int _collisionIterations = 2;

  /// How many collision passes run per frame — particles against particles,
  /// polygons against everything, and the window edges inside each pass.
  /// Piles and stacks overlap less and settle faster with more, at that
  /// many times the cost. Defaults to `2`; must be >= 1.
  int get collisionIterations => _collisionIterations;
  @override
  set collisionIterations(int iterations) {
    if (iterations < 1) {
      throw ArgumentError.value(iterations, 'iterations', 'Must be >= 1');
    }
    _collisionIterations = iterations;
  }

  /// Adds [body] to the registry and the list of every body. The `create…`
  /// methods call this, then add the body to its own kind's list.
  @override
  void _register(Flut5PhysicsBody body) {
    _registered.add(body);
    _bodies.add(body);
  }

  /// Unregisters [body] so [update] stops stepping it. Returns whether it was
  /// registered.
  ///
  /// Removing a particle also removes every spring attached to it, so no
  /// spring keeps tugging toward a particle that no longer moves. Removing a
  /// soft body removes its particles too; removing one of its particles on
  /// its own tears it there.
  ///
  /// Constant time, so retiring many particles a frame stays cheap: the
  /// lists drop removed bodies in one pass, the next time they are read or
  /// stepped. Like any list, they can't be changed while being iterated —
  /// collect what to remove, then remove it after the loop.
  bool remove(Flut5PhysicsBody body) {
    if (body is Flut5PhysicsSpring && !_springAttached(body)) return false;
    if (!_registered.remove(body)) return false;
    if (body is Flut5PhysicsParticle) {
      _removedParticles.add(body);
      final softBody = body.softBody;
      if (softBody != null) _tornSoftBodies.add(softBody);
    }
    if (body is Flut5PhysicsSoftBody) {
      for (final particle in body.particles) {
        if (_registered.remove(particle)) _removedParticles.add(particle);
      }
    }
    _pendingRemoval = true;
    return true;
  }

  /// Drops removed bodies — and springs attached to removed particles — from
  /// the lists, keeping creation order. One pass however many were removed.
  @override
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
    _polygons.removeWhere((p) => !_registered.contains(p));
    _softBodies.removeWhere((s) => !_registered.contains(s));
    _tornSoftBodies.removeWhere((s) => !_registered.contains(s));
  }

  /// Unregisters every body. The framework calls this before each `setup()`
  /// run so hot reload doesn't duplicate bodies.
  void clear() {
    _bodies.clear();
    _particles.clear();
    _springs.clear();
    _polygons.clear();
    _softBodies.clear();
    _tornSoftBodies.clear();
    _registered.clear();
    _removedParticles.clear();
    _pendingRemoval = false;
  }

  /// Steps every registered body by one frame in two passes: first every
  /// body's `accumulateForces` (springs call `applyForce` on their
  /// particles), then every body's `updatePhysics` (each particle runs its
  /// `euler` step with [gravity], resets its acceleration and turns per
  /// [rotationMode]). Then [collisionIterations] collision passes: soft
  /// bodies' springs pull their particles back into shape; with
  /// [particleCollision] on, overlapping particles bounce off each other;
  /// polygons bounce off each other and off particles; and bodies past an
  /// edge enabled with [windowBoundsCollision] bounce off it. Runs
  /// automatically before or after `draw()` per [updateTiming]; call it
  /// yourself when that is [PhysicsUpdateTiming.manual].
  void update() {
    _compact();
    for (final body in _bodies) {
      body.accumulateForces(this);
    }
    for (final body in _bodies) {
      body.updatePhysics(this);
    }
    final windowEdges = _hasWindowEdges;
    final hasPolygons = _polygons.isNotEmpty;
    final hasSoftBodies = _softBodies.isNotEmpty;
    if (_particleCollision || hasPolygons || hasSoftBodies) {
      // Walls run inside every pass, not once after them all: a body a
      // collision pushed into a wall is pushed back out before the next
      // pass, so a pile resting on the floor is held up by it.
      for (var pass = 0; pass < _collisionIterations; pass++) {
        if (hasSoftBodies) _reshapeSoftBodies();
        if (_particleCollision) _collideParticles();
        if (hasPolygons) _collidePolygons();
        if (windowEdges) {
          _collideWindowBounds();
          if (hasPolygons) _collidePolygonsWithWindow();
        }
      }
    } else if (windowEdges) {
      _collideWindowBounds();
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

  /// Drops removed bodies once, then walks the list directly — `for (final
  /// p in physicsEngine.particles)` in `draw()` would otherwise check for
  /// removals twice per body.
  @override
  Iterator<T> get iterator {
    _engine._compact();
    return _BodyListIterator(_engine, _list);
  }
}

/// Walks one of the engine's body lists. Like any list's iterator, it throws
/// a [ConcurrentModificationError] if a body is added or removed while it
/// runs — collect what to remove, then remove it after the loop.
final class _BodyListIterator<T> implements Iterator<T> {
  _BodyListIterator(this._engine, this._list) : _length = _list.length;

  final Flut5PhysicsEngine _engine;
  final List<T> _list;
  final int _length;
  int _index = 0;
  T? _current;

  @override
  T get current => _current as T;

  @override
  bool moveNext() {
    if (_engine._pendingRemoval || _list.length != _length) {
      throw ConcurrentModificationError(_list);
    }
    if (_index == _length) {
      _current = null;
      return false;
    }
    _current = _list[_index++];
    return true;
  }
}
