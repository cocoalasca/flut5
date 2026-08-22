import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/painting.dart' show EdgeInsets;

import '../math/flut5_vector.dart';
import '../shape/flut5_2d_primitives.dart';
import 'flut5_clip.dart';
import 'flut5_console.dart';
import 'flut5_event.dart';
import 'flut5_touch.dart';
import 'sketch_pointer_event.dart';
import 'flut5_transform.dart';
import 'flut5_wheel.dart';
import 'render/items/flut5_transform_render_item.dart';

/// How a [Flut5ContainerMixin.beginContainer] scope handles content drawn
/// outside its rectangular bounds.
///
/// * [hidden] — content outside the container rect is clipped away.
/// * [scroll] — content is still clipped to the container rect, but the
///   inner translate can be moved by dragging the pointer inside the
///   container, exposing content that would otherwise be hidden.
/// * [visible] — the background rect is still drawn, but no clip is
///   installed; inner content can spill past the container's bounds.
enum Flut5ContainerOverflow { hidden, scroll, visible }

/// How a [Flut5ContainerOverflow.scroll] container behaves when the user drags
/// its content past the edge of the content's bounding box.
///
/// The bounding box is computed every frame from everything drawn between
/// `beginContainer()` and `endContainer()` — including shapes at negative
/// coordinates or beyond the container's width/height, and content moved by
/// nested transforms.
///
/// * [free] — no limit; content can be dragged (and flung) infinitely far.
///   This was the original behavior before bound modes existed.
/// * [clamp] — the drag stops dead at the content edge; you can never scroll
///   past it, and fling momentum is killed on contact.
/// * [bounce] — the content rubber-bands past the edge while dragging, then
///   springs back to the edge when released (browser / iOS feel). Default.
enum Flut5ContainerOverscroll { free, clamp, bounce }

/// Which input(s) may pan a [Flut5ContainerOverflow.scroll] container.
///
/// This only affects **desktop** mouse input: touch drags always work, so on
/// mobile all three modes behave identically (there is no wheel there).
///
/// * [auto] — both the mouse-wheel / trackpad and pointer dragging scroll the
///   content. Default.
/// * [scroll] — only the wheel scrolls; mouse dragging is ignored (touch
///   dragging still works on mobile).
/// * [drag] — only dragging scrolls; the wheel is ignored.
enum Flut5ContainerOverscrollInput { auto, scroll, drag }

/// Direction a [Flut5ContainerMixin.beginLayout] scope flows the containers
/// opened inside it.
///
/// * [horizontal] — containers are placed left → right.
/// * [vertical] — containers are placed top → bottom.
enum Flut5LayoutDirection { horizontal, vertical }

/// Whether a [Flut5ContainerMixin.beginLayout] scope wraps its containers onto
/// new lines when they overflow the main axis — mirrors CSS `flex-wrap`.
///
/// The main-axis limit comes from the scope's bounds: the `w` / `h` passed to
/// `beginLayout()` (falling back to the enclosing container's declared size,
/// or the canvas edge as a last resort), or, for containers nested in a
/// layout, the parent container's own width / height — all shrunk by
/// [Flut5ContainerMixin.layoutPadding].
///
/// * [noWrap] — everything flows on a single line, even past the layout's
///   bounds. Default.
/// * [wrap] — a container that would overflow the main-axis limit starts a
///   new line, offset along the cross axis by the finished line's largest
///   cross extent plus the cross gap (see [Flut5ContainerMixin.layoutGap]).
/// * [wrapReverse] — like [wrap], but lines stack from the cross-axis end
///   back toward the start (bottom → top in a horizontal layout). Placement
///   is single-pass, so within a line each container is aligned to the
///   cross-axis end. Falls back to [wrap] when the scope's cross size is
///   unknown.
enum Flut5LayoutWrap { noWrap, wrap, wrapReverse }

/// How a [Flut5ContainerMixin.beginLayout] scope aligns containers along the
/// cross axis within their line — mirrors CSS `align-items`.
///
/// A line's cross size is its largest container ([wrap][Flut5LayoutWrap]
/// layouts have one line per row; unwrapped layouts are a single line).
/// Shorter containers are shifted within that line:
///
/// * [start] — hug the line's cross start (top in a horizontal layout).
///   Default.
/// * [center] — centered within the line.
/// * [end] — hug the line's cross end (bottom in a horizontal layout).
///
/// Under [Flut5LayoutWrap.wrapReverse] the cross axis flips, exactly as in
/// CSS: [start] hugs the bottom of the line, [end] the top.
enum Flut5LayoutAlign { start, center, end }

/// How a [Flut5ContainerMixin.beginLayout] scope distributes free main-axis
/// space among a line's containers — mirrors CSS `justify-content`.
///
/// Free space is the line's main-axis limit minus its content (including
/// gaps); when the limit is unknown (see [Flut5LayoutWrap]) or the line
/// overflows, everything behaves like [start].
///
/// * [start] — containers pack at the main start. Default.
/// * [center] — packed and centered.
/// * [end] — packed at the main end.
/// * [spaceBetween] — free space split evenly *between* containers.
/// * [spaceAround] — split so each container has equal space around it
///   (half-size margins at the line's edges).
/// * [spaceEvenly] — equal space between containers and at both edges.
enum Flut5LayoutJustify { start, center, end, spaceBetween, spaceAround, spaceEvenly }

/// Per-container persistent state used by [Flut5ContainerOverflow.scroll].
/// Lives across frames so the accumulated drag offset survives.
class _Flut5ContainerScrollState {
  double offsetX = 0;
  double offsetY = 0;

  /// Carried-over per-frame delta in px used to drive post-release momentum.
  /// Captured from the active pointer's smoothed velocity each frame while
  /// dragging, then decayed by the inertia factor after release.
  double velocityX = 0;
  double velocityY = 0;

  /// Pointer id currently driving the scroll, or `null` when idle.
  int? activePointerId;

  /// Pointer ids that have been visible to this container at least once while
  /// still pressed. Used so a touch that started *outside* the container and
  /// was dragged in does not get claimed mid-gesture.
  final Set<int> seenPointerIds = <int>{};
}

/// Read-only snapshot of a container opened by
/// [Flut5ContainerMixin.beginContainer], exposed through
/// [Flut5ContainerMixin.containerContext] /
/// [Flut5ContainerMixin.getContainerContext] while the container is open.
/// Gives the sketch the container's geometry and pointer state without it
/// needing to recompute anything.
///
/// Pointer state is scoped to the container: [pointerIsDown] and [touches]
/// only reflect pointers inside the container's bounds, and [pointerIsOver]
/// reports hover over those bounds — the container-local equivalents of the
/// sketch-wide `pointerIsDown` / `touches`.
///
/// [touches] positions are shifted to coordinates **local to the container's
/// top-left corner** — the same space draw calls between `beginContainer()`
/// and `endContainer()` operate in, where `(0, 0)` is the corner and the
/// container spans to `([width], [height])`.
/// [x] / [y] give the container's position in canvas coordinates for reference.
/// (Local touch coordinates do not account for the scroll offset applied in
/// [Flut5ContainerOverflow.scroll] mode.)
@immutable
class Flut5ContainerContext {
  /// Container's top-left x in canvas coordinates.
  final double x;

  /// Container's top-left y in canvas coordinates.
  final double y;

  /// Container width in pixels.
  final double width;

  /// Container height in pixels.
  final double height;

  /// Whether any pointer is currently pressed *inside* the container's bounds.
  /// The container-scoped equivalent of the sketch's `pointerIsDown`.
  final bool pointerIsDown;

  /// Whether the pointer is currently hovering *over* the container's bounds
  /// (position inside the rect; does not require a press). On touch devices
  /// this tracks the last known pointer position.
  final bool pointerIsOver;

  /// Current pointer x, local to the container's top-left corner — the sketch's
  /// `mouseX` shifted into container coordinates. Negative or beyond [width]
  /// when the pointer is outside the container (see [pointerIsOver]).
  final double mouseX;

  /// Current pointer y, local to the container's top-left corner. See [mouseX].
  final double mouseY;

  /// Average pointer velocity x-component (px / frame) over the last
  /// `avgMouseFrames` rendered frames — identical to the sketch's `avgMouseX`.
  /// A velocity, so it is not shifted by the container's position.
  final double avgMouseX;

  /// Average pointer velocity y-component (px / frame). See [avgMouseX].
  final double avgMouseY;

  /// Average pointer velocity (px / frame) as a 2D vector — the sketch's
  /// `avgMouse`. Useful for reading where the pointer is heading.
  final Flut5Vector avgMouse;

  /// Pointers currently pressed inside the container, with `x` / `y` / `px` /
  /// `py` shifted to coordinates local to the container's top-left corner.
  /// The container-scoped equivalent of the sketch's `touches`.
  final List<Flut5Touch> touches;

  const Flut5ContainerContext({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.pointerIsDown,
    required this.pointerIsOver,
    required this.mouseX,
    required this.mouseY,
    required this.avgMouseX,
    required this.avgMouseY,
    required this.avgMouse,
    required this.touches,
  });
}

/// Bookkeeping for one open layout scope, stacked so layouts nest. A frame is
/// pushed by [Flut5ContainerMixin.beginLayout] (a *root* frame) and by every
/// layout-managed [Flut5ContainerMixin.beginContainer] (so containers nested
/// inside a layout container flow within it), and popped by the matching
/// `endLayout()` / `endContainer()`.
class _Flut5LayoutFrame {
  /// Flow direction for the containers placed directly in this frame.
  final Flut5LayoutDirection direction;

  /// Main-axis spacing (px) between consecutive containers in this frame.
  final double gap;

  /// Cross-axis spacing (px) between wrapped lines.
  final double crossGap;

  /// Wrap behavior for this frame's containers. See [Flut5LayoutWrap].
  final Flut5LayoutWrap wrap;

  /// Cross-axis alignment of containers within their line.
  final Flut5LayoutAlign align;

  /// Main-axis distribution of a line's free space.
  final Flut5LayoutJustify justify;

  /// Whether [align] / [justify] deviate from their defaults — only then do
  /// containers reserve placeholder translates for the line-close patch pass.
  final bool aligned;

  /// The current line's containers awaiting the align/justify patch:
  /// placeholder queue slot plus declared main/cross size. Only populated
  /// when [aligned]; drained by `_finalizeLayoutLine()`.
  final List<({int slot, double main, double cross})> lineEntries = [];

  /// Content-box origin along the main / cross axis — the start padding, so
  /// children are placed inset from the scope's edge.
  final double mainStart, crossStart;

  /// Content-box main-axis size; children wrap when they would flow past it.
  /// [double.infinity] when unknown (or wrapping is off), so nothing wraps.
  final double mainLimit;

  /// Content-box cross-axis size, used by [Flut5LayoutWrap.wrapReverse] to
  /// stack lines from the end. `0` when unknown (falls back to normal wrap).
  final double crossLimit;

  /// `true` for frames opened by `beginLayout()`, `false` for frames opened
  /// by a layout-managed `beginContainer()`. `endLayout()` uses it to detect
  /// containers left open inside the layout.
  final bool isRoot;

  /// Main-axis offset (within the content box) where the next child container
  /// will be placed.
  double cursor = 0;

  /// Cross-axis offset of the current line's start.
  double crossCursor = 0;

  /// Largest cross extent seen on the current line; advances [crossCursor]
  /// when the line wraps.
  double lineCross = 0;

  _Flut5LayoutFrame({
    required this.direction,
    required this.gap,
    required this.crossGap,
    required this.wrap,
    required this.align,
    required this.justify,
    required this.mainStart,
    required this.crossStart,
    required this.mainLimit,
    required this.crossLimit,
    required this.isRoot,
  }) : aligned =
           align != Flut5LayoutAlign.start || justify != Flut5LayoutJustify.start;
}

/// Bookkeeping for one open [Flut5ContainerMixin.beginContainer] scope,
/// stacked so containers can nest. Captured at `beginContainer()` and consumed
/// by the matching `endContainer()`.
class _Flut5ContainerFrame {
  final double x, y, w, h;

  /// The `args` map passed to `beginContainer()`; read again at
  /// `endContainer()` to dispatch the per-container pointer callbacks.
  final Map<String, dynamic>? args;

  /// Overflow mode snapshotted when the container was opened, so a
  /// `containerOverflow()` call made *inside* the container only affects
  /// nested containers, never the one already open.
  final Flut5ContainerOverflow overflow;

  /// Overscroll mode snapshotted when the container was opened; same
  /// only-affects-nested rule as [overflow].
  final Flut5ContainerOverscroll overscroll;

  /// Render-queue index where the scroll translate is back-filled at
  /// `endContainer()`. Only meaningful in [Flut5ContainerOverflow.scroll] mode.
  final int slot;

  /// Scroll-state identity. Only set in [Flut5ContainerOverflow.scroll] mode.
  final String? scrollId;

  /// Whether this container was opened inside a [Flut5ContainerMixin.beginLayout]
  /// scope and therefore positioned by it. `endContainer()` uses it to advance
  /// the enclosing layout's cursor.
  final bool layoutManaged;

  final Flut5ContainerContext Function() _buildContext;
  Flut5ContainerContext? _context;

  /// Context snapshot exposed via [Flut5ContainerMixin.containerContext]
  /// while this container is the innermost open one. Built lazily on first
  /// access so containers that never read the context pay nothing; pointer
  /// state is frame-stable during `draw()`, so access timing doesn't change
  /// the values.
  Flut5ContainerContext get context => _context ??= _buildContext();

  _Flut5ContainerFrame({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.args,
    required this.overflow,
    required this.overscroll,
    required this.slot,
    required this.scrollId,
    required this.layoutManaged,
    required Flut5ContainerContext Function() buildContext,
  }) : _buildContext = buildContext;
}

/// Provides the [beginContainer] / [endContainer] drawing scope for the
/// Flut5 Engine.
///
/// `beginContainer()` paints a rectangular region and opens a matched
/// `push()` / `translate()` / `pop()` scope so draw calls made until the
/// matching `endContainer()` operate in coordinates local to the container's
/// top-left corner. A second `push()` / `pop()` is wrapped around the content
/// so its clip, optional scroll translate, and any unbalanced state inside
/// the scope stay contained.
///
/// Distinct from the `createContainer()` UI widget in `lib/ui/flut5_ui.dart`,
/// which builds a Flutter layout container — this is a low-level canvas
/// drawing helper.
mixin Flut5ContainerMixin on Flut5Transform, Flut52DPrimitives, Flut5Clip {
  /// Open containers, innermost last. Pushed by [beginContainer], popped by
  /// [endContainer], force-cleared once per frame by the painter.
  final List<_Flut5ContainerFrame> _containerStack = [];

  Flut5ContainerOverflow _containerOverflow = Flut5ContainerOverflow.hidden;
  double _containerScrollInertia = 0.85;
  static const double _inertiaStopEpsilon = 0.05;
  final Map<String, _Flut5ContainerScrollState> _containerScrollStates = {};

  /// How a scroll container reacts at the edge of its content. Defaults to
  /// [Flut5ContainerOverscroll.bounce].
  Flut5ContainerOverscroll _containerOverscroll = Flut5ContainerOverscroll.bounce;

  /// Rubber-band give for [Flut5ContainerOverscroll.bounce], in `[0, 1]`.
  /// `0.5` is the default browser-like feel; see [containerOverscrollBounce].
  double _containerOverscrollBounce = 0.5;

  /// Which input(s) drive scroll-mode containers. Defaults to
  /// [Flut5ContainerOverscrollInput.auto] (wheel + drag).
  Flut5ContainerOverscrollInput _containerOverscrollInput =
      Flut5ContainerOverscrollInput.auto;

  /// Default wheel gain — one notch ≈ its reported logical-pixel delta. Used as
  /// the `1.0` baseline that [containerScrollSensitivity]'s multiplier scales.
  static const double _defaultWheelGain = 1.0;

  /// Default pointer-drag gain. Above `1.0` so a physical mouse drag covers
  /// ground without feeling stiff (a 1:1-ish gain reads as "heavy/hard to drag"
  /// on desktop where cursor travel is small). Used as the baseline that
  /// [containerScrollSensitivity]'s multiplier scales.
  static const double _defaultDragGain = 2.2;

  /// Content moves this much per pixel of wheel scroll. Tunable via
  /// [containerWheelSensitivity] (absolute) or [containerScrollSensitivity]
  /// (relative multiplier).
  double _wheelGain = _defaultWheelGain;

  /// Content moves this much per pixel of pointer drag. Tunable via
  /// [containerPointerDragSensitivity] (absolute) or [containerScrollSensitivity]
  /// (relative multiplier).
  double _dragGain = _defaultDragGain;

  /// Per-frame spring stiffness used to pull bounce-mode content back to the
  /// content edge after release. Higher = snappier return.
  static const double _bounceSpring = 0.22;

  /// Distance (px) within which a bounce spring-back is snapped to the edge.
  static const double _bounceSnapEpsilon = 0.5;

  /// Active pointers, used by [Flut5ContainerOverflow.scroll] to detect
  /// drags. Implemented by the host (the Flut5Engine).
  List<Flut5Touch> get touches;

  /// Buffered mouse-wheel / trackpad scroll for the current frame, or `null`
  /// when none occurred. Used by [Flut5ContainerOverflow.scroll] to pan the
  /// container under the cursor. Implemented by the host (the Flut5Engine).
  Flut5WheelSample? get wheel;

  /// Pointer events captured for the current frame, read by [beginContainer] to
  /// dispatch its per-container pointer callbacks. Implemented by the host
  /// (the Flut5Engine).
  List<Flut5FramePointerEvent> get pendingPointerEvents;

  /// Current pointer x in canvas-local coordinates. Used to compute the
  /// container's hover state ([Flut5ContainerContext.pointerIsOver]).
  /// Implemented by the host (the Flut5Engine).
  double get mouseX;

  /// Current pointer y in canvas-local coordinates. See [mouseX].
  double get mouseY;

  /// Average pointer velocity x-component (px / frame). Surfaced unchanged on
  /// [Flut5ContainerContext.avgMouseX]. Implemented by the host (the Flut5Engine).
  double get avgMouseX;

  /// Average pointer velocity y-component (px / frame). See [avgMouseX].
  double get avgMouseY;

  /// Average pointer velocity (px / frame) as a 2D vector. Surfaced unchanged on
  /// [Flut5ContainerContext.avgMouse]. Implemented by the host (the Flut5Engine).
  Flut5Vector get avgMouse;

  /// Canvas width in logical pixels, used as the default wrap limit of root
  /// [beginLayout] scopes. Implemented by the host (the Flut5Engine).
  double get width;

  /// Canvas height in logical pixels. See [width].
  double get height;

  /// Current frame number, used to reset per-frame counters. Implemented by
  /// the host (the Flut5Engine).
  int get frameCount;

  /// Clipping containers ([Flut5ContainerOverflow.hidden] / `scroll`) opened
  /// within a single frame beyond which a one-time performance hint suggests
  /// [Flut5ContainerOverflow.visible]. Each clip breaks shape batching and
  /// adds a save/restore at raster time, which adds up in large grids.
  static const int _clipCountHintThreshold = 200;
  int _clipContainersThisFrame = 0;
  int _clipContainersFrameStamp = -1;
  bool _clipCountHintShown = false;

  /// Counts a clipping container opened this frame and emits the one-time
  /// [_clipCountHintThreshold] hint when crossed.
  void _countClippingContainer() {
    if (frameCount != _clipContainersFrameStamp) {
      _clipContainersFrameStamp = frameCount;
      _clipContainersThisFrame = 0;
    }
    if (++_clipContainersThisFrame == _clipCountHintThreshold &&
        !_clipCountHintShown) {
      _clipCountHintShown = true;
      Flut5Console.printLater(
        'performance: $_clipCountHintThreshold+ containers with clipping '
        '(hidden/scroll overflow) opened in one frame. If a container\'s '
        'content stays inside its bounds, '
        'containerOverflow(Flut5ContainerOverflow.visible) skips the clip '
        'and batches much better (hint shown once)',
      );
    }
  }

  /// Current overflow mode applied by [beginContainer]. Defaults to
  /// [Flut5ContainerOverflow.hidden].
  Flut5ContainerOverflow get currentContainerOverflow => _containerOverflow;

  /// Sets how subsequent [beginContainer] calls handle content drawn outside
  /// their rectangular bounds. See [Flut5ContainerOverflow].
  ///
  /// Performance note: [Flut5ContainerOverflow.hidden] and
  /// [Flut5ContainerOverflow.scroll] install a clip per container, which
  /// breaks shape batching and adds a save/restore at raster time. In large
  /// grids of containers (e.g. a wrapped [beginLayout]) whose content stays
  /// inside its bounds, [Flut5ContainerOverflow.visible] is significantly
  /// cheaper; a one-time console hint points this out past 200 clipping
  /// containers in a single frame.
  void containerOverflow(Flut5ContainerOverflow mode) {
    _containerOverflow = mode;
  }

  /// Current decay factor applied to post-release scroll momentum each frame.
  /// `0.0` means no inertia (motion stops the instant the pointer lifts).
  /// Values closer to `1.0` keep the content gliding for longer.
  double get currentContainerScrollInertia => _containerScrollInertia;

  /// Sets how much post-release momentum subsequent scroll-mode containers
  /// carry. The value is the per-frame velocity decay factor and is clamped
  /// to `[0.0, 1.0]`:
  ///
  /// * `0.0` — no inertia, motion stops the instant the pointer lifts.
  /// * `0.85` — default; a slight glide that settles within roughly half a
  ///   second at 60 fps.
  /// * `1.0` — momentum never decays (the content keeps moving forever).
  void containerScrollInertia(double value) {
    _containerScrollInertia = value.clamp(0.0, 1.0);
  }

  /// Current edge behavior applied by scroll-mode [beginContainer] calls. Defaults
  /// to [Flut5ContainerOverscroll.bounce].
  Flut5ContainerOverscroll get currentContainerOverscrollMode =>
      _containerOverscroll;

  /// Sets how subsequent scroll-mode [beginContainer] calls behave when the content
  /// is dragged past the edge of its bounding box. See
  /// [Flut5ContainerOverscroll].
  void containerOverscrollMode(Flut5ContainerOverscroll mode) {
    _containerOverscroll = mode;
  }

  /// Current rubber-band give used by [Flut5ContainerOverscroll.bounce].
  double get currentContainerOverscrollBounce => _containerOverscrollBounce;

  /// Sets how far bounce-mode content rubber-bands past the content edge while
  /// dragging. The value is clamped to `[0.0, 1.0]`:
  ///
  /// * `0.0` — almost no give; behaves close to [Flut5ContainerOverscroll.clamp].
  /// * `0.5` — default; a browser-like elastic edge.
  /// * `1.0` — very loose; the content follows the finger far past the edge.
  ///
  /// Has no effect under [Flut5ContainerOverscroll.free] or
  /// [Flut5ContainerOverscroll.clamp].
  void containerOverscrollBounce(double value) {
    _containerOverscrollBounce = value.clamp(0.0, 1.0);
  }

  /// Current input mode applied by scroll-mode [beginContainer] calls. Defaults to
  /// [Flut5ContainerOverscrollInput.auto].
  Flut5ContainerOverscrollInput get currentContainerOverscrollInput =>
      _containerOverscrollInput;

  /// Sets which input(s) drive subsequent scroll-mode [beginContainer] calls. See
  /// [Flut5ContainerOverscrollInput]. Only affects desktop mouse input; touch
  /// dragging always works.
  void containerOverscrollInput(Flut5ContainerOverscrollInput mode) {
    _containerOverscrollInput = mode;
  }

  /// Sets the overall scroll sensitivity for subsequent scroll-mode [beginContainer]
  /// calls, scaling **both** pointer drag and wheel/trackpad at once.
  ///
  /// [multiplier] is relative to the tuned defaults (drag `2.2`, wheel `1.0`),
  /// so the drag/wheel balance is preserved:
  ///
  /// * `1.0` — the default feel.
  /// * `2.0` — twice as sensitive everywhere.
  /// * `0.5` — half as sensitive everywhere.
  ///
  /// Pass [wheelMultiplier] to give the wheel/trackpad its own multiplier and
  /// break the default proportion (e.g. `containerScrollSensitivity(2.0, 1.0)`
  /// makes dragging twice as fast while leaving the wheel at its default). When
  /// omitted, the wheel uses [multiplier] too. Both are clamped non-negative.
  ///
  /// This is a convenience over [containerPointerDragSensitivity] /
  /// [containerWheelSensitivity], which set each absolute gain directly.
  void containerScrollSensitivity(double multiplier, [double? wheelMultiplier]) {
    final m = multiplier < 0.0 ? 0.0 : multiplier;
    final wm = wheelMultiplier == null
        ? m
        : (wheelMultiplier < 0.0 ? 0.0 : wheelMultiplier);
    _dragGain = _defaultDragGain * m;
    _wheelGain = _defaultWheelGain * wm;
  }

  /// Current pointer-drag sensitivity used by scroll-mode [beginContainer] calls.
  /// Defaults to `2.2`. See [containerPointerDragSensitivity].
  double get currentContainerPointerDragSensitivity => _dragGain;

  /// Sets how far scroll-mode content moves per pixel of pointer drag.
  ///
  /// `1.0` is a 1:1 drag (content tracks the cursor exactly); values above
  /// `1.0` make dragging feel lighter/faster, below `1.0` heavier/slower. This
  /// drives both the live drag and the fling velocity derived from it. Affects
  /// pointer dragging only — the wheel/trackpad has its own
  /// [containerWheelSensitivity]. Clamped to be non-negative.
  void containerPointerDragSensitivity(double value) {
    _dragGain = value < 0.0 ? 0.0 : value;
  }

  /// Current wheel/trackpad sensitivity used by scroll-mode [beginContainer] calls.
  /// Defaults to `1.0`. See [containerWheelSensitivity].
  double get currentContainerWheelSensitivity => _wheelGain;

  /// Sets how far scroll-mode content moves per pixel of wheel/trackpad scroll.
  ///
  /// `1.0` keeps one notch ≈ its reported logical-pixel delta; higher scrolls
  /// faster, lower slower. Affects the wheel/trackpad only — pointer dragging
  /// has its own [containerPointerDragSensitivity]. Clamped to be non-negative.
  void containerWheelSensitivity(double value) {
    _wheelGain = value < 0.0 ? 0.0 : value;
  }

  /// Resets the accumulated scroll offset for a container.
  ///
  /// Pass the same `id` that was used in the container's `args['id']`. When
  /// `id` is `null`, every tracked container's scroll state is cleared.
  void resetContainerScroll([String? id]) {
    if (id == null) {
      _containerScrollStates.clear();
    } else {
      _containerScrollStates.remove(id);
    }
  }

  _Flut5ContainerScrollState _updateContainerScroll(
    String id,
    double x,
    double y,
    double w,
    double h,
    Rect? contentBounds,
    Flut5ContainerOverscroll mode,
  ) {
    final state = _containerScrollStates.putIfAbsent(
      id,
      () => _Flut5ContainerScrollState(),
    );

    final activeTouches = touches;
    final currentIds = <int>{for (final t in activeTouches) t.id};

    // Drop ids that were released since last frame so a new gesture with a
    // reused id can be evaluated fresh.
    state.seenPointerIds.retainWhere(currentIds.contains);

    final bounded = mode != Flut5ContainerOverscroll.free;

    // Input gating (desktop only — touch drags are always allowed below).
    final input = _containerOverscrollInput;
    final wheelAllowed = input != Flut5ContainerOverscrollInput.drag;
    final mouseDragAllowed = input != Flut5ContainerOverscrollInput.scroll;

    // Allowed offset range per axis. With content extent [L, R] and viewport
    // [0, w], a translate of `dx` should keep content edges from exposing empty
    // space: `dx >= w - R` keeps the right edge covered and `dx <= -L` keeps
    // the left edge in place. min/max keeps the range valid even when the
    // content is smaller than the viewport. `free` leaves it unbounded.
    double loX = double.negativeInfinity, hiX = double.infinity;
    double loY = double.negativeInfinity, hiY = double.infinity;
    if (bounded) {
      if (contentBounds == null) {
        // Nothing measurable was drawn — pin to the origin.
        loX = hiX = 0;
        loY = hiY = 0;
      } else {
        loX = math.min(w - contentBounds.right, -contentBounds.left);
        hiX = math.max(w - contentBounds.right, -contentBounds.left);
        loY = math.min(h - contentBounds.bottom, -contentBounds.top);
        hiY = math.max(h - contentBounds.bottom, -contentBounds.top);
      }
    }

    if (state.activePointerId != null) {
      Flut5Touch? claimed;
      for (final t in activeTouches) {
        if (t.id == state.activePointerId) {
          claimed = t;
          break;
        }
      }
      if (claimed != null) {
        final dx = (claimed.x - claimed.px) * _dragGain;
        final dy = (claimed.y - claimed.py) * _dragGain;
        if (mode == Flut5ContainerOverscroll.bounce) {
          state.offsetX = _rubberBandDrag(state.offsetX, dx, loX, hiX);
          state.offsetY = _rubberBandDrag(state.offsetY, dy, loY, hiY);
        } else {
          state.offsetX += dx;
          state.offsetY += dy;
          if (mode == Flut5ContainerOverscroll.clamp) {
            state.offsetX = state.offsetX.clamp(loX, hiX);
            state.offsetY = state.offsetY.clamp(loY, hiY);
          }
        }
        // Snapshot the smoothed velocity so we can carry it after release.
        state.velocityX = claimed.velocity.x * _dragGain;
        state.velocityY = claimed.velocity.y * _dragGain;
      } else {
        state.activePointerId = null;
        // Keep velocityX / velocityY — the momentum block below uses them.
      }
    } else {
      for (final t in activeTouches) {
        if (state.seenPointerIds.contains(t.id)) continue;
        // Mouse/stylus drags are suppressed in scroll-only mode; touch drags
        // (mobile) are always honored so the mode only affects desktop.
        if (t.kind != PointerDeviceKind.touch && !mouseDragAllowed) continue;
        if (t.x >= x && t.x <= x + w && t.y >= y && t.y <= y + h) {
          state.activePointerId = t.id;
          // New grab: kill any in-flight momentum so the gesture starts clean.
          state.velocityX = 0;
          state.velocityY = 0;
          break;
        }
      }
    }

    // Mouse-wheel / trackpad scroll for the container under the cursor. Applied
    // before the release block so a bounce overshoot springs back next frames.
    final wheelSample = wheel;
    if (wheelAllowed &&
        wheelSample != null &&
        wheelSample.x >= x &&
        wheelSample.x <= x + w &&
        wheelSample.y >= y &&
        wheelSample.y <= y + h) {
      // Wheel-down (positive delta) moves content up, so subtract.
      final dx = -wheelSample.dx * _wheelGain;
      final dy = -wheelSample.dy * _wheelGain;
      if (mode == Flut5ContainerOverscroll.bounce) {
        state.offsetX = _rubberBandDrag(state.offsetX, dx, loX, hiX);
        state.offsetY = _rubberBandDrag(state.offsetY, dy, loY, hiY);
      } else {
        state.offsetX += dx;
        state.offsetY += dy;
        if (mode == Flut5ContainerOverscroll.clamp) {
          state.offsetX = state.offsetX.clamp(loX, hiX);
          state.offsetY = state.offsetY.clamp(loY, hiY);
        }
      }
    }

    if (state.activePointerId == null) {
      if (mode == Flut5ContainerOverscroll.bounce) {
        // Spring back when overscrolled, otherwise glide with inertia (a fling
        // past the edge overshoots, then the next frame springs it back).
        _bounceRelease(state, isX: true, lo: loX, hi: hiX);
        _bounceRelease(state, isX: false, lo: loY, hi: hiY);
      } else {
        if (state.velocityX.abs() > _inertiaStopEpsilon ||
            state.velocityY.abs() > _inertiaStopEpsilon) {
          state.offsetX += state.velocityX;
          state.offsetY += state.velocityY;
          state.velocityX *= _containerScrollInertia;
          state.velocityY *= _containerScrollInertia;
        } else {
          state.velocityX = 0;
          state.velocityY = 0;
        }
        if (mode == Flut5ContainerOverscroll.clamp) {
          // Hard wall: pin to the edge and kill momentum on contact.
          if (state.offsetX < loX) {
            state.offsetX = loX;
            state.velocityX = 0;
          } else if (state.offsetX > hiX) {
            state.offsetX = hiX;
            state.velocityX = 0;
          }
          if (state.offsetY < loY) {
            state.offsetY = loY;
            state.velocityY = 0;
          } else if (state.offsetY > hiY) {
            state.offsetY = hiY;
            state.velocityY = 0;
          }
        }
      }
    }

    state.seenPointerIds.addAll(currentIds);
    return state;
  }

  /// Applies a drag delta with rubber-band resistance: movement inside
  /// `[lo, hi]` is 1:1, but the portion that pushes past an edge is scaled down
  /// by [_containerOverscrollBounce] so the content gives less the further it's
  /// dragged out.
  double _rubberBandDrag(double offset, double delta, double lo, double hi) {
    final next = offset + delta;
    final give = _containerOverscrollBounce;
    if (next > hi) return hi + (next - hi) * give;
    if (next < lo) return lo - (lo - next) * give;
    return next;
  }

  /// Post-release bounce step for one axis: if the offset sits past an edge it
  /// springs back toward that edge (and drops momentum); otherwise it glides
  /// with the normal inertia decay.
  void _bounceRelease(
    _Flut5ContainerScrollState state, {
    required bool isX,
    required double lo,
    required double hi,
  }) {
    var offset = isX ? state.offsetX : state.offsetY;
    var velocity = isX ? state.velocityX : state.velocityY;

    if (offset < lo || offset > hi) {
      final target = offset < lo ? lo : hi;
      offset += (target - offset) * _bounceSpring;
      if ((target - offset).abs() < _bounceSnapEpsilon) offset = target;
      velocity = 0;
    } else if (velocity.abs() > _inertiaStopEpsilon) {
      offset += velocity;
      velocity *= _containerScrollInertia;
    } else {
      velocity = 0;
    }

    if (isX) {
      state.offsetX = offset;
      state.velocityX = velocity;
    } else {
      state.offsetY = offset;
      state.velocityY = velocity;
    }
  }

  // ── Layout ───────────────────────────────────────────────────────────────

  /// Open layout frames, innermost last. `beginLayout()` pushes a root frame,
  /// every layout-managed `beginContainer()` pushes a child frame, and the
  /// matching `endLayout()` / `endContainer()` pops it. Force-cleared once per
  /// frame by the painter via [closeUnbalancedLayouts].
  final List<_Flut5LayoutFrame> _layoutStack = [];

  Flut5LayoutDirection _layoutDirection = Flut5LayoutDirection.horizontal;
  double _layoutGap = 0;

  /// Cross-axis gap between wrapped lines; `null` follows [_layoutGap].
  double? _layoutCrossGap;

  Flut5LayoutWrap _layoutWrap = Flut5LayoutWrap.noWrap;
  EdgeInsets _layoutPadding = EdgeInsets.zero;
  Flut5LayoutAlign _layoutAlign = Flut5LayoutAlign.start;
  Flut5LayoutJustify _layoutJustify = Flut5LayoutJustify.start;

  /// Current flow direction applied by subsequently opened layout scopes.
  /// Defaults to [Flut5LayoutDirection.horizontal].
  Flut5LayoutDirection get currentLayoutDirection => _layoutDirection;

  /// Sets the direction in which subsequently opened layout scopes flow their
  /// containers. Like [containerOverflow], the value is snapshotted when a
  /// scope opens: calling it before [beginLayout] sets the whole layout's
  /// direction, and calling it before a [beginContainer] inside a layout sets
  /// the direction used for *that container's* nested containers.
  void layoutDirection(Flut5LayoutDirection direction) {
    _layoutDirection = direction;
  }

  /// Current main-axis spacing applied by subsequently opened layout scopes.
  double get currentLayoutGap => _layoutGap;

  /// Current cross-axis spacing between wrapped lines. Follows
  /// [currentLayoutGap] unless [layoutGap] was given an explicit cross gap.
  double get currentLayoutCrossGap => _layoutCrossGap ?? _layoutGap;

  /// Sets the spacing (px) placed between consecutive containers of
  /// subsequently opened layout scopes. Snapshotted per scope exactly like
  /// [layoutDirection]. Clamped to be non-negative. Defaults to `0`.
  ///
  /// [crossGap] sets the spacing between wrapped lines (see [layoutWrap]) —
  /// the counterpart of giving CSS `gap` two values. When omitted, wrapped
  /// lines use [gap] too.
  void layoutGap(double gap, [double? crossGap]) {
    _layoutGap = gap < 0 ? 0 : gap;
    _layoutCrossGap = crossGap == null ? null : (crossGap < 0 ? 0 : crossGap);
  }

  /// Current wrap behavior applied by subsequently opened layout scopes.
  /// Defaults to [Flut5LayoutWrap.noWrap].
  Flut5LayoutWrap get currentLayoutWrap => _layoutWrap;

  /// Sets whether subsequently opened layout scopes wrap their containers
  /// onto new lines — the CSS `flex-wrap` counterpart. Snapshotted per scope
  /// exactly like [layoutDirection]. See [Flut5LayoutWrap] for the modes and
  /// where the wrap limit comes from.
  void layoutWrap(Flut5LayoutWrap mode) {
    _layoutWrap = mode;
  }

  /// Current padding applied by subsequently opened layout scopes.
  /// Defaults to [EdgeInsets.zero].
  EdgeInsets get currentLayoutPadding => _layoutPadding;

  /// Sets the padding of subsequently opened layout scopes — the CSS
  /// `padding` counterpart on the flex container. Containers are placed inset
  /// by the padding's leading edges, and the wrap limits (see [layoutWrap])
  /// shrink to the padded content box. Snapshotted per scope exactly like
  /// [layoutDirection]: call it before [beginLayout] for the layout itself,
  /// or before a [beginContainer] inside a layout for that container's
  /// children.
  void layoutPadding(EdgeInsets padding) {
    _layoutPadding = padding;
  }

  /// Current cross-axis alignment applied by subsequently opened layout
  /// scopes. Defaults to [Flut5LayoutAlign.start].
  Flut5LayoutAlign get currentLayoutAlignItems => _layoutAlign;

  /// Sets how subsequently opened layout scopes align containers along the
  /// cross axis within their line — the CSS `align-items` counterpart.
  /// Snapshotted per scope exactly like [layoutDirection].
  ///
  /// Alignment is applied when a line completes (it wraps, or the scope
  /// closes) by patching a translate reserved per container, so it costs one
  /// extra queue item per container and an O(1) patch — nothing is measured
  /// or re-recorded, and layouts left at the default pay nothing at all.
  /// Note that [Flut5ContainerContext] positions and container pointer
  /// bounds are captured *before* the patch, so like scroll offsets they do
  /// not reflect the alignment shift.
  void layoutAlignItems(Flut5LayoutAlign align) {
    _layoutAlign = align;
  }

  /// Current main-axis distribution applied by subsequently opened layout
  /// scopes. Defaults to [Flut5LayoutJustify.start].
  Flut5LayoutJustify get currentLayoutJustifyContent => _layoutJustify;

  /// Sets how subsequently opened layout scopes distribute a line's free
  /// main-axis space — the CSS `justify-content` counterpart. Snapshotted
  /// per scope exactly like [layoutDirection].
  ///
  /// Free space needs a known main-axis limit (explicit `beginLayout`
  /// bounds or the enclosing container's size — see [Flut5LayoutWrap]);
  /// without one, or when the line overflows, this behaves like
  /// [Flut5LayoutJustify.start]. Gaps set by [layoutGap] are
  /// preserved: free space is distributed *in addition* to them, as in CSS.
  /// Same cost and [Flut5ContainerContext] caveat as [layoutAlignItems].
  void layoutJustifyContent(Flut5LayoutJustify justify) {
    _layoutJustify = justify;
  }

  /// Builds a layout frame for a scope whose outer box is
  /// [outerMain] × [outerCross] (main / cross axis of the *current* layout
  /// direction), snapshotting the direction, gaps, wrap mode and padding in
  /// effect. Non-positive outer sizes mark the limits unknown: the main limit
  /// becomes unbounded (nothing wraps) and the cross limit `0`
  /// (`wrapReverse` falls back to `wrap`).
  _Flut5LayoutFrame _newLayoutFrame({
    required double outerMain,
    required double outerCross,
    required bool isRoot,
  }) {
    final direction = _layoutDirection;
    final horizontal = direction == Flut5LayoutDirection.horizontal;
    final padding = _layoutPadding;
    final mainStart = horizontal ? padding.left : padding.top;
    final mainEnd = horizontal ? padding.right : padding.bottom;
    final crossStart = horizontal ? padding.top : padding.left;
    final crossEnd = horizontal ? padding.bottom : padding.right;
    final mainContent = outerMain - mainStart - mainEnd;
    final crossContent = outerCross - crossStart - crossEnd;
    return _Flut5LayoutFrame(
      direction: direction,
      gap: _layoutGap,
      crossGap: _layoutCrossGap ?? _layoutGap,
      wrap: _layoutWrap,
      align: _layoutAlign,
      justify: _layoutJustify,
      mainStart: mainStart,
      crossStart: crossStart,
      mainLimit:
          mainContent.isFinite && mainContent > 0 ? mainContent : double.infinity,
      crossLimit:
          crossContent.isFinite && crossContent > 0 ? crossContent : 0,
      isRoot: isRoot,
    );
  }

  /// Places the next child of [frame], wrapping to a new line first when the
  /// child would overflow the main-axis limit, and returns the child's
  /// position within the layout scope. Mutates the frame's line state; the
  /// main-axis cursor itself advances at `endContainer()`.
  Offset _layoutPlaceChild(_Flut5LayoutFrame frame, double w, double h) {
    final horizontal = frame.direction == Flut5LayoutDirection.horizontal;
    final main = horizontal ? w : h;
    final cross = horizontal ? h : w;

    if (frame.wrap != Flut5LayoutWrap.noWrap &&
        frame.cursor > 0 &&
        frame.cursor + main > frame.mainLimit) {
      _finalizeLayoutLine(frame);
      frame.cursor = 0;
      frame.crossCursor += frame.lineCross + frame.crossGap;
      frame.lineCross = 0;
    }
    if (cross > frame.lineCross) frame.lineCross = cross;

    final mainPos = frame.mainStart + frame.cursor;
    final crossPos = frame.crossStart +
        (frame.wrap == Flut5LayoutWrap.wrapReverse && frame.crossLimit > 0
            ? frame.crossLimit - frame.crossCursor - cross
            : frame.crossCursor);
    return horizontal ? Offset(mainPos, crossPos) : Offset(crossPos, mainPos);
  }

  /// Closes out the current line of [frame] — called when the line wraps and
  /// when the scope ends — applying the frame's align/justify by patching
  /// each buffered container's placeholder translate (see
  /// [layoutAlignItems]). No-op unless the frame is [aligned][_Flut5LayoutFrame.aligned]
  /// and the line has containers.
  void _finalizeLayoutLine(_Flut5LayoutFrame frame) {
    final entries = frame.lineEntries;
    if (entries.isEmpty) return;

    final n = entries.length;
    // cursor accumulated `size + gap` per container, so drop the trailing gap.
    final lineMain = frame.cursor - frame.gap;
    final freeRaw =
        frame.mainLimit.isFinite ? frame.mainLimit - lineMain : 0.0;
    // Overflowing / unbounded lines distribute nothing — CSS `start` behavior.
    final free = freeRaw > 0 ? freeRaw : 0.0;
    final horizontal = frame.direction == Flut5LayoutDirection.horizontal;
    // wrapReverse flips the cross axis, and with it what start/end hug.
    final reversed =
        frame.wrap == Flut5LayoutWrap.wrapReverse && frame.crossLimit > 0;

    for (var i = 0; i < n; i++) {
      final entry = entries[i];
      final dMain = switch (frame.justify) {
        Flut5LayoutJustify.start => 0.0,
        Flut5LayoutJustify.center => free / 2,
        Flut5LayoutJustify.end => free,
        Flut5LayoutJustify.spaceBetween => n > 1 ? free * i / (n - 1) : 0.0,
        Flut5LayoutJustify.spaceAround => free / n * (i + 0.5),
        Flut5LayoutJustify.spaceEvenly => free / (n + 1) * (i + 1),
      };
      var dCross = switch (frame.align) {
        Flut5LayoutAlign.start => 0.0,
        Flut5LayoutAlign.center => (frame.lineCross - entry.cross) / 2,
        Flut5LayoutAlign.end => frame.lineCross - entry.cross,
      };
      if (reversed) dCross = -dCross;
      if (dMain != 0 || dCross != 0) {
        renderQueue.replaceAt(
          entry.slot,
          horizontal
              ? TransformRenderItem.translate(dMain, dCross)
              : TransformRenderItem.translate(dCross, dMain),
        );
      }
    }
    entries.clear();
  }

  /// Opens a layout scope: until the matching [endLayout], containers are
  /// opened with `beginContainer(w, h)` — width and height only — and the
  /// layout positions them, flowing them in the current [layoutDirection]
  /// separated by the current [layoutGap], inset by the current
  /// [layoutPadding], and wrapped onto new lines per the current [layoutWrap].
  /// Nesting a container inside another container flows it within the parent
  /// the same way.
  ///
  /// Configure with [layoutDirection] / [layoutGap] / [layoutWrap] /
  /// [layoutPadding] *before* opening the scope — like [containerOverflow],
  /// the values are snapshotted when the scope opens.
  ///
  /// A layout belongs inside an absolute `(x, y, w, h)` [beginContainer]
  /// scope, which acts as its box: the layout's bounds (for wrapping and
  /// justification) default to that container's declared size, minus the
  /// layout's offset. [w] / [h] override the bounds explicitly. Calling
  /// `beginLayout()` outside any container logs a console warning and falls
  /// back to the explicit bounds or the canvas size.
  ///
  /// [x] / [y] optionally offset the whole layout; the scope is wrapped in a
  /// `push()` / `translate()` / `pop()` of its own, so the offset (and any
  /// transform left unbalanced inside) stays contained. Layout-managed
  /// containers share [beginContainer]'s root-transform assumption: pointer
  /// state (context, scrolling, callbacks) tests bounds in canvas-local
  /// coordinates, so it is only accurate for containers at the layout's first
  /// nesting level with the layout itself at the root transform.
  ///
  /// ```dart
  /// layoutDirection(Flut5LayoutDirection.horizontal);
  /// layoutGap(10);
  /// layoutWrap(Flut5LayoutWrap.wrap);
  /// beginContainer(20, 20, 250, 200); // the layout's box
  /// beginLayout();
  /// beginContainer(100, 60); // placed at (0, 0)
  /// endContainer();
  /// beginContainer(100, 60); // placed at (110, 0)
  /// endContainer();
  /// beginContainer(100, 60); // would end at 320 > 250 → wraps to (0, 70)
  /// endContainer();
  /// endLayout();
  /// endContainer();
  /// ```
  void beginLayout([double x = 0, double y = 0, double? w, double? h]) {
    push();
    translate(x, y);
    double outerW, outerH;
    if (_containerStack.isNotEmpty) {
      // The enclosing container is the layout's box — its declared size is
      // the bounds (coordinates in here are already container-local).
      final host = _containerStack.last;
      outerW = w ?? host.w - x;
      outerH = h ?? host.h - y;
    } else {
      Flut5Console.printLater(
        'beginLayout() called outside a container — layouts belong inside a '
        'beginContainer(x, y, w, h) scope, which gives them their bounds; '
        'falling back to the explicit/canvas size',
      );
      outerW = w ?? width - x;
      outerH = h ?? height - y;
    }
    final horizontal = _layoutDirection == Flut5LayoutDirection.horizontal;
    _layoutStack.add(_newLayoutFrame(
      outerMain: horizontal ? outerW : outerH,
      outerCross: horizontal ? outerH : outerW,
      isRoot: true,
    ));
  }

  /// Closes the innermost layout scope opened by [beginLayout]. Containers
  /// left open inside the layout are force-closed with a console warning.
  ///
  /// Calling it without an open layout is a no-op that logs a console warning.
  void endLayout() {
    if (_layoutStack.isEmpty) {
      Flut5Console.printLater(
        'endLayout() called without a matching beginLayout()',
      );
      return;
    }
    var unclosed = 0;
    while (!_layoutStack.last.isRoot && _containerStack.isNotEmpty) {
      unclosed++;
      endContainer();
    }
    if (unclosed > 0) {
      Flut5Console.printLater(
        'endLayout(): $unclosed container(s) still open — missing '
        'endContainer()',
      );
    }
    _finalizeLayoutLine(_layoutStack.last); // align/justify the last line
    _layoutStack.removeLast();
    pop(); // balance beginLayout's push()
  }

  /// Force-closes layouts left open by a missing [endLayout] and warns about
  /// them. Called by the painter once per frame *before*
  /// [closeUnbalancedContainers], since each forced endLayout() also closes
  /// the containers opened inside it; not part of the sketch-facing API.
  void closeUnbalancedLayouts() {
    if (_layoutStack.isEmpty) return;
    final roots = _layoutStack.where((f) => f.isRoot).length;
    Flut5Console.printLater(
      'beginLayout(): $roots layout(s) still open at the end of the frame — '
      'missing endLayout()',
    );
    while (_layoutStack.isNotEmpty) {
      endLayout();
    }
  }

  /// Context of the innermost container currently open via [beginContainer],
  /// or `null` outside any container.
  ///
  /// Follows the open-container stack: inside a nested container it is the
  /// nested container's context; after that container's [endContainer] it goes
  /// back to the parent's; after the outermost [endContainer] it is `null`.
  /// The snapshot is taken when the container is opened.
  Flut5ContainerContext? get containerContext =>
      _containerStack.isEmpty ? null : _containerStack.last.context;

  /// Returns [containerContext] — the innermost open container's context, or
  /// `null` outside any container. Handy for stashing the context in a local
  /// before opening a nested container.
  Flut5ContainerContext? getContainerContext() => containerContext;

  /// Opens a container: paints a rectangular region at ([x], [y]) of size
  /// ([w], [h]) and starts a `push()` / `translate()` / `pop()` scope, so
  /// draw calls made until the matching [endContainer] use coordinates local
  /// to the container's top-left corner. Containers can nest; each
  /// [beginContainer] must be balanced by an [endContainer] in the same frame.
  ///
  /// While the container is open, [containerContext] / [getContainerContext]
  /// expose a [Flut5ContainerContext] snapshot with the container's geometry
  /// and container-scoped pointer state.
  ///
  /// Configuration calls such as [containerOverflow] and
  /// [containerOverscrollMode] apply to containers opened *after* them: the
  /// modes are snapshotted by [beginContainer], so calling them inside an open
  /// container only affects nested containers, never the one already open.
  ///
  /// Recognized [args] keys:
  ///
  /// * `'borderRadius'` → `num`; when non-zero, the background rect is drawn
  ///   with rounded corners of that radius and the clip uses the same radius
  ///   so the inner content matches.
  /// * `'id'` → `String`; identity used for the scroll state map. When
  ///   omitted, the container is keyed by its `(x, y, w, h)` rect, which is
  ///   only stable if the container does not move.
  /// * `'pointerDown'` / `'pointerUp'` / `'pointerMove'` / `'pointerDragged'` →
  ///   `void Function(SketchPointerEvent)`, the container-scoped mirrors of the
  ///   sketch's pointer handlers. Each fires only for events whose location
  ///   falls inside the container's bounds, and receives the event with
  ///   `location` / `plocation` rebased to coordinates local to the container's
  ///   top-left corner (`velocity` is left unchanged). Like the sketch handlers
  ///   these are for state, not drawing — draw between [beginContainer] and
  ///   [endContainer]. Events are buffered and dispatched on the next frame
  ///   (one-frame latency, as with the wheel), and use a simple per-event
  ///   hit-test: a press that starts inside but releases outside does not
  ///   deliver `'pointerUp'` to this container. The callbacks fire from
  ///   [endContainer].
  ///
  /// In both [Flut5ContainerOverflow.hidden] and [Flut5ContainerOverflow.scroll]
  /// modes the inner content is clipped to the container's bounds. The
  /// container's background rect is drawn *before* the clip is installed, so
  /// only the content drawn inside the scope is clipped. Under
  /// [Flut5ContainerOverflow.visible] the background rect is still drawn but
  /// no clip is installed, so content can spill past the container's bounds.
  ///
  /// In [Flut5ContainerOverflow.scroll] mode the inner content can be moved
  /// by pressing inside the container and dragging. The touch must be
  /// pressed *down* inside the container's bounds — touches that start
  /// outside and are dragged in are ignored. Bounds detection works in
  /// canvas-local coordinates, which assumes `beginContainer()` is called at
  /// the root transform (i.e. no outer `translate` / `scale` / `rotate`).
  ///
  /// ```dart
  /// containerOverflow(Flut5ContainerOverflow.scroll);
  /// beginContainer(20, 20, 100, 60, {
  ///   'id': 'gallery',
  ///   'borderRadius': 12,
  /// });
  /// final ctx = containerContext!;
  /// fill(ctx.pointerIsOver ? 'orange' : 'red');
  /// ellipse(ctx.mouseX, ctx.mouseY, 30, 30); // local to the container.
  /// endContainer();
  /// ```
  ///
  /// Inside a [beginLayout] scope the container is positioned by the layout,
  /// so only width and height are passed — `beginContainer(w, h)` or
  /// `beginContainer(w, h, args)`. See [beginLayout].
  void beginContainer(
    double xOrW,
    double yOrH, [
    Object? wOrArgs,
    double? h,
    Map<String, dynamic>? args,
  ]) {
    // The args map arrives in slot 3 in the layout form and slot 5 in the
    // positioned form.
    final mapArgs = switch (wOrArgs) {
      final Map<String, dynamic> m => m,
      final Map m => Map<String, dynamic>.from(m),
      _ => args,
    };

    if (_layoutStack.isNotEmpty) {
      var w = xOrW, hResolved = yOrH;
      if (wOrArgs is num) {
        Flut5Console.printLater(
          'beginContainer(): x/y are ignored inside a layout — the layout '
          'positions the container, pass only w and h',
        );
        w = wOrArgs.toDouble();
        hResolved = h ?? 0;
      }
      final pos = _layoutPlaceChild(_layoutStack.last, w, hResolved);
      _openContainer(
        pos.dx,
        pos.dy,
        w,
        hResolved,
        mapArgs,
        layoutManaged: true,
      );
      return;
    }

    if (wOrArgs is! num) {
      Flut5Console.printLater(
        'beginContainer(w, h) requires an open layout — call beginLayout() '
        'first, or pass x, y, w and h',
      );
      _openContainer(0, 0, xOrW, yOrH, mapArgs, layoutManaged: false);
      return;
    }

    if (h == null) {
      Flut5Console.printLater(
        'beginContainer(x, y, w, h): missing h — using 0',
      );
    }
    _openContainer(
      xOrW,
      yOrH,
      wOrArgs.toDouble(),
      h ?? 0,
      args,
      layoutManaged: false,
    );
  }

  /// Shared body of [beginContainer], called with the resolved position, size
  /// and args. [layoutManaged] marks containers positioned by an enclosing
  /// [beginLayout] scope; they open a nested layout frame so their own child
  /// containers flow inside them.
  void _openContainer(
    double x,
    double y,
    double w,
    double h,
    Map<String, dynamic>? args, {
    required bool layoutManaged,
  }) {
    final radiusArg = args?['borderRadius'];
    final double radius = (radiusArg is num) ? radiusArg.toDouble() : 0.0;
    final bool rounded = radius > 0;

    push();

    // In an aligned layout, reserve a placeholder translate inside the outer
    // scope: once the container's line completes, _finalizeLayoutLine patches
    // it in place with the align/justify shift. The whole container (background
    // rect included) moves with it, and the outer pop() contains it.
    if (layoutManaged) {
      final parent = _layoutStack.last;
      if (parent.aligned) {
        renderQueue.enqueue(TransformRenderItem.translate(0, 0));
        final parentHorizontal =
            parent.direction == Flut5LayoutDirection.horizontal;
        parent.lineEntries.add((
          slot: renderQueue.itemCount - 1,
          main: parentHorizontal ? w : h,
          cross: parentHorizontal ? h : w,
        ));
      }
    }

    translate(x, y);

    if (rounded) {
      rect(0, 0, w, h, radius, radius, radius, radius);
    } else {
      rect(0, 0, w, h);
    }

    // Inner scope so the clip, optional scroll translate, and any unbalanced
    // state inside the container stay contained.
    push();

    final overflow = _containerOverflow;
    if (overflow != Flut5ContainerOverflow.visible) {
      clipRect(0, 0, w, h, radius: rounded ? radius : null);
      _countClippingContainer();
    }

    var slot = -1;
    String? scrollId;
    if (overflow == Flut5ContainerOverflow.scroll) {
      // The scroll translate has to precede the content but its value isn't
      // known until the content's bounds are measured, so we remember the
      // slot here, let the content record unshifted, then endContainer()
      // measures and back-fills the translate.
      final idArg = args?['id'];
      scrollId = (idArg is String) ? idArg : '${x}_${y}_${w}_$h';

      renderQueue.flushPending();
      slot = renderQueue.itemCount;
    }

    _containerStack.add(_Flut5ContainerFrame(
      x: x,
      y: y,
      w: w,
      h: h,
      args: args,
      overflow: overflow,
      overscroll: _containerOverscroll,
      slot: slot,
      scrollId: scrollId,
      layoutManaged: layoutManaged,
      buildContext: () => _buildContainerContext(x, y, w, h),
    ));

    if (layoutManaged) {
      // The container flows its own child containers, using the direction /
      // gap / wrap / padding in effect when it opened (same snapshot rule as
      // containerOverflow). Its own size bounds the children's wrapping.
      final childHorizontal =
          _layoutDirection == Flut5LayoutDirection.horizontal;
      _layoutStack.add(_newLayoutFrame(
        outerMain: childHorizontal ? w : h,
        outerCross: childHorizontal ? h : w,
        isRoot: false,
      ));
    }
  }

  /// Closes the innermost container opened by [beginContainer]: in scroll mode
  /// measures the content recorded since [beginContainer] and back-fills the
  /// scroll translate, closes the container's transform/clip scopes, and
  /// dispatches this frame's buffered pointer events to the container's
  /// `'pointerDown'` / `'pointerUp'` / `'pointerMove'` / `'pointerDragged'`
  /// callbacks. For a container positioned by a [beginLayout] scope it also
  /// advances the layout's cursor, so the next sibling flows after it.
  ///
  /// Calling it without an open container is a no-op that logs a console
  /// warning — as is calling it inside a layout whose begin/end container
  /// pairs are already balanced, so a stray endContainer() cannot close a
  /// container opened outside the layout.
  void endContainer() {
    if (_containerStack.isEmpty) {
      Flut5Console.printLater(
        'endContainer() called without a matching beginContainer()',
      );
      return;
    }
    // Inside a layout scope, a valid endContainer() always closes a
    // layout-managed container whose layout frame sits on top of the stack.
    // A root frame on top means every container opened in the innermost
    // layout is already closed — this call would wrongly close a container
    // opened *outside* the layout, so refuse it instead.
    if (_layoutStack.isNotEmpty && _layoutStack.last.isRoot) {
      Flut5Console.printLater(
        'endContainer() called inside a layout without a matching '
        'beginContainer() in that layout — ignored; containers opened before '
        'beginLayout() must be closed after endLayout()',
      );
      return;
    }
    final frame = _containerStack.removeLast();

    if (frame.layoutManaged && _layoutStack.isNotEmpty) {
      // Close this container's own layout frame: finalize its children's last
      // line first — before the scroll back-fill below, whose insertAt would
      // shift the buffered placeholder indices (and so the content bounds it
      // measures include the align/justify shifts) — then advance the
      // enclosing frame's cursor past the container plus that frame's gap.
      _finalizeLayoutLine(_layoutStack.last);
      _layoutStack.removeLast();
      if (_layoutStack.isNotEmpty) {
        final parent = _layoutStack.last;
        parent.cursor +=
            (parent.direction == Flut5LayoutDirection.horizontal
                ? frame.w
                : frame.h) +
            parent.gap;
      }
    }

    if (frame.overflow == Flut5ContainerOverflow.scroll) {
      renderQueue.flushPending();
      final contentBounds = frame.overscroll == Flut5ContainerOverscroll.free
          ? null
          : renderQueue.contentBoundsFrom(frame.slot);
      final state = _updateContainerScroll(
        frame.scrollId!,
        frame.x,
        frame.y,
        frame.w,
        frame.h,
        contentBounds,
        frame.overscroll,
      );

      renderQueue.insertAt(
        frame.slot,
        TransformRenderItem.translate(state.offsetX, state.offsetY),
      );
    }

    pop(); // balance the inner push() (also removes the clip)
    pop(); // balance the outer push()

    // Dispatch buffered pointer events to the per-container callbacks. Done
    // after drawing and outside the transform scope: these are state-setting
    // handlers (like the sketch's), not draw calls.
    _dispatchContainerPointerEvents(
      frame.x,
      frame.y,
      frame.w,
      frame.h,
      frame.args,
    );
  }

  /// Force-closes containers left open by a missing [endContainer] and warns
  /// about them. Called by the painter once per frame after `draw()`, *after*
  /// [closeUnbalancedLayouts] (endLayout() closes the layout's own containers,
  /// leaving only ones opened outside any layout); not part of the
  /// sketch-facing API.
  void closeUnbalancedContainers() {
    if (_containerStack.isEmpty) return;
    Flut5Console.printLater(
      'beginContainer(): ${_containerStack.length} container(s) still open at '
      'the end of the frame — missing endContainer()',
    );
    while (_containerStack.isNotEmpty) {
      final before = _containerStack.length;
      endContainer();
      // endContainer() refuses to close a container opened outside a
      // still-open layout; bail out rather than spin — the remaining
      // containers close once the layouts are cleaned up.
      if (_containerStack.length >= before) break;
    }
  }

  /// Routes this frame's buffered pointer events to the `'pointerDown'` /
  /// `'pointerUp'` / `'pointerMove'` / `'pointerDragged'` callbacks in [args].
  /// Only events whose location falls inside the container's `(x, y, w, h)` rect
  /// are delivered, each with `location` / `plocation` rebased to coordinates
  /// local to the container's top-left corner. Bounds tests use canvas-local
  /// coordinates, matching the scroll path's root-transform assumption.
  void _dispatchContainerPointerEvents(
    double x,
    double y,
    double w,
    double h,
    Map<String, dynamic>? args,
  ) {
    if (args == null) return;
    final onDown = args['pointerDown'];
    final onUp = args['pointerUp'];
    final onMove = args['pointerMove'];
    final onDragged = args['pointerDragged'];
    final hasAny = onDown is void Function(SketchPointerEvent) ||
        onUp is void Function(SketchPointerEvent) ||
        onMove is void Function(SketchPointerEvent) ||
        onDragged is void Function(SketchPointerEvent);
    if (!hasAny) return;

    final events = pendingPointerEvents;
    if (events.isEmpty) return;

    for (final frame in events) {
      final loc = frame.event.location;
      if (loc.dx < x || loc.dx > x + w || loc.dy < y || loc.dy > y + h) {
        continue;
      }
      final handler = switch (frame.phase) {
        Flut5PointerPhase.down => onDown,
        Flut5PointerPhase.up => onUp,
        Flut5PointerPhase.move => onMove,
        Flut5PointerPhase.drag => onDragged,
      };
      if (handler is! void Function(SketchPointerEvent)) continue;
      final e = frame.event;
      handler(SketchPointerEvent(
        location: Offset(e.location.dx - x, e.location.dy - y),
        plocation: Offset(e.plocation.dx - x, e.plocation.dy - y),
        rawEvent: e.rawEvent,
        velocity: e.velocity,
      ));
    }
  }

  /// Builds the [Flut5ContainerContext] exposed via [containerContext] for an
  /// open container. Pointer state is scoped to the container's `(x, y, w, h)` rect,
  /// and pointer positions are shifted into container-local coordinates;
  /// velocities ([avgMouse] and friends) are left unshifted. Bounds tests use
  /// canvas-local coordinates, matching the scroll path's root-transform
  /// assumption.
  Flut5ContainerContext _buildContainerContext(
    double x,
    double y,
    double w,
    double h,
  ) {
    final localTouches = <Flut5Touch>[];
    var down = false;
    for (final t in touches) {
      if (t.x >= x && t.x <= x + w && t.y >= y && t.y <= y + h) {
        down = true;
        localTouches.add(Flut5Touch(
          id: t.id,
          x: t.x - x,
          y: t.y - y,
          px: t.px - x,
          py: t.py - y,
          velocity: t.velocity,
          kind: t.kind,
        ));
      }
    }
    final over = mouseX >= x && mouseX <= x + w && mouseY >= y && mouseY <= y + h;
    return Flut5ContainerContext(
      x: x,
      y: y,
      width: w,
      height: h,
      pointerIsDown: down,
      pointerIsOver: over,
      mouseX: mouseX - x,
      mouseY: mouseY - y,
      avgMouseX: avgMouseX,
      avgMouseY: avgMouseY,
      avgMouse: avgMouse,
      touches: List<Flut5Touch>.unmodifiable(localTouches),
    );
  }
}
