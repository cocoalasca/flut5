import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../math/flut5_vector.dart';
import '../text/flut5_font.dart';

/// Per-sketch runtime environment state.
///
/// Holds canvas dimensions and frame timing data that change as the sketch is
/// rendered.
@immutable
final class SketchEnvironment {
  final Size size;
  final double mouseX;
  final double mouseY;
  final double pmouseX;
  final double pmouseY;
  final String key;
  final int keyCode;
  final int frameCount;
  final double deltaTime;
  final int _lastFrameMs;

  /// Font shape data preloaded from Flutter's generated `FontManifest.json`,
  /// keyed by pubspec/manifest family name.
  final Map<String, Flut5FontData> fonts;

  /// Number of frames used to compute [avgMouseX], [avgMouseY] and [avgMouse].
  /// Defaults to 15 frames (~250 ms at 60 fps).
  final int avgMouseFrames;

  /// Average mouse velocity x-component (px / frame) over the last
  /// [avgMouseFrames] rendered frames. 0 before the first frame samples.
  final double avgMouseX;

  /// Average mouse velocity y-component (px / frame) over the last
  /// [avgMouseFrames] rendered frames. 0 before the first frame samples.
  final double avgMouseY;

  /// Per-frame velocity samples backing [avgMouseX] / [avgMouseY], stored as
  /// fixed-size ring buffers so [nextFrame] appends without allocating.
  ///
  /// The buffers are *shared* along the environment chain: every `with*` copy
  /// carries the same instances, and [nextFrame] writes into them in place —
  /// only the scalar ring state ([_sampleHead], [_sampleCount]) travels
  /// immutably. That is safe because the engine advances a single linear
  /// chain (each frame's environment replaces the previous one) and the
  /// buffers are private with no external readers; branching two `nextFrame`
  /// calls off one instance would interleave samples, which the engine never
  /// does. `null` until the first [nextFrame] (const constructor).
  final Float64List? _vxSamples;
  final Float64List? _vySamples;

  /// Next ring-buffer slot [nextFrame] writes to. While the buffer isn't full
  /// yet, valid samples occupy indices `0 .. _sampleCount - 1`.
  final int _sampleHead;

  /// Number of valid samples in the ring buffers (≤ buffer length).
  final int _sampleCount;

  const SketchEnvironment._({
    required this.size,
    required this.mouseX,
    required this.mouseY,
    required this.pmouseX,
    required this.pmouseY,
    required this.key,
    required this.keyCode,
    required this.frameCount,
    required this.deltaTime,
    required this.fonts,
    required int lastFrameMs,
    required this.avgMouseFrames,
    required this.avgMouseX,
    required this.avgMouseY,
    required Float64List? vxSamples,
    required Float64List? vySamples,
    required int sampleHead,
    required int sampleCount,
  }) : _lastFrameMs = lastFrameMs,
       _vxSamples = vxSamples,
       _vySamples = vySamples,
       _sampleHead = sampleHead,
       _sampleCount = sampleCount;

  /// Creates a fresh environment before the sketch has rendered any frames.
  const SketchEnvironment()
    : this._(
        size: Size.zero,
        mouseX: 0,
        mouseY: 0,
        pmouseX: 0,
        pmouseY: 0,
        key: '',
        keyCode: 0,
        frameCount: 0,
        deltaTime: 0,
        fonts: const <String, Flut5FontData>{},
        lastFrameMs: 0,
        avgMouseFrames: 15,
        avgMouseX: 0,
        avgMouseY: 0,
        vxSamples: null,
        vySamples: null,
        sampleHead: 0,
        sampleCount: 0,
      );

  /// Width of the drawing area.
  double get width => size.width;

  /// Height of the drawing area.
  double get height => size.height;

  /// Average mouse velocity (px / frame) over the last [avgMouseFrames]
  /// rendered frames as a 2D [Flut5Vector]. Useful for getting a general
  /// idea of where the mouse is heading.
  Flut5Vector get avgMouse => Flut5Vector(avgMouseX, avgMouseY);

  /// Returns the current frame rate as frames per second.
  ///
  /// Computed from [deltaTime]. Returns 0 before the first frame.
  double frameRate() => deltaTime > 0 ? 1000 / deltaTime : 0;

  /// Returns an updated environment with a new canvas [size].
  SketchEnvironment withSize(Size size) {
    return SketchEnvironment._(
      size: size,
      mouseX: mouseX,
      mouseY: mouseY,
      pmouseX: pmouseX,
      pmouseY: pmouseY,
      key: key,
      keyCode: keyCode,
      frameCount: frameCount,
      deltaTime: deltaTime,
      fonts: fonts,
      lastFrameMs: _lastFrameMs,
      avgMouseFrames: avgMouseFrames,
      avgMouseX: avgMouseX,
      avgMouseY: avgMouseY,
      vxSamples: _vxSamples,
      vySamples: _vySamples,
      sampleHead: _sampleHead,
      sampleCount: _sampleCount,
    );
  }

  /// Returns an updated environment with the latest mouse positions.
  SketchEnvironment withMousePosition({
    required double mouseX,
    required double mouseY,
    required double pmouseX,
    required double pmouseY,
  }) {
    return SketchEnvironment._(
      size: size,
      mouseX: mouseX,
      mouseY: mouseY,
      pmouseX: pmouseX,
      pmouseY: pmouseY,
      key: key,
      keyCode: keyCode,
      frameCount: frameCount,
      deltaTime: deltaTime,
      fonts: fonts,
      lastFrameMs: _lastFrameMs,
      avgMouseFrames: avgMouseFrames,
      avgMouseX: avgMouseX,
      avgMouseY: avgMouseY,
      vxSamples: _vxSamples,
      vySamples: _vySamples,
      sampleHead: _sampleHead,
      sampleCount: _sampleCount,
    );
  }

  /// Returns an updated environment with the latest keyboard state.
  SketchEnvironment withKeyboard({required String key, required int keyCode}) {
    return SketchEnvironment._(
      size: size,
      mouseX: mouseX,
      mouseY: mouseY,
      pmouseX: pmouseX,
      pmouseY: pmouseY,
      key: key,
      keyCode: keyCode,
      frameCount: frameCount,
      deltaTime: deltaTime,
      fonts: fonts,
      lastFrameMs: _lastFrameMs,
      avgMouseFrames: avgMouseFrames,
      avgMouseX: avgMouseX,
      avgMouseY: avgMouseY,
      vxSamples: _vxSamples,
      vySamples: _vySamples,
      sampleHead: _sampleHead,
      sampleCount: _sampleCount,
    );
  }

  /// Returns an updated environment with a new [avgMouseFrames] window.
  /// Throws [ArgumentError] if [frames] is less than 1. Existing samples
  /// are kept (and trimmed to the newest if the new window is smaller).
  SketchEnvironment withAvgMouseFrames(int frames) {
    if (frames < 1) {
      throw ArgumentError.value(frames, 'frames', 'must be >= 1');
    }
    var vx = _vxSamples;
    var vy = _vySamples;
    var head = _sampleHead;
    var count = _sampleCount;
    if (vx != null && vy != null && vx.length != frames) {
      final resized = _resizeRing(vx, vy, head, count, frames);
      vx = resized.$1;
      vy = resized.$2;
      head = resized.$3;
      count = resized.$4;
    }
    final (avgX, avgY) = vx == null || vy == null
        ? (0.0, 0.0)
        : _ringAverages(vx, vy, count);
    return SketchEnvironment._(
      size: size,
      mouseX: mouseX,
      mouseY: mouseY,
      pmouseX: pmouseX,
      pmouseY: pmouseY,
      key: key,
      keyCode: keyCode,
      frameCount: frameCount,
      deltaTime: deltaTime,
      fonts: fonts,
      lastFrameMs: _lastFrameMs,
      avgMouseFrames: frames,
      avgMouseX: avgX,
      avgMouseY: avgY,
      vxSamples: vx,
      vySamples: vy,
      sampleHead: head,
      sampleCount: count,
    );
  }

  /// Returns an updated environment for a newly rendered frame at [nowMs].
  ///
  /// Pushes one velocity sample (`mouseX - pmouseX`, `mouseY - pmouseY`)
  /// into the rolling [avgMouseFrames]-sized ring buffer (overwriting the
  /// oldest sample in place — no per-frame list copies) and recomputes
  /// [avgMouseX] / [avgMouseY].
  SketchEnvironment nextFrame(int nowMs) {
    final delta = _lastFrameMs == 0 ? 0.0 : (nowMs - _lastFrameMs).toDouble();
    var vx = _vxSamples;
    var vy = _vySamples;
    var head = _sampleHead;
    var count = _sampleCount;
    if (vx == null || vy == null || vx.length != avgMouseFrames) {
      final resized = _resizeRing(vx, vy, head, count, avgMouseFrames);
      vx = resized.$1;
      vy = resized.$2;
      head = resized.$3;
      count = resized.$4;
    }
    vx[head] = mouseX - pmouseX;
    vy[head] = mouseY - pmouseY;
    head = head + 1 == vx.length ? 0 : head + 1;
    if (count < vx.length) count++;
    final (avgX, avgY) = _ringAverages(vx, vy, count);
    return SketchEnvironment._(
      size: size,
      mouseX: mouseX,
      mouseY: mouseY,
      pmouseX: pmouseX,
      pmouseY: pmouseY,
      key: key,
      keyCode: keyCode,
      frameCount: frameCount + 1,
      deltaTime: delta,
      fonts: fonts,
      lastFrameMs: nowMs,
      avgMouseFrames: avgMouseFrames,
      avgMouseX: avgX,
      avgMouseY: avgY,
      vxSamples: vx,
      vySamples: vy,
      sampleHead: head,
      sampleCount: count,
    );
  }

  /// Copies the newest `min(count, newLength)` samples, oldest first, into
  /// fresh ring buffers of [newLength]. Returns `(vx, vy, head, count)` —
  /// with valid samples compacted to the front, so the not-full invariant
  /// (valid = `0 .. count - 1`) holds for the new buffers.
  static (Float64List, Float64List, int, int) _resizeRing(
    Float64List? vx,
    Float64List? vy,
    int head,
    int count,
    int newLength,
  ) {
    final nvx = Float64List(newLength);
    final nvy = Float64List(newLength);
    if (vx == null || vy == null || count == 0) return (nvx, nvy, 0, 0);
    final keep = count < newLength ? count : newLength;
    final len = vx.length;
    // Oldest kept sample sits `keep` steps behind the write head.
    var src = (head - keep) % len;
    if (src < 0) src += len;
    for (int i = 0; i < keep; i++) {
      nvx[i] = vx[src];
      nvy[i] = vy[src];
      src = src + 1 == len ? 0 : src + 1;
    }
    return (nvx, nvy, keep == newLength ? 0 : keep, keep);
  }

  /// Averages over the [count] valid ring-buffer samples. Order-independent,
  /// so ring layout doesn't matter once the buffer is full; while filling,
  /// valid samples occupy the front (see [_sampleHead]).
  static (double, double) _ringAverages(
    Float64List vx,
    Float64List vy,
    int count,
  ) {
    if (count == 0) return (0, 0);
    double sumX = 0;
    double sumY = 0;
    for (int i = 0; i < count; i++) {
      sumX += vx[i];
      sumY += vy[i];
    }
    return (sumX / count, sumY / count);
  }

  /// Returns an updated environment with preloaded font shape data.
  SketchEnvironment withFonts(Map<String, Flut5FontData> fonts) {
    return SketchEnvironment._(
      size: size,
      mouseX: mouseX,
      mouseY: mouseY,
      pmouseX: pmouseX,
      pmouseY: pmouseY,
      key: key,
      keyCode: keyCode,
      frameCount: frameCount,
      deltaTime: deltaTime,
      fonts: Map.unmodifiable(fonts),
      lastFrameMs: _lastFrameMs,
      avgMouseFrames: avgMouseFrames,
      avgMouseX: avgMouseX,
      avgMouseY: avgMouseY,
      vxSamples: _vxSamples,
      vySamples: _vySamples,
      sampleHead: _sampleHead,
      sampleCount: _sampleCount,
    );
  }
}
