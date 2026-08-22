import 'package:flutter/material.dart';

/// Resolves shadow input into a [List<BoxShadow>].
/// Accepts: a single [BoxShadow], a [List<BoxShadow>], a [Map] (parsed),
/// or a [List<Map>] (each parsed). Returns null if [value] is null or unrecognised.
List<BoxShadow>? resolveShadows(dynamic value) {
  if (value == null) return null;
  if (value is BoxShadow) return [value];
  if (value is List<BoxShadow>) return value;
  if (value is Map) return [_mapToBoxShadow(value)];
  if (value is List) {
    return value
        .map((e) => e is BoxShadow ? e : _mapToBoxShadow(e as Map))
        .toList();
  }
  return null;
}

/// Parses a map into a [BoxShadow].
/// Supported keys: color, blur, spread, offset (Offset), offsetX, offsetY.
/// [offset] takes precedence over [offsetX]/[offsetY] if both are provided.
BoxShadow _mapToBoxShadow(Map map) {
  final Offset offset = (map['offset'] as Offset?) ??
      Offset(
        (map['offsetX'] as num?)?.toDouble() ?? 0.0,
        (map['offsetY'] as num?)?.toDouble() ?? 0.0,
      );
  return BoxShadow(
    color: (map['color'] as Color?) ?? const Color(0x33000000),
    blurRadius: (map['blur'] as num?)?.toDouble() ?? 0.0,
    spreadRadius: (map['spread'] as num?)?.toDouble() ?? 0.0,
    offset: offset,
  );
}

/// Builds a [BoxDecoration] from a style map.
/// Supported keys: backgroundColor, borderColor, borderWeight, borderRadius, shadow.
BoxDecoration buildDecoration(Map<String, dynamic> map) {
  final Color? fill = map['backgroundColor'] as Color?;
  final Color? stroke = map['borderColor'] as Color?;
  final double strokeWeight = (map['borderWeight'] as num?)?.toDouble() ?? 1.0;
  final double borderRadius = (map['borderRadius'] as num?)?.toDouble() ?? 0.0;
  final List<BoxShadow>? shadows = resolveShadows(map['shadow']);

  return BoxDecoration(
    color: fill,
    border: stroke != null ? Border.all(color: stroke, width: strokeWeight) : null,
    borderRadius: borderRadius > 0 ? BorderRadius.circular(borderRadius) : null,
    boxShadow: shadows,
  );
}

/// Builds a [TextStyle] from a style map, or null if no text props are set.
/// Supported keys: fontFamily, fontSize, fontWeight, letterSpacing, lineHeight, color.
TextStyle? buildTextStyle(Map<String, dynamic> map) {
  final String? fontFamily = map['fontFamily'] as String?;
  final double? fontSize = (map['fontSize'] as num?)?.toDouble();
  final FontWeight? fontWeight = resolveWeight(map['fontWeight']);
  final double? letterSpacing = (map['letterSpacing'] as num?)?.toDouble();
  final double? lineHeight = (map['lineHeight'] as num?)?.toDouble();
  final Color? color = map['color'] as Color?;

  if (fontFamily == null &&
      fontSize == null &&
      fontWeight == null &&
      letterSpacing == null &&
      lineHeight == null &&
      color == null) { return null; }

  return TextStyle(
    fontFamily: fontFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    letterSpacing: letterSpacing,
    height: lineHeight,
    color: color,
  );
}

/// Resolves a trackColor value into a [LinearGradient] when multiple colors are given.
/// Returns null for a single [Color] (solid case — use directly as inactiveTrackColor).
/// Accepts: [LinearGradient], [List<Color>], [List<Map>] with keys `color` + `stop` (optional).
/// When stops are omitted Flutter distributes colors evenly.
LinearGradient? resolveLinearGradient(dynamic value) {
  if (value == null || value is Color) return null;
  if (value is LinearGradient) return value;
  if (value is List && value.length >= 2) {
    final colors = <Color>[];
    final stops = <double>[];
    bool hasStops = false;
    for (final item in value) {
      if (item is Color) {
        colors.add(item);
        stops.add(0.0); // placeholder
      } else if (item is Map) {
        colors.add(item['color'] as Color);
        final stop = (item['stop'] as num?)?.toDouble();
        if (stop != null) {
          stops.add(stop);
          hasStops = true;
        } else {
          stops.add(0.0); // placeholder
        }
      }
    }
    if (colors.length < 2) return null;
    return LinearGradient(
      colors: colors,
      stops: hasStops ? stops : null, // null → Flutter distributes evenly
    );
  }
  return null;
}

/// Resolves a font weight value to [FontWeight].
/// Accepts a [FontWeight] directly or a numeric weight (100–900).
FontWeight? resolveWeight(dynamic weight) {
  if (weight == null) return null;
  if (weight is FontWeight) { return weight; }
  if (weight is num) {
    switch (weight.toInt()) {
      case 100: return FontWeight.w100;
      case 200: return FontWeight.w200;
      case 300: return FontWeight.w300;
      case 400: return FontWeight.w400;
      case 500: return FontWeight.w500;
      case 600: return FontWeight.w600;
      case 700: return FontWeight.w700;
      case 800: return FontWeight.w800;
      case 900: return FontWeight.w900;
    }
  }
  return null;
}
