// Run manually:
// flutter test test/trail_capture_benchmark_test.dart --run-skipped
//
// Measures recording + toImage Future latency. This is NOT GPU occupancy:
// skwasm's toImage creates a deferred image, so even awaiting it does not
// measure the eventual raster work. Compare paths within a renderer only;
// use real application frame timings to assess FPS. Pixel reads below are
// deliberately outside the latency benchmark.
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

enum _Path { original, physicalCopy, fusedFade }

Future<ui.Image> _capture(
  ui.Image? previous,
  int width,
  int height,
  _Path path, {
  ui.Size logicalSize = const ui.Size(997.3, 561.7),
  ui.Color fade = const ui.Color(0x22123456),
}) async {
  final r = ui.PictureRecorder();
  final c = ui.Canvas(r);
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.low;
  if (path == _Path.physicalCopy && previous != null) {
    c.drawImage(previous, ui.Offset.zero, paint);
  }
  c.scale(width / logicalSize.width, height / logicalSize.height);
  if (previous != null && path != _Path.physicalCopy) {
    if (path == _Path.fusedFade) {
      paint.colorFilter = ui.ColorFilter.mode(fade, ui.BlendMode.srcOver);
    }
    c.drawImageRect(
      previous,
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Offset.zero & logicalSize,
      paint,
    );
  }
  if (previous == null || path != _Path.fusedFade) {
    c.drawColor(fade, ui.BlendMode.srcOver);
  }
  c.drawCircle(
    const ui.Offset(20.3, 24.7),
    16.8,
    ui.Paint()..color = const ui.Color(0x8077AA33),
  );
  final p = r.endRecording();
  final image = await p.toImage(width, height);
  p.dispose();
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final candidate in [_Path.physicalCopy, _Path.fusedFade]) {
    test(
      '$candidate repeated fade pixel comparison',
      () async {
        ui.Image? original;
        ui.Image? alternative;
        var maxDifference = 0;
        var differentChannels = 0;
        for (var frame = 0; frame < 120; frame++) {
          final fade = frame < 40
              ? const ui.Color(0x01123456)
              : frame < 80
              ? const ui.Color(0x22000000)
              : const ui.Color(0x33FFFFFF);
          final a = await _capture(
            original,
            80,
            59,
            _Path.original,
            fade: fade,
          );
          final b = await _capture(alternative, 80, 59, candidate, fade: fade);
          original?.dispose();
          alternative?.dispose();
          original = a;
          alternative = b;
          final bytesA = (await a.toByteData())!.buffer.asUint8List();
          final bytesB = (await b.toByteData())!.buffer.asUint8List();
          for (var i = 0; i < bytesA.length; i++) {
            final difference = (bytesA[i] - bytesB[i]).abs();
            if (difference > maxDifference) maxDifference = difference;
            if (difference != 0) differentChannels++;
          }
        }
        original?.dispose();
        alternative?.dispose();
        if (candidate == _Path.physicalCopy) {
          expect(maxDifference, 0);
        } else {
          // Fusion has backend-dependent rounding; characterize it instead of
          // claiming pixel equivalence based on the native test renderer alone.
          // ignore: avoid_print
          print(
            'fused fade over 120 frames: max channel difference '
            '$maxDifference/255; $differentChannels differing channel samples',
          );
        }
      },
      skip: 'experimental comparison — run manually with --run-skipped',
    );
  }

  test(
    'capture latency by size and path',
    () async {
      for (final (width, height) in [(1280, 720), (1920, 1080), (2560, 1440)]) {
        final snapshots = <_Path, ui.Image>{};
        final samples = {for (final path in _Path.values) path: <double>[]};
        for (var i = 0; i < 70; i++) {
          // Rotate order to reduce warm-up/thermal bias.
          for (var j = 0; j < _Path.values.length; j++) {
            final path = _Path.values[(i + j) % _Path.values.length];
            final watch = Stopwatch()..start();
            final image = await _capture(snapshots[path], width, height, path);
            watch.stop();
            snapshots[path]?.dispose();
            snapshots[path] = image;
            if (i >= 10) samples[path]!.add(watch.elapsedMicroseconds / 1000);
          }
        }
        for (final path in _Path.values) {
          final times = samples[path]!..sort();
          // ignore: avoid_print
          print(
            '${width}x$height ${path.name}: '
            'p50 ${times[times.length ~/ 2].toStringAsFixed(3)} ms, '
            'p95 ${times[(times.length * .95).floor()].toStringAsFixed(3)} ms',
          );
          snapshots[path]!.dispose();
        }
      }
    },
    skip: 'benchmark — run manually with --run-skipped',
  );
}
