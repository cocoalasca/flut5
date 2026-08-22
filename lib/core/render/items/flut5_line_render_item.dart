import 'package:flutter/material.dart';
import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

class LineRenderItem extends Flut5RenderItem {
  final Offset p1;
  final Offset p2;
  final Paint? strokePaint;
  final Flut5ShadowSpec? shadow;

  LineRenderItem(this.p1, this.p2, this.strokePaint, {this.shadow});

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
