import 'package:flutter/material.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

class LineRenderItem(
  final Offset p1,
  final Offset p2,
  final Paint? strokePaint, {
  final Flut5ShadowSpec? shadow,
}) extends Flut5RenderItem {
  @override
  Rect? get bounds => Rect.fromPoints(p1, p2);

  @override
  void execute(Canvas canvas) {
    final stroke = strokePaint;
    if (stroke == null) return;
    final s = shadow;
    if (s != null) {
      canvas.save();
      canvas.translate(s.offset.dx, s.offset.dy);
      canvas.drawLine(p1, p2, s.strokeShadowPaint(stroke));
      canvas.restore();
    }
    canvas.drawLine(p1, p2, stroke);
  }
}
