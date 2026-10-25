import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Flut5Engine engine() => Flut5Engine()
    ..fill(Colors.white)
    ..noStroke();

  group('polygon/star — queue batching', () {
    test('consecutive polygons with the same paint coalesce into one item',
        () {
      final e = engine();
      for (var i = 0; i < 10; i++) {
        e.polygon(i * 30.0, 50, 6, 20);
      }
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
      expect(e.renderQueue.items.single, isA<PathRenderItem>());
    });

    test('polygon, star, triangle, and quad share one batch', () {
      final e = engine();
      e.polygon(20, 20, 5, 20);
      e.star(60, 20, 10, 20, 5);
      e.triangle(90, 10, 80, 30, 100, 30);
      e.quad(110, 10, 130, 12, 128, 30, 112, 28);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
    });

    test('translucent fill batches only while the shapes keep clear', () {
      Flut5Engine translucent() => Flut5Engine()
        ..fill(Colors.white.withValues(alpha: 0.5))
        ..noStroke();
      // Hexagon ends at x = 28.7, the star starts at 32.5: 3.8 px apart.
      final apart = translucent()
        ..polygon(20, 20, 6, 20)
        ..star(42, 20, 10, 20, 5);
      apart.renderQueue.flushPending();
      expect(apart.renderQueue.itemCount, 1);
      // 1.8 px apart — close enough to share an edge pixel.
      final close = translucent()
        ..polygon(20, 20, 6, 20)
        ..star(40, 20, 10, 20, 5);
      close.renderQueue.flushPending();
      expect(close.renderQueue.itemCount, 2);
    });

    test('invalid sides/points enqueue nothing', () {
      final e = engine();
      e.polygon(20, 20, 2, 20);
      e.star(60, 20, 10, 20, 2);
      e.renderQueue.flushPending();
      expect(e.renderQueue.isEmpty, isTrue);
    });
  });

  group('polygon/star — translate folding', () {
    test('push/translate/polygon/pop loops coalesce into one path item', () {
      final e = engine();
      for (var i = 0; i < 10; i++) {
        e.push();
        e.translate(i * 10.0, 5);
        e.polygon(0, 0, 6, 8);
        e.pop();
      }
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
      expect(e.renderQueue.items.single, isA<PathRenderItem>());
    });

    test('folded translate bakes polygon geometry at shifted coordinates',
        () {
      final e = engine();
      e.renderQueue.flushPending();
      final slot = e.renderQueue.itemCount;
      e.push();
      e.translate(100, 50);
      // 4-gon of radius 10, first vertex up: exact bounds (-10,-10)-(10,10).
      e.polygon(0, 0, 4, 20);
      e.pop();
      e.renderQueue.flushPending();
      expect(
        e.renderQueue.contentBoundsFrom(slot),
        const Rect.fromLTRB(90, 40, 110, 60),
      );
    });

    test('star under a folded translate keeps a single batched item', () {
      final e = engine();
      e.push();
      e.translate(30, 40);
      e.star(0, 0, 10, 20, 5);
      e.pop();
      e.star(100, 100, 10, 20, 5);
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
    });
  });

  group('polygon/star — geometry', () {
    test('polygon vertices sit on the inscribing circle', () {
      final e = engine();
      e.polygon(0, 0, 4, 20);
      e.renderQueue.flushPending();
      final item = e.renderQueue.items.single as PathRenderItem;
      expect(item.bounds, const Rect.fromLTRB(-10, -10, 10, 10));
    });

    test('star outer points reach the outer radius, first point up', () {
      final e = engine();
      e.star(0, 0, 10, 20, 5);
      e.renderQueue.flushPending();
      final b = (e.renderQueue.items.single as PathRenderItem).bounds!;
      // Outer R = 10: minY is the top point, ±x extremes at cos(18°),
      // maxY at the two lower points, sin(54°).
      expect(b.top, closeTo(-10, 1e-9));
      expect(b.left, closeTo(-9.5106, 1e-4));
      expect(b.right, closeTo(9.5106, 1e-4));
      expect(b.bottom, closeTo(8.0902, 1e-4));
    });
  });

  group('polygon/star — beginBatch/endBatch', () {
    test('shapes inside a batch merge into a single item', () {
      final e = engine();
      e.beginBatch();
      e.polygon(20, 20, 6, 20);
      e.star(60, 20, 10, 20, 5);
      e.polygon(100, 20, 3, 20);
      e.endBatch();
      e.renderQueue.flushPending();
      expect(e.renderQueue.itemCount, 1);
    });
  });
}
