part of 'flut5_physics_engine.dart';

/// Where two bodies touch, and how to push them apart.
///
/// Detection (in the polygons part) fills it with a [normal] pointing from
/// the first body to the second and one or two contact points, each with
/// how deep the bodies overlap there. [resolve] then does what
/// `_correctOverlap` and `_bounceApart` do for two particles, generalised:
/// the contact points sit off the bodies' centers, so a push there also
/// turns them.
///
/// One instance is reused for every contact, so finding one allocates
/// nothing.
final class _ContactManifold {
  /// Unit vector from the first body toward the second.
  double normalX = 0, normalY = 0;

  /// How many of the contact slots below are filled: 1 or 2 (0 = none).
  int pointCount = 0;
  final Float64List pointX = Float64List(2);
  final Float64List pointY = Float64List(2);
  final Float64List depth = Float64List(2);

  // Working values for [resolve]. The arms from each body's center have a
  // third slot, [_frictionSlot], for the point friction acts at.
  final Float64List _armAX = Float64List(3);
  final Float64List _armAY = Float64List(3);
  final Float64List _armBX = Float64List(3);
  final Float64List _armBY = Float64List(3);
  final Float64List _normalMass = Float64List(2);
  final Float64List _bounceSpeed = Float64List(2);
  final Float64List _normalImpulse = Float64List(2);
  double _frictionMass = 0;
  double _frictionImpulse = 0;

  /// Friction acts once, at the middle of the contact points. Two points on
  /// one flat face would each grip in exactly the same direction with the
  /// same arm, and solving the same grip twice makes the sweeps settle so
  /// slowly that a resting box creeps.
  static const int _frictionSlot = 2;

  // The contact's impulses as one small system of equations: a row per
  // contact point (the push along the normal) plus one for friction.
  final Float64List _matrix = Float64List(9);
  final Float64List _rightSide = Float64List(3);
  final Float64List _solution = Float64List(3);

  /// How many times [resolve] sweeps over the impulses when they can't be
  /// solved exactly (see [_solveExactly]), and over two points when
  /// separating them. Each impulse changes what the others need, so they
  /// are solved in turns until they agree.
  static const int _sweeps = 8;

  /// Empties the manifold and sets its normal.
  void start(double normalX, double normalY) {
    this.normalX = normalX;
    this.normalY = normalY;
    pointCount = 0;
  }

  /// Adds a contact point [overlap] deep. With both slots taken, it replaces
  /// the shallower point if it is deeper, so the two deepest are kept.
  void addPoint(double x, double y, double overlap) {
    var slot = pointCount;
    if (pointCount == 2) {
      slot = depth[0] < depth[1] ? 0 : 1;
      if (overlap <= depth[slot]) return;
    } else {
      pointCount++;
    }
    pointX[slot] = x;
    pointY[slot] = y;
    depth[slot] = overlap;
  }

  /// Turns the normal around, for when detection found it from the second
  /// body's side.
  void flipNormal() {
    normalX = -normalX;
    normalY = -normalY;
  }

  /// Pushes [a] and [b] apart and bounces them, in two steps:
  ///
  /// 1. **Separate:** move them apart until they just touch, the lighter
  ///    body moving more. Against a static body this also levels a body
  ///    sunk deeper at one end; see [_separateAndLevel].
  /// 2. **Impulses:** at each contact point that is closing in, an equal and
  ///    opposite impulse along the normal, sized so they leave at
  ///    [restitution] times the speed they hit with. In
  ///    [PhysicsRotationMode.physical] each point also turns the bodies, and
  ///    friction (up to [friction] times the push) grips them.
  ///
  /// A contact closing in no faster than one frame of [gravity] along the
  /// normal is resting, so it doesn't bounce — boxes stay still on the
  /// ground instead of hopping in place.
  void resolve(
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b, {
    required double restitution,
    required double friction,
    required PhysicsRotationMode rotationMode,
    required Flut5Vector gravity,
  }) {
    final inverseMassA = a.inverseMass;
    final inverseMassB = b.inverseMass;
    if (inverseMassA + inverseMassB == 0) return; // nothing can move
    final inverseInertiaA = _inverseInertia(a, rotationMode);
    final inverseInertiaB = _inverseInertia(b, rotationMode);

    final restingSpeed = (gravity.x * normalX + gravity.y * normalY).abs();
    for (var k = 0; k < pointCount; k++) {
      _preparePoint(
        k,
        a,
        b,
        inverseMassA,
        inverseMassB,
        inverseInertiaA,
        inverseInertiaB,
        restitution,
        restingSpeed,
      );
    }

    _prepareFriction(
      a,
      b,
      inverseMassA,
      inverseMassB,
      inverseInertiaA,
      inverseInertiaB,
    );

    if (inverseMassA == 0 || inverseMassB == 0) {
      _separateAndLevel(
        a,
        b,
        inverseMassA,
        inverseMassB,
        inverseInertiaA,
        inverseInertiaB,
        pointCount == 1 ? 1 : _sweeps,
      );
    } else {
      _liftApart(a, b, inverseMassA, inverseMassB);
    }

    final withFriction = rotationMode == .physical && friction > 0;
    final solved = _solveExactly(
      a,
      b,
      inverseMassA,
      inverseMassB,
      inverseInertiaA,
      inverseInertiaB,
      withFriction ? friction : null,
    );
    if (solved) return;

    for (var sweep = 0; sweep < _sweeps; sweep++) {
      for (var k = 0; k < pointCount; k++) {
        _pushAlongNormal(
          k,
          a,
          b,
          inverseMassA,
          inverseMassB,
          inverseInertiaA,
          inverseInertiaB,
        );
      }
      if (withFriction) {
        _gripAlongTangent(
          a,
          b,
          inverseMassA,
          inverseMassB,
          inverseInertiaA,
          inverseInertiaB,
          friction,
        );
      }
    }
  }

  /// Solves every impulse of the contact at once — the push at each point
  /// and, with [friction], the grip — so that each point leaves at its
  /// bounce speed and the surfaces stop sliding. Applies them and returns
  /// `true` if that answer is physical: no point pulls, and the grip is
  /// within [friction] times the total push.
  ///
  /// Solving them in turns instead leaves a tiny error each frame; for a
  /// resting box, gravity brings that error back every frame and the box
  /// creeps sideways. When the exact answer isn't physical — a corner
  /// lifting off, or a box sliding — [resolve] falls back to sweeps, which
  /// handle those limits.
  bool _solveExactly(
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double inverseMassA,
    double inverseMassB,
    double inverseInertiaA,
    double inverseInertiaB,
    double? friction,
  ) {
    final rows = pointCount + (friction != null ? 1 : 0);
    for (var i = 0; i < rows; i++) {
      final slotI = _slotOf(i);
      final dirIX = _directionX(i), dirIY = _directionY(i);
      final turnAI = _armAX[slotI] * dirIY - _armAY[slotI] * dirIX;
      final turnBI = _armBX[slotI] * dirIY - _armBY[slotI] * dirIX;
      for (var j = 0; j < rows; j++) {
        final slotJ = _slotOf(j);
        final dirJX = _directionX(j), dirJY = _directionY(j);
        final turnAJ = _armAX[slotJ] * dirJY - _armAY[slotJ] * dirJX;
        final turnBJ = _armBX[slotJ] * dirJY - _armBY[slotJ] * dirJX;
        // How much an impulse in row j changes the speed row i measures.
        _matrix[i * 3 + j] =
            (inverseMassA + inverseMassB) * (dirIX * dirJX + dirIY * dirJY) +
            inverseInertiaA * turnAI * turnAJ +
            inverseInertiaB * turnBI * turnBJ;
      }
      final speed = _relativeSpeed(slotI, a, b, dirIX, dirIY);
      _rightSide[i] = i < pointCount ? _bounceSpeed[i] - speed : -speed;
    }
    if (!_solveSystem(rows)) return false;

    var totalPush = 0.0;
    for (var k = 0; k < pointCount; k++) {
      if (_solution[k] < 0) return false; // that point would have to pull
      totalPush += _solution[k];
    }
    if (friction != null &&
        _solution[pointCount].abs() > friction * totalPush) {
      return false; // sliding: more grip than friction allows
    }

    for (var i = 0; i < rows; i++) {
      _applyImpulse(
        _slotOf(i),
        a,
        b,
        _directionX(i) * _solution[i],
        _directionY(i) * _solution[i],
        inverseMassA,
        inverseMassB,
        inverseInertiaA,
        inverseInertiaB,
      );
    }
    return true;
  }

  // Row r of the system is either contact point r along the normal, or —
  // after the points — friction along the tangent at the middle of the
  // contact.
  int _slotOf(int row) => row < pointCount ? row : _frictionSlot;
  double _directionX(int row) => row < pointCount ? normalX : -normalY;
  double _directionY(int row) => row < pointCount ? normalY : normalX;

  /// Solves `_matrix · _solution = _rightSide` for the first [size] rows by
  /// Gaussian elimination. Returns `false` if the rows don't pin down one
  /// answer — two points that push exactly alike, as when nothing turns.
  bool _solveSystem(int size) {
    final matrix = _matrix, right = _rightSide;
    for (var column = 0; column < size; column++) {
      // Swap up the row with the largest entry in this column, for accuracy.
      var pivot = column;
      for (var row = column + 1; row < size; row++) {
        if (matrix[row * 3 + column].abs() > matrix[pivot * 3 + column].abs()) {
          pivot = row;
        }
      }
      if (matrix[pivot * 3 + column].abs() < 1e-9) return false;
      if (pivot != column) {
        for (var j = 0; j < size; j++) {
          final swap = matrix[column * 3 + j];
          matrix[column * 3 + j] = matrix[pivot * 3 + j];
          matrix[pivot * 3 + j] = swap;
        }
        final swap = right[column];
        right[column] = right[pivot];
        right[pivot] = swap;
      }
      for (var row = column + 1; row < size; row++) {
        final factor = matrix[row * 3 + column] / matrix[column * 3 + column];
        for (var j = column; j < size; j++) {
          matrix[row * 3 + j] -= factor * matrix[column * 3 + j];
        }
        right[row] -= factor * right[column];
      }
    }
    for (var row = size - 1; row >= 0; row--) {
      var sum = right[row];
      for (var j = row + 1; j < size; j++) {
        sum -= matrix[row * 3 + j] * _solution[j];
      }
      _solution[row] = sum / matrix[row * 3 + row];
    }
    return true;
  }

  /// Works out, once per contact, what the impulses at point [k] need: the
  /// arms from each center to the point, how much the point's speed along
  /// the normal changes per unit of impulse, and the speed they should
  /// leave with.
  void _preparePoint(
    int k,
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double inverseMassA,
    double inverseMassB,
    double inverseInertiaA,
    double inverseInertiaB,
    double restitution,
    double restingSpeed,
  ) {
    _armAX[k] = pointX[k] - a.position.x;
    _armAY[k] = pointY[k] - a.position.y;
    _armBX[k] = pointX[k] - b.position.x;
    _armBY[k] = pointY[k] - b.position.y;
    _normalMass[k] = _massAlong(
      k,
      normalX,
      normalY,
      inverseMassA,
      inverseMassB,
      inverseInertiaA,
      inverseInertiaB,
    );

    final approachSpeed = -_relativeSpeed(k, a, b, normalX, normalY);
    _bounceSpeed[k] = approachSpeed > restingSpeed
        ? restitution * approachSpeed
        : 0;
    _normalImpulse[k] = 0;
  }

  /// Sets up friction at the middle of the contact points (the point itself
  /// when there is one).
  void _prepareFriction(
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double inverseMassA,
    double inverseMassB,
    double inverseInertiaA,
    double inverseInertiaB,
  ) {
    var middleX = pointX[0], middleY = pointY[0];
    if (pointCount == 2) {
      middleX = (middleX + pointX[1]) / 2;
      middleY = (middleY + pointY[1]) / 2;
    }
    _armAX[_frictionSlot] = middleX - a.position.x;
    _armAY[_frictionSlot] = middleY - a.position.y;
    _armBX[_frictionSlot] = middleX - b.position.x;
    _armBY[_frictionSlot] = middleY - b.position.y;
    _frictionMass = _massAlong(
      _frictionSlot,
      -normalY,
      normalX,
      inverseMassA,
      inverseMassB,
      inverseInertiaA,
      inverseInertiaB,
    );
    _frictionImpulse = 0;
  }

  /// How much impulse it takes to change the speed at slot [k] along
  /// ([directionX], [directionY]) by 1: through both bodies' mass and, as
  /// the arm turns a push by `arm × direction`, through their spin.
  double _massAlong(
    int k,
    double directionX,
    double directionY,
    double inverseMassA,
    double inverseMassB,
    double inverseInertiaA,
    double inverseInertiaB,
  ) {
    final turnA = _armAX[k] * directionY - _armAY[k] * directionX;
    final turnB = _armBX[k] * directionY - _armBY[k] * directionX;
    return 1 /
        (inverseMassA +
            inverseMassB +
            inverseInertiaA * turnA * turnA +
            inverseInertiaB * turnB * turnB);
  }

  /// Moves a body off a static one (the ground, a wall, a platform) until
  /// every contact point just touches.
  ///
  /// Each point pushes like an impulse does, but on position, and in
  /// [PhysicsRotationMode.physical] a push off center also turns the body.
  /// A box that lands tilted is levelled out flat on the ground instead of
  /// being lifted by its deepest corner and left resting tilted on it.
  void _separateAndLevel(
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double inverseMassA,
    double inverseMassB,
    double inverseInertiaA,
    double inverseInertiaB,
    int sweeps,
  ) {
    // How far each body has been moved and turned so far.
    var moveAX = 0.0, moveAY = 0.0, turnA = 0.0;
    var moveBX = 0.0, moveBY = 0.0, turnB = 0.0;
    for (var sweep = 0; sweep < sweeps; sweep++) {
      for (var k = 0; k < pointCount; k++) {
        // How much of point k's overlap those moves have already undone: how
        // far b's surface there has moved away from a's along the normal.
        final undone =
            (moveBX - turnB * _armBY[k] - moveAX + turnA * _armAY[k]) *
                normalX +
            (moveBY + turnB * _armBX[k] - moveAY - turnA * _armAX[k]) * normalY;
        final remaining = depth[k] - undone;
        if (remaining <= 0) continue;
        final push = remaining * _normalMass[k];
        moveAX -= normalX * push * inverseMassA;
        moveAY -= normalY * push * inverseMassA;
        turnA -=
            inverseInertiaA *
            (_armAX[k] * normalY - _armAY[k] * normalX) *
            push;
        moveBX += normalX * push * inverseMassB;
        moveBY += normalY * push * inverseMassB;
        turnB +=
            inverseInertiaB *
            (_armBX[k] * normalY - _armBY[k] * normalX) *
            push;
      }
    }
    a.position
      ..x += moveAX
      ..y += moveAY;
    a.angle += turnA;
    b.position
      ..x += moveBX
      ..y += moveBY;
    b.angle += turnB;
  }

  /// Moves two moving bodies apart along the normal by the deepest overlap,
  /// split by mass, without turning them. Levelling between two moving
  /// bodies feeds back through a stack and makes it rock harder.
  void _liftApart(
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double inverseMassA,
    double inverseMassB,
  ) {
    var deepest = depth[0];
    if (pointCount == 2 && depth[1] > deepest) deepest = depth[1];
    final move = deepest / (inverseMassA + inverseMassB);
    a.position
      ..x -= normalX * move * inverseMassA
      ..y -= normalY * move * inverseMassA;
    b.position
      ..x += normalX * move * inverseMassB
      ..y += normalY * move * inverseMassB;
  }

  /// One sweep's impulse along the normal at point [k], so they leave at
  /// their bounce speed. The total over the sweeps never pulls them
  /// together: contacts only push.
  void _pushAlongNormal(
    int k,
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double inverseMassA,
    double inverseMassB,
    double inverseInertiaA,
    double inverseInertiaB,
  ) {
    final separatingSpeed = _relativeSpeed(k, a, b, normalX, normalY);
    final wanted = (_bounceSpeed[k] - separatingSpeed) * _normalMass[k];
    final total = math.max(_normalImpulse[k] + wanted, 0.0);
    final impulse = total - _normalImpulse[k];
    _normalImpulse[k] = total;
    _applyImpulse(
      k,
      a,
      b,
      normalX * impulse,
      normalY * impulse,
      inverseMassA,
      inverseMassB,
      inverseInertiaA,
      inverseInertiaB,
    );
  }

  /// One sweep's friction: an impulse across the normal, at the middle of
  /// the contact, that stops the surfaces sliding past each other — no
  /// stronger in total than [friction] times the push along the normal.
  void _gripAlongTangent(
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double inverseMassA,
    double inverseMassB,
    double inverseInertiaA,
    double inverseInertiaB,
    double friction,
  ) {
    final tangentX = -normalY, tangentY = normalX;
    final slip = _relativeSpeed(_frictionSlot, a, b, tangentX, tangentY);
    final wanted = -slip * _frictionMass;
    var totalPush = _normalImpulse[0];
    if (pointCount == 2) totalPush += _normalImpulse[1];
    final limit = friction * totalPush;
    final total = (_frictionImpulse + wanted).clamp(-limit, limit);
    final impulse = total - _frictionImpulse;
    _frictionImpulse = total;
    _applyImpulse(
      _frictionSlot,
      a,
      b,
      tangentX * impulse,
      tangentY * impulse,
      inverseMassA,
      inverseMassB,
      inverseInertiaA,
      inverseInertiaB,
    );
  }

  /// How fast [b]'s surface moves away from [a]'s at slot [k], along
  /// ([directionX], [directionY]). A surface point moves with its body and
  /// with its spin: `velocity + angularVelocity × arm`.
  double _relativeSpeed(
    int k,
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double directionX,
    double directionY,
  ) {
    final spinA = a.angularVelocity, spinB = b.angularVelocity;
    final relativeX =
        (b.velocity.x - spinB * _armBY[k]) - (a.velocity.x - spinA * _armAY[k]);
    final relativeY =
        (b.velocity.y + spinB * _armBX[k]) - (a.velocity.y + spinA * _armAX[k]);
    return relativeX * directionX + relativeY * directionY;
  }

  /// Applies the impulse ([impulseX], [impulseY]) at slot [k]: to [b] as
  /// given, to [a] reversed. Each body's velocity changes by impulse / mass
  /// and its spin by `arm × impulse` / moment of inertia.
  void _applyImpulse(
    int k,
    Flut5PhysicsRigidBody a,
    Flut5PhysicsRigidBody b,
    double impulseX,
    double impulseY,
    double inverseMassA,
    double inverseMassB,
    double inverseInertiaA,
    double inverseInertiaB,
  ) {
    a.velocity
      ..x -= impulseX * inverseMassA
      ..y -= impulseY * inverseMassA;
    a.angularVelocity -=
        inverseInertiaA * (_armAX[k] * impulseY - _armAY[k] * impulseX);
    b.velocity
      ..x += impulseX * inverseMassB
      ..y += impulseY * inverseMassB;
    b.angularVelocity +=
        inverseInertiaB * (_armBX[k] * impulseY - _armBY[k] * impulseX);
  }
}

/// How much a push off-center changes [body]'s spin: `1 / moment of
/// inertia`, or `0` when it must not turn — outside
/// [PhysicsRotationMode.physical], for static bodies, and for particles
/// without a radius. Particles count as solid discs (`½·m·r²`).
double _inverseInertia(Flut5PhysicsRigidBody body, PhysicsRotationMode mode) {
  if (mode != .physical) return 0;
  if (body is Flut5PhysicsParticle) {
    final radius = body.radius;
    return radius > 0 ? 2 / (body.mass * radius * radius) : 0;
  }
  if (body is Flut5PhysicsPolygon) {
    return body.isStatic ? 0 : 1 / body.momentOfInertia;
  }
  return 0;
}
