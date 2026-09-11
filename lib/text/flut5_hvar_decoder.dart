import 'dart:typed_data';

/// Parsed `HVAR` table — variable advance-width deltas.
///
/// HVAR stores per-glyph horizontal-metric variations as a delta-set
/// indexed through an item variation store (the same structure used by
/// MVAR / COLR / etc.). Lookup steps:
///   1. Map [glyphIndex] → (outerIndex, innerIndex). When the table has no
///      advance-width mapping, outer is 0 and inner is [glyphIndex].
///   2. outerIndex picks an `ItemVariationData` subtable.
///   3. innerIndex picks one row inside it; each row holds one int per
///      region in the subtable's region-index list.
///   4. Sum (regionScalar × delta) across all deltas in the row.
///
/// LSB and RSB mappings are present in some fonts but rarely consulted by
/// renderers — we only decode the advance-width path.
class const Flut5HvarStore._({
  required final List<_VariationRegion> _regions,
  required final List<_ItemVariationData> _itemVariationData,
  required final _DeltaSetIndexMap? _advanceWidthMap,
}) {
  /// Parses a complete HVAR table from its raw bytes (offset 0 = table start).
  factory Flut5HvarStore.fromBytes(ByteData bytes) {
    // HVAR header: majorVersion(2), minorVersion(2),
    //   itemVariationStoreOffset(4), advanceWidthMappingOffset(4),
    //   lsbMappingOffset(4), rsbMappingOffset(4)
    final ivsOffset = bytes.getUint32(4);
    final advMapOffset = bytes.getUint32(8);

    final (regions, ivData) = _parseItemVariationStore(bytes, ivsOffset);
    final advMap = advMapOffset == 0
        ? null
        : _parseDeltaSetIndexMap(bytes, advMapOffset);

    return Flut5HvarStore._(
      regions: regions,
      itemVariationData: ivData,
      advanceWidthMap: advMap,
    );
  }

  /// Returns the advance-width delta in font units for [glyphIndex] at the
  /// current [normalizedCoords]. Returns 0 when no contribution applies
  /// (e.g. all axes at default, or glyph not referenced).
  double advanceDelta(int glyphIndex, List<double> normalizedCoords) {
    int outer, inner;
    final map = _advanceWidthMap;
    if (map != null) {
      final (o, i) = map.lookup(glyphIndex);
      outer = o;
      inner = i;
    } else {
      // Spec: when the mapping is absent, the inner index equals the glyph
      // ID and outer is implicitly 0. Many fonts use the implicit form when
      // every glyph maps 1:1 to row N of the only ItemVariationData subtable.
      outer = 0;
      inner = glyphIndex;
    }

    if (outer >= _itemVariationData.length) return 0;
    final ivd = _itemVariationData[outer];
    if (inner >= ivd.itemCount) return 0;

    double total = 0;
    final regionIdxs = ivd.regionIndexes;
    for (int r = 0; r < regionIdxs.length; r++) {
      final regionIdx = regionIdxs[r];
      if (regionIdx >= _regions.length) continue;
      final scalar = _regions[regionIdx].scalar(normalizedCoords);
      if (scalar == 0) continue;
      total += scalar * ivd.delta(inner, r);
    }
    return total;
  }
}

// ── ItemVariationStore parsing ───────────────────────────────────────────

(List<_VariationRegion>, List<_ItemVariationData>) _parseItemVariationStore(
  ByteData bytes,
  int ivsOffset,
) {
  // ItemVariationStore: format(2), variationRegionListOffset(4),
  //   itemVariationDataCount(2), itemVariationDataOffsets[count] (4 each)
  final regionListOffset = ivsOffset + bytes.getUint32(ivsOffset + 2);
  final ivdCount = bytes.getUint16(ivsOffset + 6);

  final regions = _parseVariationRegionList(bytes, regionListOffset);

  final ivdList = <_ItemVariationData>[];
  for (int i = 0; i < ivdCount; i++) {
    final off = ivsOffset + bytes.getUint32(ivsOffset + 8 + i * 4);
    ivdList.add(_parseItemVariationData(bytes, off));
  }
  return (regions, ivdList);
}

List<_VariationRegion> _parseVariationRegionList(ByteData bytes, int offset) {
  final axisCount = bytes.getUint16(offset);
  final regionCount = bytes.getUint16(offset + 2);
  final regions = <_VariationRegion>[];
  int off = offset + 4;
  for (int r = 0; r < regionCount; r++) {
    final axes = <_RegionAxis>[];
    for (int a = 0; a < axisCount; a++) {
      final start = bytes.getInt16(off) / 16384.0;
      final peak = bytes.getInt16(off + 2) / 16384.0;
      final end = bytes.getInt16(off + 4) / 16384.0;
      axes.add(_RegionAxis(start: start, peak: peak, end: end));
      off += 6;
    }
    regions.add(_VariationRegion(axes));
  }
  return regions;
}

_ItemVariationData _parseItemVariationData(ByteData bytes, int offset) {
  final itemCount = bytes.getUint16(offset);
  final shortDeltaCount = bytes.getUint16(offset + 2);
  final regionIndexCount = bytes.getUint16(offset + 4);

  final regionIndexes = List<int>.generate(
    regionIndexCount,
    (i) => bytes.getUint16(offset + 6 + i * 2),
    growable: false,
  );

  final deltasOffset = offset + 6 + regionIndexCount * 2;
  // Each row: shortDeltaCount × int16 then (regionIndexCount - shortDeltaCount) × int8
  final rowBytes = shortDeltaCount * 2 + (regionIndexCount - shortDeltaCount);

  return _ItemVariationData(
    itemCount: itemCount,
    shortDeltaCount: shortDeltaCount,
    regionIndexes: regionIndexes,
    bytes: bytes,
    deltasOffset: deltasOffset,
    rowBytes: rowBytes,
  );
}

// ── DeltaSetIndexMap parsing ─────────────────────────────────────────────

_DeltaSetIndexMap _parseDeltaSetIndexMap(ByteData bytes, int offset) {
  // Format 0: format(1), entryFormat(1), mapCount(2), mapData
  // Format 1: format(1), entryFormat(1), mapCount(4), mapData
  final format = bytes.getUint8(offset);
  final entryFormat = bytes.getUint8(offset + 1);
  final int mapCount;
  final int dataOffset;
  if (format == 0) {
    mapCount = bytes.getUint16(offset + 2);
    dataOffset = offset + 4;
  } else {
    mapCount = bytes.getUint32(offset + 2);
    dataOffset = offset + 6;
  }
  // entryFormat: bits 4..5 = (entrySize - 1) range 1..4; bits 0..3 =
  //              (innerIndexBitCount - 1)
  final entrySize = ((entryFormat >> 4) & 0x03) + 1;
  final innerBitCount = (entryFormat & 0x0F) + 1;
  return _DeltaSetIndexMap(
    bytes: bytes,
    dataOffset: dataOffset,
    mapCount: mapCount,
    entrySize: entrySize,
    innerBitCount: innerBitCount,
  );
}

// ── Internal types ──────────────────────────────────────────────────────

class const _RegionAxis({
  required final double start,
  required final double peak,
  required final double end,
});

class const _VariationRegion(final List<_RegionAxis> axes) {
  /// Computes the contribution scalar for this region at [coords]. Returns 0
  /// when the position falls outside the region's span on any axis.
  double scalar(List<double> coords) {
    double scale = 1.0;
    for (int a = 0; a < axes.length; a++) {
      final axis = axes[a];
      final c = a < coords.length ? coords[a] : 0.0;
      final start = axis.start;
      final peak = axis.peak;
      final end = axis.end;

      // Per spec: invalid region descriptions (peak crossing zero asymmetrically,
      // start > peak, or peak > end) contribute scalar 1 i.e. no effect on
      // this axis. Real-world fonts rarely emit them.
      if (start > peak || peak > end) continue;
      if (start < 0 && end > 0 && peak != 0) continue;
      if (peak == 0) continue;
      if (c < start || c > end) return 0;
      if (c == peak) continue;
      if (c < peak) {
        final denom = peak - start;
        if (denom == 0) continue;
        scale *= (c - start) / denom;
      } else {
        final denom = end - peak;
        if (denom == 0) continue;
        scale *= (end - c) / denom;
      }
      if (scale == 0) return 0;
    }
    return scale;
  }
}

class const _ItemVariationData({
  required final int itemCount,
  required final int shortDeltaCount,
  required final List<int> regionIndexes,
  required final ByteData bytes,
  required final int deltasOffset,
  required final int rowBytes,
}) {
  /// Returns the delta for row [item] and region-index slot [r].
  /// The first [shortDeltaCount] slots are int16; the rest are int8.
  int delta(int item, int r) {
    final rowStart = deltasOffset + item * rowBytes;
    if (r < shortDeltaCount) {
      return bytes.getInt16(rowStart + r * 2);
    }
    final byteOff = rowStart + shortDeltaCount * 2 + (r - shortDeltaCount);
    return bytes.getInt8(byteOff);
  }
}

class const _DeltaSetIndexMap({
  required final ByteData bytes,
  required final int dataOffset,
  required final int mapCount,
  required final int entrySize,
  required final int innerBitCount,
}) {
  /// Looks up the (outer, inner) variation-data index for [glyphIndex].
  /// Glyphs past [mapCount - 1] reuse the last entry (per spec).
  (int, int) lookup(int glyphIndex) {
    final i = glyphIndex >= mapCount ? mapCount - 1 : glyphIndex;
    if (i < 0) return (0, 0);
    final off = dataOffset + i * entrySize;
    int raw = 0;
    for (int b = 0; b < entrySize; b++) {
      raw = (raw << 8) | bytes.getUint8(off + b);
    }
    final innerMask = (1 << innerBitCount) - 1;
    final inner = raw & innerMask;
    final outer = raw >> innerBitCount;
    return (outer, inner);
  }
}
