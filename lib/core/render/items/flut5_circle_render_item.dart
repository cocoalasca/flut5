import 'package:flutter/material.dart';
import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

class CircleRenderItem extends Flut5RenderItem {
  final Offset center;
  final double radius;
  final Paint? fillPaint;
  final Paint? strokePaint;
  final Flut5ShadowSpec? shadow;

  CircleRenderItem(
    this.center,
    this.radius,
    this.fillPaint,
    this.strokePaint, {
    this.shadow,
  });

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
