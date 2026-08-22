import 'dart:typed_data';
import 'dart:ui';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

/// Renders multiple points in a single GPU call via [Canvas.drawRawPoints].
///
/// [coords] is a flat [Float32List] of (x, y) pairs.
/// [pointPaint] must have [Paint.strokeWidth] set to the desired point diameter
/// and [Paint.strokeCap] = [StrokeCap.round] for circular dots.
class MultiPointRenderItem extends Flut5RenderItem {
  final Float32List coords;
  final Paint pointPaint;
  final Flut5ShadowSpec? shadow;

  MultiPointRenderItem(this.coords, this.pointPaint, {this.shadow});

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
        PointMode.points,
        coords,
        s.strokeShadowPaint(pointPaint),
      );
      canvas.restore();
    }
    canvas.drawRawPoints(PointMode.points, coords, pointPaint);
  }
}

/// Axis-aligned bounds over a flat `(x, y)` [Float32List], or `null` when empty.
/// Shared by [MultiPointRenderItem] and [MultiLineRenderItem].
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
