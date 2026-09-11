import 'package:flutter/material.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

class ArcRenderItem(
  final Rect rect,
  final double start,
  final double sweepAngle,
  final bool useCenter,
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
        (p) => canvas.drawArc(rect, start, sweepAngle, useCenter, p),
      );
    }
    if (fillPaint != null) {
      canvas.drawArc(rect, start, sweepAngle, useCenter, fillPaint!);
    }
    if (strokePaint != null) {
      canvas.drawArc(rect, start, sweepAngle, useCenter, strokePaint!);
    }
  }
}
