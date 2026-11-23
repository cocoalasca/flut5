import 'dart:math' as math;
import 'dart:typed_data';

/// Boxes of what a batch has drawn so far, for asking whether a new draw
/// lands on one of them. Boxes that only touch do not overlap.
///
/// A handful of boxes are scanned directly. Past [_scanLimit] they are filed
/// on a uniform grid by the cell their centre falls in, and a query walks the
/// cells its box can reach once widened by the largest half-extent on file.
/// Cells hash into a flat table, so two cells may share a chain — every
/// candidate still gets the exact box test, so a collision costs a
/// comparison, never a wrong answer.
///
/// [overlaps] may answer `true` when deciding would be expensive: a box far
/// larger than the grid was sized for, a crowded cell, or coordinates that
/// cannot be hashed. The queue then closes the batch — one extra draw call —
/// and the next batch sizes a fresh grid from the shapes that follow, so the
/// per-shape cost stays bounded whatever the sketch draws.
class Flut5OverlapIndex() {
  static const int _scanLimit = 16;
  static const int _firstSlots = 64;
  static const int _maxCells = 16;
  static const int _maxTests = 96;
  static const double _coordLimit = 1e9;

  // Doubles, not float32: touching shapes must compare exactly as drawn.
  Float64List _boxes = Float64List(_scanLimit * 4);
  Int32List _next = Int32List(_scanLimit);
  // Per box: 1 when added as `marked`, for queries that only avoid those.
  Uint8List _marks = Uint8List(_scanLimit);
  // Per box: the `batch` it was added under, for queries that only avoid
  // the boxes of later batches.
  Int32List _batches = Int32List(_scanLimit);
  // Slot → newest box filed there, -1 when empty. Only the first `_mask + 1`
  // slots are live; the list keeps its largest size across batches so a
  // small batch never pays to reset a big batch's table.
  Int32List _heads = Int32List(_firstSlots);
  int _mask = 0;
  int _count = 0;
  // Zero until the grid is built.
  double _cellW = 0;
  double _cellH = 0;
  double _maxHalfW = 0;
  double _maxHalfH = 0;
  bool _undecidable = false;

  void clear() {
    _count = 0;
    _cellW = 0;
    _cellH = 0;
    _maxHalfW = 0;
    _maxHalfH = 0;
    _undecidable = false;
  }

  // Also false for NaN.
  static bool _hashable(double l, double t, double r, double b) =>
      l > -_coordLimit &&
      t > -_coordLimit &&
      r < _coordLimit &&
      b < _coordLimit;

  int _slot(int cx, int cy) => ((cx * 73856093) ^ (cy * 19349663)) & _mask;

  /// Whether the box lands on one already added — on any of them, with
  /// [markedOnly] just on those added as `marked`, and with [laterThan] just
  /// on those added under a `batch` after that one.
  bool overlaps(
    double x1,
    double y1,
    double x2,
    double y2, {
    bool markedOnly = false,
    int laterThan = -1,
  }) {
    if (_undecidable) return true;
    if (_count == 0) return false;
    final l = math.min(x1, x2), r = math.max(x1, x2);
    final t = math.min(y1, y2), b = math.max(y1, y2);
    if (!_hashable(l, t, r, b)) return true;
    final boxes = _boxes, marks = _marks, batches = _batches;
    if (_cellW == 0) {
      for (int o = 0, end = _count * 4; o < end; o += 4) {
        if (markedOnly && marks[o >> 2] == 0) continue;
        if (batches[o >> 2] <= laterThan) continue;
        if (l < boxes[o + 2] &&
            boxes[o] < r &&
            t < boxes[o + 3] &&
            boxes[o + 1] < b) {
          return true;
        }
      }
      return false;
    }
    final cx0 = ((l - _maxHalfW) / _cellW).floor();
    final cx1 = ((r + _maxHalfW) / _cellW).floor();
    final cy0 = ((t - _maxHalfH) / _cellH).floor();
    final cy1 = ((b + _maxHalfH) / _cellH).floor();
    if ((cx1 - cx0 + 1) * (cy1 - cy0 + 1) > _maxCells) return true;
    final heads = _heads, next = _next;
    int tests = 0;
    for (int cx = cx0; cx <= cx1; cx++) {
      for (int cy = cy0; cy <= cy1; cy++) {
        for (int i = heads[_slot(cx, cy)]; i >= 0; i = next[i]) {
          if (++tests > _maxTests) return true;
          if (markedOnly && marks[i] == 0) continue;
          if (batches[i] <= laterThan) continue;
          final o = i * 4;
          if (l < boxes[o + 2] &&
              boxes[o] < r &&
              t < boxes[o + 3] &&
              boxes[o + 1] < b) {
            return true;
          }
        }
      }
    }
    return false;
  }

  void add(
    double x1,
    double y1,
    double x2,
    double y2, {
    bool marked = false,
    int batch = 0,
  }) {
    final l = math.min(x1, x2), r = math.max(x1, x2);
    final t = math.min(y1, y2), b = math.max(y1, y2);
    if (!_hashable(l, t, r, b)) {
      _undecidable = true;
      return;
    }
    if (_count == _next.length) {
      _boxes = Float64List(_count * 8)..setRange(0, _count * 4, _boxes);
      _next = Int32List(_count * 2)..setRange(0, _count, _next);
      _marks = Uint8List(_count * 2)..setRange(0, _count, _marks);
      _batches = Int32List(_count * 2)..setRange(0, _count, _batches);
    }
    _marks[_count] = marked ? 1 : 0;
    _batches[_count] = batch;
    final o = _count * 4;
    _boxes[o] = l;
    _boxes[o + 1] = t;
    _boxes[o + 2] = r;
    _boxes[o + 3] = b;
    final halfW = (r - l) * 0.5, halfH = (b - t) * 0.5;
    if (halfW > _maxHalfW) _maxHalfW = halfW;
    if (halfH > _maxHalfH) _maxHalfH = halfH;
    final i = _count++;
    if (_cellW == 0) {
      if (_count > _scanLimit) {
        // Two shape-widths per cell: a query for a typical shape reaches two
        // cells per axis, each holding a handful of non-overlapping shapes.
        _cellW = math.max(_maxHalfW * 4, 1.0);
        _cellH = math.max(_maxHalfH * 4, 1.0);
        _regrid(_firstSlots);
      }
    } else if (_count > (_mask + 1) >> 1) {
      _regrid((_mask + 1) * 2);
    } else {
      _file(i);
    }
  }

  /// Resets the table to [slots] (a power of two) and files every box.
  void _regrid(int slots) {
    if (_heads.length < slots) _heads = Int32List(slots);
    _heads.fillRange(0, slots, -1);
    _mask = slots - 1;
    for (int j = 0; j < _count; j++) {
      _file(j);
    }
  }

  void _file(int i) {
    final o = i * 4;
    final slot = _slot(
      ((_boxes[o] + _boxes[o + 2]) * 0.5 / _cellW).floor(),
      ((_boxes[o + 1] + _boxes[o + 3]) * 0.5 / _cellH).floor(),
    );
    _next[i] = _heads[slot];
    _heads[slot] = i;
  }
}
