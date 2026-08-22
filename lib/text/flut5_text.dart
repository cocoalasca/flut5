import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/flut5_console.dart';
import '../core/render/flut5_render_queue.dart';
import '../core/sketch_environment.dart';
import '../math/flut5_vector.dart';
import '../shape/flut5_fill.dart';
import '../shape/flut5_stroke.dart';
import 'flut5_font.dart';
import 'flut5_text_cache.dart';
import 'flut5_text_grid.dart';

/// Cell count past which [Flut5Text.textToGrid] warns that the grid is big
/// enough to be worth building once instead of every frame.
const int _gridCellAdviceThreshold = 250000;

/// The advice above fires at most once per process — it is guidance, not a
/// per-call diagnostic, and a sketch that means it should not be spammed.
bool _gridCellAdviceShown = false;

// ── Optional args map ─────────────────────────────────────────────────

/// Keys accepted by the `args` map on the text-outline queries
/// ([Flut5Text.textToPaths], [Flut5Text.textToPoints],
/// [Flut5Text.textToContours], [Flut5Text.textToGrid] and their variants).
///
/// The map is deliberately loose. It carries *optional* per-call overrides —
/// the normal path is to set `textFont`/`textSize`/`letterSpacing` on the
/// sketch and pass no args at all. Reads are defensive: an unrecognized key or
/// a wrong value type logs once and is ignored, never throws.
///
/// Use these constants rather than raw strings and the compiler catches
/// typos for you:
///
/// ```dart
/// flut5.textToPoints('Hello', 50, 100, args: {
///   Flut5TextArg.fontSize: 72,          // int is fine, coerced to double
///   Flut5TextArg.letterSpacing: 4,
///   Flut5TextArg.sampleFactor: 0.8,
/// });
/// ```
abstract final class Flut5TextArg {
  /// A [Flut5Font] to use instead of the loaded one.
  static const String font = 'font';

  /// A number overriding the current `textSize`.
  static const String fontSize = 'fontSize';

  /// A number overriding the current `letterSpacing`.
  static const String letterSpacing = 'letterSpacing';

  /// A number setting sampled-point density. Defaults to `0.5`.
  static const String sampleFactor = 'sampleFactor';

  /// A number setting the near-collinear simplify angle. Defaults to `0`.
  static const String simplifyThreshold = 'simplifyThreshold';

  /// A number setting grid cell edge length. Defaults to `fontSize / 20`.
  static const String cellSize = 'cellSize';

  /// Keys understood by [Flut5Text.textToPaths].
  static const Set<String> pathKeys = {font, fontSize, letterSpacing};

  /// Keys understood by the sampled-outline queries.
  static const Set<String> sampledKeys = {
    font,
    fontSize,
    letterSpacing,
    sampleFactor,
    simplifyThreshold,
  };

  /// Keys understood by [Flut5Text.textToGrid].
  static const Set<String> gridKeys = {font, fontSize, letterSpacing, cellSize};
}

/// One-shot guard per `method:key:problem`, so a bad arg inside `draw()`
/// reports once instead of every frame.
final Set<String> _argWarnings = <String>{};

void _warnArg(String token, String message) {
  if (!_argWarnings.add(token)) return;
  Flut5Console.printLater(message);
}

/// Reports each key [method] does not understand — the mitigation for a map's
/// silent-typo failure mode.
void _checkArgKeys(
  Map<String, dynamic>? args,
  String method,
  Set<String> allowed,
) {
  if (args == null) return;
  for (final key in args.keys) {
    if (allowed.contains(key)) continue;
    _warnArg(
      '$method:$key:unknown',
      '$method() ignored the arg "$key" — it accepts '
      '${(allowed.toList()..sort()).join(', ')}. Check the spelling, or use '
      'the Flut5TextArg constants so the compiler catches it.',
    );
  }
}

/// Reads a numeric arg, accepting `int` as well as `double` so a plain
/// `{Flut5TextArg.fontSize: 72}` works. Anything else warns once and is
/// treated as absent.
double? _argDouble(Map<String, dynamic>? args, String key, String method) {
  final value = args?[key];
  if (value == null) return null;
  if (value is num) return value.toDouble();
  _warnArg(
    '$method:$key:type',
    '$method() ignored the arg "$key": expected a number, got '
    '${value.runtimeType}.',
  );
  return null;
}

/// Reads the font arg. Anything that is not a [Flut5Font] warns once and is
/// treated as absent, falling back to the loaded font.
Flut5Font? _argFont(Map<String, dynamic>? args, String method) {
  final value = args?[Flut5TextArg.font];
  if (value == null) return null;
  if (value is Flut5Font) return value;
  _warnArg(
    '$method:font:type',
    '$method() ignored the arg "font": expected a Flut5Font, got '
    '${value.runtimeType}. Load one with await loadFont("path/to/font.ttf").',
  );
  return null;
}

/// Controls which caching strategy [Flut5Text.text] uses.
enum TextCacheMode {
  /// Caches individual characters and composites them at draw time.
  /// Ideal for frequently-changing text (scores, timers, counters).
  dynamic,

  /// Caches the entire string as one GPU texture.
  /// Ideal for static text that rarely changes.
  static,
}

/// Text rendering for the Flut5 Engine.
///
/// Uses fill color for text body and stroke color/weight for outlines,
/// reading both from the current engine state.
///
/// ```dart
/// flut5.fill(Colors.white);
/// flut5.stroke(Colors.black);
/// flut5.strokeWeight(2);
/// flut5.textFont('Courier');
/// flut5.textSize(24);
/// flut5.text('Hello!', 10, 40);
/// ```
mixin Flut5Text on Flut5Fill, Flut5Stroke {
  // ── State ─────────────────────────────────────────────────────────────

  String _fontFamily = 'sans-serif';
  double _fontSize = 12.0;
  double _fontWeightValue = 400.0;
  FontStyle _fontStyle = FontStyle.normal;

  /// Discrete `FontWeight` derived from [_fontWeightValue], used by Flutter's
  /// rasterized text pipeline (which doesn't accept fractional values
  /// directly without `FontVariation`).
  FontWeight get _fontWeight {
    final clamped = _fontWeightValue.clamp(100.0, 900.0);
    final idx = ((clamped / 100).round() - 1).clamp(0, 8);
    return FontWeight.values[idx];
  }

  TextAlign _textAlign = TextAlign.left;
  double? _textLeading;
  double? _letterSpacing;
  TextCacheMode _textCacheMode = .dynamic;

  final Flut5TextCache _textCache = Flut5TextCache.instance;

  SketchEnvironment get environment;
  set environment(SketchEnvironment value);

  // ── Configuration ─────────────────────────────────────────────────────

  /// Sets the font for text rendering and/or shape operations.
  ///
  /// Pass a [String] to set the font family for [text] rendering. When that
  /// family exists in the preloaded pubspec font map, it also becomes the
  /// active outline font for [textToPaths], [textToPoints], and
  /// [textToContours].
  ///
  /// Pass a [Flut5Font] returned by [loadFont] to set only the active outline
  /// font. It does not change Flutter's rasterized text family.
  void textFont(Object font) {
    if (font is String) {
      _fontFamily = font;
      _loadedFont = environment.fonts[font]?.font;
    } else if (font is Flut5Font) {
      _loadedFont = font;
    } else {
      throw ArgumentError(
        'textFont expects a String (font family) or a Flut5Font.',
      );
    }
  }

  /// Sets or returns the current font weight as a numeric value (typically
  /// 100..900, fractional values allowed).
  ///
  /// Accepts a [num] (e.g. `700`, `350`) or a Flutter [FontWeight] enum
  /// (e.g. `FontWeight.bold`, which maps to `700`).
  ///
  /// ```dart
  /// textWeight(700);                // bold
  /// textWeight(FontWeight.bold);    // also bold
  /// textWeight(350);                // between Light and Regular
  /// final w = textWeight();         // → 350
  /// ```
  ///
  /// When a variable font with a `wght` axis is the active outline font, the
  /// value is routed to that axis so glyph outlines interpolate accordingly.
  /// For rasterized text the value is mapped to the nearest [FontWeight]
  /// enum (100..900 in 100-unit steps).
  double textWeight([Object? weight]) {
    if (weight != null) {
      final double value;
      if (weight is num) {
        value = weight.toDouble();
      } else if (weight is FontWeight) {
        value = weight.value.toDouble();
      } else {
        throw ArgumentError(
          'textWeight expects a num (e.g. 700) or a FontWeight '
          '(e.g. FontWeight.bold). Got ${weight.runtimeType}.',
        );
      }
      _fontWeightValue = value;
      final font = _loadedFont;
      if (font != null && font.axisByTag('wght') != null) {
        font.setAxisValue('wght', _fontWeightValue);
        // The font clamps to its axis range; mirror the clamped value back
        // so subsequent reads of textWeight() report what's actually applied.
        _fontWeightValue = font.axisValues['wght']!;
      }
    }
    return _fontWeightValue;
  }

  /// Sets the font style (e.g. `FontStyle.italic`).
  void textStyle(FontStyle style) {
    _fontStyle = style;
  }

  /// Sets a single variation-axis value on the active outline font.
  ///
  /// [tag] is a four-character OpenType axis tag (`wght`, `wdth`, `slnt`,
  /// `ital`, `opsz`, or a font-specific custom axis). Values are clamped to
  /// the axis's declared min/max range. No-op when no outline font is loaded
  /// or the font does not declare the axis.
  ///
  /// ```dart
  /// fontAxis('wdth', 75);  // condensed
  /// fontAxis('slnt', -8);  // slanted
  /// ```
  void fontAxis(String tag, double value) {
    final font = _loadedFont;
    if (font == null || font.axisByTag(tag) == null) return;
    font.setAxisValue(tag, value);
    // Keep textWeight() in sync when the engine writes 'wght' directly.
    if (tag == 'wght') _fontWeightValue = font.axisValues['wght']!;
  }

  /// Applies a font-declared named instance — a preset combination of axis
  /// values such as "Bold Condensed" or "Display".
  ///
  /// Use [Flut5Font.namedInstances] to discover what's available. No-op when
  /// no outline font is loaded or [name] is not a known instance.
  void fontInstance(String name) {
    final font = _loadedFont;
    if (font == null) return;
    for (final inst in font.namedInstances) {
      if (inst.name == name) {
        font.setAxisValues(inst.coordinates);
        final w = font.axisValues['wght'];
        if (w != null) _fontWeightValue = w;
        return;
      }
    }
  }

  /// Resets every axis on the active outline font to its declared default.
  void clearFontAxes() {
    final font = _loadedFont;
    if (font == null) return;
    font.resetAxisValues();
    final w = font.axisValues['wght'];
    if (w != null) _fontWeightValue = w;
  }

  /// Current user-space axis values on the active outline font as an
  /// unmodifiable map keyed by axis tag. Empty when no outline font is
  /// loaded or the font has no axes.
  Map<String, double> get fontAxes =>
      _loadedFont?.axisValues ?? const <String, double>{};

  /// Pubspec-registered font shape data preloaded from `FontManifest.json`,
  /// keyed by family name.
  Map<String, Flut5FontData> get fonts => environment.fonts;

  /// Sets the font size in pixels.
  void textSize(double size) {
    _fontSize = size;
  }

  /// Sets horizontal text alignment. The `x` in [text] becomes the
  /// anchor point for the chosen alignment.
  void textAlign(TextAlign align) {
    _textAlign = align;
  }

  /// Sets the line height in pixels.
  void textLeading(double leading) {
    _textLeading = leading / _fontSize;
  }

  /// Sets additional letter spacing in pixels. Pass `null` to reset to font default.
  void letterSpacing(double? spacing) {
    _letterSpacing = spacing;
  }

  /// Sets the text caching strategy.
  ///
  /// [TextCacheMode.dynamic] (default) caches each character individually —
  /// ideal for text that changes every frame.
  /// [TextCacheMode.static] caches the full string as one texture —
  /// ideal for text that rarely changes.
  void textCacheMode(TextCacheMode mode) {
    _textCacheMode = mode;
  }

  /// Gets or sets the sampling quality used when blitting cached glyph
  /// textures onto the canvas.
  ///
  /// [FilterQuality.low] (the default) is bilinear — it keeps rotated or
  /// scaled text smooth. [FilterQuality.none] is nearest-neighbor: crisper for
  /// unrotated, pixel-aligned text but it aliases ("jitters") under rotation.
  ///
  /// This is a global setting shared across every sketch. Pass a value to
  /// change it; call with no argument to read the current value.
  ///
  /// ```dart
  /// textFilterQuality(FilterQuality.none);   // set
  /// final q = textFilterQuality();           // read
  /// ```
  FilterQuality textFilterQuality([FilterQuality? quality]) {
    if (quality != null) _textCache.textBlitQuality = quality;
    return _textCache.textBlitQuality;
  }

  /// Current maximum number of raster text textures retained in the shared
  /// LRU cache (default 1024).
  ///
  /// This is a soft cap — while [textCacheAutoGrow] is on it doubles on
  /// overflow instead of evicting, up to [textCacheGrowthLimit] /
  /// [textCacheMaxBytes]. Setting it re-bases growth at the given value.
  int get textCacheMaxSize => _textCache.maxCacheSize;
  set textCacheMaxSize(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'value', 'must be >= 1');
    }
    _textCache.maxCacheSize = value;
  }

  /// Whether the text caches double their cap on overflow instead of evicting
  /// immediately (default `true`).
  ///
  /// LRU eviction degrades gracefully only while the per-frame *working set*
  /// fits the cache. Once a sketch cycles through more unique
  /// text/style/size combinations than the cap, the entry evicted is exactly
  /// the one needed next, so the hit rate collapses rather than tapering —
  /// every glyph then re-rasterizes through `TextPainter` every frame.
  /// Growing sidesteps that cliff; [textCacheMaxBytes] keeps it honest.
  ///
  /// Set `false` when you want a hard, predictable memory ceiling and would
  /// rather absorb the eviction cost.
  bool get textCacheAutoGrow => _textCache.autoGrow;
  set textCacheAutoGrow(bool value) => _textCache.autoGrow = value;

  /// Memory budget for cached text textures in bytes (default 128 MB).
  ///
  /// Bounds both auto-growth and residency — entries are evicted once usage
  /// exceeds it, even below [textCacheMaxSize]. This, not the entry count, is
  /// the limit that actually protects GPU memory: one 300px headline texture
  /// can outweigh a thousand 12px glyphs.
  int get textCacheMaxBytes => _textCache.maxCacheBytes;
  set textCacheMaxBytes(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'value', 'must be >= 1');
    }
    _textCache.maxCacheBytes = value;
  }

  /// Hard ceiling on how far [textCacheMaxSize] may auto-grow (default
  /// 16384). Past it the cache reverts to LRU eviction.
  int get textCacheGrowthLimit => _textCache.growthLimit;
  set textCacheGrowthLimit(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'value', 'must be >= 1');
    }
    _textCache.growthLimit = value;
  }

  /// Total decoded size of all cached text textures, in bytes.
  int get textCacheBytes => _textCache.cacheBytes;

  /// Number of text textures currently cached.
  int get textCacheLength => _textCache.cacheLength;

  /// Current maximum number of word-wrap text layouts retained in the shared
  /// LRU cache. Layout entries hold only strings and doubles (no GPU
  /// textures), so raising this is much cheaper than raising
  /// [textCacheMaxSize]. Auto-grows under [textCacheAutoGrow].
  int get textLayoutCacheMaxSize => _textCache.maxLayoutCacheSize;
  set textLayoutCacheMaxSize(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'value', 'must be >= 1');
    }
    _textCache.maxLayoutCacheSize = value;
  }

  /// Hard ceiling on how far [textLayoutCacheMaxSize] may auto-grow
  /// (default 16384).
  int get textLayoutCacheGrowthLimit => _textCache.layoutGrowthLimit;
  set textLayoutCacheGrowthLimit(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'value', 'must be >= 1');
    }
    _textCache.layoutGrowthLimit = value;
  }

  /// Number of word-wrap layouts currently cached.
  int get textLayoutCacheLength => _textCache.layoutCacheLength;

  /// Clears all cached raster text textures and measurement helpers.
  void clearTextCache() {
    _textCache.clear();
  }

  /// The registered-font set, parsed once per process.
  ///
  /// Every engine reads the same manifest and the same font files, so a second
  /// canvas re-reading and re-parsing all of them is pure waste.
  ///
  /// The resolved map is cached, deliberately not the [Future]: awaiting a
  /// future created earlier is fine in an app, but under `flutter_test` each
  /// test runs in its own fake-async zone and a future created in a previous
  /// test's zone never completes. Caching the value means every canvas after
  /// the first takes a synchronous path with nothing foreign to await — which
  /// is why a second `Flut5Canvas` in a test file reaches `setup()` at all.
  static Map<String, Flut5FontData>? _registeredFonts;

  /// Drops the process-wide registered-font cache so the next preload re-reads
  /// the asset bundle. Test-only seam.
  @visibleForTesting
  static void debugResetRegisteredFonts() => _registeredFonts = null;

  /// Loads parseable fonts declared in Flutter's generated FontManifest.json.
  ///
  /// Called by [Flut5Canvas] before user [setup]. The resulting map is stored
  /// in [SketchEnvironment.fonts], keyed by pubspec/manifest family name.
  Future<void> preloadRegisteredFonts() async {
    final fonts = _registeredFonts ??= await _loadRegisteredFonts();
    environment = environment.withFonts(fonts);
    _loadedFont = environment.fonts[_fontFamily]?.font;
  }

  static Future<Map<String, Flut5FontData>> _loadRegisteredFonts() async {
    final loaded = <String, Flut5FontData>{};
    List<dynamic> manifest;
    try {
      final jsonString = await rootBundle.loadString('FontManifest.json');
      manifest = jsonDecode(jsonString) as List<dynamic>;
    } catch (_) {
      return Map.unmodifiable(loaded);
    }

    for (final entry in manifest) {
      if (entry is! Map<String, dynamic>) continue;
      final family = entry['family'];
      final fonts = entry['fonts'];
      if (family is! String || fonts is! List) continue;

      for (final fontEntry in fonts) {
        if (fontEntry is! Map<String, dynamic>) continue;
        final asset = fontEntry['asset'];
        if (asset is! String) continue;
        try {
          final data = await rootBundle.load(asset);
          final font = Flut5Font.fromBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
          loaded[family] = Flut5FontData(
            name: family,
            asset: asset,
            font: font,
          );
          break;
        } catch (_) {
          // Some manifest entries may be unsupported outline formats. Keep
          // scanning variants and omit the family if none can be parsed.
        }
      }
    }

    // Unmodifiable because the same instance is handed to every engine.
    return Map.unmodifiable(loaded);
  }

  // ── Drawing ───────────────────────────────────────────────────────────

  /// Draws [content] at ([x], [y]).
  ///
  /// Delegates to [textDynamic] or [textStatic] based on the current [textCacheMode].
  /// Use those methods directly to bypass the mode and always use a specific pipeline.
  void text(
    String content,
    double x,
    double y, [
    double? maxWidth,
    double? maxHeight,
  ]) {
    if (batchPath != null) {
      // Rasterized text is a GPU texture op and cannot merge into a `Path`.
      throw FlutterError('text() cannot be called inside beginBatch/endBatch');
    }
    if (renderQueue.isRecordingClip) {
      _appendTextToClipMask(content, x, y);
      return;
    }
    if (_textCacheMode == .dynamic) {
      textDynamic(content, x, y, maxWidth, maxHeight);
    } else {
      textStatic(content, x, y, maxWidth, maxHeight);
    }
  }

  /// Routes a `text()` call made inside a `clip()` callback through the
  /// outline-font pipeline so the glyph contours become part of the mask.
  ///
  /// Requires a loaded `Flut5Font` (via `loadFontShapeData` or a pubspec
  /// family selected with `textFont`). When no font is available,
  /// `textToPaths` already logs a warning and returns an empty list — we
  /// add a clip-specific warning to make the cause obvious.
  void _appendTextToClipMask(String content, double x, double y) {
    final commands = textToPaths(content, x, y);
    if (commands.isEmpty) {
      Flut5Console.printLater(
        'clip(): text() inside a clip callback requires a loaded Flut5Font '
        '(call loadFontShapeData() or select a pubspec family with textFont()).',
      );
      return;
    }
    renderQueue.addTextCommandsToClip(commands);
  }

  /// Draws [content] using per-character caching, regardless of [textCacheMode].
  ///
  /// Each character is cached individually and composited at draw time.
  /// Ideal for text that changes every frame (scores, timers, counters).
  /// Respects [letterSpacing] and [textLeading] as composition-time values.
  void textDynamic(
    String content,
    double x,
    double y, [
    double? maxWidth,
    double? maxHeight,
  ]) {
    if (batchPath != null) {
      throw FlutterError(
        'textDynamic() cannot be called inside beginBatch/endBatch',
      );
    }
    if (renderQueue.isRecordingClip) {
      _appendTextToClipMask(content, x, y);
      return;
    }
    final bool hasFill = fillColor != Colors.transparent;
    final bool hasStroke = strokeColor != Colors.transparent;
    if (!hasFill && !hasStroke) return;

    final Gradient? autoFillGrad =
        (fillGradient != null && fillGradientRect == null) ? fillGradient : null;
    final Gradient? autoStrokeGrad =
        (strokeGradient != null && strokeGradientRect == null) ? strokeGradient : null;

    // Identity-stable snapshots — no per-call Paint clone. When bounds will
    // be resolved at render time (auto gradient), the shaderless variant
    // rides along so the render item's own bounds logic takes over.
    final Paint? queuedFill = !hasFill
        ? null
        : autoFillGrad != null
            ? snapshotFillPaintNoShader()
            : snapshotFillPaint();
    final Paint? queuedStroke = !hasStroke
        ? null
        : autoStrokeGrad != null
            ? snapshotStrokePaintNoShader()
            : snapshotStrokePaint();

    renderQueue.enqueue(
      TextDynamicRenderItem(
        text: content,
        x: x,
        y: y,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        fontFamily: _fontFamily,
        fontSize: _fontSize,
        fontWeight: _fontWeight,
        fontStyle: _fontStyle,
        textAlign: _textAlign,
        textLeading: _textLeading,
        letterSpacing: _letterSpacing,
        fillPaint: queuedFill,
        strokePaint: queuedStroke,
        fillGradient: autoFillGrad,
        strokeGradient: autoStrokeGrad,
        shadow: renderQueue.activeShadow,
      ),
    );
  }

  /// Draws [content] using full-string caching, regardless of [textCacheMode].
  ///
  /// The entire string is rasterized as one GPU texture.
  /// Ideal for text that rarely changes.
  void textStatic(
    String content,
    double x,
    double y, [
    double? maxWidth,
    double? maxHeight,
  ]) {
    if (batchPath != null) {
      throw FlutterError(
        'textStatic() cannot be called inside beginBatch/endBatch',
      );
    }
    if (renderQueue.isRecordingClip) {
      _appendTextToClipMask(content, x, y);
      return;
    }
    final bool hasFill = fillColor != Colors.transparent;
    final bool hasStroke = strokeColor != Colors.transparent;
    if (!hasFill && !hasStroke) return;

    final Gradient? autoFillGrad =
        (fillGradient != null && fillGradientRect == null) ? fillGradient : null;
    final Gradient? autoStrokeGrad =
        (strokeGradient != null && strokeGradientRect == null) ? strokeGradient : null;

    Paint? queuedFill;
    if (hasFill) {
      queuedFill = getFillPaint().clone();
      if (autoFillGrad != null) queuedFill.shader = null;
    }
    Paint? queuedStroke;
    if (hasStroke) {
      queuedStroke = getStrokePaint().clone();
      if (autoStrokeGrad != null) queuedStroke.shader = null;
    }

    renderQueue.enqueue(
      TextRenderItem(
        text: content,
        x: x,
        y: y,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        fontFamily: _fontFamily,
        fontSize: _fontSize,
        fontWeight: _fontWeight,
        fontStyle: _fontStyle,
        textAlign: _textAlign,
        textLeading: _textLeading,
        letterSpacing: _letterSpacing,
        fillPaint: queuedFill,
        strokePaint: queuedStroke,
        fillGradient: autoFillGrad,
        strokeGradient: autoStrokeGrad,
        shadow: renderQueue.activeShadow,
      ),
    );
  }

  // ── Text to path / points / contours ───────────────────────────────────

  Flut5Font? _loadedFont;

  /// Loads a font file and sets it as the active outline font, exactly as if
  /// you had called `textFont(font)` afterwards.
  ///
  /// After this call [textToPaths], [textToPoints], and [textToContours] use
  /// the loaded font automatically. Raster [text] still uses Flutter's
  /// pubspec-registered font families.
  ///
  /// ```dart
  /// // Simplest usage — font is active immediately:
  /// await flut5.loadFontShapeData('assets/fonts/Roboto.ttf');
  /// flut5.textToPoints('Hello', 10, 50); // already uses the loaded font
  ///
  /// // Keep the reference if you need multiple fonts:
  /// final roboto = await flut5.loadFontShapeData('assets/fonts/Roboto.ttf');
  /// final mono   = await flut5.loadFontShapeData('assets/fonts/Mono.ttf');
  /// flut5.textFont(roboto);
  /// flut5.textToPoints('Body',  10, 50);
  /// flut5.textFont(mono);
  /// flut5.textToPoints('Code', 10, 80);
  /// ```
  ///
  /// Accepts either a Flutter asset path (`String`) or raw bytes (`Uint8List`).
  /// Returns the parsed [Flut5Font] for reuse or inspection.
  ///
  /// **Variable fonts** are supported (TrueType `gvar`-based; CFF2/OTF
  /// variable fonts are not). When the loaded font ships an `fvar` table,
  /// `font.isVariable` is `true` and you can drive axes via [textWeight]
  /// (auto-routes to the `wght` axis), [fontAxis], or [fontInstance]:
  ///
  /// ```dart
  /// await loadFont('assets/fonts/RobotoFlex-VF.ttf');
  /// textWeight(700);              // wght → 700
  /// fontAxis('wdth', 75);         // condensed
  /// fontInstance('Bold Display'); // any named instance from fvar
  /// ```
  Future<Flut5Font> loadFontShapeData(dynamic source) async {
    Uint8List bytes;
    if (source is Uint8List) {
      bytes = source;
    } else if (source is String) {
      final data = await rootBundle.load(source);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } else {
      throw ArgumentError(
        'loadFontShapeData() expects a String asset path or Uint8List bytes.',
      );
    }
    _loadedFont = Flut5Font.fromBytes(bytes);
    return _loadedFont!;
  }

  /// Loads a font file and sets it as the active outline font — alias for
  /// [loadFontShapeData] that matches the p5.js name.
  ///
  /// The loaded outline font is active immediately without a separate
  /// [textFont] call:
  ///
  /// ```dart
  /// @override
  /// Future<void> preload() async {
  ///   await loadFont('assets/fonts/Roboto.ttf');
  /// }
  ///
  /// @override
  /// void draw() {
  ///   textSize(48);
  ///   textToPoints('Hello', 50, 100);  // also uses the loaded font
  /// }
  /// ```
  ///
  /// Note: unlike p5.js, rasterized [text] rendering uses Flutter fonts
  /// declared in `pubspec.yaml`. Pass the family name string to [textFont] to
  /// choose the raster family used by [text].
  Future<Flut5Font> loadFont(dynamic source) => loadFontShapeData(source);

  /// Returns raw path commands for [content] positioned at baseline ([x], [y]).
  ///
  /// Requires font shape data loaded via [loadFontShapeData], a preloaded
  /// pubspec family selected with [textFont], or `Flut5TextArg.font` in [args].
  /// Uses the current [textSize] for scaling and the current [letterSpacing]
  /// for glyph advance, so the outline spans the same width [textWidth]
  /// reports.
  ///
  /// [args] optionally overrides any of that for this call only — see
  /// [Flut5TextArg] for the accepted keys (`font`, `fontSize`,
  /// `letterSpacing`). Unrecognized keys and wrong-typed values are logged
  /// once and ignored rather than throwing.
  ///
  /// ```dart
  /// final cmds = flut5.textToPaths('Hello', 50, 100);
  /// flut5.beginShape();
  /// for (final cmd in cmds) {
  ///   switch (cmd) {
  ///     case MoveToCommand(:final x, :final y): flut5.vertex(x, y);
  ///     case LineToCommand(:final x, :final y): flut5.vertex(x, y);
  ///     case QuadToCommand(:final cx, :final cy, :final x, :final y):
  ///       flut5.quadraticVertex(cx, cy, x, y);
  ///     case CloseCommand(): break;
  ///     default: break;
  ///   }
  /// }
  /// flut5.endShape(close: true);
  /// ```
  List<PathCommand> textToPaths(
    String content,
    double x,
    double y, {
    Map<String, dynamic>? args,
  }) {
    const method = 'textToPaths';
    _checkArgKeys(args, method, Flut5TextArg.pathKeys);
    final f = _argFont(args, method) ?? _loadedFont;
    if (f == null) {
      Flut5Console.printLater(
        'textToPaths() requires a Flut5Font. '
        'Call await loadFont("path/to/font.ttf"), use a pubspec family with '
        'textFont("Roboto"), or pass args: {Flut5TextArg.font: myFont}.',
      );
      return const [];
    }
    return f.textToPaths(
      content,
      x,
      y,
      _argDouble(args, Flut5TextArg.fontSize, method) ?? _fontSize,
      letterSpacing:
          _argDouble(args, Flut5TextArg.letterSpacing, method) ??
          _letterSpacing ??
          0.0,
    );
  }

  /// Returns sampled points along the outlines of [content] at ([x], [y]).
  ///
  /// By default this reads the sketch's own `textFont`/`textSize`/
  /// `letterSpacing`, so the sampled outline spans the same width [textWidth]
  /// reports. [args] overrides any of that for this call only — see
  /// [Flut5TextArg] for the accepted keys:
  ///
  /// - `fontSize` — overrides the current [textSize].
  /// - `sampleFactor` — point density in **pixel space**, default `0.5`.
  ///   Higher values produce more points. Visual spacing is
  ///   fontSize-independent: the same factor produces the same on-screen
  ///   density at any font size (matching p5.js).
  /// - `simplifyThreshold` — default `0`. Above 0 it removes near-collinear
  ///   points; the value is the threshold angle in radians between two
  ///   adjacent edges, below which the middle point is dropped.
  /// - `letterSpacing`, `font` — override the sketch's own.
  ///
  /// Unrecognized keys and wrong-typed values are logged once and ignored
  /// rather than throwing, since these are optional overrides.
  ///
  /// ```dart
  /// final pts = flut5.textToPoints('Hello', 50, 100, args: {
  ///   Flut5TextArg.sampleFactor: 0.5,
  /// });
  /// for (final p in pts) {
  ///   flut5.point(p.x, p.y);
  /// }
  /// ```
  List<Flut5Vector> textToPoints(
    String content,
    double x,
    double y, {
    Map<String, dynamic>? args,
  }) {
    const method = 'textToPoints';
    _checkArgKeys(args, method, Flut5TextArg.sampledKeys);
    final f = _argFont(args, method) ?? _loadedFont;
    if (f == null) {
      Flut5Console.printLater(
        'textToPoints() requires a Flut5Font. '
        'Call await loadFont("path/to/font.ttf"), use a pubspec family with '
        'textFont("Roboto"), or pass args: {Flut5TextArg.font: myFont}.',
      );
      return const [];
    }
    return f.textToPoints(
      content,
      x,
      y,
      _argDouble(args, Flut5TextArg.fontSize, method) ?? _fontSize,
      sampleFactor:
          _argDouble(args, Flut5TextArg.sampleFactor, method) ?? 0.5,
      simplifyThreshold:
          _argDouble(args, Flut5TextArg.simplifyThreshold, method) ?? 0,
      letterSpacing:
          _argDouble(args, Flut5TextArg.letterSpacing, method) ??
          _letterSpacing ??
          0.0,
    );
  }

  /// Returns sampled points grouped by contour for [content] at ([x], [y]).
  ///
  /// Each inner list is one closed contour — for example, the letter "O"
  /// produces two contours (outer edge and inner hole).
  ///
  /// The current [letterSpacing] is applied, so the sampled outline spans
  /// the same width [textWidth] reports. [args] takes the same keys as
  /// [textToPoints] — see [Flut5TextArg].
  ///
  /// ```dart
  /// final contours = flut5.textToContours('O', 50, 100);
  /// for (final contour in contours) {
  ///   flut5.beginShape();
  ///   for (final p in contour) {
  ///     flut5.vertex(p.x, p.y);
  ///   }
  ///   flut5.endShape(close: true);
  /// }
  /// ```
  List<List<Flut5Vector>> textToContours(
    String content,
    double x,
    double y, {
    Map<String, dynamic>? args,
  }) {
    const method = 'textToContours';
    _checkArgKeys(args, method, Flut5TextArg.sampledKeys);
    final f = _argFont(args, method) ?? _loadedFont;
    if (f == null) {
      Flut5Console.printLater(
        'textToContours() requires a Flut5Font. '
        'Call await loadFont("path/to/font.ttf"), use a pubspec family with '
        'textFont("Roboto"), or pass args: {Flut5TextArg.font: myFont}.',
      );
      return const [];
    }
    return f.textToContours(
      content,
      x,
      y,
      _argDouble(args, Flut5TextArg.fontSize, method) ?? _fontSize,
      sampleFactor:
          _argDouble(args, Flut5TextArg.sampleFactor, method) ?? 0.5,
      simplifyThreshold:
          _argDouble(args, Flut5TextArg.simplifyThreshold, method) ?? 0,
      letterSpacing:
          _argDouble(args, Flut5TextArg.letterSpacing, method) ??
          _letterSpacing ??
          0.0,
    );
  }

  /// Rasterizes the outlines of [content] into a uniform grid of cells,
  /// spanning the tight bounding box of the outline.
  ///
  /// Each cell reports whether it is empty, interior, or on the edge — see
  /// [Flut5CellState]. Edge cells are the filled ones that touch the outside
  /// (on the box's rim, or 4-adjacent to an empty cell), so they trace a
  /// one-cell outline of the glyph. Counters come back empty, so the hole in
  /// "O" stays a hole — and its wall reads as edge. The returned
  /// [Flut5TextGrid] carries the box origin and cell size alongside the 2D
  /// array, so cells map straight back to screen coordinates.
  ///
  /// Read it either way: [Flut5TextGrid.states] and [Flut5TextGrid.stateAt]
  /// for allocation-free index loops, or [Flut5TextGrid.filledCells] and
  /// [Flut5TextGrid.allCells] for [Flut5TextCell] views that carry their own
  /// coordinates and survive being filtered, sorted, or stored.
  ///
  /// [args] overrides the sketch's own settings for this call only — see
  /// [Flut5TextArg] for the accepted keys (`cellSize`, `fontSize`,
  /// `letterSpacing`, `font`). Unrecognized keys and wrong-typed values are
  /// logged once and ignored rather than throwing.
  ///
  /// `cellSize` is the cell edge length in pixels and defaults to
  /// `fontSize / 20` — chunky but legible at any font size. Halving it
  /// quadruples the cell count, so treat this as a build-once call rather
  /// than a per-frame one.
  ///
  /// ```dart
  /// final grid = flut5.textToGrid('HELLO', 40, 200, args: {
  ///   Flut5TextArg.cellSize: 10,
  /// });
  /// for (final cell in grid.filledCells) {
  ///   flut5.fill(cell.state == Flut5CellState.edge ? Colors.red : Colors.white);
  ///   flut5.square(cell.anchorX, cell.anchorY, cell.size);
  /// }
  /// ```
  Flut5TextGrid textToGrid(
    String content,
    double x,
    double y, {
    Map<String, dynamic>? args,
  }) {
    const method = 'textToGrid';
    _checkArgKeys(args, method, Flut5TextArg.gridKeys);
    final f = _argFont(args, method) ?? _loadedFont;
    if (f == null) {
      Flut5Console.printLater(
        'textToGrid() requires a Flut5Font. '
        'Call await loadFont("path/to/font.ttf"), use a pubspec family with '
        'textFont("Roboto"), or pass args: {Flut5TextArg.font: myFont}.',
      );
      return Flut5TextGrid.empty;
    }
    final grid = f.textToGrid(
      content,
      x,
      y,
      _argDouble(args, Flut5TextArg.fontSize, method) ?? _fontSize,
      cellSize: _argDouble(args, Flut5TextArg.cellSize, method),
      letterSpacing:
          _argDouble(args, Flut5TextArg.letterSpacing, method) ??
          _letterSpacing ??
          0.0,
    );

    final cellCount = grid.rows * grid.cols;
    if (cellCount > _gridCellAdviceThreshold && !_gridCellAdviceShown) {
      _gridCellAdviceShown = true;
      Flut5Console.printLater(
        'textToGrid() built a ${grid.cols}x${grid.rows} grid '
        '($cellCount cells) at cellSize ${grid.cellSize.toStringAsFixed(2)}. '
        'That is fine to build once, but it will stutter if you call it every '
        'frame — hoist it out of draw(), or pass a larger cellSize.',
      );
    }
    return grid;
  }

  // ── Measurement ───────────────────────────────────────────────────────

  /// Returns the pixel width of [content] with the current font/size,
  /// including the current [letterSpacing] (matching Flutter's TextPainter
  /// and p5.js v2 semantics).
  ///
  /// Uses the lightweight width-only cache backed by Flutter's `TextPainter`
  /// and adds inter-glyph spacing on top.
  ///
  /// For multi-line content (`\n`-separated) the **longest line** wins.
  /// Letter spacing is applied between glyphs on each line — `N` glyphs get
  /// `N - 1` insertions, matching how the renderer lays text out.
  double textWidth(String content) {
    if (content.isEmpty) return 0;
    final double spacing = _letterSpacing ?? 0.0;

    double maxWidth = 0;
    for (final line in content.split('\n')) {
      if (line.isEmpty) continue;
      double w = _textCache.measureWidth(
        text: line,
        fontFamily: _fontFamily,
        fontSize: _fontSize,
        fontWeight: _fontWeight,
        fontStyle: _fontStyle,
      );
      final n = line.runes.length;
      if (n > 1) w += spacing * (n - 1);
      if (w > maxWidth) maxWidth = w;
    }
    return maxWidth;
  }
}
