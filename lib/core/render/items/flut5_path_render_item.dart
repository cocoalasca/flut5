import 'package:flutter/material.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

class PathRenderItem(
  final Path path,
  final Paint? fillPaint,
  final Paint? strokePaint, {
  final Flut5ShadowSpec? shadow,
}) extends Flut5RenderItem {
  /// Memoized — the path is immutable once queued, and bounds may be read
  /// repeatedly (e.g. overlapping `contentBoundsFrom` walks).
  @override
  late final Rect? bounds = path.getBounds();

  @override
  void execute(Canvas canvas) {
    final s = shadow;
    if (s != null) {
      s.paintShape(
        canvas,
        fillPaint,
        strokePaint,
        (p) => canvas.drawPath(path, p),
      );
    }
    if (fillPaint != null) canvas.drawPath(path, fillPaint!);
    if (strokePaint != null) canvas.drawPath(path, strokePaint!);
  }
}
