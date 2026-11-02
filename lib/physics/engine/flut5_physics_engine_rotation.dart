part of 'flut5_physics_engine.dart';

/// How particles turn. Set it with [Flut5PhysicsEngine.rotationMode]; draw a
/// particle turned with `rotate(p.angle)`.
enum PhysicsRotationMode {
  /// Particles never turn: the engine leaves `angle` and `angularVelocity`
  /// alone. The default, and the cheapest.
  none,

  /// Particles spin as if rolling along a floor below them, smoothed like the
  /// classic sketch trick (`angleV += vel.x * 0.002; angleV *= 0.95`): each
  /// frame their angular velocity keeps [Flut5PhysicsEngine.cosmeticSpinDecay]
  /// of itself (95% by default) and takes the rest from the rolling spin for
  /// their horizontal speed (`velocity.x / radius`) times
  /// [Flut5PhysicsEngine.cosmeticSpinScale]. Spin lags speed a little, eases
  /// through bounces and coasts to a stop when they do. A few operations per
  /// particle — but it's only a look: spin never changes how they move, and
  /// they spin in mid-air too.
  cosmetic,

  /// Real rotation. Friction where a particle touches another particle or a
  /// window edge turns it, and its spin pushes back: sliding balls start
  /// rolling, grazing hits set both spinning, and a spinning ball kicks
  /// sideways when it lands. Particles are solid discs; how hard surfaces
  /// grip is [Flut5PhysicsEngine.friction]. Costs a little extra per contact.
  physical,
}

/// The rotation side of [Flut5PhysicsEngine]: the rotation mode and, for
/// [PhysicsRotationMode.physical], the friction at contacts that turns
/// particles (applied by [_rubParticles] and [_rubAgainstEdge] below).
///
/// Every contact works the same way. Friction acts on the *slip*: how fast
/// the two surfaces slide past each other where they touch, from both the
/// particles' speed and their spin. It pushes against the slip, at most
/// [friction] times as hard as the hit pushed the particles apart, and the
/// push both slows the particle and turns it. A solid disc rubbing on a wall
/// gives up a third of the slip from its speed and two thirds from its spin
/// — once the slip is gone it rolls.
mixin _PhysicsRotation {
  /// How particles turn: not at all ([PhysicsRotationMode.none], default),
  /// a rolling look ([PhysicsRotationMode.cosmetic]), or real rotation from
  /// friction ([PhysicsRotationMode.physical]).
  PhysicsRotationMode rotationMode = .none;

  double _cosmeticSpinScale = 0.5;

  /// How fast particles spin in [PhysicsRotationMode.cosmetic], as a share of
  /// the rolling spin for their speed (`velocity.x / radius`). `0.5`
  /// (default) spins at half the rolling rate — the calmer look of the
  /// classic sketch trick at typical ball sizes; `1` rolls exactly, with no
  /// visible slip. For the classic trick's exact look at one size, use
  /// `0.04 * radius`. Must be >= 0.
  double get cosmeticSpinScale => _cosmeticSpinScale;
  set cosmeticSpinScale(double scale) {
    if (scale < 0) {
      throw ArgumentError.value(scale, 'scale', 'Must be >= 0');
    }
    _cosmeticSpinScale = scale;
  }

  double _cosmeticSpinDecay = 0.95;

  /// How much of its spin a particle keeps each frame in
  /// [PhysicsRotationMode.cosmetic]; the rest comes from its speed (see
  /// [cosmeticSpinScale]). `0.95` (default) lags speed a little and coasts to
  /// a stop over about a second; `0` snaps straight to the rolling spin;
  /// closer to `1` lags and coasts longer, and `1` never changes the spin.
  /// Must be between 0 and 1.
  double get cosmeticSpinDecay => _cosmeticSpinDecay;
  set cosmeticSpinDecay(double decay) {
    if (decay < 0 || decay > 1) {
      throw ArgumentError.value(decay, 'decay', 'Must be between 0 and 1');
    }
    _cosmeticSpinDecay = decay;
  }

  double _friction = 0.5;

  /// How hard surfaces grip each other in [PhysicsRotationMode.physical]:
  /// the friction at a contact is at most this many times as strong as the
  /// hit. `0` is ice — nothing turns — and higher values grip harder.
  /// Defaults to `0.5`; must be >= 0. Unused in the other modes, so
  /// collisions there stay frictionless.
  double get friction => _friction;
  set friction(double friction) {
    if (friction < 0) {
      throw ArgumentError.value(friction, 'friction', 'Must be >= 0');
    }
    _friction = friction;
  }
}

/// Friction between particles [a] and [b], which just bounced apart along
/// [normal] (from a to b) with an impulse of [normalImpulse]; [friction] is
/// [Flut5PhysicsEngine.friction].
void _rubParticles(
  Flut5PhysicsParticle a,
  Flut5PhysicsParticle b,
  Flut5Vector normal,
  double normalImpulse,
  double friction,
) {
  // Rotation is in the screen plane, so friction acts along the tangent:
  // the normal turned a quarter clockwise.
  var tangentX = -normal.y, tangentY = normal.x;
  final tangentLength = math.sqrt(tangentX * tangentX + tangentY * tangentY);
  if (tangentLength == 0) return; // touching straight along z
  tangentX /= tangentLength;
  tangentY /= tangentLength;

  final radiusA = a.radius;
  final radiusB = b.radius;
  final velocityA = a.velocity;
  final velocityB = b.velocity;
  // How fast b's surface slides past a's where they touch: their speed
  // along the tangent, minus what their spins carry the surfaces along.
  final slip =
      (velocityB.x - velocityA.x) * tangentX +
      (velocityB.y - velocityA.y) * tangentY -
      (a.angularVelocity * radiusA + b.angularVelocity * radiusB);

  // How much the slip changes per unit of friction impulse: through each
  // particle's speed (1 / mass) and, for a solid disc, twice that through
  // its spin. A particle without a radius has nothing to turn.
  final inverseMassA = 1 / a.mass;
  final inverseMassB = 1 / b.mass;
  final slipPerImpulse =
      inverseMassA +
      inverseMassB +
      (radiusA > 0 ? 2 * inverseMassA : 0) +
      (radiusB > 0 ? 2 * inverseMassB : 0);
  final maxImpulse = friction * normalImpulse;
  final impulse = (-slip / slipPerImpulse).clamp(-maxImpulse, maxImpulse);

  velocityA
    ..x -= tangentX * impulse * inverseMassA
    ..y -= tangentY * impulse * inverseMassA;
  velocityB
    ..x += tangentX * impulse * inverseMassB
    ..y += tangentY * impulse * inverseMassB;
  // Both turn the same way: friction pushes their touching surfaces in
  // opposite directions, but those surfaces are on opposite sides of each.
  if (radiusA > 0) a.angularVelocity -= 2 * impulse * inverseMassA / radiusA;
  if (radiusB > 0) b.angularVelocity -= 2 * impulse * inverseMassB / radiusB;
}

/// Friction between [particle] and [edge], after a hit that changed its
/// speed into the edge by [normalSpeedChange]; [friction] is
/// [Flut5PhysicsEngine.friction].
void _rubAgainstEdge(
  Flut5PhysicsParticle particle,
  _WindowEdge edge,
  double normalSpeedChange,
  double friction,
) {
  final radius = particle.radius;
  if (radius <= 0) return; // a point has no surface to turn
  final velocity = particle.velocity;
  final along = edge.alongAxis;
  final spinDirection = edge.spinDirection;

  // How fast the particle's surface slides along the edge where it
  // touches: its speed along the edge plus what its spin carries the
  // surface along.
  final slip =
      velocity[along] + particle.angularVelocity * radius * spinDirection;
  // A solid disc against an immovable wall: a third of the slip comes off
  // its speed, two thirds off its spin.
  final maxChange = friction * normalSpeedChange;
  final speedChange = (-slip / 3).clamp(-maxChange, maxChange);
  velocity[along] += speedChange;
  particle.angularVelocity += 2 * spinDirection * speedChange / radius;
}
