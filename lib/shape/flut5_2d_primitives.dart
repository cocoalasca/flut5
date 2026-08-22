import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../core/flut5_console.dart';
import '../core/render/flut5_render_queue.dart';
import '../math/flut5_trigonometry.dart';
import 'flut5_stroke.dart';
import 'flut5_fill.dart';

/// 2D primitive shape drawing for the Flut5 Engine.
///
/// All shapes respect the current [fill] and [stroke] state. Call [noFill] or
/// [noStroke] to disable either. Coordinates use Flutter's top-left origin.
mixin Flut52DPrimitives on Flut5Stroke, Flut5Fill, Flut5Trigonometry {
  @override
  Canvas get canvas;

  // All snapshot caches now live on Flut5Fill/Flut5Stroke (shared with the
  // vertex API) so consecutive same-state draws batch by paint identity.
  Paint _pointPaintSnapshot() => snapshotPointPaint()!;
  Paint? _linePaintForBounds(Rect bounds) => snapshotStrokePaintForShape(bounds);

  // Shape-bounds-aware variants: when a gradient with no explicit rect is
  // active the shader is built against the shape's own bounding box instead
  // of the full canvas.
  Paint? _queuedFillForBounds(Rect bounds) => snapshotFillPaintForShape(bounds);
  Paint? _queuedStrokeForBounds(Rect bounds) => snapshotStrokePaintForShape(bounds);

  // ---------------------------------------------------------------------------
  // Ellipse & Circle
  // ---------------------------------------------------------------------------

  /// Draws an ellipse centered at ([x], [y]) with the given [width] and [height].
  /// ```dart
  /// flut5.ellipse(100, 200, 80, 40);
  /// ```
  void ellipse(double x, double y, double width, double height) {
    final rect = Rect.fromCenter(
      center: Offset(x, y),
      width: width,
      height: height,
    );
    if (batchPath != null) {
      batchPath!.addOval(rect);
      markBatchDirty();
      return;
    }
    renderQueue.appendEllipse(rect, _queuedFillForBounds(rect), _queuedStrokeForBounds(rect));
  }

  /// Draws a circle centered at ([x], [y]) with diameter [d].
  /// ```dart
  /// flut5.circle(100, 200, 50); // diameter 50
  /// ```
  void circle(double x, double y, double d) {
    if (batchPath != null) {
      batchPath!.addOval(Rect.fromCenter(
        center: Offset(x, y), width: d, height: d,
      ));
      markBatchDirty();
      return;
    }
    final radius = d / 2;
    final bounds = Rect.fromCircle(center: Offset(x, y), radius: radius);
    renderQueue.appendCircle(Offset(x, y), radius, _queuedFillForBounds(bounds), _queuedStrokeForBounds(bounds));
  }

  // ---------------------------------------------------------------------------
  // Point & Line
  // ---------------------------------------------------------------------------

  /// Draws a single point at ([x], [y]). Size is controlled by [strokeWeight].
  /// ```dart
  /// flut5.point(100, 200);
  /// ```
  ///
  /// Points are auto-coalesced: consecutive [point] calls share a buffer that
  /// the render queue flushes as a single [Canvas.drawRawPoints] call. Any
  /// other primitive, transform, or state change flushes the buffer first, so
  /// z-order is preserved. [beginBatch] / [endBatch] route through their own
  /// buffer and emit the same way.
  void point(double x, double y) {
    if (strokeColor == Colors.transparent) return;
    final points = batchPoints;
    if (points != null) {
      points..add(x)..add(y);
      return;
    }
    renderQueue.appendPoint(x, y, _pointPaintSnapshot());
  }

  /// Draws a line from ([x1], [y1]) to ([x2], [y2]).
  /// ```dart
  /// flut5.line(0, 0, 100, 100);
  /// ```
  void line(double x1, double y1, double x2, double y2) {
    if (batchPath != null) {
      batchPath!.moveTo(x1, y1);
      batchPath!.lineTo(x2, y2);
      markBatchDirty();
      return;
    }
    if (strokeColor == Colors.transparent) return;
    final minX = x1 < x2 ? x1 : x2;
    final maxX = x1 > x2 ? x1 : x2;
    final minY = y1 < y2 ? y1 : y2;
    final maxY = y1 > y2 ? y1 : y2;
    final bounds = Rect.fromLTRB(minX, minY, maxX, maxY);
    renderQueue.appendLine(x1, y1, x2, y2, _linePaintForBounds(bounds)!);
  }

  // ---------------------------------------------------------------------------
  // Rect & Square
  // ---------------------------------------------------------------------------

  /// Draws a rectangle with its top-left corner at ([x], [y]).
  ///
  /// Optionally round corners with [tl] (top-left), [tr] (top-right),
  /// [br] (bottom-right), [bl] (bottom-left) radii. If only [tl] is provided,
  /// it applies to all four corners.
  /// ```dart
  /// flut5.rect(10, 10, 80, 40);
  /// flut5.rect(10, 10, 80, 40, 8);        // uniform 8px radius
  /// flut5.rect(10, 10, 80, 40, 8, 0, 8, 0); // per-corner radii
  /// ```
  void rect(
    double x,
    double y,
    double w,
    double h, [
    double? tl,
    double? tr,
    double? br,
    double? bl,
  ]) {
    if (batchPath != null) {
      if (tl != null || tr != null || br != null || bl != null) {
        Radius rad(double? r) => Radius.circular(r ?? 0.0);
        batchPath!.addRRect(RRect.fromRectAndCorners(
          Rect.fromLTWH(x, y, w, h),
          topLeft: rad(tl),
          topRight: rad(tr ?? tl),
          bottomRight: rad(br ?? tl),
          bottomLeft: rad(bl ?? tl),
        ));
      } else {
        batchPath!.addRect(Rect.fromLTWH(x, y, w, h));
      }
      markBatchDirty();
      return;
    }

    final bounds = Rect.fromLTWH(x, y, w, h);
    final fill = _queuedFillForBounds(bounds);
    final stroke = _queuedStrokeForBounds(bounds);

    if (tl != null || tr != null || br != null || bl != null) {
      Radius rad(double? r) => Radius.circular(r ?? 0.0);
      final rrect = RRect.fromRectAndCorners(
        bounds,
        topLeft: rad(tl),
        topRight: rad(tr ?? tl),
        bottomRight: rad(br ?? tl),
        bottomLeft: rad(bl ?? tl),
      );
      renderQueue.appendRect(Rect.zero, rrect, fill, stroke);
    } else {
      renderQueue.appendRect(bounds, null, fill, stroke);
    }
  }

  /// Draws a square with its top-left corner at ([x], [y]) and side length [s].
  ///
  /// Supports the same optional corner radii as [rect].
  /// ```dart
  /// flut5.square(10, 10, 60);
  /// flut5.square(10, 10, 60, 8); // rounded corners
  /// ```
  void square(
    double x,
    double y,
    double s, [
    double? tl,
    double? tr,
    double? br,
    double? bl,
  ]) {
    rect(x, y, s, s, tl, tr, br, bl);
  }

  // ---------------------------------------------------------------------------
  // Triangle
  // ---------------------------------------------------------------------------

  /// Draws a triangle through three points.
  /// ```dart
  /// flut5.triangle(50, 10, 10, 90, 90, 90);
  /// ```
  void triangle(
    double x1, double y1,
    double x2, double y2,
    double x3, double y3,
  ) {
    if (batchPath != null) {
      batchPath!.moveTo(x1, y1);
      batchPath!.lineTo(x2, y2);
      batchPath!.lineTo(x3, y3);
      batchPath!.close();
      markBatchDirty();
      return;
    }
    double minX = x1, maxX = x1;
    if (x2 < minX) minX = x2; if (x2 > maxX) maxX = x2;
    if (x3 < minX) minX = x3; if (x3 > maxX) maxX = x3;
    double minY = y1, maxY = y1;
    if (y2 < minY) minY = y2; if (y2 > maxY) maxY = y2;
    if (y3 < minY) minY = y3; if (y3 > maxY) maxY = y3;
    final bounds = Rect.fromLTRB(minX, minY, maxX, maxY);
    renderQueue.appendTriangle(
      x1, y1, x2, y2, x3, y3,
      _queuedFillForBounds(bounds),
      _queuedStrokeForBounds(bounds),
    );
  }

  // ---------------------------------------------------------------------------
  // Quad
  // ---------------------------------------------------------------------------

  /// Draws a quadrilateral through four points (in order — CW or CCW).
  /// ```dart
  /// flut5.quad(10, 10, 90, 20, 85, 80, 15, 70);
  /// ```
  void quad(
    double x1, double y1,
    double x2, double y2,
    double x3, double y3,
    double x4, double y4,
  ) {
    if (batchPath != null) {
      batchPath!.moveTo(x1, y1);
      batchPath!.lineTo(x2, y2);
      batchPath!.lineTo(x3, y3);
      batchPath!.lineTo(x4, y4);
      batchPath!.close();
      markBatchDirty();
      return;
    }
    double minX = x1, maxX = x1;
    if (x2 < minX) minX = x2; if (x2 > maxX) maxX = x2;
    if (x3 < minX) minX = x3; if (x3 > maxX) maxX = x3;
    if (x4 < minX) minX = x4; if (x4 > maxX) maxX = x4;
    double minY = y1, maxY = y1;
    if (y2 < minY) minY = y2; if (y2 > maxY) maxY = y2;
    if (y3 < minY) minY = y3; if (y3 > maxY) maxY = y3;
    if (y4 < minY) minY = y4; if (y4 > maxY) maxY = y4;
    final bounds = Rect.fromLTRB(minX, minY, maxX, maxY);
    renderQueue.appendQuad(
      x1, y1, x2, y2, x3, y3, x4, y4,
      _queuedFillForBounds(bounds),
      _queuedStrokeForBounds(bounds),
    );
  }

  // ---------------------------------------------------------------------------
  // Polygon
  // ---------------------------------------------------------------------------

  /// Draws a regular polygon with [sides] vertices centered at ([x], [y]),
  /// inscribed in a circle of diameter [d]. The first vertex points up; use
  /// [rotate] to change the orientation.
  /// ```dart
  /// flut5.polygon(100, 100, 6, 80); // hexagon, 80px across
  /// ```
  void polygon(double x, double y, int sides, double d) {
    if (sides < 3) {
      Flut5Console.printLater('polygon() needs at least 3 sides');
      return;
    }
    final radius = d / 2;
    if (batchPath != null) {
      const start = -math.pi / 2;
      final step = 2 * math.pi / sides;
      batchPath!.moveTo(x, y - radius);
      for (int i = 1; i < sides; i++) {
        final a = start + i * step;
        batchPath!.lineTo(x + radius * math.cos(a), y + radius * math.sin(a));
      }
      batchPath!.close();
      markBatchDirty();
      return;
    }
    // Gradient bounds use the circumscribed circle, like arc() does with its
    // full oval rect, rather than the exact vertex extents.
    final bounds = Rect.fromCircle(center: Offset(x, y), radius: radius);
    renderQueue.appendRegularPolygon(
      x, y, radius, sides,
      _queuedFillForBounds(bounds),
      _queuedStrokeForBounds(bounds),
    );
  }

  // ---------------------------------------------------------------------------
  // Star
  // ---------------------------------------------------------------------------

  /// Draws a star with [points] outer points centered at ([x], [y]). Outer
  /// vertices sit on a circle of diameter [outerDiameter], the notches
  /// between them on [innerDiameter]. The first point faces up; use [rotate]
  /// to change the orientation.
  /// ```dart
  /// flut5.star(100, 100, 30, 80, 5); // classic 5-pointed star
  /// ```
  void star(
    double x,
    double y,
    double innerDiameter,
    double outerDiameter,
    int points,
  ) {
    if (points < 3) {
      Flut5Console.printLater('star() needs at least 3 points');
      return;
    }
    final innerRadius = innerDiameter / 2;
    final outerRadius = outerDiameter / 2;
    if (batchPath != null) {
      const start = -math.pi / 2;
      final step = math.pi / points;
      final n = points * 2;
      batchPath!.moveTo(x, y - outerRadius);
      for (int i = 1; i < n; i++) {
        final r = i.isEven ? outerRadius : innerRadius;
        final a = start + i * step;
        batchPath!.lineTo(x + r * math.cos(a), y + r * math.sin(a));
      }
      batchPath!.close();
      markBatchDirty();
      return;
    }
    // Gradient bounds use the outer circumscribed circle, like polygon().
    final bounds = Rect.fromCircle(center: Offset(x, y), radius: outerRadius);
    renderQueue.appendStar(
      x, y, innerRadius, outerRadius, points,
      _queuedFillForBounds(bounds),
      _queuedStrokeForBounds(bounds),
    );
  }

  // ---------------------------------------------------------------------------
  // Arc
  // ---------------------------------------------------------------------------

  /// Draws an arc centered at ([x], [y]) with bounding box [w] × [h].
  ///
  /// [start] and [stop] angles respect the current [AngleMode].
  /// [mode] controls how the arc is closed: [ArcMode.open] (default),
  /// [ArcMode.chord], or [ArcMode.pie].
  /// ```dart
  /// flut5.arc(100, 100, 80, 80, 0, pi);           // open half-circle
  /// flut5.arc(100, 100, 80, 80, 0, pi, ArcMode.pie); // pie slice
  /// ```
  void arc(
    double x,
    double y,
    double w,
    double h,
    double start,
    double stop, [
    ArcMode mode = .open,
  ]) {
    final rect = Rect.fromCenter(center: Offset(x, y), width: w, height: h);
    final radStart = toRadians(start);
    final radStop = toRadians(stop);
    final sweepAngle = radStop - radStart;

    if (batchPath != null) {
      switch (mode) {
        case .open:
          batchPath!.arcTo(rect, radStart, sweepAngle, true);
        case .chord:
          batchPath!.arcTo(rect, radStart, sweepAngle, true);
          batchPath!.close();
        case .pie:
          batchPath!.moveTo(x, y);
          batchPath!.arcTo(rect, radStart, sweepAngle, false);
          batchPath!.close();
      }
      markBatchDirty();
      return;
    }

    final fill = _queuedFillForBounds(rect);
    final stroke = _queuedStrokeForBounds(rect);

    switch (mode) {
      case .open:
        renderQueue.appendArc(rect, radStart, sweepAngle, false, fill, stroke);

      case .chord:
        final path = Path()..arcTo(rect, radStart, sweepAngle, true)..close();
        renderQueue.enqueue(PathRenderItem(path, fill, stroke));

      case .pie:
        renderQueue.appendArc(rect, radStart, sweepAngle, true, fill, stroke);
    }
  }
}

/// Controls how an arc is closed.
enum ArcMode {
  /// Ends left open — stroke does not connect the two endpoints.
  open,

  /// Connects the two endpoints with a straight line (chord).
  chord,

  /// Connects both endpoints to the center, forming a pie slice.
  pie,
}
