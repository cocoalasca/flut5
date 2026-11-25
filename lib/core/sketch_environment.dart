import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../math/flut5_vector.dart';
import '../text/flut5_font.dart';

/// Per-sketch runtime environment state.
///
/// Holds canvas dimensions and frame timing data that change as the sketch is
/// rendered.
@immutable
final class const SketchEnvironment._({
  required final Size size,
  required final double mouseX,
  required final double mouseY,
  required final double pmouseX,
  required final double pmouseY,
  required final String key,
  required final int keyCode,
  required final int frameCount,
  required final double deltaTime,

  /// Font shape data preloaded from Flutter's generated `FontManifest.json`,
  /// keyed by pubspec/manifest family name.
  required final Map<String, Flut5FontData> fonts,

  /// Flexible props map passed from the parent widget via `Flut5Canvas.props`.
  required final Map<String, dynamic> props,
  required final int _lastFrameMs,

  /// Number of frames used to compute [avgMouseX], [avgMouseY] and [avgMouse].
  /// Defaults to 15 frames (~250 ms at 60 fps).
  required final int avgMouseFrames,

  /// Average mouse velocity x-component (px / frame) over the last
  /// [avgMouseFrames] rendered frames. 0 before the first frame samples.
  required final double avgMouseX,

  /// Average mouse velocity y-component (px / frame) over the last
  /// [avgMouseFrames] rendered frames. 0 before the first frame samples.
  required final double avgMouseY,

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
  required final Float64List? _vxSamples,
  required final Float64List? _vySamples,

  /// Next ring-buffer slot [nextFrame] writes to. While the buffer isn't full
  /// yet, valid samples occupy indices `0 .. _sampleCount - 1`.
  required final int _sampleHead,

  /// Number of valid samples in the ring buffers (≤ buffer length).
  required final int _sampleCount,
}) {
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
        props: const <String, dynamic>{},
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
    if (size == this.size) return this;
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
      props: props,
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
    if (mouseX == this.mouseX &&
        mouseY == this.mouseY &&
        pmouseX == this.pmouseX &&
        pmouseY == this.pmouseY) {
      return this;
    }
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
      props: props,
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
    if (key == this.key && keyCode == this.keyCode) return this;
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
      props: props,
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
      props: props,
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
      props: props,
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
      props: props,
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

  /// Returns an updated environment with a new [props] map.
  SketchEnvironment withProps(Map<String, dynamic> props) {
    if (mapEquals(props, this.props)) return this;
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
      props: Map.unmodifiable(props),
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

/// Package-internal mutable host for [SketchEnvironment] fields.
///
/// [Flut5Engine] mutates these scalar fields and ring buffers in place on every
/// pointer move (120–1000 Hz), keyboard event, canvas resize, and frame tick
/// without allocating a new [SketchEnvironment] wrapper. An immutable
/// [SketchEnvironment] snapshot is materialized lazily only when callers read
/// `engine.environment`, and assigning `engine.environment = ...` synchronizes
/// all fields back via [loadFrom].
final class Flut5EnvironmentState() {
  Size size = Size.zero;
  double mouseX = 0;
  double mouseY = 0;
  double pmouseX = 0;
  double pmouseY = 0;
  String key = '';
  int keyCode = 0;
  int frameCount = 0;
  double deltaTime = 0;
  Map<String, Flut5FontData> fonts = const <String, Flut5FontData>{};
  Map<String, dynamic> props = const <String, dynamic>{};
  int _lastFrameMs = 0;
  int avgMouseFrames = 15;
  double avgMouseX = 0;
  double avgMouseY = 0;
  Float64List? _vxSamples;
  Float64List? _vySamples;
  int _sampleHead = 0;
  int _sampleCount = 0;

  SketchEnvironment? _cachedSnapshot = const SketchEnvironment();

  double get width => size.width;
  double get height => size.height;
  Flut5Vector get avgMouse => Flut5Vector(avgMouseX, avgMouseY);
  double frameRate() => deltaTime > 0 ? 1000 / deltaTime : 0;

  /// Whether an immutable [SketchEnvironment] snapshot is currently cached.
  bool get hasCachedSnapshot => _cachedSnapshot != null;

  /// Updates [size] in place. Returns `true` if the size actually changed.
  bool setSize(Size newSize) {
    if (size == newSize) return false;
    size = newSize;
    _cachedSnapshot = null;
    return true;
  }

  /// Updates mouse coordinates in place without allocating.
  void setMousePosition({
    required double mouseX,
    required double mouseY,
    required double pmouseX,
    required double pmouseY,
  }) {
    if (this.mouseX == mouseX &&
        this.mouseY == mouseY &&
        this.pmouseX == pmouseX &&
        this.pmouseY == pmouseY) {
      return;
    }
    this.mouseX = mouseX;
    this.mouseY = mouseY;
    this.pmouseX = pmouseX;
    this.pmouseY = pmouseY;
    _cachedSnapshot = null;
  }

  /// Updates keyboard state in place without allocating.
  void setKeyboard({required String key, required int keyCode}) {
    if (this.key == key && this.keyCode == keyCode) return;
    this.key = key;
    this.keyCode = keyCode;
    _cachedSnapshot = null;
  }

  /// Resizes the rolling average mouse velocity window in place.
  void setAvgMouseFrames(int frames) {
    if (frames < 1) {
      throw ArgumentError.value(frames, 'frames', 'must be >= 1');
    }
    var vx = _vxSamples;
    var vy = _vySamples;
    var head = _sampleHead;
    var count = _sampleCount;
    if (vx != null && vy != null && vx.length != frames) {
      final resized = SketchEnvironment._resizeRing(vx, vy, head, count, frames);
      vx = resized.$1;
      vy = resized.$2;
      head = resized.$3;
      count = resized.$4;
      _vxSamples = vx;
      _vySamples = vy;
      _sampleHead = head;
      _sampleCount = count;
    }
    avgMouseFrames = frames;
    if (vx == null || vy == null || count == 0) {
      avgMouseX = 0.0;
      avgMouseY = 0.0;
    } else {
      double sumX = 0;
      double sumY = 0;
      for (int i = 0; i < count; i++) {
        sumX += vx[i];
        sumY += vy[i];
      }
      avgMouseX = sumX / count;
      avgMouseY = sumY / count;
    }
    _cachedSnapshot = null;
  }

  /// Advances frame timing and updates the rolling velocity ring buffer in
  /// place without allocating per frame.
  void nextFrame(int nowMs) {
    deltaTime = _lastFrameMs == 0 ? 0.0 : (nowMs - _lastFrameMs).toDouble();
    var vx = _vxSamples;
    var vy = _vySamples;
    var head = _sampleHead;
    var count = _sampleCount;
    if (vx == null || vy == null || vx.length != avgMouseFrames) {
      final resized = SketchEnvironment._resizeRing(
        vx,
        vy,
        head,
        count,
        avgMouseFrames,
      );
      vx = resized.$1;
      vy = resized.$2;
      head = resized.$3;
      count = resized.$4;
      _vxSamples = vx;
      _vySamples = vy;
    }
    vx[head] = mouseX - pmouseX;
    vy[head] = mouseY - pmouseY;
    head = head + 1 == vx.length ? 0 : head + 1;
    if (count < vx.length) count++;
    _sampleHead = head;
    _sampleCount = count;
    double sumX = 0;
    double sumY = 0;
    for (int i = 0; i < count; i++) {
      sumX += vx[i];
      sumY += vy[i];
    }
    avgMouseX = count == 0 ? 0.0 : sumX / count;
    avgMouseY = count == 0 ? 0.0 : sumY / count;
    frameCount++;
    _lastFrameMs = nowMs;
    _cachedSnapshot = null;
  }

  /// Replaces the preloaded font shape map in place.
  void setFonts(Map<String, Flut5FontData> newFonts) {
    fonts = Map.unmodifiable(newFonts);
    _cachedSnapshot = null;
  }

  /// Replaces the props map in place. Returns `true` if the map differed by
  /// value ([mapEquals]).
  bool setProps(Map<String, dynamic> newProps) {
    if (mapEquals(props, newProps)) return false;
    props = Map.unmodifiable(newProps);
    _cachedSnapshot = null;
    return true;
  }

  /// Lazily materializes and caches an immutable [SketchEnvironment] snapshot.
  SketchEnvironment get snapshot => _cachedSnapshot ??= SketchEnvironment._(
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
    props: props,
    lastFrameMs: _lastFrameMs,
    avgMouseFrames: avgMouseFrames,
    avgMouseX: avgMouseX,
    avgMouseY: avgMouseY,
    vxSamples: _vxSamples,
    vySamples: _vySamples,
    sampleHead: _sampleHead,
    sampleCount: _sampleCount,
  );

  /// Synchronizes all mutable state from an externally assigned
  /// [SketchEnvironment].
  void loadFrom(SketchEnvironment env) {
    size = env.size;
    mouseX = env.mouseX;
    mouseY = env.mouseY;
    pmouseX = env.pmouseX;
    pmouseY = env.pmouseY;
    key = env.key;
    keyCode = env.keyCode;
    frameCount = env.frameCount;
    deltaTime = env.deltaTime;
    fonts = env.fonts;
    props = env.props;
    _lastFrameMs = env._lastFrameMs;
    avgMouseFrames = env.avgMouseFrames;
    avgMouseX = env.avgMouseX;
    avgMouseY = env.avgMouseY;
    _vxSamples = env._vxSamples;
    _vySamples = env._vySamples;
    _sampleHead = env._sampleHead;
    _sampleCount = env._sampleCount;
    _cachedSnapshot = env;
  }
}
