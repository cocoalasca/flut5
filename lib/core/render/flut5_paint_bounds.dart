import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'flut5_render_item.dart';
import 'items/flut5_arc_render_item.dart';
import 'items/flut5_circle_render_item.dart';
import 'items/flut5_ellipse_render_item.dart';
import 'items/flut5_image_render_item.dart';
import 'items/flut5_line_render_item.dart';
import 'items/flut5_multi_line_render_item.dart';
import 'items/flut5_multi_point_render_item.dart';
import 'items/flut5_path_render_item.dart';
import 'items/flut5_rect_render_item.dart';

/// Everything [item] can paint, in its own coordinates: its geometry grown by
/// its stroke's reach, its shadow's offset, spread and halo, and [aa] for edge
/// anti-aliasing. `null` when the extent isn't known up front, as with paints
/// that carry their own filters, so callers must assume it paints anywhere.
///
/// Used wherever a draw may be left out or a layer bounded because of where
/// the draw lands, so it errs on the large side.
Rect? flut5PaintBounds(Flut5RenderItem item, double aa) {
  final ink = item.inkBounds;
  if (ink != null) return ink.inflate(aa);
  final parts = switch (item) {
    RectRenderItem(:final fillPaint, :final strokePaint, :final shadow) ||
    CircleRenderItem(:final fillPaint, :final strokePaint, :final shadow) ||
    EllipseRenderItem(:final fillPaint, :final strokePaint, :final shadow) ||
    ArcRenderItem(:final fillPaint, :final strokePaint, :final shadow) ||
    PathRenderItem(
      :final fillPaint,
      :final strokePaint,
      :final shadow,
    ) => (item.bounds, fillPaint, strokePaint, shadow),
    LineRenderItem(:final strokePaint, :final shadow) => (
      item.bounds,
      null,
      strokePaint,
      shadow,
    ),
    MultiLineRenderItem(:final linePaint, :final shadow) => (
      item.bounds,
      null,
      linePaint,
      shadow,
    ),
    MultiPointRenderItem(:final pointPaint, :final shadow) => (
      item.bounds,
      null,
      pointPaint,
      shadow,
    ),
    ImageRenderItem(:final dst, :final shadow) => (dst, null, null, shadow),
    _ => null,
  };
  if (parts == null) return null;
  final (geometry, fill, stroke, shadow) = parts;
  if (geometry == null) return null;
  for (final p in [fill, stroke]) {
    if (p != null && (p.maskFilter != null || p.imageFilter != null)) {
      return null;
    }
  }
  final box = Rect.fromLTRB(
    math.min(geometry.left, geometry.right),
    math.min(geometry.top, geometry.bottom),
    math.max(geometry.left, geometry.right),
    math.max(geometry.top, geometry.bottom),
  );
  final reach = stroke == null ? 0.0 : _strokeReach(stroke, stroke.strokeWidth);
  var result = box.inflate(reach + aa);
  if (shadow != null) {
    // The shadow redraws the shape shifted by its offset, spread by a stroke
    // of twice the spread (or a stroke that much wider), then blurred.
    final spreadReach = stroke == null
        ? shadow.spread * math.sqrt2
        : _strokeReach(stroke, stroke.strokeWidth + shadow.spread * 2);
    final halo = shadow.blur > 0
        ? 3 * Shadow.convertRadiusToSigma(shadow.blur)
        : 0.0;
    result = result.expandToInclude(
      box
          .shift(shadow.offset)
          .inflate(math.max(reach, spreadReach) + halo + aa),
    );
  }
  return result;
}

/// How far a stroke of [width] painted with [stroke]'s joins and caps can
/// reach past the outline: half its width, out to a miter's tip at sharp
/// corners or a square cap's corner.
double _strokeReach(Paint stroke, double width) =>
    width /
    2 *
    (stroke.strokeJoin == StrokeJoin.miter
        ? math.max(stroke.strokeMiterLimit, math.sqrt2)
        : math.sqrt2);
