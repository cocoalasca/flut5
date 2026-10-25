import 'package:flutter/material.dart';

import '../flut5_render_item.dart';

/// Opens a `beginPixelate()` scope in the render queue.
///
/// Draws nothing itself. During replay the queue renders every item between
/// this marker and its [PixelateEndRenderItem] into a snapshot with one pixel
/// per block, then draws that back scaled up with nearest-neighbour sampling.
/// Rendering at block resolution averages each block: anti-aliasing covers
/// shapes, mipmaps cover images. The grid starts at the canvas origin, so
/// every scope in a frame shares it.
///
/// [width] and [height] are the canvas size in logical pixels when the scope
/// opened; the snapshot covers the whole canvas.
class PixelateBeginRenderItem(
  final double blockSize,
  final double width,
  final double height,
) extends Flut5RenderItem {
  @override
  void execute(Canvas canvas) {}
}

/// Closes the innermost open [PixelateBeginRenderItem] scope.
class PixelateEndRenderItem() extends Flut5RenderItem {
  @override
  void execute(Canvas canvas) {}
}
