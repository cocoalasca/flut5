// CPU construction/recording measurements. Run explicitly with --run-skipped.
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('performance enhancement workloads', () {
    final cache = Flut5TextCache.instance;
    final recorder = ui.PictureRecorder();
    Canvas(
      recorder,
    ).drawRect(const Rect.fromLTWH(0, 0, 16, 16), Paint()..color = Colors.red);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(16, 16);
    picture.dispose();
    for (final kind in [
      'transformed shapes',
      'transformed sprites',
      'gradient text',
      'solid text',
      'layout eviction',
    ]) {
      cache.clear();
      cache.maxCacheSize = 1024;
      cache.maxLayoutCacheSize = kind == 'layout eviction' ? 1024 : 16384;
      cache.autoGrow = kind != 'layout eviction';
      final e = Flut5Engine()
        ..fill(Colors.white)
        ..noStroke();
      final samples = <double>[];
      var count = 0;
      for (var frame = 0; frame < 160; frame++) {
        final watch = Stopwatch()..start();
        if (kind == 'layout eviction') {
          for (var i = 0; i < 256; i++) {
            cache.getOrCreateLayout(
              text: 'label ${frame * 256 + i}',
              fontFamily: 'sans-serif',
              fontSize: 12,
              fontWeight: FontWeight.normal,
              fontStyle: FontStyle.normal,
              letterSpacing: 0,
            );
          }
        } else if (kind.endsWith('text')) {
          for (var i = 0; i < 30; i++) {
            e.renderQueue.enqueue(
              TextDynamicRenderItem(
                text: 'Hello World Gradient\nSecond line',
                x: 10,
                y: i * 50.0,
                fontFamily: 'sans-serif',
                fontSize: 18,
                fontWeight: FontWeight.normal,
                fontStyle: FontStyle.italic,
                textAlign: TextAlign.left,
                textLeading: 1.2,
                letterSpacing: (frame % 10) * .1,
                fillPaint: Paint()..color = Colors.white,
                strokePaint: kind == 'gradient text'
                    ? (Paint()..strokeWidth = 1.5)
                    : null,
                fillGradient: kind == 'gradient text'
                    ? const LinearGradient(colors: [Colors.red, Colors.blue])
                    : null,
                strokeGradient: kind == 'gradient text'
                    ? const LinearGradient(
                        colors: [Colors.green, Colors.yellow],
                      )
                    : null,
              ),
            );
          }
        } else {
          for (var i = 0; i < 2400; i++) {
            e.push();
            e.translate((i % 60) * 16.0, (i ~/ 60) * 16.0);
            e.rotate((i % 10) * .13);
            e.scale(1 + (i % 3) * .1);
            if (kind == 'transformed shapes') {
              if (i.isEven) {
                e.rect(-3, -3, 6, 6);
              } else {
                e.circle(0, 0, 6);
              }
            } else {
              e.renderQueue.appendImage(
                image,
                const Rect.fromLTWH(0, 0, 16, 16),
                const Rect.fromLTWH(-4, -4, 8, 8),
                BlendMode.srcOver,
              );
            }
            e.pop();
          }
        }
        final r = ui.PictureRecorder();
        e.renderQueue.execute(Canvas(r));
        count = e.renderQueue.itemCount;
        r.endRecording().dispose();
        e.renderQueue.clear();
        watch.stop();
        if (frame >= 40) samples.add(watch.elapsedMicroseconds / 1000);
      }
      samples.sort();
      // ignore: avoid_print
      print(
        '$kind: p50 ${samples[60].toStringAsFixed(3)} ms, p95 ${samples[114].toStringAsFixed(3)} ms; $count items',
      );
    }
    image.dispose();
    cache.clear();
    cache.maxCacheSize = cache.maxLayoutCacheSize = 1024;
    cache.autoGrow = true;
  }, skip: 'manual performance benchmark');
}
