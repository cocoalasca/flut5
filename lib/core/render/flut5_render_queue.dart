import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../flut5_console.dart';
import '../../image/flut5_image_handles.dart';
import '../../image/flut5_image_shadows.dart';
import '../../text/flut5_font.dart';
import '../../text/flut5_text_cache.dart';
import '../flut5_shadow.dart';
import 'flut5_dash.dart';
import 'flut5_overlap_index.dart';
import 'flut5_paint_bounds.dart';
import 'flut5_render_item.dart';
import 'flut5_shaders.dart';
import 'items/flut5_multi_line_render_item.dart';
import 'items/flut5_multi_point_render_item.dart';
import 'items/flut5_path_render_item.dart';
import 'items/flut5_pixelate_render_item.dart';
import 'items/flut5_rect_render_item.dart';
import 'items/flut5_circle_render_item.dart';
import 'items/flut5_circle_run_render_item.dart';
import 'items/flut5_ellipse_render_item.dart';
import 'items/flut5_image_atlas_render_item.dart';
import 'items/flut5_image_render_item.dart';
import 'items/flut5_line_render_item.dart';
import 'items/flut5_arc_render_item.dart';
import 'items/flut5_background_render_item.dart';
import 'items/flut5_blur_render_item.dart';
import 'items/flut5_text_dynamic_batch_render_item.dart';
import 'items/flut5_text_dynamic_render_item.dart';
import 'items/flut5_text_render_item.dart';
import 'items/flut5_transform_render_item.dart';
import 'items/flut5_clip_render_item.dart';
export '../flut5_shadow.dart' show Flut5ShadowSpec;
export 'flut5_render_item.dart';
export 'flut5_shaders.dart';
export 'items/flut5_arc_render_item.dart';
export 'items/flut5_background_render_item.dart';
export 'items/flut5_blur_render_item.dart';
export 'items/flut5_circle_render_item.dart';
export 'items/flut5_circle_run_render_item.dart';
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
export 'items/flut5_text_dynamic_batch_render_item.dart'
    hide Flut5GlyphGrid, flut5TextInkBox;
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
/// text, background, or a primitive of a different kind) flushes the pending
/// batches first. So does an outlined shape drawn over one already in the
/// batch, when fill and stroke differ in colour — its fill has to cover the
/// earlier outline — and a translucent shape that comes within a few pixels
/// of one already in the batch, which one by one would blend over it twice.
///
/// A shape with a different paint closes the batch too, unless both are
/// plain opaque shapes with straight edges or arcs. Then the batch stays
/// open behind a new one, and later shapes of its colour go back into it
/// while they keep clear of everything drawn in between — where the order
/// they are drawn in cannot show — so a sketch of a few colours draws in a
/// few calls however its colours alternate.
///
/// Translation, rotation and uniform scale are folded into compatible geometry
/// at append time, including across push/pop scopes. Uniform scale adjusts
/// stroke widths; differing widths split batches. Nonuniform scale, matrices,
/// and operations that require canvas-local paint effects still emit transforms.
class Flut5RenderQueue() {
  final List<Flut5RenderItem> _items = [];

  // ── Pending points (auto-batched via drawRawPoints/PointMode.points) ──
  Float32List _pointBuffer = Float32List(0);
  int _pointCount = 0;
  Paint? _pendingPointPaint;
  Flut5ShadowSpec? _pendingPointShadow;
  final List<_OpenCoordBatch> _openPointBatches = [];
  final Map<Paint, int> _openPointBatchOfPaint = Map.identity();
  final Flut5OverlapIndex _laterPointBoxes = Flut5OverlapIndex();
  int _pointBoxFiledCount = 0;
  int _fruitlessPointOpenings = 0;
  int _restingPointPaintChanges = 0;

  // ── Pending lines (auto-batched via drawRawPoints/PointMode.lines) ────
  Float32List _lineBuffer = Float32List(0);
  int _lineCount = 0;
  Paint? _pendingLinePaint;
  Flut5ShadowSpec? _pendingLineShadow;
  final List<_OpenCoordBatch> _openLineBatches = [];
  final Map<Paint, int> _openLineBatchOfPaint = Map.identity();
  final Flut5OverlapIndex _laterLineBoxes = Flut5OverlapIndex();
  int _lineBoxFiledCount = 0;
  int _fruitlessLineOpenings = 0;
  int _restingLinePaintChanges = 0;

  static const int _mostOpenCoordBatches = 64;
  static const int _restingCoordPaintChangeCount = 1024;

  // ── Pending dynamic text (coalesced into drawRawAtlas batches) ────────
  //
  // Text waits to draw on top of the shape batches still open, so a sketch
  // that labels its shapes draws all the shapes and then all the labels. A
  // shape drawn after a label goes under it, so it only joins while it keeps
  // clear of every label queued so far ([_keepShapesBeneathText]).
  final List<Flut5TextDynamicEntry> _pendingTextEntries = [];
  final Flut5OverlapIndex _pendingTextBoxes = Flut5OverlapIndex();
  int _textBoxesFiled = 0;

  /// Whether text has been queued since the newest shape batch last grew.
  bool _textCrossedShapes = false;

  // Labels packed so close that most shapes land on the label before them
  // share few batches, and checking costs a layout lookup per label. So each
  // such shape counts against them, and one that keeps clear, saving a draw
  // call, takes [_clearCrossingCredit] off. Past
  // [_fruitlessTextCrossingsLimit], text and shapes draw strictly in turn
  // for the next [_restingTextCrossingCount] shapes. The counts carry over
  // from frame to frame, like [_fruitlessOpenings].
  int _fruitlessTextCrossings = 0;
  int _restingTextCrossings = 0;
  static const int _fruitlessTextCrossingsLimit = 32;
  static const int _clearCrossingCredit = 4;
  static const int _restingTextCrossingCount = 1024;

  // ── Per-frame TypedData arenas & batch pools ──────────────────────────
  // Sliced via sublistView; the queue drops its reference on clear() so items
  // retained past a frame remain immutable.
  Float32List? _frameArena;
  int _frameArenaOffset = 0;
  int _frameArenaTotal = 0;
  int _lastFrameArenaFloats = 0;

  Int32List? _intFrameArena;
  int _intFrameArenaOffset = 0;
  int _intFrameArenaTotal = 0;
  int _lastIntFrameArena = 0;

  static const int _maxPooledCoordBatches = 64;
  static const int _maxPooledImageBatches = 32;
  final List<_OpenCoordBatch> _coordBatchPool = [];
  final List<_OpenImageBatch> _imageBatchPool = [];

  _OpenCoordBatch _takeCoordBatch(Paint paint, Flut5ShadowSpec? shadow) {
    if (_coordBatchPool.isNotEmpty) {
      return _coordBatchPool.removeLast()..reset(paint, shadow);
    }
    return _OpenCoordBatch()..reset(paint, shadow);
  }

  void _releaseCoordBatches(List<_OpenCoordBatch> batches) {
    for (final batch in batches) {
      batch.clearRefs();
      if (_coordBatchPool.length < _maxPooledCoordBatches) {
        _coordBatchPool.add(batch);
      }
    }
    batches.clear();
  }

  _OpenImageBatch _takeImageBatch({
    required ui.Image image,
    required BlendMode blendMode,
    required FilterQuality filterQuality,
    required Rect firstSrc,
    required Rect firstDst,
    required _FoldTransform? firstFold,
    required Color? firstTint,
    required Rect bounds,
    required bool hasRotation,
  }) {
    if (_imageBatchPool.isNotEmpty) {
      return _imageBatchPool.removeLast()..reset(
        image: image,
        blendMode: blendMode,
        filterQuality: filterQuality,
        firstSrc: firstSrc,
        firstDst: firstDst,
        firstFold: firstFold,
        firstTint: firstTint,
        bounds: bounds,
        hasRotation: hasRotation,
      );
    }
    return _OpenImageBatch()..reset(
      image: image,
      blendMode: blendMode,
      filterQuality: filterQuality,
      firstSrc: firstSrc,
      firstDst: firstDst,
      firstFold: firstFold,
      firstTint: firstTint,
      bounds: bounds,
      hasRotation: hasRotation,
    );
  }

  void _releaseImageBatches(List<_OpenImageBatch> batches) {
    for (final batch in batches) {
      batch.clearRefs();
      if (_imageBatchPool.length < _maxPooledImageBatches) {
        _imageBatchPool.add(batch);
      }
    }
    batches.clear();
  }

  Float32List _allocArenaCopy(Float32List src, int length) {
    var arena = _frameArena;
    if (arena == null || _frameArenaOffset + length > arena.length) {
      var cap = _lastFrameArenaFloats;
      if (cap < 256) cap = 256;
      if (cap > 65536) cap = 65536;
      if (length > cap) cap = length;
      arena = _frameArena = Float32List(cap);
      _frameArenaOffset = 0;
    }
    final start = _frameArenaOffset;
    final end = start + length;
    arena.setRange(start, end, src);
    _frameArenaOffset = end;
    _frameArenaTotal += length;
    return Float32List.sublistView(arena, start, end);
  }

  Int32List _allocIntArenaCopy(Int32List src, int length) {
    var arena = _intFrameArena;
    if (arena == null || _intFrameArenaOffset + length > arena.length) {
      var cap = _lastIntFrameArena;
      if (cap < 64) cap = 64;
      if (cap > 16384) cap = 16384;
      if (length > cap) cap = length;
      arena = _intFrameArena = Int32List(cap);
      _intFrameArenaOffset = 0;
    }
    final start = _intFrameArenaOffset;
    final end = start + length;
    arena.setRange(start, end, src);
    _intFrameArenaOffset = end;
    _intFrameArenaTotal += length;
    return Int32List.sublistView(arena, start, end);
  }

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
  final Flut5OverlapIndex _pendingShapeBoxes = Flut5OverlapIndex();
  bool _pendingShapeTracked = false;

  // ── Circle runs (Skia only) ───────────────────────────────────────────
  //
  // While every shape in the newest batch is a filled, anti-aliased,
  // unshadowed circle of one radius, the circles are not added to its path:
  // their centres are kept here instead, and the batch is queued as one
  // [CircleRunRenderItem] — round points, which Skia draws exactly as it
  // draws each circle alone, for a fraction of a path's cost. The first
  // shape that breaks the run has the kept circles added to the path, in
  // order, and the batch carries on exactly as it would have.

  /// Whether this backend draws a round point the way it draws a circle —
  /// true on Skia, false on Impeller. See [CircleRunRenderItem].
  static final bool _skiaCircles = !ui.ImageFilter.isShaderFilterSupported;

  /// Forces circle runs on or off regardless of backend, or restores
  /// detection with `null`. Test seam: `flutter test` runs Skia unless
  /// `--enable-impeller` is passed.
  @visibleForTesting
  static bool? debugCirclesAsPoints;

  static bool get _circlesAsPoints => debugCirclesAsPoints ?? _skiaCircles;

  /// Whether shapes batch by the web's rules — see [_drawnAlone].
  ///
  /// On the web (CanvasKit and skwasm) a merged path costs by its bounds,
  /// not by its shapes: without multisampling, Skia draws an anti-aliased
  /// path of many contours by rasterizing a coverage mask of its whole
  /// bounds on the CPU, about 0.7 ms per canvas-sized path at 1600×1026,
  /// while shapes drawn one by one go to its GPU ops, which batch them
  /// itself. Measured on CanvasKit, 3000 shapes, build + raster:
  ///
  /// | scene | merged | web rules |
  /// |---|---|---|
  /// | fill + stroke circles | 90 ms | 12 ms |
  /// | stroke-only circles / rects | 35 / 18 ms | 6 / 6 ms |
  /// | translucent squares | 41 ms | 6.4 ms |
  /// | squares in 8 colours, random order | 76 ms | 19 ms |
  ///
  /// Opaque fill-only shapes of one colour still merge (a single path is as
  /// cheap or cheaper there), and nothing slowed down in the scenes measured.
  /// Every shape the rules take out of a batch draws the way it draws alone,
  /// which on Skia is also the closer picture.
  static bool get _webBatching => debugWebBatching ?? kIsWeb;

  /// Forces the web batching rules on or off regardless of platform, or
  /// restores detection with `null`. Test seam.
  @visibleForTesting
  static bool? debugWebBatching;

  /// True while the newest batch holds only kept circles, none of them in
  /// its path yet.
  bool _circleRunOpen = false;
  double _circleRunRadius = 0;
  Float64List _circleRun = Float64List(256);

  /// Doubles used in [_circleRun], two per circle.
  int _circleRunLength = 0;
  Float32List _circleRunScratch = Float32List(0);

  // One-entry memo for [_circleRunPaint]: point paints are immutable once
  // queued, so the same fill at the same radius can share one.
  Paint? _circleRunPaintFill;
  double _circleRunPaintRadius = -1;
  Paint? _circleRunPaintMemo;
  Paint? _stacksFill;
  Paint? _stacksStroke;
  bool _stacksResult = false;

  // ── Open colour batches ───────────────────────────────────────────────
  //
  // A sketch that gives every particle one of a few colours changes paint
  // with nearly every shape, and closing the batch each time leaves one draw
  // call per shape. So the batch being left stays open instead, and a later
  // shape of its colour goes back into it — as long as that shape keeps
  // clear of everything drawn since, in the batches opened after it. Two
  // shapes that share no pixel look the same in either order, so the frame
  // is unchanged; one that does touch a later shape opens a new batch on
  // top, exactly as before.
  //
  // [_openBatches] holds the batches left open, oldest first, and the
  // `_pendingShape*` fields above are the newest. All of them are plain:
  // opaque, and with nothing to keep off within the batch (no stacking
  // outline, no backwards winding). Anything else closes them all first.
  //
  // Going back into an older batch merges a shape with shapes it did not
  // follow directly, which it would not have shared a path with before.
  // That is invisible for straight-edged shapes and arcs: on Impeller they
  // rasterize the same in a path of their own as in one shared with others
  // (measured identical). Circles, ellipses and rounded rects do not — in a
  // path of their own the canvas draws them with its renderer for that
  // shape, whose edge anti-aliasing differs from a path's by up to a
  // quarter of full scale on edge pixels. So unless
  // [_reordersShapesWithOwnRenderer] is on, they batch exactly as before:
  // with the shapes of their paint drawn right before and after them, and a
  // batch holding one closes at the next change of paint.
  final List<PathRenderItem> _openBatches = [];

  /// Whether circles, ellipses and rounded rects take part in the open
  /// colour batches too. That would give every one of them in a sketch of
  /// many colours the path-rendered edges they already have in a sketch of
  /// one colour, in place of the canvas's own circle and rounded-rect edges
  /// they keep while each is alone in its batch.
  static const bool _reordersShapesWithOwnRenderer = false;

  /// Where in [_openBatches] the newest batch drawing with a paint is, by
  /// the fill if it has one, else the stroke.
  final Map<Paint, int> _openBatchOfPaint = Map.identity();

  /// The boxes of every shape in an open batch after the first, each grown
  /// as in [_keepsApart] and filed under its batch's place among the open
  /// ones. The first batch needs none: nothing is ever drawn before it.
  final Flut5OverlapIndex _laterShapeBoxes = Flut5OverlapIndex();

  /// Boxes of the newest batch's shapes, four doubles each, not yet filed
  /// in [_laterShapeBoxes]. Filing waits for the next change of colour, so
  /// a long run of one colour pays only for writing them down.
  Float64List _newestShapeBoxes = Float64List(64);
  int _newestShapeBoxCount = 0;

  /// Whether the newest batch may stay open when another colour starts: it
  /// is plain, every shape in it has its box on record, and all of them
  /// merge exactly (see [_beginShape]).
  bool _newestStaysOpen = false;

  /// How many batches stay open behind the newest. One more closes them
  /// all, and the count starts over.
  static const int _mostOpenBatches = 256;

  // A sketch whose every shape has a colour of its own gains nothing from
  // open batches and pays for keeping them (measured: a third more time
  // queueing each shape). So once [_fruitlessOpeningsLimit] batches have
  // been opened in a row without a shape ever going back into one — as many
  // as stay open, so a palette that fits never gets there — paint changes
  // close the batch, as they used to, for the next
  // [_restingPaintChangeCount] changes. The counts carry over from frame to
  // frame: a sketch draws much the same every frame.
  int _fruitlessOpenings = 0;
  int _restingPaintChanges = 0;
  static const int _fruitlessOpeningsLimit = _mostOpenBatches;
  static const int _restingPaintChangeCount = 2048;

  /// Whether shapes may be drawn in another order than the sketch's where
  /// they keep clear of each other. Not under a shadow, on a canvas carrying
  /// a materialized scale or in a pixelate scope, for the reasons given in
  /// [_batchesApart].
  bool get _mayReorderShapes =>
      _activeShadow == null && !_canvasLinear && _pixelateScopes == 0;

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
  FilterQuality _pendingAtlasFilterQuality = FilterQuality.medium;
  Float32List _atlasTransforms = Float32List(0);
  Float32List _atlasRects = Float32List(0);
  Int32List _atlasColors = Int32List(0);
  int _atlasCount = 0;
  bool _atlasHasRotation = false;
  bool _atlasHasTint = false;
  Color? _atlasFirstTint;
  final List<_OpenImageBatch> _openImageBatches = [];
  final Map<ui.Image, int> _openImageBatchOfImage = Map.identity();
  final Flut5OverlapIndex _laterImageBoxes = Flut5OverlapIndex();
  Float64List _newestAtlasBoxes = Float64List(32);
  int _newestAtlasBoxCount = 0;
  int _fruitlessImageOpenings = 0;
  int _restingImageChanges = 0;
  static const int _mostOpenImageBatches = 32;
  static const int _restingImageChangeCount = 512;

  /// Running union of the destination rects in the open run, so the flushed
  /// item carries bounds without re-reading the float32 buffers.
  Rect? _atlasBounds;

  /// Bitmaps this frame's items will paint, held through
  /// [Flut5ImageHandles] so an `updatePixels()`, `resize()` or `dispose()`
  /// later in the frame can't free them first. Released by [clear]. One
  /// entry per standalone blit or atlas run, not per sprite.
  final List<ui.Image> _heldImages = [];

  void _holdImage(ui.Image image) {
    _heldImages.add(image);
    Flut5ImageHandles.hold(image);
  }

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

  void _ensureAtlasColorCapacity(int sprites) {
    if (_atlasColors.length >= sprites) return;
    int newLen = _atlasColors.isEmpty ? 16 : _atlasColors.length * 2;
    while (newLen < sprites) {
      newLen *= 2;
    }
    final next = Int32List(newLen);
    if (_atlasHasTint && _atlasCount > 0) {
      next.setRange(0, _atlasCount, _atlasColors);
    }
    _atlasColors = next;
  }

  // ── Batch paths, reused across frames ─────────────────────────────────
  //
  // Every shape batch draws from a [Path] of its own, and a sketch that
  // changes colour with every shape opens thousands of batches a frame. A
  // new path costs a native allocation and a finalizer; one handed back by
  // [clear] and reset costs a single call. The canvas copies a path's
  // outline when it is drawn, so a frame already recorded — on screen or in
  // a trail capture still rasterizing — is untouched by the reuse.
  final List<Path> _batchPaths = [];
  int _batchPathsInUse = 0;

  // The most paths one frame used since the last trim, so a single busy
  // frame doesn't keep its paths alive for the rest of the sketch.
  int _mostBatchPathsInUse = 0;
  int _framesSincePathTrim = 0;
  static const int _framesBetweenPathTrims = 120;

  /// An empty path for a batch or a shape drawn on its own, kept until
  /// [clear]. Only for paths this queue fills itself and hands to an item:
  /// nothing else may hold on to one past the frame.
  Path _takeBatchPath() {
    if (_batchPathsInUse < _batchPaths.length) {
      return _batchPaths[_batchPathsInUse++]..reset();
    }
    final path = Path();
    _batchPaths.add(path);
    _batchPathsInUse++;
    return path;
  }

  /// Hands every path taken this frame back for the next one.
  void _releaseBatchPaths() {
    if (_batchPathsInUse > _mostBatchPathsInUse) {
      _mostBatchPathsInUse = _batchPathsInUse;
    }
    _batchPathsInUse = 0;
    if (++_framesSincePathTrim < _framesBetweenPathTrims) return;
    if (_batchPaths.length > _mostBatchPathsInUse) {
      _batchPaths.length = _mostBatchPathsInUse;
    }
    _mostBatchPathsInUse = 0;
    _framesSincePathTrim = 0;
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
  //
  // Stored as mutable primitive fields + a flat typed-list stack so inner-loop
  // push()/translate()/rotate()/scale()/pop() sequences allocate zero objects.
  double _foldA = 1.0;
  double _foldB = 0.0;
  double _foldDx = 0.0;
  double _foldDy = 0.0;
  double _foldScale = 1.0;

  // Per entry: 5 doubles (a, b, dx, dy, scale) and 1 flag byte
  // (bit 0 = real canvas save, bit 1 = saved _canvasLinear).
  Float64List _foldStackVals = Float64List(32 * 5);
  Uint8List _foldStackFlags = Uint8List(32);
  int _foldDepth = 0;
  int _unmaterializedFolds = 0;

  /// Whether the canvas itself carries a rotation, scale or matrix — one
  /// materialized rather than folded into geometry. Queue coordinates then
  /// stop being logical pixels, so distances measured in them say nothing
  /// about which device pixels two shapes touch.
  bool _canvasLinear = false;
  final Map<Paint, Map<double, Paint>> _scaledStrokes = Map.identity();
  int _scaledStrokeCount = 0;
  static const int _scaledStrokeCap = 256;
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

  bool get _foldHasLinear => _foldA != 1.0 || _foldB != 0.0;
  bool get _foldIsIdentity =>
      _foldA == 1.0 && _foldB == 0.0 && _foldDx == 0.0 && _foldDy == 0.0;
  bool get _hasFoldOffset => _foldDx != 0.0 || _foldDy != 0.0;

  double _foldX(double x, double y) => _foldA * x - _foldB * y + _foldDx;
  double _foldY(double x, double y) => _foldB * x + _foldA * y + _foldDy;

  Rect _foldBounds(Rect rect) {
    final x0 = _foldX(rect.left, rect.top), y0 = _foldY(rect.left, rect.top);
    final x1 = _foldX(rect.right, rect.top), y1 = _foldY(rect.right, rect.top);
    final x2 = _foldX(rect.right, rect.bottom),
        y2 = _foldY(rect.right, rect.bottom);
    final x3 = _foldX(rect.left, rect.bottom),
        y3 = _foldY(rect.left, rect.bottom);
    return Rect.fromLTRB(
      math.min(math.min(x0, x1), math.min(x2, x3)),
      math.min(math.min(y0, y1), math.min(y2, y3)),
      math.max(math.max(x0, x1), math.max(x2, x3)),
      math.max(math.max(y0, y1), math.max(y2, y3)),
    );
  }

  void _writeFoldMatrix(Float64List storage) {
    storage[0] = _foldA;
    storage[1] = _foldB;
    storage[4] = -_foldB;
    storage[5] = _foldA;
    storage[12] = _foldDx;
    storage[13] = _foldDy;
  }

  _FoldTransform _snapshotFold() => _FoldTransform(
    a: _foldA,
    b: _foldB,
    dx: _foldDx,
    dy: _foldDy,
    scale: _foldScale,
  );

  // Shadows, dashes and shaders depend on the original local coordinate
  // system. Keep their existing canvas rendering rather than transforming
  // only the outline and silently changing their appearance.
  //
  // [alone] is the caller's own verdict on whether the shape draws by itself,
  // for shapes [_drawnAlone] alone does not decide.
  void _prepareGeometry(
    Paint? fill,
    Paint? stroke, {
    bool points = false,
    bool? alone,
  }) {
    if (!_foldHasLinear) {
      // A shader is laid out in the sketch's coordinates. Moving only the
      // geometry would slide the shape out from under its gradient.
      if (_hasFoldOffset && (fill?.shader != null || stroke?.shader != null)) {
        _materializeTransforms();
      }
      return;
    }
    if (_activeShadow != null ||
        (_hasDash && stroke != null && !points) ||
        (alone ?? _drawnAlone(fill, stroke)) ||
        (points && stroke?.strokeCap != StrokeCap.round)) {
      _materializeTransforms();
    }
  }

  Paint? _foldStroke(Paint? stroke) {
    if (stroke == null || _foldScale == 1.0 || stroke.strokeWidth == 0) {
      return stroke;
    }
    var variants = _scaledStrokes[stroke];
    if (variants != null) {
      final cached = variants[_foldScale];
      if (cached != null) return cached;
    }
    if (_scaledStrokeCount >= _scaledStrokeCap) {
      _scaledStrokes.clear();
      _scaledStrokeCount = 0;
      variants = null;
    }
    variants ??= _scaledStrokes[stroke] = <double, Paint>{};
    _scaledStrokeCount++;
    return variants[_foldScale] = Paint.from(stroke)
      ..strokeWidth = stroke.strokeWidth * _foldScale;
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
    bool mergesExactly = true,
  }) {
    if (fill == null && stroke == null) return;
    stroke = _foldStroke(stroke);
    // A box that has to be measured is only worth it when the batch can't
    // do without; one handed over is free.
    final wantsBox = localBounds != null
        ? _wantsBox(fill, stroke, oriented)
        : _needsBox(fill, stroke, oriented);
    final bounds = wantsBox
        ? _foldBounds(localBounds ?? path.getBounds())
        : null;
    _writeFoldMatrix(_transformMatrix);
    _beginShape(
      fill,
      stroke,
      bounds,
      oriented: oriented,
      mergesExactly: mergesExactly,
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
    if (_foldDepth == _foldStackFlags.length) {
      final newCap = _foldStackFlags.length * 2;
      _foldStackVals = Float64List(newCap * 5)
        ..setRange(0, _foldDepth * 5, _foldStackVals);
      _foldStackFlags = Uint8List(newCap)
        ..setRange(0, _foldDepth, _foldStackFlags);
    }
    final base = _foldDepth * 5;
    _foldStackVals[base] = _foldA;
    _foldStackVals[base + 1] = _foldB;
    _foldStackVals[base + 2] = _foldDx;
    _foldStackVals[base + 3] = _foldDy;
    _foldStackVals[base + 4] = _foldScale;
    _foldStackFlags[_foldDepth] = 0;
    _foldDepth++;
    _unmaterializedFolds++;
  }

  /// Records a `pop()`. Folded entries restore the pending transform silently;
  /// materialized (`real`) entries emit a canvas restore.
  void popTransform() {
    if (_scopes.isNotEmpty && _foldDepth == _scopes.last.depth) {
      final name = _scopeName(_scopes.last.pixelate);
      Flut5Console.printLater(
        'pop() inside begin$name()/end$name() has no push() inside the scope '
        'to match and was ignored.',
      );
      return;
    }
    if (_foldDepth == 0) {
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
    final topFlags = _foldStackFlags[_foldDepth - 1];
    final real = (topFlags & 1) != 0;
    if (real && _clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): pop() of a scope opened outside the clip callback was '
        'ignored inside the callback.',
      );
      return;
    }
    _foldDepth--;
    final base = _foldDepth * 5;
    if (real) {
      _addItem(TransformRenderItem.pop());
      _canvasLinear = (topFlags & 2) != 0;
    } else {
      _unmaterializedFolds--;
    }
    _foldA = _foldStackVals[base];
    _foldB = _foldStackVals[base + 1];
    _foldDx = _foldStackVals[base + 2];
    _foldDy = _foldStackVals[base + 3];
    _foldScale = _foldStackVals[base + 4];
  }

  /// Records a `translate()`. Never emits an item — the offset is baked into
  /// geometry at append time, so batches keep accumulating across it.
  void translateTransform(double dx, double dy) {
    final nextDx = _foldA * dx - _foldB * dy + _foldDx;
    final nextDy = _foldB * dx + _foldA * dy + _foldDy;
    _foldDx = nextDx;
    _foldDy = nextDy;
  }

  /// Records a 2D rotation in [radians] without allocating a render item when
  /// foldable.
  void rotateTransform(double radians) {
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): rotate()/scale()/applyMatrix() are not supported inside a '
        'clip callback and were ignored (translate/push/pop do apply).',
      );
      return;
    }
    if (radians.isFinite) {
      final c = math.cos(radians);
      final s = math.sin(radians);
      final nextA = _foldA * c - _foldB * s;
      final nextB = _foldB * c + _foldA * s;
      _foldA = nextA;
      _foldB = nextB;
      return;
    }
    _materializeTransforms();
    _canvasLinear = true;
    _addItem(TransformRenderItem.rotate(radians));
  }

  /// Records a 2D scale ([sx], [sy]) without allocating a render item when
  /// uniform and invertible.
  void scaleTransform(double sx, double sy) {
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): rotate()/scale()/applyMatrix() are not supported inside a '
        'clip callback and were ignored (translate/push/pop do apply).',
      );
      return;
    }
    if (sx == sy && sx.isFinite && sx != 0) {
      final nextA = _foldA * sx;
      final nextB = _foldB * sx;
      // Keep the folded state invertible for materializing nested saves.
      final determinant = nextA * nextA + nextB * nextB;
      if (determinant.isFinite && determinant > 0) {
        _foldA = nextA;
        _foldB = nextB;
        _foldScale *= sx.abs();
        return;
      }
    }
    _materializeTransforms();
    _canvasLinear = true;
    _addItem(TransformRenderItem.scale(sx, sy));
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
    if (item.type == TransformType.rotate) {
      rotateTransform(item.rotation!);
      return;
    }
    if (item.type == TransformType.scale) {
      scaleTransform(item.scaleX!, item.scaleY!);
      return;
    }
    _materializeTransforms();
    if (item.type != TransformType.translate) _canvasLinear = true;
    _addItem(item);
  }

  /// Moves pending transforms onto the canvas, preserving every saved scope.
  /// Each saved transform is relative to the last materialized canvas state.
  /// Emit the delta between saved states before their corresponding save.
  void _materializeTransforms() {
    if (_foldIsIdentity && _unmaterializedFolds == 0) return;
    flushPending();
    var prevA = 1.0, prevB = 0.0, prevDx = 0.0, prevDy = 0.0;
    for (int i = 0; i < _foldDepth; i++) {
      if ((_foldStackFlags[i] & 1) != 0) continue;
      final base = i * 5;
      final savedA = _foldStackVals[base];
      final savedB = _foldStackVals[base + 1];
      final savedDx = _foldStackVals[base + 2];
      final savedDy = _foldStackVals[base + 3];
      _emitFoldDelta(
        prevA,
        prevB,
        prevDx,
        prevDy,
        savedA,
        savedB,
        savedDx,
        savedDy,
      );
      _items.add(TransformRenderItem.push());
      prevA = savedA;
      prevB = savedB;
      prevDx = savedDx;
      prevDy = savedDy;
      _foldStackVals[base] = 1.0;
      _foldStackVals[base + 1] = 0.0;
      _foldStackVals[base + 2] = 0.0;
      _foldStackVals[base + 3] = 0.0;
      _foldStackVals[base + 4] = 1.0;
      _foldStackFlags[i] = 1 | (_canvasLinear ? 2 : 0);
    }
    _emitFoldDelta(
      prevA,
      prevB,
      prevDx,
      prevDy,
      _foldA,
      _foldB,
      _foldDx,
      _foldDy,
    );
    _foldA = 1.0;
    _foldB = 0.0;
    _foldDx = 0.0;
    _foldDy = 0.0;
    _foldScale = 1.0;
    _unmaterializedFolds = 0;
  }

  void _emitFoldDelta(
    double fromA,
    double fromB,
    double fromDx,
    double fromDy,
    double toA,
    double toB,
    double toDx,
    double toDy,
  ) {
    if (fromA == toA && fromB == toB && fromDx == toDx && fromDy == toDy) {
      return;
    }
    final d = fromA * fromA + fromB * fromB;
    final tx = toDx - fromDx;
    final ty = toDy - fromDy;
    final ra = (fromA * toA + fromB * toB) / d;
    final rb = (fromA * toB - fromB * toA) / d;
    final rdx = (fromA * tx + fromB * ty) / d;
    final rdy = (fromA * ty - fromB * tx) / d;
    if (ra == 1.0 && rb == 0.0 && rdx == 0.0 && rdy == 0.0) return;
    if (ra == 1.0 && rb == 0.0) {
      _items.add(TransformRenderItem.translate(rdx, rdy));
    } else {
      _items.add(
        TransformRenderItem.matrix(
          Float64List.fromList([
            ra,
            rb,
            0,
            0,
            -rb,
            ra,
            0,
            0,
            0,
            0,
            1,
            0,
            rdx,
            rdy,
            0,
            1,
          ]),
        ),
      );
      _canvasLinear = true;
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
  /// an active blur, or a paint [canBatchPaint] rejects — unless all that
  /// sets it apart is opacity and it may still batch with the shapes it
  /// keeps clear of ([_batchesApart]).
  ///
  /// A translucent rect, oval or arc drawn alone goes through the canvas's
  /// dedicated renderer for that shape; merged into a batch path its edges
  /// are anti-aliased by the path renderer instead, exactly as an opaque
  /// batch already draws them (measured on Impeller: up to 47 levels on
  /// edge pixels, nothing else). Polygons and vertex shapes are paths either
  /// way and come out identical.
  ///
  /// Under [_webBatching], stroked and translucent shapes always draw alone:
  /// their batches are the ones that end up as many canvas-wide paths
  /// (strokes split where an outline would show through, translucent shapes
  /// wherever two come close). A translucent filled [circle] is the
  /// exception while circle runs apply — a run is one point call, cheaper
  /// still, and draws each circle as it draws alone.
  bool _drawnAlone(Paint? fill, Paint? stroke, {bool circle = false}) {
    if (_blurLayer != null) return true;
    if (_webBatching &&
        (stroke != null || (fill != null && fill.color.a < 1.0)) &&
        !(circle &&
            stroke == null &&
            _activeShadow == null &&
            _circlesAsPoints)) {
      return true;
    }
    if (canBatchPaint(fill) && canBatchPaint(stroke)) return false;
    return !_batchesApart(fill, stroke);
  }

  /// True when translucent shapes painted with [fill]/[stroke] may share a
  /// batch with the shapes they keep clear of — see [_keepsApart] for what
  /// clear means.
  ///
  /// Not under a shadow (one shadow pass beneath the batch would land under
  /// neighbours a shape-by-shape shadow covers), on a canvas carrying a
  /// materialized scale (the clearance is measured in logical pixels), or in
  /// a pixelate scope (whose pixels are whole blocks).
  bool _batchesApart(Paint? fill, Paint? stroke) =>
      _activeShadow == null &&
      !_canvasLinear &&
      _pixelateScopes == 0 &&
      (fill == null || _plainPaint(fill)) &&
      (stroke == null || _plainPaint(stroke));

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
  /// own entry, its kind, and its opening index in [_items].
  final List<({int depth, bool pixelate, int beginIndex})> _scopes = [];

  /// How many of [_scopes] are pixelate scopes.
  int _pixelateScopes = 0;

  /// Whether this frame holds a pixelate scope, so other frames keep the
  /// plain replay. Blur scopes need nothing from the replay.
  bool _hasPixelate = false;
  final _PaletteImages _palettes = _PaletteImages();
  bool _warnedOpenScope = false;
  bool _warnedScopeLeak = false;

  static String _scopeName(bool pixelate) => pixelate ? 'Pixelate' : 'Blur';

  /// Opens a pixelate scope of [blockSize] logical pixels over a canvas of
  /// [width]×[height]. Pending batches flush first, so nothing drawn before
  /// the scope joins a batch inside it.
  ///
  /// A non-empty [palette] snaps every block to its nearest colour. It is
  /// copied, so changing the list afterwards leaves this frame alone.
  void beginPixelate(
    double blockSize,
    double width,
    double height, {
    List<Color>? palette,
  }) {
    final colors = palette == null || palette.isEmpty
        ? null
        : List<Color>.unmodifiable(palette);
    // Flut5Canvas starts this; it covers queues replayed elsewhere.
    if (colors != null) Flut5Shaders.load();
    _beginScope(
      PixelateBeginRenderItem(blockSize, width, height, palette: colors),
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
      BlurBeginRenderItem(
        blurs ? _layerPaintFor(sigma) : null,
        sigma: blurs ? sigma : 0,
      ),
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
    final beginIndex = _items.length;
    _scopes.add((depth: _foldDepth, pixelate: pixelate, beginIndex: beginIndex));
    if (pixelate) _pixelateScopes++;
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
    if (_foldDepth > scope.depth && !_warnedScopeLeak) {
      _warnedScopeLeak = true;
      Flut5Console.printLater(
        'end$name() closed ${_foldDepth - scope.depth} push() left '
        'open inside the scope. Add the missing pop() to fix it.',
      );
    }
    while (_foldDepth > scope.depth) {
      popTransform();
    }
    _scopes.removeLast();
    if (pixelate) _pixelateScopes--;
    popTransform();
    flushPending();
    if (!pixelate && BlurRenderItem.boundLayers) {
      final beginItem = _items[scope.beginIndex];
      if (beginItem is BlurBeginRenderItem && beginItem.layerPaint != null) {
        final result = _blurScopeContentBounds(scope.beginIndex);
        beginItem.emptyScope = result.empty;
        beginItem.contentBounds = result.bounds;
      }
    }
    _items.add(marker);
  }

  /// Paint bounds of everything inside the blur scope at [beginIndex], in the
  /// scope's entry coordinates, or `(bounds: null, empty: false)` if any child
  /// has unknown/unbounded extent (backgrounds, nested scopes, or items without
  /// bounds). Distinguishes an empty scope from a zero-area hairline whose
  /// stroke/AA/blur still paints.
  ({Rect? bounds, bool empty}) _blurScopeContentBounds(int beginIndex) {
    final stack = <Matrix4>[];
    Matrix4? current;
    Rect? painted;
    for (var i = beginIndex + 1; i < _items.length; i++) {
      final item = _items[i];
      if (item is TransformRenderItem) {
        current = _appliedTo(current, item, stack);
        continue;
      }
      if (item is ClipRenderItem) continue;
      if (item is BackgroundRenderItem ||
          item is BlurBeginRenderItem ||
          item is BlurEndRenderItem ||
          item is PixelateBeginRenderItem ||
          item is PixelateEndRenderItem) {
        return (bounds: null, empty: false);
      }
      final bounds = flut5PaintBounds(item, 0);
      if (bounds == null) return (bounds: null, empty: false);
      final placed = current == null
          ? bounds
          : MatrixUtils.transformRect(current, bounds);
      painted = painted == null ? placed : painted.expandToInclude(placed);
    }
    return painted == null
        ? (bounds: null, empty: true)
        : (bounds: painted, empty: false);
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
    _flushText();
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
  ///
  /// Translucent shapes still batch with the shapes they keep clear of — see
  /// [_batchesApart].
  static bool canBatchPaint(Paint? paint) =>
      paint == null || (paint.color.a == 1.0 && _plainPaint(paint));

  /// [canBatchPaint] with opacity left out: no shader, blend mode or filter.
  static bool _plainPaint(Paint paint) =>
      paint.shader == null &&
      paint.blendMode == BlendMode.srcOver &&
      paint.maskFilter == null &&
      paint.colorFilter == null &&
      paint.imageFilter == null;

  // ── Append entry points ───────────────────────────────────────────────

  /// True when there are no queued or pending draw operations for this frame.
  bool get isEmpty =>
      _items.isEmpty &&
      _pointCount == 0 &&
      _openPointBatches.isEmpty &&
      _lineCount == 0 &&
      _openLineBatches.isEmpty &&
      _atlasCount == 0 &&
      _openImageBatches.isEmpty &&
      _pendingTextEntries.isEmpty &&
      !_pendingShapeHasContent;

  /// Whether points painted with [paint] stand apart from the folded
  /// geometry — blurred, or a paint whose shader or filter is laid out in
  /// canvas coordinates. Opacity doesn't count: every point in a
  /// [Canvas.drawRawPoints] run blends on its own, so a translucent run
  /// draws exactly like its points one by one, wherever they overlap.
  bool _pointsAlone(Paint paint) => _blurLayer != null || !_plainPaint(paint);

  /// Whether a line painted with [paint] draws as its own item. Opacity only
  /// counts under a shadow: a run casts its shadow beneath all of its lines,
  /// where one by one each line's shadow would cover the lines before it.
  /// Otherwise a run draws exactly like its segments one by one —
  /// [Canvas.drawRawPoints] strokes and blends every segment on its own,
  /// measured identical on Skia and on Impeller for every cap.
  bool _lineAlone(Paint paint, bool opaque) =>
      _blurLayer != null ||
      !_plainPaint(paint) ||
      (!opaque && _activeShadow != null);

  static double _pointPad(Paint paint) =>
      _apartClearance + paint.strokeWidth * 0.5 * math.sqrt2;

  static double _linePad(Paint stroke) {
    final reach = stroke.strokeJoin == StrokeJoin.miter
        ? math.max(stroke.strokeMiterLimit, math.sqrt2)
        : math.sqrt2;
    return _apartClearance + stroke.strokeWidth * 0.5 * reach;
  }

  /// Append a point to the auto-batch buffer. Consecutive calls with the same
  /// [paint] reference coalesce; a change in paint identity parks the open
  /// batch when safe so non-overlapping multi-colour points merge back into
  /// their colour's run, preserving exact z-order.
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
    final alone = _pointsAlone(paint);
    _prepareGeometry(null, paint, points: true, alone: alone);
    paint = _foldStroke(paint)!;
    final transformedX = _foldX(x, y);
    y = _foldY(x, y);
    x = transformedX;
    if (_pendingPointPaint != null && !identical(_pendingPointPaint, paint)) {
      if (_tryJoinOrParkPointBatch(x, y, paint, alone)) return;
    }
    _flushLines();
    _flushShapes();
    _flushImages();
    _flushText();
    _pendingPointPaint = paint;
    _pendingPointShadow = _activeShadow;
    _ensurePointCapacity(_pointCount + 2);
    _pointBuffer[_pointCount++] = x;
    _pointBuffer[_pointCount++] = y;
    // Blurred points draw one by one — the run never grows past this point.
    if (_blurLayer != null) _addItem(_takePoints());
  }

  /// Files any unfiled points from the newest pending point batch into
  /// [_laterPointBoxes] under [batch].
  void _filePendingPointBoxes(int batch) {
    final pendingPaint = _pendingPointPaint;
    if (pendingPaint == null || _pointBoxFiledCount >= _pointCount) return;
    final pad = _pointPad(pendingPaint);
    final buf = _pointBuffer;
    for (int i = _pointBoxFiledCount; i < _pointCount; i += 2) {
      final px = buf[i], py = buf[i + 1];
      _laterPointBoxes.add(
        px - pad,
        py - pad,
        px + pad,
        py + pad,
        batch: batch,
      );
    }
    _pointBoxFiledCount = _pointCount;
  }

  /// Attempts to place `(x, y)` into an older open point batch for [paint]
  /// when clear of intervening batches, or parks the current pending batch
  /// behind a new one. Returns `true` if `(x, y)` was already appended to an
  /// older batch.
  bool _tryJoinOrParkPointBatch(double x, double y, Paint paint, bool alone) {
    if (_restingPointPaintChanges > 0) {
      _restingPointPaintChanges--;
      _flushPoints();
      return false;
    }
    final prevPaint = _pendingPointPaint!;
    if (!_mayReorderShapes || alone || _pointsAlone(prevPaint)) {
      _flushPoints();
      return false;
    }
    final newest = _openPointBatches.length;
    if (newest > 0) _filePendingPointBoxes(newest);

    final pad = _pointPad(paint);
    final left = x - pad;
    final top = y - pad;
    final right = x + pad;
    final bottom = y + pad;

    final older = _openPointBatchOfPaint[paint];
    if (older != null &&
        !_laterPointBoxes.overlaps(
          left,
          top,
          right,
          bottom,
          laterThan: older,
        )) {
      _openPointBatches[older].addPoint(x, y);
      if (older > 0) {
        _laterPointBoxes.add(left, top, right, bottom, batch: older);
      }
      _fruitlessPointOpenings = 0;
      return true;
    }

    if (++_fruitlessPointOpenings > _mostOpenCoordBatches) {
      _fruitlessPointOpenings = 0;
      _restingPointPaintChanges = _restingCoordPaintChangeCount;
      _flushPoints();
      return false;
    }
    if (newest + 1 >= _mostOpenCoordBatches) {
      _flushPoints();
      return false;
    }

    final parked = _takeCoordBatch(prevPaint, _pendingPointShadow);
    parked.addSlice(_pointBuffer, _pointCount);
    _openPointBatchOfPaint[prevPaint] = newest;
    _openPointBatches.add(parked);
    _pointCount = 0;
    _pointBoxFiledCount = 0;
    _pendingPointPaint = null;
    _pendingPointShadow = null;
    return false;
  }

  /// Append a line segment to the auto-batch buffer. Consecutive calls with
  /// the same [paint] reference coalesce into a single [MultiLineRenderItem]
  /// rendered with [Canvas.drawRawPoints]/[PointMode.lines]. Non-overlapping
  /// multi-colour lines also coalesce into open batches per paint.
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
    final opaque = paint.color.a == 1.0;
    final alone = _lineAlone(paint, opaque);
    _prepareGeometry(null, paint, alone: alone);
    paint = _foldStroke(paint)!;
    final transformedX1 = _foldX(x1, y1);
    final transformedX2 = _foldX(x2, y2);
    y1 = _foldY(x1, y1);
    y2 = _foldY(x2, y2);
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
    if (alone) {
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
    // A translucent line stays in the line buffer too: a translucent shape
    // batch only takes shapes that keep clear of each other.
    if (opaque &&
        _lineCount == 0 &&
        _openLineBatches.isEmpty &&
        _pendingTextEntries.isEmpty &&
        _pendingShapeHasContent &&
        identical(_pendingShapeStroke, paint) &&
        (_activeShadow == null || _pendingShapeFill == null)) {
      _addCircleRunToPath();
      _pendingShapePath!
        ..moveTo(x1, y1)
        ..lineTo(x2, y2);
      // The line strokes with the batch, after every fill — a later shape
      // drawn across it has to split off to cover it.
      if (_stacks(_pendingShapeFill, paint)) {
        _pendingShapeBoxes.add(x1, y1, x2, y2);
      } else if (_openBatches.isNotEmpty) {
        _keepsApart(_pendingShapeFill, paint); // sets the pad for this pair
        _keepNewestShapeBox(x1, y1, x2, y2);
      }
      return;
    }
    if (_pendingLinePaint != null && !identical(_pendingLinePaint, paint)) {
      if (_tryJoinOrParkLineBatch(x1, y1, x2, y2, paint, alone)) return;
    }
    _flushPoints();
    _flushShapes();
    _flushImages();
    _flushText();
    _pendingLinePaint = paint;
    _pendingLineShadow = _activeShadow;
    _ensureLineCapacity(_lineCount + 4);
    _lineBuffer[_lineCount++] = x1;
    _lineBuffer[_lineCount++] = y1;
    _lineBuffer[_lineCount++] = x2;
    _lineBuffer[_lineCount++] = y2;
  }

  /// Files any unfiled segments from the newest pending line batch into
  /// [_laterLineBoxes] under [batch].
  void _filePendingLineBoxes(int batch) {
    final pendingPaint = _pendingLinePaint;
    if (pendingPaint == null || _lineBoxFiledCount >= _lineCount) return;
    final pad = _linePad(pendingPaint);
    final buf = _lineBuffer;
    for (int i = _lineBoxFiledCount; i < _lineCount; i += 4) {
      final lx1 = buf[i], ly1 = buf[i + 1], lx2 = buf[i + 2], ly2 = buf[i + 3];
      _laterLineBoxes.add(
        math.min(lx1, lx2) - pad,
        math.min(ly1, ly2) - pad,
        math.max(lx1, lx2) + pad,
        math.max(ly1, ly2) + pad,
        batch: batch,
      );
    }
    _lineBoxFiledCount = _lineCount;
  }

  /// Attempts to place `(x1, y1)-(x2, y2)` into an older open line batch for
  /// [paint] when clear of intervening batches, or parks the current pending
  /// batch behind a new one.
  bool _tryJoinOrParkLineBatch(
    double x1,
    double y1,
    double x2,
    double y2,
    Paint paint,
    bool alone,
  ) {
    if (_restingLinePaintChanges > 0) {
      _restingLinePaintChanges--;
      _flushLines();
      return false;
    }
    final prevPaint = _pendingLinePaint!;
    if (!_mayReorderShapes ||
        alone ||
        _lineAlone(prevPaint, prevPaint.color.a == 1.0)) {
      _flushLines();
      return false;
    }
    final newest = _openLineBatches.length;
    if (newest > 0) _filePendingLineBoxes(newest);

    final pad = _linePad(paint);
    final left = math.min(x1, x2) - pad;
    final top = math.min(y1, y2) - pad;
    final right = math.max(x1, x2) + pad;
    final bottom = math.max(y1, y2) + pad;

    final older = _openLineBatchOfPaint[paint];
    if (older != null &&
        !_laterLineBoxes.overlaps(left, top, right, bottom, laterThan: older)) {
      _openLineBatches[older].addLine(x1, y1, x2, y2);
      if (older > 0) {
        _laterLineBoxes.add(left, top, right, bottom, batch: older);
      }
      _fruitlessLineOpenings = 0;
      return true;
    }

    if (++_fruitlessLineOpenings > _mostOpenCoordBatches) {
      _fruitlessLineOpenings = 0;
      _restingLinePaintChanges = _restingCoordPaintChangeCount;
      _flushLines();
      return false;
    }
    if (newest + 1 >= _mostOpenCoordBatches) {
      _flushLines();
      return false;
    }

    final parked = _takeCoordBatch(prevPaint, _pendingLineShadow);
    parked.addSlice(_lineBuffer, _lineCount);
    _openLineBatchOfPaint[prevPaint] = newest;
    _openLineBatches.add(parked);
    _lineCount = 0;
    _lineBoxFiledCount = 0;
    _pendingLinePaint = null;
    _pendingLineShadow = null;
    return false;
  }

  /// Append a rectangle (or rounded rectangle) to the pending shape path.
  ///
  /// Falls back to a per-shape [RectRenderItem] when the paint can't be
  /// safely merged (shader, filter, non-srcOver blend, or translucent and
  /// too close to a shape in the batch).
  void appendRect(Rect rect, RRect? rrect, Paint? fill, Paint? stroke) {
    _prepareGeometry(fill, stroke);
    if (_foldHasLinear) {
      if (fill == null && stroke == null) return;
      if (rrect == null) {
        stroke = _foldStroke(stroke);
        if (stroke == null) rect = _clockwise(rect);
        final oriented = !_backwards(rect);
        final path = _beginShape(
          fill,
          stroke,
          _wantsBox(fill, stroke, oriented) ? _foldBounds(rect) : null,
          oriented: oriented,
        );
        path.moveTo(_foldX(rect.left, rect.top), _foldY(rect.left, rect.top));
        path.lineTo(_foldX(rect.right, rect.top), _foldY(rect.right, rect.top));
        path.lineTo(
          _foldX(rect.right, rect.bottom),
          _foldY(rect.right, rect.bottom),
        );
        path.lineTo(
          _foldX(rect.left, rect.bottom),
          _foldY(rect.left, rect.bottom),
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
          mergesExactly: false,
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
        mergesExactly: false,
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
    appendCircleCoords(center.dx, center.dy, radius, fill, stroke);
  }

  /// Append a circle from raw coordinates without allocating an intermediate
  /// [Offset] on the batched fast path.
  void appendCircleCoords(
    double cx,
    double cy,
    double radius,
    Paint? fill,
    Paint? stroke,
  ) {
    _prepareGeometry(
      fill,
      stroke,
      alone: _drawnAlone(fill, stroke, circle: true),
    );
    if (_foldHasLinear) {
      if (fill == null && stroke == null) return;
      final px = _foldX(cx, cy);
      final py = _foldY(cx, cy);
      final r = radius * _foldScale;
      final oval = Rect.fromLTRB(px - r, py - r, px + r, py + r);
      final path = _beginShape(
        fill,
        _foldStroke(stroke),
        oval,
        mergesExactly: false,
        circleRadius: r,
      );
      if (_circleRunOpen && identical(path, _pendingShapePath)) {
        _keepRunCircle(px, py);
      } else {
        path.addOval(oval);
      }
      _pendingShapeHasContent = true;
      return;
    }
    if (_hasFoldOffset) {
      cx += _foldDx;
      cy += _foldDy;
    }
    if (_clipRecordingPath != null) {
      _clipRecordingPath!.addOval(
        Rect.fromLTRB(cx - radius, cy - radius, cx + radius, cy + radius),
      );
      return;
    }
    if (fill == null && stroke == null) return;
    if (_hasDash && stroke != null) {
      _emitDashed(
        Path()..addOval(
          Rect.fromLTRB(cx - radius, cy - radius, cx + radius, cy + radius),
        ),
        fill,
        stroke,
      );
      return;
    }
    if (_drawnAlone(fill, stroke, circle: true)) {
      final masked = _maskBlurredFill(fill, stroke);
      _addItem(
        CircleRenderItem(
          Offset(cx, cy),
          radius,
          masked ?? fill,
          stroke,
          shadow: _activeShadow,
        ),
        blurred: masked != null,
      );
      return;
    }
    final oval = Rect.fromLTRB(
      cx - radius,
      cy - radius,
      cx + radius,
      cy + radius,
    );
    final path = _beginShape(
      fill,
      stroke,
      oval,
      mergesExactly: false,
      circleRadius: radius,
    );
    if (_circleRunOpen && identical(path, _pendingShapePath)) {
      _keepRunCircle(cx, cy);
    } else {
      path.addOval(oval);
    }
    _pendingShapeHasContent = true;
  }

  /// Append an ellipse (oval) to the pending shape path.
  void appendEllipse(Rect rect, Paint? fill, Paint? stroke) {
    _prepareGeometry(fill, stroke);
    if (_foldHasLinear) {
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
        mergesExactly: false,
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
    _beginShape(
      fill,
      stroke,
      rect,
      oriented: !_backwards(rect),
      mergesExactly: false,
    ).addOval(rect);
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
    if (_foldHasLinear) {
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
    final alone = _drawnAlone(fill, stroke);
    _prepareGeometry(fill, stroke, alone: alone);
    if (_foldHasLinear) {
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
    if (alone) {
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
      _needsBox(fill, stroke, oriented) ? path.getBounds().shift(off) : null,
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
  void appendImage(
    ui.Image image,
    Rect src,
    Rect dst,
    BlendMode blendMode, {
    Color? tint,
    FilterQuality filterQuality = FilterQuality.medium,
    bool transparentBorder = false,
  }) {
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): image() ignored inside clip callback — a bitmap has no '
        'outline to build a mask from. Use rect() to mask the region the '
        'image occupies.',
      );
      return;
    }
    if (!_canAtlas(src, dst)) {
      if (_foldHasLinear) _materializeTransforms();
      final placed = _hasFoldOffset ? dst.shift(Offset(_foldDx, _foldDy)) : dst;
      _holdImage(image);
      _addItem(
        ImageRenderItem(
          image: image,
          src: src,
          dst: placed,
          blendMode: blendMode,
          shadow: _activeShadow,
          tint: tint,
          filterQuality: filterQuality,
        ),
      );
      return;
    }

    final placed = _foldHasLinear
        ? _foldBounds(dst)
        : (_hasFoldOffset ? dst.shift(Offset(_foldDx, _foldDy)) : dst);
    final ratio = dst.width / src.width;
    final scos = _foldA * ratio;
    final ssin = _foldB * ratio;
    final tx = _foldX(dst.left, dst.top);
    final ty = _foldY(dst.left, dst.top);
    final hasRot = _foldB != 0 && !transparentBorder;

    if (_pendingAtlasImage != null &&
        (!identical(_pendingAtlasImage, image) ||
            _pendingAtlasBlend != blendMode ||
            _pendingAtlasFilterQuality != filterQuality)) {
      if (_tryJoinOrParkImageBatch(
        image,
        src,
        dst,
        placed,
        blendMode,
        tint,
        filterQuality,
        scos,
        ssin,
        tx,
        ty,
        hasRot,
      )) {
        return;
      }
    }
    _flushPoints();
    _flushLines();
    _flushShapes();
    _flushText();

    // A new run holds its bitmap once; sprites joining it ride on that hold.
    if (_pendingAtlasImage == null) _holdImage(image);
    _pendingAtlasImage = image;
    _pendingAtlasBlend = blendMode;
    _pendingAtlasFilterQuality = filterQuality;
    _ensureAtlasCapacity(_atlasCount + 1);
    final i = _atlasCount * 4;
    _atlasTransforms[i] = scos;
    _atlasTransforms[i + 1] = ssin;
    if (hasRot) _atlasHasRotation = true;
    _atlasTransforms[i + 2] = tx;
    _atlasTransforms[i + 3] = ty;
    _atlasRects[i] = src.left;
    _atlasRects[i + 1] = src.top;
    _atlasRects[i + 2] = src.right;
    _atlasRects[i + 3] = src.bottom;
    if (tint != null || _atlasHasTint) {
      _ensureAtlasColorCapacity(_atlasCount + 1);
      if (!_atlasHasTint) {
        _atlasColors.fillRange(0, _atlasCount, 0xFFFFFFFF);
        _atlasHasTint = true;
      }
      _atlasColors[_atlasCount] = tint?.toARGB32() ?? 0xFFFFFFFF;
    }
    if (_openImageBatches.isNotEmpty) {
      _keepNewestAtlasBox(placed);
    }
    if (_atlasCount == 0) {
      _atlasFirstSrc = src;
      _atlasFirstDst = _foldHasLinear ? dst : placed;
      _atlasFirstFold = _foldHasLinear ? _snapshotFold() : null;
      _atlasFirstTint = tint;
      _atlasBounds = placed;
    } else {
      _atlasBounds = _atlasBounds!.expandToInclude(placed);
    }
    _atlasCount++;
  }

  void _keepNewestAtlasBox(Rect placed) {
    final offset = _newestAtlasBoxCount * 4;
    if (offset == _newestAtlasBoxes.length) {
      _newestAtlasBoxes = Float64List(offset * 2)
        ..setRange(0, offset, _newestAtlasBoxes);
    }
    _newestAtlasBoxes[offset] =
        math.min(placed.left, placed.right) - _apartClearance;
    _newestAtlasBoxes[offset + 1] =
        math.min(placed.top, placed.bottom) - _apartClearance;
    _newestAtlasBoxes[offset + 2] =
        math.max(placed.left, placed.right) + _apartClearance;
    _newestAtlasBoxes[offset + 3] =
        math.max(placed.top, placed.bottom) + _apartClearance;
    _newestAtlasBoxCount++;
  }

  void _fileNewestAtlasBoxes(int batch) {
    final boxes = _newestAtlasBoxes;
    for (int o = 0, end = _newestAtlasBoxCount * 4; o < end; o += 4) {
      _laterImageBoxes.add(
        boxes[o],
        boxes[o + 1],
        boxes[o + 2],
        boxes[o + 3],
        batch: batch,
      );
    }
    _newestAtlasBoxCount = 0;
  }

  bool _tryJoinOrParkImageBatch(
    ui.Image image,
    Rect src,
    Rect dst,
    Rect placed,
    BlendMode blendMode,
    Color? tint,
    FilterQuality filterQuality,
    double scos,
    double ssin,
    double tx,
    double ty,
    bool hasRot,
  ) {
    if (_restingImageChanges > 0) {
      _restingImageChanges--;
      _flushImages();
      return false;
    }
    if (!_mayReorderShapes ||
        blendMode != BlendMode.srcOver ||
        _pendingAtlasBlend != BlendMode.srcOver) {
      _flushImages();
      return false;
    }
    final newest = _openImageBatches.length;
    if (newest > 0) _fileNewestAtlasBoxes(newest);

    final left = math.min(placed.left, placed.right) - _apartClearance;
    final top = math.min(placed.top, placed.bottom) - _apartClearance;
    final right = math.max(placed.left, placed.right) + _apartClearance;
    final bottom = math.max(placed.top, placed.bottom) + _apartClearance;

    final older = _openImageBatchOfImage[image];
    if (older != null &&
        _openImageBatches[older].filterQuality == filterQuality &&
        !_laterImageBoxes.overlaps(
          left,
          top,
          right,
          bottom,
          laterThan: older,
        )) {
      _openImageBatches[older].addSprite(
        scos,
        ssin,
        tx,
        ty,
        src,
        placed,
        hasRot,
        tint,
      );
      if (older > 0) {
        _laterImageBoxes.add(left, top, right, bottom, batch: older);
      }
      _fruitlessImageOpenings = 0;
      return true;
    }

    if (++_fruitlessImageOpenings > _mostOpenImageBatches) {
      _fruitlessImageOpenings = 0;
      _restingImageChanges = _restingImageChangeCount;
      _flushImages();
      return false;
    }
    if (newest + 1 >= _mostOpenImageBatches) {
      _flushImages();
      return false;
    }

    final prevImage = _pendingAtlasImage!;
    final parked = _takeImageBatch(
      image: prevImage,
      blendMode: _pendingAtlasBlend,
      filterQuality: _pendingAtlasFilterQuality,
      firstSrc: _atlasFirstSrc!,
      firstDst: _atlasFirstDst!,
      firstFold: _atlasFirstFold,
      firstTint: _atlasFirstTint,
      bounds: _atlasBounds!,
      hasRotation: _atlasHasRotation,
    );
    parked.addSlices(
      _atlasTransforms,
      _atlasRects,
      _atlasHasTint ? _atlasColors : null,
      _atlasCount,
    );
    _openImageBatchOfImage[prevImage] = newest;
    _openImageBatches.add(parked);
    _atlasCount = 0;
    _atlasHasRotation = false;
    _atlasHasTint = false;
    _atlasFirstTint = null;
    _pendingAtlasImage = null;
    _atlasBounds = null;
    _atlasFirstSrc = null;
    _atlasFirstDst = null;
    _atlasFirstFold = null;
    return false;
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

  /// Materializes open and pending image runs.
  ///
  /// A run of one keeps drawImageRect and its original double coordinates.
  /// Its folded transform, if any, is captured in an owned wrapper.
  void _flushImages() {
    _newestAtlasBoxCount = 0;
    if (_openImageBatches.isNotEmpty) {
      for (final batch in _openImageBatches) {
        if (batch.count == 1) {
          final item = ImageRenderItem(
            image: batch.image!,
            src: batch.firstSrc!,
            dst: batch.firstDst!,
            blendMode: batch.blendMode,
            tint: batch.firstTint,
            filterQuality: batch.filterQuality,
          );
          final fold = batch.firstFold;
          _items.add(
            fold == null ? item : _TransformedImageRenderItem(item, fold),
          );
        } else {
          final len = batch.count * 4;
          _items.add(
            ImageAtlasRenderItem(
              image: batch.image!,
              transforms: _allocArenaCopy(batch.transforms, len),
              preserveRotatedEdges: batch.hasRotation,
              rects: _allocArenaCopy(batch.rects, len),
              blendMode: batch.blendMode,
              colors: batch.hasTint
                  ? _allocIntArenaCopy(batch.colors, batch.count)
                  : null,
              filterQuality: batch.filterQuality,
              bounds: batch.bounds!,
            ),
          );
        }
      }
      _releaseImageBatches(_openImageBatches);
      _openImageBatchOfImage.clear();
      _laterImageBoxes.clear();
    }
    if (_atlasCount == 0) return;
    final image = _pendingAtlasImage!;
    if (_atlasCount == 1) {
      final item = ImageRenderItem(
        image: image,
        src: _atlasFirstSrc!,
        dst: _atlasFirstDst!,
        blendMode: _pendingAtlasBlend,
        tint: _atlasFirstTint,
        filterQuality: _pendingAtlasFilterQuality,
      );
      final fold = _atlasFirstFold;
      _items.add(fold == null ? item : _TransformedImageRenderItem(item, fold));
    } else {
      final len = _atlasCount * 4;
      _items.add(
        ImageAtlasRenderItem(
          image: image,
          transforms: _allocArenaCopy(_atlasTransforms, len),
          preserveRotatedEdges: _atlasHasRotation,
          rects: _allocArenaCopy(_atlasRects, len),
          blendMode: _pendingAtlasBlend,
          colors: _atlasHasTint
              ? _allocIntArenaCopy(_atlasColors, _atlasCount)
              : null,
          filterQuality: _pendingAtlasFilterQuality,
          bounds: _atlasBounds!,
        ),
      );
    }
    _atlasCount = 0;
    _atlasHasRotation = false;
    _atlasHasTint = false;
    _atlasFirstTint = null;
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
    _prepareGeometry(null, paint, points: true, alone: _pointsAlone(paint));
    paint = _foldStroke(paint)!;
    if (_pendingPointPaint != null && !identical(_pendingPointPaint, paint)) {
      _flushPoints();
    }
    _flushLines();
    _flushShapes();
    _flushImages();
    _flushText();
    _pendingPointPaint = paint;
    _pendingPointShadow = _activeShadow;
    _ensurePointCapacity(_pointCount + coords.length);
    if (!_foldIsIdentity) {
      for (int i = 0; i + 1 < coords.length; i += 2) {
        _pointBuffer[_pointCount++] = _foldX(coords[i], coords[i + 1]);
        _pointBuffer[_pointCount++] = _foldY(coords[i], coords[i + 1]);
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

  static const int _unitCircleCacheLimit = 64;
  static final List<Float64List?> _unitCircleCos = List.filled(
    _unitCircleCacheLimit + 1,
    null,
  );
  static final List<Float64List?> _unitCircleSin = List.filled(
    _unitCircleCacheLimit + 1,
    null,
  );

  static (Float64List, Float64List) _unitCircleTable(int n) {
    var cosTab = _unitCircleCos[n];
    var sinTab = _unitCircleSin[n];
    if (cosTab != null && sinTab != null) return (cosTab, sinTab);
    cosTab = Float64List(n);
    sinTab = Float64List(n);
    const start = -math.pi / 2;
    final step = 2 * math.pi / n;
    cosTab[0] = 0.0;
    sinTab[0] = -1.0;
    for (int i = 1; i < n; i++) {
      final a = start + i * step;
      cosTab[i] = math.cos(a);
      sinTab[i] = math.sin(a);
    }
    _unitCircleCos[n] = cosTab;
    _unitCircleSin[n] = sinTab;
    return (cosTab, sinTab);
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
    _polyXs[0] = cx;
    _polyYs[0] = cy - radius;
    if (sides <= _unitCircleCacheLimit) {
      final (cosTab, sinTab) = _unitCircleTable(sides);
      for (int i = 1; i < sides; i++) {
        _polyXs[i] = cx + radius * cosTab[i];
        _polyYs[i] = cy + radius * sinTab[i];
      }
    } else {
      const start = -math.pi / 2;
      final step = 2 * math.pi / sides;
      for (int i = 1; i < sides; i++) {
        final a = start + i * step;
        _polyXs[i] = cx + radius * math.cos(a);
        _polyYs[i] = cy + radius * math.sin(a);
      }
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
    _polyXs[0] = cx;
    _polyYs[0] = cy - outerRadius;
    if (n <= _unitCircleCacheLimit) {
      final (cosTab, sinTab) = _unitCircleTable(n);
      for (int i = 1; i < n; i++) {
        final r = i.isEven ? outerRadius : innerRadius;
        _polyXs[i] = cx + r * cosTab[i];
        _polyYs[i] = cy + r * sinTab[i];
      }
    } else {
      const start = -math.pi / 2;
      final step = math.pi / points;
      for (int i = 1; i < n; i++) {
        final r = i.isEven ? outerRadius : innerRadius;
        final a = start + i * step;
        _polyXs[i] = cx + r * math.cos(a);
        _polyYs[i] = cy + r * math.sin(a);
      }
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
    final alone = _drawnAlone(fill, stroke);
    _prepareGeometry(fill, stroke, alone: alone);
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
    if (alone) {
      final p = _takeBatchPath();
      _addPolyTo(p, n);
      final masked = _maskBlurredFill(fill, stroke);
      _addItem(
        PathRenderItem(p, masked ?? fill, stroke, shadow: _activeShadow),
        blurred: masked != null,
      );
      return;
    }
    // Winding only matters to a fill, and not at all to a stacking or
    // translucent batch, which keeps every shape off every other anyway.
    if (fill != null && !_stacks(fill, stroke) && !_keepsApart(fill, stroke)) {
      turn ??= _polyTurn(n);
    }
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
    final xs = _polyXs, ys = _polyYs;
    if (_foldIsIdentity) {
      for (int i = 0; i < n; i++) {
        final x = xs[i], y = ys[i];
        if (x < l) l = x;
        if (x > r) r = x;
        if (y < t) t = y;
        if (y > b) b = y;
      }
    } else if (!_foldHasLinear) {
      final dx = _foldDx, dy = _foldDy;
      for (int i = 0; i < n; i++) {
        final x = xs[i] + dx, y = ys[i] + dy;
        if (x < l) l = x;
        if (x > r) r = x;
        if (y < t) t = y;
        if (y > b) b = y;
      }
    } else {
      for (int i = 0; i < n; i++) {
        final x = _foldX(xs[i], ys[i]);
        final y = _foldY(xs[i], ys[i]);
        if (x < l) l = x;
        if (x > r) r = x;
        if (y < t) t = y;
        if (y > b) b = y;
      }
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  void _addPolyTo(Path p, int n, {bool reversed = false}) {
    final xs = _polyXs, ys = _polyYs;
    if (_foldIsIdentity) {
      if (reversed) {
        final last = n - 1;
        p.moveTo(xs[last], ys[last]);
        for (int i = last - 1; i >= 0; i--) {
          p.lineTo(xs[i], ys[i]);
        }
      } else {
        p.moveTo(xs[0], ys[0]);
        for (int i = 1; i < n; i++) {
          p.lineTo(xs[i], ys[i]);
        }
      }
      p.close();
      return;
    }
    if (!_foldHasLinear) {
      final dx = _foldDx, dy = _foldDy;
      if (reversed) {
        final last = n - 1;
        p.moveTo(xs[last] + dx, ys[last] + dy);
        for (int i = last - 1; i >= 0; i--) {
          p.lineTo(xs[i] + dx, ys[i] + dy);
        }
      } else {
        p.moveTo(xs[0] + dx, ys[0] + dy);
        for (int i = 1; i < n; i++) {
          p.lineTo(xs[i] + dx, ys[i] + dy);
        }
      }
      p.close();
      return;
    }
    if (reversed) {
      final last = n - 1;
      p.moveTo(_foldX(xs[last], ys[last]), _foldY(xs[last], ys[last]));
      for (int i = last - 1; i >= 0; i--) {
        p.lineTo(_foldX(xs[i], ys[i]), _foldY(xs[i], ys[i]));
      }
      p.close();
      return;
    }
    p.moveTo(_foldX(xs[0], ys[0]), _foldY(xs[0], ys[0]));
    for (int i = 1; i < n; i++) {
      p.lineTo(_foldX(xs[i], ys[i]), _foldY(xs[i], ys[i]));
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
  ///
  /// The items are this frame's: [clear] takes the batches' paths back to
  /// draw the next frame with, so an item must not be drawn after it.
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

  /// Appends a dynamic text draw. Consecutive plain solid-colour calls —
  /// across different strings, colours, sizes, translations, rotations, and
  /// uniform scales — coalesce into a single [TextDynamicBatchRenderItem]
  /// drawn via `Canvas.drawRawAtlas`. Pure translations are also folded for
  /// non-batched dynamic text without materializing canvas transforms.
  void appendTextDynamic({
    required String text,
    required double x,
    required double y,
    double? maxWidth,
    double? maxHeight,
    required String fontFamily,
    required double fontSize,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    required TextAlign textAlign,
    required double? textLeading,
    double? letterSpacing,
    Paint? fillPaint,
    Paint? strokePaint,
    Gradient? fillGradient,
    Gradient? strokeGradient,
    List<FontVariation>? fontVariations,
    String fontVariationKey = '',
  }) {
    if (text.isEmpty) return;

    final singlePassStroke = strokePaint != null && fillPaint == null;
    final dualPass = fillPaint != null && strokePaint != null;
    final canBatch =
        (fillPaint != null || strokePaint != null) &&
        _blurLayer == null &&
        maxHeight == null &&
        fillGradient == null &&
        strokeGradient == null &&
        (fillPaint == null || _plainPaint(fillPaint)) &&
        (strokePaint == null || _plainPaint(strokePaint));

    if (canBatch) {
      _flushPoints();
      _flushLines();
      _flushImages();
      if (_pendingShapeHasContent && _textMayCrossShapes) {
        _textCrossedShapes = true;
      } else {
        _flushShapes();
      }
      _pendingTextEntries.add(
        Flut5TextDynamicEntry(
          text: text,
          x: x,
          y: y,
          maxWidth: maxWidth,
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          textAlign: textAlign,
          textLeading: textLeading,
          letterSpacing: letterSpacing,
          color: singlePassStroke ? strokePaint.color : fillPaint!.color,
          paintingStyle: singlePassStroke ? 1 : 0,
          strokeWidth: (singlePassStroke || dualPass)
              ? strokePaint.strokeWidth
              : 0.0,
          strokeColor: dualPass ? strokePaint.color : null,
          foldA: _foldA,
          foldB: _foldB,
          foldDx: _foldDx,
          foldDy: _foldDy,
          foldScale: _foldScale,
          shadow: _activeShadow,
          fontVariations: fontVariations,
          fontVariationKey: fontVariationKey,
        ),
      );
      return;
    }

    final hasCanvasShader =
        fillPaint?.shader != null || strokePaint?.shader != null;
    if (!_foldHasLinear && !hasCanvasShader) {
      _addItem(
        TextDynamicRenderItem(
          text: text,
          x: x + _foldDx,
          y: y + _foldDy,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          textAlign: textAlign,
          textLeading: textLeading,
          letterSpacing: letterSpacing,
          fillPaint: fillPaint,
          strokePaint: strokePaint,
          fillGradient: fillGradient,
          strokeGradient: strokeGradient,
          shadow: _activeShadow,
          fontVariations: fontVariations,
          fontVariationKey: fontVariationKey,
        ),
      );
      return;
    }

    _materializeTransforms();
    _addItem(
      TextDynamicRenderItem(
        text: text,
        x: x,
        y: y,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        fontFamily: fontFamily,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        textAlign: textAlign,
        textLeading: textLeading,
        letterSpacing: letterSpacing,
        fillPaint: fillPaint,
        strokePaint: strokePaint,
        fillGradient: fillGradient,
        strokeGradient: strokeGradient,
        shadow: _activeShadow,
        fontVariations: fontVariations,
        fontVariationKey: fontVariationKey,
      ),
    );
  }

  /// Appends a static text draw, folding pure 2D translations directly into
  /// `(x, y)` whenever no canvas-space shader is active so translated text
  /// emits zero `TransformRenderItem`s.
  void appendTextStatic({
    required String text,
    required double x,
    required double y,
    double? maxWidth,
    double? maxHeight,
    required String fontFamily,
    required double fontSize,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    required TextAlign textAlign,
    required double? textLeading,
    double? letterSpacing,
    Paint? fillPaint,
    Paint? strokePaint,
    Gradient? fillGradient,
    Gradient? strokeGradient,
    List<FontVariation>? fontVariations,
    String fontVariationKey = '',
  }) {
    final hasCanvasShader =
        fillPaint?.shader != null || strokePaint?.shader != null;
    if (!_foldHasLinear && !hasCanvasShader) {
      _addItem(
        TextRenderItem(
          text: text,
          x: x + _foldDx,
          y: y + _foldDy,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          textAlign: textAlign,
          textLeading: textLeading,
          letterSpacing: letterSpacing,
          fillPaint: fillPaint,
          strokePaint: strokePaint,
          fillGradient: fillGradient,
          strokeGradient: strokeGradient,
          shadow: _activeShadow,
          fontVariations: fontVariations,
          fontVariationKey: fontVariationKey,
        ),
      );
      return;
    }

    _materializeTransforms();
    _addItem(
      TextRenderItem(
        text: text,
        x: x,
        y: y,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        fontFamily: fontFamily,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        textAlign: textAlign,
        textLeading: textLeading,
        letterSpacing: letterSpacing,
        fillPaint: fillPaint,
        strokePaint: strokePaint,
        fillGradient: fillGradient,
        strokeGradient: strokeGradient,
        shadow: _activeShadow,
        fontVariations: fontVariations,
        fontVariationKey: fontVariationKey,
      ),
    );
  }

  /// Whether queued text may wait on top of the shape batches still open.
  /// Not while text sizes animate: finding where such text lands would take
  /// the per-glyph layout it otherwise skips ([Flut5TextCache.drawsNatively]).
  bool get _textMayCrossShapes =>
      _mayReorderShapes &&
      _restingTextCrossings == 0 &&
      !Flut5TextCache.instance.stylesAreAnimating;

  /// Makes way for a shape while text is queued. The text draws after every
  /// open shape batch, so this shape would go under it: it stays that way
  /// only if it lands on none of it, else the shapes and the text both go
  /// out first and the shape starts afresh on top.
  void _keepShapesBeneathText(
    Paint? fill,
    Paint? stroke,
    Rect? bounds,
    bool mergesExactly,
  ) {
    if (_restingTextCrossings > 0) _restingTextCrossings--;
    if (bounds == null || !_textMayCrossShapes) {
      _flushShapes();
      _flushText();
      return;
    }
    if (_landsOnPendingText(fill, stroke, bounds)) {
      if (++_fruitlessTextCrossings >= _fruitlessTextCrossingsLimit) {
        _fruitlessTextCrossings = 0;
        _restingTextCrossings = _restingTextCrossingCount;
      }
      _flushShapes();
      _flushText();
      return;
    }
    _fruitlessTextCrossings = math.max(
      0,
      _fruitlessTextCrossings - _clearCrossingCredit,
    );
    if (!_textCrossedShapes) return;
    _textCrossedShapes = false;
    // Shapes on either side of the text would have been separate paths.
    // Merging them is only invisible for shapes that rasterize the same in
    // a shared path, so the others keep theirs.
    if (!mergesExactly || !_pendingMergesExactly) _flushShapes();
  }

  bool _landsOnPendingText(Paint? fill, Paint? stroke, Rect bounds) {
    final entries = _pendingTextEntries;
    for (var i = _textBoxesFiled; i < entries.length; i++) {
      final box = entries[i].inkBounds();
      _pendingTextBoxes.add(box.left, box.top, box.right, box.bottom);
    }
    _textBoxesFiled = entries.length;
    _keepsApart(fill, stroke); // sets the pad for these paints
    final pad = _apartPad;
    return _pendingTextBoxes.overlaps(
      math.min(bounds.left, bounds.right) - pad,
      math.min(bounds.top, bounds.bottom) - pad,
      math.max(bounds.left, bounds.right) + pad,
      math.max(bounds.top, bounds.bottom) + pad,
    );
  }

  // The paints of the last label queued on its own. Queued paints are never
  // changed, so labels in one colour can share them — and, by sharing them, the
  // tint built from them.
  Paint? _lonePaint;
  Color? _lonePaintColor;
  int _lonePaintStyle = 0;
  double _lonePaintStrokeWidth = 0;
  Paint? _loneStrokePaint;
  Color? _loneStrokeColor;
  double _loneStrokeWidth = 0;

  Paint _lonePaintFor(Flut5TextDynamicEntry entry) {
    final kept = _lonePaint;
    if (kept != null &&
        entry.paintingStyle == _lonePaintStyle &&
        entry.strokeWidth == _lonePaintStrokeWidth &&
        entry.color == _lonePaintColor) {
      return kept;
    }
    _lonePaintColor = entry.color;
    _lonePaintStyle = entry.paintingStyle;
    _lonePaintStrokeWidth = entry.strokeWidth;
    return _lonePaint = Paint()
      ..color = entry.color
      ..style = entry.paintingStyle == 1
          ? PaintingStyle.stroke
          : PaintingStyle.fill
      ..strokeWidth = entry.strokeWidth;
  }

  Paint _loneStrokePaintFor(Color color, double strokeWidth) {
    final kept = _loneStrokePaint;
    if (kept != null &&
        strokeWidth == _loneStrokeWidth &&
        color == _loneStrokeColor) {
      return kept;
    }
    _loneStrokeColor = color;
    _loneStrokeWidth = strokeWidth;
    return _loneStrokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
  }

  void _flushText() {
    if (_pendingTextEntries.isEmpty) return;
    _pendingTextBoxes.clear();
    _textBoxesFiled = 0;
    if (_pendingTextEntries.length == 1) {
      final e = _pendingTextEntries.removeLast();
      if (e.foldA == 1.0 && e.foldB == 0.0) {
        final Paint? fillPaint;
        final Paint? strokePaint;
        if (e.strokeColor != null) {
          fillPaint = _lonePaintFor(e);
          strokePaint = _loneStrokePaintFor(e.strokeColor!, e.strokeWidth);
        } else {
          final paint = _lonePaintFor(e);
          fillPaint = e.paintingStyle == 0 ? paint : null;
          strokePaint = e.paintingStyle == 1 ? paint : null;
        }
        _items.add(
          TextDynamicRenderItem(
            text: e.text,
            x: e.x + e.foldDx,
            y: e.y + e.foldDy,
            maxWidth: e.maxWidth,
            fontFamily: e.fontFamily,
            fontSize: e.fontSize,
            fontWeight: e.fontWeight,
            fontStyle: e.fontStyle,
            textAlign: e.textAlign,
            textLeading: e.textLeading,
            letterSpacing: e.letterSpacing,
            fillPaint: fillPaint,
            strokePaint: strokePaint,
            shadow: e.shadow,
            fontVariations: e.fontVariations,
            fontVariationKey: e.fontVariationKey,
          ),
        );
        return;
      }
      _items.add(TextDynamicBatchRenderItem(<Flut5TextDynamicEntry>[e]));
      return;
    }
    _items.add(
      TextDynamicBatchRenderItem(
        List<Flut5TextDynamicEntry>.of(_pendingTextEntries, growable: false),
      ),
    );
    _pendingTextEntries.clear();
  }

  /// Forces pending batches (shapes/points/lines/images/text) to materialize
  /// as `Flut5RenderItem`s appended to the queue. Call before reading
  /// [items]/[itemCount] when you need an accurate snapshot.
  void flushPending() {
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    _flushText();
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

  // ── Scroll-container culling ──────────────────────────────────────────
  //
  // A scroll container shows a window onto content that can be far larger,
  // and everything outside the window is clipped away. [cullOutside] drops
  // those draws once the final scroll offset is known, which saves replaying
  // and rasterizing them. A batch is only dropped whole, so inside a scroll
  // container batches are also kept to about one window of content each: a
  // long list then becomes a few batches, of which one or two are visible.

  /// The largest batch extent inside the innermost scroll container, or `0`
  /// outside any. See [beginScrollContent].
  double _chunkWidth = 0;
  double _chunkHeight = 0;
  final List<(double, double)> _outerChunkSizes = [];

  // Box around every shape in the open batches, for [_limitBatchExtent].
  double _chunkLeft = double.infinity;
  double _chunkTop = double.infinity;
  double _chunkRight = double.negativeInfinity;
  double _chunkBottom = double.negativeInfinity;

  /// Whether every shape in the newest batch rasterizes the same in a path of
  /// its own as in a shared one, so the batch can be split without a change.
  bool _pendingMergesExactly = true;

  /// Called when a scroll container's content starts: keeps batches to about
  /// [viewWidth] × [viewHeight] until [endScrollContent].
  void beginScrollContent(double viewWidth, double viewHeight) {
    _outerChunkSizes.add((_chunkWidth, _chunkHeight));
    _chunkWidth = viewWidth > 1 ? viewWidth : 1;
    _chunkHeight = viewHeight > 1 ? viewHeight : 1;
    _resetBatchExtent();
  }

  /// Closes [beginScrollContent]. Call it with no shape batch open.
  void endScrollContent() {
    final (width, height) = _outerChunkSizes.removeLast();
    _chunkWidth = width;
    _chunkHeight = height;
    _resetBatchExtent();
  }

  void _resetBatchExtent() {
    _chunkLeft = double.infinity;
    _chunkTop = double.infinity;
    _chunkRight = double.negativeInfinity;
    _chunkBottom = double.negativeInfinity;
  }

  /// Closes the open batches when a shape at [bounds] would stretch them past
  /// the size [beginScrollContent] set — unless a split could show, which
  /// keeps circles and rounded rects in the one batch they'd share anyway.
  void _limitBatchExtent(Rect? bounds, bool mergesExactly) {
    if (bounds == null) return;
    final left = math.min(bounds.left, bounds.right);
    final top = math.min(bounds.top, bounds.bottom);
    final right = math.max(bounds.left, bounds.right);
    final bottom = math.max(bounds.top, bounds.bottom);
    if (_pendingShapeHasContent &&
        mergesExactly &&
        _pendingMergesExactly &&
        (math.max(right, _chunkRight) - math.min(left, _chunkLeft) >
                _chunkWidth ||
            math.max(bottom, _chunkBottom) - math.min(top, _chunkTop) >
                _chunkHeight)) {
      _flushShapes();
    }
    if (left < _chunkLeft) _chunkLeft = left;
    if (top < _chunkTop) _chunkTop = top;
    if (right > _chunkRight) _chunkRight = right;
    if (bottom > _chunkBottom) _chunkBottom = bottom;
  }

  /// Drops the items from [startIndex] on that can't show through [viewport]
  /// — a rect in the coordinates active at [startIndex], the content's clip.
  /// Call it with nothing pending. Text batches are filtered entry by entry.
  ///
  /// Items are kept when their extent isn't known, inside blur and pixelate
  /// scopes (whose content spreads), and when they aren't draws at all.
  void cullOutside(int startIndex, Rect viewport) {
    final items = _items;
    final paddedViewport = viewport.inflate(_cullPad);
    final stack = <Matrix4>[];
    final pushStarts = <int>[];
    final pushHasContent = <bool>[];
    Matrix4? current;
    var scopeDepth = 0;
    var kept = startIndex;
    for (var i = startIndex; i < items.length; i++) {
      final item = items[i];
      var survivor = item;
      if (item is TransformRenderItem) {
        current = _appliedTo(current, item, stack);
        if (scopeDepth == 0) {
          if (item.type == TransformType.push) {
            pushStarts.add(kept);
            pushHasContent.add(false);
            items[kept++] = item;
            continue;
          }
          if (item.type == TransformType.pop && pushStarts.isNotEmpty) {
            final pushAt = pushStarts.removeLast();
            final hasContent = pushHasContent.removeLast();
            if (!hasContent) {
              kept = pushAt;
              continue;
            }
            if (pushHasContent.isNotEmpty) {
              pushHasContent[pushHasContent.length - 1] = true;
            }
          }
        }
      } else if (item is PixelateBeginRenderItem ||
          item is BlurBeginRenderItem) {
        if (scopeDepth == 0 && pushHasContent.isNotEmpty) {
          pushHasContent[pushHasContent.length - 1] = true;
        }
        scopeDepth++;
      } else if (item is PixelateEndRenderItem || item is BlurEndRenderItem) {
        scopeDepth--;
      } else if (scopeDepth == 0 &&
          item is! ClipRenderItem &&
          item is! BackgroundRenderItem) {
        final visible = _inViewport(item, paddedViewport, current);
        if (visible == null) continue;
        survivor = visible;
        if (pushHasContent.isNotEmpty) {
          pushHasContent[pushHasContent.length - 1] = true;
        }
      } else if (item is BackgroundRenderItem &&
          scopeDepth == 0 &&
          pushHasContent.isNotEmpty) {
        pushHasContent[pushHasContent.length - 1] = true;
      }
      items[kept++] = survivor;
    }
    items.length = kept;
  }

  /// [item] if any of it can land in [paddedViewport], a narrowed batch if
  /// only some of its entries/sprites/points/lines can, or `null` when none can.
  Flut5RenderItem? _inViewport(
    Flut5RenderItem item,
    Rect paddedViewport,
    Matrix4? transform,
  ) {
    bool shows(Rect? paint) {
      if (paint == null) return true;
      final placed = transform == null
          ? paint
          : MatrixUtils.transformRect(transform, paint);
      return placed.overlaps(paddedViewport);
    }

    bool whollyInside(Rect? paint) {
      if (paint == null) return false;
      final placed = transform == null
          ? paint
          : MatrixUtils.transformRect(transform, paint);
      return placed.left >= paddedViewport.left &&
          placed.right <= paddedViewport.right &&
          placed.top >= paddedViewport.top &&
          placed.bottom <= paddedViewport.bottom;
    }

    if (item is TextDynamicBatchRenderItem) {
      final entries = item.entries;
      var showing = 0;
      final visible = <Flut5TextDynamicEntry>[];
      for (var i = 0; i < entries.length; i++) {
        if (shows(entries[i].inkBounds())) {
          visible.add(entries[i]);
          showing++;
        }
      }
      if (showing == 0) return null;
      return showing == entries.length
          ? item
          : TextDynamicBatchRenderItem(visible);
    }
    if (item is ImageAtlasRenderItem) {
      final box = item.bounds;
      if (box != null) {
        if (!shows(box)) return null;
        if (item.spriteCount <= 2 || whollyInside(box)) return item;
      }
      final t = item.transforms;
      final r = item.rects;
      final c = item.colors;
      final count = item.spriteCount;
      final keepIndices = <int>[];
      Rect? nextBounds;
      for (var s = 0; s < count; s++) {
        final o = s * 4;
        final scos = t[o];
        final ssin = t[o + 1];
        final tx = t[o + 2];
        final ty = t[o + 3];
        final sw = r[o + 2] - r[o];
        final sh = r[o + 3] - r[o + 1];
        final Rect spriteBox;
        if (ssin == 0.0) {
          final x1 = tx + scos * sw;
          final y1 = ty + scos * sh;
          spriteBox = Rect.fromLTRB(
            math.min(tx, x1),
            math.min(ty, y1),
            math.max(tx, x1),
            math.max(ty, y1),
          );
        } else {
          final ux = scos * sw, uy = ssin * sw;
          final vx = -ssin * sh, vy = scos * sh;
          final x1 = tx + ux, y1 = ty + uy;
          final x2 = tx + ux + vx, y2 = ty + uy + vy;
          final x3 = tx + vx, y3 = ty + vy;
          spriteBox = Rect.fromLTRB(
            math.min(math.min(tx, x1), math.min(x2, x3)),
            math.min(math.min(ty, y1), math.min(y2, y3)),
            math.max(math.max(tx, x1), math.max(x2, x3)),
            math.max(math.max(ty, y1), math.max(y2, y3)),
          );
        }
        if (shows(spriteBox)) {
          keepIndices.add(s);
          nextBounds = nextBounds == null
              ? spriteBox
              : nextBounds.expandToInclude(spriteBox);
        }
      }
      if (keepIndices.isEmpty) return null;
      if (keepIndices.length == count) return item;
      final keptCount = keepIndices.length;
      final outT = Float32List(keptCount * 4);
      final outR = Float32List(keptCount * 4);
      final outC = c == null ? null : Int32List(keptCount);
      for (var k = 0; k < keptCount; k++) {
        final srcIdx = keepIndices[k];
        final sOff = srcIdx * 4;
        final dOff = k * 4;
        outT[dOff] = t[sOff];
        outT[dOff + 1] = t[sOff + 1];
        outT[dOff + 2] = t[sOff + 2];
        outT[dOff + 3] = t[sOff + 3];
        outR[dOff] = r[sOff];
        outR[dOff + 1] = r[sOff + 1];
        outR[dOff + 2] = r[sOff + 2];
        outR[dOff + 3] = r[sOff + 3];
        if (outC != null) outC[k] = c![srcIdx];
      }
      return ImageAtlasRenderItem(
        image: item.image,
        transforms: outT,
        rects: outR,
        preserveRotatedEdges: item.preserveRotatedEdges,
        blendMode: item.blendMode,
        colors: outC,
        filterQuality: item.filterQuality,
        bounds: nextBounds!,
      );
    }
    if (item is MultiPointRenderItem) {
      final paintBox = flut5PaintBounds(item, 0);
      if (paintBox == null) return item;
      if (!shows(paintBox)) return null;
      final coords = item.coords;
      if (coords.length <= 2 || whollyInside(paintBox)) return item;
      final (offL, offT, offR, offB) = _coordReachOffsets(
        item.pointPaint,
        item.shadow,
      );
      final out = Float32List(coords.length);
      var outLen = 0;
      for (var idx = 0; idx + 1 < coords.length; idx += 2) {
        final px = coords[idx];
        final py = coords[idx + 1];
        if (shows(Rect.fromLTRB(px + offL, py + offT, px + offR, py + offB))) {
          out[outLen++] = px;
          out[outLen++] = py;
        }
      }
      if (outLen == 0) return null;
      if (outLen == coords.length) return item;
      return MultiPointRenderItem(
        _allocArenaCopy(out, outLen),
        item.pointPaint,
        shadow: item.shadow,
      );
    }
    if (item is MultiLineRenderItem) {
      final paintBox = flut5PaintBounds(item, 0);
      if (paintBox == null) return item;
      if (!shows(paintBox)) return null;
      final coords = item.coords;
      if (coords.length <= 4 || whollyInside(paintBox)) return item;
      final (offL, offT, offR, offB) = _coordReachOffsets(
        item.linePaint,
        item.shadow,
      );
      final out = Float32List(coords.length);
      var outLen = 0;
      for (var idx = 0; idx + 3 < coords.length; idx += 4) {
        final x1 = coords[idx];
        final y1 = coords[idx + 1];
        final x2 = coords[idx + 2];
        final y2 = coords[idx + 3];
        if (shows(
          Rect.fromLTRB(
            math.min(x1, x2) + offL,
            math.min(y1, y2) + offT,
            math.max(x1, x2) + offR,
            math.max(y1, y2) + offB,
          ),
        )) {
          out[outLen++] = x1;
          out[outLen++] = y1;
          out[outLen++] = x2;
          out[outLen++] = y2;
        }
      }
      if (outLen == 0) return null;
      if (outLen == coords.length) return item;
      return MultiLineRenderItem(
        _allocArenaCopy(out, outLen),
        item.linePaint,
        shadow: item.shadow,
      );
    }
    return shows(flut5PaintBounds(item, 0)) ? item : null;
  }

  static (double, double, double, double) _coordReachOffsets(
    Paint stroke,
    Flut5ShadowSpec? shadow,
  ) {
    final reach = flut5StrokeReach(stroke, stroke.strokeWidth);
    if (shadow == null) return (-reach, -reach, reach, reach);
    final spreadReach = flut5StrokeReach(
      stroke,
      stroke.strokeWidth + shadow.spread * 2,
    );
    final halo = shadow.blur > 0
        ? 3 * Shadow.convertRadiusToSigma(shadow.blur)
        : 0.0;
    final totalShadow = spreadReach + halo;
    return (
      math.min(-reach, shadow.offset.dx - totalShadow),
      math.min(-reach, shadow.offset.dy - totalShadow),
      math.max(reach, shadow.offset.dx + totalShadow),
      math.max(reach, shadow.offset.dy + totalShadow),
    );
  }

  /// Anti-aliasing margin for [cullOutside], in logical pixels.
  static const double _cullPad = 2;

  /// The matrix after [item], keeping saved states in [stack]; `null` is the
  /// identity.
  static Matrix4? _appliedTo(
    Matrix4? current,
    TransformRenderItem item,
    List<Matrix4> stack,
  ) {
    switch (item.type) {
      case TransformType.push:
        stack.add(current?.clone() ?? Matrix4.identity());
        return current;
      case TransformType.pop:
        return stack.isEmpty ? current : stack.removeLast();
      case TransformType.translate:
        return (current ?? Matrix4.identity())
          ..translateByDouble(item.dx!, item.dy!, 0, 1);
      case TransformType.scale:
        return (current ?? Matrix4.identity())
          ..scaleByDouble(item.scaleX!, item.scaleY!, 1, 1);
      case TransformType.rotate:
        return (current ?? Matrix4.identity())..rotateZ(item.rotation!);
      case TransformType.matrix:
        return (current ?? Matrix4.identity())
          ..multiply(Matrix4.fromFloat64List(item.matrix!));
    }
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
    _flushText();
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
      _items.add(BlurRenderItem([item], layer, sigma: _blurSigma));
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
    _flushText();
    _items.add(BlurRenderItem(items, layer, sigma: _blurSigma));
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
    _flushText();
    final baseline = canvas.getSaveCount();
    Flut5GlyphGrid.beginReplay(canvas);
    if (_hasPixelate) {
      _replayPixelated(canvas, skipBackgrounds: false);
    } else {
      for (final item in _items) {
        Flut5GlyphGrid.beforeItem(item.keepsCanvasTransform);
        item.execute(canvas);
      }
    }
    Flut5GlyphGrid.endReplay();
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
    _flushText();
    final baseline = canvas.getSaveCount();
    Flut5GlyphGrid.beginReplay(canvas);
    if (_hasPixelate) {
      _replayPixelated(canvas, skipBackgrounds: true);
    } else {
      for (final item in _items) {
        if (item is BackgroundRenderItem) continue;
        Flut5GlyphGrid.beforeItem(item.keepsCanvasTransform);
        item.execute(canvas);
      }
    }
    Flut5GlyphGrid.endReplay();
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
    for (var index = 0; index < _items.length; index++) {
      final item = _items[index];
      if (item is PixelateBeginRenderItem) {
        final pass = _PixelatePass(
          item,
          target,
          passes.isEmpty ? base : passes.last.logical,
          _palettes,
          contentBounds: _scopeContentBounds(index),
        );
        passes.add(pass);
        target = pass.canvas;
      } else if (item is PixelateEndRenderItem) {
        if (passes.isNotEmpty) target = passes.removeLast().end();
      } else if (!skipBackgrounds || item is! BackgroundRenderItem) {
        Flut5GlyphGrid.pixelating = passes.isNotEmpty;
        Flut5GlyphGrid.beforeItem(item.keepsCanvasTransform);
        item.execute(target);
      }
    }
  }

  /// What the pixelate scope opened at [beginIndex] paints, in the coordinates
  /// active at its marker, so its pass can cover just those blocks. `null`
  /// when that can't be told: it holds a background, a nested scope (whose
  /// blocks or blur spread past their content), or a paint of unknown extent.
  Rect? _scopeContentBounds(int beginIndex) {
    final stack = <Matrix4>[];
    Matrix4? current;
    Rect? painted;
    for (var i = beginIndex + 1; i < _items.length; i++) {
      final item = _items[i];
      if (item is PixelateEndRenderItem) return painted ?? Rect.zero;
      if (item is TransformRenderItem) {
        current = _appliedTo(current, item, stack);
      } else if (item is! ClipRenderItem) {
        final bounds = item is BackgroundRenderItem
            ? null
            : flut5PaintBounds(item, _cullPad);
        if (bounds == null) return null;
        final placed = current == null
            ? bounds
            : MatrixUtils.transformRect(current, bounds);
        painted = painted == null ? placed : painted.expandToInclude(placed);
      }
    }
    return null;
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
  /// kept alive, and the batches' paths are kept for the next frame to reuse.
  void clear() {
    _items.clear();
    ImageAtlasRenderItem.noteFrameEnded();
    Flut5ImageShadows.noteFrameEnded();
    if (_heldImages.isNotEmpty) {
      for (final image in _heldImages) {
        Flut5ImageHandles.release(image);
      }
      _heldImages.clear();
    }
    _releaseBatchPaths();
    _pointCount = 0;
    _pointBoxFiledCount = 0;
    _pendingPointPaint = null;
    _pendingPointShadow = null;
    _releaseCoordBatches(_openPointBatches);
    _openPointBatchOfPaint.clear();
    _laterPointBoxes.clear();
    _lineCount = 0;
    _lineBoxFiledCount = 0;
    _pendingLinePaint = null;
    _pendingLineShadow = null;
    _releaseCoordBatches(_openLineBatches);
    _openLineBatchOfPaint.clear();
    _laterLineBoxes.clear();
    _pendingShapePath = null;
    _pendingShapeFill = null;
    _pendingShapeStroke = null;
    _pendingShapeHasContent = false;
    _pendingShapeShadow = null;
    _circleRunOpen = false;
    _circleRunLength = 0;
    _pendingShapeBoxes.clear();
    _pendingShapeTracked = false;
    _pendingMergesExactly = true;
    _chunkWidth = 0;
    _chunkHeight = 0;
    _outerChunkSizes.clear();
    _resetBatchExtent();
    _openBatches.clear();
    _openBatchOfPaint.clear();
    _laterShapeBoxes.clear();
    _newestShapeBoxCount = 0;
    _newestStaysOpen = false;
    // Atlas run: drop the sprites but keep the Float32List backing buffers,
    // same bargain as the point/line buffers above.
    _atlasCount = 0;
    _atlasHasRotation = false;
    _atlasHasTint = false;
    _atlasFirstTint = null;
    _pendingAtlasImage = null;
    _atlasBounds = null;
    _atlasFirstSrc = null;
    _atlasFirstDst = null;
    _atlasFirstFold = null;
    _releaseImageBatches(_openImageBatches);
    _openImageBatchOfImage.clear();
    _laterImageBoxes.clear();
    _newestAtlasBoxCount = 0;
    _pendingTextEntries.clear();
    _pendingTextBoxes.clear();
    _textBoxesFiled = 0;
    _textCrossedShapes = false;
    _clipRecordingPath = null;
    // Fold state is per-frame — the canvas transform resets with the frame.
    _foldA = 1.0;
    _foldB = 0.0;
    _foldDx = 0.0;
    _foldDy = 0.0;
    _foldScale = 1.0;
    _foldDepth = 0;
    _unmaterializedFolds = 0;
    _canvasLinear = false;
    // Drop the frame arena references so retained items remain immutable.
    _lastFrameArenaFloats = _frameArenaTotal;
    _frameArena = null;
    _frameArenaOffset = 0;
    _frameArenaTotal = 0;
    _lastIntFrameArena = _intFrameArenaTotal;
    _intFrameArena = null;
    _intFrameArenaOffset = 0;
    _intFrameArenaTotal = 0;
    _lastBackground = null;
    _hasOpaqueFullCanvasBg = false;
    _scopes.clear();
    _pixelateScopes = 0;
    _hasPixelate = false;
    _palettes.endFrame();
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

  /// Half the clearance, in logical pixels, kept between the drawn extents
  /// of shapes in a translucent batch ([_keepsApart]).
  ///
  /// Measured on Impeller (Metal): translucent polygons two device pixels
  /// apart render identically merged into one path and drawn one by one;
  /// one pixel apart, shared edge pixels move by up to 4 levels. Three
  /// logical pixels keep two device pixels down to a 0.67 trail capture
  /// scale.
  static const double _apartClearance = 1.5;

  // One-entry memo for [_keepsApart], on paint identity like [_stacks].
  Paint? _apartFill;
  Paint? _apartStroke;
  bool _apartResult = false;
  double _apartPad = 0;

  /// True when shapes painted with [fill]/[stroke] may only share a batch
  /// with shapes they keep clear of — a translucent paint, which blends
  /// twice where two shapes drawn one by one overlap and once where a
  /// single path covers both. Clear means not sharing a device pixel, edge
  /// anti-aliasing included: such a batch files every shape's box grown by
  /// its stroke's reach and [_apartClearance], and closes as soon as a new
  /// one lands on any of them.
  bool _keepsApart(Paint? fill, Paint? stroke) {
    if (!identical(fill, _apartFill) || !identical(stroke, _apartStroke)) {
      _apartFill = fill;
      _apartStroke = stroke;
      _apartResult =
          (fill != null && fill.color.a != 1.0) ||
          (stroke != null && stroke.color.a != 1.0);
      var pad = _apartClearance;
      if (stroke != null) {
        // How far the stroke reaches past the outline: half its width, out
        // to a miter's tip at sharp corners or a square cap's corner.
        final reach = stroke.strokeJoin == StrokeJoin.miter
            ? math.max(stroke.strokeMiterLimit, math.sqrt2)
            : math.sqrt2;
        pad += stroke.strokeWidth / 2 * reach;
      }
      _apartPad = pad;
    }
    return _apartResult;
  }

  /// True when [_beginShape] has to read the box of a shape painted with
  /// [fill]/[stroke] to batch it correctly.
  bool _needsBox(Paint? fill, Paint? stroke, bool oriented) =>
      _chunkWidth > 0 ||
      _pendingTextEntries.isNotEmpty ||
      _pendingShapeTracked ||
      (fill != null && !oriented) ||
      _stacks(fill, stroke) ||
      _keepsApart(fill, stroke);

  /// True when [_beginShape] will read the box of a shape painted with
  /// [fill]/[stroke], so callers that would have to work it out can skip
  /// it otherwise. Besides [_needsBox], that is whenever several batches
  /// are open, or this shape's change of paint may open another.
  bool _wantsBox(Paint? fill, Paint? stroke, bool oriented) =>
      _needsBox(fill, stroke, oriented) ||
      _openBatches.isNotEmpty ||
      (_pendingShapePath != null &&
          _newestStaysOpen &&
          _restingPaintChanges == 0 &&
          (!identical(fill, _pendingShapeFill) ||
              !identical(stroke, _pendingShapeStroke)));

  /// Opens (or continues) the shape batch for [fill]/[stroke] and returns its
  /// path. Besides a change of paint, two things close the open batch, both
  /// because one path is not its shapes drawn one by one:
  ///
  /// * [_stacks] holds and the new shape lands on any shape in the batch —
  ///   its fill has to cover their outlines.
  /// * the new shape, or one it lands on, is filled and not [oriented] — its
  ///   contours may wind counter-clockwise, and opposite windings cancel into
  ///   a hole where they overlap. Shapes that all wind clockwise only add up.
  /// * the paint is translucent ([_keepsApart]) and the new shape comes
  ///   within the clearance of any shape in the batch.
  ///
  /// [bounds] is the box of the geometry about to be added, in queue space
  /// and without stroke width; it is only read when [_wantsBox] holds, so
  /// callers that would have to compute it may pass `null` otherwise.
  ///
  /// The unstroked box is enough: the part of an earlier outline that reaches
  /// into a shape it merely touches lies under that shape's own outline.
  ///
  /// [mergesExactly] is whether the shape rasterizes the same in a path
  /// shared with other shapes as in a path of its own — true of everything
  /// but circles, ellipses and rounded rects. Only such shapes go back into
  /// an older open batch, or share a batch that stays open; see the notes
  /// on [_openBatches].
  ///
  /// A change of paint does not always open a new batch: the path returned
  /// may be an older open batch's.
  ///
  /// [circleRadius] is set by circles, which may then be kept out of the
  /// path as a circle run: when [_circleRunOpen] holds afterwards and the
  /// path returned is the newest batch's, the caller keeps the circle with
  /// [_keepRunCircle] instead of adding it to the path. Any other shape
  /// joining the batch has the kept circles added to the path first.
  Path _beginShape(
    Paint? fill,
    Paint? stroke,
    Rect? bounds, {
    bool oriented = true,
    bool mergesExactly = true,
    double? circleRadius,
  }) {
    if (_pendingTextEntries.isNotEmpty) {
      _keepShapesBeneathText(fill, stroke, bounds, mergesExactly);
    }
    if (_chunkWidth > 0) _limitBatchExtent(bounds, mergesExactly);
    final stacks = _stacks(fill, stroke);
    final unwound = fill != null && !oriented;
    final apart = _keepsApart(fill, stroke);
    if (apart) {
      // Sorted first: a negative-size shape's box is inverted, and growing
      // an inverted box shrinks it.
      final b = bounds!;
      bounds = Rect.fromLTRB(
        math.min(b.left, b.right) - _apartPad,
        math.min(b.top, b.bottom) - _apartPad,
        math.max(b.left, b.right) + _apartPad,
        math.max(b.top, b.bottom) + _apartPad,
      );
    }
    // Nothing in its own batch that this shape has to be kept off.
    final plain = !stacks && !unwound && !apart;
    final reorders = mergesExactly || _reordersShapesWithOwnRenderer;
    if (_pendingShapePath != null) {
      final bool split;
      if (!identical(_pendingShapeFill, fill) ||
          !identical(_pendingShapeStroke, stroke)) {
        // Another colour: the shape goes back into an older open batch, or
        // the newest batch is left open or closed to make way for a new one.
        final olderBatch = _changeColourBatch(
          fill,
          stroke,
          bounds,
          plain && reorders,
        );
        if (olderBatch != null) return olderBatch;
        split = false;
      } else if (_pendingShapeTracked) {
        // A clockwise shape in a non-stacking batch only has the unwound
        // shapes to avoid; everything else has every shape to avoid.
        split = _pendingShapeBoxes.overlaps(
          bounds!.left,
          bounds.top,
          bounds.right,
          bounds.bottom,
          markedOnly: !stacks && !unwound && !apart,
        );
      } else {
        // The batch kept no boxes, so a shape that must be tested can't
        // join it. (A translucent batch always keeps them.)
        split = unwound;
      }
      if (split) _flushShapes();
    }
    if (_pendingShapePath == null) {
      _pendingShapeTracked = !plain;
      _pendingMergesExactly = mergesExactly;
      // The first open batch needs no boxes; a later one needs every one.
      _newestStaysOpen =
          plain &&
          reorders &&
          _mayReorderShapes &&
          // On the web a colour batch kept open spans the canvas, and each
          // one is a canvas-wide coverage mask — see [_webBatching].
          !_webBatching &&
          (_openBatches.isEmpty || bounds != null);
    } else {
      if (!mergesExactly) _pendingMergesExactly = false;
      if (!reorders) _newestStaysOpen = false;
    }
    if (_pendingShapeTracked) {
      _pendingShapeBoxes.add(
        bounds!.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
        marked: unwound,
      );
    } else if (_openBatches.isNotEmpty) {
      if (bounds != null) {
        _keepNewestShapeBox(
          bounds.left,
          bounds.top,
          bounds.right,
          bounds.bottom,
        );
      } else {
        _newestStaysOpen = false;
      }
    }
    _flushPoints();
    _flushLines();
    _flushImages();
    final opening = _pendingShapePath == null;
    final path = _pendingShapePath ??= _takeBatchPath();
    _pendingShapeFill = fill;
    _pendingShapeStroke = stroke;
    // Rides along on the batch — setShadowState flushes on change, so an open
    // batch always matches the current shadow.
    _pendingShapeShadow = _activeShadow;
    _continueCircleRun(opening, fill, stroke, circleRadius);
    return path;
  }

  /// Opens, extends or ends the newest batch's circle run for a shape that
  /// has just joined it — see the notes on [_circleRunOpen]. [radius] is the
  /// shape's when it is a circle, `null` otherwise.
  void _continueCircleRun(
    bool opening,
    Paint? fill,
    Paint? stroke,
    double? radius,
  ) {
    final runs =
        radius != null &&
        radius > 0 &&
        fill != null &&
        stroke == null &&
        fill.isAntiAlias &&
        _activeShadow == null &&
        _circlesAsPoints;
    if (opening) {
      _circleRunLength = 0;
      _circleRunOpen = runs;
      if (runs) _circleRunRadius = radius;
      return;
    }
    if (!_circleRunOpen || (runs && radius == _circleRunRadius)) return;
    _addCircleRunToPath();
  }

  /// Keeps one circle of the open run, centred on ([x], [y]).
  void _keepRunCircle(double x, double y) {
    if (_circleRunLength + 2 > _circleRun.length) {
      _circleRun = Float64List(_circleRun.length * 2)
        ..setRange(0, _circleRunLength, _circleRun);
    }
    _circleRun[_circleRunLength++] = x;
    _circleRun[_circleRunLength++] = y;
  }

  /// Ends the open circle run by adding its circles to the newest batch's
  /// path, in the order they were drawn — the path they would have been in
  /// all along.
  void _addCircleRunToPath() {
    if (!_circleRunOpen) return;
    _circleRunOpen = false;
    final path = _pendingShapePath;
    if (path != null) {
      final r = _circleRunRadius;
      final run = _circleRun;
      for (var i = 0; i < _circleRunLength; i += 2) {
        final x = run[i];
        final y = run[i + 1];
        path.addOval(Rect.fromLTRB(x - r, y - r, x + r, y + r));
      }
    }
    _circleRunLength = 0;
  }

  /// Queues the open circle run as one [CircleRunRenderItem].
  CircleRunRenderItem _takeCircleRun(Paint fill) {
    final length = _circleRunLength;
    if (_circleRunScratch.length < length) {
      _circleRunScratch = Float32List(_circleRun.length);
    }
    final scratch = _circleRunScratch;
    final run = _circleRun;
    for (var i = 0; i < length; i++) {
      scratch[i] = run[i];
    }
    final radius = _circleRunRadius;
    _circleRunOpen = false;
    _circleRunLength = 0;
    return CircleRunRenderItem(
      _allocArenaCopy(scratch, length),
      radius,
      _circleRunPaint(fill, radius),
    );
  }

  /// [fill] as a point paint for circles of [radius]: a round point
  /// `2 * radius` wide.
  Paint _circleRunPaint(Paint fill, double radius) {
    if (identical(fill, _circleRunPaintFill) &&
        radius == _circleRunPaintRadius) {
      return _circleRunPaintMemo!;
    }
    _circleRunPaintFill = fill;
    _circleRunPaintRadius = radius;
    return _circleRunPaintMemo = Paint()
      ..color = fill.color
      ..blendMode = fill.blendMode
      ..isAntiAlias = fill.isAntiAlias
      ..invertColors = fill.invertColors
      ..strokeWidth = radius * 2
      ..strokeCap = StrokeCap.round;
  }

  /// Makes way for a shape whose paints are not the newest batch's — see
  /// the notes on [_openBatches].
  ///
  /// Returns the path of the older open batch the shape goes back into,
  /// when one draws with its paints and the shape keeps clear of everything
  /// in the batches opened after that one. Otherwise returns `null` with the
  /// newest batch either left open, when it can be, or closed along with
  /// every other open batch — so the caller opens a new one.
  ///
  /// [bounds] is the shape's box and [reorders] whether the shape may be
  /// drawn out of order at all: it has nothing to keep off in its own batch
  /// and merges exactly. A shape that may not, or has no box, closes every
  /// open batch.
  Path? _changeColourBatch(
    Paint? fill,
    Paint? stroke,
    Rect? bounds,
    bool reorders,
  ) {
    if (_restingPaintChanges > 0) {
      _restingPaintChanges--;
      _flushShapes();
      return null;
    }
    if (!reorders || bounds == null || !_newestStaysOpen) {
      _flushShapes();
      return null;
    }

    // The newest batch's place among the open ones, once it joins them.
    final newest = _openBatches.length;
    _fileNewestShapeBoxes(newest);

    // [_keepsApart] has just set the pad for these paints.
    final pad = _apartPad;
    final left = math.min(bounds.left, bounds.right) - pad;
    final top = math.min(bounds.top, bounds.bottom) - pad;
    final right = math.max(bounds.left, bounds.right) + pad;
    final bottom = math.max(bounds.top, bounds.bottom) + pad;

    final older = _openBatchOfPaint[fill ?? stroke!];
    if (older != null) {
      final batch = _openBatches[older];
      if (identical(batch.fillPaint, fill) &&
          identical(batch.strokePaint, stroke) &&
          !_laterShapeBoxes.overlaps(
            left,
            top,
            right,
            bottom,
            laterThan: older,
          )) {
        if (older > 0) {
          _laterShapeBoxes.add(left, top, right, bottom, batch: older);
        }
        _fruitlessOpenings = 0;
        return batch.path;
      }
    }

    if (++_fruitlessOpenings > _fruitlessOpeningsLimit) {
      _fruitlessOpenings = 0;
      _restingPaintChanges = _restingPaintChangeCount;
      _flushShapes();
      return null;
    }
    if (newest + 1 >= _mostOpenBatches) {
      _flushShapes();
      return null;
    }

    // Leave the newest batch open, behind the one about to be opened.
    _addCircleRunToPath();
    _openBatchOfPaint[_pendingShapeFill ?? _pendingShapeStroke!] = newest;
    _openBatches.add(
      PathRenderItem(
        _pendingShapePath!,
        _pendingShapeFill,
        _pendingShapeStroke,
      ),
    );
    _pendingShapePath = null;
    _pendingShapeFill = null;
    _pendingShapeStroke = null;
    _pendingShapeHasContent = false;
    return null;
  }

  /// Writes down the box of a shape just added to the newest batch, grown
  /// by the pad [_keepsApart] last worked out — the batch's own paints.
  void _keepNewestShapeBox(double x1, double y1, double x2, double y2) {
    final offset = _newestShapeBoxCount * 4;
    if (offset == _newestShapeBoxes.length) {
      _newestShapeBoxes = Float64List(offset * 2)
        ..setRange(0, offset, _newestShapeBoxes);
    }
    final pad = _apartPad;
    final boxes = _newestShapeBoxes;
    boxes[offset] = math.min(x1, x2) - pad;
    boxes[offset + 1] = math.min(y1, y2) - pad;
    boxes[offset + 2] = math.max(x1, x2) + pad;
    boxes[offset + 3] = math.max(y1, y2) + pad;
    _newestShapeBoxCount++;
  }

  /// Files the boxes written down for the newest batch in
  /// [_laterShapeBoxes], under [batch] — its place among the open batches.
  void _fileNewestShapeBoxes(int batch) {
    final boxes = _newestShapeBoxes;
    for (int o = 0, end = _newestShapeBoxCount * 4; o < end; o += 4) {
      _laterShapeBoxes.add(
        boxes[o],
        boxes[o + 1],
        boxes[o + 2],
        boxes[o + 3],
        batch: batch,
      );
    }
    _newestShapeBoxCount = 0;
  }

  /// Queues every batch left open behind the newest, oldest first.
  void _closeOpenBatches() {
    _newestShapeBoxCount = 0;
    if (_openBatches.isEmpty) return;
    _items.addAll(_openBatches);
    _openBatches.clear();
    _openBatchOfPaint.clear();
    _laterShapeBoxes.clear();
  }

  void _flushPoints() {
    if (_openPointBatches.isNotEmpty) {
      for (final batch in _openPointBatches) {
        _items.add(
          MultiPointRenderItem(
            _allocArenaCopy(batch.coords, batch.count),
            batch.paint!,
            shadow: batch.shadow,
          ),
        );
      }
      _releaseCoordBatches(_openPointBatches);
      _openPointBatchOfPaint.clear();
      _laterPointBoxes.clear();
    }
    _pointBoxFiledCount = 0;
    if (_pointCount == 0) return;
    _items.add(_takePoints());
  }

  /// Closes the open point run and returns it as an item. The run must hold
  /// at least one point.
  MultiPointRenderItem _takePoints() {
    final item = MultiPointRenderItem(
      _allocArenaCopy(_pointBuffer, _pointCount),
      _pendingPointPaint!,
      shadow: _pendingPointShadow,
    );
    _pointCount = 0;
    _pointBoxFiledCount = 0;
    _pendingPointPaint = null;
    _pendingPointShadow = null;
    return item;
  }

  void _flushLines() {
    if (_openLineBatches.isNotEmpty) {
      for (final batch in _openLineBatches) {
        _items.add(
          MultiLineRenderItem(
            _allocArenaCopy(batch.coords, batch.count),
            batch.paint!,
            shadow: batch.shadow,
          ),
        );
      }
      _releaseCoordBatches(_openLineBatches);
      _openLineBatchOfPaint.clear();
      _laterLineBoxes.clear();
    }
    _lineBoxFiledCount = 0;
    if (_lineCount == 0) return;
    final snapshot = _allocArenaCopy(_lineBuffer, _lineCount);
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
    _textCrossedShapes = false;
    _closeOpenBatches();
    if (_chunkWidth > 0) _resetBatchExtent();
    _pendingShapeBoxes.clear();
    _pendingShapeTracked = false;
    _newestStaysOpen = false;
    if (!_pendingShapeHasContent) {
      _circleRunOpen = false;
      _circleRunLength = 0;
      _pendingShapePath = null;
      _pendingShapeFill = null;
      _pendingShapeStroke = null;
      _pendingShapeShadow = null;
      return;
    }
    if (_circleRunOpen && _circleRunLength > 0) {
      _items.add(_takeCircleRun(_pendingShapeFill!));
    } else {
      _addCircleRunToPath();
      _items.add(
        PathRenderItem(
          _pendingShapePath!,
          _pendingShapeFill,
          _pendingShapeStroke,
          shadow: _pendingShapeShadow,
        ),
      );
    }
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

/// Parked point or line batch kept open behind newer paint batches so
/// non-overlapping multi-colour points and lines coalesce into one draw call
/// per paint. Pooled across flushes so multi-colour point/line frames avoid
/// per-flush object and typed-array churn.
class _OpenCoordBatch() {
  Paint? paint;
  Flut5ShadowSpec? shadow;
  Float32List coords = Float32List(16);
  int count = 0;

  void reset(Paint paint, Flut5ShadowSpec? shadow) {
    this.paint = paint;
    this.shadow = shadow;
    count = 0;
  }

  void clearRefs() {
    paint = null;
    shadow = null;
    count = 0;
  }

  void _ensure(int needed) {
    if (coords.length >= needed) return;
    int len = coords.length * 2;
    while (len < needed) {
      len *= 2;
    }
    coords = Float32List(len)..setRange(0, count, coords);
  }

  void addSlice(Float32List src, int length) {
    _ensure(count + length);
    coords.setRange(count, count + length, src);
    count += length;
  }

  void addPoint(double x, double y) {
    _ensure(count + 2);
    coords[count++] = x;
    coords[count++] = y;
  }

  void addLine(double x1, double y1, double x2, double y2) {
    _ensure(count + 4);
    coords[count++] = x1;
    coords[count++] = y1;
    coords[count++] = x2;
    coords[count++] = y2;
  }
}

/// Parked image atlas batch kept open behind newer texture batches so
/// non-overlapping interleaved sprites of the same [ui.Image] coalesce.
/// Pooled across flushes; [clearRefs] drops image/fold/tint handles on return.
class _OpenImageBatch() {
  ui.Image? image;
  BlendMode blendMode = BlendMode.srcOver;
  FilterQuality filterQuality = FilterQuality.medium;
  Rect? firstSrc;
  Rect? firstDst;
  _FoldTransform? firstFold;
  Color? firstTint;
  Rect? bounds;
  bool hasRotation = false;
  Float32List transforms = Float32List(16);
  Float32List rects = Float32List(16);
  Int32List colors = Int32List(0);
  bool hasTint = false;
  int count = 0;

  void reset({
    required ui.Image image,
    required BlendMode blendMode,
    required FilterQuality filterQuality,
    required Rect firstSrc,
    required Rect firstDst,
    required _FoldTransform? firstFold,
    required Color? firstTint,
    required Rect bounds,
    required bool hasRotation,
  }) {
    this.image = image;
    this.blendMode = blendMode;
    this.filterQuality = filterQuality;
    this.firstSrc = firstSrc;
    this.firstDst = firstDst;
    this.firstFold = firstFold;
    this.firstTint = firstTint;
    this.bounds = bounds;
    this.hasRotation = hasRotation;
    hasTint = false;
    count = 0;
  }

  void clearRefs() {
    image = null;
    firstSrc = null;
    firstDst = null;
    firstFold = null;
    firstTint = null;
    bounds = null;
    hasRotation = false;
    hasTint = false;
    count = 0;
  }

  void _ensure(int sprites) {
    final needed = sprites * 4;
    if (transforms.length >= needed) return;
    int len = transforms.length * 2;
    while (len < needed) {
      len *= 2;
    }
    final used = count * 4;
    transforms = Float32List(len)..setRange(0, used, transforms);
    rects = Float32List(len)..setRange(0, used, rects);
  }

  void _ensureColors(int sprites) {
    if (colors.length >= sprites) return;
    int len = colors.isEmpty ? 8 : colors.length * 2;
    while (len < sprites) {
      len *= 2;
    }
    final next = Int32List(len);
    if (hasTint && count > 0) {
      next.setRange(0, count, colors);
    }
    colors = next;
  }

  void addSlices(
    Float32List srcTransforms,
    Float32List srcRects,
    Int32List? srcColors,
    int sprites,
  ) {
    _ensure(count + sprites);
    final used = count * 4;
    final len = sprites * 4;
    transforms.setRange(used, used + len, srcTransforms);
    rects.setRange(used, used + len, srcRects);
    if (srcColors != null) {
      _ensureColors(count + sprites);
      if (!hasTint) {
        colors.fillRange(0, count, 0xFFFFFFFF);
        hasTint = true;
      }
      colors.setRange(count, count + sprites, srcColors);
    } else if (hasTint) {
      _ensureColors(count + sprites);
      colors.fillRange(count, count + sprites, 0xFFFFFFFF);
    }
    count += sprites;
  }

  void addSprite(
    double scos,
    double ssin,
    double tx,
    double ty,
    Rect src,
    Rect placed,
    bool rotated,
    Color? tint,
  ) {
    _ensure(count + 1);
    final i = count * 4;
    transforms[i] = scos;
    transforms[i + 1] = ssin;
    transforms[i + 2] = tx;
    transforms[i + 3] = ty;
    rects[i] = src.left;
    rects[i + 1] = src.top;
    rects[i + 2] = src.right;
    rects[i + 3] = src.bottom;
    if (tint != null || hasTint) {
      _ensureColors(count + 1);
      if (!hasTint) {
        colors.fillRange(0, count, 0xFFFFFFFF);
        hasTint = true;
      }
      colors[count] = tint?.toARGB32() ?? 0xFFFFFFFF;
    }
    if (rotated) hasRotation = true;
    bounds = bounds!.expandToInclude(placed);
    count++;
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

  @override
  Rect? get inkBounds => bounds;

  @override
  bool get keepsCanvasTransform => true;

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
class _PixelatePass(
  PixelateBeginRenderItem scope,
  final Canvas parent,

  /// Logical pixels → [canvas] pixels, before any transform inside the
  /// scope. The base a nested scope builds its grid on.
  var Matrix4 logical,
  final _PaletteImages _palettes, {

  /// What the scope paints, in its own coordinates: the pass then covers only
  /// the blocks under it. `null` covers the whole canvas.
  Rect? contentBounds,
}) {
  this : _palette = scope.palette, canvas = parent {
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
    // The grid stays anchored to the canvas origin: a cropped pass is the
    // same blocks, with fewer of them, moved by a whole number of pixels.
    var firstCol = 0, firstRow = 0, lastCol = cols, lastRow = rows;
    if (contentBounds != null) {
      final painted = MatrixUtils.transformRect(
        fromLogical.multiplied(current),
        contentBounds,
      );
      if (painted.isFinite) {
        firstCol = math.max(0, (painted.left / size).floor() - 1);
        firstRow = math.max(0, (painted.top / size).floor() - 1);
        lastCol = math.min(cols, (painted.right / size).ceil() + 1);
        lastRow = math.min(rows, (painted.bottom / size).ceil() + 1);
        if (firstCol >= lastCol || firstRow >= lastRow) {
          // Nothing lands on the canvas: one empty block will do.
          firstCol = firstRow = 0;
          lastCol = lastRow = 1;
        }
      }
    }
    _firstCol = firstCol;
    _firstRow = firstRow;
    _cols = lastCol - firstCol;
    _rows = lastRow - firstRow;
    _size = size;
    final blocks = Matrix4.translationValues(
      -firstCol.toDouble(),
      -firstRow.toDouble(),
      0,
    )..scaleByDouble(1 / size, 1 / size, 1, 1);
    // Scope-local → logical (logical⁻¹ · current) → blocks.
    final toBlocks = blocks.multiplied(fromLogical)..multiply(current);
    // From the parent's transform back to logical: current⁻¹ · logical.
    _back = fromCurrent..multiply(logical);
    final recorder = _recorder = ui.PictureRecorder();
    canvas = Canvas(recorder)..transform(toBlocks.storage);
    logical = blocks;
  }

  static final Paint _blockPaint = Paint()..filterQuality = FilterQuality.none;

  /// Where the scope's items draw.
  Canvas canvas;

  ui.PictureRecorder? _recorder;
  final List<Color>? _palette;
  late final Matrix4 _back;
  late final int _firstCol;
  late final int _firstRow;
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
    var image = picture.toImageSync(_cols, _rows);
    picture.dispose();
    final palette = _palette;
    if (palette != null) {
      if (Flut5Shaders.palette == null && Flut5Shaders.isLoading) {
        // Not ready yet: draw nothing rather than the unmatched colours.
        // The canvas draws every frame, so the scope appears once it lands.
        image.dispose();
        return parent;
      }
      final snapped = _snap(image, palette);
      if (snapped != null) {
        image.dispose();
        image = snapped;
      }
    }
    parent
      ..save()
      ..transform(_back.storage)
      ..drawImageRect(
        image,
        Rect.fromLTWH(0, 0, _cols.toDouble(), _rows.toDouble()),
        Rect.fromLTWH(
          _firstCol * _size,
          _firstRow * _size,
          _cols * _size,
          _rows * _size,
        ),
        _blockPaint,
      )
      ..restore();
    // The recorded frame keeps its own reference to the pixels.
    image.dispose();
    return parent;
  }

  static bool _warnedNoShader = false;

  /// [blocks] with every pixel — every block — snapped to the nearest
  /// colour of [palette], or `null` when the palette shader failed to load.
  /// Runs at one pixel per block, so it costs a few thousand shader runs,
  /// not a screenful.
  ui.Image? _snap(ui.Image blocks, List<Color> palette) {
    final program = Flut5Shaders.palette;
    if (program == null) {
      if (!_warnedNoShader) {
        _warnedNoShader = true;
        Flut5Console.printLater(
          'beginPixelate(): the palette shader is unavailable, so the scope '
          'was drawn without its palette.',
        );
      }
      return null;
    }
    final shader = program.fragmentShader()
      ..setFloat(0, _cols.toDouble())
      ..setFloat(1, _rows.toDouble())
      ..setFloat(2, palette.length.toDouble())
      ..setImageSampler(0, blocks)
      ..setImageSampler(1, _palettes.lookup(palette));
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, _cols.toDouble(), _rows.toDouble()),
      Paint()..shader = shader,
    );
    final picture = recorder.endRecording();
    final snapped = picture.toImageSync(_cols, _rows);
    picture.dispose();
    shader.dispose();
    return snapped;
  }
}

/// Palette textures for [_PixelatePass._snap], one pixel per colour, keyed
/// by the colours themselves — a sketch passing a fresh list literal every
/// frame still reuses one texture.
///
/// Kept for the frames that use them: [endFrame] drops every palette the
/// frame just ended did not draw with, so the cache grows to what a frame
/// needs and an animated palette never piles up textures.
class _PaletteImages() {
  Map<_PaletteKey, ui.Image> _current = {};
  Map<_PaletteKey, ui.Image> _previous = {};

  static double _srgbToLinear(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  static double _cbrt(double v) =>
      v <= 0.0 ? 0.0 : math.pow(v, 1.0 / 3.0).toDouble();

  static int _encode16(double normalized) =>
      (normalized.clamp(0.0, 1.0) * 65535.0).round();

  ui.Image lookup(List<Color> palette) {
    final key = _PaletteKey(palette);
    final hit = _current[key] ?? _previous.remove(key);
    if (hit != null) return _current[key] = hit;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // `src` without AA stores each texel verbatim:
    //   row 0: exact palette colour (premultiplied by Skia/Impeller)
    //   row 1: opaque high 8 bits of 16-bit OKLab (L, a + 0.5, b + 0.5)
    //   row 2: opaque low  8 bits of 16-bit OKLab (L, a + 0.5, b + 0.5)
    final paint = Paint()
      ..blendMode = BlendMode.src
      ..isAntiAlias = false;
    for (var i = 0; i < palette.length; i++) {
      final c = palette[i];
      final x = i.toDouble();
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, 1), paint..color = c);

      final hasAlpha = c.a > 0.0;
      final r = hasAlpha ? _srgbToLinear(c.r) : 0.0;
      final g = hasAlpha ? _srgbToLinear(c.g) : 0.0;
      final b = hasAlpha ? _srgbToLinear(c.b) : 0.0;
      final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
      final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
      final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
      final labL = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
      final labA = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
      final labB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;

      final qL = _encode16(labL);
      final qA = _encode16(labA + 0.5);
      final qB = _encode16(labB + 0.5);
      canvas.drawRect(
        Rect.fromLTWH(x, 1, 1, 1),
        paint..color = Color.fromARGB(255, qL >> 8, qA >> 8, qB >> 8),
      );
      canvas.drawRect(
        Rect.fromLTWH(x, 2, 1, 1),
        paint..color = Color.fromARGB(255, qL & 0xFF, qA & 0xFF, qB & 0xFF),
      );
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(palette.length, 3);
    picture.dispose();
    return _current[key] = image;
  }

  void endFrame() {
    // Recorded frames hold their own references, so disposing is safe.
    for (final image in _previous.values) {
      image.dispose();
    }
    _previous = _current;
    _current = {};
  }
}

class _PaletteKey(final List<Color> colors) {
  this : hashCode = Object.hashAll(colors);

  @override
  final int hashCode;

  @override
  bool operator ==(Object other) {
    if (other is! _PaletteKey || other.hashCode != hashCode) return false;
    final a = colors, b = other.colors;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
