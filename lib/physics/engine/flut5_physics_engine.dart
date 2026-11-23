import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import '../../math/flut5_vector.dart';
import '../flut5_physics_body.dart';
import '../flut5_physics_collision_event.dart';
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
enum PhysicsUpdateTiming() {
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

  int _substeps = 1;

  /// Number of physics integration + collision substeps executed per [update]
  /// call. Defaults to `1`. Increasing to `2`–`4` scales per-substep gravity,
  /// acceleration, and displacement by `1 / substeps` to cut high-speed
  /// tunneling and stabilize stiff springs without changing overall motion
  /// speed.
  int get substeps => _substeps;
  set substeps(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'substeps', 'Must be >= 1');
    }
    _substeps = value;
  }

  double _stepScale = 1.0;

  /// Current substep fraction (`1 / substeps`) read by rigid-body integration.
  double get stepScale => _stepScale;

  /// Enables automatic sleeping for settled rigid bodies. Off (`false`) by
  /// default so existing simulations remain bit-identical. When enabled, calm
  /// bodies below [sleepSpeedThreshold] and [sleepAngularThreshold] for
  /// [sleepFrames] consecutive updates stop integrating and skip
  /// sleeping-vs-sleeping/static collisions until woken.
  bool sleeping = false;

  /// Linear speed (pixels / frame) below which a body counts as calm when
  /// [sleeping] is enabled.
  double sleepSpeedThreshold = 0.08;

  /// Angular speed (radians / frame) below which a body counts as calm when
  /// [sleeping] is enabled.
  double sleepAngularThreshold = 0.005;

  /// Consecutive calm frames required before a body transitions to sleep.
  int sleepFrames = 30;

  /// Optional callback fired once per colliding body pair per [update] step.
  /// Zero overhead when `null`.
  void Function(Flut5PhysicsCollisionEvent event)? onCollision;

  /// Per-update deduplication set for [onCollision] so a pair touching across
  /// multiple [collisionIterations] or [substeps] triggers the callback once.
  final Set<int> _notifiedPairs = HashSet<int>();

  @override
  void _notifyCollision(
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double normalX,
    double normalY,
    double normalZ,
    double overlap,
  ) {
    final cb = onCollision;
    if (cb == null) return;
    final ha = identityHashCode(a);
    final hb = identityHashCode(b);
    final key = ha < hb
        ? Object.hash(ha, hb)
        : Object.hash(hb, ha);
    if (!_notifiedPairs.add(key)) return;
    cb(
      Flut5PhysicsCollisionEvent(
        bodyA: a,
        bodyB: b,
        normal: Flut5Vector(normalX, normalY, normalZ),
        overlap: overlap,
      ),
    );
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
    _compactSoftBodies();
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
    _softBodySolvings.clear();
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
    if (onCollision != null) _notifiedPairs.clear();
    final steps = _substeps;
    _stepScale = steps == 1 ? 1.0 : 1.0 / steps;
    if (sleeping) _wakeManuallyMovedBodies();
    for (var s = 0; s < steps; s++) {
      _stepOnce();
    }
    _stepScale = 1.0;
    if (sleeping) _updateSleepingBodies();
  }

  void _stepOnce() {
    // Monomorphic loops: only springs accumulate forces, and only particles
    // and polygons integrate motion — skips empty virtual calls and keeps
    // call sites monomorphic.
    final springs = _springs;
    for (var i = 0; i < springs.length; i++) {
      springs[i].accumulateForces(this);
    }
    final particles = _particles;
    for (var i = 0; i < particles.length; i++) {
      particles[i].updatePhysics(this);
    }
    final polygons = _polygons;
    for (var i = 0; i < polygons.length; i++) {
      polygons[i].updatePhysics(this);
    }
    final windowEdges = _hasWindowEdges;
    final hasPolygons = polygons.isNotEmpty;
    final hasSoftBodies = _softBodies.isNotEmpty;
    if (_particleCollision || hasPolygons || hasSoftBodies) {
      // Walls run inside every pass, not once after them all: a body a
      // collision pushed into a wall is pushed back out before the next
      // pass, so a pile resting on the floor is held up by it.
      for (var pass = 0; pass < _collisionIterations; pass++) {
        if (hasSoftBodies) _reshapeSoftBodies();
        var gridFresh = false;
        if (_particleCollision) {
          gridFresh = _collideParticles();
        }
        if (hasPolygons) {
          _collidePolygons(reuseParticleGrid: gridFresh);
        }
        if (windowEdges) {
          _collideWindowBounds();
          if (hasPolygons) _collidePolygonsWithWindow();
        }
      }
    } else if (windowEdges) {
      _collideWindowBounds();
    }
  }

  void _wakeManuallyMovedBodies() {
    final speedSq = sleepSpeedThreshold * sleepSpeedThreshold;
    final angThresh = sleepAngularThreshold;
    for (var i = 0; i < _particles.length; i++) {
      final p = _particles[i];
      if (!p.isSleeping) continue;
      if (p.velocity.length2 > speedSq ||
          p.angularVelocity.abs() > angThresh ||
          p.acceleration.length2 > 0) {
        p.wake();
      }
    }
    for (var i = 0; i < _polygons.length; i++) {
      final p = _polygons[i];
      if (!p.isSleeping) continue;
      if (p.velocity.length2 > speedSq ||
          p.angularVelocity.abs() > angThresh ||
          p.acceleration.length2 > 0) {
        p.wake();
      }
    }
  }

  void _updateSleepingBodies() {
    final speedSq = sleepSpeedThreshold * sleepSpeedThreshold;
    final angThresh = sleepAngularThreshold;
    final frames = sleepFrames < 1 ? 1 : sleepFrames;
    for (var i = 0; i < _particles.length; i++) {
      final p = _particles[i];
      if (p.isStatic || p.softBody != null) continue;
      final calm =
          p.velocity.length2 <= speedSq && p.angularVelocity.abs() <= angThresh;
      p.updateSleepCounter(calm, frames);
    }
    for (var i = 0; i < _polygons.length; i++) {
      final p = _polygons[i];
      if (p.isStatic) continue;
      final calm =
          p.velocity.length2 <= speedSq && p.angularVelocity.abs() <= angThresh;
      p.updateSleepCounter(calm, frames);
    }
  }

  /// Casts a 2-D ray from ([rayX], [rayY]) along ([dirX], [dirY]) against live
  /// bodies in this physics world, returning the closest [Flut5PhysicsRayHit]
  /// within [maxDistance], or `null` if nothing is struck.
  ///
  /// Direction does not need to be normalized. Set [includePolygons] or
  /// [includeParticles] to filter body types.
  Flut5PhysicsRayHit? castRayClosest(
    double rayX,
    double rayY,
    double dirX,
    double dirY, {
    double maxDistance = double.infinity,
    bool includePolygons = true,
    bool includeParticles = true,
  }) {
    _compact();
    if (maxDistance < 0.0) return null;
    final lenSq = dirX * dirX + dirY * dirY;
    if (lenSq == 0.0 || !lenSq.isFinite) return null;
    final invLen = 1.0 / math.sqrt(lenSq);
    final ndx = dirX * invLen;
    final ndy = dirY * invLen;

    Flut5PhysicsRigidBody? bestBody;
    var bestT = maxDistance;
    var bestNx = 0.0;
    var bestNy = 0.0;

    if (includePolygons && _polygons.isNotEmpty) {
      _refreshPolygonShapes();
      final invDx = ndx == 0.0 ? double.infinity : 1.0 / ndx;
      final invDy = ndy == 0.0 ? double.infinity : 1.0 / ndy;
      for (var i = 0; i < _polygonShapes.length; i++) {
        final shape = _polygonShapes[i];
        if (!_rayHitsAabb(
          rayX,
          rayY,
          invDx,
          invDy,
          shape.minX - 1e-7,
          shape.minY - 1e-7,
          shape.maxX + 1e-7,
          shape.maxY + 1e-7,
          bestT,
        )) {
          continue;
        }
        final count = shape.count;
        final cx = shape.cornerX;
        final cy = shape.cornerY;
        for (var e = 0; e < count; e++) {
          final next = e + 1 == count ? 0 : e + 1;
          final ex = cx[next] - cx[e];
          final ey = cy[next] - cy[e];
          final den = ndx * ey - ndy * ex;
          if (den == 0.0) continue;
          final gx = cx[e] - rayX;
          final gy = cy[e] - rayY;
          final double t;
          if (den > 0.0) {
            final tol = 1e-9 * den;
            final uNum = gx * ndy - gy * ndx;
            if (uNum < -tol || uNum > den + tol) continue;
            final tNum = gx * ey - gy * ex;
            if (tNum < -tol) continue;
            if (bestT.isFinite && tNum >= bestT * den) continue;
            t = tNum / den;
          } else {
            final negDen = -den;
            final tol = 1e-9 * negDen;
            final uNum = -(gx * ndy - gy * ndx);
            if (uNum < -tol || uNum > negDen + tol) continue;
            final tNum = -(gx * ey - gy * ex);
            if (tNum < -tol) continue;
            if (bestT.isFinite && tNum >= bestT * negDen) continue;
            t = tNum / negDen;
          }
          if (t < bestT) {
            bestT = t;
            bestBody = shape.polygon;
            var nx = shape.normalX[e];
            var ny = shape.normalY[e];
            if (nx * ndx + ny * ndy > 0.0) {
              nx = -nx;
              ny = -ny;
            }
            bestNx = nx;
            bestNy = ny;
          }
        }
      }
    }

    if (includeParticles) {
      for (var i = 0; i < _particles.length; i++) {
        final p = _particles[i];
        final r = p.radius;
        if (r <= 0.0) continue;
        final ocx = rayX - p.position.x;
        final ocy = rayY - p.position.y;
        final hb = ocx * ndx + ocy * ndy;
        final c = ocx * ocx + ocy * ocy - r * r;
        final disc = hb * hb - c;
        if (disc < 0.0) continue;
        final sqrtDisc = math.sqrt(disc);
        var t = -hb - sqrtDisc;
        if (t < -1e-9) {
          t = -hb + sqrtDisc;
          if (t < -1e-9) continue;
        }
        if (t < 0.0) t = 0.0;
        if (t < bestT) {
          bestT = t;
          bestBody = p;
          final hx = rayX + t * ndx;
          final hy = rayY + t * ndy;
          var nx = (hx - p.position.x) / r;
          var ny = (hy - p.position.y) / r;
          if (nx * ndx + ny * ndy > 0.0) {
            nx = -nx;
            ny = -ny;
          }
          bestNx = nx;
          bestNy = ny;
        }
      }
    }

    if (bestBody == null) return null;
    final dist = bestT < 0.0 ? 0.0 : bestT;
    return Flut5PhysicsRayHit(
      body: bestBody,
      point: Flut5Vector(rayX + dist * ndx, rayY + dist * ndy),
      distance: dist,
      normal: Flut5Vector(bestNx, bestNy),
    );
  }

  /// Casts a 2-D ray from ([rayX], [rayY]) along ([dirX], [dirY]) against live
  /// bodies in this physics world, returning every [Flut5PhysicsRayHit] within
  /// [maxDistance], sorted closest-first (at most one closest entry hit per
  /// body).
  List<Flut5PhysicsRayHit> castRay(
    double rayX,
    double rayY,
    double dirX,
    double dirY, {
    double maxDistance = double.infinity,
    bool includePolygons = true,
    bool includeParticles = true,
  }) {
    _compact();
    if (maxDistance < 0.0) return const [];
    final lenSq = dirX * dirX + dirY * dirY;
    if (lenSq == 0.0 || !lenSq.isFinite) return const [];
    final invLen = 1.0 / math.sqrt(lenSq);
    final ndx = dirX * invLen;
    final ndy = dirY * invLen;

    final hits = <Flut5PhysicsRayHit>[];

    if (includePolygons && _polygons.isNotEmpty) {
      _refreshPolygonShapes();
      final invDx = ndx == 0.0 ? double.infinity : 1.0 / ndx;
      final invDy = ndy == 0.0 ? double.infinity : 1.0 / ndy;
      for (var i = 0; i < _polygonShapes.length; i++) {
        final shape = _polygonShapes[i];
        if (!_rayHitsAabb(
          rayX,
          rayY,
          invDx,
          invDy,
          shape.minX - 1e-7,
          shape.minY - 1e-7,
          shape.maxX + 1e-7,
          shape.maxY + 1e-7,
          maxDistance,
        )) {
          continue;
        }
        var polyBestT = maxDistance;
        var polyNx = 0.0;
        var polyNy = 0.0;
        var hitPoly = false;
        final count = shape.count;
        final cx = shape.cornerX;
        final cy = shape.cornerY;
        for (var e = 0; e < count; e++) {
          final next = e + 1 == count ? 0 : e + 1;
          final ex = cx[next] - cx[e];
          final ey = cy[next] - cy[e];
          final den = ndx * ey - ndy * ex;
          if (den == 0.0) continue;
          final gx = cx[e] - rayX;
          final gy = cy[e] - rayY;
          final double t;
          if (den > 0.0) {
            final tol = 1e-9 * den;
            final uNum = gx * ndy - gy * ndx;
            if (uNum < -tol || uNum > den + tol) continue;
            final tNum = gx * ey - gy * ex;
            if (tNum < -tol) continue;
            if (polyBestT.isFinite && tNum > polyBestT * den) continue;
            t = tNum / den;
          } else {
            final negDen = -den;
            final tol = 1e-9 * negDen;
            final uNum = -(gx * ndy - gy * ndx);
            if (uNum < -tol || uNum > negDen + tol) continue;
            final tNum = -(gx * ey - gy * ex);
            if (tNum < -tol) continue;
            if (polyBestT.isFinite && tNum > polyBestT * negDen) continue;
            t = tNum / negDen;
          }
          if (t <= polyBestT) {
            polyBestT = t;
            hitPoly = true;
            var nx = shape.normalX[e];
            var ny = shape.normalY[e];
            if (nx * ndx + ny * ndy > 0.0) {
              nx = -nx;
              ny = -ny;
            }
            polyNx = nx;
            polyNy = ny;
          }
        }
        if (hitPoly) {
          final dist = polyBestT < 0.0 ? 0.0 : polyBestT;
          hits.add(
            Flut5PhysicsRayHit(
              body: shape.polygon,
              point: Flut5Vector(rayX + dist * ndx, rayY + dist * ndy),
              distance: dist,
              normal: Flut5Vector(polyNx, polyNy),
            ),
          );
        }
      }
    }

    if (includeParticles) {
      for (var i = 0; i < _particles.length; i++) {
        final p = _particles[i];
        final r = p.radius;
        if (r <= 0.0) continue;
        final ocx = rayX - p.position.x;
        final ocy = rayY - p.position.y;
        final hb = ocx * ndx + ocy * ndy;
        final c = ocx * ocx + ocy * ocy - r * r;
        final disc = hb * hb - c;
        if (disc < 0.0) continue;
        final sqrtDisc = math.sqrt(disc);
        var t = -hb - sqrtDisc;
        if (t < -1e-9) {
          t = -hb + sqrtDisc;
          if (t < -1e-9) continue;
        }
        if (t < 0.0) t = 0.0;
        if (t <= maxDistance) {
          final hx = rayX + t * ndx;
          final hy = rayY + t * ndy;
          var nx = (hx - p.position.x) / r;
          var ny = (hy - p.position.y) / r;
          if (nx * ndx + ny * ndy > 0.0) {
            nx = -nx;
            ny = -ny;
          }
          hits.add(
            Flut5PhysicsRayHit(
              body: p,
              point: Flut5Vector(hx, hy),
              distance: t,
              normal: Flut5Vector(nx, ny),
            ),
          );
        }
      }
    }

    if (hits.length > 1) {
      hits.sort((a, b) => a.distance.compareTo(b.distance));
    }
    return hits;
  }

  static bool _rayHitsAabb(
    double rayX,
    double rayY,
    double invDx,
    double invDy,
    double minX,
    double minY,
    double maxX,
    double maxY,
    double maxDist,
  ) {
    var tMin = 0.0;
    var tMax = maxDist;
    if (invDx.isFinite) {
      final t1 = (minX - rayX) * invDx;
      final t2 = (maxX - rayX) * invDx;
      final lo = t1 < t2 ? t1 : t2;
      final hi = t1 < t2 ? t2 : t1;
      if (lo > tMin) tMin = lo;
      if (hi < tMax) tMax = hi;
      if (tMax < tMin) return false;
    } else if (rayX < minX || rayX > maxX) {
      return false;
    }
    if (invDy.isFinite) {
      final t1 = (minY - rayY) * invDy;
      final t2 = (maxY - rayY) * invDy;
      final lo = t1 < t2 ? t1 : t2;
      final hi = t1 < t2 ? t2 : t1;
      if (lo > tMin) tMin = lo;
      if (hi < tMax) tMax = hi;
      if (tMax < tMin) return false;
    } else if (rayY < minY || rayY > maxY) {
      return false;
    }
    return true;
  }
}

/// Read-only view of one of the engine's body lists that drops removed
/// bodies before every read — see [Flut5PhysicsEngine.remove].
final class _BodyListView<T extends Flut5PhysicsBody>(
  final Flut5PhysicsEngine _engine,
  final List<T> _list,
) extends ListBase<T> {
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
final class _BodyListIterator<T>(
  final Flut5PhysicsEngine _engine,
  final List<T> _list,
) implements Iterator<T> {
  this : _length = _list.length;

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
