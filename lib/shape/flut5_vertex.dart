import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../core/flut5_console.dart';
import '../core/render/flut5_render_queue.dart';
import 'flut5_stroke.dart';
import 'flut5_fill.dart';

// ── Flattened vertex storage ────────────────────────────────────────────
//
// Vertices are recorded into reusable typed buffers instead of one object
// per call: a tight Float64List of coordinate payloads, plus per-vertex type
// tags and payload offsets. A 20k-vertex frame allocates nothing once the
// buffers have grown — clear() keeps capacity — where the previous
// one-object-per-vertex storage churned 20k allocations per frame.

/// Growable typed-buffer storage for one vertex sequence (the main shape or
/// a single contour). Payload layout per type:
///
/// * simple / curve: `[x, y]`
/// * quadratic: `[cx, cy, x3, y3]`
/// * bezier: `[x2, y2, x3, y3, x4, y4]`
class _VertexBuffer {
  static const int typeSimple = 0;
  static const int typeBezier = 1;
  static const int typeQuadratic = 2;
  static const int typeCurve = 3;

  Float64List _coords = Float64List(64);
  Uint8List _types = Uint8List(16);
  Int32List _offsets = Int32List(16);
  int _coordCount = 0;

  /// Number of recorded vertices.
  int count = 0;

  bool get isEmpty => count == 0;
  bool get isNotEmpty => count != 0;

  /// Resets to empty while keeping the backing buffers allocated.
  void clear() {
    count = 0;
    _coordCount = 0;
  }

  void _ensureCapacity(int extraCoords) {
    if (count == _types.length) {
      _types = Uint8List(_types.length * 2)..setRange(0, count, _types);
      _offsets = Int32List(_offsets.length * 2)..setRange(0, count, _offsets);
    }
    final needed = _coordCount + extraCoords;
    if (needed > _coords.length) {
      var len = _coords.length * 2;
      while (len < needed) {
        len *= 2;
      }
      _coords = Float64List(len)..setRange(0, _coordCount, _coords);
    }
  }

  void _addHeader(int type, int coords) {
    _ensureCapacity(coords);
    _types[count] = type;
    _offsets[count] = _coordCount;
    count++;
  }

  void addSimple(double x, double y) {
    _addHeader(typeSimple, 2);
    _coords[_coordCount++] = x;
    _coords[_coordCount++] = y;
  }

  void addCurve(double x, double y) {
    _addHeader(typeCurve, 2);
    _coords[_coordCount++] = x;
    _coords[_coordCount++] = y;
  }

  void addQuadratic(double cx, double cy, double x3, double y3) {
    _addHeader(typeQuadratic, 4);
    _coords[_coordCount++] = cx;
    _coords[_coordCount++] = cy;
    _coords[_coordCount++] = x3;
    _coords[_coordCount++] = y3;
  }

  void addBezier(
    double x2, double y2,
    double x3, double y3,
    double x4, double y4,
  ) {
    _addHeader(typeBezier, 6);
    _coords[_coordCount++] = x2;
    _coords[_coordCount++] = y2;
    _coords[_coordCount++] = x3;
    _coords[_coordCount++] = y3;
    _coords[_coordCount++] = x4;
    _coords[_coordCount++] = y4;
  }

  int typeAt(int i) => _types[i];

  /// The [j]-th payload double of vertex [i] (see the class doc for layouts).
  double coordAt(int i, int j) => _coords[_offsets[i] + j];

  /// Endpoint x of vertex [i] — the anchor a following segment continues from.
  double endX(int i) => switch (_types[i]) {
    typeBezier => _coords[_offsets[i] + 4],
    typeQuadratic => _coords[_offsets[i] + 2],
    _ => _coords[_offsets[i]],
  };

  /// Endpoint y of vertex [i]. See [endX].
  double endY(int i) => switch (_types[i]) {
    typeBezier => _coords[_offsets[i] + 5],
    typeQuadratic => _coords[_offsets[i] + 3],
    _ => _coords[_offsets[i] + 1],
  };
}

/// Shape kind constants for [beginShape].
enum ShapeMode {
  /// Default — connects vertices into a closed or open polygon.
  polygon,

  /// Draws each vertex as an individual point.
  points,

  /// Draws unconnected line segments between pairs of vertices.
  lines,

  /// Draws separate triangles from every three vertices.
  triangles,

  /// Draws a triangle strip — each new vertex forms a triangle with the
  /// previous two.
  triangleStrip,

  /// Draws a triangle fan — all triangles share the first vertex.
  triangleFan,

  /// Draws separate quads from every four vertices.
  quads,

  /// Draws a quad strip — each pair of new vertices forms a quad with the
  /// previous pair.
  quadStrip,
}

/// Vertex-based shape building for the Flut5 Engine.
///
/// Mirrors the p5.js `beginShape` / `vertex` / `endShape` workflow,
/// using Flutter's [Path] under the hood for efficient rendering.
///
/// ```dart
/// flut5.beginShape();
/// flut5.vertex(30, 20);
/// flut5.vertex(85, 20);
/// flut5.vertex(85, 75);
/// flut5.vertex(30, 75);
/// flut5.endShape(close: true);
/// ```
///
/// **Closing behaviour:** When [endShape] is called with `close: true`,
/// `path.close()` draws a **straight line** from the last vertex back to the
/// first — even if the shape uses bezier or curve vertices. This matches
/// p5.js behaviour.
mixin Flut5Vertex on Flut5Stroke, Flut5Fill {
  @override
  Flut5RenderQueue get renderQueue;

  // ── Internal state ────────────────────────────────────────────────────

  final _VertexBuffer _vertices = _VertexBuffer();
  final List<_VertexBuffer> _contours = [];

  /// Recycled contour buffers — a finished contour's storage is reused by
  /// the next [beginContour] instead of reallocating.
  final List<_VertexBuffer> _contourPool = [];
  _VertexBuffer? _activeContour;
  ShapeMode? _shapeMode;
  bool _shapeActive = false;

  // ── Helpers ───────────────────────────────────────────────────────────

  /// Returns finished contour buffers (and any dangling active contour) to
  /// the pool and clears the main vertex buffer, keeping all capacity.
  void _resetShapeBuffers() {
    _vertices.clear();
    for (final c in _contours) {
      c.clear();
      _contourPool.add(c);
    }
    _contours.clear();
    final active = _activeContour;
    if (active != null) {
      active.clear();
      _contourPool.add(active);
      _activeContour = null;
    }
  }

  /// Tight bounding box of the current vertex endpoint coordinates.
  /// Used as the default gradient shader rect when no explicit rect is set.
  Rect _computeVertexBounds() {
    if (_vertices.isEmpty) return Rect.zero;
    double minX = _vertices.endX(0), maxX = minX;
    double minY = _vertices.endY(0), maxY = minY;
    for (int i = 1; i < _vertices.count; i++) {
      final vx = _vertices.endX(i), vy = _vertices.endY(i);
      if (vx < minX) minX = vx; if (vx > maxX) maxX = vx;
      if (vy < minY) minY = vy; if (vy > maxY) maxY = vy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  // ── Public API ────────────────────────────────────────────────────────

  /// Starts recording vertices for a custom shape.
  ///
  /// [mode] sets the vertex interpretation. Defaults to [ShapeMode.polygon].
  void beginShape([ShapeMode mode = .polygon]) {
    _shapeActive = true;
    _shapeMode = mode;
    _resetShapeBuffers();
  }

  /// Adds a vertex at ([x], [y]) to the current shape.
  ///
  /// Must be called between [beginShape] and [endShape].
  void vertex(double x, double y) {
    if (!_shapeActive) {
      Flut5Console.printLater('vertex() called outside beginShape/endShape');
      return;
    }
    (_activeContour ?? _vertices).addSimple(x, y);
  }

  /// Adds a cubic Bezier curve segment to the current shape.
  ///
  /// Uses the previous vertex as the first anchor point.
  /// ([x2],[y2]) and ([x3],[y3]) are the two control points,
  /// ([x4],[y4]) is the end anchor point.
  ///
  /// Must be called after at least one [vertex] call and between
  /// [beginShape] and [endShape]. Only works in polygon mode.
  void bezierVertex(
    double x2, double y2,
    double x3, double y3,
    double x4, double y4,
  ) {
    if (!_shapeActive) {
      Flut5Console.printLater('bezierVertex() called outside beginShape/endShape');
      return;
    }
    final target = _activeContour ?? _vertices;
    if (target.isEmpty) {
      Flut5Console.printLater('vertex() must be used once before calling bezierVertex()');
      return;
    }
    if (_shapeMode != .polygon) {
      Flut5Console.printLater('bezierVertex() only works in polygon mode');
      return;
    }
    target.addBezier(x2, y2, x3, y3, x4, y4);
  }

  /// Adds a quadratic Bezier curve segment to the current shape.
  ///
  /// Uses the previous vertex as the first anchor point.
  /// ([cx],[cy]) is the control point, ([x3],[y3]) is the end anchor point.
  ///
  /// Must be called after at least one [vertex] call and between
  /// [beginShape] and [endShape]. Only works in polygon mode.
  void quadraticVertex(double cx, double cy, double x3, double y3) {
    if (!_shapeActive) {
      Flut5Console.printLater('quadraticVertex() called outside beginShape/endShape');
      return;
    }
    final target = _activeContour ?? _vertices;
    if (target.isEmpty) {
      Flut5Console.printLater('vertex() must be used once before calling quadraticVertex()');
      return;
    }
    if (_shapeMode != .polygon) {
      Flut5Console.printLater('quadraticVertex() only works in polygon mode');
      return;
    }
    target.addQuadratic(cx, cy, x3, y3);
  }

  /// Adds a Catmull-Rom spline vertex at ([x],[y]) to the current shape.
  ///
  /// At least four `curveVertex` calls are needed to draw a visible curve.
  /// The first and last points act as control points that define the curve's
  /// direction but are not drawn through.
  ///
  /// When a curve run appears after regular vertices, the path draws a
  /// straight line to the first anchor (second curve point) — the first
  /// curve point is used only for direction. This matches p5.js behaviour.
  ///
  /// Must be called between [beginShape] and [endShape]. Only works in
  /// polygon mode.
  void curveVertex(double x, double y) {
    if (!_shapeActive) {
      Flut5Console.printLater('curveVertex() called outside beginShape/endShape');
      return;
    }
    if (_shapeMode != .polygon) {
      Flut5Console.printLater('curveVertex() only works in polygon mode');
      return;
    }
    (_activeContour ?? _vertices).addCurve(x, y);
  }

  /// Begins a contour (hole) inside the current shape.
  ///
  /// Contour vertices should wind in the opposite direction from the outer
  /// shape. Must be called between [beginShape] and [endShape].
  /// Only works in polygon mode.
  void beginContour() {
    if (!_shapeActive) {
      Flut5Console.printLater('beginContour() called outside beginShape/endShape');
      return;
    }
    if (_shapeMode != .polygon) {
      Flut5Console.printLater('beginContour() only works in polygon mode');
      return;
    }
    // A dangling previous contour (beginContour twice with no endContour) is
    // discarded, matching the previous behavior; its buffer is recycled.
    final dangling = _activeContour;
    if (dangling != null) {
      dangling.clear();
      _contourPool.add(dangling);
    }
    _activeContour = _contourPool.isNotEmpty
        ? _contourPool.removeLast()
        : _VertexBuffer();
  }

  /// Ends the current contour and saves its vertices.
  void endContour() {
    final active = _activeContour;
    if (active == null) {
      Flut5Console.printLater('endContour() called without beginContour()');
      return;
    }
    if (active.isNotEmpty) {
      _contours.add(active);
    } else {
      _contourPool.add(active);
    }
    _activeContour = null;
  }

  /// Stops recording and enqueues the shape for rendering.
  ///
  /// If [close] is `true`, the first and last vertex are connected with a
  /// straight line via `path.close()`.
  void endShape({bool close = false}) {
    if (!_shapeActive) {
      Flut5Console.printLater('endShape() called without beginShape()');
      return;
    }
    _shapeActive = false;

    if (_vertices.isEmpty) return;

    // Batch mode — build directly into the shared batch path.
    if (batchPath != null) {
      _buildBatchShape(close);
      markBatchDirty();
      _resetShapeBuffers();
      return;
    }

    // Build gradient shader against the vertex bounding box; falls back to
    // the normal snapshot (and canvas-size rect) for solid colors or when the
    // user has set an explicit gradient rect.
    final bounds = _computeVertexBounds();
    final Paint? fill = snapshotFillPaintForShape(bounds);
    final Paint? stroke = snapshotStrokePaintForShape(bounds);

    switch (_shapeMode!) {
      case .points:
        _drawPoints(stroke);
      case .lines:
        _drawLines(stroke);
      case .triangles:
        _drawTriangles(fill, stroke);
      case .triangleStrip:
        _drawTriangleStrip(fill, stroke);
      case .triangleFan:
        _drawTriangleFan(fill, stroke);
      case .quads:
        _drawQuads(fill, stroke);
      case .quadStrip:
        _drawQuadStrip(fill, stroke);
      case .polygon:
        _drawPolygon(fill, stroke, close);
    }

    _resetShapeBuffers();
  }

  /// Builds the current shape directly into [batchPath].
  void _buildBatchShape(bool close) {
    final bp = batchPath!;
    final v = _vertices;
    switch (_shapeMode!) {
      case .polygon:
        _buildPath(bp, v, close);
        for (final contour in _contours) {
          _buildPath(bp, contour, true);
        }
      case .points:
        final radius = strokeWeightVal;
        for (int i = 0; i < v.count; i++) {
          bp.addOval(Rect.fromCenter(
            center: Offset(v.endX(i), v.endY(i)),
            width: radius,
            height: radius,
          ));
        }
      case .lines:
        for (int i = 0; i + 1 < v.count; i += 2) {
          bp.moveTo(v.endX(i), v.endY(i));
          bp.lineTo(v.endX(i + 1), v.endY(i + 1));
        }
      case .triangles:
        for (int i = 0; i + 2 < v.count; i += 3) {
          bp.moveTo(v.endX(i), v.endY(i));
          bp.lineTo(v.endX(i + 1), v.endY(i + 1));
          bp.lineTo(v.endX(i + 2), v.endY(i + 2));
          bp.close();
        }
      case .triangleStrip:
        for (int i = 0; i + 2 < v.count; i++) {
          bp.moveTo(v.endX(i), v.endY(i));
          bp.lineTo(v.endX(i + 1), v.endY(i + 1));
          bp.lineTo(v.endX(i + 2), v.endY(i + 2));
          bp.close();
        }
      case .triangleFan:
        final cx = v.endX(0);
        final cy = v.endY(0);
        for (int i = 1; i + 1 < v.count; i++) {
          bp.moveTo(cx, cy);
          bp.lineTo(v.endX(i), v.endY(i));
          bp.lineTo(v.endX(i + 1), v.endY(i + 1));
          bp.close();
        }
      case .quads:
        for (int i = 0; i + 3 < v.count; i += 4) {
          bp.moveTo(v.endX(i), v.endY(i));
          bp.lineTo(v.endX(i + 1), v.endY(i + 1));
          bp.lineTo(v.endX(i + 2), v.endY(i + 2));
          bp.lineTo(v.endX(i + 3), v.endY(i + 3));
          bp.close();
        }
      case .quadStrip:
        for (int i = 0; i + 3 < v.count; i += 2) {
          bp.moveTo(v.endX(i), v.endY(i));
          bp.lineTo(v.endX(i + 1), v.endY(i + 1));
          bp.lineTo(v.endX(i + 3), v.endY(i + 3));
          bp.lineTo(v.endX(i + 2), v.endY(i + 2));
          bp.close();
        }
    }
  }

  // ── Path builder (polygon mode) ──────────────────────────────────────

  /// Builds a [Path] from a recorded vertex sequence.
  void _buildPath(Path path, _VertexBuffer verts, bool close) {
    if (verts.isEmpty) return;

    int i = 0;

    // Move to the first point.
    path.moveTo(verts.endX(0), verts.endY(0));

    // If the first entry is a curve vertex, handle the entire run of curves.
    if (verts.typeAt(0) == _VertexBuffer.typeCurve) {
      final runStart = i;
      while (i < verts.count && verts.typeAt(i) == _VertexBuffer.typeCurve) {
        i++;
      }
      _addCatmullRomRun(path, verts, runStart, i - runStart, isFirst: true);
    } else {
      i = 1;
    }

    // Process remaining vertices.
    while (i < verts.count) {
      switch (verts.typeAt(i)) {
        case _VertexBuffer.typeSimple:
          path.lineTo(verts.coordAt(i, 0), verts.coordAt(i, 1));
          i++;
        case _VertexBuffer.typeBezier:
          path.cubicTo(
            verts.coordAt(i, 0), verts.coordAt(i, 1),
            verts.coordAt(i, 2), verts.coordAt(i, 3),
            verts.coordAt(i, 4), verts.coordAt(i, 5),
          );
          i++;
        case _VertexBuffer.typeQuadratic:
          path.quadraticBezierTo(
            verts.coordAt(i, 0), verts.coordAt(i, 1),
            verts.coordAt(i, 2), verts.coordAt(i, 3),
          );
          i++;
        case _VertexBuffer.typeCurve:
          final runStart = i;
          while (i < verts.count &&
              verts.typeAt(i) == _VertexBuffer.typeCurve) {
            i++;
          }
          _addCatmullRomRun(path, verts, runStart, i - runStart, isFirst: false);
      }
    }

    if (close) path.close();
  }

  /// Converts a run of Catmull-Rom points (vertices `start .. start + count
  /// - 1` of [verts], all curve-typed) to cubic Bezier segments on [path].
  ///
  /// For N points, draws N-3 segments. Each segment uses 4 consecutive points:
  /// P0, P1, P2, P3 — the curve is drawn between P1 and P2.
  ///
  /// If [isFirst] is true, the path is moved to the first drawn point (P1)
  /// since the initial moveTo may have been to P0 (a control point).
  void _addCatmullRomRun(
    Path path,
    _VertexBuffer verts,
    int start,
    int count, {
    required bool isFirst,
  }) {
    if (count < 4) {
      Flut5Console.printLater(
        'curveVertex() needs at least 4 points to draw a curve (got $count)',
      );
      return;
    }

    double px(int k) => verts.coordAt(start + k, 0);
    double py(int k) => verts.coordAt(start + k, 1);

    // Move/line to the first anchor point (pts[1]), not the control point (pts[0]).
    if (isFirst) {
      path.moveTo(px(1), py(1));
    } else {
      path.lineTo(px(1), py(1));
    }

    for (int i = 0; i + 3 < count; i++) {
      final p0x = px(i), p0y = py(i);
      final p1x = px(i + 1), p1y = py(i + 1);
      final p2x = px(i + 2), p2y = py(i + 2);
      final p3x = px(i + 3), p3y = py(i + 3);

      // Catmull-Rom → cubic Bezier control points (tightness = 0)
      final cp1x = p1x + (p2x - p0x) / 6;
      final cp1y = p1y + (p2y - p0y) / 6;
      final cp2x = p2x - (p3x - p1x) / 6;
      final cp2y = p2y - (p3y - p1y) / 6;

      path.cubicTo(cp1x, cp1y, cp2x, cp2y, p2x, p2y);
    }
  }

  // ── Shape-mode renderers ──────────────────────────────────────────────

  void _drawPolygon(Paint? fill, Paint? stroke, bool close) {
    final path = Path();
    _buildPath(path, _vertices, close);

    // Add contour holes
    for (final contour in _contours) {
      _buildPath(path, contour, true);
    }

    renderQueue.appendShapePath(path, fill, stroke);
  }

  void _drawPoints(Paint? stroke) {
    if (stroke == null || _vertices.isEmpty) return;
    final pointPaint = snapshotPointPaint();
    if (pointPaint == null) return;
    final coords = Float32List(_vertices.count * 2);
    for (int i = 0; i < _vertices.count; i++) {
      coords[i * 2]     = _vertices.endX(i);
      coords[i * 2 + 1] = _vertices.endY(i);
    }
    renderQueue.appendPoints(coords, pointPaint);
  }

  void _drawLines(Paint? stroke) {
    if (stroke == null) return;
    for (int i = 0; i + 1 < _vertices.count; i += 2) {
      renderQueue.appendLine(
        _vertices.endX(i), _vertices.endY(i),
        _vertices.endX(i + 1), _vertices.endY(i + 1),
        stroke,
      );
    }
  }

  void _drawTriangles(Paint? fill, Paint? stroke) {
    final path = Path();
    for (int i = 0; i + 2 < _vertices.count; i += 3) {
      path.moveTo(_vertices.endX(i), _vertices.endY(i));
      path.lineTo(_vertices.endX(i + 1), _vertices.endY(i + 1));
      path.lineTo(_vertices.endX(i + 2), _vertices.endY(i + 2));
      path.close();
    }
    renderQueue.appendShapePath(path, fill, stroke);
  }

  void _drawTriangleStrip(Paint? fill, Paint? stroke) {
    final path = Path();
    for (int i = 0; i + 2 < _vertices.count; i++) {
      path.moveTo(_vertices.endX(i), _vertices.endY(i));
      path.lineTo(_vertices.endX(i + 1), _vertices.endY(i + 1));
      path.lineTo(_vertices.endX(i + 2), _vertices.endY(i + 2));
      path.close();
    }
    renderQueue.appendShapePath(path, fill, stroke);
  }

  void _drawTriangleFan(Paint? fill, Paint? stroke) {
    final path = Path();
    final cx = _vertices.endX(0);
    final cy = _vertices.endY(0);
    for (int i = 1; i + 1 < _vertices.count; i++) {
      path.moveTo(cx, cy);
      path.lineTo(_vertices.endX(i), _vertices.endY(i));
      path.lineTo(_vertices.endX(i + 1), _vertices.endY(i + 1));
      path.close();
    }
    renderQueue.appendShapePath(path, fill, stroke);
  }

  void _drawQuads(Paint? fill, Paint? stroke) {
    final path = Path();
    for (int i = 0; i + 3 < _vertices.count; i += 4) {
      path.moveTo(_vertices.endX(i), _vertices.endY(i));
      path.lineTo(_vertices.endX(i + 1), _vertices.endY(i + 1));
      path.lineTo(_vertices.endX(i + 2), _vertices.endY(i + 2));
      path.lineTo(_vertices.endX(i + 3), _vertices.endY(i + 3));
      path.close();
    }
    renderQueue.appendShapePath(path, fill, stroke);
  }

  void _drawQuadStrip(Paint? fill, Paint? stroke) {
    final path = Path();
    for (int i = 0; i + 3 < _vertices.count; i += 2) {
      path.moveTo(_vertices.endX(i), _vertices.endY(i));
      path.lineTo(_vertices.endX(i + 1), _vertices.endY(i + 1));
      path.lineTo(_vertices.endX(i + 3), _vertices.endY(i + 3));
      path.lineTo(_vertices.endX(i + 2), _vertices.endY(i + 2));
      path.close();
    }
    renderQueue.appendShapePath(path, fill, stroke);
  }
}
