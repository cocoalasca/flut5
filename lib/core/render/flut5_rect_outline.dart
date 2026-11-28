import 'dart:typed_data';
import 'dart:ui';

/// The geometry of one batch made only of plain rects — a `beginBatch()`
/// batch or a long run of rects in an automatic one — kept by the render
/// queue from one frame to the next.
///
/// A batch that draws the same rects as last frame (a grid, a tile map, a
/// board) gets this frame the same [rects] path, and the same [outline],
/// instead of new ones: no path is rebuilt, and on the web Skia reuses the
/// work it cached for the path last frame (measured 2.5× faster there for a
/// 26,000-cell grid).
final class Flut5RectBatchGeometry._(
  /// The rects this geometry was built from, four doubles each (left, top,
  /// right, bottom, as given — not sorted) — what the next frame's batch is
  /// compared against.
  final Float64List _source,

  /// Doubles used in [_source].
  final int length,

  /// Every rect, in drawing order: the batch's fill, and its stroke wherever
  /// [outline] can't stand in for it.
  final Path rects,
) {
  /// [rects]' bounds, worked out once for the life of the geometry rather
  /// than by every frame's render item.
  late final Rect bounds = rects.getBounds();

  /// The union of the rects' edges as long lines, when merging them was
  /// worth it — see [Flut5RectOutline]. `null` until asked for, and when it
  /// would not have saved enough.
  Path? outline;

  /// [outline]'s lines, four floats each (x0, y0, x1, y1), as the path holds
  /// them. Read by the replay to check whether the lines land on whole
  /// device pixels.
  Float32List? outlineLines;

  /// Whether merging was already tried for this geometry, so a batch whose
  /// edges don't merge doesn't retry every frame.
  bool outlineTried = false;

  /// Whether [rects] is the geometry of the [length] doubles in [source].
  bool matches(Float64List source, int length) {
    if (length != this.length) return false;
    final own = _source;
    for (var i = 0; i < length; i++) {
      if (own[i] != source[i]) return false;
    }
    return true;
  }

  /// Builds the geometry of the first [length] doubles of [source].
  factory Flut5RectBatchGeometry.of(Float64List source, int length) {
    final copy = Float64List(length)..setRange(0, length, source);
    final path = Path();
    for (var i = 0; i < length; i += 4) {
      path.addRect(
        Rect.fromLTRB(copy[i], copy[i + 1], copy[i + 2], copy[i + 3]),
      );
    }
    return Flut5RectBatchGeometry._(copy, length, path);
  }

  /// Fills in [outline] when merging the edges pays: at most half as many
  /// lines as the rects have edges.
  void buildOutline(Flut5RectOutline merger) {
    if (outlineTried) return;
    outlineTried = true;
    final lines = merger.merge(_source, length);
    if (lines == null) return;
    final path = Path();
    for (var i = 0; i < lines.length; i += 4) {
      path
        ..moveTo(lines[i], lines[i + 1])
        ..lineTo(lines[i + 2], lines[i + 3]);
    }
    outline = path;
    outlineLines = lines;
  }
}

/// Merges the edges of axis-aligned rects into the long lines they form.
///
/// A stroked rect with mitered corners covers exactly what its four edges
/// cover when each is stroked with square caps: a 90° miter is the square a
/// cap adds. So the stroke of many rects is the stroke of their edges, and
/// edges that lie on one line and overlap or touch — the shared walls of a
/// grid, the nested cells of a quadtree — can be stroked as one line. A
/// 200×150 grid is 120,000 edges and 352 lines.
///
/// One pass in drawing order: each line keeps one open segment, an edge that
/// starts inside or at the end of it extends it, and any other edge closes
/// it. Rects drawn row by row or column by column merge completely; in an
/// order that doesn't line up, segments are left unmerged, which is never
/// wrong — the lines are stroked together as one path, so overlapping
/// segments cover what one would.
///
/// Coordinates are compared as 32-bit floats, the precision a path stores,
/// so `x + width` of one cell and `x` of the next, which can differ in the
/// last bit of a double, still meet.
final class Flut5RectOutline() {
  final _LineTable _horizontal = _LineTable();
  final _LineTable _vertical = _LineTable();
  final Float32List _f32 = Float32List(1);

  @pragma('vm:prefer-inline')
  double _single(double v) {
    _f32[0] = v;
    return _f32[0];
  }

  /// The merged lines of the rects in [rects] (four doubles each: left, top,
  /// right, bottom), four floats per line (x0, y0, x1, y1), or `null` when
  /// they don't come to at most half the rects' edges — or when a rect has
  /// no width or height: its stroke is a line without the corner squares
  /// the caps would add.
  Float32List? merge(Float64List rects, int length) {
    final edges = length; // four edges per rect, four doubles per rect
    final limit = edges ~/ 2;
    _horizontal.reset();
    _vertical.reset();
    for (var i = 0; i < length; i += 4) {
      final x0 = rects[i], y0 = rects[i + 1];
      final x1 = rects[i + 2], y1 = rects[i + 3];
      if (!(x0 != x1 && y0 != y1 && (x0 + x1 + y0 + y1).isFinite)) {
        return null;
      }
      final left = _single(x0 < x1 ? x0 : x1);
      final right = _single(x0 < x1 ? x1 : x0);
      final top = _single(y0 < y1 ? y0 : y1);
      final bottom = _single(y0 < y1 ? y1 : y0);
      _horizontal.add(top, left, right);
      _horizontal.add(bottom, left, right);
      _vertical.add(left, top, bottom);
      _vertical.add(right, top, bottom);
      if (_horizontal.closed + _vertical.closed > limit) return null;
    }
    final count =
        _horizontal.closed +
        _vertical.closed +
        _horizontal.open +
        _vertical.open;
    if (count > limit) return null;
    final out = Float32List(count * 4);
    var o = _horizontal.write(out, 0, horizontal: true);
    o = _vertical.write(out, o, horizontal: false);
    return out;
  }
}

/// Open segments per line coordinate, in an open-addressing table, plus the
/// segments already closed.
final class _LineTable() {
  Float64List _keys = Float64List(256);
  Int32List _stamp = Int32List(256);
  Float64List _start = Float64List(256);
  Float64List _end = Float64List(256);
  int _generation = 1;
  int _mask = 255;

  /// Lines with an open segment.
  int open = 0;

  /// Closed segments, three doubles each (line, start, end).
  Float64List _closed = Float64List(768);
  int closed = 0;

  void reset() {
    _generation++;
    open = 0;
    closed = 0;
  }

  int _slot(double line) {
    var h = (line.hashCode * 0x9E3779B1) & _mask;
    while (_stamp[h] == _generation && _keys[h] != line) {
      h = (h + 1) & _mask;
    }
    return h;
  }

  void add(double line, double start, double end) {
    var h = _slot(line);
    if (_stamp[h] != _generation) {
      if (open * 2 >= _mask) {
        _grow();
        h = _slot(line);
      }
      _stamp[h] = _generation;
      _keys[h] = line;
      _start[h] = start;
      _end[h] = end;
      open++;
      return;
    }
    if (start <= _end[h] && end >= _start[h]) {
      if (start < _start[h]) _start[h] = start;
      if (end > _end[h]) _end[h] = end;
      return;
    }
    _close(line, _start[h], _end[h]);
    _start[h] = start;
    _end[h] = end;
  }

  void _close(double line, double start, double end) {
    final o = closed * 3;
    if (o + 3 > _closed.length) {
      _closed = Float64List(_closed.length * 2)..setRange(0, o, _closed);
    }
    _closed[o] = line;
    _closed[o + 1] = start;
    _closed[o + 2] = end;
    closed++;
  }

  void _grow() {
    final keys = _keys, stamp = _stamp, start = _start, end = _end;
    final generation = _generation;
    final size = keys.length * 2;
    _keys = Float64List(size);
    _stamp = Int32List(size);
    _start = Float64List(size);
    _end = Float64List(size);
    _mask = size - 1;
    _generation = 1;
    for (var i = 0; i < keys.length; i++) {
      if (stamp[i] != generation) continue;
      final h = _slot(keys[i]);
      _stamp[h] = _generation;
      _keys[h] = keys[i];
      _start[h] = start[i];
      _end[h] = end[i];
    }
  }

  /// Writes every segment, closed then open, into [out] from [offset] as
  /// (x0, y0, x1, y1), and returns the offset after the last.
  int write(Float32List out, int offset, {required bool horizontal}) {
    var o = offset;
    void put(double line, double start, double end) {
      if (horizontal) {
        out[o] = start;
        out[o + 1] = line;
        out[o + 2] = end;
        out[o + 3] = line;
      } else {
        out[o] = line;
        out[o + 1] = start;
        out[o + 2] = line;
        out[o + 3] = end;
      }
      o += 4;
    }

    for (var i = 0; i < closed * 3; i += 3) {
      put(_closed[i], _closed[i + 1], _closed[i + 2]);
    }
    for (var h = 0; h < _keys.length; h++) {
      if (_stamp[h] == _generation) put(_keys[h], _start[h], _end[h]);
    }
    return o;
  }
}
