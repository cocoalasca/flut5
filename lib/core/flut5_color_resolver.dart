import 'dart:ui' show Color;

/// Result of resolving a multi-argument color call (`fill`, `stroke`,
/// `background`, `tint`, `shadowFill`, `color`, `Flut5Image.set`).
///
/// Exactly one of [color] or [argb] is set on success:
/// - [color] is populated when the resolved value is an existing [Color]
///   instance (preserving non-sRGB color spaces like Display P3 and avoiding
///   unnecessary `Color` allocations).
/// - [argb] is populated for newly parsed sRGB colors (numeric channels, hex /
///   CSS `rgb()`/`rgba()` strings, or numeric lists), letting callers skip
///   `Color` allocation on unchanged-state fast paths.
///
/// When [error] is non-null, resolution failed and no color was produced.
/// When [warning] is non-null, a color *was* resolved, but extra trailing
/// arguments were ignored and should be reported to the user.
typedef Flut5ColorResolution = ({
  Color? color,
  int? argb,
  String? warning,
  String? error,
});

/// Clamps a channel value to `[0, 255]` and rounds to an integer byte.
/// `NaN` maps safely to `0`.
int flut5ClampByte(num value) {
  if (value.isNaN || value <= 0) return 0;
  if (value >= 255) return 255;
  return value.round();
}

/// Packs sRGB byte channels into an unsigned 32-bit `0xAARRGGBB` integer
/// across Dart VM, Wasm, and JS backends.
int flut5PackArgb(int a, int r, int g, int b) =>
    ((a << 24) | (r << 16) | (g << 8) | b) >>> 0;

/// Resolves a single-value color specification into a [Color], or `null` if
/// [input] is not a supported color value.
///
/// Supported forms:
/// - [Color] — returned as-is
/// - [num] — grayscale `0..255`, opaque
/// - [String] — hex (`#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`) or CSS
///   `rgb(...)` / `rgba(...)`
/// - [List] of 1–4 [num]s — `[gray]`, `[gray, a]`, `[r, g, b]`, `[r, g, b, a]`
Color? flut5TryResolveSingleColor(Object? input) {
  if (input == null) return null;
  if (input is Color) return input;
  if (input is num) {
    final g = flut5ClampByte(input);
    return Color(flut5PackArgb(255, g, g, g));
  }
  if (input is String) {
    final argb = flut5TryParseColorString(input);
    return argb == null ? null : Color(argb);
  }
  if (input is List) {
    final argb = flut5TryResolveNumericList(input);
    return argb == null ? null : Color(argb);
  }
  return null;
}

/// Resolves a p5-style color call with up to 4 color arguments (plus an
/// optional 5th trailing [d] slot used by `fill`/`stroke`/`background` to
/// detect mistaken gradient-bounds calls).
///
/// Supported forms:
/// - `(Color)` or `(Color, alpha)`
/// - `(gray)`, `(gray, alpha)`, `(r, g, b)`, `(r, g, b, alpha)` (`0..255`)
/// - `(hexOrRgbString)` or `(hexOrRgbString, alpha)`
/// - `([gray, ...])` or `([r, g, b], alpha)`
Flut5ColorResolution flut5ResolveColorArgs(
  String methodName,
  Object input, [
  num? a,
  num? b,
  num? c,
  num? d,
  bool allowGradientInError = false,
]) {
  if (input is Color) {
    if (a == null && b == null && c == null && d == null) {
      return (color: input, argb: null, warning: null, error: null);
    }
    if (a != null && b == null && c == null && d == null) {
      return (
        color: input.withAlpha(flut5ClampByte(a)),
        argb: null,
        warning: null,
        error: null,
      );
    }
    return (
      color: input,
      argb: null,
      warning:
          '$methodName(): extra arguments are ignored when the first argument is a Color',
      error: null,
    );
  }

  if (input is num) {
    final argb = flut5TryResolveNumericChannels(input, a, b, c);
    if (argb == null) {
      return (
        color: null,
        argb: null,
        warning: null,
        error:
            '$methodName(): invalid numeric color arguments (null gap between channels)',
      );
    }
    final warning = d != null
        ? '$methodName(): expected at most 4 numeric arguments (r, g, b, alpha) — 5th argument ignored'
        : null;
    return (color: null, argb: argb, warning: warning, error: null);
  }

  if (input is String) {
    final parsed = flut5TryParseColorString(input);
    if (parsed == null) {
      return (
        color: null,
        argb: null,
        warning: null,
        error:
            '$methodName(): invalid color string "$input" — expected hex '
            '(#RGB, #RGBA, #RRGGBB, #RRGGBBAA) or rgb()/rgba()',
      );
    }
    if (a == null && b == null && c == null && d == null) {
      return (color: null, argb: parsed, warning: null, error: null);
    }
    if (a != null && b == null && c == null && d == null) {
      final overridden = ((flut5ClampByte(a) << 24) | (parsed & 0x00FFFFFF)) >>> 0;
      return (color: null, argb: overridden, warning: null, error: null);
    }
    return (
      color: null,
      argb: parsed,
      warning:
          '$methodName(): extra arguments are ignored when the first argument is a String',
      error: null,
    );
  }

  if (input is List) {
    final parsed = flut5TryResolveNumericList(input);
    if (parsed == null) {
      return (
        color: null,
        argb: null,
        warning: null,
        error:
            '$methodName(): color list must contain 1 to 4 numeric values',
      );
    }
    if (a == null && b == null && c == null && d == null) {
      return (color: null, argb: parsed, warning: null, error: null);
    }
    if (a != null && b == null && c == null && d == null) {
      final overridden = ((flut5ClampByte(a) << 24) | (parsed & 0x00FFFFFF)) >>> 0;
      return (color: null, argb: overridden, warning: null, error: null);
    }
    return (
      color: null,
      argb: parsed,
      warning:
          '$methodName(): extra arguments are ignored when the first argument is a List',
      error: null,
    );
  }

  final expected = allowGradientInError
      ? 'Color, Gradient, num, String, or List<num>'
      : 'Color, num, String, or List<num>';
  return (
    color: null,
    argb: null,
    warning: null,
    error: '$methodName(): expected $expected, got ${input.runtimeType}',
  );
}

/// Resolves 1–4 p5 numeric RGB/grayscale channels (`0..255`) into an unsigned
/// `0xAARRGGBB` integer, or `null` if there is a `null` gap between arguments.
int? flut5TryResolveNumericChannels(num v1, [num? v2, num? v3, num? v4]) {
  if (v2 == null) {
    if (v3 != null || v4 != null) return null;
    final g = flut5ClampByte(v1);
    return flut5PackArgb(255, g, g, g);
  }
  if (v3 == null) {
    if (v4 != null) return null;
    final g = flut5ClampByte(v1);
    final a = flut5ClampByte(v2);
    return flut5PackArgb(a, g, g, g);
  }
  final r = flut5ClampByte(v1);
  final g = flut5ClampByte(v2);
  final b = flut5ClampByte(v3);
  final a = v4 == null ? 255 : flut5ClampByte(v4);
  return flut5PackArgb(a, r, g, b);
}

/// Resolves a list of 1–4 [num] values into an unsigned `0xAARRGGBB` integer,
/// or `null` if the list is empty, has more than 4 elements, or contains any
/// non-numeric entry.
int? flut5TryResolveNumericList(List<Object?> values) {
  final len = values.length;
  if (len < 1 || len > 4) return null;
  final v1 = values[0];
  if (v1 is! num) return null;
  if (len == 1) {
    final g = flut5ClampByte(v1);
    return flut5PackArgb(255, g, g, g);
  }
  final v2 = values[1];
  if (v2 is! num) return null;
  if (len == 2) {
    final g = flut5ClampByte(v1);
    final a = flut5ClampByte(v2);
    return flut5PackArgb(a, g, g, g);
  }
  final v3 = values[2];
  if (v3 is! num) return null;
  final r = flut5ClampByte(v1);
  final g = flut5ClampByte(v2);
  final b = flut5ClampByte(v3);
  if (len == 3) {
    return flut5PackArgb(255, r, g, b);
  }
  final v4 = values[3];
  if (v4 is! num) return null;
  return flut5PackArgb(flut5ClampByte(v4), r, g, b);
}

/// Parses a CSS/p5 color string into an unsigned `0xAARRGGBB` integer, or
/// `null` if [raw] is not a recognized format.
///
/// Supported formats (case-insensitive, surrounding whitespace ignored):
/// - `#RGB`
/// - `#RGBA`
/// - `#RRGGBB`
/// - `#RRGGBBAA`
/// - `rgb(r, g, b)` / `rgba(r, g, b, a)` (CSS alpha in `0..1` or `0%..100%`)
int? flut5TryParseColorString(String raw) {
  var start = 0;
  var end = raw.length;
  while (start < end && raw.codeUnitAt(start) <= 0x20) {
    start++;
  }
  while (end > start && raw.codeUnitAt(end - 1) <= 0x20) {
    end--;
  }
  final len = end - start;
  if (len < 4) return null;

  final first = raw.codeUnitAt(start);
  if (first == 0x23) {
    // '#'
    return _parseHex(raw, start + 1, len - 1);
  }
  if (first == 0x72 || first == 0x52) {
    // 'r' or 'R'
    return _parseRgbFunction(raw, start, end);
  }
  return null;
}

int? _parseHex(String s, int offset, int digits) {
  switch (digits) {
    case 3:
      final r = _hexDigit(s.codeUnitAt(offset));
      final g = _hexDigit(s.codeUnitAt(offset + 1));
      final b = _hexDigit(s.codeUnitAt(offset + 2));
      if ((r | g | b) < 0) return null;
      return flut5PackArgb(255, r * 17, g * 17, b * 17);
    case 4:
      final r = _hexDigit(s.codeUnitAt(offset));
      final g = _hexDigit(s.codeUnitAt(offset + 1));
      final b = _hexDigit(s.codeUnitAt(offset + 2));
      final a = _hexDigit(s.codeUnitAt(offset + 3));
      if ((r | g | b | a) < 0) return null;
      return flut5PackArgb(a * 17, r * 17, g * 17, b * 17);
    case 6:
      final r1 = _hexDigit(s.codeUnitAt(offset));
      final r2 = _hexDigit(s.codeUnitAt(offset + 1));
      final g1 = _hexDigit(s.codeUnitAt(offset + 2));
      final g2 = _hexDigit(s.codeUnitAt(offset + 3));
      final b1 = _hexDigit(s.codeUnitAt(offset + 4));
      final b2 = _hexDigit(s.codeUnitAt(offset + 5));
      if ((r1 | r2 | g1 | g2 | b1 | b2) < 0) return null;
      return flut5PackArgb(
        255,
        (r1 << 4) | r2,
        (g1 << 4) | g2,
        (b1 << 4) | b2,
      );
    case 8:
      final r1 = _hexDigit(s.codeUnitAt(offset));
      final r2 = _hexDigit(s.codeUnitAt(offset + 1));
      final g1 = _hexDigit(s.codeUnitAt(offset + 2));
      final g2 = _hexDigit(s.codeUnitAt(offset + 3));
      final b1 = _hexDigit(s.codeUnitAt(offset + 4));
      final b2 = _hexDigit(s.codeUnitAt(offset + 5));
      final a1 = _hexDigit(s.codeUnitAt(offset + 6));
      final a2 = _hexDigit(s.codeUnitAt(offset + 7));
      if ((r1 | r2 | g1 | g2 | b1 | b2 | a1 | a2) < 0) return null;
      return flut5PackArgb(
        (a1 << 4) | a2,
        (r1 << 4) | r2,
        (g1 << 4) | g2,
        (b1 << 4) | b2,
      );
    default:
      return null;
  }
}

int _hexDigit(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30; // '0'..'9'
  if (c >= 0x41 && c <= 0x46) return c - 0x37; // 'A'..'F'
  if (c >= 0x61 && c <= 0x66) return c - 0x57; // 'a'..'f'
  return -1;
}

int? _parseRgbFunction(String raw, int start, int end) {
  if (raw.codeUnitAt(end - 1) != 0x29) return null; // ')'
  final trimmed = raw.substring(start, end);
  final lower = trimmed.toLowerCase();
  int bodyStart;
  if (lower.startsWith('rgb(')) {
    bodyStart = 4;
  } else if (lower.startsWith('rgba(')) {
    bodyStart = 5;
  } else {
    return null;
  }
  final parts = trimmed.substring(bodyStart, trimmed.length - 1).split(',');
  if (parts.length != 3 && parts.length != 4) return null;

  final r = _parseCssRgbChannel(parts[0]);
  final g = _parseCssRgbChannel(parts[1]);
  final b = _parseCssRgbChannel(parts[2]);
  if (r == null || g == null || b == null) return null;

  var a = 255;
  if (parts.length == 4) {
    final parsedAlpha = _parseCssAlphaChannel(parts[3]);
    if (parsedAlpha == null) return null;
    a = parsedAlpha;
  }
  return flut5PackArgb(a, r, g, b);
}

int? _parseCssRgbChannel(String token) {
  final s = token.trim();
  if (s.isEmpty) return null;
  if (s.endsWith('%')) {
    final pct = double.tryParse(s.substring(0, s.length - 1).trim());
    if (pct == null || !pct.isFinite) return null;
    return flut5ClampByte((pct * 255.0) / 100.0);
  }
  final val = double.tryParse(s);
  if (val == null || !val.isFinite) return null;
  return flut5ClampByte(val);
}

int? _parseCssAlphaChannel(String token) {
  final s = token.trim();
  if (s.isEmpty) return null;
  if (s.endsWith('%')) {
    final pct = double.tryParse(s.substring(0, s.length - 1).trim());
    if (pct == null || !pct.isFinite) return null;
    return flut5ClampByte((pct * 255.0) / 100.0);
  }
  final val = double.tryParse(s);
  if (val == null || !val.isFinite) return null;
  return flut5ClampByte(val * 255.0);
}
