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
import 'items/flut5_rect_render_item.dart';
import 'items/flut5_circle_render_item.dart';
import 'items/flut5_ellipse_render_item.dart';
import 'items/flut5_image_atlas_render_item.dart';
import 'items/flut5_image_render_item.dart';
import 'items/flut5_line_render_item.dart';
import 'items/flut5_arc_render_item.dart';
import 'items/flut5_background_render_item.dart';
import 'items/flut5_transform_render_item.dart';
import 'items/flut5_clip_render_item.dart';
export '../flut5_shadow.dart' show Flut5ShadowSpec;
export 'flut5_render_item.dart';
export 'items/flut5_arc_render_item.dart';
export 'items/flut5_background_render_item.dart';
export 'items/flut5_circle_render_item.dart';
export 'items/flut5_clip_render_item.dart';
export 'items/flut5_ellipse_render_item.dart';
export 'items/flut5_image_atlas_render_item.dart';
export 'items/flut5_image_render_item.dart';
export 'items/flut5_line_render_item.dart';
export 'items/flut5_path_render_item.dart';
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
/// a different kind) flushes the pending batches first.
///
/// Pure translations (`push`/`pop`/`translate` with no rotation, scale, or
/// skew in between) are *folded* into geometry coordinates at append time
/// instead of being emitted as [TransformRenderItem]s — see the fold-state
/// section below. This keeps the canonical `push(); translate(); shape();
/// pop();` pattern fully batchable across iterations.
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

  /// Running union of the destination rects in the open run, so the flushed
  /// item carries bounds without re-reading the float32 buffers.
  Rect? _atlasBounds;

  /// First sprite's rects in full double precision. A run that never grows
  /// past one flushes as a plain [ImageRenderItem] instead, which is both
  /// cheaper and bit-exact — see [_flushImages].
  Rect? _atlasFirstSrc;
  Rect? _atlasFirstDst;

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

  // ── Translate folding ─────────────────────────────────────────────────
  //
  // While the transform state is a pure translation, `translate()` adds to
  // (_foldDx, _foldDy) and geometry is offset at append time — no transform
  // items are queued and batches keep accumulating across push/pop pairs.
  // Each folded push() saves the pending offset on [_foldStack]; a folded
  // pop() restores it. The moment something needs the *canvas* transform to
  // match (a rotate/scale/matrix, an opaque enqueued item like text or a
  // clip, or clip-mask recording), [_materializeTransforms] converts the
  // folded state into real save/translate items — folded stack entries
  // become `real` and their pops emit real restores. Baking a translation
  // into local coordinates is valid under any already-emitted canvas
  // transform (canvas.translate(o) then draw(p) ≡ draw(p + o)), so folding
  // resumes immediately after materialization.
  double _foldDx = 0.0;
  double _foldDy = 0.0;

  /// Saved (dx, dy, isReal) per push. `isReal` entries were materialized as
  /// canvas `save()`s and pop as real restores; their saved offset is always
  /// (0, 0) because materialization moves pending offsets onto the canvas.
  final List<(double, double, bool)> _foldStack = [];

  bool get _hasFoldOffset => _foldDx != 0.0 || _foldDy != 0.0;

  // ── Background bookkeeping (kept O(1) instead of scanning _items) ─────
  BackgroundRenderItem? _lastBackground;
  bool _hasOpaqueFullCanvasBg = false;

  // ── Transform entry points (called by the transform mixin) ────────────

  /// Records a `push()`. Folded: saves the pending offset, emits nothing.
  void pushTransform() {
    _foldStack.add((_foldDx, _foldDy, false));
  }

  /// Records a `pop()`. Folded entries restore the pending offset silently;
  /// materialized (`real`) entries emit a canvas restore.
  void popTransform() {
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
    if (_foldStack.last.$3 && _clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): pop() of a scope opened outside the clip callback was '
        'ignored inside the callback.',
      );
      return;
    }
    final (dx, dy, real) = _foldStack.removeLast();
    if (real) {
      _addItem(TransformRenderItem.pop());
    }
    _foldDx = dx;
    _foldDy = dy;
  }

  /// Records a `translate()`. Never emits an item — the offset is baked into
  /// geometry at append time, so batches keep accumulating across it.
  void translateTransform(double dx, double dy) {
    _foldDx += dx;
    _foldDy += dy;
  }

  /// Records a non-translate transform (rotate/scale/skew/matrix). The folded
  /// state is materialized first so the canvas transform matches, then [item]
  /// is queued like any other.
  void applyTransform(TransformRenderItem item) {
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): rotate()/scale()/applyMatrix() are not supported inside a '
        'clip callback and were ignored (translate/push/pop do apply).',
      );
      return;
    }
    _materializeTransforms();
    _addItem(item);
  }

  /// Converts the folded translation state into real canvas ops.
  ///
  /// Needed whenever the *canvas* transform must reflect the folded offsets:
  /// before opaque enqueued items (text, clips, custom paths — their
  /// coordinates are not baked by this queue), before non-translate
  /// transforms, and before clip-mask recording. Emits, bottom-up per folded
  /// stack level, `translate(delta)` + `save()`, then the remaining pending
  /// delta; marks those levels `real` so their pops emit real restores.
  void _materializeTransforms() {
    var anyFolded = _foldDx != 0.0 || _foldDy != 0.0;
    if (!anyFolded) {
      for (int i = _foldStack.length - 1; i >= 0; i--) {
        if (!_foldStack[i].$3) {
          anyFolded = true;
          break;
        }
      }
      if (!anyFolded) return;
    }
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    double prevDx = 0.0, prevDy = 0.0;
    for (int i = 0; i < _foldStack.length; i++) {
      final (dx, dy, real) = _foldStack[i];
      if (real) continue; // Already on the canvas; its saved offset is 0.
      if (dx != prevDx || dy != prevDy) {
        _items.add(TransformRenderItem.translate(dx - prevDx, dy - prevDy));
      }
      _items.add(TransformRenderItem.push());
      prevDx = dx;
      prevDy = dy;
      _foldStack[i] = (0.0, 0.0, true);
    }
    if (_foldDx != prevDx || _foldDy != prevDy) {
      _items.add(
        TransformRenderItem.translate(_foldDx - prevDx, _foldDy - prevDy),
      );
    }
    _foldDx = 0.0;
    _foldDy = 0.0;
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

  // ── Save-stack imbalance warning throttle ─────────────────────────────
  //
  // Tracks whether an "unbalanced canvas stack" warning has already been
  // emitted, so a sketch that leaks a push()/clip() every frame warns once
  // rather than 60×/sec. Reset back to false the first balanced frame.
  bool _warnedSaveImbalance = false;

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
      throw StateError('endClipRecording() called without beginClipRecording().');
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
    x += _foldDx;
    y += _foldDy;
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
    x1 += _foldDx;
    y1 += _foldDy;
    x2 += _foldDx;
    y2 += _foldDy;
    if (_hasDash) {
      _emitDashed(Path()..moveTo(x1, y1)..lineTo(x2, y2), null, paint);
      return;
    }
    if (!canBatchPaint(paint)) {
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
    if (_hasFoldOffset) {
      final off = Offset(_foldDx, _foldDy);
      rect = rect.shift(off);
      rrect = rrect?.shift(off);
    }
    if (_clipRecordingPath != null) {
      if (rrect != null) {
        _clipRecordingPath!.addRRect(rrect);
      } else {
        _clipRecordingPath!.addRect(rect);
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
    if (!canBatchPaint(fill) || !canBatchPaint(stroke)) {
      _addItem(
        RectRenderItem(rect, rrect, fill, stroke, shadow: _activeShadow),
      );
      return;
    }
    final path = _beginShape(fill, stroke);
    if (rrect != null) {
      path.addRRect(rrect);
    } else {
      path.addRect(rect);
    }
    _pendingShapeHasContent = true;
  }

  /// Append a circle to the pending shape path.
  void appendCircle(Offset center, double radius, Paint? fill, Paint? stroke) {
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
    if (!canBatchPaint(fill) || !canBatchPaint(stroke)) {
      _addItem(
        CircleRenderItem(center, radius, fill, stroke, shadow: _activeShadow),
      );
      return;
    }
    _beginShape(
      fill,
      stroke,
    ).addOval(Rect.fromCircle(center: center, radius: radius));
    _pendingShapeHasContent = true;
  }

  /// Append an ellipse (oval) to the pending shape path.
  void appendEllipse(Rect rect, Paint? fill, Paint? stroke) {
    if (_hasFoldOffset) {
      rect = rect.shift(Offset(_foldDx, _foldDy));
    }
    if (_clipRecordingPath != null) {
      _clipRecordingPath!.addOval(rect);
      return;
    }
    if (fill == null && stroke == null) return;
    if (_hasDash && stroke != null) {
      _emitDashed(Path()..addOval(rect), fill, stroke);
      return;
    }
    if (!canBatchPaint(fill) || !canBatchPaint(stroke)) {
      _addItem(EllipseRenderItem(rect, fill, stroke, shadow: _activeShadow));
      return;
    }
    _beginShape(fill, stroke).addOval(rect);
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
    if (!canBatchPaint(fill) || !canBatchPaint(stroke)) {
      _addItem(
        ArcRenderItem(
          rect,
          startAngle,
          sweepAngle,
          useCenter,
          fill,
          stroke,
          shadow: _activeShadow,
        ),
      );
      return;
    }
    final path = _beginShape(fill, stroke);
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
  void appendShapePath(Path path, Paint? fill, Paint? stroke) {
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
    if (!canBatchPaint(fill) || !canBatchPaint(stroke)) {
      _addItem(
        PathRenderItem(
          off == Offset.zero ? path : path.shift(off),
          fill,
          stroke,
          shadow: _activeShadow,
        ),
      );
      return;
    }
    final pending = _beginShape(fill, stroke);
    pending.addPath(path, off);
    _pendingShapeHasContent = true;
  }

  /// Append a bitmap blit sampling [src] (image pixels) into [dst] (user
  /// coordinates).
  ///
  /// A texture op can't merge into the shared shape [Path], so this always
  /// materializes its own [ImageRenderItem]. It still bakes the folded
  /// translate into [dst] rather than routing through [enqueue], so an
  /// `image()` inside a `push(); translate(); … pop();` loop doesn't force
  /// the queue to emit real transform items and break batching for the
  /// shapes around it.
  void appendImage(ui.Image image, Rect src, Rect dst, BlendMode blendMode) {
    if (_clipRecordingPath != null) {
      Flut5Console.printLater(
        'clip(): image() ignored inside clip callback — a bitmap has no '
        'outline to build a mask from. Use rect() to mask the region the '
        'image occupies.',
      );
      return;
    }
    // Bake the folded translate the same way the shape/point paths do, so an
    // image() inside a push(); translate(); … pop(); loop neither materializes
    // transform items nor breaks batching for the shapes around it. For the
    // atlas run this is doubly useful: the baked offset IS the sprite's
    // translate, so the canonical mosaic loop feeds the buffers directly.
    final placed = _hasFoldOffset ? dst.shift(Offset(_foldDx, _foldDy)) : dst;

    if (!_canAtlas(src, placed)) {
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
    // scos carries the uniform scale; ssin stays 0 because Flut5 rotation
    // lives on the canvas transform, shared by every sprite in the run.
    _atlasTransforms[i] = placed.width / src.width;
    _atlasTransforms[i + 1] = 0.0;
    _atlasTransforms[i + 2] = placed.left;
    _atlasTransforms[i + 3] = placed.top;
    _atlasRects[i] = src.left;
    _atlasRects[i + 1] = src.top;
    _atlasRects[i + 2] = src.right;
    _atlasRects[i + 3] = src.bottom;
    if (_atlasCount == 0) {
      _atlasFirstSrc = src;
      _atlasFirstDst = placed;
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
  /// pass), and the scale must be uniform: `RSTransform` holds one scale
  /// factor, so a stretch that scales x and y differently has no
  /// representation. Degenerate rects fall out rather than dividing by zero.
  bool _canAtlas(Rect src, Rect dst) {
    if (_activeShadow != null) return false;
    if (src.width <= 0 || src.height <= 0) return false;
    if (!dst.width.isFinite || !dst.height.isFinite) return false;
    final scaleX = dst.width / src.width;
    final scaleY = dst.height / src.height;
    final larger = scaleX.abs() > scaleY.abs() ? scaleX.abs() : scaleY.abs();
    return (scaleX - scaleY).abs() <= _atlasScaleTolerance * larger;
  }

  /// Materializes the open atlas run, if any.
  ///
  /// A run of one flushes as a plain [ImageRenderItem]: it skips the atlas
  /// setup and keeps full double precision, so a single `image()` produces
  /// byte-identical output whether or not this path exists.
  void _flushImages() {
    if (_atlasCount == 0) return;
    final image = _pendingAtlasImage!;
    if (_atlasCount == 1) {
      _items.add(
        ImageRenderItem(
          image: image,
          src: _atlasFirstSrc!,
          dst: _atlasFirstDst!,
          blendMode: _pendingAtlasBlend,
        ),
      );
    } else {
      // sublist copies — decouples the item from the reusable buffers so the
      // next run can overwrite them in place (same as the point/line flushes).
      _items.add(
        ImageAtlasRenderItem(
          image: image,
          transforms: _atlasTransforms.sublist(0, _atlasCount * 4),
          rects: _atlasRects.sublist(0, _atlasCount * 4),
          blendMode: _pendingAtlasBlend,
          bounds: _atlasBounds!,
        ),
      );
    }
    _atlasCount = 0;
    _pendingAtlasImage = null;
    _atlasBounds = null;
    _atlasFirstSrc = null;
    _atlasFirstDst = null;
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
    if (_pendingPointPaint != null && !identical(_pendingPointPaint, paint)) {
      _flushPoints();
    }
    _flushLines();
    _flushShapes();
    _flushImages();
    _pendingPointPaint = paint;
    _pendingPointShadow = _activeShadow;
    _ensurePointCapacity(_pointCount + coords.length);
    if (_hasFoldOffset) {
      final fdx = _foldDx, fdy = _foldDy;
      for (int i = 0; i + 1 < coords.length; i += 2) {
        _pointBuffer[_pointCount++] = coords[i] + fdx;
        _pointBuffer[_pointCount++] = coords[i + 1] + fdy;
      }
    } else {
      _pointBuffer.setRange(_pointCount, _pointCount + coords.length, coords);
      _pointCount += coords.length;
    }
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
    _appendPoly(sides, fill, stroke);
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
    _appendPoly(n, fill, stroke);
  }

  /// Shared polygon implementation reading the first [n] points from the
  /// poly scratch buffers. Applies the fold offset while building the path.
  void _appendPoly(int n, Paint? fill, Paint? stroke) {
    if (_clipRecordingPath != null) {
      _addPolyTo(_clipRecordingPath!, n);
      return;
    }
    if (fill == null && stroke == null) return;
    if (_hasDash && stroke != null) {
      final p = Path();
      _addPolyTo(p, n);
      _emitDashed(p, fill, stroke);
      return;
    }
    if (!canBatchPaint(fill) || !canBatchPaint(stroke)) {
      final p = Path();
      _addPolyTo(p, n);
      _addItem(PathRenderItem(p, fill, stroke, shadow: _activeShadow));
      return;
    }
    _addPolyTo(_beginShape(fill, stroke), n);
    _pendingShapeHasContent = true;
  }

  void _addPolyTo(Path p, int n) {
    final fdx = _foldDx, fdy = _foldDy;
    p.moveTo(_polyXs[0] + fdx, _polyYs[0] + fdy);
    for (int i = 1; i < n; i++) {
      p.lineTo(_polyXs[i] + fdx, _polyYs[i] + fdy);
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

  /// Internal add: flushes pending batches and appends [item]. Used by the
  /// append* fallback branches, whose item coordinates already carry the
  /// fold offset — materializing here would apply the translation twice.
  void _addItem(Flut5RenderItem item) {
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    if (item is BackgroundRenderItem) {
      _lastBackground = item;
      if (item.isOpaqueFullCanvas) _hasOpaqueFullCanvasBg = true;
    }
    _items.add(item);
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
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    final baseline = canvas.getSaveCount();
    for (final item in _items) {
      item.execute(canvas);
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
    _flushShapes();
    _flushPoints();
    _flushLines();
    _flushImages();
    final baseline = canvas.getSaveCount();
    for (final item in _items) {
      if (item is BackgroundRenderItem) continue;
      item.execute(canvas);
    }
    _balanceSaveStack(canvas, baseline);
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
    // Atlas run: drop the sprites but keep the Float32List backing buffers,
    // same bargain as the point/line buffers above.
    _atlasCount = 0;
    _pendingAtlasImage = null;
    _atlasBounds = null;
    _atlasFirstSrc = null;
    _atlasFirstDst = null;
    _clipRecordingPath = null;
    // Fold state is per-frame — the canvas transform resets with the frame.
    _foldDx = 0.0;
    _foldDy = 0.0;
    _foldStack.clear();
    _lastBackground = null;
    _hasOpaqueFullCanvasBg = false;
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
      _addItem(PathRenderItem(outline, fill, null, shadow: shadow));
      _addItem(PathRenderItem(dashed, null, stroke));
    } else {
      _addItem(PathRenderItem(dashed, null, stroke, shadow: shadow));
    }
  }

  Path _beginShape(Paint? fill, Paint? stroke) {
    if (_pendingShapePath != null &&
        (!identical(_pendingShapeFill, fill) ||
            !identical(_pendingShapeStroke, stroke))) {
      _flushShapes();
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
    // sublist copies — decouples the item from the reusable buffer so later
    // frames can overwrite _pointBuffer in place.
    final snapshot = _pointBuffer.sublist(0, _pointCount);
    _items.add(
      MultiPointRenderItem(
        snapshot,
        _pendingPointPaint!,
        shadow: _pendingPointShadow,
      ),
    );
    _pointCount = 0;
    _pendingPointPaint = null;
    _pendingPointShadow = null;
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
