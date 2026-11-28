import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';

import '../flut5_render_item.dart';
import '../flut5_rect_outline.dart';

/// A batch of plain stroked rects — a `beginBatch()` batch, or a run of at
/// least 16 rects in an automatic one — whose edges merge into a few long
/// lines ([Flut5RectBatchGeometry.outline]): a grid of 30,000 cells is 352
/// lines.
///
/// Impeller only, and only while everything between the sketch and the
/// screen keeps the rects upright: the engine checks the canvas widget's
/// place on screen before queueing this ([linesAllowed],
/// `Flut5Engine.screenUpright`), and [execute] checks the sketch's own
/// transforms on the canvas. Under those conditions the lines measured
/// byte-identical to the rects for grids, fractional grids, scattered and
/// nested rects, stroke widths 0.5–3.3, opaque and translucent, at 1×, 1.5×
/// and 2×. Rotated, the two tessellate their edges differently, so the
/// rects' own path is stroked instead.
///
/// Skia (the web, desktops without Impeller) never draws the lines: it
/// draws a stroke of one device pixel or less as hairlines, which paint a
/// shared edge once per rect, so a grid's walls come out brighter as rects
/// than as lines. And a frame's foreground is recorded once and drawn both
/// on screen and into the trail snapshot at another scale, so whether a
/// stroke is that thin can't be known when it is recorded.
///
/// Measured on Demo 11's 30,000-cell grid (Metal, 800×600 at 2×): raster
/// 5.3 → 0.65 ms, trail capture 5.3 → 0.62 ms.
class RectOutlineRenderItem(
  final Flut5RectBatchGeometry geometry,
  final Paint? fillPaint,
  final Paint strokePaint,
) extends Flut5RenderItem {
  @override
  Rect? get bounds => geometry.bounds;

  @override
  bool get keepsCanvasTransform => true;

  static final bool _impeller = ui.ImageFilter.isShaderFilterSupported;

  /// Forces [linesAllowed] on or off regardless of backend, or restores
  /// detection with `null`. Test seam: `flutter test` runs Skia unless
  /// `--enable-impeller` is passed.
  @visibleForTesting
  static bool? debugImpeller;

  /// Whether this backend draws the lines at all — Impeller.
  static bool get linesAllowed => debugImpeller ?? _impeller;

  /// Whether rects stroked with [stroke] can be drawn as their edges' lines:
  /// a real (non-hairline) stroke with mitered corners — a 90° miter is the
  /// square a square cap adds — and no mask or image filter.
  static bool strokes(Paint stroke) =>
      stroke.style == PaintingStyle.stroke &&
      stroke.strokeWidth > 0 &&
      stroke.strokeJoin == StrokeJoin.miter &&
      // The default limit (4) miters a 90° corner, which needs √2. Compared
      // with a default paint's rather than with a number: natively the
      // getter returns the limit's offset from that default (0 for 4), on
      // the web the limit itself.
      stroke.strokeMiterLimit == _defaultMiterLimit &&
      stroke.maskFilter == null &&
      stroke.imageFilter == null;

  static final double _defaultMiterLimit = Paint().strokeMiterLimit;

  // Line paints are immutable once queued, so the same stroke shares one.
  static Paint? _lineStrokeSource;
  static Paint? _lineStrokeMemo;

  /// [strokePaint] with square caps, for the lines.
  Paint get _lineStroke {
    if (identical(strokePaint, _lineStrokeSource)) return _lineStrokeMemo!;
    _lineStrokeSource = strokePaint;
    return _lineStrokeMemo = Paint()
      ..style = PaintingStyle.stroke
      ..color = strokePaint.color
      ..blendMode = strokePaint.blendMode
      ..isAntiAlias = strokePaint.isAntiAlias
      ..invertColors = strokePaint.invertColors
      ..shader = strokePaint.shader
      ..colorFilter = strokePaint.colorFilter
      ..filterQuality = strokePaint.filterQuality
      ..strokeWidth = strokePaint.strokeWidth
      ..strokeCap = StrokeCap.square;
  }

  @override
  void execute(Canvas canvas) {
    if (fillPaint != null) canvas.drawPath(geometry.rects, fillPaint!);
    final outline = geometry.outline;
    if (outline != null && _upright(canvas.getTransform())) {
      canvas.drawPath(outline, _lineStroke);
    } else {
      canvas.drawPath(geometry.rects, strokePaint);
    }
  }

  /// Whether [m] keeps rects upright: no rotation, skew or perspective.
  static bool _upright(Float64List m) =>
      m[1] == 0 && m[4] == 0 && m[3] == 0 && m[7] == 0 && m[15] == 1;
}
