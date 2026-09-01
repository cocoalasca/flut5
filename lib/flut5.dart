import 'dart:ui' as dart_ui;

import 'package:flutter/material.dart';

/////// Lib Flut5 ///////
import 'core/flut5_container.dart';
import 'core/flut5_cursor.dart';
import 'core/flut5_engine.dart';
import 'core/flut5_event.dart';
import 'core/flut5_touch.dart';
import 'core/flut5_wheel.dart';
import 'core/sketch_environment.dart';
import 'image/flut5_image.dart';
import 'shape/flut5_2d_primitives.dart';
import 'math/flut5_vector.dart';
import 'math/flut5_trigonometry.dart';
import 'math/flut5_noise.dart';
import 'core/render/flut5_render_queue.dart';
import 'shape/flut5_vertex.dart';
import 'text/flut5_font.dart';
import 'text/flut5_text.dart';
import 'text/flut5_text_grid.dart';
import 'ui/flut5_ui.dart';
import 'steering/flut5_steering.dart';

export 'core/flut5_color.dart';
export 'core/flut5_container.dart';
export 'core/flut5_cursor.dart';
export 'core/flut5_engine.dart';
export 'core/flut5_event.dart';
export 'core/flut5_touch.dart';
export 'core/flut5_wheel.dart';
export 'core/sketch_environment.dart';
export 'core/sketch_keyboard_event.dart';
export 'core/sketch_pointer_event.dart';
export 'core/sketch_scroll_event.dart';
export 'shape/flut5_stroke.dart';
export 'shape/flut5_fill.dart';
export 'shape/flut5_2d_primitives.dart';
export 'math/flut5_vector.dart';
export 'math/flut5_math.dart';
export 'math/flut5_trigonometry.dart';
export 'math/flut5_noise.dart';
export 'core/flut5_sketch.dart';
export 'core/flut5_canvas.dart';
export 'core/flut5_clip.dart';
export 'core/flut5_transform.dart';
export 'core/render/flut5_render_queue.dart';
export 'core/flut5_console.dart';
export 'core/flut5_update_tree.dart';
export 'image/flut5_image.dart';
export 'image/flut5_image_mixin.dart';
export 'ui/flut5_ui_element.dart';
export 'ui/flut5_button.dart';
export 'ui/flut5_label.dart';
export 'ui/flut5_container.dart';
export 'ui/flut5_slider.dart';
export 'ui/flut5_toggle.dart';
export 'ui/flut5_checkbox.dart';
export 'ui/flut5_ui.dart';
export 'shape/flut5_vertex.dart';
export 'steering/flut5_steering.dart';
export 'text/flut5_text.dart';
export 'text/flut5_text_cache.dart';
export 'text/flut5_font.dart';
export 'text/flut5_glyph.dart';
export 'text/flut5_text_grid.dart';

/// Base class meant to be extended by the user's Sketch class.
///
/// Provides access to the [Flut5Engine] through the [flut5] property.
/// It also mixes in [Flut5EventMixin] which sets up default gesture
/// and event handling out-of-the-box (e.g. pointer down events).
///
/// In *global mode* (the default, mirroring p5.js), a plain [Flut5]
/// subclass constructed without an explicit engine automatically adopts
/// [Flut5Engine.current] — the engine of the sketch currently running —
/// so helper classes don't need constructor injection:
///
/// ```dart
/// class Enemy extends Flut5 {
///   void render() => circle(x, y, 20); // draws on the parent sketch's engine
/// }
///
/// class MySketch extends Flut5Sketch {
///   late final enemy = Enemy(); // `late` — resolves during setup()/draw()
/// }
/// ```
///
/// Note the `late` keyword above: a non-`late` field initializer runs
/// *before* the sketch's engine exists, so eager helpers would fall back to
/// a standalone engine. Make helper fields `late`, or construct them inside
/// `setup()`.
///
/// In *instance mode* ([instanceMode] set to `true`, mirroring p5.js
/// instance mode — https://p5js.org/reference/p5/p5/), the shared engine is
/// never consulted and helpers must receive it explicitly:
///
/// ```dart
/// class Enemy extends Flut5 {
///   Enemy(Flut5Engine engine) : super(flut5: engine);
/// }
/// ```
abstract class Flut5 with Flut5EventMixin {
  /// Whether Flut5 runs in *instance mode* (mirrors p5.js instance mode,
  /// see https://p5js.org/reference/p5/p5/).
  ///
  /// `false` (default) — *global mode*: plain [Flut5] subclasses constructed
  /// without an explicit engine adopt [Flut5Engine.current], the engine of
  /// the sketch currently running `setup()`/`draw()`.
  ///
  /// `true` — *instance mode*: every plain [Flut5] subclass must receive its
  /// engine through the constructor (`super(flut5: engine)`); constructing
  /// one without an engine throws a [StateError]. Enable this when running
  /// multiple canvases whose helper objects are constructed outside
  /// `setup()`/`draw()` (timers, gesture callbacks, app state), where "the
  /// engine of whichever sketch painted last" would be ambiguous. Set it
  /// once, before constructing sketches (e.g. in `main()`).
  static bool instanceMode = false;

  /// The core rendering and state engine.
  late final Flut5Engine flut5;

  /// Whether this instance created its own engine (and is responsible for disposing it).
  late final bool _ownsEngine;

  Flut5({Flut5Engine? flut5, bool listenEvents = false}) {
    final resolved = flut5 ?? (instanceMode ? null : Flut5Engine.current);
    if (resolved == null && instanceMode) {
      throw StateError(
        'Flut5 is in instance mode (Flut5.instanceMode == true), so every '
        'Flut5 subclass must receive its engine through the constructor:\n'
        '  class Enemy extends Flut5 {\n'
        '    Enemy(Flut5Engine engine) : super(flut5: engine);\n'
        '  }\n'
        '  // construct with Enemy(flut5) from inside the parent sketch.\n'
        'Alternatively, leave instance mode off (the default) and helpers '
        "constructed during setup()/draw() adopt the running sketch's "
        'engine automatically.',
      );
    }
    _ownsEngine = resolved == null;
    this.flut5 = resolved ?? Flut5Engine();
    if (listenEvents) this.listenEvents(this.flut5);
  }

  /// Creates a *root* instance that always owns a fresh [Flut5Engine] and
  /// registers it as [Flut5Engine.current].
  ///
  /// Used by [Flut5Sketch]: root sketches never adopt a shared engine — each
  /// hosts its own — while plain [Flut5] helpers adopt the current one in
  /// global mode. [Flut5Canvas] then keeps [Flut5Engine.current] pointing at
  /// whichever sketch is running `setup()`/`draw()`.
  @protected
  Flut5.root({bool listenEvents = false}) {
    _ownsEngine = true;
    flut5 = Flut5Engine();
    Flut5Engine.current = flut5;
    if (listenEvents) this.listenEvents(flut5);
  }

  void dispose() {
    disposeEvents();
    if (_ownsEngine) {
      if (identical(Flut5Engine.current, flut5)) Flut5Engine.current = null;
      flut5.ui.clear();
      flut5.ui.dispose();
      flut5.events.dispose();
      flut5.clearFrameSnapshot();
      flut5.disposeCursor();
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  Engine forwarders — let users write `ellipse(...)` instead of
  //  `flut5.ellipse(...)`. Each method below is a one-line redirect to the
  //  same method on the engine instance, so both styles share state.
  //
  //  When you add a new public method or field to Flut5Engine (or any of its
  //  mixins), add a matching forwarder here.
  // ════════════════════════════════════════════════════════════════════════

  // ── Environment & dimensions ─────────────────────────────────────────────
  Canvas get canvas => flut5.canvas;
  set canvas(Canvas c) => flut5.canvas = c;
  Size get size => flut5.size;
  double get width => flut5.width;
  double get height => flut5.height;
  Size get canvasSize => flut5.canvasSize;
  SketchEnvironment get environment => flut5.environment;
  set environment(SketchEnvironment e) => flut5.environment = e;
  double get mouseX => flut5.mouseX;
  double get mouseY => flut5.mouseY;
  double get pmouseX => flut5.pmouseX;
  double get pmouseY => flut5.pmouseY;
  double get avgMouseX => flut5.avgMouseX;
  double get avgMouseY => flut5.avgMouseY;
  Flut5Vector get avgMouse => flut5.avgMouse;
  int get avgMouseFrames => flut5.avgMouseFrames;
  void setAvgMouseFrames(int frames) => flut5.setAvgMouseFrames(frames);
  String get key => flut5.key;
  int get keyCode => flut5.keyCode;
  List<Flut5Touch> get touches => flut5.touches;
  bool get pointerIsDown => flut5.pointerIsDown;
  Flut5WheelSample? get wheel => flut5.wheel;
  List<Flut5FramePointerEvent> get pendingPointerEvents =>
      flut5.pendingPointerEvents;
  int get frameCount => flut5.frameCount;
  double get deltaTime => flut5.deltaTime;
  double frameRate([double? fps]) => flut5.frameRate(fps);
  double? get frameRateCap => flut5.frameRateCap;
  set frameRateCap(double? v) => flut5.frameRateCap = v;
  dart_ui.Image? get frameSnapshot => flut5.frameSnapshot;
  Size? get frameSnapshotLogicalSize => flut5.frameSnapshotLogicalSize;
  void clearFrameSnapshot() => flut5.clearFrameSnapshot();
  bool get preserveSnapshotOnResize => flut5.preserveSnapshotOnResize;
  set preserveSnapshotOnResize(bool v) => flut5.preserveSnapshotOnResize = v;
  int? get frameSnapshotMaxResolution => flut5.frameSnapshotMaxResolution;
  set frameSnapshotMaxResolution(int? v) =>
      flut5.frameSnapshotMaxResolution = v;
  void setFrameSnapshotMaxResolution(int? size) =>
      flut5.setFrameSnapshotMaxResolution(size);
  double get frameSnapshotResolutionFactor =>
      flut5.frameSnapshotResolutionFactor;
  set frameSnapshotResolutionFactor(double v) =>
      flut5.frameSnapshotResolutionFactor = v;
  void setFrameSnapshotResolutionFactor(double factor) =>
      flut5.setFrameSnapshotResolutionFactor(factor);
  double snapshotResolutionFactor([double? factor]) =>
      flut5.snapshotResolutionFactor(factor);
  double get frameSnapshotResolutionFactorDebug =>
      flut5.frameSnapshotResolutionFactorDebug;
  set frameSnapshotResolutionFactorDebug(double v) =>
      flut5.frameSnapshotResolutionFactorDebug = v;
  void setFrameSnapshotResolutionFactorDebug(double factor) =>
      flut5.setFrameSnapshotResolutionFactorDebug(factor);
  double snapshotResolutionFactorDebug([double? factor]) =>
      flut5.snapshotResolutionFactorDebug(factor);
  double get frameSnapshotResolutionFactorProd =>
      flut5.frameSnapshotResolutionFactorProd;
  set frameSnapshotResolutionFactorProd(double v) =>
      flut5.frameSnapshotResolutionFactorProd = v;
  void setFrameSnapshotResolutionFactorProd(double factor) =>
      flut5.setFrameSnapshotResolutionFactorProd(factor);
  double snapshotResolutionFactorProd([double? factor]) =>
      flut5.snapshotResolutionFactorProd(factor);
  bool get frameSnapshotResolutionFactorIsExplicit =>
      flut5.frameSnapshotResolutionFactorIsExplicit;
  void clearFrameSnapshotResolutionFactor() =>
      flut5.clearFrameSnapshotResolutionFactor();
  double get frameSnapshotResolutionFactorMax =>
      flut5.frameSnapshotResolutionFactorMax;
  set frameSnapshotResolutionFactorMax(double v) =>
      flut5.frameSnapshotResolutionFactorMax = v;
  void setFrameSnapshotResolutionFactorMax(double factor) =>
      flut5.setFrameSnapshotResolutionFactorMax(factor);
  double snapshotResolutionFactorMax([double? factor]) =>
      flut5.snapshotResolutionFactorMax(factor);
  double get frameSnapshotCalibratedFactor =>
      flut5.frameSnapshotCalibratedFactor;
  bool get frameSnapshotCalibrating => flut5.frameSnapshotCalibrating;
  String? get frameSnapshotCalibrationOutcome =>
      flut5.frameSnapshotCalibrationOutcome;
  void resetSnapshotCalibration() => flut5.resetSnapshotCalibration();
  double get effectiveFrameSnapshotResolutionFactor =>
      flut5.effectiveFrameSnapshotResolutionFactor;
  String? get frameSnapshotCapBinding => flut5.frameSnapshotCapBinding;
  int? get frameSnapshotMaxPixels => flut5.frameSnapshotMaxPixels;
  set frameSnapshotMaxPixels(int? v) => flut5.frameSnapshotMaxPixels = v;
  void setFrameSnapshotMaxPixels(int? pixels) =>
      flut5.setFrameSnapshotMaxPixels(pixels);
  int? snapshotMaxPixels([int? pixels]) => flut5.snapshotMaxPixels(pixels);
  bool get adaptiveSnapshotFilterQuality =>
      flut5.adaptiveSnapshotFilterQuality;
  set adaptiveSnapshotFilterQuality(bool v) =>
      flut5.adaptiveSnapshotFilterQuality = v;
  int get frameSnapshotMinResolution => flut5.frameSnapshotMinResolution;
  set frameSnapshotMinResolution(int v) =>
      flut5.frameSnapshotMinResolution = v;
  void setFrameSnapshotMinResolution(int size) =>
      flut5.setFrameSnapshotMinResolution(size);
  double get frameSnapshotResolutionScale =>
      flut5.frameSnapshotResolutionScale;
  FilterQuality get frameSnapshotFilterQuality =>
      flut5.frameSnapshotFilterQuality;
  set frameSnapshotFilterQuality(FilterQuality v) =>
      flut5.frameSnapshotFilterQuality = v;
  FilterQuality snapshotFilterQuality([FilterQuality? quality]) =>
      flut5.snapshotFilterQuality(quality);
  int get frameSnapshotInterval => flut5.frameSnapshotInterval;
  set frameSnapshotInterval(int v) => flut5.frameSnapshotInterval = v;
  int snapshotInterval([int? interval]) => flut5.snapshotInterval(interval);
  bool get showFrameSnapshotDebug => flut5.showFrameSnapshotDebug;
  set showFrameSnapshotDebug(bool v) => flut5.showFrameSnapshotDebug = v;
  void showSnapshotPerformanceInfo([bool enabled = true]) =>
      flut5.showSnapshotPerformanceInfo(enabled);
  void noSnapshotPerformanceInfo() => flut5.noSnapshotPerformanceInfo();
  bool get useLayeredTrails => flut5.useLayeredTrails;
  set useLayeredTrails(bool v) => flut5.useLayeredTrails = v;
  bool get smoothTrailFade => flut5.smoothTrailFade;
  set smoothTrailFade(bool v) => flut5.smoothTrailFade = v;
  int get framesSinceSnapshotApplied => flut5.framesSinceSnapshotApplied;
  bool get useSyncSnapshotCapture => flut5.useSyncSnapshotCapture;
  set useSyncSnapshotCapture(bool v) => flut5.useSyncSnapshotCapture = v;
  Listenable get trailRepaint => flut5.trailRepaint;
  bool get adaptiveSnapshotThrottle => flut5.adaptiveSnapshotThrottle;
  set adaptiveSnapshotThrottle(bool v) => flut5.adaptiveSnapshotThrottle = v;
  bool snapshotAdaptiveQuality([bool? enabled]) =>
      flut5.snapshotAdaptiveQuality(enabled);
  double get frameSnapshotBudgetMs => flut5.frameSnapshotBudgetMs;
  set frameSnapshotBudgetMs(double v) => flut5.frameSnapshotBudgetMs = v;
  double snapshotMsBudget([double? ms]) => flut5.snapshotMsBudget(ms);
  int get frameSnapshotMaxInterval => flut5.frameSnapshotMaxInterval;
  set frameSnapshotMaxInterval(int v) => flut5.frameSnapshotMaxInterval = v;
  int get effectiveFrameSnapshotInterval =>
      flut5.effectiveFrameSnapshotInterval;
  int get frameSnapshotDroppedCount => flut5.frameSnapshotDroppedCount;
  double? get frameSnapshotLastCaptureMs => flut5.frameSnapshotLastCaptureMs;
  double? get frameSnapshotCostEmaMs => flut5.frameSnapshotCostEmaMs;
  double? get frameSnapshotRasterLoad => flut5.frameSnapshotRasterLoad;
  double? get smoothedFrameRate => flut5.smoothedFrameRate;
  double? get smoothedFrameTimeMs => flut5.smoothedFrameTimeMs;
  (int, int)? get frameSnapshotLastPhysicalSize =>
      flut5.frameSnapshotLastPhysicalSize;

  // ── Subsystems ───────────────────────────────────────────────────────────
  Flut5Event get events => flut5.events;
  Flut5UI get ui => flut5.ui;
  Flut5RenderQueue get renderQueue => flut5.renderQueue;

  // ── Cursor ───────────────────────────────────────────────────────────────
  MouseCursor get currentCursor => flut5.currentCursor;
  void cursor([Object type = Flut5CursorType.arrow]) => flut5.cursor(type);
  void noCursor() => flut5.noCursor();

  // ── Batching ─────────────────────────────────────────────────────────────
  Path? get batchPath => flut5.batchPath;
  set batchPath(Path? p) => flut5.batchPath = p;
  List<double>? get batchPoints => flut5.batchPoints;
  set batchPoints(List<double>? l) => flut5.batchPoints = l;
  void markBatchDirty() => flut5.markBatchDirty();
  void beginBatch() => flut5.beginBatch();
  void endBatch() => flut5.endBatch();

  // ── 2D primitives ────────────────────────────────────────────────────────
  void ellipse(double x, double y, double width, double height) =>
      flut5.ellipse(x, y, width, height);
  void circle(double x, double y, double d) => flut5.circle(x, y, d);
  void point(double x, double y) => flut5.point(x, y);
  void line(double x1, double y1, double x2, double y2) =>
      flut5.line(x1, y1, x2, y2);
  void rect(
    double x,
    double y,
    double w,
    double h, [
    double? tl,
    double? tr,
    double? br,
    double? bl,
  ]) => flut5.rect(x, y, w, h, tl, tr, br, bl);
  void square(
    double x,
    double y,
    double s, [
    double? tl,
    double? tr,
    double? br,
    double? bl,
  ]) => flut5.square(x, y, s, tl, tr, br, bl);
  void triangle(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) => flut5.triangle(x1, y1, x2, y2, x3, y3);
  void quad(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    double x4,
    double y4,
  ) => flut5.quad(x1, y1, x2, y2, x3, y3, x4, y4);
  void polygon(double x, double y, int sides, double d) =>
      flut5.polygon(x, y, sides, d);
  void star(
    double x,
    double y,
    double innerDiameter,
    double outerDiameter,
    int points,
  ) => flut5.star(x, y, innerDiameter, outerDiameter, points);
  void arc(
    double x,
    double y,
    double w,
    double h,
    double start,
    double stop, [
    ArcMode mode = .open,
  ]) => flut5.arc(x, y, w, h, start, stop, mode);

  // ── Fill ─────────────────────────────────────────────────────────────────
  Color get fillColor => flut5.fillColor;
  set fillColor(Color c) => flut5.fillColor = c;
  Gradient? get fillGradient => flut5.fillGradient;
  set fillGradient(Gradient? g) => flut5.fillGradient = g;
  int get fillVersion => flut5.fillVersion;
  void fill(Object input, [double? x, double? y, double? w, double? h]) =>
      flut5.fill(input, x, y, w, h);
  void noFill() => flut5.noFill();
  Paint getFillPaint() => flut5.getFillPaint();
  Paint? snapshotFillPaint() => flut5.snapshotFillPaint();
  Paint? snapshotFillPaintNoShader() => flut5.snapshotFillPaintNoShader();
  void background(Object input, [double? x, double? y, double? w, double? h]) =>
      flut5.background(input, x, y, w, h);

  // ── Stroke ───────────────────────────────────────────────────────────────
  Color get strokeColor => flut5.strokeColor;
  set strokeColor(Color c) => flut5.strokeColor = c;
  double get strokeWeightVal => flut5.strokeWeightVal;
  set strokeWeightVal(double v) => flut5.strokeWeightVal = v;
  Gradient? get strokeGradient => flut5.strokeGradient;
  set strokeGradient(Gradient? g) => flut5.strokeGradient = g;
  int get strokeVersion => flut5.strokeVersion;
  void stroke(Object input, [double? x, double? y, double? w, double? h]) =>
      flut5.stroke(input, x, y, w, h);
  void noStroke() => flut5.noStroke();
  void strokeWeight(double weight) => flut5.strokeWeight(weight);
  void strokeCap(StrokeCap cap) => flut5.strokeCap(cap);
  void strokeJoin(StrokeJoin join) => flut5.strokeJoin(join);
  List<double>? get lineDashVal => flut5.lineDashVal;
  double get lineDashOffsetVal => flut5.lineDashOffsetVal;
  void setLineDash(List<double> pattern, [double offset = 0.0]) =>
      flut5.setLineDash(pattern, offset);
  void noLineDash() => flut5.noLineDash();
  Paint getStrokePaint() => flut5.getStrokePaint();
  Paint getStrokeFillPaint() => flut5.getStrokeFillPaint();
  Paint? snapshotStrokePaint() => flut5.snapshotStrokePaint();
  Paint? snapshotStrokePaintNoShader() => flut5.snapshotStrokePaintNoShader();
  Paint? snapshotPointPaint() => flut5.snapshotPointPaint();

  // ── Shadow ───────────────────────────────────────────────────────────────
  void shadow(
    double offsetX,
    double offsetY,
    double blur, [
    Object? spreadOrColor,
    Color? color,
  ]) => flut5.shadow(offsetX, offsetY, blur, spreadOrColor, color);
  void shadowFill(Color color) => flut5.shadowFill(color);
  void noShadow() => flut5.noShadow();

  // ── Vertex API ───────────────────────────────────────────────────────────
  void beginShape([ShapeMode mode = .polygon]) =>
      flut5.beginShape(mode);
  void vertex(double x, double y) => flut5.vertex(x, y);
  void bezierVertex(
    double x2,
    double y2,
    double x3,
    double y3,
    double x4,
    double y4,
  ) => flut5.bezierVertex(x2, y2, x3, y3, x4, y4);
  void quadraticVertex(double cx, double cy, double x3, double y3) =>
      flut5.quadraticVertex(cx, cy, x3, y3);
  void curveVertex(double x, double y) => flut5.curveVertex(x, y);
  void beginContour() => flut5.beginContour();
  void endContour() => flut5.endContour();
  void endShape({bool close = false}) => flut5.endShape(close: close);

  // ── Math & color ─────────────────────────────────────────────────────────
  double map(
    double value,
    double start1,
    double stop1,
    double start2,
    double stop2,
  ) => flut5.map(value, start1, stop1, start2, stop2);
  double lerp(double start, double stop, double amt) =>
      flut5.lerp(start, stop, amt);
  double random([num? min, num? max]) => flut5.random(min, max);
  T randomChoice<T>(List<T> items) => flut5.randomChoice(items);
  double randomGaussian([double mean = 0.0, double sd = 1.0]) =>
      flut5.randomGaussian(mean, sd);
  void randomSeed(int seed) => flut5.randomSeed(seed);
  void resetRandom() => flut5.resetRandom();
  Color lerpColor(Color c1, Color c2, double amt) =>
      flut5.lerpColor(c1, c2, amt);
  BlendMode get currentBlendMode => flut5.currentBlendMode;
  int get blendVersion => flut5.blendVersion;
  void blendMode(BlendMode mode) => flut5.blendMode(mode);

  // ── Trigonometry ─────────────────────────────────────────────────────────
  AngleMode get angleMode => flut5.angleMode;
  set angleMode(AngleMode m) => flut5.angleMode = m;
  double acos(double ratio) => flut5.acos(ratio);
  double asin(double ratio) => flut5.asin(ratio);
  double atan(double ratio) => flut5.atan(ratio);
  double atan2(double y, double x) => flut5.atan2(y, x);
  double cos(double angle) => flut5.cos(angle);
  double sin(double angle) => flut5.sin(angle);
  double tan(double angle) => flut5.tan(angle);
  double degrees(double radians) => flut5.degrees(radians);
  double radians(double degrees) => flut5.radians(degrees);
  double toRadians(double angle) => flut5.toRadians(angle);

  // ── Noise ────────────────────────────────────────────────────────────────
  NoiseMode get noiseMode => flut5.noiseMode;
  set noiseMode(NoiseMode m) => flut5.noiseMode = m;
  double noise(double x, [double y = 0.0, double z = 0.0]) =>
      flut5.noise(x, y, z);
  void noiseDetail(int lod, [double? falloff]) =>
      flut5.noiseDetail(lod, falloff);
  void noiseSeed(int seed) => flut5.noiseSeed(seed);
  void resetNoise() => flut5.resetNoise();

  // ── Vector ───────────────────────────────────────────────────────────────
  Flut5Vector createVector([double x = 0.0, double y = 0.0, double z = 0.0]) =>
      flut5.createVector(x, y, z);

  // ── Transform ────────────────────────────────────────────────────────────
  void push() => flut5.push();
  void pop() => flut5.pop();
  void translate(double x, double y, [double z = 0]) =>
      flut5.translate(x, y, z);
  void rotate(double angle) => flut5.rotate(angle);
  void rotateX(double angle) => flut5.rotateX(angle);
  void rotateY(double angle) => flut5.rotateY(angle);
  void rotateZ(double angle) => flut5.rotateZ(angle);
  void scale(double x, [double? y]) => flut5.scale(x, y);
  void shearX(double angle) => flut5.shearX(angle);
  void shearY(double angle) => flut5.shearY(angle);
  void applyMatrix(List<double> matrix4x4) => flut5.applyMatrix(matrix4x4);
  void resetMatrix() => flut5.resetMatrix();

  // ── Clip ─────────────────────────────────────────────────────────────────
  void clip(
    void Function() callback, {
    bool invert = false,
    bool antiAlias = true,
  }) => flut5.clip(callback, invert: invert, antiAlias: antiAlias);
  void clipPath(Object source, {bool invert = false, bool antiAlias = true}) =>
      flut5.clipPath(source, invert: invert, antiAlias: antiAlias);
  void clipRect(
    double x,
    double y,
    double w,
    double h, {
    double? radius,
    bool invert = false,
    bool antiAlias = true,
  }) => flut5.clipRect(
    x,
    y,
    w,
    h,
    radius: radius,
    invert: invert,
    antiAlias: antiAlias,
  );

  // ── Container ────────────────────────────────────────────────────────────
  void beginContainer(
    double xOrW,
    double yOrH, [
    Object? wOrArgs,
    double? h,
    Map<String, dynamic>? args,
  ]) => flut5.beginContainer(xOrW, yOrH, wOrArgs, h, args);
  void endContainer() => flut5.endContainer();
  Flut5ContainerContext? get containerContext => flut5.containerContext;
  Flut5ContainerContext? getContainerContext() => flut5.getContainerContext();
  Flut5ContainerOverflow get currentContainerOverflow =>
      flut5.currentContainerOverflow;
  void containerOverflow(Flut5ContainerOverflow mode) =>
      flut5.containerOverflow(mode);
  double get currentContainerScrollInertia =>
      flut5.currentContainerScrollInertia;
  void containerScrollInertia(double value) =>
      flut5.containerScrollInertia(value);
  Flut5ContainerOverscroll get currentContainerOverscrollMode =>
      flut5.currentContainerOverscrollMode;
  void containerOverscrollMode(Flut5ContainerOverscroll mode) =>
      flut5.containerOverscrollMode(mode);
  double get currentContainerOverscrollBounce =>
      flut5.currentContainerOverscrollBounce;
  void containerOverscrollBounce(double value) =>
      flut5.containerOverscrollBounce(value);
  Flut5ContainerOverscrollInput get currentContainerOverscrollInput =>
      flut5.currentContainerOverscrollInput;
  void containerOverscrollInput(Flut5ContainerOverscrollInput mode) =>
      flut5.containerOverscrollInput(mode);
  void containerScrollSensitivity(double multiplier, [double? wheelMultiplier]) =>
      flut5.containerScrollSensitivity(multiplier, wheelMultiplier);
  double get currentContainerPointerDragSensitivity =>
      flut5.currentContainerPointerDragSensitivity;
  void containerPointerDragSensitivity(double value) =>
      flut5.containerPointerDragSensitivity(value);
  double get currentContainerWheelSensitivity =>
      flut5.currentContainerWheelSensitivity;
  void containerWheelSensitivity(double value) =>
      flut5.containerWheelSensitivity(value);
  void resetContainerScroll([String? id]) => flut5.resetContainerScroll(id);

  // ── Layout ───────────────────────────────────────────────────────────────
  void beginLayout([double x = 0, double y = 0, double? w, double? h]) =>
      flut5.beginLayout(x, y, w, h);
  void endLayout() => flut5.endLayout();
  Flut5LayoutDirection get currentLayoutDirection =>
      flut5.currentLayoutDirection;
  void layoutDirection(Flut5LayoutDirection direction) =>
      flut5.layoutDirection(direction);
  double get currentLayoutGap => flut5.currentLayoutGap;
  double get currentLayoutCrossGap => flut5.currentLayoutCrossGap;
  void layoutGap(double gap, [double? crossGap]) =>
      flut5.layoutGap(gap, crossGap);
  Flut5LayoutWrap get currentLayoutWrap => flut5.currentLayoutWrap;
  void layoutWrap(Flut5LayoutWrap mode) => flut5.layoutWrap(mode);
  EdgeInsets get currentLayoutPadding => flut5.currentLayoutPadding;
  void layoutPadding(EdgeInsets padding) => flut5.layoutPadding(padding);
  Flut5LayoutAlign get currentLayoutAlignItems =>
      flut5.currentLayoutAlignItems;
  void layoutAlignItems(Flut5LayoutAlign align) =>
      flut5.layoutAlignItems(align);
  Flut5LayoutJustify get currentLayoutJustifyContent =>
      flut5.currentLayoutJustifyContent;
  void layoutJustifyContent(Flut5LayoutJustify justify) =>
      flut5.layoutJustifyContent(justify);

  // ── Text ─────────────────────────────────────────────────────────────────
  void textFont(Object font) => flut5.textFont(font);
  double textWeight([Object? weight]) => flut5.textWeight(weight);
  void textStyle(FontStyle style) => flut5.textStyle(style);
  void fontAxis(String tag, double value) => flut5.fontAxis(tag, value);
  void fontInstance(String name) => flut5.fontInstance(name);
  void clearFontAxes() => flut5.clearFontAxes();
  Map<String, double> get fontAxes => flut5.fontAxes;
  Map<String, Flut5FontData> get fonts => flut5.fonts;
  void textSize(double size) => flut5.textSize(size);
  void textAlign(TextAlign align) => flut5.textAlign(align);
  void textLeading(double leading) => flut5.textLeading(leading);
  void letterSpacing(double? spacing) => flut5.letterSpacing(spacing);
  void textCacheMode(TextCacheMode mode) => flut5.textCacheMode(mode);
  FilterQuality textFilterQuality([FilterQuality? quality]) =>
      flut5.textFilterQuality(quality);
  int get textCacheMaxSize => flut5.textCacheMaxSize;
  set textCacheMaxSize(int value) => flut5.textCacheMaxSize = value;
  bool get textCacheAutoGrow => flut5.textCacheAutoGrow;
  set textCacheAutoGrow(bool value) => flut5.textCacheAutoGrow = value;
  int get textCacheMaxBytes => flut5.textCacheMaxBytes;
  set textCacheMaxBytes(int value) => flut5.textCacheMaxBytes = value;
  int get textCacheGrowthLimit => flut5.textCacheGrowthLimit;
  set textCacheGrowthLimit(int value) => flut5.textCacheGrowthLimit = value;
  int get textCacheBytes => flut5.textCacheBytes;
  int get textCacheLength => flut5.textCacheLength;
  int get textLayoutCacheMaxSize => flut5.textLayoutCacheMaxSize;
  set textLayoutCacheMaxSize(int value) =>
      flut5.textLayoutCacheMaxSize = value;
  int get textLayoutCacheGrowthLimit => flut5.textLayoutCacheGrowthLimit;
  set textLayoutCacheGrowthLimit(int value) =>
      flut5.textLayoutCacheGrowthLimit = value;
  int get textLayoutCacheLength => flut5.textLayoutCacheLength;
  void clearTextCache() => flut5.clearTextCache();
  void text(
    String content,
    double x,
    double y, [
    double? maxWidth,
    double? maxHeight,
  ]) => flut5.text(content, x, y, maxWidth, maxHeight);
  void textDynamic(
    String content,
    double x,
    double y, [
    double? maxWidth,
    double? maxHeight,
  ]) => flut5.textDynamic(content, x, y, maxWidth, maxHeight);
  void textStatic(
    String content,
    double x,
    double y, [
    double? maxWidth,
    double? maxHeight,
  ]) => flut5.textStatic(content, x, y, maxWidth, maxHeight);
  Future<Flut5Font> loadFontShapeData(dynamic source) =>
      flut5.loadFontShapeData(source);
  Future<Flut5Font> loadFont(dynamic source) => flut5.loadFont(source);
  List<PathCommand> textToPaths(
    String content,
    double x,
    double y, {
    Map<String, dynamic>? args,
  }) => flut5.textToPaths(content, x, y, args: args);
  List<Flut5Vector> textToPoints(
    String content,
    double x,
    double y, {
    Map<String, dynamic>? args,
  }) => flut5.textToPoints(content, x, y, args: args);
  List<List<Flut5Vector>> textToContours(
    String content,
    double x,
    double y, {
    Map<String, dynamic>? args,
  }) => flut5.textToContours(content, x, y, args: args);
  Flut5TextGrid textToGrid(
    String content,
    double x,
    double y, {
    Map<String, dynamic>? args,
  }) => flut5.textToGrid(content, x, y, args: args);
  double textWidth(String content) => flut5.textWidth(content);
  double textAscent() => flut5.textAscent();
  double textDescent() => flut5.textDescent();

  // ── Image ────────────────────────────────────────────────────────────────
  Future<Flut5Image> loadImage(dynamic source) => flut5.loadImage(source);
  void image(
    Flut5Image img,
    double x,
    double y, [
    double? width,
    double? height,
    double? sx,
    double? sy,
    double? sWidth,
    double? sHeight,
  ]) => flut5.image(img, x, y, width, height, sx, sy, sWidth, sHeight);

  // ── Steering (global) ────────────────────────────────────────────────────
  //  These forward to the process-wide statics on [Flut5Steering] (not the
  //  engine), so sketches can flip the global steering return mode unprefixed.
  void steeringTurboMode(bool turbo) => Flut5Steering.steeringTurboMode(turbo);
  void steeringReturnMode(SteeringReturnMode mode) =>
      Flut5Steering.steeringReturnMode(mode);
  void resetSteeringMode() => Flut5Steering.resetSteeringMode();
}
