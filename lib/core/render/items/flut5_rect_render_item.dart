import 'package:flutter/material.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

class RectRenderItem(
  final Rect rect,
  final RRect? rrect,
  final Paint? fillPaint,
  final Paint? strokePaint, {
  final Flut5ShadowSpec? shadow,
}) extends Flut5RenderItem {
  @override
  Rect? get bounds => rrect?.outerRect ?? rect;

  @override
  void execute(Canvas canvas) {
    final s = shadow;
    if (s != null) {
      s.paintShape(canvas, fillPaint, strokePaint, (p) {
        if (rrect != null) {
          canvas.drawRRect(rrect!, p);
        } else {
          canvas.drawRect(rect, p);
        }
      });
    }
    if (rrect != null) {
      if (fillPaint != null) canvas.drawRRect(rrect!, fillPaint!);
      if (strokePaint != null) canvas.drawRRect(rrect!, strokePaint!);
    } else {
      if (fillPaint != null) canvas.drawRect(rect, fillPaint!);
      if (strokePaint != null) canvas.drawRect(rect, strokePaint!);
    }
  }
}
