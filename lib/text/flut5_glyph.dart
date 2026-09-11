import 'dart:math' as math;
import 'dart:typed_data';

import '../math/flut5_vector.dart';
import 'flut5_font.dart';
import 'flut5_font_variation.dart';
import 'flut5_gvar_decoder.dart';

// ── Flut5Glyph ────────────────────────────────────────────────────────

/// A parsed glyph containing path commands in font-unit space (y-up).
class const Flut5Glyph({
  /// Drawing commands that describe this glyph's outline.
  required final List<PathCommand> commands,

  /// Bounding box in font units.
  required final int xMin,

  /// Bounding box in font units.
  required final int yMin,

  /// Bounding box in font units.
  required final int xMax,

  /// Bounding box in font units.
  required final int yMax,
}) {
  /// Empty glyph — used for space characters and missing outlines.
  static const empty = Flut5Glyph(
    commands: [],
    xMin: 0,
    yMin: 0,
    xMax: 0,
    yMax: 0,
  );
}

// ── Glyph parser ──────────────────────────────────────────────────────

// Flag bits for simple glyph points.
const _onCurve = 0x01;
const _xShort = 0x02;
const _yShort = 0x04;
const _repeat = 0x08;
const _xSameOrPositive = 0x10;
const _ySameOrPositive = 0x20;

// Compound glyph flag bits.
const _argAreWords = 0x0001;
const _argsAreXYValues = 0x0002;
const _weHaveAScale = 0x0008;
const _moreComponents = 0x0020;
const _weHaveAnXAndYScale = 0x0040;
const _weHaveATwoByTwo = 0x0080;

/// Internal glyph outline parser.
class Flut5GlyphParser._() {
  /// Parses the glyph at [glyphIndex] from the raw glyf table data.
  ///
  /// [glyfData] is a ByteData view of the glyf table (offsets start at 0).
  /// [locaOffsets] maps glyph index → byte offset within [glyfData].
  ///
  /// When [gvar] and [normalizedCoords] are supplied, the parsed outline has
  /// gvar tuple-variation deltas applied (with IUP for unreferenced points).
  /// Without them, the static default-instance outline is returned.
  ///
  /// For compound glyphs, the variation context is propagated into the
  /// component-glyph parse calls so leaf simple glyphs vary; per-component
  /// translation/transform variation is not currently applied.
  static Flut5Glyph parseGlyph(
    ByteData glyfData,
    List<int> locaOffsets,
    int glyphIndex,
    Flut5Font font, {
    Set<int>? ancestors,
    int depth = 0,
    Flut5GvarData? gvar,
    List<double>? normalizedCoords,
  }) {
    final glyphOffset = locaOffsets[glyphIndex];
    final nextOffset = locaOffsets[glyphIndex + 1];

    // Empty glyph (space, .notdef with no outline, etc.)
    if (glyphOffset == nextOffset) return Flut5Glyph.empty;

    final numberOfContours = glyfData.getInt16(glyphOffset);
    final xMin = glyfData.getInt16(glyphOffset + 2);
    final yMin = glyfData.getInt16(glyphOffset + 4);
    final xMax = glyfData.getInt16(glyphOffset + 6);
    final yMax = glyfData.getInt16(glyphOffset + 8);

    List<PathCommand> commands;
    if (numberOfContours >= 0) {
      commands = _parseSimpleGlyph(
        glyfData,
        glyphOffset + 10,
        numberOfContours,
        glyphIndex: glyphIndex,
        gvar: gvar,
        normalizedCoords: normalizedCoords,
      );
    } else {
      // Compound glyph — guard against cycles and runaway recursion.
      // `ancestors` tracks the current path (removed on unwind); `depth`
      // caps total nesting so sibling references aren't falsely rejected.
      ancestors ??= <int>{};
      if (ancestors.contains(glyphIndex) || depth >= 10) {
        return Flut5Glyph.empty;
      }
      ancestors.add(glyphIndex);
      commands = _parseCompoundGlyph(
        glyfData,
        glyphOffset + 10,
        font,
        locaOffsets,
        ancestors,
        depth + 1,
        gvar: gvar,
        normalizedCoords: normalizedCoords,
      );
      ancestors.remove(glyphIndex);
    }

    return Flut5Glyph(
      commands: commands,
      xMin: xMin,
      yMin: yMin,
      xMax: xMax,
      yMax: yMax,
    );
  }

  // ── Simple glyph ───────────────────────────────────────────────────

  static List<PathCommand> _parseSimpleGlyph(
    ByteData data,
    int offset,
    int numberOfContours, {
    required int glyphIndex,
    Flut5GvarData? gvar,
    List<double>? normalizedCoords,
  }) {
    if (numberOfContours == 0) return const [];

    // 1. Read contour end-point indices.
    final endPts = List<int>.filled(numberOfContours, 0);
    int off = offset;
    for (int i = 0; i < numberOfContours; i++) {
      endPts[i] = data.getUint16(off);
      off += 2;
    }
    final numPoints = endPts.last + 1;

    // 2. Skip instructions.
    final instructionLength = data.getUint16(off);
    off += 2 + instructionLength;

    // 3. Read flags (run-length compressed).
    final flags = List<int>.filled(numPoints, 0);
    int fi = 0;
    while (fi < numPoints) {
      final flag = data.getUint8(off++);
      flags[fi++] = flag;
      if (flag & _repeat != 0) {
        final count = data.getUint8(off++);
        for (int r = 0; r < count && fi < numPoints; r++) {
          flags[fi++] = flag;
        }
      }
    }

    // 4. Read x-coordinates (delta-encoded).
    final xCoords = List<int>.filled(numPoints, 0);
    int x = 0;
    for (int i = 0; i < numPoints; i++) {
      final flag = flags[i];
      if (flag & _xShort != 0) {
        final dx = data.getUint8(off++);
        x += (flag & _xSameOrPositive != 0) ? dx : -dx;
      } else if (flag & _xSameOrPositive == 0) {
        x += data.getInt16(off);
        off += 2;
      }
      // else: x unchanged (delta = 0)
      xCoords[i] = x;
    }

    // 5. Read y-coordinates (delta-encoded).
    final yCoords = List<int>.filled(numPoints, 0);
    int y = 0;
    for (int i = 0; i < numPoints; i++) {
      final flag = flags[i];
      if (flag & _yShort != 0) {
        final dy = data.getUint8(off++);
        y += (flag & _ySameOrPositive != 0) ? dy : -dy;
      } else if (flag & _ySameOrPositive == 0) {
        y += data.getInt16(off);
        off += 2;
      }
      yCoords[i] = y;
    }

    // 6. Apply gvar deltas at the current normalized axis position. The
    // resulting point coords carry sub-unit precision, so contour emission
    // operates on doubles from here on.
    final xs = List<double>.generate(
      numPoints,
      (i) => xCoords[i].toDouble(),
      growable: false,
    );
    final ys = List<double>.generate(
      numPoints,
      (i) => yCoords[i].toDouble(),
      growable: false,
    );
    if (gvar != null && normalizedCoords != null) {
      final deltas = resolveSimpleGlyphGvarDeltas(
        gvar: gvar,
        glyphIndex: glyphIndex,
        normalizedCoords: normalizedCoords,
        pointCount: numPoints,
        xCoords: xCoords,
        yCoords: yCoords,
        endPts: endPts,
      );
      if (deltas != null) {
        for (int i = 0; i < numPoints; i++) {
          xs[i] += deltas[i].dx;
          ys[i] += deltas[i].dy;
        }
      }
    }

    // 7. Convert contours to path commands.
    final commands = <PathCommand>[];
    int startIdx = 0;
    for (int c = 0; c < numberOfContours; c++) {
      final endIdx = endPts[c];
      commands.addAll(_contourToCommands(xs, ys, flags, startIdx, endIdx));
      startIdx = endIdx + 1;
    }

    return commands;
  }

  /// Converts one contour's points into [PathCommand]s.
  ///
  /// Handles the TrueType implied midpoint rule: two consecutive off-curve
  /// points imply an on-curve point at their midpoint.
  static List<PathCommand> _contourToCommands(
    List<double> xCoords,
    List<double> yCoords,
    List<int> flags,
    int startIdx,
    int endIdx,
  ) {
    final commands = <PathCommand>[];
    final count = endIdx - startIdx + 1;
    if (count < 1) return commands;

    // Helpers to access contour-local points with wrapping.
    double px(int i) => xCoords[startIdx + (i % count)];
    double py(int i) => yCoords[startIdx + (i % count)];
    bool isOnCurve(int i) => flags[startIdx + (i % count)] & _onCurve != 0;

    // Find first on-curve point, or use midpoint of first two off-curves.
    double startX, startY;
    int firstOn = -1;
    for (int i = 0; i < count; i++) {
      if (isOnCurve(i)) {
        firstOn = i;
        break;
      }
    }

    if (firstOn >= 0) {
      startX = px(firstOn);
      startY = py(firstOn);
    } else {
      // All off-curve — start at midpoint of first and last.
      startX = (px(0) + px(count - 1)) / 2.0;
      startY = (py(0) + py(count - 1)) / 2.0;
    }

    commands.add(MoveToCommand(startX, startY));

    // Walk all points in the contour.
    final start = firstOn >= 0 ? firstOn + 1 : 0;
    for (int n = 0; n < count; n++) {
      final i = (start + n) % count;

      if (isOnCurve(i)) {
        commands.add(LineToCommand(px(i), py(i)));
      } else {
        // Off-curve: quadratic control point.
        final ctrlX = px(i);
        final ctrlY = py(i);
        final next = (i + 1) % count;

        double endX, endY;
        if (isOnCurve(next)) {
          endX = px(next);
          endY = py(next);
          n++; // consume the on-curve endpoint
        } else {
          // Implied midpoint between two off-curve points.
          endX = (ctrlX + px(next)) / 2.0;
          endY = (ctrlY + py(next)) / 2.0;
        }

        commands.add(QuadToCommand(ctrlX, ctrlY, endX, endY));
      }
    }

    commands.add(const CloseCommand());
    return commands;
  }

  // ── Compound glyph ─────────────────────────────────────────────────

  static List<PathCommand> _parseCompoundGlyph(
    ByteData data,
    int offset,
    Flut5Font font,
    List<int> locaOffsets,
    Set<int> ancestors,
    int depth, {
    Flut5GvarData? gvar,
    List<double>? normalizedCoords,
  }) {
    final commands = <PathCommand>[];
    int off = offset;
    int compFlags;

    do {
      compFlags = data.getUint16(off);
      final compGlyphIndex = data.getUint16(off + 2);
      off += 4;

      // Read translation offsets.
      double dx, dy;
      if (compFlags & _argAreWords != 0) {
        if (compFlags & _argsAreXYValues != 0) {
          dx = data.getInt16(off).toDouble();
          dy = data.getInt16(off + 2).toDouble();
        } else {
          dx = data.getUint16(off).toDouble();
          dy = data.getUint16(off + 2).toDouble();
        }
        off += 4;
      } else {
        if (compFlags & _argsAreXYValues != 0) {
          dx = data.getInt8(off).toDouble();
          dy = data.getInt8(off + 1).toDouble();
        } else {
          dx = data.getUint8(off).toDouble();
          dy = data.getUint8(off + 1).toDouble();
        }
        off += 2;
      }

      // Read transform matrix components.
      double a = 1.0, b = 0.0, c = 0.0, d = 1.0;
      if (compFlags & _weHaveAScale != 0) {
        a = d = _readF2Dot14(data, off);
        off += 2;
      } else if (compFlags & _weHaveAnXAndYScale != 0) {
        a = _readF2Dot14(data, off);
        d = _readF2Dot14(data, off + 2);
        off += 4;
      } else if (compFlags & _weHaveATwoByTwo != 0) {
        a = _readF2Dot14(data, off);
        b = _readF2Dot14(data, off + 2);
        c = _readF2Dot14(data, off + 4);
        d = _readF2Dot14(data, off + 6);
        off += 8;
      }

      // Recursively parse component glyph. Variation context flows down so
      // leaf simple glyphs vary; per-component transform/translation deltas
      // from the compound's own gvar entry are not currently applied.
      final compGlyph = parseGlyph(
        data,
        locaOffsets,
        compGlyphIndex,
        font,
        ancestors: ancestors,
        depth: depth,
        gvar: gvar,
        normalizedCoords: normalizedCoords,
      );

      // Apply affine transform to all component commands.
      for (final cmd in compGlyph.commands) {
        commands.add(_transformCommand(cmd, a, b, c, d, dx, dy));
      }
    } while (compFlags & _moreComponents != 0);

    return commands;
  }

  /// Reads a 2.14 fixed-point value (int16 / 16384).
  static double _readF2Dot14(ByteData data, int offset) {
    return data.getInt16(offset) / 16384.0;
  }

  /// Applies an affine transform to a [PathCommand].
  static PathCommand _transformCommand(
    PathCommand cmd,
    double a,
    double b,
    double c,
    double d,
    double dx,
    double dy,
  ) {
    double tx(double gx, double gy) => a * gx + b * gy + dx;
    double ty(double gx, double gy) => c * gx + d * gy + dy;

    return switch (cmd) {
      MoveToCommand(:final x, :final y) => MoveToCommand(tx(x, y), ty(x, y)),
      LineToCommand(:final x, :final y) => LineToCommand(tx(x, y), ty(x, y)),
      QuadToCommand(:final cx, :final cy, :final x, :final y) => QuadToCommand(
        tx(cx, cy),
        ty(cx, cy),
        tx(x, y),
        ty(x, y),
      ),
      CubicToCommand(
        :final cx1,
        :final cy1,
        :final cx2,
        :final cy2,
        :final x,
        :final y,
      ) =>
        CubicToCommand(
          tx(cx1, cy1),
          ty(cx1, cy1),
          tx(cx2, cy2),
          ty(cx2, cy2),
          tx(x, y),
          ty(x, y),
        ),
      CloseCommand() => cmd,
    };
  }
}

// ── Point sampling ────────────────────────────────────────────────────

/// Samples points along path commands for textToPoints / textToContours.
class Flut5GlyphSampler._() {
  /// Samples points along all segments in [commands].
  ///
  /// [sampleFactor] controls density — higher values produce more points.
  /// Default 0.5 gives roughly one point every 6 pixels.
  /// [simplifyThreshold] drops near-collinear points when > 0. The value is
  /// the threshold angle (radians) between two adjacent edges — below this,
  /// the middle point is considered collinear and removed.
  static List<Flut5Vector> samplePoints(
    List<PathCommand> commands, {
    double sampleFactor = 0.5,
    double simplifyThreshold = 0,
  }) {
    final contours = sampleContours(
      commands,
      sampleFactor: sampleFactor,
      simplifyThreshold: simplifyThreshold,
    );
    final out = <Flut5Vector>[];
    for (final c in contours) {
      out.addAll(c);
    }
    return out;
  }

  /// Samples points grouped by contour (each `MoveToCommand` starts a new group).
  ///
  /// [simplifyThreshold] drops near-collinear points within each contour when
  /// greater than 0 (angle in radians between adjacent edges).
  static List<List<Flut5Vector>> sampleContours(
    List<PathCommand> commands, {
    double sampleFactor = 0.5,
    double simplifyThreshold = 0,
  }) {
    final rawContours = <_SampledContour>[];
    List<Flut5Vector>? currentPoints;
    bool currentClosed = false;
    bool currentHasCurve = false;
    double curX = 0, curY = 0;
    final baseStep = 3.0 / sampleFactor;

    void finishCurrent() {
      final points = currentPoints;
      if (points != null && points.isNotEmpty) {
        rawContours.add(
          _SampledContour(
            points: points,
            closed: currentClosed,
            hasCurve: currentHasCurve,
          ),
        );
      }
      currentPoints = null;
      currentClosed = false;
      currentHasCurve = false;
    }

    for (final cmd in commands) {
      switch (cmd) {
        case MoveToCommand(:final x, :final y):
          finishCurrent();
          currentPoints = <Flut5Vector>[Flut5Vector(x, y)];
          curX = x;
          curY = y;
        case LineToCommand(:final x, :final y):
          final points = currentPoints;
          if (points == null) continue;
          _appendPoint(points, x, y);
          curX = x;
          curY = y;
        case QuadToCommand(:final cx, :final cy, :final x, :final y):
          final points = currentPoints;
          if (points == null) continue;
          currentHasCurve = true;
          final sx = curX, sy = curY;
          _appendCurvePolyline(
            out: points,
            evalX: (t) {
              final mt = 1.0 - t;
              return mt * mt * sx + 2 * mt * t * cx + t * t * x;
            },
            evalY: (t) {
              final mt = 1.0 - t;
              return mt * mt * sy + 2 * mt * t * cy + t * t * y;
            },
          );
          curX = x;
          curY = y;
        case CubicToCommand(
          :final cx1,
          :final cy1,
          :final cx2,
          :final cy2,
          :final x,
          :final y,
        ):
          final points = currentPoints;
          if (points == null) continue;
          currentHasCurve = true;
          final sx = curX, sy = curY;
          _appendCurvePolyline(
            out: points,
            evalX: (t) {
              final mt = 1.0 - t;
              final mt2 = mt * mt;
              final t2 = t * t;
              return mt2 * mt * sx +
                  3 * mt2 * t * cx1 +
                  3 * mt * t2 * cx2 +
                  t2 * t * x;
            },
            evalY: (t) {
              final mt = 1.0 - t;
              final mt2 = mt * mt;
              final t2 = t * t;
              return mt2 * mt * sy +
                  3 * mt2 * t * cy1 +
                  3 * mt * t2 * cy2 +
                  t2 * t * y;
            },
          );
          curX = x;
          curY = y;
        case CloseCommand():
          currentClosed = true;
          finishCurrent();
      }
    }
    finishCurrent();

    final contours = <List<Flut5Vector>>[];
    for (final contour in rawContours) {
      contours.add(
        _resampleContour(
          contour.points,
          closed: contour.closed,
          hasCurve: contour.hasCurve,
          baseStep: baseStep,
        ),
      );
    }

    if (simplifyThreshold > 0) {
      for (int i = 0; i < contours.length; i++) {
        contours[i] = _simplifyContour(contours[i], simplifyThreshold);
      }
    }

    return contours;
  }

  /// Removes points whose adjacent edges form an angle smaller than
  /// [threshold] (radians) — i.e. near-collinear points.
  static List<Flut5Vector> _simplifyContour(
    List<Flut5Vector> pts,
    double threshold,
  ) {
    if (pts.length < 3) return pts;
    final out = <Flut5Vector>[pts.first];
    for (int i = 1; i < pts.length - 1; i++) {
      final a = out.last;
      final b = pts[i];
      final c = pts[i + 1];
      final v1x = b.x - a.x, v1y = b.y - a.y;
      final v2x = c.x - b.x, v2y = c.y - b.y;
      final len1 = math.sqrt(v1x * v1x + v1y * v1y);
      final len2 = math.sqrt(v2x * v2x + v2y * v2y);
      if (len1 == 0 || len2 == 0) continue;
      final cos = ((v1x * v2x + v1y * v2y) / (len1 * len2)).clamp(-1.0, 1.0);
      final angle = math.acos(cos);
      if (angle >= threshold) out.add(b);
    }
    out.add(pts.last);
    return out;
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  static double _dist(double x1, double y1, double x2, double y2) {
    final dx = x2 - x1;
    final dy = y2 - y1;
    return math.sqrt(dx * dx + dy * dy);
  }

  static void _appendPoint(List<Flut5Vector> out, double x, double y) {
    final last = out.last;
    if (_dist(last.x, last.y, x, y) > 0) {
      out.add(Flut5Vector(x, y));
    }
  }

  static void _appendCurvePolyline({
    required List<Flut5Vector> out,
    required double Function(double t) evalX,
    required double Function(double t) evalY,
  }) {
    const lutSize = 64;
    for (int i = 1; i <= lutSize; i++) {
      final t = i / lutSize;
      _appendPoint(out, evalX(t), evalY(t));
    }
  }

  static List<Flut5Vector> _resampleContour(
    List<Flut5Vector> points, {
    required bool closed,
    required bool hasCurve,
    required double baseStep,
  }) {
    if (points.isEmpty) return const [];
    if (points.length == 1) {
      final p = points.first;
      return [Flut5Vector(p.x, p.y)];
    }

    final segmentCount = closed ? points.length : points.length - 1;
    final segmentLengths = List<double>.filled(segmentCount, 0);
    var totalLen = 0.0;
    for (int i = 0; i < segmentCount; i++) {
      final a = points[i];
      final b = i == points.length - 1 ? points.first : points[i + 1];
      final len = _dist(a.x, a.y, b.x, b.y);
      segmentLengths[i] = len;
      totalLen += len;
    }

    if (totalLen <= 0) {
      final p = points.first;
      return [Flut5Vector(p.x, p.y)];
    }

    final requestedCount = closed
        ? (totalLen / baseStep).ceil()
        : (totalLen / baseStep).ceil() + 1;
    final minCount = closed ? (hasCurve ? 8 : 4) : 2;
    final sampleCount = math.max(requestedCount, minCount).clamp(1, 10000);

    final out = <Flut5Vector>[];
    var segmentIndex = 0;
    var segmentStartLen = 0.0;
    for (int i = 0; i < sampleCount; i++) {
      final targetLen = closed
          ? totalLen * i / sampleCount
          : totalLen * i / (sampleCount - 1);

      while (segmentIndex < segmentLengths.length - 1 &&
          segmentStartLen + segmentLengths[segmentIndex] < targetLen) {
        segmentStartLen += segmentLengths[segmentIndex];
        segmentIndex++;
      }

      final a = points[segmentIndex];
      final b = segmentIndex == points.length - 1
          ? points.first
          : points[segmentIndex + 1];
      final segLen = segmentLengths[segmentIndex];
      final t = segLen > 0 ? (targetLen - segmentStartLen) / segLen : 0.0;
      out.add(Flut5Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t));
    }
    return out;
  }
}

class const _SampledContour({
  required final List<Flut5Vector> points,
  required final bool closed,
  required final bool hasCurve,
});

// ── CFF / Type 2 charstring interpreter ──────────────────────────────

/// Interprets CFF Type 2 charstrings into [Flut5Glyph] path commands.
class Flut5CFFInterpreter._() {
  /// Parses the glyph at [glyphIndex] from [cff] charstring data.
  static Flut5Glyph parseGlyph(CFFData cff, int glyphIndex) {
    if (glyphIndex < 0 || glyphIndex >= cff.charStrings.length) {
      return Flut5Glyph.empty;
    }
    final interp = _Interpreter(
      localSubrs: cff.localSubrs,
      globalSubrs: cff.globalSubrs,
      nominalWidthX: cff.nominalWidthX,
    );
    interp.execute(cff.charStrings[glyphIndex], 0);
    return Flut5Glyph(
      commands: interp.commands,
      xMin: 0,
      yMin: 0,
      xMax: 0,
      yMax: 0,
    );
  }
}

/// Subroutine bias per Adobe Type 2 spec.
int _cffBias(int count) {
  if (count < 1240) return 107;
  if (count < 33900) return 1131;
  return 32768;
}

class _Interpreter({
  required final List<Uint8List> localSubrs,
  required final List<Uint8List> globalSubrs,
  required final double nominalWidthX,
}) {
  final List<double> _stack = [];
  final List<PathCommand> commands = [];

  double _x = 0, _y = 0;
  bool _open = false;
  bool _done = false;
  int _stemCount = 0;

  // ── Pen helpers ──────────────────────────────────────────────────────

  void _moveTo(double dx, double dy) {
    if (_open) commands.add(const CloseCommand());
    _x += dx;
    _y += dy;
    commands.add(MoveToCommand(_x, _y));
    _open = true;
  }

  void _lineTo(double dx, double dy) {
    _x += dx;
    _y += dy;
    commands.add(LineToCommand(_x, _y));
  }

  void _cubicTo(
    double dx1,
    double dy1,
    double dx2,
    double dy2,
    double dx3,
    double dy3,
  ) {
    final cx1 = _x + dx1;
    final cy1 = _y + dy1;
    final cx2 = cx1 + dx2;
    final cy2 = cy1 + dy2;
    _x = cx2 + dx3;
    _y = cy2 + dy3;
    commands.add(CubicToCommand(cx1, cy1, cx2, cy2, _x, _y));
  }

  // ── Stem hint accounting ─────────────────────────────────────────────

  void _countStems() {
    _stemCount += _stack.length ~/ 2;
    _stack.clear();
  }

  // ── Main interpreter ─────────────────────────────────────────────────

  void execute(Uint8List bytes, int depth) {
    if (depth > 10) return;
    int i = 0;

    while (i < bytes.length && !_done) {
      final b = bytes[i];

      // ── Number encoding ────────────────────────────────────────────
      // Each branch checks the operand bytes are present before reading —
      // malformed charstrings (truncated, wrong INDEX offsets, unhandled
      // 2-byte escape ops that throw off alignment) can leave the cursor
      // straddling the end of the buffer otherwise.
      if (b == 28) {
        if (i + 2 >= bytes.length) break;
        final val = (bytes[i + 1] << 8) | bytes[i + 2];
        _stack.add((val > 32767 ? val - 65536 : val).toDouble());
        i += 3;
        continue;
      }
      if (b == 255) {
        if (i + 4 >= bytes.length) break;
        final val =
            (bytes[i + 1] << 24) |
            (bytes[i + 2] << 16) |
            (bytes[i + 3] << 8) |
            bytes[i + 4];
        final signed = val > 2147483647 ? val - 4294967296 : val;
        _stack.add(signed / 65536.0);
        i += 5;
        continue;
      }
      if (b >= 32 && b <= 246) {
        _stack.add((b - 139).toDouble());
        i++;
        continue;
      }
      if (b >= 247 && b <= 250) {
        if (i + 1 >= bytes.length) break;
        _stack.add(((b - 247) * 256 + bytes[i + 1] + 108).toDouble());
        i += 2;
        continue;
      }
      if (b >= 251 && b <= 254) {
        if (i + 1 >= bytes.length) break;
        _stack.add((-(b - 251) * 256 - bytes[i + 1] - 108).toDouble());
        i += 2;
        continue;
      }

      // ── Operators ─────────────────────────────────────────────────
      i++;
      switch (b) {
        // ── Hints (we count but don't render) ──────────────────────
        case 1: // hstem
        case 3: // vstem
        case 18: // hstemhm
        case 23: // vstemhm
          _countStems();

        // ── Hint masks (consume mask bytes) ────────────────────────
        case 19: // hintmask
        case 20: // cntrmask
          {
            _stemCount += _stack.length ~/ 2;
            _stack.clear();
            final maskBytes = (_stemCount + 7) ~/ 8;
            i += maskBytes;
            if (i > bytes.length) return;
          }

        // ── Move ────────────────────────────────────────────────────
        // Type 2 spec: on the first stack-clearing operator, the stack may
        // carry an optional leading glyph-width argument. Because we only
        // need the trailing move deltas, reading from the end of the stack
        // is correct whether the width is present or not.
        case 21: // rmoveto
          {
            final dy = _stack.length >= 2 ? _stack[_stack.length - 1] : 0.0;
            final dx = _stack.length >= 2 ? _stack[_stack.length - 2] : 0.0;
            _stack.clear();
            _moveTo(dx, dy);
          }

        case 22: // hmoveto
          {
            final dx = _stack.isNotEmpty ? _stack.last : 0.0;
            _stack.clear();
            _moveTo(dx, 0);
          }

        case 4: // vmoveto
          {
            final dy = _stack.isNotEmpty ? _stack.last : 0.0;
            _stack.clear();
            _moveTo(0, dy);
          }

        // ── Lines ────────────────────────────────────────────────────
        case 5: // rlineto
          {
            for (int j = 0; j + 1 < _stack.length; j += 2) {
              _lineTo(_stack[j], _stack[j + 1]);
            }
            _stack.clear();
          }

        case 6: // hlineto — alternating h/v
          {
            for (int j = 0; j < _stack.length; j++) {
              if (j.isEven) {
                _lineTo(_stack[j], 0);
              } else {
                _lineTo(0, _stack[j]);
              }
            }
            _stack.clear();
          }

        case 7: // vlineto — alternating v/h
          {
            for (int j = 0; j < _stack.length; j++) {
              if (j.isEven) {
                _lineTo(0, _stack[j]);
              } else {
                _lineTo(_stack[j], 0);
              }
            }
            _stack.clear();
          }

        // ── Curves ───────────────────────────────────────────────────
        case 8: // rrcurveto
          {
            for (int j = 0; j + 5 < _stack.length; j += 6) {
              _cubicTo(
                _stack[j],
                _stack[j + 1],
                _stack[j + 2],
                _stack[j + 3],
                _stack[j + 4],
                _stack[j + 5],
              );
            }
            _stack.clear();
          }

        case 24: // rcurveline — curves then one line
          {
            int j = 0;
            while (j + 5 < _stack.length - 2) {
              _cubicTo(
                _stack[j],
                _stack[j + 1],
                _stack[j + 2],
                _stack[j + 3],
                _stack[j + 4],
                _stack[j + 5],
              );
              j += 6;
            }
            _lineTo(_stack[j], _stack[j + 1]);
            _stack.clear();
          }

        case 25: // rlinecurve — lines then one curve
          {
            int j = 0;
            while (j + 1 < _stack.length - 6) {
              _lineTo(_stack[j], _stack[j + 1]);
              j += 2;
            }
            _cubicTo(
              _stack[j],
              _stack[j + 1],
              _stack[j + 2],
              _stack[j + 3],
              _stack[j + 4],
              _stack[j + 5],
            );
            _stack.clear();
          }

        case 26: // vvcurveto — vertical entry, optional dx1
          {
            int j = 0;
            double dx1 = 0;
            if (_stack.length.isOdd) dx1 = _stack[j++];
            while (j + 3 < _stack.length) {
              _cubicTo(
                dx1,
                _stack[j],
                _stack[j + 1],
                _stack[j + 2],
                0,
                _stack[j + 3],
              );
              dx1 = 0;
              j += 4;
            }
            _stack.clear();
          }

        case 27: // hhcurveto — horizontal entry, optional dy1
          {
            int j = 0;
            double dy1 = 0;
            if (_stack.length.isOdd) dy1 = _stack[j++];
            while (j + 3 < _stack.length) {
              _cubicTo(
                _stack[j],
                dy1,
                _stack[j + 1],
                _stack[j + 2],
                _stack[j + 3],
                0,
              );
              dy1 = 0;
              j += 4;
            }
            _stack.clear();
          }

        case 30: // vhcurveto — starts vertical, alternates
          {
            int j = 0;
            int count = 0;
            // Each iteration consumes 4 args (with an optional 5th on the
            // last group), so guard the loop against malformed charstrings
            // that leave a partial group on the stack.
            while (j + 3 < _stack.length) {
              if (count.isEven) {
                final dy1 = _stack[j];
                final dx2 = _stack[j + 1];
                final dy2 = _stack[j + 2];
                double dx3 = _stack[j + 3];
                double dy3 = 0;
                j += 4;
                if (j == _stack.length - 1) {
                  dy3 = _stack[j++];
                }
                _cubicTo(0, dy1, dx2, dy2, dx3, dy3);
              } else {
                final dx1 = _stack[j];
                final dx2 = _stack[j + 1];
                final dy2 = _stack[j + 2];
                double dy3 = _stack[j + 3];
                double dx3 = 0;
                j += 4;
                if (j == _stack.length - 1) {
                  dx3 = _stack[j++];
                }
                _cubicTo(dx1, 0, dx2, dy2, dx3, dy3);
              }
              count++;
            }
            _stack.clear();
          }

        case 31: // hvcurveto — starts horizontal, alternates
          {
            int j = 0;
            int count = 0;
            while (j + 3 < _stack.length) {
              if (count.isEven) {
                final dx1 = _stack[j];
                final dx2 = _stack[j + 1];
                final dy2 = _stack[j + 2];
                double dy3 = _stack[j + 3];
                double dx3 = 0;
                j += 4;
                if (j == _stack.length - 1) {
                  dx3 = _stack[j++];
                }
                _cubicTo(dx1, 0, dx2, dy2, dx3, dy3);
              } else {
                final dy1 = _stack[j];
                final dx2 = _stack[j + 1];
                final dy2 = _stack[j + 2];
                double dx3 = _stack[j + 3];
                double dy3 = 0;
                j += 4;
                if (j == _stack.length - 1) {
                  dy3 = _stack[j++];
                }
                _cubicTo(0, dy1, dx2, dy2, dx3, dy3);
              }
              count++;
            }
            _stack.clear();
          }

        // ── Subroutine calls ─────────────────────────────────────────
        case 10: // callsubr
          if (_stack.isNotEmpty) {
            final idx =
                _stack.removeLast().toInt() + _cffBias(localSubrs.length);
            if (idx >= 0 && idx < localSubrs.length) {
              execute(localSubrs[idx], depth + 1);
            }
          }

        case 29: // callgsubr
          if (_stack.isNotEmpty) {
            final idx =
                _stack.removeLast().toInt() + _cffBias(globalSubrs.length);
            if (idx >= 0 && idx < globalSubrs.length) {
              execute(globalSubrs[idx], depth + 1);
            }
          }

        case 11: // return (from subroutine)
          return;

        // ── End of glyph ─────────────────────────────────────────────
        case 14: // endchar — terminates the entire charstring,
          // including from within nested subroutines.
          if (_open) {
            commands.add(const CloseCommand());
            _open = false;
          }
          _done = true;
          return;

        // ── Escape (two-byte operators) ───────────────────────────────
        case 12:
          if (i < bytes.length) {
            final op2 = bytes[i++];
            switch (op2) {
              case 35: // flex
                if (_stack.length >= 13) {
                  _cubicTo(
                    _stack[0],
                    _stack[1],
                    _stack[2],
                    _stack[3],
                    _stack[4],
                    _stack[5],
                  );
                  _cubicTo(
                    _stack[6],
                    _stack[7],
                    _stack[8],
                    _stack[9],
                    _stack[10],
                    _stack[11],
                  );
                }
                _stack.clear();
              case 34: // hflex
                if (_stack.length >= 7) {
                  _cubicTo(_stack[0], 0, _stack[1], _stack[2], _stack[3], 0);
                  _cubicTo(_stack[4], 0, _stack[5], -_stack[2], _stack[6], 0);
                }
                _stack.clear();
              case 36: // hflex1
                if (_stack.length >= 9) {
                  _cubicTo(
                    _stack[0],
                    _stack[1],
                    _stack[2],
                    _stack[3],
                    _stack[4],
                    0,
                  );
                  _cubicTo(
                    _stack[5],
                    0,
                    _stack[6],
                    _stack[7],
                    _stack[8],
                    -(_stack[1] + _stack[3] + _stack[7]),
                  );
                }
                _stack.clear();
              case 37: // flex1
                if (_stack.length >= 11) {
                  final dx =
                      _stack[0] + _stack[2] + _stack[4] + _stack[6] + _stack[8];
                  final dy =
                      _stack[1] + _stack[3] + _stack[5] + _stack[7] + _stack[9];
                  final dx6 = dx.abs() > dy.abs() ? _stack[10] : -dx;
                  final dy6 = dx.abs() > dy.abs() ? -dy : _stack[10];
                  _cubicTo(
                    _stack[0],
                    _stack[1],
                    _stack[2],
                    _stack[3],
                    _stack[4],
                    _stack[5],
                  );
                  _cubicTo(
                    _stack[6],
                    _stack[7],
                    _stack[8],
                    _stack[9],
                    dx6,
                    dy6,
                  );
                }
                _stack.clear();
              default:
                _stack.clear();
            }
          }

        default:
          _stack.clear();
      }
    }
  }
}
