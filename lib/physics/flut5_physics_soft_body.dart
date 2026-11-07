part of 'flut5_physics_particle.dart';

/// A body that bends and squashes: particles held in shape by springs, by
/// areas that keep their size, and by the memory of the shape it was made
/// in.
///
/// Every soft body, whatever its shape, is built from:
///
/// - [particles] — ordinary engine particles, placed anywhere.
/// - [springs] — pairs of particles kept at the distance they started at.
///   They give it its local give: how it bends and squashes.
/// - [areas] — closed loops of particles that keep the area they started
///   with. A loop around the whole outline works like the air in a
///   balloon; small loops (grid cells, triangles) can't fold over.
/// - [keepShape] — every particle is also pulled toward its place in the
///   shape the body was made in, laid over wherever the body is now and
///   turned to fit. Springs only reach a step or two through the body; this
///   holds the whole shape at once, so any outline — dents and all — comes
///   back after a squash instead of sagging into a puddle.
///
/// The presets build those for you: [Flut5PhysicsSoftBody.polygon] for any
/// outline — blobs, stars, letters — [Flut5PhysicsSoftBody.circle] for a
/// round blob, and [Flut5PhysicsSoftRect] for a filled grid. Or give your
/// own structure to [Flut5PhysicsSoftBody.new].
///
/// The particles are registered, listed in `physicsEngine.particles` and
/// stepped like any other, so gravity, the window edges, polygons and
/// `particleCollision()` all act on the body through them, and you can push
/// it with `applyForce` on any of them. Its own particles never collide with
/// each other; the springs keep them apart.
///
/// Remove the whole body with `physicsEngine.remove(softBody)`. Removing
/// just one of its particles tears it there: that particle stops and the
/// springs and areas it belongs to stop pulling, though the lists still
/// hold them.
final class Flut5PhysicsSoftBody extends Flut5PhysicsBody {
  /// A soft body with a particle at each of [points], relative to ([x],
  /// [y]), held together by the structure you give, as indices into
  /// [points]:
  ///
  /// - [springs]: pairs of particles to keep the distance between.
  /// - [areas]: loops of particles (3 or more, in order around the loop) to
  ///   keep the area inside.
  /// - [outline]: the particles around the edge, in order — what you draw.
  ///   Optional; [outline] stays empty without it.
  /// - [keepShape]: pull it back toward the shape [points] make (default
  ///   `true`) — see [keepShape]. Turn it off for a body that shouldn't
  ///   spring back to one shape, like a rope or a cloth.
  /// - [particleRadius]: every particle's `radius`. Defaults to half the
  ///   shortest spring, so neighbors just touch.
  /// - [stiffness]: how firmly the body holds its shape, from `0` to `1`
  ///   (default `0.3`) — see [stiffness].
  ///
  /// A triangle with a particle in the middle, braced from every corner:
  ///
  /// ```dart
  /// final body = physicsEngine.createSoftBody(
  ///   200, 100,
  ///   [createVector(0, -40), createVector(40, 30), createVector(-40, 30),
  ///    createVector(0, 7)],
  ///   springs: [(0, 1), (1, 2), (2, 0), (0, 3), (1, 3), (2, 3)],
  ///   areas: [[0, 1, 3], [1, 2, 3], [2, 0, 3]],
  ///   outline: [0, 1, 2],
  /// );
  /// ```
  ///
  /// Without [keepShape], springs alone let a body fold over itself or
  /// collapse; give it areas too. Throws an [ArgumentError] for an index outside [points], a spring
  /// from a particle to itself, an area with fewer than 3 particles, a
  /// negative [particleRadius] or a [stiffness] outside `0`–`1`.
  factory Flut5PhysicsSoftBody(
    double x,
    double y,
    List<Flut5Vector> points, {
    List<(int, int)> springs = const [],
    List<List<int>> areas = const [],
    List<int> outline = const [],
    bool keepShape = true,
    double? particleRadius,
    double stiffness = 0.3,
  }) => Flut5PhysicsSoftBody._(
    _assemble(
      x,
      y,
      points,
      springs: springs,
      areas: areas,
      outline: outline,
      particleRadius: particleRadius,
    ),
    stiffness: stiffness,
  )..keepShape = keepShape;

  /// A hollow soft body shaped like the closed outline through [corners],
  /// relative to ([x], [y]) — any shape that doesn't cross itself, dents
  /// and all. Corners can go either way around.
  ///
  /// It is a ring of particles, like a balloon: springs to the next
  /// particle and the one after along the ring, the area inside kept, and
  /// the outline's shape kept ([keepShape]), so it squashes and bulges and
  /// then springs back.
  ///
  /// - [resolution]: how many particles go around the outline. Every corner
  ///   gets one; the rest are spread along the edges by length. Defaults to
  ///   one per corner.
  /// - [particleRadius]: every particle's `radius`. Defaults to half the
  ///   shortest gap between neighbors around the ring, so they just touch.
  /// - [stiffness]: how firmly it holds its shape, from `0` to `1` (default
  ///   `0.3`) — see [stiffness].
  ///
  /// Throws an [ArgumentError] for fewer than 3 corners, two neighbors in
  /// the same place, an outline with no area or that crosses itself, a
  /// [resolution] below the corner count, a negative [particleRadius] or a
  /// [stiffness] outside `0`–`1`.
  factory Flut5PhysicsSoftBody.polygon(
    double x,
    double y,
    List<Flut5Vector> corners, {
    int? resolution,
    double? particleRadius,
    double stiffness = 0.3,
  }) {
    final points = _ringPoints(corners, resolution);
    final count = points.length;
    int around(int i) => i % count;
    var shortestGap = double.infinity;
    for (var i = 0; i < count; i++) {
      shortestGap = math.min(
        shortestGap,
        points[i].distanceTo(points[around(i + 1)]),
      );
    }
    return Flut5PhysicsSoftBody._(
      _assemble(
        x,
        y,
        points,
        springs: [
          for (var i = 0; i < count; i++) (i, around(i + 1)),
          // Two along, so the ring resists bending even with keepShape off.
          if (count > 3)
            for (var i = 0; i < count; i++) (i, around(i + 2)),
        ],
        areas: [
          [for (var i = 0; i < count; i++) i],
        ],
        outline: [for (var i = 0; i < count; i++) i],
        particleRadius: particleRadius ?? shortestGap / 2,
      ),
      stiffness: stiffness,
    );
  }

  /// A round hollow soft body — a blob — of [radius] centered on ([x],
  /// [y]): a [Flut5PhysicsSoftBody.polygon] with [resolution] particles
  /// evenly around the circle (default `24`, at least `3`).
  factory Flut5PhysicsSoftBody.circle(
    double x,
    double y,
    double radius, {
    int resolution = 24,
    double? particleRadius,
    double stiffness = 0.3,
  }) {
    if (radius <= 0) {
      throw ArgumentError.value(radius, 'radius', 'Must be > 0');
    }
    if (resolution < 3) {
      throw ArgumentError.value(resolution, 'resolution', 'Must be >= 3');
    }
    return Flut5PhysicsSoftBody.polygon(
      x,
      y,
      [
        for (var i = 0; i < resolution; i++)
          Flut5Vector(
            radius * math.cos(2 * math.pi * i / resolution),
            radius * math.sin(2 * math.pi * i / resolution),
          ),
      ],
      particleRadius: particleRadius,
      stiffness: stiffness,
    );
  }

  Flut5PhysicsSoftBody._(_Structure structure, {required double stiffness})
    : particles = List.unmodifiable(structure.particles),
      springs = List.unmodifiable(structure.springs),
      areas = List.unmodifiable(structure.areas),
      outline = List.unmodifiable(structure.outline) {
    for (final particle in particles) {
      particle._softBody = this;
    }
    this.stiffness = stiffness;
  }

  /// Every particle of the body.
  final List<Flut5PhysicsParticle> particles;

  /// Every spring holding the body in shape. Draw one with
  /// `line(s.a.x, s.a.y, s.b.x, s.b.y)`.
  final List<Flut5PhysicsSoftSpring> springs;

  /// Every loop of particles keeping the area inside it.
  final List<Flut5PhysicsSoftArea> areas;

  /// Whether every particle is also pulled toward its place in the shape
  /// the body was made in — laid over the body wherever it is now and
  /// turned to fit, so only bending and squashing are undone. `true` by
  /// default; the pull is as strong as [stiffness].
  ///
  /// Without it only the springs and areas hold the body, and they reach
  /// just a step or two through it: a big or loose body sags and can fold,
  /// and an outline-only body (`polygon`, `circle`) slowly loses its shape
  /// like a balloon. Turn it off for things with no one shape to return
  /// to — a rope, a cloth — or switch it off mid-sketch to let a body melt.
  bool keepShape = true;

  /// The particles around the body's edge, in order — ready to draw its
  /// outline:
  ///
  /// ```dart
  /// beginShape();
  /// for (final p in softBody.outline) vertex(p.x, p.y);
  /// endShape(close: true);
  /// ```
  ///
  /// The outline runs through the particles' centers, so against a wall it
  /// stays one particle radius away.
  final List<Flut5PhysicsParticle> outline;

  double _stiffness = 0;

  /// How strongly the body springs back into shape, from `0` to `1`.
  ///
  /// Each pull closes this share of the gap between a spring's length and
  /// its rest length, between an area and its starting area, and — with
  /// [keepShape] — between each particle and its place in the rest shape.
  /// Around
  /// `0.1` the body is loose jelly that squashes deep and wobbles; `0.3`
  /// bounces back quickly; `1` is as firm as it gets and barely gives. `0`
  /// turns the springs and areas off, leaving loose particles. No setting
  /// can make the body blow up.
  ///
  /// The body is pulled back into shape in every collision pass, so raising
  /// `physicsEngine.collisionIterations` firms every soft body up.
  double get stiffness => _stiffness;
  set stiffness(double value) {
    if (value < 0 || value > 1) {
      throw ArgumentError.value(value, 'stiffness', 'Must be from 0 to 1');
    }
    _stiffness = value;
  }

  /// Builds the particles, springs and areas for [points] (relative to
  /// ([x], [y])) and the index lists, checking every index.
  static _Structure _assemble(
    double x,
    double y,
    List<Flut5Vector> points, {
    required List<(int, int)> springs,
    required List<List<int>> areas,
    required List<int> outline,
    required double? particleRadius,
  }) {
    if (particleRadius != null && particleRadius < 0) {
      throw ArgumentError.value(
        particleRadius,
        'particleRadius',
        'Must be >= 0',
      );
    }
    void checkIndex(int index, String name) =>
        RangeError.checkValueInInterval(index, 0, points.length - 1, name);

    final particles = [
      for (final point in points)
        Flut5PhysicsParticle(x + point.x, y + point.y),
    ];
    final softSprings = <Flut5PhysicsSoftSpring>[];
    for (final (a, b) in springs) {
      checkIndex(a, 'spring end');
      checkIndex(b, 'spring end');
      if (a == b) {
        throw ArgumentError('A spring needs two particles, got ($a, $b)');
      }
      softSprings.add(Flut5PhysicsSoftSpring._(particles[a], particles[b]));
    }
    final softAreas = <Flut5PhysicsSoftArea>[];
    for (final loop in areas) {
      if (loop.length < 3) {
        throw ArgumentError(
          'An area needs a loop of at least 3 particles, got $loop',
        );
      }
      for (final index in loop) {
        checkIndex(index, 'area particle');
      }
      softAreas.add(
        Flut5PhysicsSoftArea._([for (final index in loop) particles[index]]),
      );
    }
    for (final index in outline) {
      checkIndex(index, 'outline particle');
    }

    var radius = particleRadius;
    if (radius == null) {
      var shortest = double.infinity;
      for (final spring in softSprings) {
        if (spring.restLength > 0) {
          shortest = math.min(shortest, spring.restLength);
        }
      }
      radius = shortest.isFinite ? shortest / 2 : 0.0;
    }
    for (final particle in particles) {
      particle.radius = radius;
    }

    return (
      particles: particles,
      springs: softSprings,
      areas: softAreas,
      outline: [for (final index in outline) particles[index]],
    );
  }

  /// The ring of points for [Flut5PhysicsSoftBody.polygon]: [corners],
  /// checked and turned clockwise on screen, with points added along the
  /// edges until there are [resolution].
  static List<Flut5Vector> _ringPoints(
    List<Flut5Vector> corners,
    int? resolution,
  ) {
    final count = corners.length;
    if (count < 3) {
      throw ArgumentError(
        'A soft polygon needs at least 3 corners, got $count',
      );
    }
    for (var i = 0; i < count; i++) {
      final next = corners[(i + 1) % count];
      if (corners[i].x == next.x && corners[i].y == next.y) {
        throw ArgumentError(
          'Soft polygon corners $i and ${(i + 1) % count} are the same point',
        );
      }
    }
    final area = _signedArea(corners);
    if (area.abs() < 1e-9) {
      throw ArgumentError('Soft polygon corners enclose no area');
    }
    _checkNoCrossing(corners);
    final total = resolution ?? count;
    if (total < count) {
      throw ArgumentError.value(
        resolution,
        'resolution',
        'Must be at least the $count corners',
      );
    }
    final ordered = area > 0 ? corners : corners.reversed.toList();

    // Share the extra points out by edge length: each edge gets its whole
    // share, then the edges that lost the most to rounding get one more.
    final lengths = [
      for (var i = 0; i < count; i++)
        ordered[i].distanceTo(ordered[(i + 1) % count]),
    ];
    final perimeter = lengths.reduce((a, b) => a + b);
    final extra = total - count;
    final shares = [for (final length in lengths) extra * length / perimeter];
    final added = [for (final share in shares) share.floor()];
    final byRemainder = List.generate(count, (i) => i)
      ..sort((a, b) => (shares[b] - added[b]).compareTo(shares[a] - added[a]));
    var left = extra - added.reduce((a, b) => a + b);
    for (final edge in byRemainder) {
      if (left == 0) break;
      added[edge]++;
      left--;
    }

    return [
      for (var i = 0; i < count; i++)
        for (var step = 0; step <= added[i]; step++)
          Flut5Vector(
            ordered[i].x,
            ordered[i].y,
          ).lerp(ordered[(i + 1) % count], step / (added[i] + 1)),
    ];
  }

  /// Throws if two edges of the closed outline through [corners] cross.
  static void _checkNoCrossing(List<Flut5Vector> corners) {
    final count = corners.length;
    double turn(Flut5Vector a, Flut5Vector b, Flut5Vector c) =>
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    for (var i = 0; i < count; i++) {
      final a = corners[i], b = corners[(i + 1) % count];
      // Neighboring edges share a corner; skip them.
      for (var j = i + 2; j < count; j++) {
        if (i == 0 && j == count - 1) continue;
        final c = corners[j], d = corners[(j + 1) % count];
        final crosses =
            turn(a, b, c) * turn(a, b, d) < 0 &&
            turn(c, d, a) * turn(c, d, b) < 0;
        if (crosses) {
          throw ArgumentError(
            'Soft polygon edges $i and $j cross; the outline must not '
            'cross itself',
          );
        }
      }
    }
  }
}

/// The particles, springs, areas and outline of a soft body being built.
typedef _Structure = ({
  List<Flut5PhysicsParticle> particles,
  List<Flut5PhysicsSoftSpring> springs,
  List<Flut5PhysicsSoftArea> areas,
  List<Flut5PhysicsParticle> outline,
});

/// The signed area of the closed outline through [points]: positive when
/// they run clockwise on screen (y down), negative when counterclockwise.
double _signedArea(List<Flut5Vector> points) {
  var doubleArea = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i], b = points[(i + 1) % points.length];
    doubleArea += a.x * b.y - b.x * a.y;
  }
  return doubleArea / 2;
}

/// A spring of a [Flut5PhysicsSoftBody], pulling particles [a] and [b] back
/// to [restLength] apart with the body's [Flut5PhysicsSoftBody.stiffness].
final class Flut5PhysicsSoftSpring {
  Flut5PhysicsSoftSpring._(this.a, this.b)
    : restLength = a.position.distanceTo(b.position);

  /// One end.
  final Flut5PhysicsParticle a;

  /// The other end.
  final Flut5PhysicsParticle b;

  /// The distance between [a] and [b] when the body was made, which the
  /// spring pulls back to.
  final double restLength;
}

/// A loop of a [Flut5PhysicsSoftBody]'s particles that keeps the area
/// inside it, with the body's [Flut5PhysicsSoftBody.stiffness].
///
/// The area is signed by which way the loop runs, so a loop turned inside
/// out is pulled back the right way round.
final class Flut5PhysicsSoftArea {
  Flut5PhysicsSoftArea._(List<Flut5PhysicsParticle> particles)
    : particles = List.unmodifiable(particles),
      restArea = _signedArea([for (final p in particles) p.position]);

  /// The particles around the loop, in order.
  final List<Flut5PhysicsParticle> particles;

  /// The area inside the loop when the body was made, which it pulls back
  /// to: positive if the loop runs clockwise on screen, negative if
  /// counterclockwise.
  final double restArea;
}

/// A soft rectangle: a filled grid of particles held together by springs.
///
/// Each particle is tied to its neighbors across, down and along both
/// diagonals, and to the particles two steps away across and down so the
/// body resists bending. Every cell of the grid also keeps its area, and
/// the whole grid keeps its shape ([keepShape]): squashed cells bulge,
/// and a hard landing can't fold the grid over itself.
///
/// Create one with `physicsEngine.createSoftRect` so its particles are
/// registered and stepped:
///
/// ```dart
/// final jelly = physicsEngine.createSoftRect(
///   200, 100, 160, 100,
///   resolution: 10, particleRadius: 6, stiffness: 0.2,
/// );
/// // in draw():
/// beginShape();
/// for (final p in jelly.outline) vertex(p.x, p.y);
/// endShape(close: true);
/// ```
final class Flut5PhysicsSoftRect extends Flut5PhysicsSoftBody {
  /// A [width] × [height] grid of particles centered on ([x], [y]), with
  /// its corner particles exactly on the rect's corners.
  ///
  /// - [resolution] is how many particles run along the longer side
  ///   (at least `2`). The shorter side gets as many as keep the gaps
  ///   between particles closest to square, at least `2`.
  /// - [particleRadius] is every particle's `radius`. Defaults to half the
  ///   gap between neighbors, so they just touch and nothing slips between
  ///   them. Must be >= 0.
  /// - [stiffness] is how firmly the body holds its shape, from `0` to `1`
  ///   (default `0.3`) — see [Flut5PhysicsSoftBody.stiffness].
  ///
  /// Throws an [ArgumentError] for a [width] or [height] <= 0, a
  /// [resolution] < 2, a negative [particleRadius], or a [stiffness]
  /// outside `0`–`1`.
  factory Flut5PhysicsSoftRect(
    double x,
    double y,
    double width,
    double height, {
    int resolution = 8,
    double? particleRadius,
    double stiffness = 0.3,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError(
        'A soft rect needs a width and height > 0, got $width × $height',
      );
    }
    if (resolution < 2) {
      throw ArgumentError.value(resolution, 'resolution', 'Must be >= 2');
    }

    final (columns, rows) = _gridSize(width, height, resolution);
    final gapX = width / (columns - 1);
    final gapY = height / (rows - 1);
    int at(int column, int row) => row * columns + column;

    final points = [
      for (var row = 0; row < rows; row++)
        for (var column = 0; column < columns; column++)
          Flut5Vector(column * gapX - width / 2, row * gapY - height / 2),
    ];
    final springs = <(int, int)>[];
    final cells = <List<int>>[];
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final hasRight = column + 1 < columns;
        final hasBelow = row + 1 < rows;
        if (hasRight) springs.add((at(column, row), at(column + 1, row)));
        if (hasBelow) springs.add((at(column, row), at(column, row + 1)));
        if (hasRight && hasBelow) {
          // Both diagonals of the cell, so it can't shear flat.
          springs.add((at(column, row), at(column + 1, row + 1)));
          springs.add((at(column + 1, row), at(column, row + 1)));
          // Clockwise on screen from its top-left corner.
          cells.add([
            at(column, row),
            at(column + 1, row),
            at(column + 1, row + 1),
            at(column, row + 1),
          ]);
        }
        // Two steps across and down: the grid resists bending, and a push
        // reaches deeper into the body with each pull.
        if (column + 2 < columns) {
          springs.add((at(column, row), at(column + 2, row)));
        }
        if (row + 2 < rows) springs.add((at(column, row), at(column, row + 2)));
      }
    }
    final outline = [
      for (var column = 0; column < columns; column++) at(column, 0),
      for (var row = 1; row < rows; row++) at(columns - 1, row),
      for (var column = columns - 2; column >= 0; column--)
        at(column, rows - 1),
      for (var row = rows - 2; row > 0; row--) at(0, row),
    ];

    return Flut5PhysicsSoftRect._(
      width,
      height,
      columns,
      rows,
      Flut5PhysicsSoftBody._assemble(
        x,
        y,
        points,
        springs: springs,
        areas: cells,
        outline: outline,
        particleRadius: particleRadius ?? math.min(gapX, gapY) / 2,
      ),
      stiffness: stiffness,
    );
  }

  Flut5PhysicsSoftRect._(
    this.width,
    this.height,
    this.columns,
    this.rows,
    super.structure, {
    required super.stiffness,
  }) : super._();

  /// Width at creation, before any squashing.
  final double width;

  /// Height at creation, before any squashing.
  final double height;

  /// How many particles run across each row.
  final int columns;

  /// How many particles run down each column.
  final int rows;

  /// The particle at [column] (from the left) and [row] (from the top) —
  /// `particleAt(0, 0)` is the top-left corner.
  Flut5PhysicsParticle particleAt(int column, int row) {
    RangeError.checkValueInInterval(column, 0, columns - 1, 'column');
    RangeError.checkValueInInterval(row, 0, rows - 1, 'row');
    return particles[row * columns + column];
  }

  /// Columns and rows for a [width] × [height] grid with [resolution]
  /// particles along its longer side.
  static (int, int) _gridSize(double width, double height, int resolution) {
    int shortSide(double short, double long) =>
        math.max(2, ((resolution - 1) * short / long).round() + 1);
    return width >= height
        ? (resolution, shortSide(height, width))
        : (shortSide(width, height), resolution);
  }
}
