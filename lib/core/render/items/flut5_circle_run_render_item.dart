import 'dart:typed_data';
import 'dart:ui';

import '../flut5_render_item.dart';

/// A batch of filled circles that share one radius, drawn as round points in
/// a single [Canvas.drawRawPoints] call.
///
/// The queue only builds this on Skia (the web renderers, and desktops
/// without Impeller), where a round point of width `2r` is the same draw as a
/// circle of radius `r`. Measured byte-identical to one `drawCircle` per
/// circle on CanvasKit and skwasm, for radii from 0.25 to 90, under scales,
/// non-uniform scales and rotations, opaque and translucent. On the software
/// rasterizer `flutter test` uses, it is identical except under rotation and
/// at a few radii under a 3× scale, and closer to `drawCircle` than a merged
/// path in every case measured. The merged path the batch would otherwise
/// draw differs from `drawCircle` along the edges (up to 88/255 on
/// CanvasKit), and costs far more there: 1000 circles took 2.3–9.4 ms as one
/// path and 0.5–1.1 ms as points.
///
/// Impeller keeps the path. There a point is tessellated while a circle is
/// drawn analytically, so neither matches `drawCircle`, and switching would
/// change what batched circles look like today.
class CircleRunRenderItem(
  /// The circles' centres, as flat `(x, y)` pairs.
  final Float32List centres,

  /// The radius every circle in the run shares.
  final double radius,

  /// The fill, as a point paint: stroke width `2 * radius`, round caps.
  final Paint pointPaint,
) extends Flut5RenderItem {
  @override
  late final Rect? bounds = _centreBounds(centres, radius);

  @override
  bool get keepsCanvasTransform => true;

  @override
  void execute(Canvas canvas) {
    canvas.drawRawPoints(PointMode.points, centres, pointPaint);
  }
}

/// The box of every circle in the run: the centres' box grown by [radius].
Rect? _centreBounds(Float32List centres, double radius) {
  if (centres.length < 2) return null;
  double minX = centres[0], maxX = centres[0];
  double minY = centres[1], maxY = centres[1];
  for (int i = 2; i + 1 < centres.length; i += 2) {
    final x = centres[i];
    final y = centres[i + 1];
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return Rect.fromLTRB(
    minX - radius,
    minY - radius,
    maxX + radius,
    maxY + radius,
  );
}
