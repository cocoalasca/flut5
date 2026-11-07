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
}
