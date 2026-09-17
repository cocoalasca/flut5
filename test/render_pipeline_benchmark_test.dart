// Measures queue construction and display-list recording, not GPU time/FPS.
// flutter test test/render_pipeline_benchmark_test.dart --run-skipped
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'rotation and uniform scale queue construction and recording',
    _transformBenchmark,
    skip: 'benchmark — run manually with --run-skipped',
  );
  test('shape, vertex, line and mixed queue workloads', () {
    for (final kind in [
      'rects',
      'lines',
      'vertex shapes',
      'long vertex path',
      'mixed',
    ]) {
      final e = Flut5Engine();
      e.fill(Colors.white);
      e.stroke(Colors.blue);
      e.strokeWeight(1);
      final samples = <double>[];
      int items = 0;
      for (var frame = 0; frame < 80; frame++) {
        final watch = Stopwatch()..start();
        if (kind == 'long vertex path') {
          e.beginShape();
          for (var i = 0; i < 20000; i++) {
            e.vertex(i * .1, i.isEven ? 10 : 30);
          }
          e.endShape();
        } else {
          for (var i = 0; i < 2400; i++) {
            final x = (i % 60) * 12.0;
            final y = (i ~/ 60) * 12.0;
            switch (kind) {
              case 'rects':
                e.rect(x, y, 8, 8);
              case 'lines':
                e.line(x, y, x + 8, y + 8);
              case 'vertex shapes':
                e.beginShape();
                e.vertex(x, y);
                e.vertex(x + 8, y);
                e.vertex(x + 8, y + 8);
                e.vertex(x, y + 8);
                e.endShape(close: true);
              case 'mixed':
                e.rect(x, y, 8, 8);
                e.line(x, y, x + 8, y + 8);
                e.circle(x + 4, y + 4, 5);
            }
          }
        }
        final recorder = ui.PictureRecorder();
        e.renderQueue.execute(Canvas(recorder));
        items = e.renderQueue.itemCount;
        recorder.endRecording().dispose();
        e.renderQueue.clear();
        watch.stop();
        if (frame >= 20) samples.add(watch.elapsedMicroseconds / 1000);
      }
      samples.sort();
      // ignore: avoid_print
      print(
        '$kind: p50 ${samples[30].toStringAsFixed(3)} ms, '
        'p95 ${samples[57].toStringAsFixed(3)} ms; $items items',
      );
    }
  }, skip: 'benchmark — run manually with --run-skipped');
}

// Compare identical per-shape transforms with and without geometry folding.
// This measures CPU queue construction + display-list recording, not GPU time.
void _transformBenchmark() {
  for (final folded in [false, true]) {
    final e = Flut5Engine()
      ..fill(Colors.white)
      ..noStroke();
    final samples = <double>[];
    var items = 0;
    for (var frame = 0; frame < 80; frame++) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < 2400; i++) {
        final x = (i % 60) * 12.0, y = (i ~/ 60) * 12.0;
        final angle = (i % 10) * .1;
        final scale = 1 + (i % 4) * .1;
        if (folded) {
          e.push();
          e.translate(x, y);
          e.rotate(angle);
          e.scale(scale);
        } else {
          e.renderQueue.enqueue(TransformRenderItem.push());
          e.renderQueue.enqueue(TransformRenderItem.translate(x, y));
          e.renderQueue.enqueue(TransformRenderItem.rotate(angle));
          e.renderQueue.enqueue(TransformRenderItem.scale(scale, scale));
        }
        e.rect(-3, -3, 6, 6);
        if (folded) {
          e.pop();
        } else {
          e.renderQueue.enqueue(TransformRenderItem.pop());
        }
      }
      final recorder = ui.PictureRecorder();
      e.renderQueue.execute(Canvas(recorder));
      items = e.renderQueue.itemCount;
      recorder.endRecording().dispose();
      e.renderQueue.clear();
      watch.stop();
      if (frame >= 20) samples.add(watch.elapsedMicroseconds / 1000);
    }
    samples.sort();
    // ignore: avoid_print
    print(
      'rotated/scaled rects (${folded ? "folded" : "canvas"}): '
      'p50 ${samples[30].toStringAsFixed(3)} ms, '
      'p95 ${samples[57].toStringAsFixed(3)} ms; $items items',
    );
  }
}
