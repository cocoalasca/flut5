import 'package:flutter/material.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

class CircleRenderItem(
  final Offset center,
  final double radius,
  final Paint? fillPaint,
  final Paint? strokePaint, {
  final Flut5ShadowSpec? shadow,
}) extends Flut5RenderItem {
  @override
  Rect? get bounds => Rect.fromCircle(center: center, radius: radius);

  @override
  void execute(Canvas canvas) {
    final s = shadow;
    if (s != null) {
      s.paintShape(
        canvas,
        fillPaint,
        strokePaint,
        (p) => canvas.drawCircle(center, radius, p),
      );
    }
    if (fillPaint != null) canvas.drawCircle(center, radius, fillPaint!);
    if (strokePaint != null) canvas.drawCircle(center, radius, strokePaint!);
  }
}
