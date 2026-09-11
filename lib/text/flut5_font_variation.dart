import 'dart:typed_data';

import 'flut5_hvar_decoder.dart';

/// A single variation axis declared by a variable font's `fvar` table.
///
/// Axes describe a continuous design dimension — weight, width, slant, optical
/// size, or any custom axis. The current value of an axis controls how glyph
/// outlines (via `gvar`) and advance widths (via `HVAR`) interpolate.
///
/// Standard registered tags:
/// - `wght` — weight, typically 1..1000, 400 = Regular, 700 = Bold
/// - `wdth` — width, typically 50..200, 100 = Normal
/// - `slnt` — slant in degrees, typically -90..0
/// - `ital` — italic, 0 (upright) or 1 (italic)
/// - `opsz` — optical size, in points
class const Flut5FontAxis({
  /// Four-character axis tag (e.g. `'wght'`, `'wdth'`).
  required final String tag,

  /// Minimum legal user-space value for this axis.
  required final double minValue,

  /// Default user-space value applied when no value has been set.
  required final double defaultValue,

  /// Maximum legal user-space value for this axis.
  required final double maxValue,

  /// Human-readable axis name from the font's `name` table, if available.
  final String? name,

  /// True if the axis is marked HIDDEN_AXIS in `fvar` flags — set by the
  /// font designer to signal that the axis is intended as an implementation
  /// detail, not user-facing.
  final bool hidden = false,
}) {
  /// Clamps a user-space [value] to this axis's legal range.
  double clampValue(double value) {
    if (value < minValue) return minValue;
    if (value > maxValue) return maxValue;
    return value;
  }

  /// Maps a user-space [value] to the normalized [-1, 0, +1] range used by
  /// the OpenType variation tables. Default → 0; minValue → -1; maxValue → +1.
  ///
  /// Note: this does not apply `avar` remapping. The font, if it has an
  /// `avar` table, should apply that after normalization.
  double normalize(double value) {
    final v = clampValue(value);
    if (v == defaultValue) return 0;
    if (v < defaultValue) {
      final span = defaultValue - minValue;
      return span == 0 ? 0 : (v - defaultValue) / span;
    }
    final span = maxValue - defaultValue;
    return span == 0 ? 0 : (v - defaultValue) / span;
  }
}

/// A predefined combination of axis values declared in `fvar` — e.g. a font
/// may ship named instances like "Bold", "Light Condensed", "Display".
///
/// Apply one with `flut5.fontInstance(name)`.
class const Flut5NamedInstance({
  /// The instance's subfamily name from the font's `name` table.
  required final String name,

  /// Axis-tag → user-space value for every axis in the font.
  required final Map<String, double> coordinates,
});

/// Internal: raw `gvar` table data plus the metadata needed to lazy-parse
/// a single glyph's tuple variation store on demand.
///
/// Storing this on [Flut5Font] keeps glyph variation lookups cheap while
/// avoiding a one-shot upfront parse of every glyph's deltas (a 1000-glyph
/// variable font with multiple shared/private tuples per glyph can be tens
/// of thousands of entries — most never visited).
/// @nodoc
class const Flut5GvarData({
  /// The raw `gvar` table contents as a ByteData view (offset 0 = table start).
  required final ByteData bytes,

  /// Number of variation axes — matches `fvar.axisCount`.
  required final int axisCount,

  /// Number of shared tuple records in the table-level shared-tuples array.
  required final int sharedTupleCount,

  /// Byte offset (from `bytes` start) of the shared tuples array.
  required final int sharedTuplesOffset,

  /// Byte offset (from `bytes` start) of the glyph variation data region.
  required final int glyphVariationDataArrayOffset,

  /// Per-glyph byte offsets into the glyph variation data region. Length
  /// is `numGlyphs + 1`; entry `i+1 - entry i` gives the glyph's size in bytes.
  /// A zero-length range means the glyph has no variations.
  required final List<int> glyphVariationDataOffsets,
});

/// Internal: parsed `avar` segment maps — piecewise-linear remapping of
/// normalized axis coordinates. Many fonts use this to make a value like
/// "wght=700" feel like genuine Bold rather than mid-interpolation.
/// @nodoc
class const Flut5AvarData(
  /// One segment map per axis (index matches `fvar` order). Each segment map
  /// is a sorted list of `(fromCoord, toCoord)` pairs in normalized space.
  final List<List<(double, double)>> axisSegmentMaps,
) {
  /// Applies the segment map for [axisIndex] to a normalized [coord].
  /// Returns [coord] unchanged if the axis has no segment map.
  double remap(int axisIndex, double coord) {
    if (axisIndex >= axisSegmentMaps.length) return coord;
    final map = axisSegmentMaps[axisIndex];
    if (map.isEmpty) return coord;
    for (int i = 0; i < map.length - 1; i++) {
      final (fromA, toA) = map[i];
      final (fromB, toB) = map[i + 1];
      if (coord >= fromA && coord <= fromB) {
        if (fromB == fromA) return toA;
        final t = (coord - fromA) / (fromB - fromA);
        return toA + t * (toB - toA);
      }
    }
    return coord;
  }
}

/// Internal: holds raw `HVAR` table bytes + a lazily-built parsed store.
/// Advance-width deltas are decoded on first use and cached on the instance.
/// @nodoc
class Flut5HvarData(final ByteData bytes) {
  Flut5HvarStore? _store;

  /// Advance-width delta in font units for [glyphIndex] at the current
  /// normalized axis position. Returns 0 when no contribution applies.
  double advanceDelta(int glyphIndex, List<double> normalizedCoords) {
    return (_store ??= Flut5HvarStore.fromBytes(
      bytes,
    )).advanceDelta(glyphIndex, normalizedCoords);
  }
}
