import 'dart:typed_data';

import '../core/flut5_console.dart';
import 'flut5_font.dart';
import 'flut5_font_variation.dart';
import 'flut5_glyph.dart';

/// Internal TTF/OTF binary parser.
///
/// Reads the table directory and extracts the tables needed for glyph
/// outline extraction. Supports both TrueType (glyf) and CFF outlines.
class Flut5FontParser {
  Flut5FontParser._();

  /// Parses a TTF or OTF font from raw [bytes].
  ///
  /// Throws [FormatException] on invalid data or unsupported format.
  static Flut5Font parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);

    // ── Table directory ────────────────────────────────────────────────
    final sfVersion = data.getUint32(0);
    final isCFF = sfVersion == 0x4F54544F; // 'OTTO'
    if (!isCFF && sfVersion != 0x00010000 && sfVersion != 0x74727565) {
      // 0x74727565 = 'true' (Apple TrueType)
      throw const FormatException('Not a valid TTF or OTF font file.');
    }

    final numTables = data.getUint16(4);
    final tables = <String, _TableRecord>{};
    for (int i = 0; i < numTables; i++) {
      final recordOffset = 12 + i * 16;
      final tag = String.fromCharCodes([
        data.getUint8(recordOffset),
        data.getUint8(recordOffset + 1),
        data.getUint8(recordOffset + 2),
        data.getUint8(recordOffset + 3),
      ]);
      tables[tag] = _TableRecord(
        offset: data.getUint32(recordOffset + 8),
        length: data.getUint32(recordOffset + 12),
      );
    }

    _TableRecord requireTable(String tag) {
      final rec = tables[tag];
      if (rec == null) throw FormatException("Required table '$tag' not found.");
      return rec;
    }

    final headRec = requireTable('head');
    final maxpRec = requireTable('maxp');
    final hheaRec = requireTable('hhea');
    final hmtxRec = requireTable('hmtx');
    final cmapRec = requireTable('cmap');

    // ── head ───────────────────────────────────────────────────────────
    final unitsPerEm = data.getUint16(headRec.offset + 18);
    final indexToLocFormat = data.getInt16(headRec.offset + 50);

    // ── maxp ───────────────────────────────────────────────────────────
    final numGlyphs = data.getUint16(maxpRec.offset + 4);

    // ── hhea ───────────────────────────────────────────────────────────
    final numberOfHMetrics = data.getUint16(hheaRec.offset + 34);

    // ── hmtx ───────────────────────────────────────────────────────────
    final advanceWidths = List<int>.filled(numGlyphs, 0);
    final lsbs = List<int>.filled(numGlyphs, 0);
    int off = hmtxRec.offset;
    for (int i = 0; i < numberOfHMetrics; i++) {
      advanceWidths[i] = data.getUint16(off);
      lsbs[i] = data.getInt16(off + 2);
      off += 4;
    }
    if (numberOfHMetrics > 0) {
      final lastAW = advanceWidths[numberOfHMetrics - 1];
      for (int i = numberOfHMetrics; i < numGlyphs; i++) {
        advanceWidths[i] = lastAW;
        lsbs[i] = data.getInt16(off);
        off += 2;
      }
    }

    // ── cmap ───────────────────────────────────────────────────────────
    final charToGlyph = _parseCmap(data, cmapRec.offset);

    final glyphs = List<Flut5Glyph?>.filled(numGlyphs, null);

    // ── Variable-font tables (all optional) ────────────────────────────
    // Resolve axis / instance names from the `name` table when present, then
    // parse `fvar` for axis records + named instances. `avar` / `gvar` / `HVAR`
    // are parsed lazily — only their bytes are captured here.
    final nameRec = tables['name'];
    final nameMap = nameRec == null
        ? const <int, String>{}
        : _parseNameTable(data, nameRec.offset);

    final fvarRec = tables['fvar'];
    final (axes, namedInstances) = fvarRec == null
        ? (const <Flut5FontAxis>[], const <Flut5NamedInstance>[])
        : _parseFvar(data, fvarRec.offset, nameMap);

    final avarRec = tables['avar'];
    final avar = (avarRec == null || axes.isEmpty)
        ? null
        : _parseAvar(data, avarRec.offset, axes.length);

    final gvarRec = tables['gvar'];
    final gvar = (gvarRec == null || axes.isEmpty || isCFF)
        ? null
        : _parseGvarHeader(bytes, gvarRec.offset, gvarRec.length, numGlyphs);

    final hvarRec = tables['HVAR'];
    final hvar = (hvarRec == null || axes.isEmpty)
        ? null
        : Flut5HvarData(
            ByteData.sublistView(
              bytes, hvarRec.offset, hvarRec.offset + hvarRec.length,
            ),
          );

    if (isCFF) {
      // ── CFF outlines ─────────────────────────────────────────────────
      // CFF2 is the variation-aware successor of CFF — its charstrings use
      // a different operator set and depend on an item-variation store
      // baked into the table. We don't decode CFF2 yet, so a font that
      // ships only CFF2 (no CFF1 fallback) loads with its axes still
      // inspectable but with no glyph outlines.
      final cffRec = tables['CFF '];
      if (cffRec == null && tables['CFF2'] != null) {
        Flut5Console.printLater(
          'Flut5: CFF2-based variable fonts are not supported. The font '
          "loaded but its glyph outlines will render empty. Use a TrueType "
          'variable font (with glyf + gvar) instead.',
        );
        return Flut5Font.internal(
          unitsPerEm: unitsPerEm,
          numGlyphs: numGlyphs,
          numberOfHMetrics: numberOfHMetrics,
          charToGlyph: charToGlyph,
          glyphs: glyphs,
          advanceWidths: advanceWidths,
          lsbs: lsbs,
          axes: axes,
          namedInstances: namedInstances,
          avar: avar,
          hvar: hvar,
        );
      }
      final cffData = _parseCFF(data, bytes, cffRec!.offset);
      return Flut5Font.internal(
        unitsPerEm: unitsPerEm,
        numGlyphs: numGlyphs,
        numberOfHMetrics: numberOfHMetrics,
        charToGlyph: charToGlyph,
        glyphs: glyphs,
        advanceWidths: advanceWidths,
        lsbs: lsbs,
        cffData: cffData,
        axes: axes,
        namedInstances: namedInstances,
        avar: avar,
        hvar: hvar,
      );
    } else {
      // ── TrueType outlines ─────────────────────────────────────────────
      final locaRec = requireTable('loca');
      final glyfRec = requireTable('glyf');

      final locaOffsets = List<int>.filled(numGlyphs + 1, 0);
      if (indexToLocFormat == 0) {
        for (int i = 0; i <= numGlyphs; i++) {
          locaOffsets[i] = data.getUint16(locaRec.offset + i * 2) * 2;
        }
      } else {
        for (int i = 0; i <= numGlyphs; i++) {
          locaOffsets[i] = data.getUint32(locaRec.offset + i * 4);
        }
      }

      final glyfData = ByteData.sublistView(
        bytes, glyfRec.offset, glyfRec.offset + glyfRec.length,
      );

      return Flut5Font.internal(
        unitsPerEm: unitsPerEm,
        numGlyphs: numGlyphs,
        numberOfHMetrics: numberOfHMetrics,
        charToGlyph: charToGlyph,
        glyphs: glyphs,
        advanceWidths: advanceWidths,
        lsbs: lsbs,
        glyfData: glyfData,
        locaOffsets: locaOffsets,
        axes: axes,
        namedInstances: namedInstances,
        gvar: gvar,
        avar: avar,
        hvar: hvar,
      );
    }
  }

  // ── name table parsing ────────────────────────────────────────────────

  /// Builds a `nameID → string` map from the font's `name` table. Prefers
  /// Windows Unicode entries (platform 3, encoding 1) at English-US
  /// (language 0x0409), falling back to the first matching entry per nameID.
  ///
  /// Strings outside platform 3 (e.g. legacy Mac entries) are not decoded
  /// since fvar/STAT always include a platform-3 entry on any modern font.
  static Map<int, String> _parseNameTable(ByteData data, int tableOffset) {
    final count = data.getUint16(tableOffset + 2);
    final stringStorageOffset = tableOffset + data.getUint16(tableOffset + 4);

    final preferred = <int, String>{};
    final fallback = <int, String>{};

    for (int i = 0; i < count; i++) {
      final recOff = tableOffset + 6 + i * 12;
      final platformID = data.getUint16(recOff);
      final encodingID = data.getUint16(recOff + 2);
      final languageID = data.getUint16(recOff + 4);
      final nameID = data.getUint16(recOff + 6);
      final length = data.getUint16(recOff + 8);
      final stringOffset = data.getUint16(recOff + 10);

      // Only decode Windows-Unicode entries (UTF-16BE).
      if (platformID != 3 || encodingID != 1) continue;

      final start = stringStorageOffset + stringOffset;
      if (start + length > data.lengthInBytes) continue;

      final codeUnits = List<int>.generate(
        length ~/ 2,
        (j) => data.getUint16(start + j * 2),
        growable: false,
      );
      final str = String.fromCharCodes(codeUnits);

      if (languageID == 0x0409) {
        preferred[nameID] = str;
      } else {
        fallback.putIfAbsent(nameID, () => str);
      }
    }

    // Merge: preferred (English-US) wins, fallback fills gaps.
    final out = Map<int, String>.from(fallback);
    out.addAll(preferred);
    return out;
  }

  // ── fvar parsing ──────────────────────────────────────────────────────

  /// Parses the `fvar` table: variation axis records + named instances.
  ///
  /// Layout: version(4), axesArrayOffset(2), reserved(2), axisCount(2),
  /// axisSize(2), instanceCount(2), instanceSize(2). Axis records start
  /// at `tableOffset + axesArrayOffset` and run axisCount × axisSize bytes;
  /// instance records follow immediately after.
  static (List<Flut5FontAxis>, List<Flut5NamedInstance>) _parseFvar(
    ByteData data,
    int tableOffset,
    Map<int, String> nameMap,
  ) {
    final axesArrayOffset = data.getUint16(tableOffset + 4);
    final axisCount = data.getUint16(tableOffset + 8);
    final axisSize = data.getUint16(tableOffset + 10);
    final instanceCount = data.getUint16(tableOffset + 12);
    final instanceSize = data.getUint16(tableOffset + 14);

    // ── Axis records ────────────────────────────────────────────────────
    final axes = <Flut5FontAxis>[];
    int off = tableOffset + axesArrayOffset;
    for (int i = 0; i < axisCount; i++) {
      final tag = String.fromCharCodes([
        data.getUint8(off),
        data.getUint8(off + 1),
        data.getUint8(off + 2),
        data.getUint8(off + 3),
      ]);
      final minValue = _readFixed(data, off + 4);
      final defaultValue = _readFixed(data, off + 8);
      final maxValue = _readFixed(data, off + 12);
      final flags = data.getUint16(off + 16);
      final axisNameID = data.getUint16(off + 18);

      axes.add(
        Flut5FontAxis(
          tag: tag,
          minValue: minValue,
          defaultValue: defaultValue,
          maxValue: maxValue,
          name: nameMap[axisNameID],
          hidden: (flags & 0x0001) != 0,
        ),
      );
      off += axisSize;
    }

    // ── Named instances ─────────────────────────────────────────────────
    final instances = <Flut5NamedInstance>[];
    // Bytes used by axis coords (Fixed16.16, 4 bytes each).
    final coordsBytes = axisCount * 4;
    // Per the spec instanceSize is either 4 + coordsBytes (no PS name) or
    // 6 + coordsBytes (with PS name). Anything else means malformed data.
    if (instanceSize == 4 + coordsBytes || instanceSize == 6 + coordsBytes) {
      for (int i = 0; i < instanceCount; i++) {
        final subfamilyNameID = data.getUint16(off);
        // flags = uint16 at off+2 — currently unused.
        final coords = <String, double>{};
        for (int a = 0; a < axisCount; a++) {
          coords[axes[a].tag] = _readFixed(data, off + 4 + a * 4);
        }
        final name = nameMap[subfamilyNameID];
        if (name != null) {
          instances.add(Flut5NamedInstance(name: name, coordinates: coords));
        }
        off += instanceSize;
      }
    }

    return (axes, instances);
  }

  // ── avar parsing ──────────────────────────────────────────────────────

  /// Parses the `avar` table: piecewise-linear axis-coord remap segments.
  ///
  /// Returns null if the table is malformed or its axis count doesn't match
  /// `fvar`. Tables that store only the identity map ((−1,−1),(0,0),(1,1))
  /// for every axis are returned as-is; remap() short-circuits to a no-op.
  static Flut5AvarData? _parseAvar(
    ByteData data,
    int tableOffset,
    int fvarAxisCount,
  ) {
    final axisCount = data.getUint16(tableOffset + 6);
    if (axisCount != fvarAxisCount) return null;

    final maps = <List<(double, double)>>[];
    int off = tableOffset + 8;
    for (int a = 0; a < axisCount; a++) {
      final positionMapCount = data.getUint16(off);
      off += 2;
      final segments = <(double, double)>[];
      for (int i = 0; i < positionMapCount; i++) {
        final fromCoord = data.getInt16(off) / 16384.0;
        final toCoord = data.getInt16(off + 2) / 16384.0;
        segments.add((fromCoord, toCoord));
        off += 4;
      }
      maps.add(segments);
    }
    return Flut5AvarData(maps);
  }

  // ── gvar header parsing ───────────────────────────────────────────────

  /// Reads the `gvar` table header and per-glyph offset array; per-glyph
  /// tuple-variation parsing is deferred to delta-application time.
  ///
  /// Layout: majorVersion(2), minorVersion(2), axisCount(2),
  /// sharedTupleCount(2), sharedTuplesOffset(4), glyphCount(2), flags(2),
  /// glyphVariationDataArrayOffset(4), then `glyphCount + 1` offsets
  /// (uint16 doubled, or uint32 depending on flags bit 0).
  static Flut5GvarData? _parseGvarHeader(
    Uint8List bytes,
    int tableOffset,
    int tableLength,
    int numGlyphs,
  ) {
    final data = ByteData.sublistView(
      bytes, tableOffset, tableOffset + tableLength,
    );
    final axisCount = data.getUint16(4);
    final sharedTupleCount = data.getUint16(6);
    final sharedTuplesOffset = data.getUint32(8);
    final glyphCount = data.getUint16(12);
    final flags = data.getUint16(14);
    final dataArrayOffset = data.getUint32(16);

    // `gvar.glyphCount` should match maxp.numGlyphs but some fonts ship a
    // smaller value when trailing glyphs have no variations. Use the smaller
    // count to bound the offset reads, then pad the rest with zero-length
    // ranges so per-glyph lookups stay in bounds.
    final headerGlyphCount = glyphCount < numGlyphs ? glyphCount : numGlyphs;
    final useLongOffsets = (flags & 0x0001) != 0;
    final offsets = List<int>.filled(numGlyphs + 1, 0);
    int off = 20;
    if (useLongOffsets) {
      for (int i = 0; i <= headerGlyphCount; i++) {
        offsets[i] = data.getUint32(off);
        off += 4;
      }
    } else {
      for (int i = 0; i <= headerGlyphCount; i++) {
        offsets[i] = data.getUint16(off) * 2;
        off += 2;
      }
    }
    // Pad trailing glyphs with the last offset so size = next - this = 0.
    final lastValid = offsets[headerGlyphCount];
    for (int i = headerGlyphCount + 1; i <= numGlyphs; i++) {
      offsets[i] = lastValid;
    }

    return Flut5GvarData(
      bytes: data,
      axisCount: axisCount,
      sharedTupleCount: sharedTupleCount,
      sharedTuplesOffset: sharedTuplesOffset,
      glyphVariationDataArrayOffset: dataArrayOffset,
      glyphVariationDataOffsets: offsets,
    );
  }

  /// Reads a Fixed16.16 (32-bit signed, 16-bit fractional) at [offset].
  static double _readFixed(ByteData data, int offset) {
    return data.getInt32(offset) / 65536.0;
  }

  // ── CFF table parsing ─────────────────────────────────────────────────

  static CFFData _parseCFF(ByteData data, Uint8List bytes, int cffBase) {
    // CFF header: major(1) minor(1) hdrSize(1) offSize(1)
    final hdrSize = data.getUint8(cffBase + 2);
    int off = cffBase + hdrSize;

    // Name INDEX — skip
    off += _cffIndexByteSize(data, off);

    // Top DICT INDEX — read first entry
    final topDictItems = _parseCFFIndex(data, bytes, off);
    off += _cffIndexByteSize(data, off);

    // String INDEX — skip
    off += _cffIndexByteSize(data, off);

    // Global Subr INDEX
    final globalSubrs = _parseCFFIndex(data, bytes, off);

    if (topDictItems.isEmpty) {
      throw const FormatException('Empty CFF Top DICT INDEX.');
    }
    final topDict = _parseCFFDict(topDictItems[0]);

    // CharStrings INDEX
    final csOffset = cffBase + (topDict[17]?.firstOrNull?.toInt() ?? 0);
    final charStrings = _parseCFFIndex(data, bytes, csOffset);

    // Private DICT → local subrs, defaultWidthX, nominalWidthX
    var defaultWidthX = 0.0;
    var nominalWidthX = 0.0;
    var localSubrs = <Uint8List>[];

    final privateEntry = topDict[18];
    if (privateEntry != null && privateEntry.length >= 2) {
      final privateSize = privateEntry[0].toInt();
      final privateOffset = cffBase + privateEntry[1].toInt();
      final privateBytes = Uint8List.sublistView(
        bytes, privateOffset, privateOffset + privateSize,
      );
      final privateDict = _parseCFFDict(privateBytes);

      defaultWidthX = (privateDict[20]?.firstOrNull ?? 0).toDouble();
      nominalWidthX = (privateDict[21]?.firstOrNull ?? 0).toDouble();

      final localSubrEntry = privateDict[19];
      if (localSubrEntry != null) {
        final localSubrOffset = privateOffset + localSubrEntry.first.toInt();
        localSubrs = _parseCFFIndex(data, bytes, localSubrOffset);
      }
    }

    return CFFData(
      charStrings: charStrings,
      globalSubrs: globalSubrs,
      localSubrs: localSubrs,
      defaultWidthX: defaultWidthX,
      nominalWidthX: nominalWidthX,
    );
  }

  /// Returns byte size of a CFF INDEX structure (header + offsets + data).
  static int _cffIndexByteSize(ByteData data, int offset) {
    final count = data.getUint16(offset);
    if (count == 0) return 2;
    final offSize = data.getUint8(offset + 2);
    final lastOffPos = offset + 3 + count * offSize;
    final lastOff = _readCFFOffset(data, lastOffPos, offSize);
    return 3 + (count + 1) * offSize + lastOff - 1;
  }

  /// Extracts all items from a CFF INDEX as zero-copy [Uint8List] views.
  static List<Uint8List> _parseCFFIndex(ByteData data, Uint8List bytes, int offset) {
    final count = data.getUint16(offset);
    if (count == 0) return const [];
    final offSize = data.getUint8(offset + 2);
    final offsetsBase = offset + 3;
    final dataBase = offsetsBase + (count + 1) * offSize;
    final items = <Uint8List>[];
    for (int i = 0; i < count; i++) {
      final start = _readCFFOffset(data, offsetsBase + i * offSize, offSize) - 1;
      final end = _readCFFOffset(data, offsetsBase + (i + 1) * offSize, offSize) - 1;
      items.add(Uint8List.sublistView(bytes, dataBase + start, dataBase + end));
    }
    return items;
  }

  static int _readCFFOffset(ByteData data, int offset, int offSize) {
    int val = 0;
    for (int i = 0; i < offSize; i++) {
      val = (val << 8) | data.getUint8(offset + i);
    }
    return val;
  }

  /// Parses a CFF DICT from a [Uint8List] item (from a CFF INDEX).
  /// Returns operator → argument list.
  static Map<int, List<num>> _parseCFFDict(Uint8List item) {
    final result = <int, List<num>>{};
    final stack = <num>[];
    int i = 0;

    while (i < item.length) {
      final b = item[i];
      if (b == 28) {
        // 2-byte integer
        final val = (item[i + 1] << 8) | item[i + 2];
        stack.add(val > 32767 ? val - 65536 : val);
        i += 3;
      } else if (b == 29) {
        // 4-byte integer
        final val = (item[i + 1] << 24) | (item[i + 2] << 16) |
                    (item[i + 3] << 8)  |  item[i + 4];
        stack.add(val > 2147483647 ? val - 4294967296 : val);
        i += 5;
      } else if (b == 30) {
        // Real number — parse nibble-encoded float
        double real = _parseCFFReal(item, i + 1);
        final end = _skipCFFReal(item, i + 1);
        stack.add(real);
        i = end;
      } else if (b >= 32 && b <= 246) {
        stack.add(b - 139);
        i++;
      } else if (b >= 247 && b <= 250) {
        stack.add((b - 247) * 256 + item[i + 1] + 108);
        i += 2;
      } else if (b >= 251 && b <= 254) {
        stack.add(-(b - 251) * 256 - item[i + 1] - 108);
        i += 2;
      } else if (b == 12) {
        // Two-byte operator
        result[1200 + item[i + 1]] = List.unmodifiable(stack);
        stack.clear();
        i += 2;
      } else {
        // One-byte operator
        result[b] = List.unmodifiable(stack);
        stack.clear();
        i++;
      }
    }
    return result;
  }

  static double _parseCFFReal(Uint8List item, int start) {
    final buf = StringBuffer();
    int i = start;
    while (i < item.length) {
      final byte = item[i++];
      for (int shift in [4, 0]) {
        final nibble = (byte >> shift) & 0xF;
        if (nibble == 0xF) return double.tryParse(buf.toString()) ?? 0;
        if (nibble == 0xE) { buf.write('-'); continue; }
        if (nibble == 0xD) continue; // reserved
        if (nibble == 0xC) { buf.write('E-'); continue; }
        if (nibble == 0xB) { buf.write('E'); continue; }
        if (nibble == 0xA) { buf.write('.'); continue; }
        buf.write(nibble);
      }
    }
    return double.tryParse(buf.toString()) ?? 0;
  }

  static int _skipCFFReal(Uint8List item, int start) {
    int i = start;
    while (i < item.length) {
      final byte = item[i++];
      if ((byte & 0xF) == 0xF || (byte >> 4) == 0xF) return i;
    }
    return i;
  }

  // ── cmap parsing ─────────────────────────────────────────────────────

  static Map<int, int> _parseCmap(ByteData data, int tableOffset) {
    final numSubtables = data.getUint16(tableOffset + 2);

    int? format12Offset;
    int? format4Offset;

    for (int i = 0; i < numSubtables; i++) {
      final recOff = tableOffset + 4 + i * 8;
      final platformID = data.getUint16(recOff);
      final encodingID = data.getUint16(recOff + 2);
      final subtableOffset = tableOffset + data.getUint32(recOff + 4);
      final format = data.getUint16(subtableOffset);

      if (format == 12) {
        if ((platformID == 3 && encodingID == 10) ||
            (platformID == 0 && encodingID >= 3)) {
          format12Offset = subtableOffset;
        }
      }
      if (format == 4) {
        if ((platformID == 3 && encodingID == 1) || platformID == 0) {
          format4Offset ??= subtableOffset;
        }
      }
    }

    if (format12Offset != null) return _parseCmapFormat12(data, format12Offset);
    if (format4Offset != null) return _parseCmapFormat4(data, format4Offset);

    throw const FormatException(
      'No supported cmap subtable found (need Format 4 or 12).',
    );
  }

  static Map<int, int> _parseCmapFormat4(ByteData data, int offset) {
    final segCountX2 = data.getUint16(offset + 6);
    final segCount = segCountX2 ~/ 2;
    final endCodesOff = offset + 14;
    final startCodesOff = endCodesOff + segCountX2 + 2;
    final idDeltasOff = startCodesOff + segCountX2;
    final idRangeOffsetsOff = idDeltasOff + segCountX2;

    final map = <int, int>{};
    for (int s = 0; s < segCount; s++) {
      final endCode = data.getUint16(endCodesOff + s * 2);
      final startCode = data.getUint16(startCodesOff + s * 2);
      final idDelta = data.getInt16(idDeltasOff + s * 2);
      final idRangeOffset = data.getUint16(idRangeOffsetsOff + s * 2);
      if (startCode == 0xFFFF) break;

      for (int c = startCode; c <= endCode; c++) {
        int glyphIndex;
        if (idRangeOffset == 0) {
          glyphIndex = (c + idDelta) & 0xFFFF;
        } else {
          final glyphIdAddr = idRangeOffsetsOff + s * 2 +
              idRangeOffset + 2 * (c - startCode);
          glyphIndex = data.getUint16(glyphIdAddr);
          if (glyphIndex != 0) glyphIndex = (glyphIndex + idDelta) & 0xFFFF;
        }
        if (glyphIndex != 0) map[c] = glyphIndex;
      }
    }
    return map;
  }

  static Map<int, int> _parseCmapFormat12(ByteData data, int offset) {
    final numGroups = data.getUint32(offset + 12);
    final map = <int, int>{};
    int off = offset + 16;
    for (int g = 0; g < numGroups; g++) {
      final startCharCode = data.getUint32(off);
      final endCharCode = data.getUint32(off + 4);
      final startGlyphID = data.getUint32(off + 8);
      off += 12;
      for (int c = startCharCode; c <= endCharCode; c++) {
        final glyphIndex = startGlyphID + (c - startCharCode);
        if (glyphIndex != 0) map[c] = glyphIndex;
      }
    }
    return map;
  }
}

class _TableRecord {
  final int offset;
  final int length;
  const _TableRecord({required this.offset, required this.length});
}
