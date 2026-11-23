import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../flut5_paint_bounds.dart';
import '../flut5_render_item.dart';

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

  /// Exposed to [Flut5RenderQueue] so Skia/Web blur scopes only compute
  /// content bounds when layer bounding is active.
  static bool get boundLayers => _boundLayers;

  @override
  bool get keepsCanvasTransform => true;

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
    final minScale = _minCanvasScale(canvas);
    if (minScale == null) return null;
    final aa = 2 / minScale;
    Rect? result;
    for (final item in items) {
      final r = flut5PaintBounds(item, aa);
      if (r == null) return null;
      result = result == null ? r : result.expandToInclude(r);
    }
    return result?.inflate(3 * sigma);
  }
}

double? _minCanvasScale(Canvas canvas) {
  final m = canvas.getTransform();
  final a = m[0], b = m[1], c = m[4], d = m[5];
  final sum = a * a + b * b + c * c + d * d;
  final det = a * d - b * c;
  final root = math.sqrt(math.max(0.0, sum * sum - 4 * det * det));
  final minScale = math.sqrt(math.max(0.0, (sum - root) / 2));
  return (minScale > 1e-6 && minScale.isFinite) ? minScale : null;
}

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
class BlurBeginRenderItem(
  final Paint? layerPaint, {
  final double sigma = 0,
}) extends Flut5RenderItem {
  /// Paint bounds accumulated inside this scope (set on scope close on Skia/Web),
  /// in the coordinate space active at this item. `null` falls back to an
  /// unbounded layer unless [emptyScope] is true.
  Rect? contentBounds;

  /// Whether the scope contained zero paintable items (as distinct from a
  /// zero-area hairline whose geometry still inflates by stroke/AA/sigma).
  bool emptyScope = false;

  @override
  bool get keepsCanvasTransform => true;

  @override
  void execute(Canvas canvas) {
    final paint = layerPaint;
    if (paint == null) {
      canvas.save();
    } else {
      canvas.saveLayer(
        BlurRenderItem._boundLayers ? _scopeLayerBounds(canvas) : null,
        paint,
      );
    }
  }

  Rect? _scopeLayerBounds(Canvas canvas) {
    if (emptyScope) return Rect.zero;
    final content = contentBounds;
    if (content == null) return null;
    final minScale = _minCanvasScale(canvas);
    if (minScale == null) return null;
    // sqrt2 accounts for AA margin around rotated inner geometry.
    return content.inflate((2 * math.sqrt2) / minScale + 3 * sigma);
  }
}

/// Closes the innermost [BlurBeginRenderItem] scope.
class BlurEndRenderItem() extends Flut5RenderItem {
  @override
  void execute(Canvas canvas) => canvas.restore();
}
