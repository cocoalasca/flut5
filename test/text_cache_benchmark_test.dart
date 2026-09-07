// CPU queue construction + display-list recording, not GPU raster time/FPS.
// flutter test test/text_cache_benchmark_test.dart --run-skipped
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'dynamic text cache recording workloads',
    () {
      final cache = Flut5TextCache.instance;
      for (final scenario in [
        'stable',
        'spacing',
        'wrapped spacing',
        'counter',
      ]) {
        cache.clear();
        cache.maxCacheSize = 1024;
        cache.maxLayoutCacheSize = 1024;
        cache.growthLimit = cache.layoutGrowthLimit = 16384;
        cache.maxCacheBytes = 128 << 20;
        cache.autoGrow = true;
        final engine = Flut5Engine();
        engine.textSize(40);
        engine.noStroke();
        engine.fill(Colors.white);
        engine.textAlign(TextAlign.center);
        final samples = <double>[];
        for (var frame = 0; frame < 1200; frame++) {
          final watch = Stopwatch()..start();
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          for (var row = 0; row < 15; row++) {
            final spacing = scenario.contains('spacing')
                ? 30 + math.sin(frame * .01 + row * .35) * 30
                : 2.0;
            engine.letterSpacing(spacing);
            engine.text(
              scenario == 'counter'
                  ? 'Score: ${frame * 15 + row}'
                  : 'Hello World',
              500,
              row * 42.0,
              scenario == 'wrapped spacing' ? 400 : null,
            );
          }
          engine.renderQueue.execute(canvas);
          engine.renderQueue.clear();
          recorder.endRecording().dispose();
          watch.stop();
          if (frame >= 200) samples.add(watch.elapsedMicroseconds / 1000);
        }
        samples.sort();
        // ignore: avoid_print
        print(
          '$scenario: p50 ${samples[500].toStringAsFixed(3)} ms, '
          'p95 ${samples[950].toStringAsFixed(3)} ms; '
          '${cache.cacheLength} textures, ${cache.cacheBytes} bytes, '
          '${cache.layoutCacheLength} layouts (cap ${cache.maxLayoutCacheSize})',
        );
      }
      cache.clear();
      cache.maxCacheSize = cache.maxLayoutCacheSize = 1024;
      Flut5Console.flush();
    },
    skip: 'benchmark — run manually with --run-skipped',
  );
}
