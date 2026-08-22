import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Total drawn length of a path — the sum of its contour lengths.
  double pathLength(Path path) {
    double total = 0;
    for (final m in path.computeMetrics()) {
      total += m.length;
    }
    return total;
  }

  group('dash support in beginBatch/endBatch', () {
    test('filled + dashed batch splits into solid fill and dashed stroke',
        () {
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..stroke(Colors.black);
      e.setLineDash([10, 5]);
      e.beginBatch();
      e.polygon(0, 0, 4, 20);
      e.star(60, 20, 10, 20, 5);
      e.endBatch();
      e.renderQueue.flushPending();

      expect(e.renderQueue.itemCount, 2);
      final fillItem = e.renderQueue.items[0] as PathRenderItem;
      final strokeItem = e.renderQueue.items[1] as PathRenderItem;
      expect(fillItem.fillPaint, isNotNull);
      expect(fillItem.strokePaint, isNull);
      expect(strokeItem.fillPaint, isNull);
      expect(strokeItem.strokePaint, isNotNull);
      // The fill silhouette stays the un-dashed merged path.
      expect(fillItem.bounds!.left, -10);
      expect(fillItem.bounds!.top, -10);
    });

    test('dashed stroke path carries only the "on" segments', () {
      final e = Flut5Engine()
        ..noFill()
        ..stroke(Colors.black);
      e.setLineDash([10, 5]);
      e.beginBatch();
      // One straight contour of length 100: on-segments at 0-10, 15-25,
      // 30-40, 45-55, 60-70, 75-85, 90-100 → 7 × 10 = 70 drawn pixels.
      e.line(0, 0, 100, 0);
      e.endBatch();
      e.renderQueue.flushPending();

      expect(e.renderQueue.itemCount, 1);
      final item = e.renderQueue.items.single as PathRenderItem;
      expect(item.strokePaint, isNotNull);
      expect(pathLength(item.path), closeTo(70, 0.001));
    });

    test('batched dash matches the same shape dashed outside a batch', () {
      Path dashedPathOf(void Function(Flut5Engine) draw, {required bool batch}) {
        final e = Flut5Engine()
          ..noFill()
          ..stroke(Colors.black);
        e.setLineDash([10, 5], 3);
        if (batch) e.beginBatch();
        draw(e);
        if (batch) e.endBatch();
        e.renderQueue.flushPending();
        return (e.renderQueue.items.single as PathRenderItem).path;
      }

      void shapes(Flut5Engine e) => e.polygon(50, 50, 6, 40);
      final batched = dashedPathOf(shapes, batch: true);
      final direct = dashedPathOf(shapes, batch: false);
      expect(pathLength(batched), closeTo(pathLength(direct), 0.001));
    });

    test('no dash active keeps the single merged batch item', () {
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..stroke(Colors.black);
      e.beginBatch();
      e.polygon(20, 20, 6, 20);
      e.line(0, 0, 50, 50);
      e.endBatch();
      e.renderQueue.flushPending();

      expect(e.renderQueue.itemCount, 1);
      final item = e.renderQueue.items.single as PathRenderItem;
      expect(item.fillPaint, isNotNull);
      expect(item.strokePaint, isNotNull);
    });

    test('dash active with noStroke enqueues the plain fill item', () {
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..noStroke();
      e.setLineDash([10, 5]);
      e.beginBatch();
      e.polygon(20, 20, 6, 20);
      e.endBatch();
      e.renderQueue.flushPending();

      expect(e.renderQueue.itemCount, 1);
      final item = e.renderQueue.items.single as PathRenderItem;
      expect(item.fillPaint, isNotNull);
      expect(item.strokePaint, isNull);
    });
  });
}
