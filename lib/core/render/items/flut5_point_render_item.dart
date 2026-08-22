import 'package:flutter/material.dart';
import '../flut5_render_item.dart';

class PointRenderItem extends Flut5RenderItem {
  final Offset center;
  final double radius;
  final Paint? strokePaint;
  
  PointRenderItem(this.center, this.radius, this.strokePaint);

  @override
  Rect? get bounds => Rect.fromCircle(center: center, radius: radius);

  @override
  void execute(Canvas canvas) {
    if (strokePaint != null) canvas.drawCircle(center, radius, strokePaint!);
  }
}
