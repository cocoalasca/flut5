import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWasm, kIsWeb, mapEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../flut5.dart';

/// Notifier used to manually trigger repaints of the Flut5 canvas.
///
/// Internally hooked to a [Ticker] that fires continuously.

class Flut5CanvasRepaintController extends ChangeNotifier {
  /// Notifies listeners (the CustomPainter) that a new frame should be drawn.
  void refresh() {
    notifyListeners();
  }
}

/// The primary widget that hosts a [Flut5Sketch].
///
/// It sets up the [Ticker] loop, handles pointer events, and layers
/// the custom UI elements defined by the sketch on top of the drawing canvas.
class const Flut5Canvas({
  super.key,

  /// The user's implemented sketch containing the `setup` and `draw` logic.
  required final Flut5Sketch sketch,

  /// Optional size constraints for the canvas. Defaults to infinite,
  /// causing it to fill the available space.
  final Size size = Size.infinite,

  /// Flexible props map that flows from the parent widget into the sketch.
  /// Available as `props` inside [Flut5Sketch.setup] and [Flut5Sketch.draw].
  ///
  /// When this map changes by value, `onStateChange` is broadcast to the
  /// sketch and to every helper constructed with `listenEvents: true` — the
  /// sketch is NOT reset. Keep the sketch instance stable (as a field, not
  /// inline) to avoid unintended resets on parent rebuilds.
  ///
  /// Comparison is [mapEquals], so a fresh `List`/closure literal in the map
  /// counts as a change on every parent rebuild.
  /// Null means no props are provided; the sketch will use an empty map.
  final Map<String, dynamic>? props,

  /// Flutter widgets drawn over the canvas, sized to it. Follows the
  /// [CustomPaint] convention: the painter renders behind, the child in front.
  ///
  /// A [Stack] is the usual choice — it is transparent to hit-testing, so
  /// [Positioned] children occupy only the regions they paint:
  ///
  /// ```dart
  /// Flut5Canvas(
  ///   sketch: _sketch,
  ///   child: Stack(children: [
  ///     Positioned(top: 8, right: 8, child: ScoreReadout(sketch: _sketch)),
  ///   ]),
  /// )
  /// ```
  ///
  /// A gesture that starts inside a widget's bounds belongs to that widget and
  /// never reaches the sketch; one that starts on empty space reaches the
  /// sketch for its whole duration, even while passing over a widget. Wrap a
  /// widget in [IgnorePointer] to let presses through to the sketch.
  ///
  /// Three things this slot cannot do — use a sibling widget instead:
  /// * It cannot take layout space; it always matches the canvas rect.
  /// * It unmounts whenever the canvas resolves to a zero size, discarding any
  ///   state it holds (an in-flight `AnimationController`, scroll position).
  /// * It sits inside the canvas's autofocused [KeyboardListener], so a
  ///   [TextField] here takes focus and silences the sketch's key events.
  final Widget? child,
}) extends StatefulWidget {
  @override
  State<Flut5Canvas> createState() => _Flut5CanvasState();

  /// Whether the one-time multi-canvas / global-mode advice has fired this
  /// session. Test-only seam for the warning in [_Flut5CanvasState].
  @visibleForTesting
  static bool get debugMultiCanvasWarned =>
      _Flut5CanvasState._multiCanvasWarned;

  /// Resets the one-time multi-canvas warning guard so a following test can
  /// observe it fire again. Does not touch the live-canvas count, which
  /// balances itself as widgets mount and unmount.
  @visibleForTesting
  static void debugResetMultiCanvasWarning() {
    _Flut5CanvasState._multiCanvasWarned = false;
  }

  /// Whether the one-time [child] orientation note has fired this session.
  /// Test-only seam for the notice in [_Flut5CanvasState].
  @visibleForTesting
  static bool get debugChildNoticeShown => _Flut5CanvasState._childNoticeShown;

  /// Resets the one-time [child] notice guard so a following test can observe
  /// it fire again.
  @visibleForTesting
  static void debugResetChildNotice() {
    _Flut5CanvasState._childNoticeShown = false;
  }
}

class _Flut5CanvasState extends State<Flut5Canvas>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  late Flut5Painter _painter;
  late _TrailPainter _trailPainter;
  late final FocusNode _keyboardFocusNode;
  final Flut5CanvasRepaintController _repaint = Flut5CanvasRepaintController();

  bool _setupScheduled = false;
  Size _previousSize = Size.zero;
  Duration _nextFrameTarget = Duration.zero;
  static const Duration _frameRateTolerance = Duration(microseconds: 2000);

  /// Number of [Flut5Canvas] widgets currently mounted. Incremented in
  /// [initState] and decremented in [dispose] so [_maybeWarnMultipleCanvases]
  /// can detect the global-mode multi-canvas hazard.
  static int _liveCanvasCount = 0;

  /// Guards [_maybeWarnMultipleCanvases] so the advice is printed at most once
  /// per app session, never per frame or per extra canvas.
  static bool _multiCanvasWarned = false;

  /// Guards [_maybeNoteChildInput] so the orientation note is printed at most
  /// once per app session, never per frame or per canvas.
  static bool _childNoticeShown = false;

  @override
  void initState() {
    super.initState();
    Flut5TextCache.instance.trackFrames();
    _ticker = createTicker(_onTick);
    _ticker.start();
    _painter = Flut5Painter(sketch: widget.sketch, repaint: _repaint);
    _trailPainter = _TrailPainter(widget.sketch.flut5);
    _keyboardFocusNode = FocusNode(debugLabel: 'Flut5Canvas');
    _liveCanvasCount++;
    _maybeWarnMultipleCanvases();
  }

  /// Emits a one-time note the first time a [Flut5Canvas.child] is used.
  ///
  /// Not a defect report — overlaid widgets capturing input is ordinary
  /// behaviour, identical to a DOM element over a `<canvas>`. The note exists
  /// so the first time a press lands on an overlay and the sketch stays quiet,
  /// the reason is already familiar. Debug builds only: an orientation note has
  /// no business in a shipped app's logs.
  void _maybeNoteChildInput() {
    if (!kDebugMode || _childNoticeShown) return;
    _childNoticeShown = true;
    Flut5Console.printLater(
      'Flut5Canvas.child draws Flutter widgets over the canvas. A Stack is the '
      'recommended child when positioning several widgets. Widgets there take '
      'pointer events first, so a press inside their bounds never reaches the '
      'sketch (mousePressed / onPointerDown). Wrap one in IgnorePointer to let '
      'presses through.',
    );
  }

  /// Emits a one-time console warning when more than one [Flut5Canvas] is
  /// alive while Flut5 is in *global mode* ([Flut5.instanceMode] is false).
  ///
  /// In global mode every sketch shares one engine through
  /// [Flut5Engine.current], which is retargeted to whichever canvas is running
  /// `setup()`/`draw()`. With a single canvas that's unambiguous, but two or
  /// more sharing the singleton means a plain [Flut5] helper constructed
  /// outside `setup()`/`draw()` (a timer, gesture callback, or app state) can
  /// bind to whichever canvas painted last — a coin flip. Instance mode makes
  /// that explicit and safe.
  ///
  /// The check is deferred to after the current frame so an in-place canvas
  /// swap (hot reload, a keyed rebuild) whose old state disposes moments later
  /// doesn't trip a false positive on the transient overlap.
  void _maybeWarnMultipleCanvases() {
    if (_multiCanvasWarned || Flut5.instanceMode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_multiCanvasWarned || Flut5.instanceMode) return;
      if (_liveCanvasCount <= 1) return;
      _multiCanvasWarned = true;
      Flut5Console.printLater(
        'Multiple Flut5Canvas widgets are active in global mode '
        '(Flut5.instanceMode == false), so they all share one engine via '
        'Flut5Engine.current. A Flut5 helper constructed outside '
        'setup()/draw() may bind to the wrong canvas. Switch to instance '
        'mode and pass each engine explicitly:\n'
        '  Flut5.instanceMode = true; // once, e.g. in main()\n'
        '  class Enemy extends Flut5 {\n'
        '    Enemy(Flut5Engine engine) : super(flut5: engine);\n'
        '  }',
      );
    });
  }

  @override
  void reassemble() {
    super.reassemble();
    // Developer helper: Force setup to run again on Hot Reload
    widget.sketch.isReady = false;
    _setupScheduled = false;
  }

  @override
  void didUpdateWidget(Flut5Canvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sketch != widget.sketch) {
      _disposeSketch(oldWidget.sketch);
      _painter = Flut5Painter(sketch: widget.sketch, repaint: _repaint);
      _trailPainter = _TrailPainter(widget.sketch.flut5);
      _setupScheduled = false;
    } else if (!mapEquals(oldWidget.props, widget.props)) {
      final newProps = widget.props ?? const {};
      // The field is assigned synchronously so setup()/draw() and any pointer
      // callback read the new value immediately. The onStateChange broadcast
      // rides the engine's event stream like every other event, so the sketch
      // and any helper with `listenEvents: true` receive it uniformly — one
      // microtask later, which still lands before the next frame.
      widget.sketch.props = newProps;
      widget.sketch.flut5.events.addStateChange(newProps);
    }
  }

  @override
  void dispose() {
    _liveCanvasCount--;
    _ticker.dispose();
    _keyboardFocusNode.dispose();
    _repaint.dispose();
    _disposeSketch(widget.sketch);
    super.dispose();
  }

  /// Tears [sketch] down: its own `dispose()` first, so a user override runs,
  /// then [Flut5.disposeFlut5] directly.
  ///
  /// A sketch that mixes in [ChangeNotifier] (as [Flut5ChangeNotifier] asks it
  /// to) inherits `ChangeNotifier.dispose`, which overrides `Flut5.dispose`
  /// and does not chain to it — so the engine teardown would never run.
  /// `disposeFlut5` is idempotent, so the ordinary path pays nothing for the
  /// second call.
  void _disposeSketch(Flut5Sketch sketch) {
    sketch.dispose();
    sketch.disposeFlut5();
  }

  /// Ticker callback. When [Flut5Engine.frameRateCap] is null the tick is
  /// delivered immediately. Otherwise we track an absolute next-target time
  /// (`_nextFrameTarget`) and only deliver once `elapsed` reaches it, with a
  /// small tolerance to absorb sub-millisecond vsync jitter — comparing
  /// `elapsed - last < interval` directly drops legitimate ticks that arrive
  /// a hair early and halves the effective framerate on a cap-matches-display
  /// setup. Catch-up is suppressed so a backgrounded sketch doesn't fire a
  /// burst of repaints on resume.
  void _onTick(Duration elapsed) {
    final cap = widget.sketch.flut5.frameRateCap;
    if (cap == null || cap <= 0) {
      _nextFrameTarget = Duration.zero;
      _repaint.refresh();
      return;
    }
    if (elapsed + _frameRateTolerance < _nextFrameTarget) return;
    final minInterval = Duration(microseconds: (1e6 / cap).round());
    final candidate = _nextFrameTarget + minInterval;
    _nextFrameTarget = candidate > elapsed ? candidate : elapsed + minInterval;
    _repaint.refresh();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _keyboardFocusNode.requestFocus();
    widget.sketch.flut5.events.addPointerDown(event);
  }

  /// Init sketch vars and call the setup.
  Future<void> setupCanvasSketch(double width, double height) async {
    // Mark this sketch's engine as the running one so Flut5 helper classes
    // constructed inside setup() adopt it (global mode).
    Flut5Engine.current = widget.sketch.flut5;

    // Set the size of the sketch
    widget.sketch.flut5.environment = widget.sketch.flut5.environment.withSize(
      Size(width, height),
    );

    // Drop any leftover trail snapshot so setup() / hot reload starts clean.
    widget.sketch.flut5.clearFrameSnapshot();

    // Inject props before setup runs so they are accessible as `this.props`
    widget.sketch.props = widget.props ?? const {};

    // Provide a valid dummy canvas for setup() so drawing/transform commands don't crash
    final recorder = ui.PictureRecorder();
    widget.sketch.flut5.canvas = Canvas(recorder);

    // Reset UI elements before setup so repeated setup runs, such as hot reload,
    // do not duplicate sketch-owned controls.
    widget.sketch.flut5.ui.clear();
    // Same for physics bodies registered by a previous setup run.
    widget.sketch.flut5.physicsEngine.clear();

    // Preload pubspec-registered font shape data before user setup so
    // textFont('Family') can drive both raster text and textToPoints/contours.
    await widget.sketch.flut5.preloadRegisteredFonts();

    // Call the setup of the sketch — supports both sync and async overrides
    await widget.sketch.setup();
    widget.sketch.isReady = true;

    // Flush any warnings queued during setup() — printed once before first frame
    Flut5Console.flush();

    // Release the dummy recorder's native resources
    recorder.endRecording().dispose();

    // Persist setup-time draws as a snapshot. Drawing calls in setup() (e.g.
    // background(Colors.blue)) enqueue render items. Without this, the first
    // paint frame would execute and clear them; if draw() is empty, every
    // subsequent frame paints nothing and the canvas appears blank.
    _captureSetupSnapshot(width, height);
  }

  void _captureSetupSnapshot(double width, double height) {
    final engine = widget.sketch.flut5;
    final queue = engine.renderQueue;
    if (queue.isEmpty) return;

    final dpr = Flut5Painter._effectiveDevicePixelRatio(
      engine.devicePixelRatio,
    );
    // Apply the same longest-edge cap (and adaptive resolution lever) as
    // the per-frame capture path so a setup-time snapshot on a large HiDPI
    // canvas isn't rasterized at full physical resolution only to be
    // replaced by a cheaper one a frame later.
    final baseCaptureScale = Flut5Painter._captureScale(
      width,
      height,
      dpr,
      engine.frameSnapshotMaxResolution,
      engine.frameSnapshotCalibratedFactor,
      maxPixels: engine.frameSnapshotMaxPixels,
    );
    var captureScale = baseCaptureScale;
    if (engine.adaptiveSnapshotThrottle) {
      final floorScale = Flut5Painter._floorCaptureScale(
        baseCaptureScale,
        width > height ? width : height,
        engine.frameSnapshotMinResolution,
      );
      captureScale = baseCaptureScale * engine.frameSnapshotResolutionScale;
      if (captureScale < floorScale) captureScale = floorScale;
    }
    final pw = Flut5Painter._physicalExtent(width, captureScale);
    final ph = Flut5Painter._physicalExtent(height, captureScale);
    // Use independent X/Y scales derived from the rounded physical extents so
    // logical→physical mapping is pixel-exact in both axes — a single shared
    // scale would leave a fractional remainder on whichever axis didn't land
    // on a whole number, which manifests as cumulative resampling drift in
    // the trail snapshot path. (Pure correctness; same GPU cost.)
    final scaleX = pw / width;
    final scaleY = ph / height;

    final recorder = ui.PictureRecorder();
    final c = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, pw.toDouble(), ph.toDouble()),
    );
    if (scaleX != 1.0 || scaleY != 1.0) c.scale(scaleX, scaleY);
    queue.execute(c);
    final picture = recorder.endRecording();
    engine.setFrameSnapshot(picture.toImageSync(pw, ph), Size(width, height));
    picture.dispose();
    queue.clear();
  }

  /// Schedules and calls the setup of the sketch and inits basic vars.
  /// uses addPostFrameCallback to run setup after the initial and current paint of the widget. this prevents render and paint conflicts.
  void scheduleCanvasSetup(double width, double height) {
    if (!_setupScheduled) {
      _setupScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await setupCanvasSketch(width, height);
      });
    }
  }

  /// Determines the finite canvas dimensions based on the parent's constraints.
  /// If the parent allows infinite size (e.g., inside a scrolling widget like [ListView]),
  /// it falls back to the screen size.
  Size _resolveDimensions(BuildContext context, BoxConstraints constraints) {
    // 1. Get the maximum possible dimensions from the parent widget
    double width = constraints.maxWidth;
    double height = constraints.maxHeight;

    // 2. Handle unbounded (infinite) constraints (e.g., inside a ListView or Column)
    // A canvas needs a finite size, so we fall back to the actual screen size using MediaQuery
    if (width == double.infinity || height == double.infinity) {
      final mq = MediaQuery.maybeSizeOf(context) ?? Size.zero;
      if (width == double.infinity) width = mq.width;
      if (height == double.infinity) height = mq.height;
    }
    return Size(width, height);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _resolveDimensions(context, constraints);
        final width = size.width;
        final height = size.height;

        // Wait for the layout to settle. If size is 0, setup() would fail or cause errors.
        if (width == 0 || height == 0) {
          return const SizedBox.shrink(); // Wait until we have a real size!
        }

        if (_previousSize != Size.zero &&
            _previousSize != size &&
            widget.sketch.isReady) {
          final psize = _previousSize;

          // Pre-update the engine dimensions before firing the event
          widget.sketch.flut5.environment = widget.sketch.flut5.environment
              .withSize(size);

          // Default behaviour: drop the trail snapshot on resize so the
          // next frame starts a fresh accumulation at the new size.
          // Sketches that want trails preserved across drags can opt in
          // via `engine.preserveSnapshotOnResize = true`, in which case
          // the painter anchors the existing snapshot at top-left at its
          // original logical size.
          if (!widget.sketch.flut5.preserveSnapshotOnResize) {
            widget.sketch.flut5.clearFrameSnapshot();
          }

          widget.sketch.flut5.events.addResize(ResizeEvent(psize, size));
        }
        _previousSize = size;

        // Sync DPR each build so trail snapshots capture at native resolution.
        final devicePixelRatio =
            MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
        if (widget.sketch.flut5.devicePixelRatio != devicePixelRatio) {
          widget.sketch.flut5.clearFrameSnapshot();
        }
        widget.sketch.flut5.devicePixelRatio = devicePixelRatio;

        scheduleCanvasSetup(width, height);

        if (widget.child != null) _maybeNoteChildInput();

        return KeyboardListener(
          focusNode: _keyboardFocusNode,
          autofocus: true,
          onKeyEvent: widget.sketch.flut5.events.addKeyEvent,
          child: ListenableBuilder(
            listenable: widget.sketch.flut5.ui,
            // This child is cached — it does NOT rebuild when Flut5UI notifies
            child: ValueListenableBuilder<MouseCursor>(
              valueListenable: widget.sketch.flut5.cursorNotifier,
              child: Listener(
                onPointerDown: _handlePointerDown,
                onPointerHover: widget.sketch.flut5.events.addPointerHover,
                onPointerUp: widget.sketch.flut5.events.addPointerUp,
                onPointerMove: widget.sketch.flut5.events.addPointerMove,
                onPointerCancel: widget.sketch.flut5.events.addPointerCancel,
                onPointerSignal: widget.sketch.flut5.events.addPointerScroll,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Trail layer: cached snapshot blit, repaints only when
                    // engine.trailRepaint fires. No-ops when
                    // useLayeredTrails is false, so the legacy single-painter
                    // path works unchanged.
                    RepaintBoundary(
                      child: CustomPaint(
                        size: Size(width, height),
                        painter: _trailPainter,
                      ),
                    ),
                    // Foreground layer: runs sketch.draw() every frame.
                    RepaintBoundary(
                      child: CustomPaint(
                        size: Size(width, height),
                        painter: _painter,
                      ),
                    ),
                  ],
                ),
              ),
              builder: (context, cursor, child) {
                return MouseRegion(cursor: cursor, child: child);
              },
            ),
            builder: (context, canvas) {
              return Flut5UIScope(
                transitionDuration: Duration(
                  milliseconds: widget.sketch.flut5.ui.transitionMs,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: [
                    // Base layer: cached canvas (not rebuilt)
                    canvas!,
                    // Overlay layer: sits above the painters but OUTSIDE the
                    // pointer Listener, so a gesture starting on an overlay
                    // widget belongs to that widget and is never also
                    // delivered to the sketch. Positioned with explicit
                    // extents rather than Positioned.fill so it matches the
                    // painters exactly, including the unbounded-constraints
                    // path where _resolveDimensions falls back to MediaQuery.
                    // Positioned children never influence Stack sizing, so the
                    // canvas box is unaffected by whatever is passed here.
                    if (widget.child != null)
                      Positioned(
                        left: 0,
                        top: 0,
                        width: width,
                        height: height,
                        child: widget.child!,
                      ),
                    // UI layer: only this part rebuilds on notification.
                    // Stays on top — sketch-owned controls outrank app chrome.
                    ...widget.sketch.flut5.ui.elements.map(
                      (e) => e.build(context),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// The internal [CustomPainter] that executes the sketch's drawing commands.
///
/// Listens to the repaint notifier to draw continuously each frame.
class Flut5Painter({required final Flut5Sketch sketch, super.repaint})
    extends CustomPainter {
  /// Reused for [Canvas.drawImageRect] of the trail snapshot. Quality is
  /// resolved per blit by [Flut5Engine.effectiveFrameSnapshotFilterQuality]:
  /// bilinear at 1:1 and mild upscales (calm on rotating thin shapes),
  /// bicubic past ~1.4× where softness dominates, or the explicit
  /// [Flut5Engine.frameSnapshotFilterQuality] if one was assigned.
  static final Paint _blitPaint = Paint()..filterQuality = FilterQuality.low;

  /// Cached HUD text layout. [_paintSnapshotHud] rebuilds the [TextPainter]
  /// only when the rendered string actually changes — the HUD's numbers move
  /// at most once per capture, but `paint` runs every frame, and
  /// `TextPainter.layout()` shapes glyphs on each call. Rebuilding it per
  /// frame made the diagnostic overlay a measurable share of the very frame
  /// cost it exists to report.
  String? _hudText;
  TextPainter? _hudTextPainter;

  /// Pictures recorded last frame, released at the top of the next [paint].
  /// See [_deferPictureDispose]. Bounded by the number of pictures one frame
  /// can record (at most the trail picture plus its foreground).
  final List<ui.Picture> _pendingDispose = <ui.Picture>[];

  /// Guards the one-time debug-build advice in [_maybeAdviseTrailBuildMode].
  /// Static so it fires once per session rather than once per canvas, and
  /// never per frame.
  static bool _trailBuildModeAdviceShown = false;

  /// Whether the translucent-background build-mode advice has fired this
  /// session. Test-only seam.
  @visibleForTesting
  static bool get debugTrailBuildModeAdviceShown => _trailBuildModeAdviceShown;

  /// Re-arms the one-time translucent-background advice so a following test
  /// can observe it fire again.
  @visibleForTesting
  static void debugResetTrailBuildModeAdvice() {
    _trailBuildModeAdviceShown = false;
  }

  /// Prints one-time guidance when a sketch runs the trail-snapshot path in a
  /// debug build.
  ///
  /// A translucent `background()` puts every frame through snapshot capture —
  /// the most expensive path in the engine — and debug is the worst place to
  /// judge it: unoptimized Dart, and on web the DDC compiler rather than
  /// dart2js. A sketch that feels heavy here can be entirely comfortable
  /// shipped, so without this note the natural response is to tune quality
  /// down against a number that was never real.
  void _maybeAdviseTrailBuildMode() {
    if (!kDebugMode || _trailBuildModeAdviceShown) return;
    _trailBuildModeAdviceShown = true;
    final advice = StringBuffer(
      'Flut5: in debug, a translucent background() captures the background '
      'trail at lower resolution and may run slower. A release build usually '
      'fixes both.',
    );
    // Not on a WasmGC build — suggesting the flag you already compiled with
    // is noise. Both are compile-time constants, so this branch disappears
    // from every build that isn't debug web-on-JS.
    if (kIsWeb && !kIsWasm) {
      advice.write(' If it persists, try `flutter build web --wasm`.');
    }
    Flut5Console.printLater(advice.toString());
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!sketch.isReady) return;

    final width = size.width;
    final height = size.height;
    if (width <= 0 || height <= 0) return;

    final engine = sketch.flut5;
    // Last frame's pictures have been composited by now; release them before
    // recording anything new so at most one frame's worth is ever alive.
    _flushDeferredDisposals();
    // Refresh the global-mode singleton alongside the canvas so helpers
    // constructed during this sketch's draw() adopt the right engine even
    // when multiple canvases are alive.
    Flut5Engine.current = engine;
    engine.canvas = canvas;
    if (engine.environment.size != size) {
      engine.environment = engine.environment.withSize(size);
      // Capture cost scales with canvas area, so a measurement taken at the
      // old size says nothing about the new one. Resizing already drops the
      // trail by default, so re-searching costs nothing to trail quality.
      engine.resetSnapshotCalibration();
    }

    // Update frame timing before draw()
    final now = DateTime.now().millisecondsSinceEpoch;
    engine.environment = engine.environment.nextFrame(now);
    // Age the displayed snapshot by one frame (reset whenever a fresh capture
    // lands, so smoothTrailFade always knows how far the visible trail has
    // fallen behind the fade it should be showing) and fold this frame into
    // the smoothed rate the HUD reports.
    engine.noteFramePainted();

    final physics = engine.physicsEngine;
    if (physics.updateTiming == .beforeDraw) physics.update();
    sketch.draw();
    if (physics.updateTiming == .afterDraw) physics.update();

    // Close any layout scopes draw() left open (missing endLayout()) — this
    // also closes the containers belonging to them — then any remaining
    // container scopes (missing endContainer()). Layouts go first because
    // endContainer() refuses to close a container from outside a still-open
    // layout. Both must run before the wheel / pointer buffers are cleared so
    // the forced endContainer() still sees this frame's input.
    engine.closeUnbalancedLayouts();
    engine.closeUnbalancedContainers();

    // A buffered wheel sample drives scroll-mode containers for exactly one
    // frame; clear it now that draw() has read it.
    engine.events.clearPendingWheel();

    // Per-frame pointer events are dispatched to container callbacks during
    // draw(); drain them so each is delivered exactly once.
    engine.events.clearPendingPointerEvents();

    final queue = engine.renderQueue;
    final snapshot = engine.frameSnapshot;
    final snapshotLogicalSize = engine.frameSnapshotLogicalSize;
    final dpr = _effectiveDevicePixelRatio(engine.devicePixelRatio);
    final currentLogicalSize = Size(width, height);
    // Three factors, three scales. The ceiling is what startup calibration is
    // allowed to climb to; the calibrated factor is where it settled (the
    // floor until it finds the device can afford more); the floor is the
    // resolution the sketch is guaranteed regardless.
    final baseCaptureScale = _captureScale(
      width,
      height,
      dpr,
      engine.frameSnapshotMaxResolution,
      engine.frameSnapshotResolutionFactorMax,
      maxPixels: engine.frameSnapshotMaxPixels,
    );
    final calibratedScale = _captureScale(
      width,
      height,
      dpr,
      engine.frameSnapshotMaxResolution,
      engine.frameSnapshotCalibratedFactor,
      maxPixels: engine.frameSnapshotMaxPixels,
    );
    var floorScale = _captureScale(
      width,
      height,
      dpr,
      engine.frameSnapshotMaxResolution,
      engine.frameSnapshotResolutionFactor,
      maxPixels: engine.frameSnapshotMaxPixels,
    );
    // Calibration settles the resolution; the overload throttle can still
    // pull below it, but never below the guaranteed floor — nor below the
    // absolute frameSnapshotMinResolution guarantee, which applies only on
    // this path. Cadence (and with it the smooth per-frame fade) is
    // sacrificed only once this lever is exhausted.
    var captureScale = calibratedScale;
    if (engine.adaptiveSnapshotThrottle) {
      final absoluteFloor = _floorCaptureScale(
        baseCaptureScale,
        width > height ? width : height,
        engine.frameSnapshotMinResolution,
      );
      if (absoluteFloor > floorScale) floorScale = absoluteFloor;
      if (floorScale > baseCaptureScale) floorScale = baseCaptureScale;
      captureScale = calibratedScale * engine.frameSnapshotResolutionScale;
      if (captureScale < floorScale) captureScale = floorScale;
    }
    final physicalWidth = _physicalExtent(width, captureScale);
    final physicalHeight = _physicalExtent(height, captureScale);

    final layered = engine.useLayeredTrails;

    if (queue.isEmpty) {
      // Nothing changed; redraw the existing trail image without recapturing it.
      // In layered mode the dedicated [_TrailPainter] handles the blit, so the
      // foreground stays blank to avoid drawing the snapshot twice.
      if (!layered && snapshot != null) {
        _drawSnapshot(
          canvas,
          snapshot,
          snapshotLogicalSize ?? currentLogicalSize,
          dpr,
        );
      }
    } else if (queue.lastBackgroundIsOpaqueFullCanvas) {
      // A final opaque full-canvas background makes older trail pixels
      // irrelevant. Paint directly and drop the snapshot. (In layered mode the
      // opaque fill covers the trail layer beneath; clearFrameSnapshot fires
      // the trail-repaint notifier so the cached trail layer goes blank.)
      queue.execute(canvas);
      engine.clearFrameSnapshot();
    } else {
      // Translucent full-canvas fill: the trail path is live, so in a debug
      // build say once that this is not where to judge its cost.
      if (queue.trailFadeColor != null) _maybeAdviseTrailBuildMode();

      final previousSnapshot = queue.hasOpaqueFullCanvasBackground
          ? null
          : snapshot;
      final previousSnapshotLogicalSize = previousSnapshot == null
          ? null
          : (snapshotLogicalSize ?? currentLogicalSize);

      // Decide whether this frame actually rebuilds the snapshot *before*
      // recording anything — the recorded picture is consumed only by
      // toImage(), so on a non-capture frame it would be pure waste. Gates:
      //   1. interval — only frames on the snapshot tick recapture.
      //   2. in-flight throttle — at most one async capture pending at a time
      //      so toImage futures don't pile up if rasterization is slower than
      //      the frame rate; the displayed frame is still composed correctly.
      // (A third gate — the epoch check in completeFrameSnapshotCapture —
      // discards stale results if clearFrameSnapshot or a resolution change
      // happens mid-flight.)
      final interval = engine.effectiveFrameSnapshotInterval;
      final intervalTicks = interval <= 1 || engine.frameCount % interval == 0;
      final willCapture = intervalTicks && !engine.isFrameSnapshotInFlight;

      if (willCapture) {
        // Record (previousSnapshot + bg fade + shapes) at physical resolution:
        // the picture is both displayed and async-rasterized into the next
        // snapshot. Derive independent X/Y scales from the rounded physical
        // extents — a single shared scale leaves a fractional remainder on
        // whichever axis doesn't round cleanly (e.g. 16:9 logical at a 1380
        // longest-edge cap gives physical 1380×776 but height*scale = 776.25),
        // which compounds into vertical trail-spread over many rebuilds.
        final scaleX = physicalWidth / width;
        final scaleY = physicalHeight / height;

        // Layered display draws the foreground alone, so without this the same
        // item list is walked twice on every capture frame — once into the
        // recording, once onto the screen. Record it once into a logical-space
        // picture and replay that into both targets, halving the Dart-side
        // dispatch on capture frames (the dominant cost in debug JIT, where
        // each item.execute is a megamorphic call).
        //
        // Only valid while every background precedes all content: the split
        // runs backgrounds as a group ahead of the foreground, which reorders
        // a frame that interleaves them. Otherwise fall back to two replays.
        final splitReplay = layered && queue.backgroundsPrecedeContent;
        final foreground = splitReplay
            ? _recordForegroundPicture(queue, currentLogicalSize)
            : null;

        final picture = _recordPhysicalTrailPicture(
          queue: queue,
          previousSnapshot: previousSnapshot,
          previousSnapshotLogicalSize: previousSnapshotLogicalSize,
          scaleX: scaleX,
          scaleY: scaleY,
          physicalWidth: physicalWidth,
          physicalHeight: physicalHeight,
          foreground: foreground,
        );
        if (layered) {
          // Foreground display = shapes only (the trail layer beneath shows the
          // snapshot, which itself incorporates the bg fade at rebuild time).
          // The recorded picture is used purely for the snapshot rebuild.
          _paintLayeredForeground(canvas, engine, queue, foreground);
        } else {
          // Legacy path: display is the full recorded picture (snapshot blit +
          // bg fade + shapes), guaranteeing the on-screen pixels match what the
          // next snapshot will contain even when rebuilds lag.
          _drawPhysicalPicture(canvas, picture, scaleX, scaleY);
        }
        engine.beginFrameSnapshotCapture(
          physicalWidth,
          physicalHeight,
          appliedResolutionRatio: captureScale / baseCaptureScale,
          floorResolutionRatio: floorScale / baseCaptureScale,
        );
        final epoch = engine.frameSnapshotEpoch;
        final pictureRef = picture;
        // Both pictures were just drawn into this frame's layer tree, so their
        // disposal is deferred to the next paint rather than run inline —
        // the engine refcounts the underlying display lists, but outliving the
        // frame that composited them removes the question entirely.
        _deferPictureDispose(foreground);
        if (engine.useSyncSnapshotCapture) {
          // toImageSync returns a handle immediately and leaves the raster
          // thread to fill it during this frame: no async round-trip, so the
          // snapshot is current next frame instead of lagging one or more.
          // The in-flight gate never trips here — begin/complete both land in
          // this frame — which is exactly the backpressure being traded away.
          ui.Image? image;
          try {
            image = pictureRef.toImageSync(physicalWidth, physicalHeight);
          } catch (_) {
            image = null;
          }
          _deferPictureDispose(pictureRef);
          engine.completeFrameSnapshotCapture(
            image,
            currentLogicalSize,
            epoch,
            // The elapsed span covers the handle allocation, not the deferred
            // rasterization — a near-zero reading the throttle must not see.
            recordCost: false,
          );
        } else {
          // Capture asynchronously so the UI thread isn't blocked on rasterize.
          // Net effect: the trail lags an extra frame or two, but the per-frame
          // cost of rasterizing the snapshot is moved to the raster thread.
          pictureRef
              .toImage(physicalWidth, physicalHeight)
              .then((image) {
                pictureRef.dispose();
                engine.completeFrameSnapshotCapture(
                  image,
                  currentLogicalSize,
                  epoch,
                );
              })
              .catchError((Object _) {
                pictureRef.dispose();
                engine.completeFrameSnapshotCapture(
                  null,
                  currentLogicalSize,
                  epoch,
                );
              });
        }
      } else {
        // No snapshot rebuild this frame — composite straight to the screen
        // canvas instead of recording a physical-resolution picture we'd only
        // throw away. Pixel-identical to the willCapture display paths, minus
        // the PictureRecorder/Picture allocation and the extra queue replay.
        if (layered) {
          // The trail layer already shows the cached snapshot; the foreground
          // is the shapes only — plus, under smoothTrailFade, the synthetic
          // fill that advances the fade on frames that never recapture.
          _paintLayeredForeground(canvas, engine, queue, null);
        } else {
          // Blit the carried-over snapshot, then draw this frame's items
          // (background fade + shapes) on top — the same content the recorded
          // picture would have held.
          if (previousSnapshot != null) {
            _drawSnapshot(
              canvas,
              previousSnapshot,
              previousSnapshotLogicalSize!,
              dpr,
            );
          }
          queue.execute(canvas);
        }
        // A frame on the interval tick that couldn't capture (a previous
        // rasterize is still in flight) counts as a drop and feeds the
        // adaptive throttle; a frame simply off the tick does not.
        if (intervalTicks) engine.noteFrameSnapshotDropped();
      }
    }

    queue.clear();

    if (engine.showFrameSnapshotDebug) {
      _paintSnapshotHud(canvas, engine);
    }

    // Flush deferred console warnings accumulated during draw()
    Flut5Console.flush();
  }

  /// Paints a small corner HUD with snapshot timing/size info. Only invoked
  /// when [Flut5Engine.showFrameSnapshotDebug] is true.
  void _paintSnapshotHud(Canvas canvas, Flut5Engine engine) {
    final ms = engine.frameSnapshotLastCaptureMs;
    final size = engine.frameSnapshotLastPhysicalSize;
    final effective = engine.effectiveFrameSnapshotInterval;
    final configured = engine.frameSnapshotInterval;
    final intervalLine = configured == effective
        ? 'interval $configured'
        : 'interval $configured → $effective';
    final resScale = engine.frameSnapshotResolutionScale;
    // Only show the adaptive scale while the throttle is actually applying
    // it — with the throttle off the painter captures at full configured
    // resolution regardless of the stored scale.
    final showScale = engine.adaptiveSnapshotThrottle && resScale < 1.0;

    // Frame budget the raster load is measured against — the same target the
    // engine uses, so the percentage answers "does capture fit in a frame at
    // the rate I asked for".
    final target = engine.frameRateCap ?? 60.0;
    final budgetMs = target > 0 ? 1000.0 / target : 0.0;
    final costEma = engine.frameSnapshotCostEmaMs;
    final load = engine.frameSnapshotRasterLoad;
    final fps = engine.smoothedFrameRate;

    // The resolution dial as it currently stands — the calibrated factor, not
    // the configured floor — shown only when it's actually cutting, since at
    // 1.0 it explains nothing about the number beside it. When an absolute cap
    // binds, even that isn't what the painter captured at, so show both rather
    // than let the knob misreport itself (same `→ effective` shape as the
    // interval line).
    final activeFactor = engine.frameSnapshotCalibratedFactor;
    final effectiveFactor = engine.effectiveFrameSnapshotResolutionFactor;
    final factorCapped = effectiveFactor < activeFactor - 0.005;
    final factorSuffix = activeFactor >= 1.0 && !factorCapped
        ? ''
        : factorCapped
        ? ' f${activeFactor.toStringAsFixed(2)}'
              ' → ${effectiveFactor.toStringAsFixed(2)}'
              ' ${engine.frameSnapshotCapBinding ?? ''}'
        : ' f${activeFactor.toStringAsFixed(2)}';

    // Calibration line, shown only when a search is configured at all (floor
    // below ceiling). While running it reports where the climb has reached;
    // once locked it reports the settled rung, so a surprising steady-state
    // resolution can be traced back to the measurement that chose it.
    final floor = engine.frameSnapshotResolutionFactor;
    final ceiling = engine.frameSnapshotResolutionFactorMax;
    final calibrationActive = ceiling > floor + 1e-6;
    final calibrationLine = engine.frameSnapshotCalibrating
        ? 'calibrating ${engine.frameSnapshotCalibratedFactor.toStringAsFixed(2)}'
              ' ↗ ${ceiling.toStringAsFixed(2)}'
        : 'calibrated ${engine.frameSnapshotCalibratedFactor.toStringAsFixed(2)}'
              ' of ${floor.toStringAsFixed(2)}–${ceiling.toStringAsFixed(2)}'
              // Why it stopped. A factor resting on the floor is ambiguous
              // without this: "climbed and this was the best fit" and "never got
              // off the floor because even that is over budget" look identical.
              '${engine.frameSnapshotCalibrationOutcome == null ? '' : ' (${engine.frameSnapshotCalibrationOutcome})'}';

    final lines = <String>[
      'snapshot ${ms == null ? '—' : '${ms.toStringAsFixed(1)} ms'}'
          '${costEma == null ? '' : ' (ema ${costEma.toStringAsFixed(1)})'}',
      // The headline number: capture cost amortized over the capture cadence,
      // as a share of one frame. Past 100% the raster thread cannot keep up
      // regardless of anything on the Dart side.
      //
      // The trailing limit is frameSnapshotBudgetMs expressed in the same
      // units. Without it the reading has no scale — the measured share is
      // against the whole frame while the budget is a slice of it, so how
      // close you are to the point where calibration stops climbing was left
      // as arithmetic for the reader.
      'raster ${load == null ? '—' : '${(load * 100).round()}%'}'
          ' of ${budgetMs.toStringAsFixed(1)} ms'
          '${budgetMs > 0 ? ' · limit ${(engine.frameSnapshotBudgetMs / budgetMs * 100).round()}%' : ''}',
      'fps ${fps == null ? '—' : fps.toStringAsFixed(0)}'
          ' / cap ${engine.frameRateCap == null ? '—' : target.toStringAsFixed(0)}',
      'res ${size == null ? '—' : '${size.$1}×${size.$2}'}'
          '${showScale ? ' ×${resScale.toStringAsFixed(2)}' : ''}'
          '$factorSuffix',
      'dropped ${engine.frameSnapshotDroppedCount}',
      intervalLine,
      if (calibrationActive) calibrationLine,
      'throttle ${engine.adaptiveSnapshotThrottle ? 'auto' : 'manual'}',
      'layered ${engine.useLayeredTrails}',
      'capture ${engine.useSyncSnapshotCapture ? 'sync' : 'async'}',
      if (engine.useLayeredTrails)
        'fade ${engine.smoothTrailFade ? 'smooth +${engine.framesSinceSnapshotApplied}' : 'stepped'}',
    ];
    // Re-shape only when the text changed; otherwise reuse last frame's
    // layout. The HUD is on precisely when frame cost is being measured, so
    // it must not add per-frame glyph shaping to the number it reports.
    final text = lines.join('\n');
    var tp = _hudTextPainter;
    if (tp == null || _hudText != text) {
      tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 11,
            fontFamily: 'monospace',
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      _hudTextPainter = tp;
      _hudText = text;
    }
    const pad = 6.0;
    final boxRect = Rect.fromLTWH(
      8,
      8,
      tp.width + pad * 2,
      tp.height + pad * 2,
    );
    // Tint the panel once capture stops fitting in a frame, so the state that
    // actually caps the frame rate is visible at a glance instead of needing
    // the percentage to be read.
    final overBudget = load != null && load > 1.0;
    canvas.drawRect(
      boxRect,
      Paint()
        ..color = overBudget
            ? const Color(0xCC7A1020)
            : const Color(0xAA000000),
    );
    tp.paint(canvas, Offset(boxRect.left + pad, boxRect.top + pad));
  }

  ui.Picture _recordPhysicalTrailPicture({
    required Flut5RenderQueue queue,
    required ui.Image? previousSnapshot,
    required Size? previousSnapshotLogicalSize,
    required double scaleX,
    required double scaleY,
    required int physicalWidth,
    required int physicalHeight,
    ui.Picture? foreground,
  }) {
    final recorder = ui.PictureRecorder();
    final c = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, physicalWidth.toDouble(), physicalHeight.toDouble()),
    );
    if (scaleX != 1.0 || scaleY != 1.0) {
      c.scale(scaleX, scaleY);
    }
    if (previousSnapshot != null && previousSnapshotLogicalSize != null) {
      // Capture space: the canvas is scaled by scaleX/scaleY, so the blit
      // lands at snapshot resolution (1:1) and resolves to bilinear.
      _drawSnapshot(c, previousSnapshot, previousSnapshotLogicalSize, scaleX);
    }
    if (foreground == null) {
      queue.execute(c);
    } else {
      // Split replay: the caller already confirmed every background precedes
      // all content, so backgrounds-as-a-group then the pre-recorded
      // foreground reproduces execute()'s ordering. The foreground was
      // recorded in logical space and this canvas carries the physical scale,
      // so it lands at capture resolution like the inline replay would.
      queue.executeBackground(c);
      c.drawPicture(foreground);
    }
    return recorder.endRecording();
  }

  /// Records the frame's non-background items once, in logical space, so the
  /// same list needn't be walked separately for the snapshot recording and
  /// the on-screen foreground. See the `splitReplay` branch in [paint].
  ///
  /// [logicalSize] becomes the recording's cull rect. Recording without one
  /// leaves the picture unbounded, which costs the culling the inline replay
  /// used to get from the destination canvas's own bounds — the reason this
  /// takes a size rather than using the no-cull-rect `Canvas` constructor.
  ui.Picture _recordForegroundPicture(
    Flut5RenderQueue queue,
    Size logicalSize,
  ) {
    final recorder = ui.PictureRecorder();
    final c = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, logicalSize.width, logicalSize.height),
    );
    queue.executeForeground(c);
    return recorder.endRecording();
  }

  /// Draws the layered-mode foreground: the synthetic trail fade (when
  /// [Flut5Engine.smoothTrailFade] is on) beneath this frame's shapes, taken
  /// either from a pre-recorded [foreground] picture or by replaying the
  /// queue inline when there is none.
  void _paintLayeredForeground(
    Canvas canvas,
    Flut5Engine engine,
    Flut5RenderQueue queue,
    ui.Picture? foreground,
  ) {
    _drawSyntheticTrailFade(canvas, engine, queue);
    if (foreground != null) {
      canvas.drawPicture(foreground);
    } else {
      queue.executeForeground(canvas);
    }
  }

  /// Advances the *visible* trail fade on frames where the snapshot beneath
  /// hasn't been rebuilt, so the fade stops stepping at capture cadence.
  ///
  /// The trail layer shows a snapshot containing every fade up to its own
  /// capture. After `k` further frames it should look `k` fades further
  /// along, which for a per-frame alpha `a` composites to `1 - (1 - a)^k` of
  /// the fade color — one `drawColor` regardless of how large `k` grows. At
  /// `k == 0` (a snapshot that just landed) the term is zero and nothing is
  /// drawn, so the real fade in the snapshot is never double-counted.
  void _drawSyntheticTrailFade(
    Canvas canvas,
    Flut5Engine engine,
    Flut5RenderQueue queue,
  ) {
    if (!engine.smoothTrailFade) return;
    // Nothing on the trail layer to fade toward the background color.
    if (engine.frameSnapshot == null) return;
    final fade = queue.trailFadeColor;
    if (fade == null) return;
    final k = engine.framesSinceSnapshotApplied;
    if (k <= 0) return;
    final residual = math.pow(1.0 - fade.a, k).toDouble();
    final compounded = 1.0 - residual;
    if (compounded <= 0.0) return;
    canvas.drawColor(
      fade.withValues(alpha: compounded.clamp(0.0, 1.0)),
      BlendMode.srcOver,
    );
  }

  /// Queues [picture] for disposal at the start of the next [paint].
  ///
  /// Pictures handed here have already been drawn into the current frame's
  /// layer tree. The engine refcounts the underlying display list, so an
  /// inline `dispose()` is believed safe — deferring one frame simply makes
  /// that irrelevant. At most one picture per slot is held, and the previous
  /// occupant is released as the new one arrives.
  void _deferPictureDispose(ui.Picture? picture) {
    if (picture == null) return;
    _pendingDispose.add(picture);
  }

  /// Releases pictures retained by [_deferPictureDispose] on the previous
  /// frame. Called once at the top of [paint], before anything new is
  /// recorded.
  void _flushDeferredDisposals() {
    if (_pendingDispose.isEmpty) return;
    for (final picture in _pendingDispose) {
      picture.dispose();
    }
    _pendingDispose.clear();
  }

  void _drawPhysicalPicture(
    Canvas canvas,
    ui.Picture picture,
    double scaleX,
    double scaleY,
  ) {
    if (scaleX == 1.0 && scaleY == 1.0) {
      canvas.drawPicture(picture);
      return;
    }
    canvas.save();
    canvas.scale(1 / scaleX, 1 / scaleY);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  /// Blits [snapshot] anchored at the top-left, sized to [logicalSize] —
  /// the canvas dimensions at the time the snapshot was captured. When
  /// the canvas has since been resized, this preserves trail content in
  /// place: a wider canvas leaves new pixels uncovered (filled by future
  /// draws), a smaller canvas clips the snapshot at the cull rect. Avoids
  /// the visual flash of a hard clear and the distortion of stretching.
  ///
  /// [destScale] is the destination's pixels-per-logical-unit (display DPR
  /// for screen blits, the capture scale inside snapshot recordings); it
  /// only feeds the upscale detection for the filter-quality choice.
  void _drawSnapshot(
    Canvas canvas,
    ui.Image snapshot,
    Size logicalSize,
    double destScale,
  ) {
    _blitPaint.filterQuality = sketch.flut5.effectiveFrameSnapshotFilterQuality(
      upscaleRatio: _blitUpscaleRatio(snapshot, logicalSize, destScale),
    );
    canvas.drawImageRect(
      snapshot,
      Rect.fromLTWH(
        0,
        0,
        snapshot.width.toDouble(),
        snapshot.height.toDouble(),
      ),
      Rect.fromLTWH(0, 0, logicalSize.width, logicalSize.height),
      _blitPaint,
    );
  }

  static double _effectiveDevicePixelRatio(double dpr) => dpr > 0 ? dpr : 1.0;

  /// Destination pixels per snapshot pixel when blitting [snapshot] onto a
  /// [logicalSize] × [destScale] rect — the larger of the two axis ratios.
  /// ~1.0 (or below) when the blit doesn't upscale.
  static double _blitUpscaleRatio(
    ui.Image snapshot,
    Size logicalSize,
    double destScale,
  ) {
    final rx = logicalSize.width * destScale / snapshot.width;
    final ry = logicalSize.height * destScale / snapshot.height;
    return rx > ry ? rx : ry;
  }

  /// The lowest capture scale the adaptive resolution throttle may pick:
  /// [minResolution] pixels on the longest edge, but never above
  /// [baseScale] (small canvases already capture below the floor and are
  /// left alone).
  static double _floorCaptureScale(
    double baseScale,
    double longestLogical,
    int minResolution,
  ) {
    if (longestLogical <= 0) return baseScale;
    final floor = minResolution / longestLogical;
    return floor < baseScale ? floor : baseScale;
  }

  /// Returns the scale to use when recording the snapshot picture.
  ///
  /// Three independent limits, tightest wins:
  ///
  /// 1. [resolutionFactor] — the window-relative quality dial, applied to the
  ///    device pixel ratio.
  /// 2. [maxResolution] — absolute ceiling on the longest physical edge,
  ///    which bounds how far the trail blit upscales (sharpness).
  /// 3. [maxPixels] — absolute ceiling on total physical pixels, which bounds
  ///    snapshot memory at any aspect ratio. Pixels grow with the *square* of
  ///    the scale, hence the square root.
  ///
  /// Keeping them separate matters: on a wide canvas the edge cap binds first
  /// and governs sharpness, while on a square one the edge cap alone would
  /// let memory run and the pixel budget takes over.
  static double _captureScale(
    double logicalWidth,
    double logicalHeight,
    double dpr,
    int? maxResolution,
    double resolutionFactor, {
    int? maxPixels,
  }) {
    var scale = resolutionFactor > 0 && resolutionFactor < 1
        ? dpr * resolutionFactor
        : dpr;
    final longestLogical = logicalWidth > logicalHeight
        ? logicalWidth
        : logicalHeight;
    if (maxResolution != null && maxResolution > 0 && longestLogical > 0) {
      final edgeCap = maxResolution / longestLogical;
      if (edgeCap < scale) scale = edgeCap;
    }
    final logicalArea = logicalWidth * logicalHeight;
    if (maxPixels != null && maxPixels > 0 && logicalArea > 0) {
      final areaCap = math.sqrt(maxPixels / logicalArea);
      if (areaCap < scale) scale = areaCap;
    }
    return scale;
  }

  static int _physicalExtent(double logicalExtent, double dpr) {
    final extent = (logicalExtent * dpr).round();
    return extent > 0 ? extent : 1;
  }

  @override
  bool shouldRepaint(covariant Flut5Painter oldDelegate) {
    return true;
  }
}

/// Companion painter for [Flut5Engine.useLayeredTrails]: blits the cached
/// [Flut5Engine.frameSnapshot] beneath the foreground [Flut5Painter] and
/// repaints only when the snapshot itself changes (via
/// [Flut5Engine.trailRepaint]). Returns early when layered trails are off so
/// the same widget tree works for both modes without an extra Stack swap.
class _TrailPainter(final Flut5Engine engine) extends CustomPainter {
  static final Paint _blitPaint = Paint()..filterQuality = FilterQuality.low;

  this : super(repaint: engine.trailRepaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (!engine.useLayeredTrails) return;
    final snapshot = engine.frameSnapshot;
    if (snapshot == null) return;
    final logicalSize = engine.frameSnapshotLogicalSize ?? size;
    final dpr = Flut5Painter._effectiveDevicePixelRatio(
      engine.devicePixelRatio,
    );
    _blitPaint.filterQuality = engine.effectiveFrameSnapshotFilterQuality(
      upscaleRatio: Flut5Painter._blitUpscaleRatio(snapshot, logicalSize, dpr),
    );
    canvas.drawImageRect(
      snapshot,
      Rect.fromLTWH(
        0,
        0,
        snapshot.width.toDouble(),
        snapshot.height.toDouble(),
      ),
      Rect.fromLTWH(0, 0, logicalSize.width, logicalSize.height),
      _blitPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _TrailPainter oldDelegate) =>
      oldDelegate.engine != engine;
}
