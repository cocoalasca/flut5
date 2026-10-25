import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../flut5_console.dart';
import '../../text/flut5_font.dart';
import '../flut5_shadow.dart';
import 'flut5_dash.dart';
import 'flut5_render_item.dart';
import 'items/flut5_multi_line_render_item.dart';
import 'items/flut5_multi_point_render_item.dart';
import 'items/flut5_path_render_item.dart';
import 'items/flut5_pixelate_render_item.dart';
import 'items/flut5_rect_render_item.dart';
import 'items/flut5_circle_render_item.dart';
import 'items/flut5_ellipse_render_item.dart';
import 'items/flut5_image_atlas_render_item.dart';
import 'items/flut5_image_render_item.dart';
import 'items/flut5_line_render_item.dart';
import 'items/flut5_arc_render_item.dart';
import 'items/flut5_background_render_item.dart';
import 'items/flut5_blur_render_item.dart';
import 'items/flut5_transform_render_item.dart';
import 'items/flut5_clip_render_item.dart';
export '../flut5_shadow.dart' show Flut5ShadowSpec;
export 'flut5_render_item.dart';
export 'items/flut5_arc_render_item.dart';
export 'items/flut5_background_render_item.dart';
export 'items/flut5_blur_render_item.dart';
export 'items/flut5_circle_render_item.dart';
export 'items/flut5_clip_render_item.dart';
export 'items/flut5_ellipse_render_item.dart';
export 'items/flut5_image_atlas_render_item.dart';
export 'items/flut5_image_render_item.dart';
export 'items/flut5_line_render_item.dart';
export 'items/flut5_path_render_item.dart';
export 'items/flut5_pixelate_render_item.dart';
export 'items/flut5_multi_line_render_item.dart';
export 'items/flut5_multi_point_render_item.dart';
export 'items/flut5_point_render_item.dart';
export 'items/flut5_rect_render_item.dart';
export 'items/flut5_text_dynamic_render_item.dart';
export 'items/flut5_text_render_item.dart';
export 'items/flut5_transform_render_item.dart';

/// A centralized queue for all drawing operations in a frame.
///
/// Elements are added to this queue during the `sketch.draw()` loop.
/// The pipeline executes the queue against the actual flutter [Canvas] exactly
/// once at the very end of the pipeline inside the underlying [CustomPainter],
/// allowing deferred rendering strategies (like depth-sorting) in the future.
///
/// The queue auto-batches consecutive same-paint primitives to cut GPU calls:
/// * Points coalesce into one [MultiPointRenderItem] ([Canvas.drawRawPoints]).
/// * Lines coalesce into one [MultiLineRenderItem] ([Canvas.drawRawPoints]
///   with [PointMode.lines]).
/// * Rects, circles, ellipses and arcs merge into a single [Path] rendered
///   with one [Canvas.drawPath] per aspect (fill / stroke).
///
/// Auto-batching preserves draw order: any non-batchable operation (path,
/// text, background, a shape with a different paint, or a primitive of
/// a different kind) flushes the pending batches first. So does an outlined
/// shape drawn over one already in the batch, when fill and stroke differ in
/// colour — its fill has to cover the earlier outline.
///
/// Translation, rotation and uniform scale are folded into compatible geometry
/// at append time, including across push/pop scopes. Uniform scale adjusts
/// stroke widths; differing widths split batches. Nonuniform scale, matrices,
/// and operations that require canvas-local paint effects still emit transforms.
class Flut5RenderQueue {
  final List<Flut5RenderItem> _items = [];

  // ── Pending points (auto-batched via drawRawPoints/PointMode.points) ──
  Float32List _pointBuffer = Float32List(0);
  int _pointCount = 0;
  Paint? _pendingPointPaint;
  Flut5ShadowSpec? _pendingPointShadow;

  // ── Pending lines (auto-batched via drawRawPoints/PointMode.lines) ────
  Float32List _lineBuffer = Float32List(0);
  int _lineCount = 0;
  Paint? _pendingLinePaint;
  Flut5ShadowSpec? _pendingLineShadow;

  // ── Pending shape path (rects, ovals, arcs merged into one Path) ──────
  Path? _pendingShapePath;
  Paint? _pendingShapeFill;
  Paint? _pendingShapeStroke;
  bool _pendingShapeHasContent = false;
  Flut5ShadowSpec? _pendingShapeShadow;

  // One path is not the same as its shapes drawn one by one where they
  // overlap: it paints every fill and then every stroke, so an earlier outline
  // would show through a later shape ([_stacks]), and it fills by winding, so
  // a counter-clockwise shape would punch a hole in a clockwise one. Batches
  // that can show either keep their shapes' boxes here ([_pendingShapeTracked])
  // and close as soon as a new shape lands where that would happen.
  final _ShapeOverlapIndex _pendingShapeBoxes = _ShapeOverlapIndex();
  bool _pendingShapeTracked = false;
  Paint? _stacksFill;
  Paint? _stacksStroke;
  bool _stacksResult = false;

  // ── Pending image atlas (same-source blits merged via drawRawAtlas) ───
  //
  // Consecutive image() calls collapse into one Canvas.drawRawAtlas when they
  // sample the same ui.Image and each scales proportionally. An RSTransform
  // carries a single uniform scale per sprite, so sizes may differ freely
  // between calls, but a non-proportional stretch cannot be expressed and
  // falls out to its own item. A shadowed image opts out too: the silhouette
  // pass would need a second atlas draw beneath, and shadowed sprite floods
  // are rare enough not to justify it.
  ui.Image? _pendingAtlasImage;
  BlendMode _pendingAtlasBlend = BlendMode.srcOver;
  Float32List _atlasTransforms = Float32List(0);
  Float32List _atlasRects = Float32List(0);
  int _atlasCount = 0;
  bool _atlasHasRotation = false;

  /// Running union of the destination rects in the open run, so the flushed
  /// item carries bounds without re-reading the float32 buffers.
  Rect? _atlasBounds;

  /// First sprite's rects in full double precision. A run that never grows
  /// past one flushes as a plain [ImageRenderItem] instead, which is both
  /// cheaper and bit-exact — see [_flushImages].
  Rect? _atlasFirstSrc;
  Rect? _atlasFirstDst;
  _FoldTransform? _atlasFirstFold;

  /// Relative tolerance for calling a blit's x and y scales equal.
  ///
  /// Deliberately tight. Batching must never move a pixel: anything but a
  /// genuinely proportional draw falls out to its own item rather than being
  /// approximated, which keeps the atlas path invisible in the output.
  static const double _atlasScaleTolerance = 1e-6;

  void _ensureAtlasCapacity(int sprites) {
    final needed = sprites * 4;
    if (_atlasTransforms.length >= needed) return;
    int newLen = _atlasTransforms.isEmpty ? 64 : _atlasTransforms.length * 2;
    while (newLen < needed) {
      newLen *= 2;
    }
    final used = _atlasCount * 4;
    _atlasTransforms = Float32List(newLen)..setRange(0, used, _atlasTransforms);
    _atlasRects = Float32List(newLen)..setRange(0, used, _atlasRects);
  }

  // ── Polygon scratch (triangle/quad appended without list allocations) ─
  //
  // Consumed synchronously by [_appendPoly] before the call returns, so a
  // single reusable pair of buffers is safe.
  Float64List _polyXs = Float64List(8);
  Float64List _polyYs = Float64List(8);

  void _ensurePolyCapacity(int n) {
    if (_polyXs.length >= n) return;
    int len = _polyXs.length * 2;
    while (len < n) {
      len *= 2;
    }
    _polyXs = Float64List(len);
    _polyYs = Float64List(len);
  }

  // ── Geometry transform folding ────────────────────────────────────────
  // Similarities (translation, rotation, uniform scale) are baked into safe
  // geometry. Opaque operations and unsupported paints materialize the state
  // on the canvas. Saved states then become real canvas saves; folding can
  // resume relative to that canvas transform.
  _FoldTransform _fold = const _FoldTransform();
  final List<(_FoldTransform, bool)> _foldStack = [];
  final Map<Paint, Map<double, Paint>> _scaledStrokes = Map.identity();
  // addPath consumes these synchronously. Only the destination path is queued.
  final Path _transformPath = Path();
  final Float64List _transformMatrix = Float64List.fromList([
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);

  double get _foldDx => _fold.dx;
  double get _foldDy => _fold.dy;
  bool get _hasFoldOffset => _foldDx != 0.0 || _foldDy != 0.0;

  // Shadows, dashes and shaders depend on the original local coordinate
  // system. Keep their existing canvas rendering rather than transforming
  // only the outline and silently changing their appearance.
  void _prepareGeometry(Paint? fill, Paint? stroke, {bool points = false}) {
    if (!_fold.hasLinear) {
      // A shader is laid out in the sketch's coordinates. Moving only the
      // geometry would slide the shape out from under its gradient.
      if (_hasFoldOffset && (fill?.shader != null || stroke?.shader != null)) {
        _materializeTransforms();
      }
      return;
    }
    if (_activeShadow != null ||
        (_hasDash && stroke != null && !points) ||
        _drawnAlone(fill, stroke) ||
        (points && stroke?.strokeCap != StrokeCap.round)) {
      _materializeTransforms();
    }
  }

  Paint? _foldStroke(Paint? stroke) {
    if (stroke == null || _fold.scale == 1 || stroke.strokeWidth == 0) {
      return stroke;
    }
    final variants = _scaledStrokes.putIfAbsent(stroke, () => {});
    return variants.putIfAbsent(
      _fold.scale,
      () => Paint.from(stroke)..strokeWidth = stroke.strokeWidth * _fold.scale,
    );
  }

  /// [localBounds] is [path]'s box before the fold; omit it to have the path
  /// measured, which only happens when the batch needs it. [oriented] as in
  /// [_beginShape] — the fold never mirrors, so it carries over unchanged.
  void _appendTransformedPath(
    Path path,
    Paint? fill,
    Paint? stroke, {
    Rect? localBounds,
    bool oriented = true,
  }) {
    if (fill == null && stroke == null) return;
    stroke = _foldStroke(stroke);
    final bounds = _wantsBox(fill, stroke, oriented)
        ? _fold.bounds(localBounds ?? path.getBounds())
        : null;
    _fold.writeMatrix(_transformMatrix);
    _beginShape(
      fill,
      stroke,
      bounds,
      oriented: oriented,
    ).addPath(path, Offset.zero, matrix4: _transformMatrix);
    _pendingShapeHasContent = true;
  }

  /// True when a rect or oval built from [rect] traces counter-clockwise:
  /// flipped on exactly one axis, by a negative width *or* height.
  static bool _backwards(Rect rect) =>
      (rect.left > rect.right) != (rect.top > rect.bottom);

  /// [rect] sorted so it traces clockwise like every other batched shape.
  ///
  /// Only for geometry that is filled and not stroked: a fill rasterizes
  /// identically either way round, a stroke's anti-aliasing does not. Stroked
  /// shapes are left as given and reported through `oriented` instead.
  static Rect _clockwise(Rect rect) => _backwards(rect)
      ? Rect.fromLTRB(
          math.min(rect.left, rect.right),
          math.min(rect.top, rect.bottom),
          math.max(rect.left, rect.right),
          math.max(rect.top, rect.bottom),
        )
      : rect;

  // ── Background bookkeeping (kept O(1) instead of scanning _items) ─────
  BackgroundRenderItem? _lastBackground;
  bool _hasOpaqueFullCanvasBg = false;

  // ── Transform entry points (called by the transform mixin) ────────────

  /// Records a `push()`. Saves the pending transform without emitting an item.
  void pushTransform() {
    _foldStack.add((_fold, false));
  }

  /// Records a `pop()`. Folded entries restore the pending transform silently;
  /// materialized (`real`) entries emit a canvas restore.
  void popTransform() {
    if (_scopes.isNotEmpty && _foldStack.length == _scopes.last.depth) {
      final name = _scopeName(_scopes.last.pixelate);
      Flut5Console.printLater(
        'pop() inside begin$name()/end$name() has no push() inside the scope '
        'to match and was ignored.',
      );
      return;
    }
    if (_foldStack.isEmpty) {
      // Unbalanced pop — legacy behavior: emit a raw restore and let
      // Canvas ignore it at baseline depth.
      if (_clipRecordingPath != null) {
        Flut5Console.printLater(
          'clip(): unbalanced pop() inside clip callback ignored.',
        );
        return;
      }
      _materializeTransforms();
      _addItem(TransformRenderItem.pop());
      return;
    }
    if (_foldStack.last.$2 && _clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): pop() of a scope opened outside the clip callback was '
        'ignored inside the callback.',
      );
      return;
    }
    final (saved, real) = _foldStack.removeLast();
    if (real) {
      _addItem(TransformRenderItem.pop());
    }
    _fold = saved;
  }

  /// Records a `translate()`. Never emits an item — the offset is baked into
  /// geometry at append time, so batches keep accumulating across it.
  void translateTransform(double dx, double dy) {
    _fold = _fold.translated(dx, dy);
  }

  /// Folds rotations and nonzero uniform scales into subsequent geometry.
  /// Other transforms materialize the folded state and close pending batches.
  void applyTransform(TransformRenderItem item) {
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): rotate()/scale()/applyMatrix() are not supported inside a '
        'clip callback and were ignored (translate/push/pop do apply).',
      );
      return;
    }
    if (item.type == TransformType.rotate && item.rotation!.isFinite) {
      _fold = _fold.rotated(item.rotation!);
      return;
    }
    if (item.type == TransformType.scale &&
        item.scaleX == item.scaleY &&
        item.scaleX!.isFinite &&
        item.scaleX != 0) {
      final next = _fold.scaled(item.scaleX!);
      // Keep the folded state invertible for materializing nested saves.
      final determinant = next.a * next.a + next.b * next.b;
      if (determinant.isFinite && determinant > 0) {
        _fold = next;
        return;
      }
    }
    _materializeTransforms();
    _addItem(item);
  }

  /// Moves pending transforms onto the canvas, preserving every saved scope.
  /// Each saved transform is relative to the last materialized canvas state.
  /// Emit the delta between saved states before their corresponding save.
  void _materializeTransforms() {
    if (_fold.isIdentity && !_foldStack.any((entry) => !entry.$2)) return;
    flushPending();
    var previous = const _FoldTransform();
    for (int i = 0; i < _foldStack.length; i++) {
      final (saved, real) = _foldStack[i];
      if (real) continue;
      _emitFoldDelta(previous, saved);
      _items.add(TransformRenderItem.push());
      previous = saved;
      _foldStack[i] = (const _FoldTransform(), true);
    }
    _emitFoldDelta(previous, _fold);
    _fold = const _FoldTransform();
  }

  void _emitFoldDelta(_FoldTransform from, _FoldTransform to) {
    final delta = to.relativeTo(from);
    if (delta.isIdentity) return;
    if (!delta.hasLinear) {
      _items.add(TransformRenderItem.translate(delta.dx, delta.dy));
    } else {
      _items.add(TransformRenderItem.matrix(delta.matrix));
    }
  }

  // ── Line dash state ───────────────────────────────────────────────────
  //
  // Mirrors the stroke mixin's dash pattern. Unlike points/lines/shapes this
  // is *persistent* render-setting state, not per-frame content, so it is
  // pushed in by [setDashState] whenever the sketch calls setLineDash() and is
  // deliberately NOT reset by [clear]. When active, stroked geometry is drawn
  // on a dashed copy of its outline (fill stays solid) — see [_emitDashed].
  List<double>? _dashPattern;
  double _dashOffset = 0;
  bool get _hasDash => _dashPattern != null;

  /// Updates the active line-dash pattern. Pass a `null`/empty [pattern] to
  /// disable dashing. Pending batches are flushed first so already-queued
  /// geometry keeps the dash state it was drawn under.
  void setDashState(List<double>? pattern, double offset) {
    _flushShapes();
    _flushLines();
    _dashPattern = (pattern != null && pattern.isNotEmpty) ? pattern : null;
    _dashOffset = offset;
  }

  // ── Drop-shadow state ─────────────────────────────────────────────────
  //
  // Like dash state this is *persistent* render-setting state (set by the
  // sketch's shadow()/noShadow()), not per-frame content, so it is deliberately
  // NOT reset by [clear]. When active, the shadow rides along on the shape /
  // point / line batches (drawn once beneath the whole run — setShadowState
  // flushes, so a run never spans a shadow change); only un-batchable paints
  // fall back to a per-shape item carrying [activeShadow]. `null` means no
  // shadow — the batched fast path runs unchanged.
  Flut5ShadowSpec? _activeShadow;

  /// The active drop shadow, or `null` when shadows are off. Read by the engine
  /// (`endBatch`) and text mixin so explicitly-batched and text draws pick it up.
  Flut5ShadowSpec? get activeShadow => _activeShadow;

  /// Updates the active drop shadow. Pass `null` to disable. Pending batches are
  /// flushed first so already-queued geometry keeps the shadow it was drawn under.
  void setShadowState(Flut5ShadowSpec? shadow) {
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    _activeShadow = shadow;
  }

  // ── Blur state ────────────────────────────────────────────────────────
  //
  // Persistent render-setting state like the shadow (set by the sketch's
  // blur()/noBlur()), so it is deliberately NOT reset by [clear]. While
  // active, every draw is blurred on its own — a plain fill through a mask
  // filter ([_maskBlurredFill]), anything else in its own [BlurRenderItem]
  // layer — and nothing batches: one blurred path is not its shapes blurred one by one wherever
  // their halos meet, and the blur's own sampling depends on what the layer
  // holds. `null` means no blur — the batched fast path runs unchanged.
  Paint? _blurLayer;
  double _blurSigma = 0;

  /// The active blur's Gaussian sigma in logical pixels, `0` when off.
  double get activeBlur => _blurSigma;

  /// Updates the active blur. A [sigma] that is not a positive finite number
  /// turns it off. Unchanged values return early, keeping the layer paint
  /// identity-stable; a change flushes pending batches first, like
  /// [setShadowState].
  void setBlurState(double sigma) {
    if (!(sigma.isFinite && sigma > 0)) sigma = 0;
    if (sigma == _blurSigma) return;
    flushPending();
    _blurSigma = sigma;
    _maskSource = null;
    _maskPaint = null;
    _blurLayer = sigma == 0 ? null : _layerPaintFor(sigma);
  }

  // One-entry memo for [_layerPaintFor], shared by blur() and beginBlur().
  Paint? _layerPaint;
  double _layerPaintSigma = 0;

  /// A layer paint that blurs by [sigma], reused while [sigma] repeats.
  Paint _layerPaintFor(double sigma) {
    final cached = _layerPaint;
    if (cached != null && sigma == _layerPaintSigma) return cached;
    _layerPaintSigma = sigma;
    // Decal, not the default clamp: the layer holds just the drawn content,
    // and clamping would stretch its edge pixels outward instead of fading.
    return _layerPaint = Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.decal,
      );
  }

  /// True when a shape painted with [fill]/[stroke] has to be its own item:
  /// a paint [canBatchPaint] rejects, or an active blur.
  bool _drawnAlone(Paint? fill, Paint? stroke) =>
      _blurLayer != null || !canBatchPaint(fill) || !canBatchPaint(stroke);

  // One-entry memo for [_maskBlurredFill], keyed on the source paint's
  // identity — paint snapshots are immutable once queued and stay identical
  // while the fill doesn't change. Cleared by [setBlurState].
  Paint? _maskSource;
  Paint? _maskPaint;

  /// [fill] carrying the active blur as a [MaskFilter], or `null` when the
  /// shape needs a [BlurRenderItem] layer instead.
  ///
  /// A plain fill blurs the same either way — it is one colour over one
  /// coverage mask — and the mask route is the cheap one: no offscreen
  /// layer, and Impeller blurs rects, rounded rects and circles
  /// analytically. Measured on Impeller it is also the closer of the two to
  /// an exact Gaussian. A stroke, gradient, shadow, blend mode or filter
  /// keeps the layer: a stroke blurs together with its fill there, and
  /// Impeller's mask blur misses stroked corners at small radii.
  Paint? _maskBlurredFill(Paint? fill, Paint? stroke) {
    final layer = _blurLayer;
    if (layer == null ||
        fill == null ||
        stroke != null ||
        _activeShadow != null ||
        fill.shader != null ||
        fill.blendMode != BlendMode.srcOver ||
        fill.maskFilter != null ||
        fill.colorFilter != null ||
        fill.imageFilter != null) {
      return null;
    }
    if (identical(fill, _maskSource)) return _maskPaint;
    _maskSource = fill;
    return _maskPaint = Paint.from(fill)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, _blurSigma);
  }

  // ── Save-stack imbalance warning throttle ─────────────────────────────
  //
  // Tracks whether an "unbalanced canvas stack" warning has already been
  // emitted, so a sketch that leaks a push()/clip() every frame warns once
  // rather than 60×/sec. Reset back to false the first balanced frame.
  bool _warnedSaveImbalance = false;

  // ── Pixelate and blur scopes ──────────────────────────────────────────
  //
  // A scope is a pair of marker items. A blur scope's markers open and close
  // one blurred layer; a pixelate scope's are read by the replay, which
  // renders what lies between them at block resolution (see
  // [_PixelatePass]). Markers, not a wrapper item, because containers patch
  // queued items by index and a wrapper would have to move the scope's items.
  //
  // Both kinds act as push()/pop(): what lies between the markers replays
  // inside a layer or onto the low-resolution canvas, so a transform
  // materialized in there is undone when the scope closes and must not
  // outlive it in the fold either. Scopes nest but cannot cross.

  /// Each open scope, innermost last: the fold-stack depth just above its
  /// own entry, and its kind.
  final List<({int depth, bool pixelate})> _scopes = [];

  /// Whether this frame holds a pixelate scope, so other frames keep the
  /// plain replay. Blur scopes need nothing from the replay.
  bool _hasPixelate = false;
  bool _warnedOpenScope = false;
  bool _warnedScopeLeak = false;

  static String _scopeName(bool pixelate) => pixelate ? 'Pixelate' : 'Blur';

  /// Opens a pixelate scope of [blockSize] logical pixels over a canvas of
  /// [width]×[height]. Pending batches flush first, so nothing drawn before
  /// the scope joins a batch inside it.
  void beginPixelate(double blockSize, double width, double height) {
    _beginScope(
      PixelateBeginRenderItem(blockSize, width, height),
      pixelate: true,
    );
    _hasPixelate = true;
  }

  /// Closes the innermost pixelate scope, restoring the transform active at
  /// [beginPixelate]. A push() left open inside the scope is popped here.
  void endPixelate() => _endScope(PixelateEndRenderItem(), pixelate: true);

  /// Opens a blur scope: everything until [endBlur] draws into one layer,
  /// blurred as a whole by a Gaussian of [sigma] when it closes. A [sigma]
  /// that is not a positive finite number blurs nothing but still scopes
  /// transforms. Pending batches flush first, as for [beginPixelate].
  void beginBlur(double sigma) {
    final blurs = sigma.isFinite && sigma > 0;
    _beginScope(
      BlurBeginRenderItem(blurs ? _layerPaintFor(sigma) : null),
      pixelate: false,
    );
  }

  /// Closes the innermost blur scope, restoring the transform active at
  /// [beginBlur]. A push() left open inside the scope is popped here.
  void endBlur() => _endScope(BlurEndRenderItem(), pixelate: false);

  void _beginScope(Flut5RenderItem marker, {required bool pixelate}) {
    if (_clipRecordingPath != null) {
      throw StateError(
        'begin${_scopeName(pixelate)}() cannot be used inside a clip().',
      );
    }
    // Put the transforms folded so far on the frame canvas. Left folded, the
    // first materialization inside the scope would emit them between the
    // markers, where closing the scope undoes them, and lose them for
    // everything drawn after it.
    _materializeTransforms();
    flushPending();
    pushTransform();
    _scopes.add((depth: _foldStack.length, pixelate: pixelate));
    _items.add(marker);
  }

  void _endScope(Flut5RenderItem marker, {required bool pixelate}) {
    final name = _scopeName(pixelate);
    if (_scopes.isEmpty) {
      throw FlutterError('end$name() called without begin$name()');
    }
    final scope = _scopes.last;
    if (scope.pixelate != pixelate) {
      final open = _scopeName(scope.pixelate);
      throw FlutterError(
        'end$name() called while a begin$open() scope is open — close it '
        'with end$open() first. Scopes nest but cannot cross.',
      );
    }
    if (_clipRecordingPath != null) {
      throw StateError('end$name() cannot be used inside a clip().');
    }
    if (_foldStack.length > scope.depth && !_warnedScopeLeak) {
      _warnedScopeLeak = true;
      Flut5Console.printLater(
        'end$name() closed ${_foldStack.length - scope.depth} push() left '
        'open inside the scope. Add the missing pop() to fix it.',
      );
    }
    while (_foldStack.length > scope.depth) {
      popTransform();
    }
    _scopes.removeLast();
    popTransform();
    flushPending();
    _items.add(marker);
  }

  /// Closes every scope still open, with a one-time warning — the replay
  /// calls this so a forgotten end*() still draws, mirroring the save-stack
  /// auto-restore in [_balanceSaveStack].
  void _closeOpenScopes() {
    if (_scopes.isEmpty) {
      _warnedOpenScope = false;
      return;
    }
    if (!_warnedOpenScope) {
      _warnedOpenScope = true;
      final name = _scopeName(_scopes.last.pixelate);
      Flut5Console.printLater(
        'begin$name() was left open this frame and was closed at the end of '
        'draw(). Add the missing end$name() to fix it.',
      );
    }
    while (_scopes.isNotEmpty) {
      final pixelate = _scopes.last.pixelate;
      _endScope(
        pixelate ? PixelateEndRenderItem() : BlurEndRenderItem(),
        pixelate: pixelate,
      );
    }
  }

  // ── Clip mask recording ───────────────────────────────────────────────
  //
  // While a clip() callback is running, append* calls divert their path
  // geometry into [_clipRecordingPath] instead of producing visible render
  // items. The accumulated path is then handed off to a [ClipRenderItem].
  Path? _clipRecordingPath;

  /// True while a `clip()` callback is recording its mask path. Drawing calls
  /// made during this window contribute to the mask instead of the frame.
  bool get isRecordingClip => _clipRecordingPath != null;

  /// Starts recording subsequent `append*` calls into a fresh mask path.
  /// The folded transform state is materialized first — the resulting
  /// [ClipRenderItem] executes in canvas space, so the canvas transform must
  /// already reflect any folded translation, and the enclosing folded push
  /// must become a real save so the eventual pop lifts the clip. Pending
  /// batched shapes are flushed so they remain visible (they belong to the
  /// pre-clip content, not the mask).
  void beginClipRecording() {
    if (_clipRecordingPath != null) {
      throw StateError('clip() callbacks cannot be nested.');
    }
    _materializeTransforms();
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    _clipRecordingPath = Path();
  }

  /// Stops clip recording and returns the accumulated mask path.
  Path endClipRecording() {
    final p = _clipRecordingPath;
    if (p == null) {
      throw StateError(
        'endClipRecording() called without beginClipRecording().',
      );
    }
    _clipRecordingPath = null;
    return p;
  }

  /// Appends glyph outline commands (from `textToPaths`) to the active
  /// clip-recording path. Silently no-ops when no clip is being recorded.
  /// The fold offset is applied so `translate()` inside the clip callback
  /// moves text masks the same way it moves shape masks.
  void addTextCommandsToClip(List<PathCommand> commands) {
    final p = _clipRecordingPath;
    if (p == null) return;
    final fdx = _foldDx, fdy = _foldDy;
    for (final c in commands) {
      switch (c) {
        case MoveToCommand(:final x, :final y):
          p.moveTo(x + fdx, y + fdy);
        case LineToCommand(:final x, :final y):
          p.lineTo(x + fdx, y + fdy);
        case QuadToCommand(:final cx, :final cy, :final x, :final y):
          p.quadraticBezierTo(cx + fdx, cy + fdy, x + fdx, y + fdy);
        case CubicToCommand(
          :final cx1,
          :final cy1,
          :final cx2,
          :final cy2,
          :final x,
          :final y,
        ):
          p.cubicTo(
            cx1 + fdx,
            cy1 + fdy,
            cx2 + fdx,
            cy2 + fdy,
            x + fdx,
            y + fdy,
          );
        case CloseCommand():
          p.close();
      }
    }
  }

  /// Returns true when [paint] is safe to merge with others into a single
  /// draw call. Translucent colors, shaders, non-default blend modes, or
  /// image/color/mask filters can produce visibly different output when
  /// many shapes are combined into one path (overlapping regions blend
  /// once instead of per-shape), so those paints fall back to per-shape
  /// render items.
  static bool canBatchPaint(Paint? paint) {
    if (paint == null) return true;
    if (paint.color.a != 1.0) return false;
    if (paint.shader != null) return false;
    if (paint.blendMode != BlendMode.srcOver) return false;
    if (paint.maskFilter != null) return false;
    if (paint.colorFilter != null) return false;
    if (paint.imageFilter != null) return false;
    return true;
  }

  // ── Append entry points ───────────────────────────────────────────────

  /// True when there are no queued or pending draw operations for this frame.
  bool get isEmpty =>
      _items.isEmpty &&
      _pointCount == 0 &&
      _lineCount == 0 &&
      _atlasCount == 0 &&
      !_pendingShapeHasContent;

  /// Append a point to the auto-batch buffer. Consecutive calls with the same
  /// [paint] reference coalesce; a change in paint identity flushes the prior
  /// run as a single [MultiPointRenderItem] (one GPU call).
  ///
  /// An active drop shadow rides along on the batch (drawn once beneath the
  /// whole run) instead of forcing one item per point.
  ///
  /// Z-order is preserved: any pending line or shape batch flushes first.
  void appendPoint(double x, double y, Paint paint) {
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): point() ignored inside clip callback — points have no area '
        'and cannot bound a mask region. Use circle() for dot-shaped masks.',
      );
      return;
    }
    _prepareGeometry(null, paint, points: true);
    paint = _foldStroke(paint)!;
    final transformedX = _fold.x(x, y);
    y = _fold.y(x, y);
    x = transformedX;
    if (_pendingPointPaint != null && !identical(_pendingPointPaint, paint)) {
      _flushPoints();
    }
    _flushLines();
    _flushShapes();
    _flushImages();
    _pendingPointPaint = paint;
    _pendingPointShadow = _activeShadow;
    _ensurePointCapacity(_pointCount + 2);
    _pointBuffer[_pointCount++] = x;
    _pointBuffer[_pointCount++] = y;
    // Blurred points draw one by one — the run never grows past this point.
    if (_blurLayer != null) _addItem(_takePoints());
  }

  /// Append a line segment to the auto-batch buffer. Consecutive calls with
  /// the same [paint] reference coalesce into a single [MultiLineRenderItem]
  /// rendered with [Canvas.drawRawPoints]/[PointMode.lines].
  ///
  /// An active drop shadow rides along on the batch (drawn once beneath the
  /// whole run) instead of forcing one item per segment.
  void appendLine(double x1, double y1, double x2, double y2, Paint paint) {
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): line() ignored inside clip callback — strokes have no area '
        'and cannot bound a mask region.',
      );
      return;
    }
    _prepareGeometry(null, paint);
    paint = _foldStroke(paint)!;
    final transformedX1 = _fold.x(x1, y1);
    final transformedX2 = _fold.x(x2, y2);
    y1 = _fold.y(x1, y1);
    y2 = _fold.y(x2, y2);
    x1 = transformedX1;
    x2 = transformedX2;
    if (_hasDash) {
      _emitDashed(
        Path()
          ..moveTo(x1, y1)
          ..lineTo(x2, y2),
        null,
        paint,
      );
      return;
    }
    if (_drawnAlone(null, paint)) {
      _addItem(
        LineRenderItem(
          Offset(x1, y1),
          Offset(x2, y2),
          paint,
          shadow: _activeShadow,
        ),
      );
      return;
    }
    // Merge into an open shape batch that strokes with the identical paint:
    // a 2-point sub-path strokes the same as a PointMode.lines segment (caps
    // apply per sub-path, and its zero area adds nothing to the fill pass),
    // so `rect(); line(); rect();` stays one draw call instead of three
    // items. Exception: a *filled* batch under an active shadow casts its
    // shadow from the fill silhouette, which a zero-area line sub-path adds
    // nothing to — the line's shadow would vanish. Keep the line in the line
    // buffer there, where it casts its own stroke shadow. (Stroke-only
    // batches shadow via the stroke outline, so merging stays safe.)
    if (_lineCount == 0 &&
        _pendingShapeHasContent &&
        identical(_pendingShapeStroke, paint) &&
        (_activeShadow == null || _pendingShapeFill == null)) {
      _pendingShapePath!
        ..moveTo(x1, y1)
        ..lineTo(x2, y2);
      // The line strokes with the batch, after every fill — a later shape
      // drawn across it has to split off to cover it.
      if (_stacks(_pendingShapeFill, paint)) {
        _pendingShapeBoxes.add(x1, y1, x2, y2);
      }
      return;
    }
    if (_pendingLinePaint != null && !identical(_pendingLinePaint, paint)) {
      _flushLines();
    }
    _flushPoints();
    _flushShapes();
    _flushImages();
    _pendingLinePaint = paint;
    _pendingLineShadow = _activeShadow;
    _ensureLineCapacity(_lineCount + 4);
    _lineBuffer[_lineCount++] = x1;
    _lineBuffer[_lineCount++] = y1;
    _lineBuffer[_lineCount++] = x2;
    _lineBuffer[_lineCount++] = y2;
  }

  /// Append a rectangle (or rounded rectangle) to the pending shape path.
  ///
  /// Falls back to a per-shape [RectRenderItem] when the paint can't be
  /// safely merged (translucent, shader, filter, non-srcOver blend).
  void appendRect(Rect rect, RRect? rrect, Paint? fill, Paint? stroke) {
    _prepareGeometry(fill, stroke);
    if (_fold.hasLinear) {
      if (fill == null && stroke == null) return;
      if (rrect == null) {
        stroke = _foldStroke(stroke);
        if (stroke == null) rect = _clockwise(rect);
        final oriented = !_backwards(rect);
        final path = _beginShape(
          fill,
          stroke,
          _wantsBox(fill, stroke, oriented) ? _fold.bounds(rect) : null,
          oriented: oriented,
        );
        path.moveTo(_fold.x(rect.left, rect.top), _fold.y(rect.left, rect.top));
        path.lineTo(
          _fold.x(rect.right, rect.top),
          _fold.y(rect.right, rect.top),
        );
        path.lineTo(
          _fold.x(rect.right, rect.bottom),
          _fold.y(rect.right, rect.bottom),
        );
        path.lineTo(
          _fold.x(rect.left, rect.bottom),
          _fold.y(rect.left, rect.bottom),
        );
        path.close();
        _pendingShapeHasContent = true;
      } else {
        _transformPath
          ..reset()
          ..addRRect(rrect);
        _appendTransformedPath(
          _transformPath,
          fill,
          stroke,
          localBounds: rrect.outerRect,
          oriented: rrect.width >= 0 && rrect.height >= 0,
        );
      }
      return;
    }
    if (_hasFoldOffset) {
      final off = Offset(_foldDx, _foldDy);
      rect = rect.shift(off);
      rrect = rrect?.shift(off);
    }
    if (_clipRecordingPath != null) {
      if (rrect != null) {
        _clipRecordingPath!.addRRect(rrect);
      } else {
        _clipRecordingPath!.addRect(_clockwise(rect));
      }
      return;
    }
    if (fill == null && stroke == null) return;
    if (_hasDash && stroke != null) {
      final outline = rrect != null
          ? (Path()..addRRect(rrect))
          : (Path()..addRect(rect));
      _emitDashed(outline, fill, stroke);
      return;
    }
    if (_drawnAlone(fill, stroke)) {
      final masked = _maskBlurredFill(fill, stroke);
      _addItem(
        RectRenderItem(
          rect,
          rrect,
          masked ?? fill,
          stroke,
          shadow: _activeShadow,
        ),
        blurred: masked != null,
      );
      return;
    }
    if (rrect != null) {
      _beginShape(
        fill,
        stroke,
        rrect.outerRect,
        oriented: rrect.width >= 0 && rrect.height >= 0,
      ).addRRect(rrect);
    } else {
      if (stroke == null) rect = _clockwise(rect);
      _beginShape(
        fill,
        stroke,
        rect,
        oriented: !_backwards(rect),
      ).addRect(rect);
    }
    _pendingShapeHasContent = true;
  }

  /// Append a circle to the pending shape path.
  void appendCircle(Offset center, double radius, Paint? fill, Paint? stroke) {
    _prepareGeometry(fill, stroke);
    if (_fold.hasLinear) {
      if (fill == null && stroke == null) return;
      final placed = Offset(
        _fold.x(center.dx, center.dy),
        _fold.y(center.dx, center.dy),
      );
      final oval = Rect.fromCircle(
        center: placed,
        radius: radius * _fold.scale,
      );
      _beginShape(fill, _foldStroke(stroke), oval).addOval(oval);
      _pendingShapeHasContent = true;
      return;
    }
    if (_hasFoldOffset) {
      center = center.translate(_foldDx, _foldDy);
    }
    if (_clipRecordingPath != null) {
      _clipRecordingPath!.addOval(
        Rect.fromCircle(center: center, radius: radius),
      );
      return;
    }
    if (fill == null && stroke == null) return;
    if (_hasDash && stroke != null) {
      _emitDashed(
        Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
        fill,
        stroke,
      );
      return;
    }
    if (_drawnAlone(fill, stroke)) {
      final masked = _maskBlurredFill(fill, stroke);
      _addItem(
        CircleRenderItem(
          center,
          radius,
          masked ?? fill,
          stroke,
          shadow: _activeShadow,
        ),
        blurred: masked != null,
      );
      return;
    }
    final oval = Rect.fromCircle(center: center, radius: radius);
    _beginShape(fill, stroke, oval).addOval(oval);
    _pendingShapeHasContent = true;
  }

  /// Append an ellipse (oval) to the pending shape path.
  void appendEllipse(Rect rect, Paint? fill, Paint? stroke) {
    _prepareGeometry(fill, stroke);
    if (_fold.hasLinear) {
      if (stroke == null) rect = _clockwise(rect);
      _transformPath
        ..reset()
        ..addOval(rect);
      _appendTransformedPath(
        _transformPath,
        fill,
        stroke,
        localBounds: rect,
        oriented: !_backwards(rect),
      );
      return;
    }
    if (_hasFoldOffset) {
      rect = rect.shift(Offset(_foldDx, _foldDy));
    }
    if (_clipRecordingPath != null) {
      _clipRecordingPath!.addOval(_clockwise(rect));
      return;
    }
    if (fill == null && stroke == null) return;
    if (_hasDash && stroke != null) {
      _emitDashed(Path()..addOval(rect), fill, stroke);
      return;
    }
    if (_drawnAlone(fill, stroke)) {
      final masked = _maskBlurredFill(fill, stroke);
      _addItem(
        EllipseRenderItem(rect, masked ?? fill, stroke, shadow: _activeShadow),
        blurred: masked != null,
      );
      return;
    }
    if (stroke == null) rect = _clockwise(rect);
    _beginShape(fill, stroke, rect, oriented: !_backwards(rect)).addOval(rect);
    _pendingShapeHasContent = true;
  }

  /// Append an arc to the pending shape path.
  ///
  /// When [useCenter] is true, the arc is connected to the centre of [rect]
  /// (pie slice). Open arcs are added as a new sub-path via [Path.arcTo] with
  /// `forceMoveTo: true` so they don't connect to the previous sub-path.
  void appendArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint? fill,
    Paint? stroke,
  ) {
    _prepareGeometry(fill, stroke);
    // A backwards sweep (or a mirrored oval) traces the arc counter-clockwise.
    final oriented = sweepAngle >= 0 && rect.width >= 0 && rect.height >= 0;
    if (_fold.hasLinear) {
      final path = _transformPath..reset();
      if (useCenter) path.moveTo(rect.center.dx, rect.center.dy);
      path.arcTo(rect, startAngle, sweepAngle, !useCenter);
      if (useCenter) path.close();
      _appendTransformedPath(
        path,
        fill,
        stroke,
        localBounds: rect,
        oriented: oriented,
      );
      return;
    }
    if (_hasFoldOffset) {
      rect = rect.shift(Offset(_foldDx, _foldDy));
    }
    if (_clipRecordingPath != null) {
      final p = _clipRecordingPath!;
      if (useCenter) {
        final cx = rect.left + rect.width * 0.5;
        final cy = rect.top + rect.height * 0.5;
        p.moveTo(cx, cy);
        p.arcTo(rect, startAngle, sweepAngle, false);
        p.close();
      } else {
        p.arcTo(rect, startAngle, sweepAngle, true);
      }
      return;
    }
    if (fill == null && stroke == null) return;
    if (_hasDash && stroke != null) {
      final outline = Path();
      if (useCenter) {
        final cx = rect.left + rect.width * 0.5;
        final cy = rect.top + rect.height * 0.5;
        outline.moveTo(cx, cy);
        outline.arcTo(rect, startAngle, sweepAngle, false);
        outline.close();
      } else {
        outline.arcTo(rect, startAngle, sweepAngle, true);
      }
      _emitDashed(outline, fill, stroke);
      return;
    }
    if (_drawnAlone(fill, stroke)) {
      final masked = _maskBlurredFill(fill, stroke);
      _addItem(
        ArcRenderItem(
          rect,
          startAngle,
          sweepAngle,
          useCenter,
          masked ?? fill,
          stroke,
          shadow: _activeShadow,
        ),
        blurred: masked != null,
      );
      return;
    }
    // The whole oval's box: an arc and its pie slice both stay inside it.
    final path = _beginShape(fill, stroke, rect, oriented: oriented);
    if (useCenter) {
      final cx = rect.left + rect.width * 0.5;
      final cy = rect.top + rect.height * 0.5;
      path.moveTo(cx, cy);
      path.arcTo(rect, startAngle, sweepAngle, false);
      path.close();
    } else {
      path.arcTo(rect, startAngle, sweepAngle, true);
    }
    _pendingShapeHasContent = true;
  }

  /// Append a pre-built [Path] as a new sub-path of the pending shape batch.
  ///
  /// Used by the vertex API to merge custom shapes with surrounding basic
  /// shapes when [paint] identity matches. Falls back to a per-shape
  /// [PathRenderItem] when the paint can't be safely merged.
  ///
  /// Pass [oriented] when every contour of [path] is known to wind clockwise
  /// on screen, the way rects and ovals are added. Without it a filled [path]
  /// only shares a batch with shapes it does not overlap, since opposite
  /// windings would cancel into a hole.
  ///
  /// [path] is copied when it merges and kept when it does not — see
  /// [mergesShapePath] before handing over one that will be reused.
  void appendShapePath(
    Path path,
    Paint? fill,
    Paint? stroke, {
    bool oriented = false,
  }) {
    _prepareGeometry(fill, stroke);
    if (_fold.hasLinear) {
      _appendTransformedPath(path, fill, stroke, oriented: oriented);
      return;
    }
    final off = _hasFoldOffset ? Offset(_foldDx, _foldDy) : Offset.zero;
    if (_clipRecordingPath != null) {
      _clipRecordingPath!.addPath(path, off);
      return;
    }
    if (fill == null && stroke == null) return;
    if (_hasDash && stroke != null) {
      _emitDashed(off == Offset.zero ? path : path.shift(off), fill, stroke);
      return;
    }
    if (_drawnAlone(fill, stroke)) {
      final masked = _maskBlurredFill(fill, stroke);
      _addItem(
        PathRenderItem(
          off == Offset.zero ? path : path.shift(off),
          masked ?? fill,
          stroke,
          shadow: _activeShadow,
        ),
        blurred: masked != null,
      );
      return;
    }
    final pending = _beginShape(
      fill,
      stroke,
      _wantsBox(fill, stroke, oriented) ? path.getBounds().shift(off) : null,
      oriented: oriented,
    );
    pending.addPath(path, off);
    _pendingShapeHasContent = true;
  }

  /// True when [appendShapePath] would copy a path painted with [fill] and
  /// [stroke] into a batch or clip mask rather than keep the [Path] object —
  /// i.e. when the caller may reuse one scratch path for every shape.
  bool mergesShapePath(Paint? fill, Paint? stroke) {
    if (_clipRecordingPath != null) return true;
    if (fill == null && stroke == null) return true;
    if (_hasDash && stroke != null) return false;
    return !_drawnAlone(fill, stroke);
  }

  /// Append a bitmap blit sampling [src] (image pixels) into [dst] (user
  /// coordinates).
  ///
  /// Compatible same-image runs use an atlas, baking folded translation,
  /// rotation and uniform scale into each sprite. Other operations preserve
  /// draw order by closing the run. Shadows and non-proportional sizes keep
  /// their individual canvas rendering.
  void appendImage(ui.Image image, Rect src, Rect dst, BlendMode blendMode) {
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): image() ignored inside clip callback — a bitmap has no '
        'outline to build a mask from. Use rect() to mask the region the '
        'image occupies.',
      );
      return;
    }
    if (!_canAtlas(src, dst)) {
      if (_fold.hasLinear) _materializeTransforms();
      final placed = _hasFoldOffset ? dst.shift(Offset(_foldDx, _foldDy)) : dst;
      _addItem(
        ImageRenderItem(
          image: image,
          src: src,
          dst: placed,
          blendMode: blendMode,
          shadow: _activeShadow,
        ),
      );
      return;
    }

    final placed = _fold.hasLinear
        ? _fold.bounds(dst)
        : (_hasFoldOffset ? dst.shift(Offset(_foldDx, _foldDy)) : dst);
    // Same protocol as appendPoint/appendLine: close our own run when it can
    // no longer accept this blit, then close the other batches so draw order
    // is preserved.
    if (_pendingAtlasImage != null &&
        (!identical(_pendingAtlasImage, image) ||
            _pendingAtlasBlend != blendMode)) {
      _flushImages();
    }
    _flushPoints();
    _flushLines();
    _flushShapes();

    _pendingAtlasImage = image;
    _pendingAtlasBlend = blendMode;
    _ensureAtlasCapacity(_atlasCount + 1);
    final i = _atlasCount * 4;
    // Compose the sprite's size/position with the folded similarity. Atlas
    // coordinates start at the source rect's top-left, not image (0, 0).
    final ratio = dst.width / src.width;
    _atlasTransforms[i] = _fold.a * ratio;
    _atlasTransforms[i + 1] = _fold.b * ratio;
    if (_fold.b != 0) _atlasHasRotation = true;
    _atlasTransforms[i + 2] = _fold.x(dst.left, dst.top);
    _atlasTransforms[i + 3] = _fold.y(dst.left, dst.top);
    _atlasRects[i] = src.left;
    _atlasRects[i + 1] = src.top;
    _atlasRects[i + 2] = src.right;
    _atlasRects[i + 3] = src.bottom;
    if (_atlasCount == 0) {
      _atlasFirstSrc = src;
      _atlasFirstDst = _fold.hasLinear ? dst : placed;
      _atlasFirstFold = _fold.hasLinear ? _fold : null;
      _atlasBounds = placed;
    } else {
      _atlasBounds = _atlasBounds!.expandToInclude(placed);
    }
    _atlasCount++;
  }

  /// Whether a blit of [src] into [dst] can join an atlas run — the two
  /// conditions an `RSTransform` can represent.
  ///
  /// A shadow disqualifies the blit outright (the silhouette needs its own
  /// pass), as does a blur (each blit blurs alone), and the scale must be
  /// uniform: `RSTransform` holds one scale factor, so a stretch that scales
  /// x and y differently has no representation. Degenerate rects fall out
  /// rather than dividing by zero.
  bool _canAtlas(Rect src, Rect dst) {
    if (_activeShadow != null || _blurLayer != null) return false;
    if (src.width <= 0 || src.height <= 0) return false;
    if (!dst.width.isFinite || !dst.height.isFinite) return false;
    final scaleX = dst.width / src.width;
    final scaleY = dst.height / src.height;
    final larger = scaleX.abs() > scaleY.abs() ? scaleX.abs() : scaleY.abs();
    return (scaleX - scaleY).abs() <= _atlasScaleTolerance * larger;
  }

  /// Materializes the open atlas run, if any.
  ///
  /// A run of one keeps drawImageRect and its original double coordinates.
  /// Its folded transform, if any, is captured in an owned wrapper.
  void _flushImages() {
    if (_atlasCount == 0) return;
    final image = _pendingAtlasImage!;
    if (_atlasCount == 1) {
      final item = ImageRenderItem(
        image: image,
        src: _atlasFirstSrc!,
        dst: _atlasFirstDst!,
        blendMode: _pendingAtlasBlend,
      );
      final fold = _atlasFirstFold;
      _items.add(fold == null ? item : _TransformedImageRenderItem(item, fold));
    } else {
      // sublist copies — decouples the item from the reusable buffers so the
      // next run can overwrite them in place (same as the point/line flushes).
      _items.add(
        ImageAtlasRenderItem(
          image: image,
          transforms: _atlasTransforms.sublist(0, _atlasCount * 4),
          preserveRotatedEdges: _atlasHasRotation,
          rects: _atlasRects.sublist(0, _atlasCount * 4),
          blendMode: _pendingAtlasBlend,
          bounds: _atlasBounds!,
        ),
      );
    }
    _atlasCount = 0;
    _atlasHasRotation = false;
    _pendingAtlasImage = null;
    _atlasBounds = null;
    _atlasFirstSrc = null;
    _atlasFirstDst = null;
    _atlasFirstFold = null;
  }

  /// Bulk-append a packed `(x, y)` coordinate list to the auto-batch point
  /// buffer. Consecutive calls with the same [paint] reference coalesce into
  /// a single [MultiPointRenderItem]. Z-order is preserved: any pending line
  /// or shape batch flushes first.
  ///
  /// An active drop shadow rides along on the batch (drawn once beneath the
  /// whole run) instead of forcing a standalone item.
  void appendPoints(Float32List coords, Paint paint) {
    if (coords.isEmpty) return;
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): point() ignored inside clip callback — points have no area '
        'and cannot bound a mask region. Use circle() for dot-shaped masks.',
      );
      return;
    }
    _prepareGeometry(null, paint, points: true);
    paint = _foldStroke(paint)!;
    if (_pendingPointPaint != null && !identical(_pendingPointPaint, paint)) {
      _flushPoints();
    }
    _flushLines();
    _flushShapes();
    _flushImages();
    _pendingPointPaint = paint;
    _pendingPointShadow = _activeShadow;
    _ensurePointCapacity(_pointCount + coords.length);
    if (!_fold.isIdentity) {
      for (int i = 0; i + 1 < coords.length; i += 2) {
        _pointBuffer[_pointCount++] = _fold.x(coords[i], coords[i + 1]);
        _pointBuffer[_pointCount++] = _fold.y(coords[i], coords[i + 1]);
      }
    } else {
      _pointBuffer.setRange(_pointCount, _pointCount + coords.length, coords);
      _pointCount += coords.length;
    }
    // One call is one draw: under blur its points share a layer, alone.
    if (_blurLayer != null) _addItem(_takePoints());
  }

  /// Append a closed polygon (triangle, quad, etc.) defined by a sequence of
  /// (x, y) pairs as a new sub-path of the pending shape path.
  ///
  /// The first coordinate becomes a `moveTo`, the rest become `lineTo`, and
  /// the sub-path is closed.
  void appendPolyPath(
    List<double> xs,
    List<double> ys,
    Paint? fill,
    Paint? stroke,
  ) {
    assert(xs.length == ys.length && xs.length >= 2);
    final n = xs.length;
    _ensurePolyCapacity(n);
    for (int i = 0; i < n; i++) {
      _polyXs[i] = xs[i];
      _polyYs[i] = ys[i];
    }
    _appendPoly(n, fill, stroke);
  }

  /// Append a triangle without allocating coordinate lists — the hot-path
  /// variant of [appendPolyPath] used by `triangle()`.
  void appendTriangle(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    Paint? fill,
    Paint? stroke,
  ) {
    _polyXs[0] = x1;
    _polyXs[1] = x2;
    _polyXs[2] = x3;
    _polyYs[0] = y1;
    _polyYs[1] = y2;
    _polyYs[2] = y3;
    _appendPoly(3, fill, stroke);
  }

  /// Append a quadrilateral without allocating coordinate lists — the
  /// hot-path variant of [appendPolyPath] used by `quad()`.
  void appendQuad(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    double x4,
    double y4,
    Paint? fill,
    Paint? stroke,
  ) {
    _polyXs[0] = x1;
    _polyXs[1] = x2;
    _polyXs[2] = x3;
    _polyXs[3] = x4;
    _polyYs[0] = y1;
    _polyYs[1] = y2;
    _polyYs[2] = y3;
    _polyYs[3] = y4;
    _appendPoly(4, fill, stroke);
  }

  /// Append a regular polygon with [sides] vertices on the circle of
  /// [radius] around ([cx], [cy]), first vertex pointing up — the hot-path
  /// variant of [appendPolyPath] used by `polygon()`.
  void appendRegularPolygon(
    double cx,
    double cy,
    double radius,
    int sides,
    Paint? fill,
    Paint? stroke,
  ) {
    assert(sides >= 3);
    _ensurePolyCapacity(sides);
    const start = -math.pi / 2;
    final step = 2 * math.pi / sides;
    _polyXs[0] = cx;
    _polyYs[0] = cy - radius;
    for (int i = 1; i < sides; i++) {
      final a = start + i * step;
      _polyXs[i] = cx + radius * math.cos(a);
      _polyYs[i] = cy + radius * math.sin(a);
    }
    // Generated clockwise — no need to measure it.
    _appendPoly(sides, fill, stroke, turn: 1);
  }

  /// Append a [points]-pointed star centered at ([cx], [cy]), outer vertices
  /// on the circle of [outerRadius] and inner vertices on [innerRadius],
  /// first point up — the hot-path variant of [appendPolyPath] used by
  /// `star()`.
  void appendStar(
    double cx,
    double cy,
    double innerRadius,
    double outerRadius,
    int points,
    Paint? fill,
    Paint? stroke,
  ) {
    assert(points >= 3);
    final n = points * 2;
    _ensurePolyCapacity(n);
    const start = -math.pi / 2;
    final step = math.pi / points;
    _polyXs[0] = cx;
    _polyYs[0] = cy - outerRadius;
    for (int i = 1; i < n; i++) {
      final r = i.isEven ? outerRadius : innerRadius;
      final a = start + i * step;
      _polyXs[i] = cx + r * math.cos(a);
      _polyYs[i] = cy + r * math.sin(a);
    }
    // Clockwise as generated unless a negative radius folds it over itself.
    _appendPoly(
      n,
      fill,
      stroke,
      turn: innerRadius > 0 && outerRadius > 0 ? 1 : null,
    );
  }

  /// Shared polygon implementation reading the first [n] points from the
  /// poly scratch buffers. Applies the fold offset while building the path.
  ///
  /// [turn] is the polygon's winding as [_polyTurn] reports it, for callers
  /// that already know; left out, it is measured when a fill needs it.
  void _appendPoly(int n, Paint? fill, Paint? stroke, {int? turn}) {
    _prepareGeometry(fill, stroke);
    stroke = _foldStroke(stroke);
    if (_clipRecordingPath != null) {
      _addPolyTo(_clipRecordingPath!, n, reversed: (turn ?? _polyTurn(n)) < 0);
      return;
    }
    if (fill == null && stroke == null) return;
    if (_hasDash && stroke != null) {
      final p = Path();
      _addPolyTo(p, n);
      _emitDashed(p, fill, stroke);
      return;
    }
    if (_drawnAlone(fill, stroke)) {
      final p = Path();
      _addPolyTo(p, n);
      final masked = _maskBlurredFill(fill, stroke);
      _addItem(
        PathRenderItem(p, masked ?? fill, stroke, shadow: _activeShadow),
        blurred: masked != null,
      );
      return;
    }
    // Winding only matters to a fill, and not at all to a stacking batch,
    // which keeps every shape off every other anyway.
    if (fill != null && !_stacks(fill, stroke)) turn ??= _polyTurn(n);
    // A counter-clockwise polygon goes in backwards — the same fill, pixel
    // for pixel, and it now adds to the shapes it overlaps instead of
    // cancelling them. A stroke's anti-aliasing does depend on direction, so
    // a stroked one is left as given and kept off whatever it overlaps.
    final reversed = turn == -1 && stroke == null;
    final oriented = turn == null || turn == 1 || reversed;
    _addPolyTo(
      _beginShape(
        fill,
        stroke,
        _wantsBox(fill, stroke, oriented) ? _polyBounds(n) : null,
        oriented: oriented,
      ),
      n,
      reversed: reversed,
    );
    _pendingShapeHasContent = true;
  }

  /// Which way the first [n] scratch points wind: `1` clockwise on screen
  /// (the direction rects and ovals are added in), `-1` counter-clockwise,
  /// `0` when the polygon does not keep turning one way around the average
  /// of its points — it may cross itself, so no single direction describes it.
  ///
  /// Sweeping one way around a point is what makes every region the polygon
  /// encloses wind with the same sign, which is all a batch needs. It holds
  /// for every triangle and convex polygon, and for stars and blobs.
  int _polyTurn(int n) {
    double cx = 0, cy = 0;
    for (int i = 0; i < n; i++) {
      cx += _polyXs[i];
      cy += _polyYs[i];
    }
    cx /= n;
    cy /= n;
    bool cw = false, ccw = false;
    double px = _polyXs[n - 1] - cx, py = _polyYs[n - 1] - cy;
    for (int i = 0; i < n; i++) {
      final qx = _polyXs[i] - cx, qy = _polyYs[i] - cy;
      final cross = px * qy - py * qx;
      if (cross > 0) {
        cw = true;
      } else if (cross < 0) {
        ccw = true;
      }
      px = qx;
      py = qy;
    }
    if (cw && ccw) return 0;
    return ccw ? -1 : 1;
  }

  /// Folded box of the first [n] points in the poly scratch buffers.
  Rect _polyBounds(int n) {
    double l = double.infinity, t = double.infinity;
    double r = double.negativeInfinity, b = double.negativeInfinity;
    for (int i = 0; i < n; i++) {
      final x = _fold.x(_polyXs[i], _polyYs[i]);
      final y = _fold.y(_polyXs[i], _polyYs[i]);
      if (x < l) l = x;
      if (x > r) r = x;
      if (y < t) t = y;
      if (y > b) b = y;
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  void _addPolyTo(Path p, int n, {bool reversed = false}) {
    if (reversed) {
      final last = n - 1;
      p.moveTo(
        _fold.x(_polyXs[last], _polyYs[last]),
        _fold.y(_polyXs[last], _polyYs[last]),
      );
      for (int i = last - 1; i >= 0; i--) {
        p.lineTo(
          _fold.x(_polyXs[i], _polyYs[i]),
          _fold.y(_polyXs[i], _polyYs[i]),
        );
      }
      p.close();
      return;
    }
    p.moveTo(_fold.x(_polyXs[0], _polyYs[0]), _fold.y(_polyXs[0], _polyYs[0]));
    for (int i = 1; i < n; i++) {
      p.lineTo(
        _fold.x(_polyXs[i], _polyYs[i]),
        _fold.y(_polyXs[i], _polyYs[i]),
      );
    }
    p.close();
  }

  /// Current count of finalized items in the queue. Excludes pending
  /// shape/point/line batches — call [flushPending] first if those need
  /// to be counted.
  int get itemCount => _items.length;

  /// Read-only view over finalized items. Used by `endContainer()` to walk
  /// the queue and compute bounding boxes from already-queued geometry.
  /// Excludes pending batches — call [flushPending] first if needed.
  List<Flut5RenderItem> get items => List.unmodifiable(_items);

  /// Inserts [item] at [index] in the finalized items list. Used by
  /// `endContainer()` to back-fill the scroll translate at the slot
  /// `beginContainer()` remembered, once the content's bounds are known.
  /// Does NOT flush pending batches.
  void insertAt(int index, Flut5RenderItem item) {
    _items.insert(index, item);
    if (item is BackgroundRenderItem) _recomputeBackgroundFlags();
  }

  /// Replaces the item at [index] in place — O(1), unlike [insertAt], and
  /// shifts no indices. Used by the layout's align/justify pass to patch the
  /// placeholder translate it reserved at container open once the line's
  /// metrics are known. Intended for transform-for-transform swaps; it does
  /// not recompute background flags.
  void replaceAt(int index, Flut5RenderItem item) {
    _items[index] = item;
  }

  /// Forces pending batches (shapes/points/lines) to materialize as
  /// `Flut5RenderItem`s appended to the queue. Call before reading
  /// [items]/[itemCount] when you need an accurate snapshot.
  void flushPending() {
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
  }

  /// Axis-aligned bounding box of every item drawn at [startIndex] and beyond,
  /// expressed in the coordinate space active *at* [startIndex] — i.e. before
  /// any transform queued from that point onward is applied.
  ///
  /// Walks the queue maintaining a [Matrix4] stack that mirrors the canvas save
  /// stack, so content moved by nested `push`/`translate`/`scale`/`matrix` is
  /// measured in the right place. Each item's local [Flut5RenderItem.bounds] is
  /// transformed by the accumulated matrix and unioned. Items with `null`
  /// bounds (transforms, clips, backgrounds) contribute nothing. Clips no
  /// longer `save()` on their own — the enclosing `push`/`pop` drives the
  /// stack — and are not intersected into the result, so the scrollable area
  /// is a slight over-estimate, which is fine for sizing a scroll-mode
  /// container scope.
  ///
  /// Returns `null` when nothing measurable was drawn. Call [flushPending]
  /// first so batched shapes are materialized as items.
  Rect? contentBoundsFrom(int startIndex) {
    Rect? result;
    // Fast path: pure translations are folded into geometry at append time,
    // so most measured ranges contain no [TransformRenderItem] at all. Union
    // local bounds directly — no Matrix4 stack, no per-item transformRect —
    // until the first transform item requires the matrix walk. The matrix is
    // identity up to that point, so the accumulated union carries over.
    int i = startIndex;
    for (; i < _items.length; i++) {
      final item = _items[i];
      if (item is TransformRenderItem) break;
      if (item is ClipRenderItem) continue;
      final b = item.bounds;
      if (b == null) continue;
      result = result == null ? b : result.expandToInclude(b);
    }
    if (i >= _items.length) return result;
    final stack = <Matrix4>[];
    var current = Matrix4.identity();
    for (; i < _items.length; i++) {
      final item = _items[i];
      if (item is TransformRenderItem) {
        switch (item.type) {
          case TransformType.push:
            stack.add(current.clone());
          case TransformType.pop:
            if (stack.isNotEmpty) current = stack.removeLast();
          case TransformType.translate:
            current.translateByDouble(item.dx!, item.dy!, 0, 1);
          case TransformType.scale:
            current.scaleByDouble(item.scaleX!, item.scaleY!, 1, 1);
          case TransformType.rotate:
            current.rotateZ(item.rotation!);
          case TransformType.matrix:
            current.multiply(Matrix4.fromFloat64List(item.matrix!));
        }
        continue;
      }
      // A clip() narrows the current layer without its own save() — the
      // enclosing push()/pop() (handled above) drives the matrix stack, so
      // the clip item itself is skipped here. It doesn't move the origin and
      // contributes no bounds.
      if (item is ClipRenderItem) continue;
      final b = item.bounds;
      if (b == null) continue;
      final transformed = MatrixUtils.transformRect(current, b);
      result = result == null
          ? transformed
          : result.expandToInclude(transformed);
    }
    return result;
  }

  /// Add a new rendering operation to the queue. The folded transform state
  /// is materialized first (the item's coordinates are canvas-space, not
  /// baked by this queue), then pending batches flush to preserve draw order.
  void enqueue(Flut5RenderItem item) {
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): unsupported operation inside clip callback ignored '
        '(only filled shapes and text contribute to a mask).',
      );
      return;
    }
    _materializeTransforms();
    _addItem(item);
  }

  /// [enqueue] for one draw the caller had to split into several [items] —
  /// a dashed shape's solid fill and dashed stroke. Under blur they share a
  /// single layer, so they still blur as one shape.
  void enqueueAll(List<Flut5RenderItem> items) {
    if (_clipRecordingPath != null) {
      enqueue(items.first);
      return;
    }
    _materializeTransforms();
    _addItems(items);
  }

  /// Internal add: flushes pending batches and appends [item]. Used by the
  /// append* fallback branches, whose item coordinates already carry the
  /// fold offset — materializing here would apply the translation twice.
  ///
  /// Under blur a draw is wrapped in its own [BlurRenderItem], unless it is
  /// [blurred] already (see [_maskBlurredFill]). Backgrounds, clips and
  /// transforms are not draws: they stay bare, where the trail bookkeeping,
  /// the container's placeholder patching and the canvas save stack expect
  /// them.
  void _addItem(Flut5RenderItem item, {bool blurred = false}) {
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    if (item is BackgroundRenderItem) {
      _lastBackground = item;
      if (item.isOpaqueFullCanvas) _hasOpaqueFullCanvasBg = true;
    }
    final layer = _blurLayer;
    if (layer != null &&
        !blurred &&
        item is! BackgroundRenderItem &&
        item is! TransformRenderItem &&
        item is! ClipRenderItem) {
      _items.add(BlurRenderItem([item], layer));
    } else {
      _items.add(item);
    }
  }

  /// [_addItem] for the parts of one draw, which share a blur layer.
  void _addItems(List<Flut5RenderItem> items) {
    final layer = _blurLayer;
    if (layer == null || items.length == 1) {
      items.forEach(_addItem);
      return;
    }
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    _items.add(BlurRenderItem(items, layer));
  }

  /// Returns `true` when the last [BackgroundRenderItem] enqueued in this
  /// frame fully clears the canvas with an opaque fill — i.e. a solid color
  /// with alpha 1.0, or a full-canvas paint/shader (no `rect` restriction).
  /// Used by the painter to decide whether to keep a frame snapshot for
  /// trail accumulation: an opaque clear means previous-frame content is
  /// invisible anyway, so the snapshot can be dropped (or skipped).
  ///
  /// A shader background restricted to a sub-`rect` is **not** treated as a
  /// clear — it doesn't cover the whole canvas. Shader/gradient backgrounds
  /// that cover the full canvas only count when their colors are known opaque.
  ///
  /// O(1): tracked incrementally as backgrounds are enqueued.
  bool get lastBackgroundIsOpaqueFullCanvas =>
      _lastBackground?.isOpaqueFullCanvas ?? false;

  /// True when this frame contains any opaque full-canvas background.
  ///
  /// Once such a background executes, older trail content underneath it can no
  /// longer contribute to the final frame, even if later drawing keeps trails
  /// active for subsequent frames.
  ///
  /// O(1): tracked incrementally as backgrounds are enqueued.
  bool get hasOpaqueFullCanvasBackground => _hasOpaqueFullCanvasBg;

  /// True when every [BackgroundRenderItem] in this frame appears before any
  /// non-background item — the p5-shaped `background()`-at-the-top-of-`draw()`
  /// case.
  ///
  /// Only under this ordering are [executeBackground] followed by
  /// [executeForeground] together equivalent to a single in-order [execute],
  /// so the split-replay capture path in the painter checks this before
  /// taking its fast route and falls back to two full replays otherwise.
  ///
  /// Pending point/line/shape batches are deliberately not flushed here: they
  /// always append at the tail, which can only add content *after* every
  /// existing background and so can never invalidate a `true` result.
  ///
  /// O(n) in queued items, but only pointer reads and type checks — a small
  /// fraction of one replay, and consulted at most once per capture frame.
  bool get backgroundsPrecedeContent {
    var seenContent = false;
    for (final item in _items) {
      if (item is BackgroundRenderItem) {
        if (seenContent) return false;
      } else {
        seenContent = true;
      }
    }
    return true;
  }

  /// The translucent full-canvas fill this frame uses as its trail fade, or
  /// `null` when the frame has no such background.
  ///
  /// Returns a color only for the plain-color `drawColor` background form
  /// with alpha below 1 and no `rect` restriction — the case whose repeated
  /// application compounds predictably as `1 - (1 - a)^k`, which is what
  /// [Flut5Engine.smoothTrailFade] relies on to synthesize the fade for
  /// frames between snapshot captures. Shader and sub-rect backgrounds have
  /// no such closed form and return `null`.
  Color? get trailFadeColor {
    final bg = _lastBackground;
    if (bg == null) return null;
    if (bg.isOpaqueFullCanvas) return null;
    final color = bg.color;
    if (color == null || bg.rect != null) return null;
    return color.a < 1.0 ? color : null;
  }

  /// Rebuilds the incremental background flags after an out-of-order insert.
  void _recomputeBackgroundFlags() {
    _lastBackground = null;
    _hasOpaqueFullCanvasBg = false;
    for (final item in _items) {
      if (item is! BackgroundRenderItem) continue;
      _lastBackground = item;
      if (item.isOpaqueFullCanvas) _hasOpaqueFullCanvasBg = true;
    }
  }

  /// Iterates through and draws all queued operations to the Canvas.
  ///
  /// The canvas save stack is rebalanced afterwards via [_balanceSaveStack]:
  /// if the frame's items left more `save()` open than they `restore()`d —
  /// typically a sketch calling `push()` (often the `push()` that scopes a
  /// `clip*()`) without a matching `pop()` — the surplus is popped back to the
  /// entry depth so the host `CustomPainter` (or `PictureRecorder`) doesn't
  /// throw.
  void execute(Canvas canvas) {
    _closeOpenScopes();
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    final baseline = canvas.getSaveCount();
    if (_hasPixelate) {
      _replayPixelated(canvas, skipBackgrounds: false);
    } else {
      for (final item in _items) {
        item.execute(canvas);
      }
    }
    _balanceSaveStack(canvas, baseline);
  }

  /// Draws *only* the [BackgroundRenderItem]s in the queue, skipping all
  /// content. The complement of [executeForeground].
  ///
  /// Used by the painter's split-replay capture path: the snapshot recording
  /// needs the background fade, while the foreground picture — replayed into
  /// both the recording and the screen — must not carry it. Together the two
  /// halves reproduce [execute] exactly, but only when
  /// [backgroundsPrecedeContent] holds; the painter checks that first.
  ///
  /// No save-stack rebalancing: backgrounds neither `save()` nor `restore()`,
  /// so the surrounding [executeForeground] owns the baseline.
  void executeBackground(Canvas canvas) {
    for (final item in _items) {
      if (item is BackgroundRenderItem) item.execute(canvas);
    }
  }

  /// Like [execute] but skips every [BackgroundRenderItem] in the queue. Used
  /// by the split-layer foreground painter so the live display doesn't double-
  /// apply the translucent background fade (the snapshot rebuild already
  /// incorporates it).
  void executeForeground(Canvas canvas) {
    _closeOpenScopes();
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    final baseline = canvas.getSaveCount();
    if (_hasPixelate) {
      _replayPixelated(canvas, skipBackgrounds: true);
    } else {
      for (final item in _items) {
        if (item is BackgroundRenderItem) continue;
        item.execute(canvas);
      }
    }
    _balanceSaveStack(canvas, baseline);
  }

  /// The replay for a frame holding pixelate scopes: items between a pair of
  /// markers draw onto that scope's low-resolution canvas, which is drawn
  /// back onto its parent when the scope closes.
  ///
  /// A background inside a scope is pixelated like any other draw here. The
  /// split replay never sees that case: the opening marker counts as content
  /// for [backgroundsPrecedeContent], so the painter falls back to [execute].
  void _replayPixelated(Canvas canvas, {required bool skipBackgrounds}) {
    final base = Matrix4.fromFloat64List(canvas.getTransform());
    final passes = <_PixelatePass>[];
    var target = canvas;
    for (final item in _items) {
      if (item is PixelateBeginRenderItem) {
        final pass = _PixelatePass(
          item,
          target,
          passes.isEmpty ? base : passes.last.logical,
        );
        passes.add(pass);
        target = pass.canvas;
      } else if (item is PixelateEndRenderItem) {
        if (passes.isNotEmpty) target = passes.removeLast().end();
      } else if (!skipBackgrounds || item is! BackgroundRenderItem) {
        item.execute(target);
      }
    }
  }

  /// Pops the canvas save stack back down to [baseline] when the frame's
  /// render items left it unbalanced — i.e. more `save()` (`push()`) than
  /// `restore()` (`pop()`). Clips no longer `save()` on their own, so a leak
  /// always traces back to an unmatched `push()` — most often the `push()`
  /// meant to scope a `clip*()` whose closing `pop()` was forgotten. Without
  /// this the host [Canvas] (a `CustomPainter`'s, or a `PictureRecorder`'s
  /// during snapshot capture) throws on completion: "called
  /// canvas.save()/saveLayer() … more time than … restore()".
  ///
  /// Mirrors p5.js, which auto-resets an unbalanced `push()` at the end of
  /// `draw()`. A one-shot warning ([_warnedSaveImbalance]) reports the leak
  /// once instead of every frame; it re-arms after a balanced frame.
  ///
  /// [Canvas.getSaveCount] starts at 1 (the implicit base state) and the loop
  /// never restores past [baseline] ≥ 1, so the base state is never popped.
  void _balanceSaveStack(Canvas canvas, int baseline) {
    final leaked = canvas.getSaveCount() - baseline;
    if (leaked <= 0) {
      _warnedSaveImbalance = false;
      return;
    }
    while (canvas.getSaveCount() > baseline) {
      canvas.restore();
    }
    if (!_warnedSaveImbalance) {
      _warnedSaveImbalance = true;
      Flut5Console.printLater(
        'Flut5: the canvas save stack was left unbalanced this frame — '
        '$leaked more push() than pop(). It has been auto-restored, but add '
        'the missing pop() to fix it. Note: a clip*() needs an enclosing '
        'push() / pop() — the pop() is what lifts the clip.',
      );
    }
  }

  /// Restores the queue to an empty state for the next frame.
  /// Uses [List.clear] which resets the length to zero while keeping
  /// the backing store allocated, avoiding re-growth on subsequent frames.
  /// The point, line and image-atlas [Float32List] backing buffers are also
  /// kept alive.
  void clear() {
    _items.clear();
    _pointCount = 0;
    _pendingPointPaint = null;
    _pendingPointShadow = null;
    _lineCount = 0;
    _pendingLinePaint = null;
    _pendingLineShadow = null;
    _pendingShapePath = null;
    _pendingShapeFill = null;
    _pendingShapeStroke = null;
    _pendingShapeHasContent = false;
    _pendingShapeShadow = null;
    _pendingShapeBoxes.clear();
    _pendingShapeTracked = false;
    // Atlas run: drop the sprites but keep the Float32List backing buffers,
    // same bargain as the point/line buffers above.
    _atlasCount = 0;
    _atlasHasRotation = false;
    _pendingAtlasImage = null;
    _atlasBounds = null;
    _atlasFirstSrc = null;
    _atlasFirstDst = null;
    _atlasFirstFold = null;
    _clipRecordingPath = null;
    // Fold state is per-frame — the canvas transform resets with the frame.
    _fold = const _FoldTransform();
    _foldStack.clear();
    _scaledStrokes.clear();
    _lastBackground = null;
    _hasOpaqueFullCanvasBg = false;
    _scopes.clear();
    _hasPixelate = false;
  }

  // ── Internals ─────────────────────────────────────────────────────────

  /// Emits a dashed shape: the fill (if any) is drawn solid on [outline], and
  /// the stroke is drawn on a dashed copy of [outline]. Render items stay dumb
  /// (plain [PathRenderItem]s) — the dashing happens here, at enqueue time.
  /// Dashed shapes don't merge into the shape batch; each emits on its own,
  /// which is fine since dashing is never a hot path.
  void _emitDashed(Path outline, Paint? fill, Paint stroke) {
    final shadow = _activeShadow;
    final dashed = dashPath(outline, _dashPattern!, _dashOffset);
    // Attach the shadow to the solid silhouette (the fill outline) when present,
    // otherwise to the dashed stroke — so a dashed shape casts a single coherent
    // shadow instead of one per pass. Callers pass fold-baked outlines, so no
    // transform materialization here (_addItem, not enqueue).
    if (fill != null) {
      _addItems([
        PathRenderItem(outline, fill, null, shadow: shadow),
        PathRenderItem(dashed, null, stroke),
      ]);
    } else {
      _addItem(PathRenderItem(dashed, null, stroke, shadow: shadow));
    }
  }

  /// True when a batch painted with [fill] and [stroke] can show its
  /// all-fills-then-all-strokes order: both are drawn and they differ in
  /// colour. Fill-only, stroke-only and single-colour batches look the same
  /// in either order, so they never need to split on overlap.
  ///
  /// Memoized on paint identity — queued paints are immutable snapshots.
  bool _stacks(Paint? fill, Paint? stroke) {
    if (fill == null || stroke == null) return false;
    if (!identical(fill, _stacksFill) || !identical(stroke, _stacksStroke)) {
      _stacksFill = fill;
      _stacksStroke = stroke;
      _stacksResult = fill.color != stroke.color;
    }
    return _stacksResult;
  }

  /// True when [_beginShape] will read the box of a shape painted with
  /// [fill]/[stroke], so callers for whom the box is not free can skip it.
  bool _wantsBox(Paint? fill, Paint? stroke, bool oriented) =>
      _pendingShapeTracked ||
      (fill != null && !oriented) ||
      _stacks(fill, stroke);

  /// Opens (or continues) the shape batch for [fill]/[stroke] and returns its
  /// path. Besides a change of paint, two things close the open batch, both
  /// because one path is not its shapes drawn one by one:
  ///
  /// * [_stacks] holds and the new shape lands on any shape in the batch —
  ///   its fill has to cover their outlines.
  /// * the new shape, or one it lands on, is filled and not [oriented] — its
  ///   contours may wind counter-clockwise, and opposite windings cancel into
  ///   a hole where they overlap. Shapes that all wind clockwise only add up.
  ///
  /// [bounds] is the box of the geometry about to be added, in queue space
  /// and without stroke width; it is only read when [_wantsBox] holds, so
  /// callers that would have to compute it may pass `null` otherwise.
  ///
  /// The unstroked box is enough: the part of an earlier outline that reaches
  /// into a shape it merely touches lies under that shape's own outline.
  Path _beginShape(
    Paint? fill,
    Paint? stroke,
    Rect? bounds, {
    bool oriented = true,
  }) {
    final stacks = _stacks(fill, stroke);
    final unwound = fill != null && !oriented;
    if (_pendingShapePath != null) {
      final bool split;
      if (!identical(_pendingShapeFill, fill) ||
          !identical(_pendingShapeStroke, stroke)) {
        split = true;
      } else if (_pendingShapeTracked) {
        // A clockwise shape in a non-stacking batch only has the unwound
        // shapes to avoid; everything else has every shape to avoid.
        split = _pendingShapeBoxes.overlaps(
          bounds!.left,
          bounds.top,
          bounds.right,
          bounds.bottom,
          markedOnly: !stacks && !unwound,
        );
      } else {
        // The batch kept no boxes, so a shape that must be tested can't
        // join it.
        split = unwound;
      }
      if (split) _flushShapes();
    }
    if (_pendingShapePath == null) _pendingShapeTracked = stacks || unwound;
    if (_pendingShapeTracked) {
      _pendingShapeBoxes.add(
        bounds!.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
        marked: unwound,
      );
    }
    _flushPoints();
    _flushLines();
    _flushImages();
    final path = _pendingShapePath ??= Path();
    _pendingShapeFill = fill;
    _pendingShapeStroke = stroke;
    // Rides along on the batch — setShadowState flushes on change, so an open
    // batch always matches the current shadow.
    _pendingShapeShadow = _activeShadow;
    return path;
  }

  void _flushPoints() {
    if (_pointCount == 0) return;
    _items.add(_takePoints());
  }

  /// Closes the open point run and returns it as an item. The run must hold
  /// at least one point.
  MultiPointRenderItem _takePoints() {
    // sublist copies — decouples the item from the reusable buffer so later
    // frames can overwrite _pointBuffer in place.
    final item = MultiPointRenderItem(
      _pointBuffer.sublist(0, _pointCount),
      _pendingPointPaint!,
      shadow: _pendingPointShadow,
    );
    _pointCount = 0;
    _pendingPointPaint = null;
    _pendingPointShadow = null;
    return item;
  }

  void _flushLines() {
    if (_lineCount == 0) return;
    final snapshot = _lineBuffer.sublist(0, _lineCount);
    _items.add(
      MultiLineRenderItem(
        snapshot,
        _pendingLinePaint!,
        shadow: _pendingLineShadow,
      ),
    );
    _lineCount = 0;
    _pendingLinePaint = null;
    _pendingLineShadow = null;
  }

  void _flushShapes() {
    _pendingShapeBoxes.clear();
    _pendingShapeTracked = false;
    if (!_pendingShapeHasContent) {
      _pendingShapePath = null;
      _pendingShapeFill = null;
      _pendingShapeStroke = null;
      _pendingShapeShadow = null;
      return;
    }
    _items.add(
      PathRenderItem(
        _pendingShapePath!,
        _pendingShapeFill,
        _pendingShapeStroke,
        shadow: _pendingShapeShadow,
      ),
    );
    _pendingShapePath = null;
    _pendingShapeFill = null;
    _pendingShapeStroke = null;
    _pendingShapeHasContent = false;
    _pendingShapeShadow = null;
  }

  void _ensurePointCapacity(int needed) {
    if (_pointBuffer.length >= needed) return;
    int newLen = _pointBuffer.isEmpty ? 64 : _pointBuffer.length * 2;
    while (newLen < needed) {
      newLen *= 2;
    }
    final grown = Float32List(newLen);
    grown.setRange(0, _pointCount, _pointBuffer);
    _pointBuffer = grown;
  }

  void _ensureLineCapacity(int needed) {
    if (_lineBuffer.length >= needed) return;
    int newLen = _lineBuffer.isEmpty ? 128 : _lineBuffer.length * 2;
    while (newLen < needed) {
      newLen *= 2;
    }
    final grown = Float32List(newLen);
    grown.setRange(0, _lineCount, _lineBuffer);
    _lineBuffer = grown;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

extension Flut5PaintCloner on Paint {
  /// Deep-copies the Paint object to safely queue State snapshots
  /// without being mutated by subsequent draw calls in the frame loop.
  Paint clone() {
    return Paint()
      ..color = color
      ..style = style
      ..strokeWidth = strokeWidth
      ..strokeCap = strokeCap
      ..strokeJoin = strokeJoin
      ..blendMode = blendMode
      ..shader = shader
      ..maskFilter = maskFilter
      ..colorFilter = colorFilter
      ..imageFilter = imageFilter
      ..isAntiAlias = isAntiAlias
      ..filterQuality = filterQuality;
  }
}

/// Boxes of the shapes in the open shape batch, for asking whether a new
/// shape lands on one already in it. Boxes that only touch do not overlap.
///
/// A handful of boxes are scanned directly. Past [_scanLimit] they are filed
/// on a uniform grid by the cell their centre falls in, and a query walks the
/// cells its box can reach once widened by the largest half-extent on file.
/// Cells hash into a flat table, so two cells may share a chain — every
/// candidate still gets the exact box test, so a collision costs a
/// comparison, never a wrong answer.
///
/// [overlaps] may answer `true` when deciding would be expensive: a box far
/// larger than the grid was sized for, a crowded cell, or coordinates that
/// cannot be hashed. The queue then closes the batch — one extra draw call —
/// and the next batch sizes a fresh grid from the shapes that follow, so the
/// per-shape cost stays bounded whatever the sketch draws.
class _ShapeOverlapIndex {
  static const int _scanLimit = 16;
  static const int _firstSlots = 64;
  static const int _maxCells = 16;
  static const int _maxTests = 96;
  static const double _coordLimit = 1e9;

  // Doubles, not float32: touching shapes must compare exactly as drawn.
  Float64List _boxes = Float64List(_scanLimit * 4);
  Int32List _next = Int32List(_scanLimit);
  // Per box: 1 when added as `marked`, for queries that only avoid those.
  Uint8List _marks = Uint8List(_scanLimit);
  // Slot → newest box filed there, -1 when empty. Only the first `_mask + 1`
  // slots are live; the list keeps its largest size across batches so a
  // small batch never pays to reset a big batch's table.
  Int32List _heads = Int32List(_firstSlots);
  int _mask = 0;
  int _count = 0;
  // Zero until the grid is built.
  double _cellW = 0;
  double _cellH = 0;
  double _maxHalfW = 0;
  double _maxHalfH = 0;
  bool _undecidable = false;

  void clear() {
    _count = 0;
    _cellW = 0;
    _cellH = 0;
    _maxHalfW = 0;
    _maxHalfH = 0;
    _undecidable = false;
  }

  // Also false for NaN.
  static bool _hashable(double l, double t, double r, double b) =>
      l > -_coordLimit &&
      t > -_coordLimit &&
      r < _coordLimit &&
      b < _coordLimit;

  int _slot(int cx, int cy) => ((cx * 73856093) ^ (cy * 19349663)) & _mask;

  /// Whether the box lands on one already added — on any of them, or with
  /// [markedOnly] just on those added as `marked`.
  bool overlaps(
    double x1,
    double y1,
    double x2,
    double y2, {
    bool markedOnly = false,
  }) {
    if (_undecidable) return true;
    if (_count == 0) return false;
    final l = math.min(x1, x2), r = math.max(x1, x2);
    final t = math.min(y1, y2), b = math.max(y1, y2);
    if (!_hashable(l, t, r, b)) return true;
    final boxes = _boxes, marks = _marks;
    if (_cellW == 0) {
      for (int o = 0, end = _count * 4; o < end; o += 4) {
        if (markedOnly && marks[o >> 2] == 0) continue;
        if (l < boxes[o + 2] &&
            boxes[o] < r &&
            t < boxes[o + 3] &&
            boxes[o + 1] < b) {
          return true;
        }
      }
      return false;
    }
    final cx0 = ((l - _maxHalfW) / _cellW).floor();
    final cx1 = ((r + _maxHalfW) / _cellW).floor();
    final cy0 = ((t - _maxHalfH) / _cellH).floor();
    final cy1 = ((b + _maxHalfH) / _cellH).floor();
    if ((cx1 - cx0 + 1) * (cy1 - cy0 + 1) > _maxCells) return true;
    final heads = _heads, next = _next;
    int tests = 0;
    for (int cx = cx0; cx <= cx1; cx++) {
      for (int cy = cy0; cy <= cy1; cy++) {
        for (int i = heads[_slot(cx, cy)]; i >= 0; i = next[i]) {
          if (++tests > _maxTests) return true;
          if (markedOnly && marks[i] == 0) continue;
          final o = i * 4;
          if (l < boxes[o + 2] &&
              boxes[o] < r &&
              t < boxes[o + 3] &&
              boxes[o + 1] < b) {
            return true;
          }
        }
      }
    }
    return false;
  }

  void add(double x1, double y1, double x2, double y2, {bool marked = false}) {
    final l = math.min(x1, x2), r = math.max(x1, x2);
    final t = math.min(y1, y2), b = math.max(y1, y2);
    if (!_hashable(l, t, r, b)) {
      _undecidable = true;
      return;
    }
    if (_count == _next.length) {
      _boxes = Float64List(_count * 8)..setRange(0, _count * 4, _boxes);
      _next = Int32List(_count * 2)..setRange(0, _count, _next);
      _marks = Uint8List(_count * 2)..setRange(0, _count, _marks);
    }
    _marks[_count] = marked ? 1 : 0;
    final o = _count * 4;
    _boxes[o] = l;
    _boxes[o + 1] = t;
    _boxes[o + 2] = r;
    _boxes[o + 3] = b;
    final halfW = (r - l) * 0.5, halfH = (b - t) * 0.5;
    if (halfW > _maxHalfW) _maxHalfW = halfW;
    if (halfH > _maxHalfH) _maxHalfH = halfH;
    final i = _count++;
    if (_cellW == 0) {
      if (_count > _scanLimit) {
        // Two shape-widths per cell: a query for a typical shape reaches two
        // cells per axis, each holding a handful of non-overlapping shapes.
        _cellW = math.max(_maxHalfW * 4, 1.0);
        _cellH = math.max(_maxHalfH * 4, 1.0);
        _regrid(_firstSlots);
      }
    } else if (_count > (_mask + 1) >> 1) {
      _regrid((_mask + 1) * 2);
    } else {
      _file(i);
    }
  }

  /// Resets the table to [slots] (a power of two) and files every box.
  void _regrid(int slots) {
    if (_heads.length < slots) _heads = Int32List(slots);
    _heads.fillRange(0, slots, -1);
    _mask = slots - 1;
    for (int j = 0; j < _count; j++) {
      _file(j);
    }
  }

  void _file(int i) {
    final o = i * 4;
    final slot = _slot(
      ((_boxes[o] + _boxes[o + 2]) * 0.5 / _cellW).floor(),
      ((_boxes[o + 1] + _boxes[o + 3]) * 0.5 / _cellH).floor(),
    );
    _next[i] = _heads[slot];
    _heads[slot] = i;
  }
}

/// An invertible 2D similarity: `[a -b dx; b a dy; 0 0 1]`.
/// The scale magnitude is tracked separately so rotation rounding cannot
/// create slightly different stroke widths and accidentally split a batch.
class const _FoldTransform({
  final double a = 1,
  final double b = 0,
  final double dx = 0,
  final double dy = 0,
  final double scale = 1,
}) {
  bool get hasLinear => a != 1 || b != 0;
  bool get isIdentity => !hasLinear && dx == 0 && dy == 0;

  double x(double x, double y) => a * x - b * y + dx;
  double y(double x, double y) => b * x + a * y + dy;

  Rect bounds(Rect rect) {
    final x0 = x(rect.left, rect.top), y0 = y(rect.left, rect.top);
    final x1 = x(rect.right, rect.top), y1 = y(rect.right, rect.top);
    final x2 = x(rect.right, rect.bottom), y2 = y(rect.right, rect.bottom);
    final x3 = x(rect.left, rect.bottom), y3 = y(rect.left, rect.bottom);
    return Rect.fromLTRB(
      math.min(math.min(x0, x1), math.min(x2, x3)),
      math.min(math.min(y0, y1), math.min(y2, y3)),
      math.max(math.max(x0, x1), math.max(x2, x3)),
      math.max(math.max(y0, y1), math.max(y2, y3)),
    );
  }

  _FoldTransform translated(double x, double y) => _FoldTransform(
    a: a,
    b: b,
    dx: this.x(x, y),
    dy: this.y(x, y),
    scale: scale,
  );

  _FoldTransform rotated(double angle) {
    final c = math.cos(angle), s = math.sin(angle);
    return _FoldTransform(
      a: a * c - b * s,
      b: b * c + a * s,
      dx: dx,
      dy: dy,
      scale: scale,
    );
  }

  _FoldTransform scaled(double factor) => _FoldTransform(
    a: a * factor,
    b: b * factor,
    dx: dx,
    dy: dy,
    scale: scale * factor.abs(),
  );

  _FoldTransform relativeTo(_FoldTransform previous) {
    if (identical(this, previous)) return const _FoldTransform();
    final d = previous.a * previous.a + previous.b * previous.b;
    final tx = dx - previous.dx, ty = dy - previous.dy;
    return _FoldTransform(
      a: (previous.a * a + previous.b * b) / d,
      b: (previous.a * b - previous.b * a) / d,
      dx: (previous.a * tx + previous.b * ty) / d,
      dy: (previous.a * ty - previous.b * tx) / d,
      scale: scale / previous.scale,
    );
  }

  void writeMatrix(Float64List storage) {
    storage[0] = a;
    storage[1] = b;
    storage[4] = -b;
    storage[5] = a;
    storage[12] = dx;
    storage[13] = dy;
  }

  Float64List get matrix =>
      Float64List.fromList([a, b, 0, 0, -b, a, 0, 0, 0, 0, 1, 0, dx, dy, 0, 1]);
}

/// Owns a lone blit's folded transform without changing the surrounding canvas
/// state. Multi-sprite runs instead carry these transforms in their atlas data.
class _TransformedImageRenderItem(
  final ImageRenderItem item,
  final _FoldTransform fold,
) extends Flut5RenderItem {
  @override
  late final Rect? bounds = fold.bounds(item.dst);
  late final Float64List _matrix = fold.matrix;

  @override
  void execute(Canvas canvas) {
    canvas.save();
    canvas.transform(_matrix);
    item.execute(canvas);
    canvas.restore();
  }
}

/// One open pixelate scope during a replay.
///
/// [canvas] records the scope at one pixel per block: its transform maps the
/// scope's local coordinates to logical pixels, then divides by the block
/// size, so block (i, j) covers logical
/// `[i·size, (i+1)·size) × [j·size, (j+1)·size)` whatever transform is
/// active. [end] rasterizes that and draws it back over the logical canvas
/// rect with nearest-neighbour sampling, so each block stays one flat colour.
///
/// A degenerate scope (block below one logical pixel, empty canvas, or a
/// transform that collapses the plane) passes its items straight through to
/// the parent canvas.
class _PixelatePass {
  _PixelatePass(PixelateBeginRenderItem scope, this.parent, Matrix4 logical)
    : logical = logical,
      canvas = parent {
    final size = scope.blockSize;
    if (!(size >= 1) || !size.isFinite) return;
    final cols = (scope.width / size).ceil();
    final rows = (scope.height / size).ceil();
    if (cols < 1 || rows < 1) return;
    final current = Matrix4.fromFloat64List(parent.getTransform());
    final fromLogical = Matrix4.zero();
    final fromCurrent = Matrix4.zero();
    if (fromLogical.copyInverse(logical) == 0 ||
        fromCurrent.copyInverse(current) == 0) {
      return;
    }
    final blocks = Matrix4.diagonal3Values(1 / size, 1 / size, 1);
    _cols = cols;
    _rows = rows;
    _size = size;
    // Scope-local → logical (logical⁻¹ · current) → blocks.
    final toBlocks = blocks.multiplied(fromLogical)..multiply(current);
    // From the parent's transform back to logical: current⁻¹ · logical.
    _back = fromCurrent..multiply(logical);
    final recorder = _recorder = ui.PictureRecorder();
    canvas = Canvas(recorder)..transform(toBlocks.storage);
    this.logical = blocks;
  }

  static final Paint _blockPaint = Paint()..filterQuality = FilterQuality.none;

  final Canvas parent;

  /// Where the scope's items draw.
  Canvas canvas;

  /// Logical pixels → [canvas] pixels, before any transform inside the
  /// scope. The base a nested scope builds its grid on.
  Matrix4 logical;

  ui.PictureRecorder? _recorder;
  late final Matrix4 _back;
  late final int _cols;
  late final int _rows;
  late final double _size;

  /// Draws the pixelated scope onto [parent] and returns it.
  Canvas end() {
    final recorder = _recorder;
    if (recorder == null) return parent;
    // Items balance their own saves; a push() left open in the scope must
    // not leak into the recording.
    while (canvas.getSaveCount() > 1) {
      canvas.restore();
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(_cols, _rows);
    picture.dispose();
    parent
      ..save()
      ..transform(_back.storage)
      ..drawImageRect(
        image,
        Rect.fromLTWH(0, 0, _cols.toDouble(), _rows.toDouble()),
        Rect.fromLTWH(0, 0, _cols * _size, _rows * _size),
        _blockPaint,
      )
      ..restore();
    // The recorded frame keeps its own reference to the pixels.
    image.dispose();
    return parent;
  }
}
