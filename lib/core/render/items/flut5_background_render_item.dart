import 'package:flutter/material.dart';

import '../flut5_render_item.dart';

/// Clears the canvas for the next frame.
///
/// [color] takes the fast `canvas.drawColor` path (single GPU op, no rect).
/// [paint] is used for gradient/shader backgrounds — filled via [rect] when
/// provided, or the full clip via `drawPaint` otherwise.
class BackgroundRenderItem._({
  required final Color? color,
  required final Paint? paint,
  required final Rect? rect,
  required final bool isOpaqueFullCanvas,
}) extends Flut5RenderItem {
  BackgroundRenderItem(Color color)
    : this._(
        color: color,
        paint: null,
        rect: null,
        isOpaqueFullCanvas: color.a == 1.0,
      );
  BackgroundRenderItem.shader(Paint paint, Rect? rect, {required bool isOpaque})
    : this._(
        color: null,
        paint: paint,
        rect: rect,
        isOpaqueFullCanvas: rect == null && isOpaque,
      );

  @override
  void execute(Canvas canvas) {
    if (color != null) {
      canvas.drawColor(
        color!,
        isOpaqueFullCanvas ? BlendMode.src : BlendMode.srcOver,
      );
      return;
    }
    if (rect != null) {
      canvas.drawRect(rect!, paint!);
    } else {
      canvas.drawPaint(paint!);
    }
  }
}
