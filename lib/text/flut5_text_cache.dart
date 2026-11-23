import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';

import 'flut5_expiring_cache.dart';

import '../core/flut5_console.dart';

/// The font a run of per-glyph text is drawn in: everything about its style
/// that picks a glyph raster, apart from the pass, phase and density.
final class Flut5GlyphFont({
  required final String family,
  required final double size,
  required final FontWeight weight,
  required final FontStyle style,
  final List<FontVariation>? variations,
  final String variationKey = '',
});

/// One laid-out line of dynamic text.
///
/// Holds only the drawable (non-whitespace) glyphs with their pen offsets —
/// letter spacing and kerning are already baked into [offsets], so drawing a
/// line is a flat loop with no measurement work. Whitespace still contributes
/// to [width] and to the offsets of the glyphs that follow it.
class Flut5TextLine._(
  /// Drawable glyphs in draw order. Whitespace is excluded (never blitted).
  /// A glyph is one character, or several the font shapes into one, like an
  /// "fi" ligature.
  final List<String> glyphs,

  /// Pen x-offset of each glyph in [glyphs], relative to the line start.
  final Float64List offsets,

  /// Full advance width of the line, including whitespace.
  final double width,

  /// Whether the source line had any characters at all. `false` only for
  /// truly empty lines (e.g. between consecutive `\n`), which still advance
  /// the cursor but carry no width.
  final bool hasChars,
  final Int32List? _spacingIndices,
  final int _spacingGaps,
  final List<_MeasuredToken>? _sourceTokens,
) {
  // Source character positions include whitespace, unlike the drawable
  // glyph list. They let unwrapped text apply spacing without retaining a
  // different layout for every animation value.
  Flut5TextLine(
    List<String> glyphs,
    Float64List offsets,
    double width,
    bool hasChars,
  ) : this._(glyphs, offsets, width, hasChars, null, 0, null);

  // The rasters of [glyphs] as drawn, for the fill pass and the stroke pass
  // — see [Flut5TextCache.linePass]. Only good while the cache has dropped
  // no texture since, so a dropped image is never drawn from here.
  Flut5LineRasters? _fillRasters;
  Flut5LineRasters? _strokeRasters;

  /// Internal: width after adding composition-time spacing to this layout.
  double widthWithSpacing(double spacing) => spacing == 0 || _spacingGaps == 0
      ? width
      : width + _spacingGaps * spacing;

  /// Internal: glyph offset after adding composition-time spacing.
  @pragma('vm:prefer-inline')
  double offsetWithSpacing(int index, double spacing) {
    if (spacing == 0) return offsets[index];
    final position = _spacingIndices?[index] ?? 0;
    return position == 0 ? offsets[index] : offsets[index] + position * spacing;
  }

  /// The line's characters in order, whitespace included.
  late final String sourceText = _readSourceText();

  String _readSourceText() {
    final tokens = _sourceTokens;
    if (tokens == null) return glyphs.join();
    final text = StringBuffer();
    for (final token in tokens) {
      text.writeAll(token.chars);
    }
    return text.toString();
  }
}

/// A line's glyph rasters for one pass and density: one slot per glyph and
/// subpixel phase. Taken with [Flut5TextCache.linePass] and read with
/// [Flut5TextCache.keptGlyph].
final class Flut5LineRasters._(
  int glyphCount,
  final int _generation,
  final double _strokeWidth,
  final double _rasterScale,
) {
  final List<Flut5CachedText?> _rasters = List.filled(
    glyphCount * Flut5TextCache.subpixelPhases,
    null,
  );

  /// Which phase of each glyph was drawn last.
  final Uint8List _lastPhases = Uint8List(glyphCount);
}

/// One answer of [Flut5TextCache.drawsNatively] and the style it was for.
final class _AskedStyle() {
  int frame = -1;
  String family = '';
  double size = 0;
  FontWeight? weight;
  FontStyle? style;
  String variationKey = '';
  int paintingStyle = 0;
  double strokeWidth = 0;
  double rasterScale = 0;
  bool answer = false;

  bool matches(
    Flut5GlyphFont font,
    int askedPaintingStyle,
    double askedStrokeWidth,
    double askedRasterScale,
  ) =>
      font.size == size &&
      askedRasterScale == rasterScale &&
      askedPaintingStyle == paintingStyle &&
      askedStrokeWidth == strokeWidth &&
      identical(font.weight, weight) &&
      identical(font.style, style) &&
      font.family == family &&
      font.variationKey == variationKey;

  void remember(
    int askedFrame,
    Flut5GlyphFont font,
    int askedPaintingStyle,
    double askedStrokeWidth,
    double askedRasterScale,
    bool askedAnswer,
  ) {
    frame = askedFrame;
    family = font.family;
    size = font.size;
    weight = font.weight;
    style = font.style;
    variationKey = font.variationKey;
    paintingStyle = askedPaintingStyle;
    strokeWidth = askedStrokeWidth;
    rasterScale = askedRasterScale;
    answer = askedAnswer;
  }
}

/// Cached word-wrap layout for one (text, style, spacing, maxWidth) tuple.
///
/// Deliberately stores no [Flut5CachedText] references — texture eviction in
/// the main cache can never leave a stale image inside a layout. Glyph
/// advances are font metrics, so they stay valid even after eviction.
class Flut5TextLayout(final List<Flut5TextLine> lines) {
  /// LRU bookkeeping — last [Flut5TextCache._accessTick] this layout was used.
  int _lastUsedTick = 0;

  /// The frame this layout was worked out in, and whether a later frame has
  /// asked for it again — see [Flut5TextCache._newLayouts].
  int _createdFrame = 0;
  bool _usedAgain = false;
}

/// Composite key for cached layouts:
/// (text, fontFamily, fontSize, fontWeight, fontStyle, letterSpacing, maxWidth, fontVariationKey).
typedef _LayoutKey = (
  String,
  String,
  double,
  FontWeight,
  FontStyle,
  double,
  double?,
  String,
);

class Flut5CachedText(
  final ui.Image image,
  final double width,
  final double height,
  final double drawWidth,
  final double leftPad,

  /// The size to draw [image] at, in logical pixels: its pixel size over
  /// the device pixel ratio it was rasterized for, so every texel lands on
  /// one device pixel. [image] is a whole number of pixels, rounded up from
  /// [drawWidth] × [height], so this is a fraction of a pixel larger than
  /// they are — drawn into those instead, the raster would be squeezed by
  /// that fraction and resampled.
  final double blitWidth,
  final double blitHeight, {

  /// How far left of the text's pen origin the raster starts, in logical
  /// pixels: a whole number of device pixels, so the raster stays on the
  /// pixel grid when the origin is.
  final double rasterLeft = 0,

  /// How far above the top of the text's line box the raster starts, for
  /// the ink that reaches past it: accents, swashes, a thick outline.
  final double rasterTop = 0,

  /// Pixels of [image] per logical pixel of text.
  final double pixelsPerUnit = 1,

  /// Which quarter of a device pixel past a whole pixel this raster's pen
  /// sits at, as in `0..3`.
  final int subpixelPhase = 0,
}) {
  // advance width used for character spacing
  // image logical width; wider than width when glyphs overhang right
  // shift (logical px) to apply when drawing; non-zero for left overhang

  /// This raster's entry in the texture cache, so a caller already holding
  /// the raster can count a use of it without looking it up.
  Flut5ExpiringEntry<_TextCacheKey, Flut5CachedText>? _entry;

  /// Pre-computed source rect for `drawImageRect` — avoids per-frame allocation.
  late final Rect srcRect = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );

  /// Decoded size of [image] and of its baked shadows in bytes, assuming
  /// RGBA. [ui.Image.width] and [ui.Image.height] are pixel dimensions —
  /// already scaled by the device pixel ratio — so this is the real GPU cost
  /// of the entry.
  int get bytes => _imageBytes + _shadowBytes;
  final int _imageBytes;
  int _shadowBytes = 0;

  /// Shadow silhouettes baked from [image], oldest first — see
  /// [Flut5TextCache.bakedShadow]. They live and die with the entry.
  Map<Object, Flut5ShadowRaster>? _shadows;

  /// Shelf-packed glyph atlas slot for batched [Canvas.drawRawAtlas] blits,
  /// or `null` until packed (or if oversized). Managed by [Flut5TextCache].
  Flut5GlyphAtlasSlot? _atlasSlot;

  /// LRU bookkeeping — last [Flut5TextCache._accessTick] this entry was used.
  int _lastUsedTick = 0;

  this : _imageBytes = image.width * image.height * 4;

  /// Active shelf-packed atlas slot for this glyph, or `null` if not packed.
  Flut5GlyphAtlasSlot? get atlasSlot => _atlasSlot;

  void dispose() {
    _atlasSlot = null;
    image.dispose();
    final shadows = _shadows;
    if (shadows == null) return;
    for (final shadow in shadows.values) {
      shadow.image.dispose();
    }
  }
}

/// One shelf-packed page of the dynamic glyph atlas.
///
/// Packs single-glyph white rasters with a transparent [gutter] between slots
/// so bilinear sampling never bleeds across neighbours. Owned and disposed by
/// [Flut5TextCache].
class Flut5GlyphAtlasPage(final int generation) {
  static const int maxExtent = 1024;
  static const int maxGlyphExtent = 384;
  static const int gutter = 2;

  ui.Image? image;
  int width = 0;
  int height = 0;
  int _cursorX = gutter;
  int _cursorY = gutter;
  int _shelfHeight = 0;
  bool _retired = false;
  int _maxUsedX = gutter;
  int _maxUsedY = gutter;
  int _usedPixels = 0;
  int _deadPixels = 0;
  final List<ui.Image> _pendingImages = [];
  final List<Flut5GlyphAtlasSlot> _pendingSlots = [];
}

/// Placement of a [Flut5CachedText] inside a [Flut5GlyphAtlasPage].
class Flut5GlyphAtlasSlot(
  final Flut5GlyphAtlasPage page,
  final double left,
  final double top,
  final double right,
  final double bottom,
  final int generation,
) {
  bool get isValid => page.generation == generation && !page._retired;
}

/// Pre-tokenized word-run representation of a string at a fixed font style,
/// independent of `letterSpacing` and `maxWidth`. Lets wrapped-text
/// `letterSpacing` / `maxWidth` animations re-wrap with pure float arithmetic
/// instead of re-splitting strings, decoding runes, and hashing glyph metrics.
class _MeasuredToken(
  final bool isWhitespace,
  final List<String> chars,
  final Float64List advances,
  final Float64List internalKerns,
  final double baseWidth,
) {
  String get firstChar => chars.first;
  String get lastChar => chars.last;
  int get length => chars.length;
}

class _TokenizedSegment(
  final List<_MeasuredToken> tokens,
  final Float64List joinKerns,
);

class _TokenizedText(final List<_TokenizedSegment> segments);

/// A text raster's shadow silhouette, baked once — see
/// [Flut5TextCache.bakedShadow].
class Flut5ShadowRaster(
  /// The silhouette, white, padded on every side of the raster by [pad].
  final ui.Image image,

  /// Logical pixels added on each side of the raster's draw rect.
  final double pad,

  /// Logical size of [image], padding included.
  final Size size,
) {
  late final Rect srcRect = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );

  Flut5GlyphAtlasSlot? _atlasSlot;

  /// Atlas slot holding this baked shadow silhouette, or `null` if not packed
  /// (e.g. oversized blur/spread shadow drawn directly via `drawImageRect`).
  Flut5GlyphAtlasSlot? get atlasSlot => _atlasSlot;

  int get bytes => image.width * image.height * 4;
}

/// Composite key for cached rasterized text images.
class _TextCacheKey(
  var String text,
  var double? maxWidth,
  var double? maxHeight,
  var String fontFamily,
  var double fontSize,
  var FontWeight fontWeight,
  var FontStyle fontStyle,
  var double? textLeading,
  var double? letterSpacing,
  var int alignIndex,
  var int paintingStyle,
  var double strokeWidth,
  var String fontVariationKey,
  var int subpixelPhase,
  var double rasterScale,
) {
  // 0 = fill, 1 = stroke
  /// Creates a mutable instance for reuse as a lookup key.
  _TextCacheKey._mutable()
    : this(
        '',
        null,
        null,
        '',
        0,
        FontWeight.normal,
        FontStyle.normal,
        null,
        null,
        0,
        0,
        0,
        '',
        0,
        1,
      );

  /// Sets all fields in place — avoids allocating a new key for lookups.
  void _set(
    String text,
    double? maxWidth,
    double? maxHeight,
    String fontFamily,
    double fontSize,
    FontWeight fontWeight,
    FontStyle fontStyle,
    double? textLeading,
    double? letterSpacing,
    int alignIndex,
    int paintingStyle,
    double strokeWidth,
    String fontVariationKey,
    int subpixelPhase,
    double rasterScale,
  ) {
    this.text = text;
    this.maxWidth = maxWidth;
    this.maxHeight = maxHeight;
    this.fontFamily = fontFamily;
    this.fontSize = fontSize;
    this.fontWeight = fontWeight;
    this.fontStyle = fontStyle;
    this.textLeading = textLeading;
    this.letterSpacing = letterSpacing;
    this.alignIndex = alignIndex;
    this.paintingStyle = paintingStyle;
    this.strokeWidth = strokeWidth;
    this.fontVariationKey = fontVariationKey;
    this.subpixelPhase = subpixelPhase;
    this.rasterScale = rasterScale;
  }

  /// Creates an immutable copy for map storage.
  _TextCacheKey._from(_TextCacheKey other)
    : this(
        other.text,
        other.maxWidth,
        other.maxHeight,
        other.fontFamily,
        other.fontSize,
        other.fontWeight,
        other.fontStyle,
        other.textLeading,
        other.letterSpacing,
        other.alignIndex,
        other.paintingStyle,
        other.strokeWidth,
        other.fontVariationKey,
        other.subpixelPhase,
        other.rasterScale,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TextCacheKey &&
          text == other.text &&
          maxWidth == other.maxWidth &&
          maxHeight == other.maxHeight &&
          fontFamily == other.fontFamily &&
          fontSize == other.fontSize &&
          fontWeight == other.fontWeight &&
          fontStyle == other.fontStyle &&
          textLeading == other.textLeading &&
          letterSpacing == other.letterSpacing &&
          alignIndex == other.alignIndex &&
          paintingStyle == other.paintingStyle &&
          strokeWidth == other.strokeWidth &&
          fontVariationKey == other.fontVariationKey &&
          subpixelPhase == other.subpixelPhase &&
          rasterScale == other.rasterScale;

  @override
  int get hashCode => Object.hash(
    text,
    maxWidth,
    maxHeight,
    fontFamily,
    fontSize,
    fontWeight,
    fontStyle,
    textLeading,
    letterSpacing,
    alignIndex,
    paintingStyle,
    strokeWidth,
    fontVariationKey,
    subpixelPhase,
    rasterScale,
  );
}

/// Singleton LRU cache for rasterized text [ui.Image]s.
///
/// Shared across all Flut5Engine instances. Evaluates text layout exactly
/// once per permutation in white, offloading actual tinting to the GPU later.
///
/// Recency is tracked with a monotonic tick stamped on each entry rather than
/// by map insertion order, so a cache hit is a single hash read with no
/// allocation. Eviction scans for the stalest entries only when the cache
/// overflows (i.e. on misses), keeping the per-frame hit path flat.
///
/// On overflow the cache prefers to *grow* rather than evict (see [autoGrow]):
/// plain LRU falls off a cliff once a sketch's per-frame working set exceeds
/// the cap, because the entry it evicts is the one wanted next. Growth is
/// bounded by [growthLimit] and [maxCacheBytes]; past those, eviction resumes
/// in amortized batches. Both transitions are reported once via
/// [Flut5Console] with the quantization advice that removes the cause.
class Flut5TextCache._() {
  static final Flut5TextCache instance = Flut5TextCache._();

  int _frame = 0;
  int _timeoutFrames = 600;
  bool _trackingFrames = false;

  /// Sliding lifetime in completed, unused Flutter frames. Shared by sketches.
  int get timeoutFrames => _timeoutFrames;
  set timeoutFrames(int frames) {
    if (frames < 1) throw RangeError.range(frames, 1, null, 'frames');
    _timeoutFrames = frames;
  }

  /// Hooks the shared cache into the existing frame loop exactly once.
  /// Does not request frames or keep the app animating when it is idle.
  void trackFrames() {
    if (_trackingFrames) return;
    _trackingFrames = true;
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      SchedulerBinding.instance.addPostFrameCallback((_) => finishFrame());
    });
  }

  /// Internal end-of-frame maintenance, also usable by offscreen renderers.
  /// Expire after all canvases have used their textures, then start a new age.
  void finishFrame() {
    _commitPendingAtlasPages();
    _followPixelRatio();
    _cache.expire(_timeoutFrames);
    _dropLayoutsNeverUsedAgain();
    _layoutCache.expire(_timeoutFrames);
    _tokenCache.expire(_timeoutFrames);
    _pairCache.expire(_timeoutFrames);
    _widthCache.expire(_timeoutFrames);
    _lineHeightCache.expire(_timeoutFrames);
    _blockCache.expire(_timeoutFrames);
    _ascentDescentCache.expire(_timeoutFrames);
    _charStrings.expire(_timeoutFrames);
    _recentStyles.expire(_styleMemoryFrames);
    _framesWithNewStyles = _newStyleThisFrame ? _framesWithNewStyles + 1 : 0;
    _newStyleThisFrame = false;
    _disposeRetiredAtlasImages();
    if (_cache.isEmpty && _atlasPages.isNotEmpty) {
      _clearAtlas(immediate: true);
    } else if (_atlasNeedsCompaction) {
      _atlasNeedsCompaction = false;
      _clearAtlas(immediate: false);
    }
    _growAtlasIfItFilled();
    // The mutable lookup key is scratch space, not a cache entry. Do not let
    // it retain the last measured string after all actual entries expire.
    _lookupKey.text = '';
    _lookupKey.fontFamily = '';
    _frame++;
  }

  /// Counts all entry categories without refreshing their lifetime.
  @visibleForTesting
  Map<String, int> get debugEntryCounts => {
    'textures': _cache.length,
    'layouts': _layoutCache.length,
    'kerning': _pairCache.length,
    'widths': _widthCache.length,
    'lineHeights': _lineHeightCache.length,
    'ascentDescent': _ascentDescentCache.length,
    'characters': _charStrings.length,
  };

  int _maxCacheSize = 1024;

  /// Current max cached textures before LRU eviction.
  ///
  /// This is a *soft* cap: while [autoGrow] is on it doubles on overflow (up
  /// to [growthLimit] / [maxCacheBytes]) rather than evicting, because LRU is
  /// pessimal when a sketch cycles through more unique entries than the cache
  /// holds — the entry evicted is precisely the one needed next.
  ///
  /// Setting it re-bases growth at [value] and re-arms the one-time overflow
  /// warnings so a later breach of the new limit is reported again.
  int get maxCacheSize => _maxCacheSize;
  set maxCacheSize(int value) {
    _maxCacheSize = value;
    _textureLimitWarned = false;
    _textureGrowthStopWarned = false;
  }

  /// Hard ceiling on how far [maxCacheSize] may auto-grow. Past this the
  /// cache reverts to LRU eviction. Guards against the pathological case of
  /// unbounded unique keys (e.g. an un-quantized animated `textSize`), and
  /// keeps the eviction sort bounded.
  int growthLimit = 16384;

  /// Memory budget for the texture cache, in bytes. Bounds both auto-growth
  /// and residency: entries are evicted once [cacheBytes] exceeds it, even if
  /// the cache is under [maxCacheSize].
  ///
  /// A count alone is a poor proxy for GPU cost — one 300px headline texture
  /// can outweigh a thousand 12px glyphs — so this is the limit that actually
  /// protects memory. Defaults to 128 MB.
  int maxCacheBytes = 128 << 20;

  /// Whether the texture and layout caches double their cap on overflow
  /// instead of immediately evicting. Set `false` for a hard, predictable cap
  /// (e.g. on a memory-constrained target).
  bool autoGrow = true;

  int _cacheBytes = 0;

  /// Total decoded size of all cached textures, in bytes.
  int get cacheBytes => _cacheBytes;

  /// Number of textures currently cached.
  int get cacheLength => _cache.length;

  /// Sampling quality used when the render items blit cached glyph textures
  /// onto the canvas. Global — shared across every Flut5Engine.
  ///
  /// [FilterQuality.low] (default) is bilinear: keeps rotated or scaled text
  /// smooth. [FilterQuality.none] is nearest-neighbor — crisper for
  /// pixel-aligned, unrotated text but aliases ("jitters") under rotation.
  /// The text render items and the text-shadow tint paint read this value.
  FilterQuality textBlitQuality = FilterQuality.low;

  int _maxLayoutCacheSize = 1024;

  /// Current max cached [Flut5TextLayout]s before LRU eviction. Layouts hold
  /// only strings and doubles (no GPU textures), so entries are cheap.
  ///
  /// Defaults to the same count as [maxCacheSize]: a layout entry exists per
  /// unique text/style tuple just like textures do, and a smaller layout cap
  /// would start thrashing before the texture cache does. Auto-grows under
  /// the same [autoGrow] policy, bounded by [layoutGrowthLimit].
  ///
  /// Setting it re-arms the one-time overflow warnings so a later breach of
  /// the new limit is reported again.
  int get maxLayoutCacheSize => _maxLayoutCacheSize;
  set maxLayoutCacheSize(int value) {
    _maxLayoutCacheSize = value;
    _layoutLimitWarned = false;
    _layoutGrowthStopWarned = false;
  }

  /// Hard ceiling on how far [maxLayoutCacheSize] may auto-grow.
  int layoutGrowthLimit = 16384;

  /// Number of layouts currently cached.
  int get layoutCacheLength => _layoutCache.length;

  /// One-time flags for the cache-overflow warnings. Overflow can happen
  /// thousands of times per frame while thrashing, so each cache warns once
  /// per breach — re-armed when its cap is set or the cache cleared.
  /// `_*GrowthStopWarned` latches the louder message emitted when auto-growth
  /// has run out of room and true LRU eviction begins.
  bool _textureLimitWarned = false;
  bool _layoutLimitWarned = false;
  bool _textureGrowthStopWarned = false;
  bool _layoutGrowthStopWarned = false;

  late final _cache = Flut5ExpiringCache<_TextCacheKey, Flut5CachedText>(
    () => _frame,
    onExpire: _releaseTexture,
  );

  /// Counts up whenever a texture leaves the cache, by any route. Whoever
  /// keeps hold of [Flut5CachedText]s between draws notes it, and lets go of
  /// them once it has moved on — see [resolvedGlyphs].
  int get textureGeneration => _textureGeneration;
  int _textureGeneration = 0;

  void _markDeadSlot(Flut5GlyphAtlasSlot? slot, ui.Image image) {
    if (slot != null && slot.generation == _atlasGeneration) {
      final page = slot.page;
      page._deadPixels += image.width * image.height;
      if (page._usedPixels > 0 && page._deadPixels * 2 > page._usedPixels) {
        _atlasNeedsCompaction = true;
      }
    }
  }

  /// Frees a texture already taken out of [_cache].
  void _releaseTexture(Flut5CachedText removed) {
    _markDeadSlot(removed._atlasSlot, removed.image);
    final shadows = removed._shadows;
    if (shadows != null) {
      for (final s in shadows.values) {
        _markDeadSlot(s._atlasSlot, s.image);
      }
    }
    _cacheBytes -= removed.bytes;
    removed.dispose();
    _textureGeneration++;
  }

  // ── Shelf-packed dynamic glyph atlas ──────────────────────────────────
  //
  // Layers GPU batching under the existing per-glyph texture cache so
  // `textDynamic` can blit hundreds of glyphs in a single `Canvas.drawRawAtlas`
  // call while keeping `cacheLength`, `cacheBytes`, `resolvedGlyphs`, and
  // timeout expiration unchanged.
  //
  // Pages are only ever cleared between frames, never during a draw: a
  // glyph that doesn't fit is drawn on its own, and the page limit grows for
  // the next frame.
  static const int _firstAtlasPageLimit = 8;
  static const int _atlasPageBytes =
      Flut5GlyphAtlasPage.maxExtent * Flut5GlyphAtlasPage.maxExtent * 4;
  static const int _framesBetweenAtlasRebuilds = 120;
  static const int _maxRetiredAtlasImages = 16;
  static final Paint _atlasCopyPaint = Paint()
    ..blendMode = BlendMode.src
    ..filterQuality = FilterQuality.none;

  final List<Flut5GlyphAtlasPage> _atlasPages = [];
  final List<ui.Image> _retiredAtlasImages = [];
  int _atlasGeneration = 0;
  bool _atlasNeedsCompaction = false;
  int _atlasPageLimit = _firstAtlasPageLimit;
  bool _atlasFilledThisFrame = false;
  bool _atlasLimitWarned = false;
  int _lastAtlasRebuildFrame = 0;

  /// How many pages [maxCacheBytes] allows the atlas.
  int get _atlasPageCeiling =>
      math.max(_firstAtlasPageLimit, maxCacheBytes ~/ _atlasPageBytes);

  /// After a frame with glyphs that didn't fit: more pages, or at the ceiling
  /// a periodic rebuild so the pages hold what is in use now.
  void _growAtlasIfItFilled() {
    if (!_atlasFilledThisFrame) return;
    _atlasFilledThisFrame = false;
    final ceiling = _atlasPageCeiling;
    if (_atlasPageLimit < ceiling) {
      _atlasPageLimit = math.min(_atlasPageLimit * 2, ceiling);
      return;
    }
    if (!_atlasLimitWarned) {
      _atlasLimitWarned = true;
      Flut5Console.printLater(
        'text glyph atlas is full at $ceiling pages, so some glyphs draw one '
        'at a time. $_quantizeAdvice',
      );
    }
    if (_frame - _lastAtlasRebuildFrame >= _framesBetweenAtlasRebuilds) {
      _lastAtlasRebuildFrame = _frame;
      _clearAtlas(immediate: false);
    }
  }

  /// The device pixel ratio the currently cached glyph rasters and atlas pages
  /// were rasterized at.
  double get pixelRatio => _cachedPixelRatio ??= _viewPixelRatio() ?? 1.0;

  void _disposeRetiredAtlasImages() {
    if (_retiredAtlasImages.isEmpty) return;
    for (final img in _retiredAtlasImages) {
      img.dispose();
    }
    _retiredAtlasImages.clear();
  }

  void _retireAtlasImage(ui.Image? img, {required bool immediate}) {
    if (img == null) return;
    if (immediate) {
      img.dispose();
      return;
    }
    _retiredAtlasImages.add(img);
    if (_retiredAtlasImages.length > _maxRetiredAtlasImages) {
      _retiredAtlasImages.removeAt(0).dispose();
    }
  }

  void _clearAtlas({required bool immediate}) {
    for (final page in _atlasPages) {
      _retireAtlasImage(page.image, immediate: immediate);
      page.image = null;
      page._retired = true;
      page._pendingImages.clear();
      page._pendingSlots.clear();
    }
    _atlasPages.clear();
    _atlasNeedsCompaction = false;
    if (immediate) _disposeRetiredAtlasImages();
    _atlasGeneration++;
  }

  /// The atlas slot of [glyph], reserving one if it has none; `null` when it
  /// is too big for a page or every page is full, and draws on its own.
  ///
  /// The slot's pixels land on the page when the page is next drawn from
  /// ([committedAtlasImage]), so a whole batch of new glyphs costs one page
  /// update, not one per line.
  Flut5GlyphAtlasSlot? atlasSlotFor(Flut5CachedText glyph) {
    final slot = glyph._atlasSlot;
    if (slot != null && slot.isValid) return slot;
    final image = glyph.image;
    if (image.width > Flut5GlyphAtlasPage.maxGlyphExtent ||
        image.height > Flut5GlyphAtlasPage.maxGlyphExtent) {
      return glyph._atlasSlot = null;
    }
    return glyph._atlasSlot = _reserveAtlasSlot(
      image,
      image.width,
      image.height,
    );
  }

  /// [atlasSlotFor], for a baked shadow silhouette.
  Flut5GlyphAtlasSlot? atlasSlotForShadow(Flut5ShadowRaster shadow) {
    final slot = shadow._atlasSlot;
    if (slot != null && slot.isValid) return slot;
    final image = shadow.image;
    if (image.width > Flut5GlyphAtlasPage.maxGlyphExtent ||
        image.height > Flut5GlyphAtlasPage.maxGlyphExtent) {
      return shadow._atlasSlot = null;
    }
    return shadow._atlasSlot = _reserveAtlasSlot(
      image,
      image.width,
      image.height,
    );
  }

  /// The image of [page] with every glyph reserved on it so far.
  ui.Image? committedAtlasImage(Flut5GlyphAtlasPage page) {
    if (page._pendingImages.isNotEmpty) _commitAtlasPage(page);
    return page.image;
  }

  void _commitPendingAtlasPages() {
    for (var i = 0; i < _atlasPages.length; i++) {
      final page = _atlasPages[i];
      if (page._pendingImages.isNotEmpty) _commitAtlasPage(page);
    }
  }

  static int _nextAtlasExtent(int minSize) {
    int size = 256;
    while (size < minSize && size < Flut5GlyphAtlasPage.maxExtent) {
      size <<= 1;
    }
    return size > Flut5GlyphAtlasPage.maxExtent
        ? Flut5GlyphAtlasPage.maxExtent
        : size;
  }

  Flut5GlyphAtlasSlot? _reserveAtlasSlot(ui.Image image, int w, int h) {
    const gutter = Flut5GlyphAtlasPage.gutter;
    const maxExtent = Flut5GlyphAtlasPage.maxExtent;

    Flut5GlyphAtlasPage page;
    if (_atlasPages.isEmpty) {
      page = Flut5GlyphAtlasPage(_atlasGeneration);
      _atlasPages.add(page);
    } else {
      page = _atlasPages.last;
    }

    if (page._cursorX + w + gutter > maxExtent) {
      page._cursorX = gutter;
      page._cursorY += page._shelfHeight + gutter;
      page._shelfHeight = 0;
    }
    if (page._cursorY + h + gutter > maxExtent) {
      if (_atlasPages.length >= _atlasPageLimit) {
        _atlasFilledThisFrame = true;
        return null;
      }
      page = Flut5GlyphAtlasPage(_atlasGeneration);
      _atlasPages.add(page);
    }

    final left = page._cursorX;
    final top = page._cursorY;
    final right = left + w;
    final bottom = top + h;
    page._cursorX = right + gutter;
    if (h > page._shelfHeight) page._shelfHeight = h;
    if (right + gutter > page._maxUsedX) page._maxUsedX = right + gutter;
    if (bottom + gutter > page._maxUsedY) page._maxUsedY = bottom + gutter;
    page._usedPixels += w * h;

    final slot = Flut5GlyphAtlasSlot(
      page,
      left.toDouble(),
      top.toDouble(),
      right.toDouble(),
      bottom.toDouble(),
      _atlasGeneration,
    );
    page._pendingImages.add(image);
    page._pendingSlots.add(slot);
    return slot;
  }

  void _commitAtlasPage(Flut5GlyphAtlasPage page) {
    final targetW = _nextAtlasExtent(
      page._maxUsedX > page.width ? page._maxUsedX : page.width,
    );
    final targetH = _nextAtlasExtent(
      page._maxUsedY > page.height ? page._maxUsedY : page.height,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()),
    );
    final prev = page.image;
    if (prev != null) {
      canvas.drawImage(prev, Offset.zero, _atlasCopyPaint);
    }
    final pendingImages = page._pendingImages;
    final pendingSlots = page._pendingSlots;
    for (var i = 0; i < pendingImages.length; i++) {
      final slot = pendingSlots[i];
      if (!identical(slot.page, page)) continue;
      canvas.drawImage(
        pendingImages[i],
        Offset(slot.left, slot.top),
        _atlasCopyPaint,
      );
    }
    final picture = recorder.endRecording();
    final next = picture.toImageSync(targetW, targetH);
    picture.dispose();
    _retireAtlasImage(prev, immediate: false);
    page.image = next;
    page.width = targetW;
    page.height = targetH;
    pendingImages.clear();
    pendingSlots.clear();
  }

  /// How many subpixel positions a glyph is rasterized for, along x. Text
  /// engines place glyphs on quarters of a device pixel, so a raster for
  /// each lands exactly where the engine's own glyph would.
  static const int subpixelPhases = 4;

  /// The rasters [line] keeps for one pass at one density, to read glyph by
  /// glyph with [keptGlyph]. Good until a glyph is made, which may evict
  /// others: take it again after [lineGlyph].
  Flut5LineRasters linePass(
    Flut5TextLine line,
    int paintingStyle,
    double strokeWidth,
    double rasterScale,
  ) {
    final isFill = paintingStyle == 0;
    final kept = isFill ? line._fillRasters : line._strokeRasters;
    if (kept != null &&
        kept._generation == _textureGeneration &&
        kept._rasterScale == rasterScale &&
        (isFill || kept._strokeWidth == strokeWidth)) {
      return kept;
    }
    final fresh = Flut5LineRasters._(
      line.glyphs.length,
      _textureGeneration,
      strokeWidth,
      rasterScale,
    );
    if (isFill) {
      line._fillRasters = fresh;
    } else {
      line._strokeRasters = fresh;
    }
    return fresh;
  }

  /// The raster [pass] holds for glyph [index] at [phase], counted as used,
  /// or `null` when it hasn't been made yet: then ask [lineGlyph].
  @pragma('vm:prefer-inline')
  Flut5CachedText? keptGlyph(Flut5LineRasters pass, int index, int phase) {
    pass._lastPhases[index] = phase;
    final raster = pass._rasters[index * subpixelPhases + phase];
    if (raster == null) return null;
    final entry = raster._entry!;
    if (entry.lastUsedFrame != _frame) _cache.touch(entry);
    raster._lastUsedTick = ++_accessTick;
    return raster;
  }

  /// The raster of glyph [index] of [line] for [phase] and [rasterScale],
  /// counted as used. Kept with the line, so a glyph drawn again costs no
  /// key hash.
  Flut5CachedText lineGlyph(
    Flut5TextLine line,
    int index,
    Flut5GlyphFont font, {
    required int paintingStyle,
    required double strokeWidth,
    required int phase,
    required double rasterScale,
  }) {
    final pass = linePass(line, paintingStyle, strokeWidth, rasterScale);
    final kept = keptGlyph(pass, index, phase);
    if (kept != null) return kept;
    final raster = getOrCreate(
      text: line.glyphs[index],
      fontFamily: font.family,
      fontSize: font.size,
      fontWeight: font.weight,
      fontStyle: font.style,
      textLeading: null,
      align: TextAlign.left,
      paintingStyle: paintingStyle,
      strokeWidth: strokeWidth,
      fontVariations: font.variations,
      fontVariationKey: font.variationKey,
      subpixelPhase: phase,
      rasterScale: rasterScale,
    );
    // Fetching may have evicted textures, some perhaps kept here. The next
    // lookup then sees the new generation and starts over.
    if (pass._generation == _textureGeneration) {
      pass._rasters[index * subpixelPhases + phase] = raster;
    }
    return raster;
  }

  /// The rasters [line] last drew for the fill pass ([paintingStyle] `0`) or
  /// the stroke pass at [strokeWidth], each counted as used. `null` when it
  /// hasn't drawn that pass, or a texture has left the cache since.
  List<Flut5CachedText>? resolvedGlyphs(
    Flut5TextLine line,
    int paintingStyle,
    double strokeWidth,
  ) {
    final kept = paintingStyle == 0 ? line._fillRasters : line._strokeRasters;
    if (kept == null || kept._generation != _textureGeneration) return null;
    if (paintingStyle != 0 && kept._strokeWidth != strokeWidth) return null;
    final rasters = <Flut5CachedText>[];
    for (var i = 0; i < line.glyphs.length; i++) {
      final raster = kept._rasters[i * subpixelPhases + kept._lastPhases[i]];
      if (raster == null) return null;
      _cache.touch(raster._entry!);
      raster._lastUsedTick = ++_accessTick;
      rasters.add(raster);
    }
    return rasters;
  }

  // ── Glyph density and native drawing ─────────────────────────────────

  /// A glyph is rasterized for at most this many device pixels of font size
  /// because of `scale()`; past it, text is drawn natively.
  static const double _largestScaledFontPixels = 512;
  static const double _smallestRasterScale = 1 / 16;

  /// The density, relative to the display's, to rasterize text of [fontSize]
  /// drawn at [scale], so its pixels land 1:1 on the device. In steps of
  /// 1/1024, so rounding noise from a rotating transform doesn't make a new
  /// raster every frame.
  double rasterScaleFor(double fontSize, double scale) {
    if (!scale.isFinite || scale <= 0) return 1;
    var bounded = scale;
    final devicePixels = fontSize * pixelRatio;
    if (devicePixels > 0) {
      final largest = math.max(1.0, _largestScaledFontPixels / devicePixels);
      if (bounded > largest) bounded = largest;
    }
    if (bounded < _smallestRasterScale) bounded = _smallestRasterScale;
    return (bounded * 1024).roundToDouble() / 1024;
  }

  // Sizes that animate make every glyph a new raster, every frame, to be
  // used once. So a sketch that keeps introducing new styles frame after
  // frame has its new ones drawn natively; a style is cached once it has
  // been drawn in an earlier frame too.
  static const int _styleMemoryFrames = 8;
  static const int _framesToCallItAnimated = 3;
  int _framesWithNewStyles = 0;
  bool _newStyleThisFrame = false;

  late final Flut5ExpiringCache<
    (String, double, FontWeight, FontStyle, String, int, double, double),
    int
  >
  _recentStyles = Flut5ExpiringCache(() => _frame);

  /// Whether the sketch has been bringing in new text styles frame after
  /// frame, as a size that animates does.
  bool get stylesAreAnimating =>
      _framesWithNewStyles >= _framesToCallItAnimated;

  // The styles [drawsNatively] answered for last, so text in a few styles
  // costs a few comparisons instead of a key hash each. Good for the frame
  // they were asked in: an answer can't change until the frame ends.
  static const int _askedStyleCount = 8;
  final List<_AskedStyle> _askedStyles = List.generate(
    _askedStyleCount,
    (_) => _AskedStyle(),
    growable: false,
  );
  int _nextAskedStyle = 0;

  /// Whether text in this style should skip the glyph cache and be drawn
  /// natively: because it is too large for a raster at [requestedScale], or
  /// because the sketch's text sizes are animating and this one is new.
  bool drawsNatively(
    Flut5GlyphFont font,
    int paintingStyle,
    double strokeWidth,
    double rasterScale,
    double requestedScale,
  ) {
    if (requestedScale > rasterScale * 1.001) return true;
    for (var i = 0; i < _askedStyleCount; i++) {
      final asked = _askedStyles[i];
      if (asked.frame == _frame &&
          asked.matches(font, paintingStyle, strokeWidth, rasterScale)) {
        return asked.answer;
      }
    }
    final style = (
      font.family,
      font.size,
      font.weight,
      font.style,
      font.variationKey,
      paintingStyle,
      strokeWidth,
      rasterScale,
    );
    final animated = stylesAreAnimating;
    final firstFrame = _recentStyles[style];
    final bool answer;
    if (firstFrame == null) {
      _recentStyles[style] = _frame;
      _newStyleThisFrame = true;
      answer = animated;
    } else {
      answer = animated && firstFrame == _frame;
    }
    _askedStyles[_nextAskedStyle].remember(
      _frame,
      font,
      paintingStyle,
      strokeWidth,
      rasterScale,
      answer,
    );
    _nextAskedStyle = (_nextAskedStyle + 1) % _askedStyleCount;
    return answer;
  }

  /// Monotonic access counter used to stamp entries for LRU eviction.
  int _accessTick = 0;

  /// Reusable key for lookups — avoids allocating a new key on cache hits.
  final _TextCacheKey _lookupKey = _TextCacheKey._mutable();

  /// The device pixel ratio textures are rasterized for. Read when the
  /// first texture is made, then followed frame by frame.
  double? _cachedPixelRatio;

  /// The device pixel ratio of the first view, or `null` when there is none
  /// to ask (no binding yet, no window).
  static double? _viewPixelRatio() {
    try {
      final views = SchedulerBinding.instance.platformDispatcher.views;
      if (views.isNotEmpty) return views.first.devicePixelRatio;
    } catch (_) {
      // No binding: fall through to the engine's own dispatcher.
    }
    try {
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isNotEmpty) return views.first.devicePixelRatio;
    } catch (_) {}
    return null;
  }

  /// Picks up a changed device pixel ratio — the window dragged to another
  /// display, the browser zoomed — and drops every texture rasterized for
  /// the old one: drawn at the new ratio they would be stretched or shrunk.
  /// They are rasterized again as they are next drawn. Widths, kerning and
  /// layouts are in logical pixels and stay.
  void _followPixelRatio() {
    final ratio = _viewPixelRatio();
    if (ratio == null || ratio == _cachedPixelRatio) return;
    if (_cachedPixelRatio != null) _dropTextures();
    _cachedPixelRatio = ratio;
  }

  void _dropTextures() {
    _clearAtlas(immediate: true);
    for (final texture in _cache.values) {
      texture.dispose();
    }
    _cache.clear();
    _cacheBytes = 0;
    _textureGeneration++;
  }

  /// Lightweight pair cache: per pair of glyphs, the kerning between them and
  /// the width the second takes up next to the first, which tells whether
  /// the font joins them. Record-keyed so a hash collision can never silently
  /// return the wrong pair. No textLeading or letterSpacing — those are
  /// composition-time values.
  late final Flut5ExpiringCache<
    (String, String, String, double, FontWeight, FontStyle, String),
    ({double kern, double secondWidth})
  >
  _pairCache = Flut5ExpiringCache(() => _frame);

  /// Lightweight width-only cache — stores a plain `double` per string/style.
  /// Used by [measureWidth] to avoid rasterizing a GPU texture just to read a
  /// width. Record-keyed for collision-proof lookups.
  late final Flut5ExpiringCache<
    (String, String, double, FontWeight, FontStyle, String),
    double
  >
  _widthCache = Flut5ExpiringCache(() => _frame);

  /// Lightweight line-height cache — one `double` per font style tuple.
  /// Used by [measureLineHeight] so the dynamic text pipeline never
  /// rasterizes a reference-glyph texture just to read a line height.
  late final Flut5ExpiringCache<
    (String, double, FontWeight, FontStyle, String),
    double
  >
  _lineHeightCache = Flut5ExpiringCache(() => _frame);

  /// Lightweight ascent/descent cache — one record per font style tuple.
  /// Used by [measureAscentDescent] so [Flut5Text.textAscent] and
  /// [Flut5Text.textDescent] never rasterize a texture just to read metrics.
  late final Flut5ExpiringCache<
    (String, double, FontWeight, FontStyle, String),
    (double, double)
  >
  _ascentDescentCache = Flut5ExpiringCache(() => _frame);

  /// Whole-block measurements for [measureBlock].
  late final Flut5ExpiringCache<
    (
      String,
      double?,
      double?,
      String,
      double,
      FontWeight,
      FontStyle,
      double?,
      double?,
      TextAlign,
      String,
    ),
    ({double width, double height})
  >
  _blockCache = Flut5ExpiringCache(() => _frame);

  /// Cached word-wrap layouts for the dynamic text pipeline. A hit makes
  /// per-frame layout a single hash read instead of re-tokenizing and
  /// re-measuring every glyph.
  late final Flut5ExpiringCache<_LayoutKey, Flut5TextLayout> _layoutCache =
      Flut5ExpiringCache(() => _frame);

  /// Pre-tokenized and pre-measured word runs keyed by `(text, fontFamily,
  /// fontSize, fontWeight, fontStyle, fontVariationKey)`. Speeds up
  /// wrapped-text re-layout when `letterSpacing` or `maxWidth` animates.
  late final Flut5ExpiringCache<
    (String, String, double, FontWeight, FontStyle, String),
    _TokenizedText
  >
  _tokenCache = Flut5ExpiringCache(() => _frame);

  // A string that changes every frame — a counter, a timer, a paragraph
  // whose width or wrapped spacing is animated — makes a new layout each
  // frame that is never asked for again. Kept for the full timeout like any
  // other, a few of those fill the cache with hundreds of dead layouts. So
  // a new layout is on trial: [_newLayouts] lists the ones made in each of
  // the last [_newLayoutTrialFrames] frames, and one that no later frame
  // asked for by the end of its trial is dropped then. Text that stays on
  // screen is asked for again the very next frame and lives on as before.
  static const int _newLayoutTrialFrames = 8;
  final List<List<(_LayoutKey, Flut5TextLayout)>> _newLayouts = List.generate(
    _newLayoutTrialFrames,
    (_) => [],
  );

  /// Ends the trial of the layouts made [_newLayoutTrialFrames] - 1 frames
  /// ago, dropping the ones never used in a later frame.
  void _dropLayoutsNeverUsedAgain() {
    final tried = _newLayouts[(_frame + 1) % _newLayoutTrialFrames];
    for (final (key, layout) in tried) {
      // Still the layout under that key, not a newer one made after this
      // one was evicted.
      if (!layout._usedAgain && identical(_layoutCache.peek(key), layout)) {
        _layoutCache.remove(key);
      }
    }
    tried.clear();
  }

  /// Memoized single-character strings keyed by code point, so layout never
  /// allocates the same one-char string twice.
  late final Flut5ExpiringCache<int, String> _charStrings = Flut5ExpiringCache(
    () => _frame,
  );

  String _charString(int codePoint) =>
      _charStrings[codePoint] ??= String.fromCharCode(codePoint);

  /// Whitespace test on code points — fast path for ASCII, falls back to
  /// `trim()` for the Unicode space characters (matches `String.trim`'s
  /// White_Space semantics used by the previous per-char implementation).
  bool _isWhitespaceCodePoint(int codePoint) {
    if (codePoint == 0x20 || (codePoint >= 0x09 && codePoint <= 0x0D)) {
      return true;
    }
    if (codePoint < 0x80) return false;
    return _charString(codePoint).trim().isEmpty;
  }

  /// Returns a cached rasterized white text image, generating it on miss.
  Flut5CachedText getOrCreate({
    required String text,
    double? maxWidth,
    double? maxHeight,
    required String fontFamily,
    required double fontSize,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    required double? textLeading,
    double? letterSpacing,
    required TextAlign align,
    required int paintingStyle,
    required double strokeWidth,
    List<FontVariation>? fontVariations,
    String fontVariationKey = '',
    int subpixelPhase = 0,
    double rasterScale = 1,
  }) {
    _lookupKey._set(
      text,
      maxWidth,
      maxHeight,
      fontFamily,
      fontSize,
      fontWeight,
      fontStyle,
      textLeading,
      letterSpacing,
      align.index,
      paintingStyle,
      strokeWidth,
      fontVariationKey,
      subpixelPhase,
      rasterScale,
    );

    final existing = _cache[_lookupKey];
    if (existing != null) {
      existing._lastUsedTick = ++_accessTick;
      return existing;
    }

    final key = _TextCacheKey._from(_lookupKey);

    // Generate pure white paint for the texture snapshot
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = paintingStyle == 0 ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontVariations: fontVariations,
          foreground: paint,
          height: textLeading,
          letterSpacing: letterSpacing,
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth ?? double.infinity);

    final width = maxWidth ?? painter.width;
    final height = maxHeight ?? painter.height;

    // Measure reported ink bounds for italic/skewed glyphs, and size the
    // texture's horizontal padding from them. Fonts that report *real* ink
    // boxes (bearings inside the advance, or genuine overhang) get a minimal
    // safety pad — padding is texture memory and per-blit fill rate, paid on
    // every draw. Some decorative fonts instead report their advance box as
    // the tight box (ink flush with both edges), hiding any overhang; those
    // keep the generous fudge factor.
    double leftPad = 0.0;
    double drawWidth = width;
    if (maxWidth == null && maxHeight == null && text.isNotEmpty) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: text.length),
        boxWidthStyle: ui.BoxWidthStyle.tight,
      );
      double rawLeft = double.infinity;
      double rawRight = double.negativeInfinity;
      for (final box in boxes) {
        if (box.left < rawLeft) rawLeft = box.left;
        if (box.right > rawRight) rawRight = box.right;
      }
      final bool hasBoxes = rawRight != double.negativeInfinity;
      // Suspicious: the reported ink is flush with the advance box on BOTH
      // sides (within half a pixel) — likely an advance box in disguise,
      // telling us nothing about real overhang. A visible bearing or genuine
      // overhang on either side counts as honest metrics.
      final bool suspicious =
          !hasBoxes ||
          (rawLeft.abs() <= 0.5 && (rawRight - width).abs() <= 0.5);
      final double overscan = suspicious
          ? (fontSize * 0.35 + strokeWidth).ceilToDouble()
          : (strokeWidth + 2.0).ceilToDouble();
      final double inkLeft = hasBoxes && rawLeft < 0 ? rawLeft : 0.0;
      final double inkRight = hasBoxes && rawRight > width ? rawRight : width;
      leftPad = -inkLeft + overscan;
      drawWidth = inkRight - inkLeft + overscan * 2;
    }

    final pixelsPerUnit = pixelRatio * rasterScale;

    // The raster reaches past the layout box for the ink that does: a
    // stroke's miter tips (up to twice its width out), and accents or
    // swashes above and below the line. Only a maxHeight box clips it.
    final clipsToBox = maxHeight != null;
    final strokeReach = paintingStyle == 0 ? 0.0 : strokeWidth * 2;
    final double inkLeft;
    final double inkRight;
    final double inkTop;
    final double inkBottom;
    if (clipsToBox) {
      inkLeft = leftPad;
      inkRight = drawWidth - leftPad;
      inkTop = 0;
      inkBottom = height;
    } else {
      final extraStroke = maxWidth == null
          ? math.max(0.0, strokeReach - strokeWidth)
          : strokeReach + 2;
      final verticalInk = fontSize * verticalInkReach + strokeReach + 1;
      inkLeft = leftPad + extraStroke;
      inkRight = drawWidth - leftPad + extraStroke;
      inkTop = verticalInk;
      inkBottom = height + verticalInk;
    }
    // Whole device pixels, so the raster keeps the grid it is drawn on. The
    // spare pixel holds the shift of the last subpixel phase.
    final leftPixels = (inkLeft * pixelsPerUnit).ceil();
    final topPixels = (inkTop * pixelsPerUnit).ceil();
    var iWidth = leftPixels + (inkRight * pixelsPerUnit).ceil() + 1;
    var iHeight = topPixels + (inkBottom * pixelsPerUnit).ceil();
    if (iWidth <= 0) iWidth = 1;
    if (iHeight <= 0) iHeight = 1;
    final rasterLeft = leftPixels / pixelsPerUnit;
    final rasterTop = topPixels / pixelsPerUnit;

    // Rasterize Offline
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Scale the canvas up by the pixel ratio for crisp rendering
    canvas.scale(pixelsPerUnit);

    if (clipsToBox) {
      canvas.clipRect(Rect.fromLTWH(0, 0, width, height));
    }

    // The pen goes a whole number of pixels in, plus this raster's phase.
    painter.paint(
      canvas,
      Offset(
        rasterLeft + subpixelPhase / (subpixelPhases * pixelsPerUnit),
        rasterTop,
      ),
    );
    final picture = recorder.endRecording();

    final image = picture.toImageSync(iWidth, iHeight);

    picture.dispose();
    painter.dispose();

    final cachedText = Flut5CachedText(
      image,
      width,
      height,
      drawWidth,
      leftPad,
      iWidth / pixelsPerUnit,
      iHeight / pixelsPerUnit,
      rasterLeft: rasterLeft,
      rasterTop: rasterTop,
      pixelsPerUnit: pixelsPerUnit,
      subpixelPhase: subpixelPhase,
    );
    cachedText._lastUsedTick = ++_accessTick;
    _cache[key] = cachedText;
    cachedText._entry = _cache.entryOf(key);
    _cacheBytes += cachedText.bytes;
    _enforceTextureLimits();

    return cachedText;
  }

  /// How far above and below the line box a raster reserves room for ink,
  /// in ems. Fonts' accents and swashes reach past the line's metrics by up
  /// to about a third of an em (measured across common and display fonts).
  static const double verticalInkReach = 0.4;

  /// Most shadow silhouettes kept per text raster. A shadow that changes
  /// blur or spread every frame bakes anew each time; past this many, the
  /// oldest bake is dropped.
  static const int _shadowsPerText = 4;

  /// [text]'s white raster passed once through [filter] — a shadow's spread
  /// and blur — and kept with the entry under [key], so a shadow blits a
  /// finished silhouette each frame instead of filtering the glyphs again.
  /// Drawing the same shadow again — next frame, or under a new `shadow()`
  /// call with the same [key] — reuses the bake. [reach] is how far
  /// [filter] can spread the raster, in logical pixels.
  ///
  /// The silhouette is baked at the raster's own resolution with the glyphs
  /// where a 1:1 draw puts them, so it lines up with the text exactly. Its
  /// bytes count toward [cacheBytes] and leave with the entry.
  Flut5ShadowRaster bakedShadow(
    Flut5CachedText text,
    Object key,
    Paint filter,
    double reach,
  ) {
    final shadows = text._shadows ??= <Object, Flut5ShadowRaster>{};
    final hit = shadows[key];
    if (hit != null) return hit;

    final ratio = text.pixelsPerUnit;
    // Whole pixels, so the glyphs keep the raster's pixel grid; two spare
    // for the filters' edge rounding.
    final padPx = (reach * ratio).ceil() + 2;
    final pad = padPx / ratio;
    final width = text.image.width + 2 * padPx;
    final height = text.image.height + 2 * padPx;
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..scale(ratio)
      ..drawImageRect(
        text.image,
        text.srcRect,
        Rect.fromLTWH(pad, pad, text.blitWidth, text.blitHeight),
        filter,
      );
    final picture = recorder.endRecording();
    final raster = Flut5ShadowRaster(
      picture.toImageSync(width, height),
      pad,
      Size(width / ratio, height / ratio),
    );
    picture.dispose();

    if (shadows.length >= _shadowsPerText) {
      final oldest = shadows.remove(shadows.keys.first)!;
      _markDeadSlot(oldest._atlasSlot, oldest.image);
      text._shadowBytes -= oldest.bytes;
      _cacheBytes -= oldest.bytes;
      oldest.image.dispose();
    }
    shadows[key] = raster;
    text._shadowBytes += raster.bytes;
    _cacheBytes += raster.bytes;
    // Newest, so a byte overflow evicts other entries first — this one is
    // about to be drawn.
    text._lastUsedTick = ++_accessTick;
    _enforceTextureLimits();
    return raster;
  }

  /// Grows the texture cap, or evicts, when an insert overflows the cache.
  ///
  /// Growth is preferred: LRU degrades gracefully only while the *working
  /// set* fits. Once a sketch cycles through more unique entries per frame
  /// than the cache holds, the victim LRU picks is exactly the entry needed
  /// next, so the hit rate doesn't decay — it collapses. Doubling the cap
  /// costs nothing by itself (it is a bound, not a preallocation); real
  /// memory is bounded by [maxCacheBytes].
  ///
  /// Runs only on inserts, never on the per-frame hit path.
  void _enforceTextureLimits() {
    if (_cache.length <= _maxCacheSize && _cacheBytes <= maxCacheBytes) return;

    // Over on count only, with room left in both budgets → grow instead of
    // evicting. Growth cannot fix a byte overflow, so that path falls through.
    if (autoGrow &&
        _cacheBytes <= maxCacheBytes &&
        _cache.length > _maxCacheSize &&
        _maxCacheSize < growthLimit) {
      final previous = _maxCacheSize;
      _maxCacheSize = (_maxCacheSize * 2).clamp(1, growthLimit);
      _warnTextureGrowth(previous);
      return;
    }

    // Evicting frees images glyphs queued for the atlas may still need: get
    // them onto their pages first.
    _commitPendingAtlasPages();
    if (!_textureGrowthStopWarned) {
      _textureGrowthStopWarned = true;
      final reason = _cacheBytes > maxCacheBytes
          ? 'memory budget (${_formatBytes(maxCacheBytes)})'
          : 'entry ceiling ($_maxCacheSize)';
      Flut5Console.printLater(
        'text texture cache hit its $reason — least-recently-used entries are '
        'now evicted and re-rasterized on next use. If the sketch touches more '
        'unique text/style/size combinations than this every frame, the hit '
        'rate collapses and every glyph re-rasterizes. $_quantizeAdvice Or '
        'raise the ceiling: textCacheGrowthLimit / textCacheMaxBytes.',
      );
    }
    _evictStaleTextures();
  }

  /// Evicts least-recently-used textures in one batch until both budgets fit.
  ///
  /// Trims to 7/8 of each limit using a heap to select only the victims,
  /// avoiding a full sort while keeping the ordinary cache-hit path unchanged.
  void _evictStaleTextures() {
    final targetCount = _maxCacheSize - (_maxCacheSize >> 3);
    final targetBytes = maxCacheBytes - (maxCacheBytes >> 3);

    // Ticks are unique, so priority selection preserves the exact old LRU
    // order. Keep the newest texture even if it alone exceeds the budget.
    _cache.evictWhile(
      () =>
          _cache.length > 1 &&
          (_cache.length > targetCount || _cacheBytes > targetBytes),
      (a, b) => a._lastUsedTick.compareTo(b._lastUsedTick),
      _releaseTexture,
    );
  }

  void _warnTextureGrowth(int previous) {
    if (!_textureLimitWarned) {
      _textureLimitWarned = true;
      Flut5Console.printLater(
        'text texture cache grew $previous → $_maxCacheSize entries '
        '(${_formatBytes(_cacheBytes)} of ${_formatBytes(maxCacheBytes)}). The '
        'sketch is using more unique text/style/size combinations than the '
        'cache held; growing keeps the hit rate up instead of thrashing, but '
        'every entry is a GPU texture. $_quantizeAdvice Auto-growth stops at '
        '$growthLimit entries or ${_formatBytes(maxCacheBytes)}, then falls '
        'back to LRU eviction — set textCacheAutoGrow = false for a hard cap.',
      );
      return;
    }
    Flut5Console.printLater(
      'text texture cache grew $previous → $_maxCacheSize entries '
      '(${_formatBytes(_cacheBytes)} of ${_formatBytes(maxCacheBytes)}).',
    );
  }

  /// Shared best-practice advice — the cache key is (text, family, size,
  /// weight, style, leading, letterSpacing, align, paintingStyle,
  /// strokeWidth, maxWidth, maxHeight), so any of those varying continuously
  /// mints a fresh entry every frame.
  static const String _quantizeAdvice =
      'To stop the growth at the source: quantize animated values so entries '
      'repeat — textSize((s / 4).round() * 4), and likewise letterSpacing, '
      'textLeading, strokeWeight and the maxWidth passed to text(); and use '
      'textDynamic() for text whose content changes (scores, timers, '
      'counters), which caches per glyph — "Score: 1234" costs a few digit '
      'textures rather than one texture per distinct value — reserving '
      'textStatic() for strings that repeat verbatim.';

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Returns the pixel width of [text] without rasterizing a GPU texture.
  ///
  /// First checks the main [getOrCreate] cache — if the text was already
  /// rendered, its stored width is returned for free. Otherwise falls back
  /// to a lightweight `Map<int, double>` keyed on the text/style tuple.
  double measureWidth({
    required String text,
    required String fontFamily,
    required double fontSize,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    List<FontVariation>? fontVariations,
    String fontVariationKey = '',
  }) {
    // Reuse an existing rasterized entry's width if one exists — free win.
    _lookupKey._set(
      text,
      null,
      null,
      fontFamily,
      fontSize,
      fontWeight,
      fontStyle,
      null,
      null,
      TextAlign.left.index,
      0,
      0.0,
      fontVariationKey,
      0,
      1.0,
    );
    final existing = _cache[_lookupKey];
    if (existing != null) {
      existing._lastUsedTick = ++_accessTick;
      return existing.width;
    }

    final key = (
      text,
      fontFamily,
      fontSize,
      fontWeight,
      fontStyle,
      fontVariationKey,
    );
    final cached = _widthCache[key];
    if (cached != null) return cached;

    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontVariations: fontVariations,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final width = painter.width;
    painter.dispose();

    _widthCache[key] = width;
    return width;
  }

  /// The width and height of [text] laid out as one block, as the
  /// whole-string pipeline draws it, without rasterizing a texture.
  ({double width, double height}) measureBlock({
    required String text,
    double? maxWidth,
    double? maxHeight,
    required String fontFamily,
    required double fontSize,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    required double? textLeading,
    double? letterSpacing,
    required TextAlign align,
    List<FontVariation>? fontVariations,
    String fontVariationKey = '',
  }) {
    final key = (
      text,
      maxWidth,
      maxHeight,
      fontFamily,
      fontSize,
      fontWeight,
      fontStyle,
      textLeading,
      letterSpacing,
      align,
      fontVariationKey,
    );
    final cached = _blockCache[key];
    if (cached != null) return cached;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontVariations: fontVariations,
          height: textLeading,
          letterSpacing: letterSpacing,
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth ?? double.infinity);
    final block = (
      width: maxWidth ?? painter.width,
      height: maxHeight ?? painter.height,
    );
    painter.dispose();
    return _blockCache[key] = block;
  }

  /// Returns the font's default line height for the given style without
  /// rasterizing a GPU texture.
  ///
  /// Lays out a reference glyph (`'M'`) with [TextPainter] once per style
  /// tuple and caches the resulting height as a plain `double`. Replaces the
  /// old behavior of fetching a full cached texture of `'M'` just to read its
  /// height — which consumed a texture cache slot per distinct font size.
  double measureLineHeight({
    required String fontFamily,
    required double fontSize,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    List<FontVariation>? fontVariations,
    String fontVariationKey = '',
  }) {
    final key = (fontFamily, fontSize, fontWeight, fontStyle, fontVariationKey);
    final cached = _lineHeightCache[key];
    if (cached != null) return cached;

    final painter = TextPainter(
      text: TextSpan(
        text: 'M',
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontVariations: fontVariations,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final height = painter.height;
    painter.dispose();

    _lineHeightCache[key] = height;
    return height;
  }

  /// Returns the font's `(ascent, descent)` in pixels for the given style.
  ///
  /// Both come from the first line's [LineMetrics] of a reference-glyph
  /// layout — font-wide values independent of which glyphs a string uses.
  /// Cached per style tuple, like [measureLineHeight].
  (double, double) measureAscentDescent({
    required String fontFamily,
    required double fontSize,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    List<FontVariation>? fontVariations,
    String fontVariationKey = '',
  }) {
    final key = (fontFamily, fontSize, fontWeight, fontStyle, fontVariationKey);
    final cached = _ascentDescentCache[key];
    if (cached != null) return cached;

    final painter = TextPainter(
      text: TextSpan(
        text: 'M',
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontVariations: fontVariations,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final metrics = painter.computeLineMetrics().first;
    final result = (metrics.ascent, metrics.descent);
    painter.dispose();

    _ascentDescentCache[key] = result;
    return result;
  }

  /// Returns the cached word-wrap layout for [text], computing it on miss.
  ///
  /// Letter spacing and kerning are baked into each line's glyph offsets, so
  /// the dynamic text pipeline draws a cached layout without any per-frame
  /// measurement. [letterSpacing] and [maxWidth] are part of the key, so
  /// spacing stays a composition-time value.
  Flut5TextLayout getOrCreateLayout({
    required String text,
    required String fontFamily,
    required double fontSize,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    required double letterSpacing,
    double? maxWidth,
    List<FontVariation>? fontVariations,
    String fontVariationKey = '',
  }) {
    final key = (
      text,
      fontFamily,
      fontSize,
      fontWeight,
      fontStyle,
      letterSpacing,
      maxWidth,
      fontVariationKey,
    );
    final existing = _layoutCache[key];
    if (existing != null) {
      existing._lastUsedTick = ++_accessTick;
      if (existing._createdFrame != _frame) existing._usedAgain = true;
      return existing;
    }

    final layout = _computeLayout(
      text,
      fontFamily,
      fontSize,
      fontWeight,
      fontStyle,
      letterSpacing,
      maxWidth,
      fontVariations,
      fontVariationKey,
    );
    layout._lastUsedTick = ++_accessTick;
    layout._createdFrame = _frame;
    _layoutCache[key] = layout;
    _newLayouts[_frame % _newLayoutTrialFrames].add((key, layout));

    _enforceLayoutLimits();

    return layout;
  }

  /// Grows the layout cap, or evicts, when an insert overflows the cache.
  ///
  /// Same rationale as [_enforceTextureLimits], and layouts are the cheaper
  /// of the two to retain (strings and doubles, no GPU memory) — so there is
  /// no byte budget here, only [layoutGrowthLimit].
  void _enforceLayoutLimits() {
    if (_layoutCache.length <= _maxLayoutCacheSize) return;

    if (autoGrow && _maxLayoutCacheSize < layoutGrowthLimit) {
      final previous = _maxLayoutCacheSize;
      _maxLayoutCacheSize = (_maxLayoutCacheSize * 2).clamp(
        1,
        layoutGrowthLimit,
      );
      if (!_layoutLimitWarned) {
        _layoutLimitWarned = true;
        Flut5Console.printLater(
          'text layout cache grew $previous → $_maxLayoutCacheSize entries. '
          'Layouts hold only strings and doubles, so this is far cheaper than '
          'texture growth, but it signals the same cause. $_quantizeAdvice '
          'Auto-growth stops at $layoutGrowthLimit entries — set '
          'textCacheAutoGrow = false for a hard cap.',
        );
      } else {
        Flut5Console.printLater(
          'text layout cache grew $previous → $_maxLayoutCacheSize entries.',
        );
      }
      return;
    }

    if (!_layoutGrowthStopWarned) {
      _layoutGrowthStopWarned = true;
      Flut5Console.printLater(
        'text layout cache hit its entry ceiling ($_maxLayoutCacheSize) — '
        'least-recently-used layouts are now evicted and recomputed on next '
        'use. A recomputed layout re-measures every glyph, so if the sketch '
        'touches more unique combinations than this every frame the cost is '
        'paid per draw. $_quantizeAdvice Or raise textLayoutCacheGrowthLimit.',
      );
    }

    // Keep the batch-eviction target and exact per-access LRU order.
    final targetCount = _maxLayoutCacheSize - (_maxLayoutCacheSize >> 3);
    _layoutCache.evictWhile(
      () => _layoutCache.length > targetCount,
      (a, b) => a._lastUsedTick.compareTo(b._lastUsedTick),
      (_) {},
    );
  }

  _TokenizedText _getOrCreateTokenized(
    String text,
    String fontFamily,
    double fontSize,
    FontWeight fontWeight,
    FontStyle fontStyle,
    List<FontVariation>? fontVariations,
    String fontVariationKey,
  ) {
    final key = (
      text,
      fontFamily,
      fontSize,
      fontWeight,
      fontStyle,
      fontVariationKey,
    );
    final cached = _tokenCache[key];
    if (cached != null) return cached;

    double advance(String ch) => measureWidth(
      text: ch,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      fontVariations: fontVariations,
      fontVariationKey: fontVariationKey,
    );

    double kern(String a, String b) => getKernOffset(
      a: a,
      b: b,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      fontVariations: fontVariations,
      fontVariationKey: fontVariationKey,
    );

    final rawSegments = text.split('\n');
    final segments = <_TokenizedSegment>[];
    for (int s = 0; s < rawSegments.length; s++) {
      final segment = rawSegments[s];
      final tokens = <_MeasuredToken>[];
      if (segment.isNotEmpty) {
        final codePoints = segment.runes.toList(growable: false);
        int i = 0;
        while (i < codePoints.length) {
          final tokenIsWhitespace = _isWhitespaceCodePoint(codePoints[i]);
          var chars = <String>[];
          while (i < codePoints.length &&
              _isWhitespaceCodePoint(codePoints[i]) == tokenIsWhitespace) {
            chars.add(_charString(codePoints[i]));
            i++;
          }
          if (!tokenIsWhitespace) {
            chars = _joinShapedGlyphs(
              chars,
              fontFamily,
              fontSize,
              fontWeight,
              fontStyle,
              fontVariations,
              fontVariationKey,
            );
          }
          final count = chars.length;
          final advances = Float64List(count);
          final internalKerns = count > 1
              ? Float64List(count - 1)
              : Float64List(0);
          double baseWidth = 0.0;
          for (int t = 0; t < count; t++) {
            final adv = advance(chars[t]);
            advances[t] = adv;
            baseWidth += adv;
            if (t < count - 1) {
              final k = kern(chars[t], chars[t + 1]);
              internalKerns[t] = k;
              baseWidth += k;
            }
          }
          tokens.add(
            _MeasuredToken(
              tokenIsWhitespace,
              chars,
              advances,
              internalKerns,
              baseWidth,
            ),
          );
        }
      }
      final joinKerns = tokens.length > 1
          ? Float64List(tokens.length - 1)
          : Float64List(0);
      for (int t = 0; t < tokens.length - 1; t++) {
        joinKerns[t] = kern(tokens[t].lastChar, tokens[t + 1].firstChar);
      }
      segments.add(_TokenizedSegment(tokens, joinKerns));
    }

    final tokenized = _TokenizedText(segments);
    _tokenCache[key] = tokenized;
    return tokenized;
  }

  /// [chars] with the runs the font shapes into one glyph, like an "fi"
  /// ligature, merged into one entry — they have to be rasterized together.
  ///
  /// A pair is joined when its second character takes up a different width
  /// next to the first than on its own: kerning moves a glyph but leaves its
  /// width alone, and a ligature divides its width among its characters. A
  /// three-letter ligature shows up as the last two also being divided
  /// differently once the first is in front of them.
  List<String> _joinShapedGlyphs(
    List<String> chars,
    String fontFamily,
    double fontSize,
    FontWeight fontWeight,
    FontStyle fontStyle,
    List<FontVariation>? fontVariations,
    String fontVariationKey,
  ) {
    if (chars.length < 2) return chars;
    ({double kern, double secondWidth}) pair(String a, String b) =>
        _pairMetrics(
          a: a,
          b: b,
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontVariations: fontVariations,
          fontVariationKey: fontVariationKey,
        );
    const widthTolerance = 0.02;
    List<bool>? joinsNext;
    for (var i = 0; i + 1 < chars.length; i++) {
      final metrics = pair(chars[i], chars[i + 1]);
      final alone = measureWidth(
        text: chars[i + 1],
        fontFamily: fontFamily,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        fontVariations: fontVariations,
        fontVariationKey: fontVariationKey,
      );
      if ((metrics.secondWidth - alone).abs() <= widthTolerance) continue;
      joinsNext ??= List<bool>.filled(chars.length - 1, false);
      joinsNext[i] = true;
      if (i > 0 && !joinsNext[i - 1]) {
        final withFirst = pair('${chars[i - 1]}${chars[i]}', chars[i + 1]);
        if ((withFirst.secondWidth - metrics.secondWidth).abs() >
            widthTolerance) {
          joinsNext[i - 1] = true;
        }
      }
    }
    if (joinsNext == null) return chars;
    final glyphs = <String>[];
    var glyph = chars.first;
    for (var i = 1; i < chars.length; i++) {
      if (joinsNext[i - 1]) {
        glyph += chars[i];
      } else {
        glyphs.add(glyph);
        glyph = chars[i];
      }
    }
    glyphs.add(glyph);
    return glyphs;
  }

  /// Word-wrap layout over pre-tokenized word runs. Runs only on layout-cache
  /// misses.
  ///
  /// Wrap semantics match the previous per-item implementation: lines break
  /// on whitespace/non-whitespace token boundaries when a non-whitespace
  /// token would overflow [maxWidth], and whitespace tokens are dropped at
  /// the start of wrapped lines.
  Flut5TextLayout _computeLayout(
    String text,
    String fontFamily,
    double fontSize,
    FontWeight fontWeight,
    FontStyle fontStyle,
    double spacing,
    double? maxWidth,
    List<FontVariation>? fontVariations,
    String fontVariationKey,
  ) {
    final tokenized = _getOrCreateTokenized(
      text,
      fontFamily,
      fontSize,
      fontWeight,
      fontStyle,
      fontVariations,
      fontVariationKey,
    );

    final lines = <Flut5TextLine>[];
    var glyphs = <String>[];
    var offsets = <double>[];
    var spacingIndices = maxWidth == null ? <int>[] : null;
    var lineTokens = <_MeasuredToken>[];
    double penX = 0.0;
    int lineCharCount = 0;

    void flush() {
      lines.add(
        Flut5TextLine._(
          glyphs,
          Float64List.fromList(offsets),
          penX,
          lineCharCount > 0,
          spacingIndices == null ? null : Int32List.fromList(spacingIndices!),
          lineCharCount > 0 ? lineCharCount - 1 : 0,
          lineTokens,
        ),
      );
      lineTokens = <_MeasuredToken>[];
      glyphs = <String>[];
      offsets = <double>[];
      spacingIndices = maxWidth == null ? <int>[] : null;
      penX = 0.0;
      lineCharCount = 0;
    }

    final segments = tokenized.segments;
    for (int s = 0; s < segments.length; s++) {
      final seg = segments[s];
      final tokens = seg.tokens;
      final joinKerns = seg.joinKerns;
      for (int ti = 0; ti < tokens.length; ti++) {
        final token = tokens[ti];
        final tokenLen = token.length;
        final tokenWidth = spacing == 0.0 || tokenLen <= 1
            ? token.baseWidth
            : token.baseWidth + (tokenLen - 1) * spacing;

        if (maxWidth != null && lineCharCount > 0 && !token.isWhitespace) {
          final joinGap = spacing + joinKerns[ti - 1];
          if (penX + joinGap + tokenWidth > maxWidth) flush();
        }
        if (maxWidth != null && token.isWhitespace && lineCharCount == 0) {
          continue;
        }

        if (lineCharCount > 0) {
          penX += spacing + joinKerns[ti - 1];
        }
        lineTokens.add(token);
        final chars = token.chars;
        final advances = token.advances;
        final internalKerns = token.internalKerns;
        for (int t = 0; t < tokenLen; t++) {
          if (!token.isWhitespace) {
            glyphs.add(chars[t]);
            offsets.add(penX);
            spacingIndices?.add(lineCharCount + t);
          }
          penX += advances[t];
          if (t < tokenLen - 1) penX += spacing + internalKerns[t];
        }
        lineCharCount += tokenLen;
      }
      if (s < segments.length - 1) flush();
    }

    if (lineCharCount > 0 || lines.isEmpty) flush();
    return Flut5TextLayout(lines);
  }

  /// Returns the kerning offset between [a] and [b] for the given font config.
  ///
  /// Measures the pair width via [TextPainter] and subtracts individual character
  /// widths to derive the font's kerning adjustment. Expires after the configured idle-frame timeout.
  /// A negative value means the characters should sit closer together.
  double getKernOffset({
    required String a,
    required String b,
    required String fontFamily,
    required double fontSize,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    List<FontVariation>? fontVariations,
    String fontVariationKey = '',
  }) => _pairMetrics(
    a: a,
    b: b,
    fontFamily: fontFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    fontStyle: fontStyle,
    fontVariations: fontVariations,
    fontVariationKey: fontVariationKey,
  ).kern;

  /// The kerning between [a] and [b], and the width [b] takes up right after
  /// [a], measured once from the shaped pair.
  ({double kern, double secondWidth}) _pairMetrics({
    required String a,
    required String b,
    required String fontFamily,
    required double fontSize,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    List<FontVariation>? fontVariations,
    String fontVariationKey = '',
  }) {
    final key = (
      a,
      b,
      fontFamily,
      fontSize,
      fontWeight,
      fontStyle,
      fontVariationKey,
    );

    final cached = _pairCache[key];
    if (cached != null) return cached;

    // Measure the pair as a single string
    final painter = TextPainter(
      text: TextSpan(
        text: '$a$b',
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontVariations: fontVariations,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final pairWidth = painter.width;
    final secondBoxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: a.length, extentOffset: a.length + b.length),
    );
    var secondWidth = 0.0;
    for (final box in secondBoxes) {
      secondWidth += box.right - box.left;
    }
    painter.dispose();

    // Measure individual widths without rasterizing GPU textures (avoids
    // creating blank textures for whitespace or unused fill glyphs for
    // stroke-only dynamic text).
    final aWidth = measureWidth(
      text: a,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      fontVariations: fontVariations,
      fontVariationKey: fontVariationKey,
    );

    final bWidth = measureWidth(
      text: b,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      fontVariations: fontVariations,
      fontVariationKey: fontVariationKey,
    );

    final metrics = (
      kern: pairWidth - aWidth - bWidth,
      secondWidth: secondWidth,
    );
    _pairCache[key] = metrics;
    return metrics;
  }

  void clear() {
    _clearAtlas(immediate: true);
    for (final ct in _cache.values) {
      ct.dispose();
    }
    _cache.clear();
    _cacheBytes = 0;
    _textureGeneration++;
    _atlasPageLimit = _firstAtlasPageLimit;
    _atlasFilledThisFrame = false;
    _atlasLimitWarned = false;
    _recentStyles.clear();
    for (final asked in _askedStyles) {
      asked.frame = -1;
    }
    _framesWithNewStyles = 0;
    _newStyleThisFrame = false;
    for (final made in _newLayouts) {
      made.clear();
    }
    _tokenCache.clear();
    _pairCache.clear();
    _widthCache.clear();
    _lineHeightCache.clear();
    _blockCache.clear();
    _ascentDescentCache.clear();
    _layoutCache.clear();
    _charStrings.clear();
    _lookupKey.text = '';
    _lookupKey.fontFamily = '';
    _textureLimitWarned = false;
    _layoutLimitWarned = false;
    _textureGrowthStopWarned = false;
    _layoutGrowthStopWarned = false;
  }
}
