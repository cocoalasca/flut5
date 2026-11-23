import 'package:flutter/widgets.dart';

import '../flut5_render_item.dart';

class PointRenderItem(
  final Offset center,
  final double radius,
  final Paint? strokePaint,
) extends Flut5RenderItem {
  @override
  Rect? get bounds => Rect.fromCircle(center: center, radius: radius);

  @override
  bool get keepsCanvasTransform => true;

  @override
  void execute(Canvas canvas) {
    if (strokePaint != null) canvas.drawCircle(center, radius, strokePaint!);
  }
}
