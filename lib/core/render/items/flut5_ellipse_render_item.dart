import 'package:flutter/material.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

class EllipseRenderItem(
  final Rect rect,
  final Paint? fillPaint,
  final Paint? strokePaint, {
  final Flut5ShadowSpec? shadow,
}) extends Flut5RenderItem {
  @override
  Rect? get bounds => rect;

  @override
  void execute(Canvas canvas) {
    final s = shadow;
    if (s != null) {
      s.paintShape(
        canvas,
        fillPaint,
        strokePaint,
        (p) => canvas.drawOval(rect, p),
      );
    }
    if (fillPaint != null) canvas.drawOval(rect, fillPaint!);
    if (strokePaint != null) canvas.drawOval(rect, strokePaint!);
  }
}
