import 'dart:typed_data';

import 'flut5_font_variation.dart';

// ── Tuple variation flags ────────────────────────────────────────────────

const int _embeddedPeakTuple = 0x8000;
const int _intermediateRegion = 0x4000;
const int _privatePointNumbers = 0x2000;
const int _tupleIndexMask = 0x0FFF;

const int _sharedPointNumbers = 0x8000; // bit 15 of tupleVariationCount

// ── Public API ───────────────────────────────────────────────────────────

/// Per-point delta produced by `gvar` for a single glyph at the current
/// normalized axis position. Zero on points that no tuple touches.
class const GvarDelta(final double dx, final double dy) {
  static const zero = GvarDelta(0, 0);
}

/// Resolves the per-point delta vector for a simple-glyph at the given
/// [normalizedCoords]. Returns `null` when no tuple contributes (e.g. all
/// scale factors are 0, or the glyph has no variation data).
///
/// The returned list has length [pointCount] — caller adds dx/dy to that
/// glyph's xCoords/yCoords before producing path commands.
///
/// Implements the OpenType `gvar` interpretation:
/// 1. For each tuple variation, compute its contribution factor against
///    the current axis position (peak/intermediate region semantics).
/// 2. For each tuple with non-zero factor, decode the explicit point deltas
///    and scale by factor.
/// 3. For points not referenced by a tuple, infer deltas via IUP
///    (Interpolation of Untouched Points), per-contour.
/// 4. Sum the contributions of all tuples.
List<GvarDelta>? resolveSimpleGlyphGvarDeltas({
  required Flut5GvarData gvar,
  required int glyphIndex,
  required List<double> normalizedCoords,
  required int pointCount,
  required List<int> xCoords,
  required List<int> yCoords,
  required List<int> endPts,
}) {
  final variationPointCount = pointCount + 4;

  // Locate this glyph's variation data block.
  final offsets = gvar.glyphVariationDataOffsets;
  if (glyphIndex < 0 || glyphIndex + 1 >= offsets.length) return null;
  final dataStart = gvar.glyphVariationDataArrayOffset + offsets[glyphIndex];
  final dataEnd = gvar.glyphVariationDataArrayOffset + offsets[glyphIndex + 1];
  if (dataEnd <= dataStart) return null;
  if (dataEnd > gvar.bytes.lengthInBytes) return null;

  final data = gvar.bytes;
  final tupleVariationCount = data.getUint16(dataStart);
  final tupleCount = tupleVariationCount & 0x0FFF;
  if (tupleCount == 0) return null;
  final hasSharedPoints = (tupleVariationCount & _sharedPointNumbers) != 0;
  final serializedDataOffset = dataStart + data.getUint16(dataStart + 2);

  // ── Read tuple variation headers ─────────────────────────────────────
  final headers = <_TupleHeader>[];
  int headerOff = dataStart + 4;
  for (int i = 0; i < tupleCount; i++) {
    final variationDataSize = data.getUint16(headerOff);
    final tupleIndex = data.getUint16(headerOff + 2);
    headerOff += 4;

    List<double> peak;
    if ((tupleIndex & _embeddedPeakTuple) != 0) {
      peak = List<double>.generate(
        gvar.axisCount,
        (a) => data.getInt16(headerOff + a * 2) / 16384.0,
        growable: false,
      );
      headerOff += gvar.axisCount * 2;
    } else {
      // Shared tuple — look up by index.
      final sharedIdx = tupleIndex & _tupleIndexMask;
      if (sharedIdx >= gvar.sharedTupleCount) {
        // Malformed: skip this tuple's data block.
        headerOff += variationDataSize;
        continue;
      }
      final sharedOff =
          gvar.sharedTuplesOffset + sharedIdx * gvar.axisCount * 2;
      peak = List<double>.generate(
        gvar.axisCount,
        (a) => data.getInt16(sharedOff + a * 2) / 16384.0,
        growable: false,
      );
    }

    List<double>? intermediateStart;
    List<double>? intermediateEnd;
    if ((tupleIndex & _intermediateRegion) != 0) {
      intermediateStart = List<double>.generate(
        gvar.axisCount,
        (a) => data.getInt16(headerOff + a * 2) / 16384.0,
        growable: false,
      );
      headerOff += gvar.axisCount * 2;
      intermediateEnd = List<double>.generate(
        gvar.axisCount,
        (a) => data.getInt16(headerOff + a * 2) / 16384.0,
        growable: false,
      );
      headerOff += gvar.axisCount * 2;
    }

    headers.add(
      _TupleHeader(
        variationDataSize: variationDataSize,
        hasPrivatePoints: (tupleIndex & _privatePointNumbers) != 0,
        peak: peak,
        intermediateStart: intermediateStart,
        intermediateEnd: intermediateEnd,
      ),
    );
  }

  // ── Read shared point numbers (if any) ───────────────────────────────
  int cursor = serializedDataOffset;
  List<int>? sharedPoints;
  if (hasSharedPoints) {
    final (pts, next) = _readPackedPointNumbers(
      data,
      cursor,
      variationPointCount,
    );
    sharedPoints = pts;
    cursor = next;
  }

  // ── Accumulate deltas across all tuples ──────────────────────────────
  final out = List<GvarDelta>.filled(pointCount, GvarDelta.zero);
  bool anyApplied = false;

  for (final h in headers) {
    final tupleEnd = cursor + h.variationDataSize;
    if (tupleEnd > data.lengthInBytes) break;

    final scale = _tupleScale(
      h.peak,
      h.intermediateStart,
      h.intermediateEnd,
      normalizedCoords,
    );
    if (scale == 0) {
      cursor = tupleEnd;
      continue;
    }

    int tupleCursor = cursor;
    List<int> pointNumbers;
    if (h.hasPrivatePoints) {
      final (pts, next) = _readPackedPointNumbers(
        data,
        tupleCursor,
        variationPointCount,
      );
      pointNumbers = pts;
      tupleCursor = next;
    } else if (sharedPoints != null) {
      pointNumbers = sharedPoints;
    } else {
      // "All points" means outline points plus the four TrueType phantom
      // points. We ignore phantom deltas below, but still must consume them
      // so the y-delta stream starts at the correct byte.
      pointNumbers = List<int>.generate(
        variationPointCount,
        (i) => i,
        growable: false,
      );
    }

    final deltaCount = pointNumbers.length;
    final (xDeltas, afterX) = _readPackedDeltas(data, tupleCursor, deltaCount);
    final (yDeltas, _) = _readPackedDeltas(data, afterX, deltaCount);

    // Resolve deltas for *all* points via IUP, then add scaled into out.
    final fullDx = List<double>.filled(pointCount, 0);
    final fullDy = List<double>.filled(pointCount, 0);
    final referenced = List<bool>.filled(pointCount, false);
    for (int i = 0; i < deltaCount; i++) {
      final p = pointNumbers[i];
      if (p < 0 || p >= pointCount) continue;
      fullDx[p] = xDeltas[i].toDouble();
      fullDy[p] = yDeltas[i].toDouble();
      referenced[p] = true;
    }

    _interpolateUntouchedPoints(
      fullDx,
      fullDy,
      referenced,
      xCoords,
      yCoords,
      endPts,
    );

    for (int p = 0; p < pointCount; p++) {
      if (fullDx[p] == 0 && fullDy[p] == 0) continue;
      final prev = out[p];
      out[p] = GvarDelta(
        prev.dx + fullDx[p] * scale,
        prev.dy + fullDy[p] * scale,
      );
    }
    anyApplied = true;
    cursor = tupleEnd;
  }

  return anyApplied ? out : null;
}

// ── Tuple scale computation ──────────────────────────────────────────────

/// Computes the contribution factor for a tuple at the current
/// [normalizedCoords]. Returns 0 if the tuple does not affect this position.
double _tupleScale(
  List<double> peak,
  List<double>? intermediateStart,
  List<double>? intermediateEnd,
  List<double> current,
) {
  double scale = 1.0;
  final axisCount = peak.length;
  for (int a = 0; a < axisCount; a++) {
    final p = peak[a];
    final c = a < current.length ? current[a] : 0.0;
    // A zero peak means this axis is not constrained by this tuple.
    if (p == 0) continue;

    if (intermediateStart == null) {
      // Default region: contribution scales linearly from 0..p, clipped
      // outside the same-sign interval.
      if (c == 0) return 0;
      if (c < 0 != p < 0) return 0; // wrong side
      if (c.abs() >= p.abs()) {
        // c is at or past the peak (same side) — full contribution.
        // (c.abs() > p.abs() is technically outside the tuple's range, but
        // spec treats it as full peak — values get clamped at normalize-time.)
        continue;
      }
      scale *= c / p;
    } else {
      final s = intermediateStart[a];
      final e = intermediateEnd![a];
      if (c <= s || c >= e) return 0;
      if (c == p) continue;
      if (c < p) {
        final denom = p - s;
        if (denom == 0) continue;
        scale *= (c - s) / denom;
      } else {
        final denom = e - p;
        if (denom == 0) continue;
        scale *= (e - c) / denom;
      }
    }

    if (scale == 0) return 0;
  }
  return scale;
}

// ── Packed point numbers ─────────────────────────────────────────────────

/// Reads a "packed point number" list. Returns the absolute point indices
/// and the cursor offset just past the encoded data.
///
/// Format (per spec):
/// - First byte: if high bit set, two-byte count combining low 7 bits of
///   byte 1 (high bits) with byte 2 (low bits); else single-byte count.
/// - Count of 0 is a special sentinel meaning "all points".
/// - Followed by runs: control byte (high bit = format: 0 = 1-byte deltas,
///   1 = 2-byte deltas; low 7 bits = run length - 1).
(List<int>, int) _readPackedPointNumbers(
  ByteData data,
  int offset,
  int pointCount,
) {
  int o = offset;
  int count = data.getUint8(o++);
  if ((count & 0x80) != 0) {
    count = ((count & 0x7F) << 8) | data.getUint8(o++);
  }
  if (count == 0) {
    // "All points" — caller materializes 0..pointCount-1 itself.
    return (List<int>.generate(pointCount, (i) => i, growable: false), o);
  }

  final result = <int>[];
  int currentPoint = 0;
  while (result.length < count && o < data.lengthInBytes) {
    final control = data.getUint8(o++);
    final use16 = (control & 0x80) != 0;
    final runLen = (control & 0x7F) + 1;
    for (int i = 0; i < runLen && result.length < count; i++) {
      int delta;
      if (use16) {
        delta = data.getUint16(o);
        o += 2;
      } else {
        delta = data.getUint8(o++);
      }
      currentPoint += delta;
      result.add(currentPoint);
    }
  }
  return (result, o);
}

// ── Packed deltas ────────────────────────────────────────────────────────

/// Reads a run of [count] packed delta values. Returns the deltas and the
/// cursor offset just past the encoded data.
///
/// Format: runs of (control byte, values). Control byte high two bits
/// determine the per-value format; the low 6 bits + 1 give run length.
/// - 00xxxxxx: int8 deltas
/// - 01xxxxxx: int16 deltas
/// - 10xxxxxx: all-zero run (no values follow)
/// - 11xxxxxx: reserved (treat as all-zero for safety)
(List<int>, int) _readPackedDeltas(ByteData data, int offset, int count) {
  final out = List<int>.filled(count, 0);
  int o = offset;
  int read = 0;
  while (read < count && o < data.lengthInBytes) {
    final control = data.getUint8(o++);
    final runLen = (control & 0x3F) + 1;
    final mode = control & 0xC0;
    final remaining = count - read;
    final n = runLen > remaining ? remaining : runLen;
    if (mode == 0x80) {
      // All-zero run: advance `read` only, no bytes consumed.
      for (int i = 0; i < n; i++) {
        out[read++] = 0;
      }
    } else if (mode == 0x40) {
      // 16-bit signed deltas.
      for (int i = 0; i < n; i++) {
        out[read++] = data.getInt16(o);
        o += 2;
      }
    } else if (mode == 0x00) {
      // 8-bit signed deltas.
      for (int i = 0; i < n; i++) {
        out[read++] = data.getInt8(o++);
      }
    } else {
      // Reserved: treat as zeros and consume no bytes.
      for (int i = 0; i < n; i++) {
        out[read++] = 0;
      }
    }
  }
  return (out, o);
}

// ── IUP (Interpolation of Untouched Points) ──────────────────────────────

/// Fills in deltas for points not explicitly referenced by a tuple, by
/// interpolating per-axis between the nearest referenced neighbors within
/// the same contour. The interpolation runs separately on x and y.
///
/// Spec: when a contour has any referenced points, each unreferenced point's
/// delta on a given axis is determined by:
///   - If both neighbor anchors have the same original coord:
///     - If their deltas match → use that delta
///     - Otherwise → delta is 0
///   - If the point's original coord lies between the anchors → linear
///     interp by original-coord fraction
///   - If the point lies outside both anchors → clamp to the nearer anchor's
///     delta (translate-only)
/// When a contour has no referenced points at all, nothing changes.
void _interpolateUntouchedPoints(
  List<double> dx,
  List<double> dy,
  List<bool> referenced,
  List<int> xCoords,
  List<int> yCoords,
  List<int> endPts,
) {
  int contourStart = 0;
  for (final end in endPts) {
    if (end >= contourStart) {
      _iupContour(dx, dy, referenced, xCoords, yCoords, contourStart, end);
    }
    contourStart = end + 1;
  }
}

void _iupContour(
  List<double> dx,
  List<double> dy,
  List<bool> referenced,
  List<int> xCoords,
  List<int> yCoords,
  int start,
  int end,
) {
  final length = end - start + 1;
  if (length < 1) return;

  // Find any referenced point. If none, nothing to interpolate.
  int anyRef = -1;
  for (int i = start; i <= end; i++) {
    if (referenced[i]) {
      anyRef = i;
      break;
    }
  }
  if (anyRef == -1) return;

  // For each unreferenced point, walk forward and backward (with wrap-around
  // within the contour) to find its anchor neighbors.
  for (int i = start; i <= end; i++) {
    if (referenced[i]) continue;

    int prev = i - 1;
    while (prev != i) {
      if (prev < start) prev = end;
      if (referenced[prev]) break;
      prev--;
    }
    int next = i + 1;
    while (next != i) {
      if (next > end) next = start;
      if (referenced[next]) break;
      next++;
    }

    dx[i] = _iupValue(
      xCoords[i],
      xCoords[prev],
      xCoords[next],
      dx[prev],
      dx[next],
    );
    dy[i] = _iupValue(
      yCoords[i],
      yCoords[prev],
      yCoords[next],
      dy[prev],
      dy[next],
    );
  }
}

double _iupValue(int target, int a, int b, double da, double db) {
  if (a == b) {
    return da == db ? da : 0.0;
  }
  // Order anchors by original coord so the interp formula stays consistent.
  int lo, hi;
  double dLo, dHi;
  if (a < b) {
    lo = a;
    hi = b;
    dLo = da;
    dHi = db;
  } else {
    lo = b;
    hi = a;
    dLo = db;
    dHi = da;
  }
  if (target <= lo) return dLo;
  if (target >= hi) return dHi;
  // Linear interpolation in original-coord space.
  final t = (target - lo) / (hi - lo);
  return dLo + t * (dHi - dLo);
}

// ── Internal types ───────────────────────────────────────────────────────

class const _TupleHeader({
  required final int variationDataSize,
  required final bool hasPrivatePoints,
  required final List<double> peak,
  final List<double>? intermediateStart,
  final List<double>? intermediateEnd,
});
