import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Path;

import '../math/flut5_vector.dart';
import 'flut5_font_parser.dart';
import 'flut5_font_variation.dart';
import 'flut5_glyph.dart';
import 'flut5_text_grid.dart';

export 'flut5_font_variation.dart' show Flut5FontAxis, Flut5NamedInstance;

/// Parsed font data registered from Flutter's `FontManifest.json`.
///
/// [name] is the pubspec/manifest family name used with [TextStyle.fontFamily]
/// and `textFont('Family')`. [font] is the parsed outline data used by
/// `textToPaths`, `textToPoints`, and `textToContours`.
class const Flut5FontData({
  required final String name,
  required final String asset,
  required final Flut5Font font,
});

// ── Path command hierarchy ─────────────────────────────────────────────

/// A single drawing command extracted from a glyph outline.
sealed class const PathCommand();

/// Move the pen to ([x], [y]) without drawing.
class const MoveToCommand(final double x, final double y) extends PathCommand;

/// Draw a straight line to ([x], [y]).
class const LineToCommand(final double x, final double y) extends PathCommand;

/// Draw a quadratic Bézier curve with control point ([cx], [cy]) to ([x], [y]).
class const QuadToCommand(
  final double cx,
  final double cy,
  final double x,
  final double y,
) extends PathCommand;

/// Draw a cubic Bézier curve.
/// Used by CFF/OTF fonts and available for manual vertex construction.
class const CubicToCommand(
  final double cx1,
  final double cy1,
  final double cx2,
  final double cy2,
  final double x,
  final double y,
) extends PathCommand;

/// Close the current contour path.
class const CloseCommand() extends PathCommand;

// ── CFF outline data (internal) ────────────────────────────────────────

/// Holds the raw CFF table data needed to interpret glyph charstrings.
/// @nodoc
class const CFFData({
  required final List<Uint8List> charStrings,
  required final List<Uint8List> globalSubrs,
  required final List<Uint8List> localSubrs,
  required final double defaultWidthX,
  required final double nominalWidthX,
});

// ── Flut5Font ──────────────────────────────────────────────────────────

/// A parsed TrueType or OpenType font used internally for glyph vector
/// outline extraction.
///
/// This is **not** Flutter's font system — it is a separate data object created
/// by parsing raw font bytes. It only exists when you explicitly call
/// [Flut5Text.loadFontShapeData] on the engine.
///
/// Supports both TTF (TrueType `glyf` outlines) and OTF (CFF/PostScript outlines).
///
/// You typically do not use [Flut5Font] directly. Instead, call the
/// engine-level API which automatically injects the current [textSize]:
///
/// ```dart
/// await flut5.loadFontShapeData('assets/fonts/Roboto.ttf');
/// flut5.textSize(48);
/// flut5.textToPaths('Hello', 50, 100);    // uses stored font + textSize
/// flut5.textToPoints('Hello', 50, 100);
/// flut5.textToContours('Hello', 50, 100);
/// ```
///
/// Use [Flut5Font] directly only when you need multiple fonts simultaneously
/// or want to call [textToPaths] with an explicit font size:
///
/// ```dart
/// final font = Flut5Font.fromBytes(ttfBytes);
/// final cmds = font.textToPaths('Hello', 50, 100, 48); // explicit 48px
/// ```
class Flut5Font.internal({
  /// Font design units per em square. Typically 1000 or 2048.
  required final int unitsPerEm,

  /// Total number of glyphs in the font.
  required final int numGlyphs,

  /// Number of horizontal metrics entries in hmtx.
  required final int numberOfHMetrics,
  required final Map<int, int> _charToGlyph,
  required final List<Flut5Glyph?> _glyphs,
  required final List<int> _advanceWidths,
  required final List<int> _lsbs,
  final ByteData? _glyfData,
  final List<int>? _locaOffsets,
  final CFFData? _cffData,

  /// Variation axes declared by the font's `fvar` table. Empty for static fonts.
  final List<Flut5FontAxis> axes = const [],

  /// Predefined axis-value combinations declared by the font (e.g. "Bold",
  /// "Light Condensed"). Empty for static fonts.
  final List<Flut5NamedInstance> namedInstances = const [],

  /// Raw `gvar` table data — present on TrueType variable fonts. Lazy-parsed
  /// per-glyph at delta-application time.
  /// @nodoc
  final Flut5GvarData? gvar,

  /// Parsed `avar` segment maps — present when the font remaps normalized
  /// axis coordinates non-linearly.
  /// @nodoc
  final Flut5AvarData? avar,

  /// Raw `HVAR` table data — present on variable fonts that vary advance
  /// widths. Parsed lazily.
  /// @nodoc
  final Flut5HvarData? hvar,
}) {
  /// Per-glyph sampled-contour cache in font-unit (y-up) space.
  ///
  /// Key is `(glyphIndex, sampleFactor, simplifyThreshold)` — scoped to this
  /// font instance. Values hold contours ready to be scaled + translated at
  /// render time, so bezier sampling runs exactly once per unique glyph +
  /// sampling-params combo.
  final LinkedHashMap<(String, int, double, double), List<List<Flut5Vector>>>
  _glyphContourCache = LinkedHashMap();

  /// Per-glyph [Path] cache in font-unit (y-up) space.
  ///
  /// Built once on first use of [getGlyphPath] and reused across outline
  /// rendering calls. Composition (scaling, Y-flip, translation, kerning)
  /// happens by passing a transform matrix to `Path.addPath`, so per-call
  /// cost is just one matrix-multiply per glyph.
  final LinkedHashMap<(String, int), Path> _glyphPathCache = LinkedHashMap();

  /// Parsed variable glyphs keyed by quantized axis position + glyph index.
  /// Unlike static glyphs, variable glyphs cannot live in [_glyphs] because
  /// sketches often move axes every frame.
  final LinkedHashMap<(String, int), Flut5Glyph> _variableGlyphCache =
      LinkedHashMap();

  /// Maximum number of axis-specific glyph outlines and paths retained.
  /// Animated variable-font sketches tend to revisit nearby weights; bounded
  /// LRU caches keep those hot states available without unbounded growth.
  int variableGlyphCacheMaxSize = 4096;

  /// Maximum number of sampled contour entries retained across axis states.
  int variableGlyphContourCacheMaxSize = 1024;

  // TrueType outline data (null for CFF fonts)
  // CFF outline data (null for TrueType fonts)
  /// `true` when the font ships variation axes (i.e. is a variable font).
  bool get isVariable => axes.isNotEmpty;

  /// Returns the axis with the given four-character [tag] (e.g. `'wght'`),
  /// or `null` if no such axis exists on this font.
  Flut5FontAxis? axisByTag(String tag) {
    for (final a in axes) {
      if (a.tag == tag) return a;
    }
    return null;
  }

  // ── Variable-axis state ──────────────────────────────────────────────

  /// Current user-space value for each axis. Initialized to each axis's
  /// declared default; mutate via [setAxisValue] / [setAxisValues] /
  /// [resetAxisValues].
  final Map<String, double> _axisValues = {};

  /// Cached normalized + avar-remapped axis coordinates. Null when all axes
  /// are at their default — the gvar decoder is then short-circuited.
  List<double>? _normalizedCoords;

  /// Cache key for [_normalizedCoords]. Empty means the default axis state.
  String? _normalizedCoordKey;

  /// Quantization resolution for normalized variation coordinates. One step
  /// is below the visible precision needed for animation, but it lets slowly
  /// animated axes reuse glyph paths instead of producing a fresh cache entry
  /// for every distinct floating-point sine value.
  static const int _axisCacheResolution = 512;

  /// Monotonically increasing counter — bumps every time axis values change.
  /// Used by downstream caches (e.g. composed vector-text paths) to know
  /// when their entries are stale without comparing the full axis tuple.
  int _axisVersion = 0;

  /// Counter that ticks each time this font's axis values change. Stable
  /// for the lifetime of an unmodified axis state; downstream caches can
  /// include it as a key component to avoid serving stale entries.
  int get axisVersion => _axisVersion;

  /// Quantized key for the current variation-axis state. Empty string means
  /// all axes are at their default.
  String get axisCacheKey {
    _currentNormalizedCoords;
    return _normalizedCoordKey ?? '';
  }

  /// Current user-space axis values as an unmodifiable view.
  Map<String, double> get axisValues => Map.unmodifiable(_axisValues);

  /// Sets a single axis's user-space value (clamped to its legal range).
  /// Bumps the internal version. Axis-specific glyph/path caches are retained
  /// and keyed by quantized axis position, so animated axes can reuse prior
  /// outlines instead of reparsing every glyph after each axis write.
  /// No-op if [tag] is not declared by this font.
  void setAxisValue(String tag, double value) {
    final axis = axisByTag(tag);
    if (axis == null) return;
    final clamped = axis.clampValue(value);
    if (_axisValues[tag] == clamped) return;
    _axisValues[tag] = clamped;
    _invalidateGlyphCaches();
  }

  /// Sets several axis values at once. More efficient than repeated
  /// [setAxisValue] calls — only invalidates caches once.
  void setAxisValues(Map<String, double> values) {
    bool changed = false;
    for (final entry in values.entries) {
      final axis = axisByTag(entry.key);
      if (axis == null) continue;
      final clamped = axis.clampValue(entry.value);
      if (_axisValues[entry.key] != clamped) {
        _axisValues[entry.key] = clamped;
        changed = true;
      }
    }
    if (changed) _invalidateGlyphCaches();
  }

  /// Restores every axis to its declared default value.
  void resetAxisValues() {
    bool changed = false;
    for (final a in axes) {
      if (_axisValues[a.tag] != a.defaultValue) {
        _axisValues[a.tag] = a.defaultValue;
        changed = true;
      }
    }
    if (changed) _invalidateGlyphCaches();
  }

  void _invalidateGlyphCaches() {
    _axisVersion++;
    _normalizedCoords = null;
    _normalizedCoordKey = null;
  }

  /// Recomputes (or returns the cached) normalized axis coords, including
  /// any `avar` remapping. Returns null when every axis is at its default —
  /// callers treat that as "use the static default-instance outlines".
  List<double>? get _currentNormalizedCoords {
    if (axes.isEmpty) return null;
    final cached = _normalizedCoords;
    if (cached != null) return cached.isEmpty ? null : cached;

    bool anyNonZero = false;
    final keyParts = List<int>.filled(axes.length, 0);
    final coords = List<double>.filled(axes.length, 0);
    for (int i = 0; i < axes.length; i++) {
      final axis = axes[i];
      final value = _axisValues[axis.tag] ?? axis.defaultValue;
      var n = axis.normalize(value);
      final avarTable = avar;
      if (avarTable != null) {
        n = avarTable.remap(i, n);
      }
      final q = (n * _axisCacheResolution).round();
      keyParts[i] = q;
      coords[i] = q / _axisCacheResolution;
      if (q != 0) anyNonZero = true;
    }

    // Cache an empty list as the sentinel for "all-default" so the next call
    // can short-circuit without recomputing the loop.
    _normalizedCoords = anyNonZero ? coords : const [];
    _normalizedCoordKey = anyNonZero ? keyParts.join(',') : '';
    return anyNonZero ? coords : null;
  }

  /// @nodoc — internal constructor used by [Flut5FontParser].
  this {
    for (final a in axes) {
      _axisValues[a.tag] = a.defaultValue;
    }
  }

  /// Parses a TTF or OTF font from raw bytes.
  ///
  /// Throws [FormatException] if the data is not a valid font file.
  factory Flut5Font.fromBytes(Uint8List bytes) {
    return Flut5FontParser.parse(bytes);
  }

  /// Returns the glyph index for a Unicode [codePoint], or 0 (.notdef).
  int glyphIndexForChar(int codePoint) {
    return _charToGlyph[codePoint] ?? 0;
  }

  /// Returns the parsed glyph for [glyphIndex], parsing lazily on first call.
  Flut5Glyph getGlyph(int glyphIndex) {
    if (glyphIndex < 0 || glyphIndex >= numGlyphs) return _getOrParse(0);
    return _getOrParse(glyphIndex);
  }

  Flut5Glyph _getOrParse(int index) {
    final coords = _currentNormalizedCoords;
    final axisKey = _normalizedCoordKey ?? '';
    if (coords != null) {
      final key = (axisKey, index);
      final cached = _variableGlyphCache.remove(key);
      if (cached != null) {
        _variableGlyphCache[key] = cached;
        return cached;
      }
      final glyph = _parseGlyph(index, coords);
      _variableGlyphCache[key] = glyph;
      _trimLru(_variableGlyphCache, variableGlyphCacheMaxSize);
      return glyph;
    }

    final cached = _glyphs[index];
    if (cached != null) return cached;
    final glyph = _parseGlyph(index, null);
    _glyphs[index] = glyph;
    return glyph;
  }

  Flut5Glyph _parseGlyph(int index, List<double>? normalizedCoords) {
    final cff = _cffData;
    if (cff != null) {
      return Flut5CFFInterpreter.parseGlyph(cff, index);
    }
    if (_glyfData != null && _locaOffsets != null) {
      return Flut5GlyphParser.parseGlyph(
        _glyfData,
        _locaOffsets,
        index,
        this,
        gvar: gvar,
        normalizedCoords: normalizedCoords,
      );
    }
    // CFF2 stub: outline data was not decoded. Return an empty glyph so
    // layout still iterates without crashing.
    return Flut5Glyph.empty;
  }

  /// Advance width in font units for [glyphIndex].
  ///
  /// When the font is variable and `HVAR` is present, the value reflects the
  /// current axis state — bold/wide/etc. weights produce wider advances so
  /// layout stays correct as axes change.
  double advanceWidth(int glyphIndex) {
    final base = glyphIndex < numberOfHMetrics
        ? _advanceWidths[glyphIndex]
        : _advanceWidths[numberOfHMetrics - 1];
    final hvarTable = hvar;
    final coords = _currentNormalizedCoords;
    if (hvarTable == null || coords == null) return base.toDouble();
    return base + hvarTable.advanceDelta(glyphIndex, coords);
  }

  /// Left side bearing in font units for [glyphIndex].
  int leftSideBearing(int glyphIndex) {
    return _lsbs[glyphIndex.clamp(0, numGlyphs - 1)];
  }

  /// Returns a cached [Path] for [glyphIndex] in font-unit (y-up) space.
  ///
  /// The path is built lazily on first call and reused for outline rendering.
  /// Compose the final glyph by passing a scale + Y-flip + translate matrix
  /// to `Path.addPath`'s `matrix4` parameter.
  Path getGlyphPath(int glyphIndex) {
    final key = (axisCacheKey, glyphIndex);
    final cached = _glyphPathCache.remove(key);
    if (cached != null) {
      _glyphPathCache[key] = cached;
      return cached;
    }

    final glyph = getGlyph(glyphIndex);
    final path = Path();
    for (final cmd in glyph.commands) {
      switch (cmd) {
        case MoveToCommand(:final x, :final y):
          path.moveTo(x, y);
        case LineToCommand(:final x, :final y):
          path.lineTo(x, y);
        case QuadToCommand(:final cx, :final cy, :final x, :final y):
          path.quadraticBezierTo(cx, cy, x, y);
        case CubicToCommand(
          :final cx1,
          :final cy1,
          :final cx2,
          :final cy2,
          :final x,
          :final y,
        ):
          path.cubicTo(cx1, cy1, cx2, cy2, x, y);
        case CloseCommand():
          path.close();
      }
    }
    _glyphPathCache[key] = path;
    _trimLru(_glyphPathCache, variableGlyphCacheMaxSize);
    return path;
  }

  // ── Text to path commands ────────────────────────────────────────────

  /// Returns path commands for [text] positioned at ([x], [y]) baseline.
  ///
  /// Coordinates are in screen space (y-down). [fontSize] is in pixels.
  /// [letterSpacing] is extra pixel spacing inserted *between* glyphs —
  /// `N` glyphs get `N - 1` insertions, matching `textWidth` and the
  /// raster renderer.
  List<PathCommand> textToPaths(
    String text,
    double x,
    double y,
    double fontSize, {
    double letterSpacing = 0,
  }) {
    final double scale = fontSize / unitsPerEm;
    final commands = <PathCommand>[];
    double cursorX = x;
    bool isFirstGlyph = true;

    for (final codePoint in text.runes) {
      if (!isFirstGlyph) cursorX += letterSpacing;
      isFirstGlyph = false;

      final glyphIndex = glyphIndexForChar(codePoint);
      final glyph = getGlyph(glyphIndex);

      for (final cmd in glyph.commands) {
        commands.add(_scaleAndPosition(cmd, scale, cursorX, y));
      }

      cursorX += advanceWidth(glyphIndex) * scale;
    }

    return commands;
  }

  static PathCommand _scaleAndPosition(
    PathCommand cmd,
    double scale,
    double offsetX,
    double offsetY,
  ) {
    double tx(double gx) => gx * scale + offsetX;
    double ty(double gy) => -gy * scale + offsetY;

    return switch (cmd) {
      MoveToCommand(:final x, :final y) => MoveToCommand(tx(x), ty(y)),
      LineToCommand(:final x, :final y) => LineToCommand(tx(x), ty(y)),
      QuadToCommand(:final cx, :final cy, :final x, :final y) => QuadToCommand(
        tx(cx),
        ty(cy),
        tx(x),
        ty(y),
      ),
      CubicToCommand(
        :final cx1,
        :final cy1,
        :final cx2,
        :final cy2,
        :final x,
        :final y,
      ) =>
        CubicToCommand(tx(cx1), ty(cy1), tx(cx2), ty(cy2), tx(x), ty(y)),
      CloseCommand() => cmd,
    };
  }

  // ── Text to sampled points / contours ────────────────────────────────

  /// Returns sampled points along the outlines of [text] grouped by contour.
  ///
  /// Bezier sampling is performed once per unique glyph + sampling-params
  /// combo and cached in font-unit space; at query time each cached point
  /// is scaled, translated, and Y-flipped into screen space.
  ///
  /// [sampleFactor] density is interpreted in **pixel** space — bigger
  /// glyphs simply get more points, so visual spacing stays constant
  /// across font sizes (matching p5.js semantics). This is achieved by
  /// folding the font→pixel scale into the effective sample factor before
  /// the sampler runs.
  ///
  /// [letterSpacing] is extra pixel spacing inserted *between* glyphs —
  /// `N` glyphs get `N - 1` insertions, matching `textWidth` and the
  /// raster renderer. It shifts glyph origins only; it never affects the
  /// cached per-glyph sampling.
  List<List<Flut5Vector>> textToContours(
    String text,
    double x,
    double y,
    double fontSize, {
    double sampleFactor = 0.5,
    double simplifyThreshold = 0,
    double letterSpacing = 0,
  }) {
    final double scale = fontSize / unitsPerEm;
    final double effectiveSampleFactor = sampleFactor * scale;
    final result = <List<Flut5Vector>>[];
    double cursorX = x;
    bool isFirstGlyph = true;

    for (final codePoint in text.runes) {
      if (!isFirstGlyph) cursorX += letterSpacing;
      isFirstGlyph = false;

      final glyphIndex = glyphIndexForChar(codePoint);
      final cached = _getGlyphContours(
        glyphIndex,
        effectiveSampleFactor,
        simplifyThreshold,
      );

      for (final contour in cached) {
        final positioned = List<Flut5Vector>.generate(contour.length, (i) {
          final p = contour[i];
          return Flut5Vector(p.x * scale + cursorX, -p.y * scale + y);
        }, growable: false);
        result.add(positioned);
      }

      cursorX += advanceWidth(glyphIndex) * scale;
    }

    return result;
  }

  /// Returns sampled points along the outlines of [text] as a flat list.
  List<Flut5Vector> textToPoints(
    String text,
    double x,
    double y,
    double fontSize, {
    double sampleFactor = 0.5,
    double simplifyThreshold = 0,
    double letterSpacing = 0,
  }) {
    final contours = textToContours(
      text,
      x,
      y,
      fontSize,
      sampleFactor: sampleFactor,
      simplifyThreshold: simplifyThreshold,
      letterSpacing: letterSpacing,
    );
    final out = <Flut5Vector>[];
    for (final c in contours) {
      out.addAll(c);
    }
    return out;
  }

  // ── Text to grid ─────────────────────────────────────────────────────

  /// Rasterizes the outlines of [text] into a uniform grid of cells.
  ///
  /// The grid spans the tight bounding box of the outline — cell `(0, 0)` is
  /// its top-left corner. A cell is filled when an outline passes through it
  /// or its center lies inside the outline, and [Flut5CellState.empty]
  /// otherwise. Filled cells then split by neighborhood: [Flut5CellState.edge]
  /// when the cell touches the outside — on the box's rim, or 4-adjacent to an
  /// empty cell — and [Flut5CellState.interior] when it is walled in by filled
  /// cells on all four sides. `isFilled` covers both.
  ///
  /// Counters are handled by nonzero winding, so the hole in "O" comes back
  /// empty rather than filled.
  ///
  /// [cellSize] is the cell edge length in pixels and defaults to 4 — fixed
  /// rather than font-relative, so on-screen cell density is the same at
  /// every font size. Large text therefore samples into many more cells
  /// (cost grows with glyph area); at small font sizes pass a smaller
  /// [cellSize] to keep counters like `e` and `a` open. Outline sampling
  /// density is derived from it, so curves stay accurate to within half a
  /// cell however fine the grid gets.
  ///
  /// Cost scales with the cell count, which grows quadratically as
  /// [cellSize] shrinks. This is a build-once call, not a per-frame one.
  Flut5TextGrid textToGrid(
    String text,
    double x,
    double y,
    double fontSize, {
    double? cellSize,
    double letterSpacing = 0,
  }) {
    final double cell = (cellSize == null || cellSize <= 0) ? 4.0 : cellSize;
    if (cell <= 0 || !cell.isFinite) return Flut5TextGrid.empty;

    // A polyline vertex every half cell — the sampler's pixel step is
    // 3 / sampleFactor, so 6 / cell lands exactly there.
    final contours = textToContours(
      text,
      x,
      y,
      fontSize,
      sampleFactor: 6.0 / cell,
      letterSpacing: letterSpacing,
    );

    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    for (final contour in contours) {
      for (final p in contour) {
        if (p.x < minX) minX = p.x;
        if (p.x > maxX) maxX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.y > maxY) maxY = p.y;
      }
    }
    // Whitespace-only or an empty string leaves no outline to bound.
    if (minX > maxX || minY > maxY) return Flut5TextGrid.empty;

    final int cols = math.max(1, ((maxX - minX) / cell).ceil());
    final int rows = math.max(1, ((maxY - minY) / cell).ceil());

    final cells = List<List<Flut5CellState>>.generate(
      rows,
      (_) => List<Flut5CellState>.filled(cols, Flut5CellState.empty),
      growable: false,
    );

    // Edge pass — walk every contour segment and mark each cell it crosses.
    // Contours are closed with no repeated first point, so the last segment
    // wraps back to index 0.
    for (final contour in contours) {
      if (contour.length < 2) continue;
      for (int i = 0; i < contour.length; i++) {
        final a = contour[i];
        final b = contour[(i + 1) % contour.length];
        _markSegmentCells(cells, a, b, minX, minY, cell, cols, rows);
      }
    }

    // Fill pass — every cell the outline missed is cleanly in or out.
    final path = _composedPath(text, x, y, fontSize, letterSpacing);
    for (int r = 0; r < rows; r++) {
      final row = cells[r];
      final double cy = minY + (r + 0.5) * cell;
      for (int c = 0; c < cols; c++) {
        if (row[c] == Flut5CellState.edge) continue;
        if (path.contains(Offset(minX + (c + 0.5) * cell, cy))) {
          row[c] = Flut5CellState.interior;
        }
      }
    }

    // Boundary pass — the edge pass marks every cell an outline *touches*,
    // which over-marks wherever a stroke is thicker than a cell: a slanted
    // outline walks through two cells side by side and the inner one lands
    // fully surrounded by glyph. Edge is a border of the filled shape, so
    // demote anything walled in on all four sides. Off-grid counts as empty,
    // matching [Flut5TextGrid.stateAt], so the box's rim stays edge.
    //
    // This only swaps edge and interior — `isFilled` is invariant, so
    // neighbors can be read in place while the pass rewrites them.
    for (int r = 0; r < rows; r++) {
      final row = cells[r];
      for (int c = 0; c < cols; c++) {
        if (!row[c].isFilled) continue;
        final bool exposed =
            c == 0 ||
            c == cols - 1 ||
            r == 0 ||
            r == rows - 1 ||
            !row[c - 1].isFilled ||
            !row[c + 1].isFilled ||
            !cells[r - 1][c].isFilled ||
            !cells[r + 1][c].isFilled;
        row[c] = exposed ? Flut5CellState.edge : Flut5CellState.interior;
      }
    }

    return Flut5TextGrid(states: cells, x: minX, y: minY, cellSize: cell);
  }

  /// Builds one screen-space [Path] for [text], reusing the per-glyph path
  /// cache and composing with a scale + Y-flip + translate matrix.
  Path _composedPath(
    String text,
    double x,
    double y,
    double fontSize,
    double letterSpacing,
  ) {
    final double scale = fontSize / unitsPerEm;
    final path = Path();
    double cursorX = x;
    bool isFirstGlyph = true;

    for (final codePoint in text.runes) {
      if (!isFirstGlyph) cursorX += letterSpacing;
      isFirstGlyph = false;

      final glyphIndex = glyphIndexForChar(codePoint);
      final matrix = Float64List(16)
        ..[0] = scale
        ..[5] = -scale
        ..[10] = 1
        ..[12] = cursorX
        ..[13] = y
        ..[15] = 1;
      path.addPath(getGlyphPath(glyphIndex), Offset.zero, matrix4: matrix);

      cursorX += advanceWidth(glyphIndex) * scale;
    }

    return path;
  }

  /// Marks every cell the segment [a]–[b] passes through as an edge, using a
  /// grid traversal so no cell is skipped no matter how the segment slants.
  static void _markSegmentCells(
    List<List<Flut5CellState>> cells,
    Flut5Vector a,
    Flut5Vector b,
    double originX,
    double originY,
    double cellSize,
    int cols,
    int rows,
  ) {
    void mark(int col, int row) {
      // Points sitting exactly on the box's far edge floor to cols/rows;
      // clamp them back into the last cell rather than dropping them.
      final c = col.clamp(0, cols - 1);
      final r = row.clamp(0, rows - 1);
      cells[r][c] = Flut5CellState.edge;
    }

    final double gx0 = (a.x - originX) / cellSize;
    final double gy0 = (a.y - originY) / cellSize;
    final double gx1 = (b.x - originX) / cellSize;
    final double gy1 = (b.y - originY) / cellSize;
    if (!gx0.isFinite || !gy0.isFinite || !gx1.isFinite || !gy1.isFinite) {
      return;
    }

    int col = gx0.floor();
    int row = gy0.floor();
    final int endCol = gx1.floor();
    final int endRow = gy1.floor();
    mark(col, row);
    if (col == endCol && row == endRow) return;

    final double dx = gx1 - gx0;
    final double dy = gy1 - gy0;
    final int stepCol = dx > 0 ? 1 : (dx < 0 ? -1 : 0);
    final int stepRow = dy > 0 ? 1 : (dy < 0 ? -1 : 0);

    // Parametric distance to the first boundary crossing on each axis, then
    // the constant distance between crossings after that.
    double tMaxX = stepCol == 0
        ? double.infinity
        : (stepCol > 0 ? (col + 1) - gx0 : gx0 - col) / dx.abs();
    double tMaxY = stepRow == 0
        ? double.infinity
        : (stepRow > 0 ? (row + 1) - gy0 : gy0 - row) / dy.abs();
    final double tDeltaX = stepCol == 0 ? double.infinity : 1 / dx.abs();
    final double tDeltaY = stepRow == 0 ? double.infinity : 1 / dy.abs();

    // Manhattan distance bounds the walk; the guard keeps a pathological
    // float case from spinning.
    final int maxSteps = (endCol - col).abs() + (endRow - row).abs() + 2;
    for (int i = 0; i < maxSteps && (col != endCol || row != endRow); i++) {
      if (tMaxX < tMaxY) {
        col += stepCol;
        tMaxX += tDeltaX;
      } else {
        row += stepRow;
        tMaxY += tDeltaY;
      }
      mark(col, row);
    }
  }

  /// Returns cached sampled contours for [glyphIndex] in font-unit (y-up)
  /// space, sampling lazily on first access.
  List<List<Flut5Vector>> _getGlyphContours(
    int glyphIndex,
    double sampleFactor,
    double simplifyThreshold,
  ) {
    final key = (axisCacheKey, glyphIndex, sampleFactor, simplifyThreshold);
    final cached = _glyphContourCache.remove(key);
    if (cached != null) {
      _glyphContourCache[key] = cached;
      return cached;
    }

    final glyph = getGlyph(glyphIndex);
    final contours = Flut5GlyphSampler.sampleContours(
      glyph.commands,
      sampleFactor: sampleFactor,
      simplifyThreshold: simplifyThreshold,
    );
    _glyphContourCache[key] = contours;
    _trimLru(_glyphContourCache, variableGlyphContourCacheMaxSize);
    return contours;
  }
}

void _trimLru<K, V>(LinkedHashMap<K, V> cache, int maxSize) {
  while (cache.length > maxSize) {
    cache.remove(cache.keys.first);
  }
}
