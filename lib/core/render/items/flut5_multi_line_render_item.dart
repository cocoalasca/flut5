import 'dart:typed_data';
import 'dart:ui';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

/// Renders multiple disconnected line segments in a single GPU call via
/// [Canvas.drawRawPoints] with [PointMode.lines].
///
/// [coords] is a flat [Float32List] of (x, y) pairs. Each pair of points
/// forms one segment: (p0,p1), (p2,p3), (p4,p5), ...
/// [linePaint] must have [Paint.strokeWidth] set to the desired thickness
/// and a stroke-style [Paint.color].
class MultiLineRenderItem extends Flut5RenderItem {
  final Float32List coords;
  final Paint linePaint;
  final Flut5ShadowSpec? shadow;

  MultiLineRenderItem(this.coords, this.linePaint, {this.shadow});

  @override
  late final Rect? bounds = _coordBounds(coords);

  @override
  void execute(Canvas canvas) {
    if (coords.isEmpty) return;
    final s = shadow;
    if (s != null) {
      canvas.save();
      canvas.translate(s.offset.dx, s.offset.dy);
      canvas.drawRawPoints(
        PointMode.lines,
        coords,
        s.strokeShadowPaint(linePaint),
      );
      canvas.restore();
    }
    canvas.drawRawPoints(PointMode.lines, coords, linePaint);
  }
}

/// Axis-aligned bounds over a flat `(x, y)` [Float32List], or `null` when empty.
Rect? _coordBounds(Float32List coords) {
  if (coords.length < 2) return null;
  double minX = coords[0], maxX = coords[0];
  double minY = coords[1], maxY = coords[1];
  for (int i = 2; i + 1 < coords.length; i += 2) {
    final x = coords[i];
    final y = coords[i + 1];
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}
