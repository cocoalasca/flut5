import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

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
///
/// [windowSize] reports the sketch's canvas size for
/// [windowBoundsCollision]; the sketch's engine wires it up. Without it the
/// window bounds never collide.
final class Flut5PhysicsEngine({Size Function()? windowSize}) {
  final Size Function()? _windowSize = windowSize;

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

  double _windowBoundsRestitution = 1.0;

  /// How bouncy the window edges are: the share of a particle's speed into
  /// a wall that it keeps, reversed, after hitting it. `1` (default) bounces
  /// back at full speed, `0.5` at half, `0` stops dead against the wall;
  /// above `1` every bounce adds energy. Must be >= 0. Sketches usually set
  /// it with `windowBoundsRestitution(e)`.
  double get windowBoundsRestitution => _windowBoundsRestitution;
  set windowBoundsRestitution(double e) {
    if (e < 0) {
      throw ArgumentError.value(e, 'e', 'Restitution must be >= 0');
    }
    _windowBoundsRestitution = e;
  }

  bool _particleCollision = false;
  int _collisionIterations = 2;

  /// Makes particles bounce off each other. Off by default.
  ///
  /// Two particles touch when the distance between their centers is less
  /// than the sum of their `radius`es, so a particle with radius `0` only
  /// collides with ones that have a radius. On contact they are pushed apart
  /// until they just touch — the lighter one moving more — and, if they were
  /// approaching, exchange an impulse along the line between their centers:
  /// heavier particles push lighter ones around, and how much of their
  /// approach speed bounces back is [particleRestitution].
  ///
  /// Every pair is tested each frame, so the cost grows with the square of
  /// the particle count. [iterations] repeats the collision pass (and the
  /// window walls, if on) that many times per frame: piles and stacks
  /// overlap less and settle faster with more, at that many times the cost.
  /// Defaults to `2`; `1` is the plain single pass. Turn collisions off again
  /// with [noParticleCollision].
  void particleCollision({int iterations = 2}) {
    if (iterations < 1) {
      throw ArgumentError.value(iterations, 'iterations', 'Must be >= 1');
    }
    _particleCollision = true;
    _collisionIterations = iterations;
  }

  /// Turns off collisions between particles.
  void noParticleCollision() => _particleCollision = false;

  double _particleRestitution = 1.0;

  /// How bouncy collisions between particles are: the share of their
  /// approach speed that bounces back. `1` (default) is a perfectly elastic
  /// bounce, `0` makes them stick together along the hit; above `1` every
  /// hit adds energy. Must be >= 0. Sketches usually set it with
  /// `particleRestitution(e)`.
  double get particleRestitution => _particleRestitution;
  set particleRestitution(double e) {
    if (e < 0) {
      throw ArgumentError.value(e, 'e', 'Restitution must be >= 0');
    }
    _particleRestitution = e;
  }

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
  /// `euler` step with [gravity] and resets its acceleration). Then, with
  /// [particleCollision] on, overlapping particles bounce off each other, and
  /// particles past an edge enabled with [windowBoundsCollision] bounce off
  /// it. Runs automatically before or after `draw()` per [updateTiming]; call
  /// it yourself when that is [PhysicsUpdateTiming.manual].
  void update() {
    _compact();
    for (final body in _bodies) {
      body.accumulateForces(this);
    }
    for (final body in _bodies) {
      body.updatePhysics(this);
    }
    final bounds = _boundsLeft || _boundsTop || _boundsRight || _boundsBottom;
    if (_particleCollision) {
      // Walls run inside every pass, not once after them all: a particle a
      // collision pushed into a wall is pushed back out before the next
      // pass, so a pile resting on the floor is held up by it.
      for (var pass = 0; pass < _collisionIterations; pass++) {
        _collideParticles();
        if (bounds) _collideWindowBounds();
      }
    } else if (bounds) {
      _collideWindowBounds();
    }
  }

  /// Each particle's x, y, z and radius, packed while the collision pass
  /// runs so the pair loop walks one flat buffer instead of chasing every
  /// particle's position object. Grows with the particle count.
  Float64List _packed = Float64List(0);

  /// Separates every overlapping pair of particles and bounces the ones that
  /// are approaching each other, testing each pair once.
  void _collideParticles() {
    final particles = _particles;
    final n = particles.length;
    if (_packed.length < n * 4) _packed = Float64List(n * 8);
    final s = _packed;
    for (var i = 0, k = 0; i < n; i++, k += 4) {
      final p = particles[i];
      final position = p.position;
      s[k] = position.x;
      s[k + 1] = position.y;
      s[k + 2] = position.z;
      s[k + 3] = p.radius;
    }

    final e = _particleRestitution;
    for (var i = 0, ka = 0; i < n; i++, ka += 4) {
      var ax = s[ka], ay = s[ka + 1], az = s[ka + 2];
      final ra = s[ka + 3];
      for (var j = i + 1, kb = ka + 4; j < n; j++, kb += 4) {
        final minDist = ra + s[kb + 3];
        final dx = s[kb] - ax;
        final dy = s[kb + 1] - ay;
        final dz = s[kb + 2] - az;
        final distSq = dx * dx + dy * dy + dz * dz;
        if (distSq >= minDist * minDist) continue;
        _collide(
          particles[i],
          particles[j],
          s,
          ka,
          kb,
          dx,
          dy,
          dz,
          distSq,
          minDist,
          e,
        );
        // The collision moved a; keep testing from where it is now.
        ax = s[ka];
        ay = s[ka + 1];
        az = s[ka + 2];
      }
    }

    for (var i = 0, k = 0; i < n; i++, k += 4) {
      particles[i].position.setValues(s[k], s[k + 1], s[k + 2]);
    }
  }

  /// Resolves one overlapping pair. [ka] and [kb] are the pair's offsets in
  /// the packed buffer [s], where their positions are moved; [dx], [dy],
  /// [dz] run from [a] to [b], [distSq] is their squared length and
  /// [minDist] the distance at which the two just touch.
  static void _collide(
    Flut5PhysicsParticle a,
    Flut5PhysicsParticle b,
    Float64List s,
    int ka,
    int kb,
    double dx,
    double dy,
    double dz,
    double distSq,
    double minDist,
    double e,
  ) {
    final dist = math.sqrt(distSq);
    // Unit normal from a to b. Particles exactly on top of each other have
    // no direction between them; split them along x so they don't stay
    // stuck together.
    var nx = 1.0, ny = 0.0, nz = 0.0;
    if (dist > 0) {
      nx = dx / dist;
      ny = dy / dist;
      nz = dz / dist;
    }

    final invMassA = 1 / a.mass;
    final invMassB = 1 / b.mass;
    final invMassSum = invMassA + invMassB;

    // Push them apart until they just touch, the lighter one moving more.
    final push = (minDist - dist) / invMassSum;
    final pushA = push * invMassA;
    final pushB = push * invMassB;
    s[ka] -= nx * pushA;
    s[ka + 1] -= ny * pushA;
    s[ka + 2] -= nz * pushA;
    s[kb] += nx * pushB;
    s[kb + 1] += ny * pushB;
    s[kb + 2] += nz * pushB;

    // Speed at which b moves away from a along the normal; negative means
    // they are closing in, so bounce them with an impulse along the normal.
    final va = a.velocity;
    final vb = b.velocity;
    final separation =
        (vb.x - va.x) * nx + (vb.y - va.y) * ny + (vb.z - va.z) * nz;
    if (separation >= 0) return;
    final impulse = -(1 + e) * separation / invMassSum;
    final impulseA = impulse * invMassA;
    final impulseB = impulse * invMassB;
    va
      ..x -= nx * impulseA
      ..y -= ny * impulseA
      ..z -= nz * impulseA;
    vb
      ..x += nx * impulseB
      ..y += ny * impulseB
      ..z += nz * impulseB;
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
    final minX = _boundsLeft ? 0.0 : double.negativeInfinity;
    final minY = _boundsTop ? 0.0 : double.negativeInfinity;
    final maxX = _boundsRight ? size.width : double.infinity;
    final maxY = _boundsBottom ? size.height : double.infinity;
    final e = _windowBoundsRestitution;
    final gx = gravity.x;
    final gy = gravity.y;

    for (final p in _particles) {
      final r = p.radius;
      final x = p.position.x;
      if (x < minX + r) {
        _bounce(p, 0, minX + r, -1, gx, e);
      } else if (x > maxX - r) {
        _bounce(p, 0, maxX - r, 1, gx, e);
      }
      final y = p.position.y;
      if (y < minY + r) {
        _bounce(p, 1, minY + r, -1, gy, e);
      } else if (y > maxY - r) {
        _bounce(p, 1, maxY - r, 1, gy, e);
      }
    }
  }

  /// Bounces [p] along [axis] (0 = x, 1 = y) off the wall at [wall], which
  /// [p] has crossed. [side] is `1` for a wall on the high side of the axis
  /// (right, bottom) and `-1` for one on the low side, so `value * side` is
  /// positive toward the wall. [g] is gravity along [axis].
  static void _bounce(
    Flut5PhysicsParticle p,
    int axis,
    double wall,
    double side,
    double g,
    double e,
  ) {
    final position = p.position;
    final velocity = p.velocity;
    final speed = velocity[axis] * side;
    if (speed <= 0) {
      // Already heading back inside, e.g. the window shrank past it.
      position[axis] = wall;
    } else if (speed <= g * side) {
      // No faster than one frame of gravity toward the wall: resting on it.
      position[axis] = wall;
      velocity[axis] = 0;
    } else {
      final overshoot = (position[axis] - wall) * side;
      position[axis] = wall - math.min(overshoot, speed) * e * side;
      velocity[axis] = -velocity[axis] * e;
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
