import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flut5/flut5.dart';

/// Every point stored anywhere under [area], leaves only.
List<Flut5QuadtreePoint<T>> allStoredPoints<T>(Flut5Quadtree<T> area) => [
  ...area.points,
  for (final child in area.children) ...allStoredPoints(child),
];

/// Whether any area that has been split still holds points itself.
bool anySplitAreaHoldsPoints(Flut5Quadtree area) =>
    (area.children.isNotEmpty && area.points.isNotEmpty) ||
    area.children.any(anySplitAreaHoldsPoints);

void main() {
  group('Flut5Quadtree', () {
    test('defaults to a 1 × 1 area at the origin holding 4 per area', () {
      final tree = Flut5Quadtree();
      expect(tree.x, 0.0);
      expect(tree.y, 0.0);
      expect(tree.width, 1.0);
      expect(tree.height, 1.0);
      expect(tree.capacity, 4);
      expect(tree.maxDepth, Flut5Quadtree.defaultMaxDepth);
      expect(Flut5Quadtree.defaultMaxDepth, 2048);
      expect(tree.points, isEmpty);
      expect(tree.children, isEmpty);
    });

    test('children inherit capacity and maxDepth', () {
      final tree = Flut5Quadtree(100, 100, 2, 7)..subdivide();
      for (final child in tree.children) {
        expect(child.capacity, 2);
        expect(child.maxDepth, 7);
      }
    });

    test('rejects a bad size, capacity or maxDepth', () {
      expect(() => Flut5Quadtree(0, 10), throwsArgumentError);
      expect(() => Flut5Quadtree(10, -1), throwsArgumentError);
      expect(() => Flut5Quadtree(10, 10, 0), throwsArgumentError);
      expect(() => Flut5Quadtree(10, 10, 4, -1), throwsArgumentError);
      expect(Flut5Quadtree(10, 10, 4, 0).maxDepth, 0);
    });

    test('add refuses points outside the tree, edges included', () {
      final tree = Flut5Quadtree(100, 50);
      expect(tree.add(Flut5QuadtreePoint(-0.1, 10, 'left')), isFalse);
      expect(tree.add(Flut5QuadtreePoint(10, 50.1, 'below')), isFalse);
      expect(tree.add(Flut5QuadtreePoint(0, 0, 'corner')), isTrue);
      expect(tree.add(Flut5QuadtreePoint(100, 50, 'far corner')), isTrue);
      expect(allStoredPoints(tree).map((p) => p.payload), [
        'corner',
        'far corner',
      ]);
    });

    test('keeps up to capacity points without splitting', () {
      final tree = Flut5Quadtree(100, 100);
      for (var i = 0; i < 4; i++) {
        tree.add(Flut5QuadtreePoint(i * 10.0, i * 10.0, i));
      }
      expect(tree.children, isEmpty);
      expect(tree.points, hasLength(4));
    });

    test('one point over capacity splits and moves every point down', () {
      final tree = Flut5Quadtree(100, 100);
      tree.add(Flut5QuadtreePoint(10, 10, 'top-left'));
      tree.add(Flut5QuadtreePoint(90, 10, 'top-right'));
      tree.add(Flut5QuadtreePoint(10, 90, 'bottom-left'));
      tree.add(Flut5QuadtreePoint(90, 90, 'bottom-right'));
      tree.add(Flut5QuadtreePoint(20, 20, 'top-left 2'));

      expect(tree.points, isEmpty, reason: 'split areas hold no points');
      expect(tree.children, hasLength(4));
      final [topLeft, topRight, bottomLeft, bottomRight] = tree.children;
      expect(topLeft.points.map((p) => p.payload), ['top-left', 'top-left 2']);
      expect(topRight.points.single.payload, 'top-right');
      expect(bottomLeft.points.single.payload, 'bottom-left');
      expect(bottomRight.points.single.payload, 'bottom-right');

      expect((topRight.x, topRight.y), (50.0, 0.0));
      expect((bottomLeft.x, bottomLeft.y), (0.0, 50.0));
      expect((bottomRight.width, bottomRight.height), (50.0, 50.0));
    });

    test('keeps splitting until the new point has room', () {
      final tree = Flut5Quadtree(100, 100);
      for (var i = 0; i < 5; i++) {
        tree.add(Flut5QuadtreePoint(1.0 + i, 1.0 + i, i));
      }
      expect(tree.children.first.children, isNotEmpty);
      expect(anySplitAreaHoldsPoints(tree), isFalse);
      expect(allStoredPoints(tree), hasLength(5));
    });

    test('subdivide by hand moves the points and is safe to repeat', () {
      final tree = Flut5Quadtree(100, 100);
      tree.add(Flut5QuadtreePoint(10, 10, 'a'));
      tree.add(Flut5QuadtreePoint(60, 60, 'b'));

      tree.subdivide();
      final childrenAfterFirstSplit = tree.children.toList();
      tree.subdivide();

      expect(tree.points, isEmpty);
      expect(tree.children, childrenAfterFirstSplit);
      expect(tree.children[0].points.single.payload, 'a');
      expect(tree.children[3].points.single.payload, 'b');
    });

    test('points on a center line go to the right / lower child', () {
      final tree = Flut5Quadtree(100, 100)..subdivide();
      tree.add(Flut5QuadtreePoint(50, 10, 'on vertical line'));
      tree.add(Flut5QuadtreePoint(10, 50, 'on horizontal line'));
      expect(tree.children[1].points.single.payload, 'on vertical line');
      expect(tree.children[2].points.single.payload, 'on horizontal line');
    });

    test('one point over capacity at a shared position throws at once', () {
      final tree = Flut5Quadtree(100, 100);
      for (var i = 0; i < 4; i++) {
        tree.add(Flut5QuadtreePoint(25, 25, i));
      }
      expect(
        () => tree.add(Flut5QuadtreePoint(25, 25, 'fifth')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('exactly that position'),
          ),
        ),
      );
      expect(tree.children, isEmpty, reason: 'no pointless splits first');
      expect(tree.query(0, 0, 100, 100).map((p) => p.payload), [0, 1, 2, 3]);
    });

    test('a different point still fits beside a full shared position', () {
      final tree = Flut5Quadtree(100, 100);
      for (var i = 0; i < 4; i++) {
        tree.add(Flut5QuadtreePoint(25, 25, i));
      }
      expect(tree.add(Flut5QuadtreePoint(25.001, 25, 'neighbour')), isTrue);
      expect(allStoredPoints(tree), hasLength(5));
      expect(anySplitAreaHoldsPoints(tree), isFalse);
    });

    test('a full area at maxDepth throws and the tree stays intact', () {
      // Capacity 1, at most 2 splits: (10, 10) and (20, 20) still share an
      // area 25 wide after both splits.
      final tree = Flut5Quadtree(100, 100, 1, 2);
      tree.add(Flut5QuadtreePoint(10, 10, 'first'));
      expect(
        () => tree.add(Flut5QuadtreePoint(20, 20, 'second')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('maxDepth'),
          ),
        ),
      );
      expect(allStoredPoints(tree).single.payload, 'first');
      expect(anySplitAreaHoldsPoints(tree), isFalse);
      final deepestArea = tree.children.first.children.first;
      expect(deepestArea.width, 25.0);
      expect(deepestArea.points.single.payload, 'first');
      expect(deepestArea.subdivide, throwsStateError);
    });

    test('maxDepth 0 never splits', () {
      final tree = Flut5Quadtree(100, 100, 2, 0)
        ..add(Flut5QuadtreePoint(10, 10, 'a'))
        ..add(Flut5QuadtreePoint(90, 90, 'b'));
      expect(tree.subdivide, throwsStateError);
      expect(() => tree.add(Flut5QuadtreePoint(50, 50, 'c')), throwsStateError);
      expect(tree.points, hasLength(2));
    });

    test('the default maxDepth separates points a tiny step apart', () {
      // Needs ~1000 splits: the second point is 1e-300 from the first.
      final tree = Flut5Quadtree(1, 1, 1)
        ..add(Flut5QuadtreePoint(0, 0, 'origin'))
        ..add(Flut5QuadtreePoint(1e-300, 1e-300, 'next to it'));

      var depth = 0;
      var area = tree;
      while (area.children.isNotEmpty) {
        area = area.children.first;
        depth++;
      }
      expect(depth, greaterThan(900));
      expect(tree.query(0, 0, 1, 1), hasLength(2));
      expect(tree.query(0, 0, 0, 0).single.payload, 'origin');

      expect(
        () => Flut5Quadtree(1, 1, 1, 900)
          ..add(Flut5QuadtreePoint(0, 0, 'origin'))
          ..add(Flut5QuadtreePoint(1e-300, 1e-300, 'next to it')),
        throwsStateError,
      );
    });

    test('query finds exactly the points a full scan finds', () {
      final random = math.Random(7);
      final tree = Flut5Quadtree<int>(640, 480);
      final everyPoint = <Flut5QuadtreePoint<int>>[];
      for (var i = 0; i < 2000; i++) {
        final point = Flut5QuadtreePoint(
          random.nextDouble() * 640,
          random.nextDouble() * 480,
          i,
        );
        everyPoint.add(point);
        tree.add(point);
      }

      for (var i = 0; i < 200; i++) {
        final queryX = random.nextDouble() * 800 - 80;
        final queryY = random.nextDouble() * 600 - 60;
        final queryWidth = random.nextDouble() * 300 - 50;
        final queryHeight = random.nextDouble() * 300 - 50;
        final left = math.min(queryX, queryX + queryWidth);
        final right = math.max(queryX, queryX + queryWidth);
        final top = math.min(queryY, queryY + queryHeight);
        final bottom = math.max(queryY, queryY + queryHeight);

        final expected = {
          for (final point in everyPoint)
            if (point.x >= left &&
                point.x <= right &&
                point.y >= top &&
                point.y <= bottom)
              point.payload,
        };
        final found = tree.query(queryX, queryY, queryWidth, queryHeight);
        expect(found.map((p) => p.payload).toSet(), expected);
        expect(found, hasLength(expected.length), reason: 'no duplicates');
      }
    });

    test('query counts points on the rectangle edges as inside', () {
      final tree = Flut5Quadtree(100, 100);
      tree.add(Flut5QuadtreePoint(10, 10, 'top-left corner'));
      tree.add(Flut5QuadtreePoint(30, 20, 'bottom-right corner'));
      tree.add(Flut5QuadtreePoint(30.01, 20, 'just outside'));
      expect(tree.query(10, 10, 20, 10).map((p) => p.payload), [
        'top-left corner',
        'bottom-right corner',
      ]);
    });

    test('payloads keep their type and can be anything', () {
      final typed = Flut5Quadtree<Flut5Vector>(10, 10)
        ..add(Flut5QuadtreePoint(1, 1, Flut5Vector(1, 2)));
      final Flut5Vector vector = typed.query(0, 0, 10, 10).single.payload;
      expect(vector.y, 2.0);

      final mixed = Flut5Quadtree(10, 10)
        ..add(Flut5QuadtreePoint(1, 1, 'text'))
        ..add(Flut5QuadtreePoint(2, 2, 42))
        ..add(Flut5QuadtreePoint(3, 3, null));
      expect(mixed.query(0, 0, 10, 10).map((p) => p.payload), [
        'text',
        42,
        null,
      ]);
    });

    test('the points and children views are read-only', () {
      final tree = Flut5Quadtree(10, 10)..add(Flut5QuadtreePoint(1, 1, 0));
      expect(() => tree.points.clear(), throwsUnsupportedError);
      expect(() => tree.children.clear(), throwsUnsupportedError);
    });
  });
}
