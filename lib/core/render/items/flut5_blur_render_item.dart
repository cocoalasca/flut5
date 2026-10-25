import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../flut5_render_item.dart';
import 'flut5_arc_render_item.dart';
import 'flut5_circle_render_item.dart';
import 'flut5_ellipse_render_item.dart';
import 'flut5_image_render_item.dart';
import 'flut5_line_render_item.dart';
import 'flut5_multi_line_render_item.dart';
import 'flut5_multi_point_render_item.dart';
import 'flut5_path_render_item.dart';
import 'flut5_rect_render_item.dart';

/// Draws [items] into an offscreen layer that [layerPaint] blurs as it
/// composites — the render-queue side of `blur()`.
///
/// Every draw made under `blur()` gets a layer of its own, so each one blurs
/// on its own, the way Canvas 2D treats every call under
/// `ctx.filter = 'blur(…)'`. [items] holds more than one entry only for a
/// draw the queue splits into several items — a dashed shape's solid fill
/// and dashed stroke — which still blur together as one shape.
///
/// Impeller sizes the layer from what is drawn into it, so there the layer
/// stays unbounded. Skia (web, and desktops without Impeller) does not: an
/// unbounded layer covers the whole canvas and is blurred whole, once per
/// blurred draw — measured 2.2 s for 300 blurred outlines on the CPU
/// rasterizer, 7.7 ms bounded. There the layer is bounded to what the items
/// paint ([_paintBounds]) plus the blur's own reach, which leaves the
/// picture unchanged.
class BlurRenderItem(
  final List<Flut5RenderItem> items,
  final Paint layerPaint, {

  /// The Gaussian sigma [layerPaint] blurs by, in the items' coordinates.
  final double sigma = 0,
}) extends Flut5RenderItem {
  @override
  late final Rect? bounds = _unionBounds(items);

  /// Whether layers need explicit bounds — false on Impeller.
  static final bool _boundLayers = !ui.ImageFilter.isShaderFilterSupported;

  @override
  void execute(Canvas canvas) {
    canvas.saveLayer(_boundLayers ? _layerBounds(canvas) : null, layerPaint);
    for (final item in items) {
      item.execute(canvas);
    }
    canvas.restore();
  }

  /// Everything [items] paint and the blur spreads them over, or `null`
  /// when one of them can't say. The bounds clip the blurred result too, so
  /// they reach three sigmas past the paint, where Skia's kernel ends.
  /// Anti-aliasing reaches up to a device pixel past the geometry, so two
  /// device pixels are added, measured in this canvas's units by its
  /// smallest scale.
  Rect? _layerBounds(Canvas canvas) {
    final m = canvas.getTransform();
    // Smallest singular value of the 2×2 part: the shortest a unit can get.
    final a = m[0], b = m[1], c = m[4], d = m[5];
    final sum = a * a + b * b + c * c + d * d;
    final det = a * d - b * c;
    final root = math.sqrt(math.max(0.0, sum * sum - 4 * det * det));
    final minScale = math.sqrt(math.max(0.0, (sum - root) / 2));
    if (!(minScale > 1e-6) || !minScale.isFinite) return null;
    final aa = 2 / minScale;
    Rect? result;
    for (final item in items) {
      final r = _paintBounds(item, aa);
      if (r == null) return null;
      result = result == null ? r : result.expandToInclude(r);
    }
    return result?.inflate(3 * sigma);
  }
}

/// What [item] paints in its own coordinates: its geometry grown by its
/// stroke's reach, its shadow's offset, spread and halo, and [aa] for edge
/// anti-aliasing. `null` for items whose extent isn't known up front — text,
/// whose [Flut5RenderItem.bounds] are estimates — or paints with their own
/// filters.
Rect? _paintBounds(Flut5RenderItem item, double aa) {
  final parts = switch (item) {
    RectRenderItem(:final fillPaint, :final strokePaint, :final shadow) ||
    CircleRenderItem(:final fillPaint, :final strokePaint, :final shadow) ||
    EllipseRenderItem(:final fillPaint, :final strokePaint, :final shadow) ||
    ArcRenderItem(:final fillPaint, :final strokePaint, :final shadow) ||
    PathRenderItem(
      :final fillPaint,
      :final strokePaint,
      :final shadow,
    ) => (item.bounds, fillPaint, strokePaint, shadow),
    LineRenderItem(:final strokePaint, :final shadow) => (
      item.bounds,
      null,
      strokePaint,
      shadow,
    ),
    MultiLineRenderItem(:final linePaint, :final shadow) => (
      item.bounds,
      null,
      linePaint,
      shadow,
    ),
    MultiPointRenderItem(:final pointPaint, :final shadow) => (
      item.bounds,
      null,
      pointPaint,
      shadow,
    ),
    ImageRenderItem(:final dst, :final shadow) => (dst, null, null, shadow),
    _ => null,
  };
  if (parts == null) return null;
  final (geometry, fill, stroke, shadow) = parts;
  if (geometry == null) return null;
  for (final p in [fill, stroke]) {
    if (p != null && (p.maskFilter != null || p.imageFilter != null)) {
      return null;
    }
  }
  final box = Rect.fromLTRB(
    math.min(geometry.left, geometry.right),
    math.min(geometry.top, geometry.bottom),
    math.max(geometry.left, geometry.right),
    math.max(geometry.top, geometry.bottom),
  );
  final reach = stroke == null ? 0.0 : _strokeReach(stroke, stroke.strokeWidth);
  var result = box.inflate(reach + aa);
  if (shadow != null) {
    // The shadow redraws the shape shifted by its offset, spread by a stroke
    // of twice the spread (or a stroke that much wider), then blurred.
    final spreadReach = stroke == null
        ? shadow.spread * math.sqrt2
        : _strokeReach(stroke, stroke.strokeWidth + shadow.spread * 2);
    final halo = shadow.blur > 0
        ? 3 * Shadow.convertRadiusToSigma(shadow.blur)
        : 0.0;
    result = result.expandToInclude(
      box
          .shift(shadow.offset)
          .inflate(math.max(reach, spreadReach) + halo + aa),
    );
  }
  return result;
}

/// How far a stroke of [width] painted with [stroke]'s joins and caps can
/// reach past the outline: half its width, out to a miter's tip at sharp
/// corners or a square cap's corner.
double _strokeReach(Paint stroke, double width) =>
    width /
    2 *
    (stroke.strokeJoin == StrokeJoin.miter
        ? math.max(stroke.strokeMiterLimit, math.sqrt2)
        : math.sqrt2);

Rect? _unionBounds(List<Flut5RenderItem> items) {
  Rect? result;
  for (final item in items) {
    final b = item.bounds;
    if (b == null) continue;
    result = result == null ? b : result.expandToInclude(b);
  }
  return result;
}

/// Opens a `beginBlur()` scope: everything up to the matching
/// [BlurEndRenderItem] draws into one layer that [layerPaint] blurs as a
/// whole when it closes. With a `null` paint (radius `0`) the scope only
/// saves, so it still balances.
class BlurBeginRenderItem(final Paint? layerPaint) extends Flut5RenderItem {
  @override
  void execute(Canvas canvas) {
    final paint = layerPaint;
    if (paint == null) {
      canvas.save();
    } else {
      canvas.saveLayer(null, paint);
    }
  }
}

/// Closes the innermost [BlurBeginRenderItem] scope.
class BlurEndRenderItem() extends Flut5RenderItem {
  @override
  void execute(Canvas canvas) => canvas.restore();
}
