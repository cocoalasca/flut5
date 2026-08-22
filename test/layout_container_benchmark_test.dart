// Container / layout cost benchmark. Skipped in normal runs — execute with:
//
//   flutter test test/layout_container_benchmark_test.dart --run-skipped
//
// Times one simulated frame (record draw calls + execute the render queue
// into a PictureRecorder canvas) for grids of containers in each overflow
// mode. Runs in the debug/JIT VM, so absolute numbers overestimate release
// performance — read them as upper bounds and compare ratios.
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
  test('container overflow cost per frame', () {
    final engine = Flut5Engine();
    engine.environment =
        const SketchEnvironment().withSize(const Size(800, 100000));

    void frame(Flut5ContainerOverflow mode, int count) {
      engine.renderQueue.clear();
      engine.containerOverflow(mode);
      engine.layoutWrap(Flut5LayoutWrap.wrap);
      engine.layoutGap(4);
      engine.beginLayout();
      for (var i = 0; i < count; i++) {
        engine.beginContainer(40, 40, {'id': 'cell$i'});
        engine.rect(4, 4, 10, 10); // cell content
        engine.endContainer();
      }
      engine.endLayout();
      final recorder = ui.PictureRecorder();
      engine.renderQueue.flushPending();
      engine.renderQueue.execute(Canvas(recorder));
      recorder.endRecording();
    }

    // Baseline: the same geometry with no containers at all.
    void bareFrame(int count) {
      engine.renderQueue.clear();
      for (var i = 0; i < count; i++) {
        engine.rect((i % 20) * 44.0, (i ~/ 20) * 44.0, 40, 40);
      }
      final recorder = ui.PictureRecorder();
      engine.renderQueue.flushPending();
      engine.renderQueue.execute(Canvas(recorder));
      recorder.endRecording();
    }

    String fmt(double ms) => ms.toStringAsFixed(2).padLeft(7);

    // ignore: avoid_print
    print('scenario                       10      100      500   (ms/frame)');
    for (final (label, mode) in [
      ('visible (no clip)', Flut5ContainerOverflow.visible),
      ('hidden  (clip)', Flut5ContainerOverflow.hidden),
    ]) {
      final t10 = bench(() => frame(mode, 10));
      final t100 = bench(() => frame(mode, 100));
      final t500 = bench(() => frame(mode, 500));
      // ignore: avoid_print
      print('${label.padRight(26)} ${fmt(t10)}  ${fmt(t100)}  ${fmt(t500)}');
    }
    final b10 = bench(() => bareFrame(10));
    final b100 = bench(() => bareFrame(100));
    final b500 = bench(() => bareFrame(500));
    // ignore: avoid_print
    print('${'bare rects (no containers)'.padRight(26)} '
        '${fmt(b10)}  ${fmt(b100)}  ${fmt(b500)}');

    final s1 = bench(() => frame(Flut5ContainerOverflow.scroll, 1));
    final s10 = bench(() => frame(Flut5ContainerOverflow.scroll, 10));
    final s50 = bench(() => frame(Flut5ContainerOverflow.scroll, 50));
    // ignore: avoid_print
    print('scroll: 1 → ${fmt(s1)} ms, 10 → ${fmt(s10)} ms, '
        '50 → ${fmt(s50)} ms');
  }, skip: 'benchmark — run manually with --run-skipped');
}
