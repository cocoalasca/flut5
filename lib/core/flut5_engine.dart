import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as dart_ui;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWasm, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../image/flut5_image_mixin.dart';
import '../math/flut5_math.dart';
import '../math/flut5_noise.dart';
import '../math/flut5_trigonometry.dart';
import '../math/flut5_vector.dart';
import '../physics/flut5_spring.dart';
import '../shape/flut5_2d_primitives.dart';
import '../shape/flut5_fill.dart';
import '../shape/flut5_stroke.dart';
import '../shape/flut5_vertex.dart';
import '../text/flut5_text.dart';
import '../ui/flut5_ui.dart';
import 'flut5_blur.dart';
import 'flut5_pixelate.dart';
import 'flut5_clip.dart';
import 'flut5_color.dart';
import 'flut5_shadow.dart';
import 'flut5_container.dart';
import 'flut5_cursor.dart';
import 'flut5_event.dart';
import 'flut5_touch.dart';
import 'flut5_wheel.dart';
import 'flut5_transform.dart';
import 'render/flut5_dash.dart';
import 'render/flut5_render_queue.dart';
import 'sketch_environment.dart';

/// The core engine behind Flut5.
///
/// The engine is a composite of multiple mixins that provide modular functionality:
/// * [Flut5Math]: Mathematical functions like mapping and random generation.
/// * [Flut5Trigonometry]: Trigonometric functions and angle mode management.
/// * [Flut5Stroke]: Defines stroke color and weight states.
/// * [Flut5Fill]: Defines fill color states and background drawing.
/// * [Flut52DPrimitives]: Methods to draw primitives like circle, ellipse, and point.
/// * [Flut5ImageMixin]: Loading and drawing bitmaps.
final class Flut5Engine
    with
        Flut5Color,
        Flut5Math,
        Flut5Trigonometry,
        Flut5Noise,
        Flut5Stroke,
        Flut5Fill,
        Flut5Shadow,
        Flut5Blur,
        Flut5Pixelate,
        Flut5Text,
        Flut5ImageMixin,
        Flut52DPrimitives,
        Flut5Vertex,
        Flut5VectorMixin,
        Flut5Spring,
        Flut5Transform,
        Flut5Clip,
        Flut5ContainerMixin,
        Flut5Cursor {
  /// The engine of the sketch currently running — the global-mode singleton
  /// (mirrors p5.js global mode, see https://p5js.org/reference/p5/p5/).
  ///
  /// Maintained by the framework: set when a root sketch ([Flut5Sketch]) is
  /// constructed, refreshed by [Flut5Canvas] right before `setup()` and every
  /// `draw()` (the same rhythm as [canvas]), and cleared when the owning
  /// sketch is disposed. With multiple canvases it always points at the
  /// sketch whose `setup()`/`draw()` is executing.
  ///
  /// In global mode (`Flut5.instanceMode == false`, the default) a plain
  /// `Flut5` subclass constructed without an explicit engine adopts this
  /// instance. In instance mode it is still maintained but never consulted —
  /// engines must be passed through constructors.
  static Flut5Engine? current;

  Canvas? _canvas;

  /// The active Flutter Canvas provided during the paint phase.
  ///
  /// Only assigned by [Flut5Canvas]/[Flut5Painter] on the engine belonging
  /// to the root [Flut5Sketch]. If you access this on an engine that was
  /// never attached to a canvas — most commonly a helper object (enemy,
  /// particle, etc.) that `extends Flut5` but ended up with a standalone
  /// engine instead of the parent sketch's — this throws a [StateError]
  /// explaining the fix instead of a bare [LateInitializationError].
  @override
  Canvas get canvas {
    final canvas = _canvas;
    if (canvas == null) {
      throw StateError(
        'Flut5Engine.canvas has not been initialized.\n'
        'This engine was never attached to a Flut5Canvas — a Flut5 helper '
        "class ended up with its own standalone engine instead of a sketch's."
        '\n\n'
        'Common causes and fixes:\n'
        '  1. The helper was created in a field initializer, before the '
        'parent sketch (and its engine) existed:\n'
        '       final enemy = Enemy();      // runs too early\n'
        '     Make it lazy so it resolves during setup()/draw():\n'
        '       late final enemy = Enemy();\n'
        '     ...or construct it inside setup().\n'
        '  2. The helper was constructed while no sketch was running. '
        'Construct helpers from setup()/draw(), or pass the engine '
        'explicitly:\n'
        '       class Enemy extends Flut5 {\n'
        '         Enemy(Flut5Engine engine) : super(flut5: engine);\n'
        '       }\n'
        '       // construct with Enemy(flut5) from inside the parent sketch.',
      );
    }
    return canvas;
  }

  set canvas(Canvas value) => _canvas = value;

  /// The active dimensions of the drawing area.
  Size get size => environment.size;

  /// Width of the drawing area.
  @override
  double get width => environment.width;

  /// Height of the drawing area.
  @override
  double get height => environment.height;

  @override
  Size get canvasSize => environment.size;

  /// Per-sketch runtime environment state such as frame timing.
  @override
  SketchEnvironment environment = const SketchEnvironment();

  /// Current mouse x position in local canvas coordinates.
  @override
  double get mouseX => environment.mouseX;

  /// Current mouse y position in local canvas coordinates.
  @override
  double get mouseY => environment.mouseY;

  /// Previous mouse x position in local canvas coordinates.
  double get pmouseX => environment.pmouseX;

  /// Previous mouse y position in local canvas coordinates.
  double get pmouseY => environment.pmouseY;

  /// Average mouse velocity x-component (px / frame) over the last
  /// [avgMouseFrames] rendered frames.
  @override
  double get avgMouseX => environment.avgMouseX;

  /// Average mouse velocity y-component (px / frame) over the last
  /// [avgMouseFrames] rendered frames.
  @override
  double get avgMouseY => environment.avgMouseY;

  /// Average mouse velocity (px / frame) over the last [avgMouseFrames]
  /// rendered frames as a 2D [Flut5Vector]. Useful for getting a general
  /// idea of where the mouse is heading.
  @override
  Flut5Vector get avgMouse => environment.avgMouse;

  /// Number of frames used to compute [avgMouseX] / [avgMouseY] / [avgMouse]
  /// (frame-sampled) and the average velocity reported on
  /// [SketchPointerEvent.velocity] / [Flut5Touch.velocity] (move-sampled).
  int get avgMouseFrames => environment.avgMouseFrames;

  /// Sets the rolling window used to compute the average mouse and pointer
  /// velocities. Must be >= 1.
  void setAvgMouseFrames(int frames) {
    environment = environment.withAvgMouseFrames(frames);
    events.avgMouseFrames = frames;
  }

  /// Most recent keyboard key value, matching the latest keyboard event.
  String get key => environment.key;

  /// Most recent keyboard key code, matching the latest keyboard event.
  int get keyCode => environment.keyCode;

  /// Currently active pointers on the canvas (fingers, mouse buttons,
  /// styluses) — empty when nothing is pressed. Mirrors p5.js's `touches`
  /// array and is the entry point for multi-touch interactions. Each entry
  /// has its own `x`, `y`, `px`, `py` and stable `id`.
  @override
  List<Flut5Touch> get touches => events.touches;

  /// Whether any pointer (finger / mouse button / stylus) is currently pressed
  /// on the canvas. Mirrors p5.js's `mouseIsPressed`. Equivalent to
  /// `touches.isNotEmpty`.
  bool get pointerIsDown => events.pointerIsDown;

  /// Buffered mouse-wheel / trackpad scroll for the current frame, or `null`
  /// when no wheel motion occurred. Read by scroll-mode containers; cleared
  /// once per frame by the painter.
  @override
  Flut5WheelSample? get wheel => events.pendingWheel;

  /// Pointer events buffered for the current frame, read by scroll-mode-style
  /// consumers such as `endContainer()` to dispatch per-container pointer
  /// callbacks. Cleared once per frame by the painter after `draw()`.
  @override
  List<Flut5FramePointerEvent> get pendingPointerEvents =>
      events.pendingPointerEvents;

  /// Event management for internal broadcasting.
  late final Flut5Event events = Flut5Event(
    onPointerPositionChanged: (event) {
      environment = environment.withMousePosition(
        mouseX: event.location.dx,
        mouseY: event.location.dy,
        pmouseX: event.plocation.dx,
        pmouseY: event.plocation.dy,
      );
    },
    onKeyboardChanged: (event) {
      environment = environment.withKeyboard(
        key: event.key,
        keyCode: event.keyCode,
      );
    },
  );

  /// UI management for rendering Flut5 UI elements.
  final Flut5UI ui = Flut5UI();

  /// The rendering pipeline queue for deferred drawing.
  @override
  final Flut5RenderQueue renderQueue = Flut5RenderQueue();

  /// The active batch path, or `null` when not batching.
  /// Set by [beginBatch] / [endBatch].
  @override
  Path? batchPath;

  /// The active batch point buffer (flat x,y pairs), or `null` when not
  /// batching. Points are kept separate from [batchPath] because they render
  /// via [Canvas.drawRawPoints] (a single GPU call for all points) rather than
  /// as path geometry.
  @override
  List<double>? batchPoints;

  /// Tracks whether anything has been added to [batchPath] since the current
  /// batch started. Lets [endBatch] skip `path.getBounds()`, which walks the
  /// entire path and becomes expensive once thousands of shapes have been
  /// batched.
  bool _batchDirty = false;

  @override
  void markBatchDirty() {
    _batchDirty = true;
  }

  /// Begins batching all subsequent shape draws into a single [Path] (plus a
  /// coalesced point buffer for [point] calls).
  ///
  /// All shapes drawn between [beginBatch] and [endBatch] share the current
  /// fill and stroke paint. Changing paint inside a batch throws a [FlutterError].
  ///
  /// ```dart
  /// flut5.fill(Colors.blue);
  /// flut5.stroke(Colors.white);
  /// flut5.beginBatch();
  /// flut5.circle(50, 50, 40);
  /// flut5.rect(100, 100, 60, 40);
  /// flut5.point(200, 200); // coalesced with any other points in the batch
  /// flut5.endBatch();      // -> one drawPath + one drawRawPoints
  /// ```
  void beginBatch() {
    if (batchPath != null) {
      throw FlutterError('beginBatch() called while already batching');
    }
    batchPath = Path();
    batchPoints = <double>[];
    _batchDirty = false;
  }

  /// Ends the current batch and enqueues the merged path and point buffer for
  /// rendering.
  ///
  /// An active [setLineDash] pattern applies to the merged stroke pass: the
  /// whole outline is dashed in one go (each sub-path dashes independently,
  /// exactly as the shapes would individually) while the fill stays solid.
  /// Points are never dashed.
  void endBatch() {
    if (batchPath == null) {
      throw FlutterError('endBatch() called without beginBatch()');
    }
    final path = batchPath!;
    final points = batchPoints!;
    final bool pathEmpty = !_batchDirty;
    batchPath = null;
    batchPoints = null;
    _batchDirty = false;

    final bool pointsEmpty = points.isEmpty;
    if (pathEmpty && pointsEmpty) return;

    if (!pathEmpty) {
      final bool hasFill = fillColor != Colors.transparent;
      final bool hasStroke = strokeColor != Colors.transparent;
      final bool needsBounds =
          (hasFill && fillGradient != null && fillGradientRect == null) ||
          (hasStroke && strokeGradient != null && strokeGradientRect == null);
      final bounds = needsBounds ? path.getBounds() : Rect.zero;
      final Paint? fill = hasFill ? snapshotFillPaintForShape(bounds) : null;
      final Paint? stroke = hasStroke ? snapshotStrokePaintForShape(bounds) : null;
      final dash = lineDashVal;
      if (stroke != null && dash != null) {
        // Dash the merged outline in one pass — the stroke stays a single
        // drawPath, so the batch keeps its draw-call win. The shadow rides
        // the solid silhouette when a fill exists so the batch casts one
        // coherent shadow (mirrors the queue's _emitDashed).
        final dashed = dashPath(path, dash, lineDashOffsetVal);
        if (fill != null) {
          renderQueue.enqueueAll([
            PathRenderItem(path, fill, null, shadow: renderQueue.activeShadow),
            PathRenderItem(dashed, null, stroke),
          ]);
        } else {
          renderQueue.enqueue(
            PathRenderItem(dashed, null, stroke,
                shadow: renderQueue.activeShadow),
          );
        }
      } else {
        renderQueue.enqueue(
          PathRenderItem(path, fill, stroke, shadow: renderQueue.activeShadow),
        );
      }
    }

    if (!pointsEmpty && strokeColor != Colors.transparent) {
      final Paint pointPaint = getStrokePaint().clone()
        ..strokeCap = StrokeCap.round;
      renderQueue.enqueue(
        MultiPointRenderItem(
          Float32List.fromList(points),
          pointPaint,
          shadow: renderQueue.activeShadow,
        ),
      );
    }
  }

  /// Number of frames drawn since the sketch started. 0 during [setup].
  @override
  int get frameCount => environment.frameCount;

  /// Milliseconds elapsed since the last frame was drawn.
  /// Useful for frame-rate-independent animation. 0 on the first frame.
  double get deltaTime => environment.deltaTime;

  double? _frameRateCap = 60.0;

  /// Optional cap on the sketch's tick rate, in frames per second. Defaults
  /// to `60` so high-refresh displays (120 Hz / ProMotion) don't double the
  /// per-frame work for sketches that don't need it. Set to `null` (or any
  /// non-positive value) to remove the cap and run at the display refresh
  /// rate. Set to a custom number like `30` to throttle further, or `120`
  /// to opt back into full-refresh on a ProMotion display.
  ///
  /// The cap is enforced by the canvas widget's [Ticker] using cumulative
  /// next-target tracking with a small jitter tolerance, so legitimate
  /// vsync ticks aren't dropped when the cap matches the display rate.
  double? get frameRateCap => _frameRateCap;
  set frameRateCap(double? value) {
    if (value == null || value <= 0) {
      _frameRateCap = null;
    } else {
      _frameRateCap = value;
    }
  }

  /// Returns the measured frame rate of the sketch in frames per second.
  /// When [fps] is provided, also sets [frameRateCap] — pass `0` or `null`
  /// to remove the cap. Mirrors p5's overloaded `frameRate()` API.
  double frameRate([double? fps]) {
    if (fps != null) {
      frameRateCap = fps;
    }
    return environment.frameRate();
  }

  // ── Frame snapshot (trail accumulation) ──────────────────────────────────

  /// Device pixel ratio used when rasterizing the per-frame snapshot for
  /// trail accumulation. The painter writes this each frame from the
  /// hosting widget's [MediaQuery] so the snapshot is captured at the
  /// physical resolution of the display, preserving anti-aliased edges
  /// when blitted back. Defaults to 1.0 before the first paint.
  double devicePixelRatio = 1.0;

  /// Whether the trail snapshot survives a canvas resize.
  ///
  /// When `false` (the default), a resize drops the snapshot — the next
  /// frame starts trail accumulation from a blank canvas. This matches
  /// Processing / p5.js behaviour: resizing wipes the canvas.
  ///
  /// When `true`, the snapshot is kept across resizes and anchored at
  /// the top-left of the new canvas at its original logical size. A
  /// larger canvas leaves the new area uncovered until subsequent draws
  /// reach it; a smaller canvas clips the snapshot. Useful when the user
  /// is dragging a window edge and you'd rather preserve trail content
  /// than flash it away.
  bool preserveSnapshotOnResize = false;

  int? _frameSnapshotMaxResolution = 3600;

  /// Optional cap on the snapshot's longest physical-pixel edge.
  ///
  /// This is the *sharpness* limit of the pair: capping the longest edge
  /// bounds how far the trail blit has to upscale, and so how soft the trail
  /// can get. [frameSnapshotMaxPixels] is the memory limit. Both apply and
  /// the tighter one wins, along with [frameSnapshotResolutionFactor].
  ///
  /// Defaults to `3600` — full native resolution for canvases up to 1800
  /// logical pixels on the longest edge of a 2× display, which covers a
  /// maximized window on current desktop hardware. The previous default of
  /// `2760` was sized for a 1380-logical world and had quietly begun capping
  /// ordinary desktop canvases: a fullscreen sketch on a 5K display captured
  /// at ~0.54 of native without anything saying so.
  ///
  /// Displayed frame rate is guarded independently by the async capture
  /// and, when [adaptiveSnapshotThrottle] is enabled, by the throttle: an
  /// over-budget capture first lowers the capture resolution toward
  /// [frameSnapshotMinResolution] (keeping the fade cadence smooth) and
  /// only at that floor slows the trail's update cadence — never the
  /// sketch fps. Set to `null` to disable this cap (memory is still bounded
  /// by [frameSnapshotMaxPixels]); set to a smaller value (e.g. `1380`,
  /// `1080`, `720`) to trade trail crispness for a larger drop in `toImage`
  /// cost — particularly useful on Flutter Web (CanvasKit) where each
  /// rasterization is comparatively expensive. For a size-relative version of
  /// that trade, prefer [frameSnapshotResolutionFactor].
  ///
  /// Changing the value drops the existing snapshot so the next frame
  /// recaptures at the new resolution.
  int? get frameSnapshotMaxResolution => _frameSnapshotMaxResolution;
  set frameSnapshotMaxResolution(int? value) {
    if (_frameSnapshotMaxResolution == value) return;
    _frameSnapshotMaxResolution = value;
    resetSnapshotCalibration();
    clearFrameSnapshot();
  }

  int? _frameSnapshotMaxPixels = 8000000;

  /// Optional cap on the snapshot's total physical pixel count — the memory
  /// limit of the pair, and the one that holds at any aspect ratio.
  ///
  /// [frameSnapshotMaxResolution] bounds only the longest edge, so what it
  /// costs depends on shape: at a 3600 edge cap a 16:9 snapshot is 3600×2025
  /// (7.3 MP, ~29 MB RGBA) while a square one is 3600×3600 (13 MP, ~52 MB).
  /// Same cap, nearly double the memory. A pixel budget is aspect-independent
  /// and states directly what it protects.
  ///
  /// Defaults to `8000000` — 8 MP, about **32 MB** as RGBA, and two snapshots
  /// are briefly alive during a capture (the old one is still being blitted
  /// while the new one rasterizes), so budget roughly double that as the
  /// working set. It sits just above the 16:9 shape of the default edge cap,
  /// which is deliberate: on wide canvases the edge cap binds first and
  /// governs sharpness, and this only takes over on square-ish ones where the
  /// edge cap would otherwise let memory run.
  ///
  /// Set to `null` to remove the budget. Changing it drops the existing
  /// snapshot so the next frame recaptures at the new resolution.
  int? get frameSnapshotMaxPixels => _frameSnapshotMaxPixels;
  set frameSnapshotMaxPixels(int? value) {
    if (value != null && value <= 0) {
      throw ArgumentError.value(value, 'value', 'must be > 0 or null');
    }
    if (_frameSnapshotMaxPixels == value) return;
    _frameSnapshotMaxPixels = value;
    resetSnapshotCalibration();
    clearFrameSnapshot();
  }

  /// Method form of [frameSnapshotMaxPixels], so it can be called like
  /// `setFrameSnapshotMaxPixels(4000000)`. Pass `null` to remove the budget.
  void setFrameSnapshotMaxPixels(int? pixels) {
    frameSnapshotMaxPixels = pixels;
  }

  /// Get-or-set accessor for [frameSnapshotMaxPixels] (p5-style, like
  /// [frameRate]). `snapshotMaxPixels(4000000)` to set,
  /// `snapshotMaxPixels()` to read.
  int? snapshotMaxPixels([int? pixels]) {
    if (pixels != null) frameSnapshotMaxPixels = pixels;
    return frameSnapshotMaxPixels;
  }

  /// Method form of [frameSnapshotMaxResolution] — takes [size] as a positional
  /// argument so it can be called like `setFrameSnapshotMaxResolution(1080)`.
  /// Pass `null` to disable the cap.
  void setFrameSnapshotMaxResolution(int? size) {
    frameSnapshotMaxResolution = size;
  }

  /// True on web compiled to JavaScript rather than WasmGC — the weakest
  /// target for trail capture, and the one the lower default floors exist
  /// for.
  ///
  /// Both web flavours share the two things that make capture expensive:
  /// there is no raster thread, so a capture cannot overlap the frame the way
  /// it does natively, and `Picture.toImage` carries CanvasKit's per-call
  /// surface cost either way. A WasmGC build removes much of the *Dart-side*
  /// overhead around that, which is what earns it the higher floor here.
  static bool get _isJsWeb => kIsWeb && !kIsWasm;

  /// Per-build-mode defaults for [frameSnapshotResolutionFactor], used until
  /// the factor is assigned explicitly. Both are settable.
  ///
  /// The floor is a *guarantee* — calibration never captures below it — so
  /// these are chosen to be affordable on the weakest device of their class,
  /// and the climb toward [frameSnapshotResolutionFactorMax] is what earns
  /// resolution back on stronger ones.
  static double get _defaultResolutionFactorDebug => _isJsWeb ? 0.7 : 0.8;
  static double get _defaultResolutionFactorProd => _isJsWeb ? 0.9 : 0.95;

  double _frameSnapshotResolutionFactorDebug = _defaultResolutionFactorDebug;
  double _frameSnapshotResolutionFactorProd = _defaultResolutionFactorProd;

  /// The explicit factor, once a sketch assigns one. `null` means neither
  /// build-mode default has been overridden and the mode decides.
  double? _frameSnapshotResolutionFactorOverride;

  /// True when this build runs unoptimized Dart — the debug JIT.
  ///
  /// Profile counts as production: it exists precisely to approximate release
  /// performance, so tuning it like debug would measure the wrong thing.
  static bool get _isDebugBuild => kDebugMode;

  /// Fraction of the canvas's native physical resolution the trail snapshot
  /// is captured at, and the **floor** startup calibration is guaranteed
  /// never to go below. `1.0` captures at full native resolution; `0.5`
  /// halves each edge, which is a **quarter** of the pixels.
  ///
  /// Unless assigned explicitly, this resolves per build mode *and* per
  /// platform: [frameSnapshotResolutionFactorDebug] under the debug JIT,
  /// [frameSnapshotResolutionFactorProd] in profile and release.
  ///
  /// | target | debug | production |
  /// |---|---|---|
  /// | web compiled to JavaScript | `0.7` | `0.9` |
  /// | everything else | `0.8` | `0.95` |
  ///
  /// Two effects stack. Debug is several times slower at the same work —
  /// unoptimized Dart, and on web the DDC compiler rather than dart2js — so a
  /// factor that keeps a sketch fluid while you're building it is needlessly
  /// conservative once it ships. And JavaScript web is the weakest target for
  /// this workload specifically: no raster thread to overlap capture with the
  /// frame, and CanvasKit's per-call `toImage` cost on top.
  ///
  /// Assigning [frameSnapshotResolutionFactor] directly pins one value for
  /// every mode and platform, and both defaults are ignored from then on.
  ///
  /// Paired with the `1.0` default of [frameSnapshotResolutionFactorMax],
  /// either default also means calibration is active out of the box: every
  /// sketch starts conservative for its build mode and climbs toward full
  /// resolution on hardware that measures able to afford it. Set the factor
  /// and the max both to `1.0` to opt out and always capture at native.
  ///
  /// This is the size-relative companion to [frameSnapshotMaxResolution]. The
  /// absolute cap is a fixed pixel count, so what it costs you depends
  /// entirely on the window: on a small canvas it does nothing, on a large
  /// one it bites hard, and the same constant behaves differently across
  /// displays. A factor scales with the window instead, so a sketch tuned on
  /// one machine keeps the same quality/cost trade on another.
  ///
  /// Both apply — the effective capture resolution is whichever of the two is
  /// smaller — so the factor sets the quality trade while the cap keeps a
  /// ceiling on memory for very large canvases.
  ///
  /// Snapshot cost is close to linear in pixel count, so the factor's effect
  /// on capture time goes as its **square**: `0.9` costs ~81%, `0.7` ~49%,
  /// `0.5` ~25%. Going the other way, quality loss shows only in the
  /// accumulated trail — and under [useLayeredTrails] not even there for the
  /// current frame, whose shapes are drawn to the screen at full resolution
  /// regardless.
  ///
  /// One interaction worth knowing: capturing below native means the trail
  /// blit upscales, and the default filter quality escalates to bicubic past
  /// ~1.4× (i.e. a factor below ~0.71) when [adaptiveSnapshotFilterQuality]
  /// is enabled. Bicubic is expensive on CanvasKit in particular, so a low
  /// factor there can hand back what it saved. The default leaves the kernel
  /// at [FilterQuality.low], which sidesteps this entirely.
  ///
  /// Must be greater than 0 and at most 1. Changing it drops the existing
  /// snapshot so the next frame recaptures at the new resolution.
  double get frameSnapshotResolutionFactor =>
      _frameSnapshotResolutionFactorOverride ??
      (_isDebugBuild
          ? _frameSnapshotResolutionFactorDebug
          : _frameSnapshotResolutionFactorProd);
  set frameSnapshotResolutionFactor(double value) {
    _validateResolutionFactor(value);
    if (_frameSnapshotResolutionFactorOverride == value) return;
    _frameSnapshotResolutionFactorOverride = value;
    resetSnapshotCalibration();
    clearFrameSnapshot();
  }

  /// Shared range check. Calls out the unit explicitly: this reads naturally
  /// as a percentage, and `90` or `9.0` for "90%" is the obvious slip. Thrown
  /// from `setup()` the sketch never paints, so the message is the only clue.
  static void _validateResolutionFactor(double value) {
    if (value <= 0 || value > 1) {
      throw ArgumentError.value(
        value,
        'value',
        'must be a fraction > 0 and <= 1, not a percentage '
            '(0.9 for 90% of native resolution, not 90 or 9.0)',
      );
    }
  }

  /// Applies a per-mode default change, resetting calibration only when the
  /// change actually moves the resolution this build captures at — an
  /// explicit override outranks both, and the inactive mode's value has no
  /// effect on the running sketch.
  void _applyModeFactor(bool forDebugBuild) {
    if (_frameSnapshotResolutionFactorOverride != null) return;
    if (_isDebugBuild != forDebugBuild) return;
    resetSnapshotCalibration();
    clearFrameSnapshot();
  }

  /// Default [frameSnapshotResolutionFactor] for debug builds, used unless
  /// the factor is assigned explicitly. Defaults to `0.7` on JavaScript web,
  /// `0.8` everywhere else.
  ///
  /// Lower than the production default because debug runs unoptimized Dart —
  /// and on web the DDC compiler rather than dart2js — so the same sketch
  /// costs several times more per frame while you're building it. Tuning the
  /// shipped build down to match would give away quality no user needs to pay
  /// for.
  double get frameSnapshotResolutionFactorDebug =>
      _frameSnapshotResolutionFactorDebug;
  set frameSnapshotResolutionFactorDebug(double value) {
    _validateResolutionFactor(value);
    if (_frameSnapshotResolutionFactorDebug == value) return;
    _frameSnapshotResolutionFactorDebug = value;
    _applyModeFactor(true);
  }

  /// Method form of [frameSnapshotResolutionFactorDebug].
  void setFrameSnapshotResolutionFactorDebug(double factor) {
    frameSnapshotResolutionFactorDebug = factor;
  }

  /// Get-or-set accessor for [frameSnapshotResolutionFactorDebug] (p5-style).
  /// `snapshotResolutionFactorDebug(0.6)` to set, no argument to read.
  double snapshotResolutionFactorDebug([double? factor]) {
    if (factor != null) frameSnapshotResolutionFactorDebug = factor;
    return frameSnapshotResolutionFactorDebug;
  }

  /// Default [frameSnapshotResolutionFactor] for production builds, used
  /// unless the factor is assigned explicitly. Defaults to `0.9` on
  /// JavaScript web, `0.95` everywhere else.
  ///
  /// Profile builds count as production: profile exists to approximate
  /// release performance, so measuring it against the debug default would
  /// report the wrong thing.
  double get frameSnapshotResolutionFactorProd =>
      _frameSnapshotResolutionFactorProd;
  set frameSnapshotResolutionFactorProd(double value) {
    _validateResolutionFactor(value);
    if (_frameSnapshotResolutionFactorProd == value) return;
    _frameSnapshotResolutionFactorProd = value;
    _applyModeFactor(false);
  }

  /// Method form of [frameSnapshotResolutionFactorProd].
  void setFrameSnapshotResolutionFactorProd(double factor) {
    frameSnapshotResolutionFactorProd = factor;
  }

  /// Get-or-set accessor for [frameSnapshotResolutionFactorProd] (p5-style).
  /// `snapshotResolutionFactorProd(1.0)` to set, no argument to read.
  double snapshotResolutionFactorProd([double? factor]) {
    if (factor != null) frameSnapshotResolutionFactorProd = factor;
    return frameSnapshotResolutionFactorProd;
  }

  /// True when [frameSnapshotResolutionFactor] has been assigned explicitly
  /// and the per-mode defaults are therefore inert. Diagnostic.
  bool get frameSnapshotResolutionFactorIsExplicit =>
      _frameSnapshotResolutionFactorOverride != null;

  /// Drops an explicit [frameSnapshotResolutionFactor], handing the choice
  /// back to the per-mode defaults.
  void clearFrameSnapshotResolutionFactor() {
    if (_frameSnapshotResolutionFactorOverride == null) return;
    _frameSnapshotResolutionFactorOverride = null;
    resetSnapshotCalibration();
    clearFrameSnapshot();
  }

  /// Method form of [frameSnapshotResolutionFactor], so it can be called like
  /// `setFrameSnapshotResolutionFactor(0.75)`.
  void setFrameSnapshotResolutionFactor(double factor) {
    frameSnapshotResolutionFactor = factor;
  }

  double _frameSnapshotResolutionFactorMax = 1.0;

  /// Upper bound for startup resolution calibration. Defaults to `1.0`.
  ///
  /// While this sits above [frameSnapshotResolutionFactor], the engine treats
  /// the factor as a **guaranteed floor** and spends the first second or so
  /// measuring how much more the device can afford, climbing toward this
  /// ceiling and locking in the highest rung that stays inside
  /// [frameSnapshotBudgetMs]. Set the two equal (the default, both `1.0`) and
  /// calibration is skipped entirely — the factor is used verbatim, exactly
  /// as before.
  ///
  /// The point is to stop hand-tuning a factor per platform: pick a floor you
  /// know is safe everywhere (say `0.5`), leave the ceiling at `1.0`, and a
  /// fast machine settles at full resolution while a slow one settles low,
  /// both without dropping frames.
  ///
  /// Calibration deliberately runs only at startup rather than continuously.
  /// Every resolution change resamples the accumulated trail into the new
  /// snapshot, and those generations compound — for a trail effect the
  /// accumulated image *is* the artwork, so repeatedly climbing and falling
  /// would trade exactly the quality the resolution was raised to protect. At
  /// startup the trail is still empty, which makes the search free; once it
  /// locks, resolution stays put. [adaptiveSnapshotThrottle] remains
  /// available as a separate one-way safety valve for genuine overload.
  ///
  /// Values below [frameSnapshotResolutionFactor] are ignored rather than
  /// rejected — the ceiling is never treated as lower than the floor — so the
  /// two can be assigned in either order without an ordering error.
  double get frameSnapshotResolutionFactorMax =>
      _frameSnapshotResolutionFactorMax;
  set frameSnapshotResolutionFactorMax(double value) {
    if (value <= 0 || value > 1) {
      throw ArgumentError.value(
        value,
        'value',
        'must be a fraction > 0 and <= 1, not a percentage '
            '(1.0 for full native resolution, not 100)',
      );
    }
    if (_frameSnapshotResolutionFactorMax == value) return;
    _frameSnapshotResolutionFactorMax = value;
    resetSnapshotCalibration();
    clearFrameSnapshot();
  }

  /// Method form of [frameSnapshotResolutionFactorMax].
  void setFrameSnapshotResolutionFactorMax(double factor) {
    frameSnapshotResolutionFactorMax = factor;
  }

  /// Get-or-set accessor for [frameSnapshotResolutionFactorMax] (p5-style).
  /// `snapshotResolutionFactorMax(1.0)` to set, no argument to read.
  double snapshotResolutionFactorMax([double? factor]) {
    if (factor != null) frameSnapshotResolutionFactorMax = factor;
    return frameSnapshotResolutionFactorMax;
  }

  /// The ceiling actually used: [frameSnapshotResolutionFactorMax], never
  /// below [frameSnapshotResolutionFactor]. Resolving the relationship here
  /// rather than at assignment lets the pair be set in either order.
  double get _resolutionFactorCeiling {
    final floor = frameSnapshotResolutionFactor;
    final ceiling = _frameSnapshotResolutionFactorMax;
    return ceiling < floor ? floor : ceiling;
  }

  // ── Startup resolution calibration ──────────────────────────────────────

  /// Captures spent at one rung before the result is trusted. Small enough
  /// that the whole search finishes in about a second, large enough that a
  /// single stalled capture doesn't decide the outcome.
  static const int _calibrationSamplesPerRung = 4;

  /// Hard stop on the search, in captures. Without it a sketch whose cost
  /// hovers exactly at the budget could keep sampling indefinitely, and every
  /// capture spent calibrating is one spent at less than the final quality.
  static const int _calibrationCaptureBudget = 48;

  int _calibrationIndex = 0;
  int _calibrationSamples = 0;
  int _calibrationTotalCaptures = 0;
  double? _calibrationCostEma;
  bool _calibrationDone = false;

  /// Candidate factors between the floor and the ceiling, ascending.
  ///
  /// The interior steps come from the same eighth-fraction ladder the
  /// overload throttle uses, so a calibrated capture keeps the small-rational
  /// snapshot→display resample ratio that keeps filter softness uniform
  /// across the canvas. The floor and ceiling are always included as the
  /// endpoints, whatever their values.
  List<double> get _calibrationLadder {
    final floor = frameSnapshotResolutionFactor;
    final ceiling = _resolutionFactorCeiling;
    final ladder = <double>[floor];
    // _resolutionRungs is descending; walk it backwards for ascending order.
    for (var i = _resolutionRungs.length - 1; i >= 0; i--) {
      final rung = _resolutionRungs[i];
      if (rung > floor + 1e-6 && rung < ceiling - 1e-6) ladder.add(rung);
    }
    if (ceiling > floor + 1e-6) ladder.add(ceiling);
    return ladder;
  }

  /// The resolution factor calibration has settled on — the floor until the
  /// search finds it can afford more, the locked-in value afterwards.
  ///
  /// Equals [frameSnapshotResolutionFactor] whenever calibration is inactive
  /// (floor and ceiling equal), so the common case costs nothing.
  double get frameSnapshotCalibratedFactor {
    final ladder = _calibrationLadder;
    if (ladder.length <= 1) return frameSnapshotResolutionFactor;
    final index = _calibrationIndex < 0
        ? 0
        : (_calibrationIndex >= ladder.length
            ? ladder.length - 1
            : _calibrationIndex);
    return ladder[index];
  }

  /// True while the startup search is still running. Goes false once a rung
  /// is locked in, the ceiling is reached, or the capture budget runs out.
  bool get frameSnapshotCalibrating =>
      !_calibrationDone && _calibrationLadder.length > 1;

  /// Restarts the startup search from the floor.
  ///
  /// Called automatically whenever a resolution input changes
  /// ([frameSnapshotResolutionFactor], [frameSnapshotResolutionFactorMax],
  /// [frameSnapshotMaxResolution], [frameSnapshotMaxPixels]) or the canvas is
  /// resized, since a measurement taken at one resolution says nothing about
  /// the cost at another. Safe to call directly to re-measure after a sketch
  /// changes what it draws.
  void resetSnapshotCalibration() {
    _calibrationIndex = 0;
    _calibrationSamples = 0;
    _calibrationTotalCaptures = 0;
    _calibrationCostEma = null;
    _calibrationDone = false;
    _calibrationOutcome = null;
  }

  String? _calibrationOutcome;

  /// Why the startup search stopped where it did, or `null` while it is still
  /// running or was never configured.
  ///
  /// Without this, a factor sitting at the floor is ambiguous — it could mean
  /// the search climbed and found the floor was already the best fit, or that
  /// it never got off the floor at all. The distinction matters, because they
  /// call for opposite responses:
  ///
  /// - `'ceiling'` — climbed all the way; the device has room to spare.
  /// - `'no headroom'` — climbed as far as [frameSnapshotBudgetMs] allows.
  ///   Working as intended; raise the budget to trade frame rate for trail
  ///   resolution.
  /// - `'over budget'` — the *floor itself* costs more than the budget, so no
  ///   factor could ever fit and nothing was gained by trying. Usually means
  ///   a per-capture cost that doesn't scale with resolution (CanvasKit's
  ///   `toImage` overhead is the common one), and lowering the factor further
  ///   will not help. Raise [frameSnapshotBudgetMs], lengthen
  ///   [frameSnapshotInterval], or accept the frame rate.
  /// - `'sampling budget'` — the search ran out of captures before settling,
  ///   which means cost was hovering right at the threshold.
  String? get frameSnapshotCalibrationOutcome => _calibrationOutcome;

  void _lockCalibration(String reason) {
    _calibrationDone = true;
    _calibrationOutcome = reason;
    _calibrationSamples = 0;
    _calibrationCostEma = null;
  }

  /// Test seam: injects one measured capture cost into the startup search.
  ///
  /// The production path times the real interval between
  /// [beginFrameSnapshotCapture] and [completeFrameSnapshotCapture], which a
  /// unit test can't control; this feeds the same signal directly.
  @visibleForTesting
  void debugFeedCalibrationSample(double ms) => _updateCalibration(ms);

  /// Feeds one measured capture into the startup search. Called from
  /// [completeFrameSnapshotCapture] alongside the overload throttle.
  ///
  /// Climbs a rung when the cost *projected* at the next one still leaves
  /// headroom — projected by the area ratio, since capture cost tracks pixel
  /// count — and locks the moment it doesn't, or the moment the current rung
  /// is already over budget (stepping back one first, because that rung was
  /// measured affordable).
  void _updateCalibration(double ms) {
    if (_calibrationDone) return;
    final ladder = _calibrationLadder;
    if (ladder.length <= 1) {
      _calibrationDone = true;
      return;
    }

    _calibrationTotalCaptures++;
    final previous = _calibrationCostEma;
    // Even weighting: this is a short deliberate sample, not a long-running
    // signal that needs to shrug off outliers the way the throttle's EMA does.
    _calibrationCostEma = previous == null ? ms : previous * 0.5 + ms * 0.5;

    if (_calibrationTotalCaptures >= _calibrationCaptureBudget) {
      _lockCalibration('sampling budget');
      return;
    }
    if (++_calibrationSamples < _calibrationSamplesPerRung) return;

    final budget = frameSnapshotBudgetMs > 0 ? frameSnapshotBudgetMs : 8.0;
    // Judge the amortized per-frame share, not the raw capture time — the
    // same quantity [frameSnapshotRasterLoad] reports, so the HUD and the
    // search can never disagree about whether a rung is affordable.
    //
    // A capture every `interval` frames costs a fraction of a frame, not a
    // whole one. Comparing raw latency against the budget was calling 11.5 ms
    // at interval 2 unaffordable on a device visibly holding 60 fps at 35%
    // raster load. Raw latency also overstates occupancy on its own: it is
    // measured begin-to-complete across an *async* rasterize, so it spans a
    // frame boundary rather than filling one frame.
    final interval = effectiveFrameSnapshotInterval;
    final cost = _calibrationCostEma! / (interval < 1 ? 1 : interval);

    // Decisions are made on *measured* cost at the current rung, never on a
    // predicted cost at the next one.
    //
    // Predicting requires a model of how cost scales with resolution, and no
    // fixed model survives contact with reality: capture time is
    // `fixed + variable × pixels`, and the fixed half — surface setup, and on
    // CanvasKit the `toImage` round-trip — can dominate completely. Measured
    // on web, a 590×327 capture cost 5.8 ms; scaling that by area predicted
    // 8.9 ms for the next rung when the true cost was barely higher, so the
    // search refused to leave the floor on a device with room to spare.
    //
    // Climbing on measurement instead is model-free. The cost is overshooting
    // by exactly one rung before stepping back, which is a few frames of slow
    // capture during startup — when the trail is empty and nobody is looking.
    if (cost > budget) {
      // Unaffordable. Fall back to the last rung measured affordable; at
      // index 0 there is none, which means the floor itself doesn't fit and
      // no factor in range ever could — worth reporting distinctly, because
      // lowering the factor further will not help a cost that isn't in the
      // pixels.
      final atFloor = _calibrationIndex == 0;
      if (_calibrationIndex > 0) _calibrationIndex--;
      _lockCalibration(atFloor ? 'over budget' : 'no headroom');
      return;
    }
    if (cost > budget * _calibrationHeadroom) {
      // Fits, but too close to the limit to risk another step — a heavier
      // frame than the ones sampled would push it over.
      _lockCalibration('no headroom');
      return;
    }
    if (_calibrationIndex >= ladder.length - 1) {
      _lockCalibration('ceiling');
      return;
    }

    _calibrationIndex++;
    _calibrationSamples = 0;
    _calibrationCostEma = null;
  }

  /// Fraction of [frameSnapshotBudgetMs] a rung must come in under for the
  /// search to try the next one, leaving margin for frames heavier than the
  /// handful sampled.
  static const double _calibrationHeadroom = 0.8;

  /// Get-or-set accessor for [frameSnapshotResolutionFactor] (p5-style, like
  /// [frameRate]). Called with [factor] it assigns (must be > 0 and <= 1);
  /// called with no argument it returns the current value.
  /// `snapshotResolutionFactor(0.75)` to set, `snapshotResolutionFactor()` to
  /// read.
  double snapshotResolutionFactor([double? factor]) {
    if (factor != null) frameSnapshotResolutionFactor = factor;
    return frameSnapshotResolutionFactor;
  }

  /// The fraction of native resolution the painter will *actually* capture
  /// at, once [frameSnapshotMaxResolution] and [frameSnapshotMaxPixels] have
  /// had their say.
  ///
  /// Equal to [frameSnapshotResolutionFactor] while both caps have slack, and
  /// below it once either binds. Requesting `0.9` on a canvas big enough to
  /// hit a cap can quietly yield `0.52`, so this is the value to read when
  /// reasoning about capture cost or trail sharpness, and it is what the
  /// [showFrameSnapshotDebug] HUD reports alongside the request.
  ///
  /// See [frameSnapshotCapBinding] for *which* limit is responsible.
  double get effectiveFrameSnapshotResolutionFactor {
    final dpr = devicePixelRatio > 0 ? devicePixelRatio : 1.0;
    final size = environment.size;
    var factor = frameSnapshotCalibratedFactor;
    final longestLogical = size.width > size.height ? size.width : size.height;
    final edgeCap = _frameSnapshotMaxResolution;
    if (edgeCap != null && edgeCap > 0 && longestLogical > 0) {
      final capFactor = edgeCap / (longestLogical * dpr);
      if (capFactor < factor) factor = capFactor;
    }
    final logicalArea = size.width * size.height;
    final pixelCap = _frameSnapshotMaxPixels;
    if (pixelCap != null && pixelCap > 0 && logicalArea > 0) {
      // Physical pixels scale with the square of the capture scale, so the
      // factor a pixel budget permits is the square root of the ratio.
      final capFactor = math.sqrt(pixelCap / logicalArea) / dpr;
      if (capFactor < factor) factor = capFactor;
    }
    return factor;
  }

  /// Which limit is holding [effectiveFrameSnapshotResolutionFactor] below
  /// the requested [frameSnapshotResolutionFactor], or `null` when the
  /// request is being honoured in full.
  ///
  /// `'edge'` means [frameSnapshotMaxResolution] binds — the trail is being
  /// softened to bound the blit upscale. `'px'` means
  /// [frameSnapshotMaxPixels] binds — the snapshot is being shrunk to bound
  /// memory, which on a square-ish canvas is the usual one. Reported by the
  /// [showFrameSnapshotDebug] HUD so a factor that isn't being honoured says
  /// why, not just that.
  String? get frameSnapshotCapBinding {
    final effective = effectiveFrameSnapshotResolutionFactor;
    if (effective >= frameSnapshotCalibratedFactor - 1e-9) return null;
    final dpr = devicePixelRatio > 0 ? devicePixelRatio : 1.0;
    final size = environment.size;
    final logicalArea = size.width * size.height;
    final pixelCap = _frameSnapshotMaxPixels;
    if (pixelCap != null && pixelCap > 0 && logicalArea > 0) {
      final pixelFactor = math.sqrt(pixelCap / logicalArea) / dpr;
      if (pixelFactor <= effective + 1e-9) return 'px';
    }
    return 'edge';
  }

  int _frameSnapshotMinResolution = 1380;

  /// Floor for the adaptive resolution lever (see
  /// [adaptiveSnapshotThrottle]): automatic downscaling never takes the
  /// snapshot's longest physical edge below this many pixels.
  ///
  /// Defaults to `1380` — an early default for the absolute cap, so the worst case under
  /// load is exactly the old trail crispness. Raise it to insist on more
  /// resolution (pushing overload into cadence stepping sooner), or set it
  /// at/above the effective capture resolution to disable adaptive
  /// downscaling entirely. It never *raises* resolution: canvases that
  /// already capture below this edge (small canvas, low
  /// [frameSnapshotMaxResolution]) are unaffected.
  int get frameSnapshotMinResolution => _frameSnapshotMinResolution;
  set frameSnapshotMinResolution(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'value', 'must be >= 1');
    }
    _frameSnapshotMinResolution = value;
  }

  /// Method form of [frameSnapshotMinResolution].
  void setFrameSnapshotMinResolution(int size) {
    frameSnapshotMinResolution = size;
  }

  double _frameSnapshotResolutionScale = 1.0;
  int _capturesSinceResolutionChange = 0;
  double? _frameSnapshotCostEmaMs;
  int _overBudgetStreak = 0;
  double _lastAppliedResolutionRatio = 1.0;
  double _lastFloorResolutionRatio = 1.0;

  /// Read-only: the multiplier the adaptive throttle currently applies to
  /// the capture resolution (`1.0` = the full, cap-limited resolution).
  /// Shrinks when captures run over [frameSnapshotBudgetMs] and recovers
  /// slowly once cost stays well under budget; the painter clamps the
  /// applied result so the longest edge never drops below
  /// [frameSnapshotMinResolution]. Always one of the eighth-fraction rungs
  /// in the internal ladder (1, ⅞, ¾, ⅝, ½, …) so the snapshot→display
  /// resample ratio stays a small rational: the filter kernel's phase then
  /// repeats every few pixels and softness is uniform across the canvas,
  /// instead of varying with a shape's position and angle the way an
  /// arbitrary ratio does. Diagnostic — shown in the
  /// [showFrameSnapshotDebug] HUD.
  double get frameSnapshotResolutionScale => _frameSnapshotResolutionScale;

  /// Allowed values for [frameSnapshotResolutionScale], descending.
  static const List<double> _resolutionRungs = [
    1.0,
    0.875,
    0.75,
    0.625,
    0.5,
    0.375,
    0.25,
  ];

  /// Largest ladder rung at or below [value] (last rung if none is).
  static double _rungAtOrBelow(double value) {
    for (final rung in _resolutionRungs) {
      if (rung <= value + 0.001) return rung;
    }
    return _resolutionRungs.last;
  }

  /// Smallest ladder rung strictly above [value] (1.0 if none is).
  static double _rungAbove(double value) {
    for (var i = _resolutionRungs.length - 1; i >= 0; i--) {
      final rung = _resolutionRungs[i];
      if (rung > value + 0.001) return rung;
    }
    return 1.0;
  }

  FilterQuality _frameSnapshotFilterQuality = FilterQuality.low;
  bool _frameSnapshotFilterQualityExplicit = false;

  /// Sampling quality used when the cached trail / persistent-background
  /// snapshot is blitted back onto the canvas each frame.
  ///
  /// Defaults to [FilterQuality.low] — bilinear, effectively free and
  /// pixel-exact at 1:1 — for every blit, whatever the upscale. Assign a
  /// value to force a different one: [FilterQuality.none] is
  /// nearest-neighbor, cheapest of all and pixel-exact at 1:1 but aliases
  /// when upscaled; [FilterQuality.high] is bicubic, the sharpest on heavy
  /// upscales and by far the most expensive per blit.
  ///
  /// Set [adaptiveSnapshotFilterQuality] to pick per blit instead of fixing
  /// one kernel.
  ///
  /// Independent of the text glyph sampling controlled by
  /// [Flut5Text.textFilterQuality].
  FilterQuality get frameSnapshotFilterQuality => _frameSnapshotFilterQuality;
  set frameSnapshotFilterQuality(FilterQuality value) {
    _frameSnapshotFilterQuality = value;
    _frameSnapshotFilterQualityExplicit = true;
  }

  /// Upscale ratio above which the default blit kernel switches from
  /// bilinear to bicubic. Sits between the ¾ rung (4/3 ≈ 1.33, calm
  /// bilinear) and the ⅝ rung (1.6, blur-fighting bicubic).
  static const double _bicubicUpscaleThreshold = 1.4;

  /// Lets the painters choose the blit kernel per draw instead of using
  /// [frameSnapshotFilterQuality] for every one: [FilterQuality.low]
  /// (bilinear) at 1:1 and for mild upscales, [FilterQuality.high] (bicubic)
  /// past a ~1.4× upscale.
  ///
  /// The split is perceptual. On mild upscales bicubic's sharpening lobes
  /// make the anti-aliased edges of rotating thin shapes crawl frame to frame
  /// ("jittery angles") while bilinear's extra blur is barely visible; on
  /// heavy upscales softness becomes the dominant artifact and bicubic wins.
  ///
  /// Defaults to `false`, because the cost is not symmetric with the benefit:
  /// bicubic is a materially more expensive full-canvas blit *every frame*,
  /// and it engages exactly when the snapshot is already being captured below
  /// native to save time — clawing back the saving at the moment it was
  /// wanted. It is pronounced on CanvasKit, where the trail blit is one of
  /// the more expensive per-frame operations to begin with. Enable it when
  /// trail sharpness at a low [frameSnapshotResolutionFactor] matters more
  /// than the per-frame cost.
  ///
  /// Ignored once [frameSnapshotFilterQuality] has been assigned explicitly —
  /// an explicit kernel always wins.
  bool adaptiveSnapshotFilterQuality = false;

  /// Internal: resolves the blit quality for a snapshot draw. Painter only.
  ///
  /// Returns the explicit [frameSnapshotFilterQuality] if one was assigned.
  /// Otherwise, with [adaptiveSnapshotFilterQuality] on, picks by
  /// [upscaleRatio] (destination pixels per snapshot pixel; ~1 or below when
  /// not upscaling): bilinear up to [_bicubicUpscaleThreshold], bicubic
  /// beyond it. With it off — the default — the configured quality is used
  /// for every blit.
  FilterQuality effectiveFrameSnapshotFilterQuality({
    required double upscaleRatio,
  }) {
    if (_frameSnapshotFilterQualityExplicit) return _frameSnapshotFilterQuality;
    if (!adaptiveSnapshotFilterQuality) return _frameSnapshotFilterQuality;
    return upscaleRatio > _bicubicUpscaleThreshold
        ? FilterQuality.high
        : FilterQuality.low;
  }

  /// Get-or-set accessor for [frameSnapshotFilterQuality] (p5-style, like
  /// [frameRate]). Called with [quality] it assigns; called with no
  /// argument it just returns the current value without marking the quality
  /// explicit. `snapshotFilterQuality(FilterQuality.none)` to set,
  /// `snapshotFilterQuality()` to read.
  FilterQuality snapshotFilterQuality([FilterQuality? quality]) {
    if (quality != null) frameSnapshotFilterQuality = quality;
    return frameSnapshotFilterQuality;
  }

  int _frameSnapshotInterval = 2;

  /// How often (in frames) the trail snapshot is recaptured via
  /// `picture.toImage`. `2` (the default) recaptures every other frame,
  /// halving the recurring snapshot cost — drawings on skipped frames
  /// still display correctly but don't contribute to the accumulated
  /// trail, so trails look ~half as dense and decay ~twice as fast. Set
  /// `1` to recapture every frame for the smoothest, densest trail fade;
  /// higher values trade more trail density for more headroom.
  ///
  /// When [adaptiveSnapshotThrottle] is enabled this value is treated as a
  /// *floor*: the painter consults [effectiveFrameSnapshotInterval]
  /// instead, which grows above this value when recent captures exceed
  /// [frameSnapshotBudgetMs] or accumulated drops indicate the in-flight
  /// throttle is holding back captures.
  int get frameSnapshotInterval => _frameSnapshotInterval;
  set frameSnapshotInterval(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'value', 'must be >= 1');
    }
    _frameSnapshotInterval = value;
  }

  /// Get-or-set accessor for [frameSnapshotInterval] (p5-style, like
  /// [frameRate]). Called with [interval] it assigns (must be >= 1);
  /// called with no argument it returns the current value.
  /// `snapshotInterval(2)` to set, `snapshotInterval()` to read.
  int snapshotInterval([int? interval]) {
    if (interval != null) frameSnapshotInterval = interval;
    return frameSnapshotInterval;
  }

  /// Enables the adaptive throttle. The engine measures snapshot capture
  /// cost and, when recent captures exceed [frameSnapshotBudgetMs],
  /// responds with two levers in order:
  ///
  /// 1. **Resolution** — shrink the capture resolution (tracked by
  ///    [frameSnapshotResolutionScale], floored at
  ///    [frameSnapshotMinResolution]) while keeping the cadence at
  ///    [frameSnapshotInterval], so the per-frame trail fade stays smooth.
  /// 2. **Cadence** — only once resolution is pinned at the floor,
  ///    [effectiveFrameSnapshotInterval] grows above
  ///    [frameSnapshotInterval] (the fade then steps at snapshot cadence).
  ///
  /// Defaults to `false`: the configured [frameSnapshotInterval] and
  /// resolution are used verbatim — deterministic output, no auto-tuning.
  /// Set to `true` to enable the throttle when a sketch should degrade
  /// gracefully on hardware it wasn't tuned for.
  ///
  /// Toggling resets the controller's adaptive state (resolution scale,
  /// cost/interval EMAs): a stale low rung must not linger invisibly while
  /// the throttle is off, nor snap back into force when it's re-enabled —
  /// re-enabling starts fresh from full resolution and re-measures.
  bool get adaptiveSnapshotThrottle => _adaptiveSnapshotThrottle;
  bool _adaptiveSnapshotThrottle = false;
  set adaptiveSnapshotThrottle(bool value) {
    if (_adaptiveSnapshotThrottle == value) return;
    _adaptiveSnapshotThrottle = value;
    _frameSnapshotResolutionScale = 1.0;
    _adaptiveIntervalEma = 1.0;
    _frameSnapshotCostEmaMs = null;
    _overBudgetStreak = 0;
    _capturesSinceResolutionChange = 0;
  }

  /// Get-or-set accessor for [adaptiveSnapshotThrottle] (p5-style, like
  /// [frameRate]). Called with [enabled] it assigns; called with no
  /// argument it returns the current value. `snapshotAdaptiveQuality(true)`
  /// to set, `snapshotAdaptiveQuality()` to read.
  bool snapshotAdaptiveQuality([bool? enabled]) {
    if (enabled != null) adaptiveSnapshotThrottle = enabled;
    return adaptiveSnapshotThrottle;
  }

  /// Cost ceiling for snapshot capture, in milliseconds. Defaults to `12.0` —
  /// about 72% of a 60 Hz frame, which measured on real sketches is the point
  /// where capture is buying useful trail resolution without the frame rate
  /// noticing. Consulted by two independent mechanisms, which measure against
  /// it differently — deliberately:
  ///
  /// - **Startup calibration** ([frameSnapshotResolutionFactorMax]) compares
  ///   the *amortized per-frame* share, `captureMs / interval`, the same
  ///   quantity [frameSnapshotRasterLoad] reports. At the `12.0` default and
  ///   an interval of 2 that permits captures up to ~24 ms. Raise it to trade
  ///   frame rate for trail resolution; lower it to protect frame rate.
  /// - **The overload throttle** ([adaptiveSnapshotThrottle]) compares the
  ///   raw [frameSnapshotLastCaptureMs] instead, because it controls the
  ///   interval itself — amortizing by a value the controller is steering
  ///   would make the loop circular. When raw captures exceed this it first
  ///   shrinks capture resolution ([frameSnapshotResolutionScale]) and, once
  ///   at [frameSnapshotMinResolution], grows
  ///   [effectiveFrameSnapshotInterval] proportionally.
  double _frameSnapshotBudgetMs = 12.0;
  double get frameSnapshotBudgetMs => _frameSnapshotBudgetMs;
  set frameSnapshotBudgetMs(double value) {
    if (value <= 0) {
      throw ArgumentError.value(value, 'value', 'must be > 0');
    }
    _frameSnapshotBudgetMs = value;
  }

  /// Get-or-set accessor for [frameSnapshotBudgetMs] (p5-style, like
  /// [frameRate]). Called with [ms] it assigns (must be > 0); called with
  /// no argument it returns the current value. `snapshotMsBudget(10)` to
  /// set, `snapshotMsBudget()` to read.
  double snapshotMsBudget([double? ms]) {
    if (ms != null) frameSnapshotBudgetMs = ms;
    return frameSnapshotBudgetMs;
  }

  /// Hard ceiling on [effectiveFrameSnapshotInterval]. Stops a spike from
  /// pushing the trail into "updates once per second" territory, which feels
  /// frozen even when it's technically still working. At 60 fps an interval
  /// of 16 means a snapshot ~every 270 ms — slow but recognisably live.
  int frameSnapshotMaxInterval = 16;

  /// EMA-smoothed estimate of how many snapshot intervals the recent capture
  /// cost implies; consulted by [effectiveFrameSnapshotInterval]. Updated
  /// inside [completeFrameSnapshotCapture] (from measured ms) and inside
  /// [noteFrameSnapshotDropped] (from the in-flight throttle) using a
  /// 0.7 / 0.3 blend so the throttle ramps without jitter.
  double _adaptiveIntervalEma = 1.0;

  /// The throttle the painter actually uses each frame. Never below
  /// [frameSnapshotInterval]; when [adaptiveSnapshotThrottle] is true, grows
  /// above it as recent capture times exceed [frameSnapshotBudgetMs] or as
  /// the in-flight throttle accumulates drops. Capped at
  /// [frameSnapshotMaxInterval]. Returns [frameSnapshotInterval] verbatim
  /// when the throttle is disabled.
  int get effectiveFrameSnapshotInterval {
    if (!adaptiveSnapshotThrottle) return _frameSnapshotInterval;
    final ema = _adaptiveIntervalEma;
    final adaptive = ema.isFinite ? ema.round() : _frameSnapshotInterval;
    final floored =
        adaptive > _frameSnapshotInterval ? adaptive : _frameSnapshotInterval;
    return floored > frameSnapshotMaxInterval
        ? frameSnapshotMaxInterval
        : floored;
  }

  dart_ui.Image? _frameSnapshot;
  Size? _frameSnapshotLogicalSize;

  bool _frameSnapshotInFlight = false;
  int _frameSnapshotEpoch = 0;

  int _frameSnapshotDroppedCount = 0;
  // Monotonic clock for snapshot-capture cost. A wall clock (DateTime.now)
  // can step under NTP, yielding a negative or huge measured ms that would
  // jolt the adaptive-throttle EMA; a Stopwatch only moves forward.
  final Stopwatch _frameSnapshotClock = Stopwatch()..start();
  int? _frameSnapshotCaptureStartMicros;
  double? _frameSnapshotLastCaptureMs;
  (int, int)? _frameSnapshotLastPhysicalSize;

  final _Flut5TrailRepaintNotifier _trailRepaint =
      _Flut5TrailRepaintNotifier();

  /// Fires whenever the trail snapshot is updated or cleared. The split-layer
  /// `TrailPainter` listens to this to repaint only when needed instead of
  /// every frame; safe for sketches to ignore.
  Listenable get trailRepaint => _trailRepaint;

  /// Opt-in to the layered-trail render path (split-layer Phase 2 plan).
  ///
  /// When `false` (the default), every translucent-background frame records a
  /// single picture that contains `(previousSnapshot + queue)`; that picture
  /// is both displayed and async-rasterized into the next snapshot. The live
  /// display fade and the snapshot's fade are the same operation.
  ///
  /// When `true`, display is split into two layers: a static `TrailPainter`
  /// blits the cached snapshot (only repaints when the snapshot updates) and
  /// a foreground `CustomPaint` runs the per-frame queue **without** the
  /// background fill. The snapshot rebuild still records and async-rasterizes
  /// `(previousSnapshot + bg + shapes)` exactly as before, so the snapshot
  /// fades at its own (possibly throttled) cadence. The visible trail fade
  /// therefore *steps* with snapshot updates rather than smoothing every
  /// frame, in exchange for keeping foreground shape motion at full fps even
  /// when the raster thread can't rebuild the snapshot every frame.
  ///
  /// The opaque full-canvas background fast path is unaffected by this flag.
  ///
  /// Toggling at runtime fires [trailRepaint] once so the trail layer syncs:
  /// enabling paints the current snapshot, disabling clears the layer's last
  /// blit (the non-layered foreground can be translucent, so stale trail-layer
  /// content would otherwise show through from beneath).
  bool get useLayeredTrails => _useLayeredTrails;
  set useLayeredTrails(bool value) {
    if (_useLayeredTrails == value) return;
    _useLayeredTrails = value;
    _trailRepaint.fire();
  }

  bool _useLayeredTrails = false;

  /// Decouples the *visible* trail fade from the snapshot capture cadence.
  /// Only meaningful together with [useLayeredTrails]; ignored otherwise.
  ///
  /// In layered mode the trail layer shows the last completed snapshot and
  /// the foreground skips the background fill, so the fade advances only when
  /// a new snapshot lands — it *steps* at capture cadence (and, because
  /// capture is async, the step can trail the capture frame by a frame or
  /// more). At [frameSnapshotInterval] `2` that halves the fade's temporal
  /// resolution; at `3`–`4` it reads as visibly chunky.
  ///
  /// When `true`, the foreground draws a synthetic full-canvas fill each
  /// frame that carries the trail from what the displayed snapshot actually
  /// contains up to what it should look like now: with per-frame fade alpha
  /// `a` and [framesSinceSnapshotApplied] `k`, the compounded alpha
  /// `1 - (1 - a)^k`. The moment a fresh snapshot lands, `k` resets to zero
  /// and the synthetic fill vanishes on its own, so the fade cannot
  /// double-apply.
  ///
  /// The fade then advances every frame while captures stay at whatever
  /// cadence the raster thread can afford — which is what makes a higher
  /// [frameSnapshotInterval] (cheaper) survive without the fade going chunky,
  /// at full capture resolution.
  ///
  /// Two limits worth knowing. It needs a closed-form fade, so it applies
  /// only to plain translucent color backgrounds
  /// ([Flut5RenderQueue.trailFadeColor]) — shader and sub-rect backgrounds
  /// are left alone. And it is an *approximation* of the accumulated result:
  /// shapes drawn on frames that were never captured fade along with the
  /// trail on screen but never entered the snapshot, so at large intervals
  /// the synthetic fade and the real one can drift slightly in density.
  /// Defaults to `false`.
  bool smoothTrailFade = false;

  /// Frames painted since the snapshot currently on display was applied.
  ///
  /// Incremented once per painted frame and reset by [setFrameSnapshot], so
  /// it counts against the snapshot the trail layer is *showing*, not the one
  /// being captured — which is the quantity [smoothTrailFade] needs, since an
  /// async capture lands a frame or more after the frame that started it.
  int get framesSinceSnapshotApplied => _framesSinceSnapshotApplied;
  int _framesSinceSnapshotApplied = 0;

  /// Internal: per-frame bookkeeping for the diagnostics. Painter only, once
  /// per frame, after the environment's frame timing has been advanced.
  ///
  /// Ages [framesSinceSnapshotApplied] — saturating rather than overflowing,
  /// since a sketch left running with a static trail would otherwise count
  /// forever and every consumer treats "very large" the same as "fully
  /// faded" — and folds this frame's rate into [smoothedFrameRate].
  void noteFramePainted() {
    if (_framesSinceSnapshotApplied < 1 << 20) _framesSinceSnapshotApplied++;
    final dt = environment.deltaTime;
    if (dt <= 0) return;
    final previous = _frameTimeEmaMs;
    // Smooth the frame *time* and invert at the end, rather than smoothing
    // instantaneous rates. Averaging 1/dt is biased high whenever frame times
    // vary — by Jensen's inequality E[1/dt] ≥ 1/E[dt], equal only if every
    // frame takes exactly as long as the last. Snapshot sketches are the
    // worst case for it: capture frames are slow and the frames between them
    // fast, so a rate-average reported comfortably above the frame rate cap.
    //
    // Heavier smoothing than the capture-cost EMA, since this exists to be
    // read off a HUD by eye.
    _frameTimeEmaMs = previous == null ? dt : previous * 0.9 + dt * 0.1;
  }

  double? _frameTimeEmaMs;

  /// EMA-smoothed frame time in milliseconds, or `null` before the first
  /// timed frame. The quantity [smoothedFrameRate] is derived from.
  double? get smoothedFrameTimeMs => _frameTimeEmaMs;

  /// EMA-smoothed measured frame rate, or `null` before the first timed
  /// frame. Unlike `frameRate()` — which reports the instantaneous rate from
  /// a single [deltaTime] — this is steady enough to read while a sketch runs,
  /// and cannot exceed the true average rate the way a smoothed instantaneous
  /// rate can.
  double? get smoothedFrameRate {
    final ms = _frameTimeEmaMs;
    if (ms == null || ms <= 0) return null;
    return 1000.0 / ms;
  }

  /// EMA-smoothed snapshot capture cost in milliseconds, or `null` before the
  /// first capture completes. The companion to
  /// [frameSnapshotLastCaptureMs], which is a single raw sample and jumps
  /// around with unrelated OS stalls.
  ///
  /// Maintained whether or not [adaptiveSnapshotThrottle] is on — the
  /// throttle consumes it when enabled, but it is measured either way.
  double? get frameSnapshotCostEmaMs => _frameSnapshotCostEmaMs;

  /// Share of one frame's time that snapshot capture consumes on the raster
  /// thread, amortized over the capture cadence. `null` before the first
  /// capture completes.
  ///
  /// `1.0` means capture alone fills the entire frame budget, leaving nothing
  /// for the sketch's own drawing or compositing — so anything approaching it
  /// caps the achievable frame rate no matter what the Dart side does, and
  /// values above it mean the raster thread is oversubscribed and frames are
  /// already being paced by capture. Roughly `0.5` or below is comfortable.
  ///
  /// Measured against [frameRateCap] when one is set, 60 Hz otherwise, and
  /// divided by [effectiveFrameSnapshotInterval] because a capture every `n`
  /// frames spreads its cost over `n` frames.
  double? get frameSnapshotRasterLoad {
    final cost = _frameSnapshotCostEmaMs;
    if (cost == null) return null;
    final interval = effectiveFrameSnapshotInterval;
    final perFrame = cost / (interval < 1 ? 1 : interval);
    final target = frameRateCap ?? 60.0;
    if (target <= 0) return null;
    return perFrame / (1000.0 / target);
  }

  /// Captures the trail snapshot with `Picture.toImageSync` instead of the
  /// default async `Picture.toImage`.
  ///
  /// `toImageSync` returns an image handle immediately and defers the actual
  /// rasterization to the raster thread, where it happens as part of the
  /// current frame. That removes the async round-trip, so the snapshot is
  /// available on the very next frame instead of lagging one or more, and no
  /// capture is ever skipped by the in-flight gate.
  ///
  /// The cost is that the gate is exactly what it gives up: with the async
  /// path a slow rasterization skips captures and the sketch keeps its frame
  /// rate, while here the rasterization lands inside the frame and a slow one
  /// shows up directly as frame time. It also makes
  /// [frameSnapshotLastCaptureMs] meaningless — the call returns before the
  /// work happens — so the measured cost is not fed to the adaptive throttle
  /// while this is on, and [adaptiveSnapshotThrottle]'s resolution lever has
  /// nothing to steer by. Treat the two as mutually exclusive.
  ///
  /// Defaults to `false`. Worth measuring per-platform rather than assuming:
  /// it tends to win where rasterization is comfortably inside budget and the
  /// async latency is the dominant artifact, and lose where it isn't.
  bool useSyncSnapshotCapture = false;

  /// Toggles a small on-canvas HUD that reports the per-frame snapshot cost —
  /// last `toImage` duration, dropped count, and capture resolution. The HUD is
  /// painted by [Flut5Painter] in the corner of the canvas; toggle it from a
  /// sketch to profile translucent-background performance on a real device
  /// without leaving for Flutter DevTools. Defaults to `false`.
  bool showFrameSnapshotDebug = false;

  /// Shows the on-canvas snapshot performance HUD — capture cost, raster load
  /// against the frame budget, measured fps, capture resolution, drops,
  /// interval, and the calibration state. Readable form of
  /// [showFrameSnapshotDebug].
  ///
  /// `showSnapshotPerformanceInfo()` turns it on;
  /// `showSnapshotPerformanceInfo(false)` turns it off. Unlike the p5-style
  /// get-or-set accessors elsewhere on the engine ([snapshotInterval],
  /// [snapshotAdaptiveQuality]), a bare call here *acts* rather than reads —
  /// a method named "show…" that quietly did nothing would be a trap. Read
  /// the current state from [showFrameSnapshotDebug].
  void showSnapshotPerformanceInfo([bool enabled = true]) {
    showFrameSnapshotDebug = enabled;
  }

  /// Hides the snapshot performance HUD. Equivalent to
  /// `showSnapshotPerformanceInfo(false)`, in the p5 `noFill` / `noStroke`
  /// spirit.
  void noSnapshotPerformanceInfo() {
    showFrameSnapshotDebug = false;
  }

  /// True while an async snapshot rasterization is pending. The painter uses
  /// this to throttle to one in-flight capture at a time so futures don't pile
  /// up when rasterization is slower than the frame rate.
  bool get isFrameSnapshotInFlight => _frameSnapshotInFlight;

  /// Monotonic counter bumped whenever the snapshot is invalidated
  /// ([clearFrameSnapshot], [frameSnapshotMaxResolution] change). The painter
  /// captures the epoch at the start of an async rasterize and discards the
  /// resulting image on completion if the epoch has moved on — guarantees a
  /// stale capture can't overwrite a freshly cleared snapshot.
  int get frameSnapshotEpoch => _frameSnapshotEpoch;

  /// Number of trail-snapshot captures the painter has skipped because a
  /// previous capture was still in flight (the `isFrameSnapshotInFlight`
  /// throttle). A persistently growing counter means `toImage` rasterization
  /// can't keep up with the frame rate — consider raising
  /// [frameSnapshotInterval] or lowering [frameSnapshotMaxResolution].
  int get frameSnapshotDroppedCount => _frameSnapshotDroppedCount;

  /// Wall-clock milliseconds of the most recent snapshot capture — measured
  /// between [beginFrameSnapshotCapture] and [completeFrameSnapshotCapture],
  /// so it covers the async `picture.toImage` round-trip. `null` until the
  /// first capture completes.
  double? get frameSnapshotLastCaptureMs => _frameSnapshotLastCaptureMs;

  /// Physical `(width, height)` of the most recent snapshot capture, after the
  /// [frameSnapshotMaxResolution] cap is applied. `null` until the first
  /// capture starts.
  (int, int)? get frameSnapshotLastPhysicalSize => _frameSnapshotLastPhysicalSize;

  /// Internal: called by the painter when it would have started a capture
  /// but [isFrameSnapshotInFlight] was still true. Bumps the dropped
  /// counter; once the resolution lever is pinned at its floor it also
  /// pushes the interval EMA up by one "missed interval" worth of cost —
  /// captures that complete in 8 ms but stack up because they overlap the
  /// frame budget still need a slower cadence, and measured ms alone won't
  /// surface that.
  void noteFrameSnapshotDropped() {
    _frameSnapshotDroppedCount++;
    // While resolution can still shrink, stay off the interval EMA: the
    // in-flight capture's measured duration already spans this overrun and
    // will drive a resolution shrink on completion, keeping the fade
    // cadence smooth.
    if (!_atResolutionFloor) return;
    // A drop = the previous capture is still rasterising past this tick, so
    // the *effective* per-capture cost is at least one interval longer than
    // the budget. Feed that signal into the same EMA the duration path uses.
    const droppedSignal = 2.0;
    _adaptiveIntervalEma = _adaptiveIntervalEma * 0.7 + droppedSignal * 0.3;
  }

  bool get _atResolutionFloor =>
      _lastAppliedResolutionRatio <= _lastFloorResolutionRatio + 0.001 ||
      _frameSnapshotResolutionScale <= _resolutionRungs.last + 0.001;

  /// Internal: marks an async snapshot rasterize as started. Painter only.
  ///
  /// [appliedResolutionRatio] and [floorResolutionRatio] describe where the
  /// adaptive resolution lever sat for this capture, both relative to the
  /// un-throttled (cap-limited) capture scale; the throttle uses them to
  /// decide whether over-budget cost should shrink resolution further or
  /// start growing the capture interval.
  void beginFrameSnapshotCapture(
    int physicalWidth,
    int physicalHeight, {
    double appliedResolutionRatio = 1.0,
    double floorResolutionRatio = 1.0,
  }) {
    _frameSnapshotInFlight = true;
    _frameSnapshotCaptureStartMicros = _frameSnapshotClock.elapsedMicroseconds;
    _frameSnapshotLastPhysicalSize = (physicalWidth, physicalHeight);
    _lastAppliedResolutionRatio = appliedResolutionRatio;
    _lastFloorResolutionRatio = floorResolutionRatio;
  }

  /// Internal: applies an async snapshot result if [epoch] still matches the
  /// current epoch, otherwise disposes the stale image. Painter only.
  ///
  /// [recordCost] is `false` on the [useSyncSnapshotCapture] path, where the
  /// elapsed span covers only the `toImageSync` handle allocation and not the
  /// deferred rasterization — a near-zero reading that would tell the
  /// adaptive throttle captures are free and let it recover resolution it
  /// cannot afford.
  void completeFrameSnapshotCapture(
    dart_ui.Image? image,
    Size logicalSize,
    int epoch, {
    bool recordCost = true,
  }) {
    _frameSnapshotInFlight = false;
    final start = _frameSnapshotCaptureStartMicros;
    if (start != null) {
      if (recordCost) {
        final ms =
            (_frameSnapshotClock.elapsedMicroseconds - start) / 1000.0;
        _frameSnapshotLastCaptureMs = ms;
        _updateCalibration(ms);
        _updateAdaptiveThrottle(ms);
      }
      _frameSnapshotCaptureStartMicros = null;
    }
    if (image == null) return;
    if (epoch != _frameSnapshotEpoch) {
      image.dispose();
      return;
    }
    setFrameSnapshot(image, logicalSize);
  }

  /// Feeds one measured capture duration into the two-lever adaptive
  /// throttle (see [adaptiveSnapshotThrottle]): resolution shrinks while it
  /// has room above [frameSnapshotMinResolution]; the interval EMA only
  /// accumulates real cost once resolution is pinned at the floor, and
  /// relaxes back toward the configured interval otherwise.
  void _updateAdaptiveThrottle(double ms) {
    final budget = frameSnapshotBudgetMs > 0 ? frameSnapshotBudgetMs : 8.0;
    final previousEma = _frameSnapshotCostEmaMs;
    final costEma = previousEma == null ? ms : previousEma * 0.7 + ms * 0.3;
    _frameSnapshotCostEmaMs = costEma;
    _capturesSinceResolutionChange++;
    // Track how long the smoothed cost has stayed over budget. A single
    // OS-level stall (window server hiccup, GC) produces one huge sample
    // that pushes the EMA over budget for a capture or two even though
    // steady-state cost is fine — measured on-device, that was enough to
    // trigger unjustified resolution shrinks. Genuine overload keeps the
    // EMA above budget on every capture, so requiring a short streak
    // (~80 ms at 60 fps) filters the spikes without materially delaying a
    // real response.
    if (costEma > budget) {
      _overBudgetStreak++;
    } else {
      _overBudgetStreak = 0;
    }

    final atFloor = _atResolutionFloor;
    // Clamped so a single anomalous spike can't blow the throttle up to
    // absurd values.
    final desired = atFloor ? (costEma / budget).clamp(1.0, 64.0) : 1.0;
    _adaptiveIntervalEma = _adaptiveIntervalEma * 0.7 + desired * 0.3;

    // Let a resolution change settle (shader/raster warm-up, fresh cost
    // EMA) before judging it.
    if (_capturesSinceResolutionChange < 3) return;

    if (costEma > budget && _overBudgetStreak >= 5 && !atFloor) {
      // Cost scales with pixel area, so the edge scale moves with the
      // square root. Aim below budget (70%) for headroom, clamp the step so
      // one async-delayed outlier can't collapse resolution in a single
      // jump, then snap down to the rung ladder for a clean resample ratio.
      final factor = math.sqrt(0.7 * budget / costEma).clamp(0.7, 1.0);
      final snapped =
          _rungAtOrBelow(_frameSnapshotResolutionScale * factor);
      if (snapped < _frameSnapshotResolutionScale) {
        _frameSnapshotResolutionScale = snapped;
        _capturesSinceResolutionChange = 0;
        _frameSnapshotCostEmaMs = null;
        _overBudgetStreak = 0;
      }
    } else if (_frameSnapshotResolutionScale < 1.0 &&
        _capturesSinceResolutionChange >= 90) {
      // Recover one rung at a time, and only when the projected cost at the
      // larger rung (cost grows with the area ratio) still leaves headroom —
      // hysteresis so sharpness doesn't pump, since every resolution change
      // costs one resample generation of the existing trail.
      final next = _rungAbove(_frameSnapshotResolutionScale);
      final edgeRatio = next / _frameSnapshotResolutionScale;
      if (costEma * edgeRatio * edgeRatio < budget * 0.8) {
        _frameSnapshotResolutionScale = next;
        _capturesSinceResolutionChange = 0;
        _frameSnapshotCostEmaMs = null;
      }
    }
  }

  /// The most recent rasterized frame snapshot used to carry trail content
  /// across frames. Auto-managed by the painter: populated whenever the user
  /// does NOT call an opaque full-canvas [background] in a frame, cleared
  /// when they do. Read-only — call [clearFrameSnapshot] to reset manually.
  dart_ui.Image? get frameSnapshot => _frameSnapshot;

  /// Logical-pixel size of the canvas at the time [frameSnapshot] was
  /// captured. The painter uses this to keep trails anchored at their
  /// original position when the canvas is resized — preserving trail
  /// content in place rather than stretching or wiping it.
  Size? get frameSnapshotLogicalSize => _frameSnapshotLogicalSize;

  /// Internal: replaces the stored snapshot and remembers the logical size
  /// of the canvas at capture time. Disposes the previous image. The
  /// painter owns this lifecycle; external callers should use
  /// [clearFrameSnapshot] instead.
  void setFrameSnapshot(dart_ui.Image image, Size logicalSize) {
    if (identical(_frameSnapshot, image)) return;
    _frameSnapshot?.dispose();
    _frameSnapshot = image;
    _frameSnapshotLogicalSize = logicalSize;
    // This snapshot already contains every fade applied up to its capture, so
    // the synthetic fade [smoothTrailFade] adds on top starts over from zero.
    _framesSinceSnapshotApplied = 0;
    // Only the layered TrailPainter consumes this notification; in the
    // default single-painter mode firing would just re-rasterize an empty
    // trail layer on every capture.
    if (_useLayeredTrails) _trailRepaint.fire();
  }

  /// Discards the current trail snapshot, restarting accumulation from a
  /// blank canvas on the next non-opaque-bg frame. Useful for clearing
  /// trails between scenes without calling [background].
  void clearFrameSnapshot() {
    // No stored snapshot and no capture in flight: nothing to clear, no
    // epoch to invalidate, no layer to repaint. This is the every-frame path
    // for opaque-background sketches (the painter clears unconditionally on
    // the opaque fast path), so it must stay a true no-op.
    if (_frameSnapshot == null && !_frameSnapshotInFlight) return;
    _frameSnapshot?.dispose();
    _frameSnapshot = null;
    _frameSnapshotLogicalSize = null;
    // No snapshot on display means no accumulated fade to extend.
    _framesSinceSnapshotApplied = 0;
    // Invalidate any in-flight async capture: when its future resolves, the
    // epoch mismatch causes the resulting image to be disposed instead of
    // re-establishing a snapshot the caller asked us to drop.
    _frameSnapshotEpoch++;
    if (_useLayeredTrails) _trailRepaint.fire();
  }
}

/// Simple [ChangeNotifier] subclass that exposes [fire] so the engine can
/// notify trail-layer listeners without exposing [notifyListeners] itself.
class _Flut5TrailRepaintNotifier extends ChangeNotifier {
  bool _deferred = false;

  /// Notifies trail-layer listeners that the snapshot changed.
  ///
  /// The trail layer ([_TrailPainter]) listens to this as its `repaint`
  /// [Listenable], so notifying drives its `markNeedsPaint`. When [fire] is
  /// reached *during* the frame's drawing phase — e.g. the painter calling
  /// [clearFrameSnapshot] mid-paint after an opaque full-canvas background —
  /// markNeedsPaint during paint is illegal and the framework rethrows it
  /// through this notifier ("… sending notification …"). In that case the
  /// notification is coalesced to a single post-frame callback instead, which
  /// is visually safe: an opaque background already covers the stale trail
  /// layer for the frame it's deferred over.
  void fire() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    final duringFrame = phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;
    if (!duringFrame) {
      notifyListeners();
      return;
    }
    if (_deferred) return;
    _deferred = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _deferred = false;
      notifyListeners();
    });
  }
}
