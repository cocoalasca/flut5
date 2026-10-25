import 'package:flutter/material.dart';

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
/// The layer is unbounded: item bounds leave out stroke width and shadows,
/// so a hint built from them could crop the halo. Impeller sizes the layer
/// from what is drawn into it anyway.
class BlurRenderItem(final List<Flut5RenderItem> items, final Paint layerPaint)
    extends Flut5RenderItem {
  @override
  late final Rect? bounds = _unionBounds(items);

  @override
  void execute(Canvas canvas) {
    canvas.saveLayer(null, layerPaint);
    for (final item in items) {
      item.execute(canvas);
    }
    canvas.restore();
  }
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
