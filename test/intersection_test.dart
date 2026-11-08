import 'package:flutter_test/flutter_test.dart';
import 'package:flut5/flut5.dart';

void main() {
  final engine = Flut5Engine();

  group('lineLineIntersection', () {
    test('returns the crossing point of two crossing segments', () {
      final hit = engine.lineLineIntersection(0, 0, 10, 10, 0, 10, 10, 0)!;
      expect(hit.x, closeTo(5, 1e-12));
      expect(hit.y, closeTo(5, 1e-12));
      expect(hit.z, 0);
    });

    test('returns null when the lines would cross beyond a segment end', () {
      expect(engine.lineLineIntersection(0, 0, 4, 4, 0, 10, 10, 0), isNull);
      expect(engine.lineLineIntersection(0, 0, 10, 10, 0, 10, 4, 6), isNull);
    });

    test('includes endpoints, so walls meeting at a corner both report it', () {
      final hit = engine.lineLineIntersection(0, 0, 10, 0, 10, 0, 10, 10)!;
      expect(hit.x, closeTo(10, 1e-12));
      expect(hit.y, closeTo(0, 1e-12));
    });

    test('returns null for parallel and collinear-overlapping segments', () {
      expect(engine.lineLineIntersection(0, 0, 10, 0, 0, 5, 10, 5), isNull);
      expect(engine.lineLineIntersection(0, 0, 10, 0, 5, 0, 15, 0), isNull);
    });

    test('returns null for a zero-length segment', () {
      expect(engine.lineLineIntersection(5, 5, 5, 5, 0, 0, 10, 10), isNull);
    });

    test('is order-independent', () {
      final ab = engine.lineLineIntersection(1, 2, 9, 7, 2, 8, 8, 1)!;
      final ba = engine.lineLineIntersection(2, 8, 8, 1, 1, 2, 9, 7)!;
      expect(ab.x, closeTo(ba.x, 1e-9));
      expect(ab.y, closeTo(ba.y, 1e-9));
    });
  });

  group('rayLineIntersection', () {
    test('hits a wall in front of the ray', () {
      final hit = engine.rayLineIntersection(
        10,
        -5,
        10,
        5, // vertical wall at x = 10
        0,
        0,
        Flut5Vector(1, 0),
      )!;
      expect(hit.x, closeTo(10, 1e-12));
      expect(hit.y, closeTo(0, 1e-12));
    });

    test('ignores a wall behind the ray origin', () {
      expect(
        engine.rayLineIntersection(-10, -5, -10, 5, 0, 0, Flut5Vector(1, 0)),
        isNull,
      );
    });

    test('reaches walls past the direction vector length', () {
      final hit = engine.rayLineIntersection(
        1000,
        -5,
        1000,
        5,
        0,
        0,
        Flut5Vector(0.001, 0),
      )!;
      expect(hit.x, closeTo(1000, 1e-9));
    });

    test('misses when the ray passes beside the wall segment', () {
      expect(
        engine.rayLineIntersection(10, 1, 10, 5, 0, 0, Flut5Vector(1, 0)),
        isNull,
      );
    });

    test('returns null for a zero direction or a parallel ray', () {
      expect(
        engine.rayLineIntersection(10, -5, 10, 5, 0, 0, Flut5Vector.zero()),
        isNull,
      );
      expect(
        engine.rayLineIntersection(0, 5, 10, 5, 0, 0, Flut5Vector(1, 0)),
        isNull,
      );
    });

    test('ignores the direction z component', () {
      final hit = engine.rayLineIntersection(
        10,
        -5,
        10,
        5,
        0,
        0,
        Flut5Vector(1, 0, 42),
      )!;
      expect(hit.x, closeTo(10, 1e-12));
      expect(hit.z, 0);
    });
  });

  final walls = [
    Flut5LineSegment(30, -10, 30, 10), // far wall
    Flut5LineSegment(10, -10, 10, 10), // near wall
    Flut5LineSegment(-5, -10, -5, 10), // behind the origin
  ];

  List<double> hitXs(List<Flut5Vector> hits) => [for (final h in hits) h.x];

  group('castRay', () {
    test('returns every hit sorted closest-first, whatever the list order', () {
      final hits = engine.castRay(0, 0, Flut5Vector(1, 0), walls);
      expect(hitXs(hits), [closeTo(10, 1e-12), closeTo(30, 1e-12)]);
      expect(hits.every((hit) => hit.y == 0 && hit.z == 0), isTrue);

      final reversed = engine.castRay(0, 0, Flut5Vector(1, 0), walls.reversed);
      expect(hitXs(reversed), [closeTo(10, 1e-12), closeTo(30, 1e-12)]);
    });

    test('ignores walls behind the origin', () {
      final hits = engine.castRay(0, 0, Flut5Vector(-1, 0), walls);
      expect(hitXs(hits), [closeTo(-5, 1e-12)]);
      expect(engine.castRay(20, 0, Flut5Vector(-1, 0), [walls.first]), isEmpty);
    });

    test(
      'returns an empty list when every wall is missed, or there are none',
      () {
        expect(engine.castRay(0, 0, Flut5Vector(0, 1), walls), isEmpty);
        expect(engine.castRay(0, 0, Flut5Vector(1, 0), const []), isEmpty);
      },
    );

    test('reports a corner where two walls meet once per wall', () {
      final corner = [
        Flut5LineSegment(10, -10, 10, 0),
        Flut5LineSegment(10, 0, 10, 10),
      ];
      final hits = engine.castRay(0, 0, Flut5Vector(1, 0), corner);
      expect(hitXs(hits), [closeTo(10, 1e-12), closeTo(10, 1e-12)]);
    });

    test('keeps every hit in order when a ray crosses many walls', () {
      // 40 walls (more than the reusable buffer starts with), shuffled.
      final manyWalls = [
        for (var i = 1; i <= 40; i++)
          Flut5LineSegment(i * 10.0, -10, i * 10.0, 10),
      ]..shuffle();
      final hits = engine.castRay(0, 0, Flut5Vector(1, 0), manyWalls);
      expect(hitXs(hits), [
        for (var i = 1; i <= 40; i++) closeTo(i * 10.0, 1e-9),
      ]);
      // The next call starts clean.
      expect(hitXs(engine.castRay(0, 0, Flut5Vector(1, 0), walls)), [
        closeTo(10, 1e-12),
        closeTo(30, 1e-12),
      ]);
    });

    test('matches rayLineIntersection for each single wall', () {
      final direction = Flut5Vector(3, 1);
      for (final wall in walls) {
        final fromList = engine.castRay(0, 0, direction, [wall]);
        final single = engine.rayLineIntersection(
          wall.start.x,
          wall.start.y,
          wall.end.x,
          wall.end.y,
          0,
          0,
          direction,
        );
        expect(fromList.length, single == null ? 0 : 1);
        expect(fromList.firstOrNull?.x, single?.x);
        expect(fromList.firstOrNull?.y, single?.y);
      }
    });

    test('sees walls moved through their vectors', () {
      final wall = Flut5LineSegment(10, -10, 10, 10);
      wall.start.x = 20;
      wall.end.x = 20;
      final hits = engine.castRay(0, 0, Flut5Vector(1, 0), [wall]);
      expect(hitXs(hits), [closeTo(20, 1e-12)]);
    });
  });

  group('castRayClosest', () {
    test('returns the closest hit, whatever the list order', () {
      final hit = engine.castRayClosest(0, 0, Flut5Vector(1, 0), walls)!;
      expect(hit.x, closeTo(10, 1e-12));
      expect(hit.y, closeTo(0, 1e-12));
      expect(hit.z, 0);

      final reversed = engine.castRayClosest(
        0,
        0,
        Flut5Vector(1, 0),
        walls.reversed,
      )!;
      expect(reversed.x, closeTo(10, 1e-12));
    });

    test('ignores walls behind the origin', () {
      final hit = engine.castRayClosest(0, 0, Flut5Vector(-1, 0), walls)!;
      expect(hit.x, closeTo(-5, 1e-12));
      expect(
        engine.castRayClosest(20, 0, Flut5Vector(-1, 0), [walls.first]),
        isNull,
      );
    });

    test('returns null when every wall is missed, or there are none', () {
      expect(engine.castRayClosest(0, 0, Flut5Vector(0, 1), walls), isNull);
      expect(engine.castRayClosest(0, 0, Flut5Vector(1, 0), const []), isNull);
    });

    test('agrees with the first castRay hit across many directions', () {
      final room = [
        Flut5LineSegment(-50, -50, 50, -50),
        Flut5LineSegment(50, -50, 50, 50),
        Flut5LineSegment(50, 50, -50, 50),
        Flut5LineSegment(-50, 50, -50, -50),
        Flut5LineSegment(-20, -30, 25, 10),
        Flut5LineSegment(10, -40, -15, 35),
      ];
      for (var degree = 0; degree < 360; degree += 7) {
        final angle = engine.radians(degree.toDouble());
        final direction = Flut5Vector(engine.cos(angle), engine.sin(angle));
        final closest = engine.castRayClosest(3, 4, direction, room);
        final first = engine.castRay(3, 4, direction, room).firstOrNull;
        expect(closest?.x, first?.x, reason: 'at $degree°');
        expect(closest?.y, first?.y, reason: 'at $degree°');
      }
    });
  });
}
