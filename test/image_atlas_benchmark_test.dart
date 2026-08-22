// Image atlas batching benchmark. Skipped in normal runs — execute with:
//
//   flutter test test/image_atlas_benchmark_test.dart --run-skipped
//
// Times one simulated frame (build the render queue + execute it into a
// PictureRecorder canvas) for mosaics of N tiles, comparing the atlas batch
// against the pre-batching path (one ImageRenderItem, one drawImageRect per
// tile). Runs in the debug/JIT VM, so absolute numbers overestimate release
// performance — read them as upper bounds and compare ratios. This measures
// display-list recording on the CPU; the GPU-side saving of collapsing N draw
// calls into one is additional and needs a real device to observe.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// Median wall-clock ms of [body] over [runs] timed executions.
double bench(void Function() body, {int warmup = 5, int runs = 15}) {
  for (var i = 0; i < warmup; i++) {
    body();
  }
  final times = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    times.add(sw.elapsedMicroseconds / 1000.0);
  }
  times.sort();
  return times[times.length ~/ 2];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'mosaic cost per frame: atlas batch vs per-tile blit',
    () {
      final engine = Flut5Engine()
        ..fill(Colors.white)
        ..noStroke();

      final recorder0 = ui.PictureRecorder();
      Canvas(recorder0).drawRect(
        const Rect.fromLTWH(0, 0, 32, 32),
        Paint()..color = Colors.red,
      );
      final picture0 = recorder0.endRecording();
      final source = picture0.toImageSync(32, 32);
      picture0.dispose();
      final tile = Flut5Image.fromUiImage(source);
      const srcRect = Rect.fromLTWH(0, 0, 32, 32);

      int lastItemCount = 0;

      void batchedFrame(int cols, int rows) {
        engine.renderQueue.clear();
        for (var row = 0; row < rows; row++) {
          for (var col = 0; col < cols; col++) {
            engine.image(tile, col * 32.0, row * 32.0);
          }
        }
        engine.renderQueue.flushPending();
        lastItemCount = engine.renderQueue.itemCount;
        final recorder = ui.PictureRecorder();
        engine.renderQueue.execute(Canvas(recorder));
        recorder.endRecording().dispose();
      }

      // Reconstructs the path taken before batching existed: one
      // ImageRenderItem per tile, each executing its own drawImageRect.
      void perTileFrame(int cols, int rows) {
        engine.renderQueue.clear();
        for (var row = 0; row < rows; row++) {
          for (var col = 0; col < cols; col++) {
            engine.renderQueue.enqueue(
              ImageRenderItem(
                image: source,
                src: srcRect,
                dst: Rect.fromLTWH(col * 32.0, row * 32.0, 32, 32),
                blendMode: BlendMode.srcOver,
              ),
            );
          }
        }
        engine.renderQueue.flushPending();
        lastItemCount = engine.renderQueue.itemCount;
        final recorder = ui.PictureRecorder();
        engine.renderQueue.execute(Canvas(recorder));
        recorder.endRecording().dispose();
      }

      String fmt(double ms) => ms.toStringAsFixed(3).padLeft(8);

      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('mosaic          tiles   per-tile    atlas   speedup   items');
      for (final (cols, rows) in [(10, 10), (30, 30), (60, 40)]) {
        final tiles = cols * rows;
        final slow = bench(() => perTileFrame(cols, rows));
        final slowItems = lastItemCount;
        final fast = bench(() => batchedFrame(cols, rows));
        final fastItems = lastItemCount;
        // ignore: avoid_print
        print(
          '${'$cols x $rows'.padRight(14)} ${'$tiles'.padLeft(5)} '
          '${fmt(slow)} ${fmt(fast)}  '
          '${(slow / fast).toStringAsFixed(1).padLeft(6)}x  '
          '$slowItems -> $fastItems',
        );

        expect(slowItems, tiles);
        expect(fastItems, 1);
      }

      tile.dispose();
    },
    skip: 'benchmark — run manually with --run-skipped',
  );
}
