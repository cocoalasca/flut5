import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';

import 'flut5_expiring_cache.dart';

import '../core/flut5_console.dart';

/// One laid-out line of dynamic text.
///
/// Holds only the drawable (non-whitespace) glyphs with their pen offsets —
/// letter spacing and kerning are already baked into [offsets], so drawing a
/// line is a flat loop with no measurement work. Whitespace still contributes
/// to [width] and to the offsets of the glyphs that follow it.
class Flut5TextLine._(
  /// Drawable glyphs in draw order. Whitespace is excluded (never blitted).
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
) {
  // Source character positions include whitespace, unlike the drawable
  // glyph list. They let unwrapped text apply spacing without retaining a
  // different layout for every animation value.
  Flut5TextLine(
    List<String> glyphs,
    Float64List offsets,
    double width,
    bool hasChars,
  ) : this._(glyphs, offsets, width, hasChars, null, 0);

  /// Internal: width after adding composition-time spacing to this layout.
  double widthWithSpacing(double spacing) => spacing == 0 || _spacingGaps == 0
      ? width
      : width + _spacingGaps * spacing;

  /// Internal: glyph offset after adding composition-time spacing.
  double offsetWithSpacing(int index, double spacing) {
    final position = _spacingIndices?[index] ?? 0;
    return spacing == 0 || position == 0
        ? offsets[index]
        : offsets[index] + position * spacing;
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
}

/// Composite key for cached layouts:
/// (text, fontFamily, fontSize, fontWeight, fontStyle, letterSpacing, maxWidth).
typedef _LayoutKey = (
  String,
  String,
  double,
  FontWeight,
  FontStyle,
  double,
  double?,
);

class Flut5CachedText(
  final ui.Image image,
  final double width,
  final double height,
  final double drawWidth,
  final double leftPad,
) {
  // advance width used for character spacing
  // image logical width; wider than width when glyphs overhang right
  // shift (logical px) to apply when drawing; non-zero for left overhang

  /// Pre-computed source rect for `drawImageRect` — avoids per-frame allocation.
  late final Rect srcRect = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );

  /// Decoded size of [image] in bytes, assuming RGBA. [ui.Image.width] and
  /// [ui.Image.height] are pixel dimensions — already scaled by the device
  /// pixel ratio — so this is the real GPU cost of the entry.
  final int bytes;

  /// LRU bookkeeping — last [Flut5TextCache._accessTick] this entry was used.
  int _lastUsedTick = 0;

  this : bytes = image.width * image.height * 4;

  void dispose() {
    image.dispose();
  }
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
          strokeWidth == other.strokeWidth;

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
    _cache.expire(_timeoutFrames);
    _layoutCache.expire(_timeoutFrames);
    _kernCache.expire(_timeoutFrames);
    _widthCache.expire(_timeoutFrames);
    _lineHeightCache.expire(_timeoutFrames);
    _ascentDescentCache.expire(_timeoutFrames);
    _charStrings.expire(_timeoutFrames);
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
    'kerning': _kernCache.length,
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
    onExpire: (entry) {
      _cacheBytes -= entry.bytes;
      entry.dispose();
    },
  );

  /// Monotonic access counter used to stamp entries for LRU eviction.
  int _accessTick = 0;

  /// Reusable key for lookups — avoids allocating a new key on cache hits.
  final _TextCacheKey _lookupKey = _TextCacheKey._mutable();

  /// Cached device pixel ratio — rarely changes during a session.
  double? _cachedPixelRatio;

  /// Lightweight kern cache — stores only the offset double per character
  /// pair. Record-keyed so a hash collision can never silently return the
  /// wrong pair's kerning. No textLeading or letterSpacing — those are
  /// composition-time values.
  late final Flut5ExpiringCache<
    (String, String, String, double, FontWeight, FontStyle),
    double
  >
  _kernCache = Flut5ExpiringCache(() => _frame);

  /// Lightweight width-only cache — stores a plain `double` per string/style.
  /// Used by [measureWidth] to avoid rasterizing a GPU texture just to read a
  /// width. Record-keyed for collision-proof lookups.
  late final Flut5ExpiringCache<
    (String, String, double, FontWeight, FontStyle),
    double
  >
  _widthCache = Flut5ExpiringCache(() => _frame);

  /// Lightweight line-height cache — one `double` per font style tuple.
  /// Used by [measureLineHeight] so the dynamic text pipeline never
  /// rasterizes a reference-glyph texture just to read a line height.
  late final Flut5ExpiringCache<(String, double, FontWeight, FontStyle), double>
  _lineHeightCache = Flut5ExpiringCache(() => _frame);

  /// Lightweight ascent/descent cache — one record per font style tuple.
  /// Used by [measureAscentDescent] so [Flut5Text.textAscent] and
  /// [Flut5Text.textDescent] never rasterize a texture just to read metrics.
  late final Flut5ExpiringCache<
    (String, double, FontWeight, FontStyle),
    (double, double)
  >
  _ascentDescentCache = Flut5ExpiringCache(() => _frame);

  /// Cached word-wrap layouts for the dynamic text pipeline. A hit makes
  /// per-frame layout a single hash read instead of re-tokenizing and
  /// re-measuring every glyph.
  late final Flut5ExpiringCache<_LayoutKey, Flut5TextLayout> _layoutCache =
      Flut5ExpiringCache(() => _frame);

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

    // Cached device pixel ratio — avoids try/catch on every miss
    if (_cachedPixelRatio == null) {
      try {
        final views = ui.PlatformDispatcher.instance.views;
        if (views.isNotEmpty) {
          _cachedPixelRatio = views.first.devicePixelRatio;
        }
      } catch (_) {}
    }
    final double pixelRatio = _cachedPixelRatio ?? 1.0;

    // Rasterize Offline
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Scale the canvas up by the pixel ratio for crisp rendering
    canvas.scale(pixelRatio);

    if (maxHeight != null || maxWidth != null) {
      canvas.clipRect(Rect.fromLTWH(0, 0, width, height));
    }

    // Shift right by leftPad so left-overhanging glyphs land inside the image
    painter.paint(canvas, Offset(leftPad, 0));
    final picture = recorder.endRecording();

    int iWidth = (drawWidth * pixelRatio).ceil();
    int iHeight = (height * pixelRatio).ceil();
    if (iWidth <= 0) iWidth = 1;
    if (iHeight <= 0) iHeight = 1;

    final image = picture.toImageSync(iWidth, iHeight);

    picture.dispose();
    painter.dispose();

    final cachedText = Flut5CachedText(
      image,
      width,
      height,
      drawWidth,
      leftPad,
    );
    cachedText._lastUsedTick = ++_accessTick;
    _cache[key] = cachedText;
    _cacheBytes += cachedText.bytes;
    _enforceTextureLimits();

    return cachedText;
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
  /// Trims to 7/8 of each limit rather than to exactly the limit, so the O(n)
  /// sort amortizes across the ~n/8 inserts before the next eviction instead
  /// of running per insert.
  void _evictStaleTextures() {
    final targetCount = _maxCacheSize - (_maxCacheSize >> 3);
    final targetBytes = maxCacheBytes - (maxCacheBytes >> 3);

    // Ticks are unique per entry (each stamp increments the counter), so a
    // plain ascending sort is a total order from coldest to hottest.
    final entries = _cache.entries.toList()
      ..sort((a, b) => a.value._lastUsedTick.compareTo(b.value._lastUsedTick));

    // Stop short of the last element — the entry just inserted carries the
    // highest tick, so it sorts last. [getOrCreate] returns it, and a
    // disposed image would crash at draw time. This matters on the byte
    // path, where one oversized texture can otherwise consume the whole
    // budget and walk the loop to the end. Worst case the cache sits a
    // single entry over budget until the next insert.
    for (var i = 0; i < entries.length - 1; i++) {
      if (_cache.length <= targetCount && _cacheBytes <= targetBytes) break;
      final removed = _cache.remove(entries[i].key);
      if (removed == null) continue;
      _cacheBytes -= removed.bytes;
      removed.dispose();
    }
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
    );
    final existing = _cache[_lookupKey];
    if (existing != null) {
      existing._lastUsedTick = ++_accessTick;
      return existing.width;
    }

    final key = (text, fontFamily, fontSize, fontWeight, fontStyle);
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
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final width = painter.width;
    painter.dispose();

    _widthCache[key] = width;
    return width;
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
  }) {
    final key = (fontFamily, fontSize, fontWeight, fontStyle);
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
  }) {
    final key = (fontFamily, fontSize, fontWeight, fontStyle);
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
  }) {
    final key = (
      text,
      fontFamily,
      fontSize,
      fontWeight,
      fontStyle,
      letterSpacing,
      maxWidth,
    );
    final existing = _layoutCache[key];
    if (existing != null) {
      existing._lastUsedTick = ++_accessTick;
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
    );
    layout._lastUsedTick = ++_accessTick;
    _layoutCache[key] = layout;

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

    // Batch-evict to 7/8 of the cap so the O(n) sort amortizes — see
    // [_evictStaleTextures].
    final targetCount = _maxLayoutCacheSize - (_maxLayoutCacheSize >> 3);
    final entries = _layoutCache.entries.toList()
      ..sort((a, b) => a.value._lastUsedTick.compareTo(b.value._lastUsedTick));
    for (final entry in entries) {
      if (_layoutCache.length <= targetCount) break;
      _layoutCache.remove(entry.key);
    }
  }

  /// Word-wrap layout over code points. Runs only on layout-cache misses.
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
  ) {
    double advance(String ch) => getOrCreate(
      text: ch,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      textLeading: null,
      align: TextAlign.left,
      paintingStyle: 0,
      strokeWidth: 0.0,
    ).width;

    // Whitespace is measured but never blitted, so its advance comes from the
    // width-only cache — rasterizing a blank texture would waste a cache slot
    // per whitespace character per font size.
    double whitespaceAdvance(String ch) => measureWidth(
      text: ch,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
    );

    double kern(String a, String b) => getKernOffset(
      a: a,
      b: b,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
    );

    final lines = <Flut5TextLine>[];
    var glyphs = <String>[];
    var offsets = <double>[];
    var spacingIndices = maxWidth == null ? <int>[] : null;
    double penX = 0.0;
    int lineCharCount = 0;
    String? lastChar;

    void flush() {
      lines.add(
        Flut5TextLine._(
          glyphs,
          Float64List.fromList(offsets),
          penX,
          lineCharCount > 0,
          spacingIndices == null ? null : Int32List.fromList(spacingIndices!),
          lineCharCount > 0 ? lineCharCount - 1 : 0,
        ),
      );
      glyphs = <String>[];
      offsets = <double>[];
      spacingIndices = maxWidth == null ? <int>[] : null;
      penX = 0.0;
      lineCharCount = 0;
      lastChar = null;
    }

    // Per-token scratch buffers, reused across tokens to avoid churn.
    final tokenChars = <String>[];
    final tokenAdvances = <double>[];
    final tokenGaps = <double>[]; // spacing + kern after each char except last

    final segments = text.split('\n');
    for (int s = 0; s < segments.length; s++) {
      final segment = segments[s];
      if (segment.isNotEmpty) {
        final codePoints = segment.runes.toList(growable: false);
        int i = 0;
        while (i < codePoints.length) {
          // One token: a maximal run of whitespace or non-whitespace.
          final tokenIsWhitespace = _isWhitespaceCodePoint(codePoints[i]);
          tokenChars.clear();
          tokenAdvances.clear();
          tokenGaps.clear();
          while (i < codePoints.length &&
              _isWhitespaceCodePoint(codePoints[i]) == tokenIsWhitespace) {
            tokenChars.add(_charString(codePoints[i]));
            i++;
          }

          // Measure once into the scratch buffers; appending reuses them.
          double tokenWidth = 0.0;
          for (int t = 0; t < tokenChars.length; t++) {
            final adv = tokenIsWhitespace
                ? whitespaceAdvance(tokenChars[t])
                : advance(tokenChars[t]);
            tokenAdvances.add(adv);
            tokenWidth += adv;
            if (t < tokenChars.length - 1) {
              final gap = spacing + kern(tokenChars[t], tokenChars[t + 1]);
              tokenGaps.add(gap);
              tokenWidth += gap;
            }
          }

          if (maxWidth != null && lineCharCount > 0 && !tokenIsWhitespace) {
            final joinGap = spacing + kern(lastChar!, tokenChars.first);
            if (penX + joinGap + tokenWidth > maxWidth) flush();
          }
          if (maxWidth != null && tokenIsWhitespace && lineCharCount == 0) {
            continue;
          }

          if (lineCharCount > 0) {
            penX += spacing + kern(lastChar!, tokenChars.first);
          }
          for (int t = 0; t < tokenChars.length; t++) {
            if (!tokenIsWhitespace) {
              glyphs.add(tokenChars[t]);
              offsets.add(penX);
              spacingIndices?.add(lineCharCount + t);
            }
            penX += tokenAdvances[t];
            if (t < tokenChars.length - 1) penX += tokenGaps[t];
          }
          lineCharCount += tokenChars.length;
          lastChar = tokenChars.last;
        }
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
  }) {
    final key = (a, b, fontFamily, fontSize, fontWeight, fontStyle);

    final cached = _kernCache[key];
    if (cached != null) return cached;

    // Measure the pair as a single string
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.fill;

    final painter = TextPainter(
      text: TextSpan(
        text: '$a$b',
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          foreground: paint,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final pairWidth = painter.width;
    painter.dispose();

    // Get individual widths from the character cache
    final aWidth = getOrCreate(
      text: a,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      textLeading: null,
      align: TextAlign.left,
      paintingStyle: 0,
      strokeWidth: 0.0,
    ).width;

    final bWidth = getOrCreate(
      text: b,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      textLeading: null,
      align: TextAlign.left,
      paintingStyle: 0,
      strokeWidth: 0.0,
    ).width;

    final offset = pairWidth - aWidth - bWidth;
    _kernCache[key] = offset;

    return offset;
  }

  void clear() {
    for (final ct in _cache.values) {
      ct.dispose();
    }
    _cache.clear();
    _cacheBytes = 0;
    _kernCache.clear();
    _widthCache.clear();
    _lineHeightCache.clear();
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
