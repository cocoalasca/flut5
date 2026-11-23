import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flut5/text/flut5_text_cache.dart';

import '../../flut5_shadow.dart';
import '../flut5_render_item.dart';

/// Shared scratch buffers and `Canvas.drawRawAtlas` emitter for shelf-packed
/// dynamic glyphs.
///
/// Reused synchronously during `execute(canvas)`: Skia and Impeller copy the
/// typed arrays when recording `drawRawAtlas`, so static scratch buffers avoid
/// per-frame allocations once warmed.
class Flut5GlyphAtlasBlitter._() {
  static Float32List _transforms = Float32List(128 * 4);
  static Float32List _rects = Float32List(128 * 4);
  static Int32List _colors = Int32List(128);
  static final Paint _atlasPaint = Paint();
  static final Paint _fallbackPaint = Paint();

  static void _ensureCapacity(int sprites) {
    if (_colors.length >= sprites) return;
    int cap = _colors.length * 2;
    while (cap < sprites) {
      cap *= 2;
    }
    _transforms = Float32List(cap * 4);
    _rects = Float32List(cap * 4);
    _colors = Int32List(cap);
  }

  static final Float32List _singleTransform = Float32List(4);
  static final Float32List _singleRect = Float32List(4);
  static final Int32List _singleColor = Int32List(1);

  /// Draws one glyph directly through `Canvas.drawRawAtlas` against its own
  /// [ui.Image] so oversized or evicted-cache fallbacks match the atlas path
  /// bit-for-bit (identical float32 RSTransform math and blending).
  static void drawSingleGlyph(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5CachedText cached,
    double dstX,
    double dstY,
    FilterQuality quality, {
    Color? tintColor,
  }) {
    cache.ensureGlyphPacked(cached);
    final slot = cached.atlasSlot;
    final ui.Image img;
    if (slot != null && slot.isValid) {
      img = slot.page.image!;
      _singleRect[0] = slot.left;
      _singleRect[1] = slot.top;
      _singleRect[2] = slot.right;
      _singleRect[3] = slot.bottom;
    } else {
      img = cached.image;
      _singleRect[0] = 0.0;
      _singleRect[1] = 0.0;
      _singleRect[2] = cached.image.width.toDouble();
      _singleRect[3] = cached.image.height.toDouble();
    }
    final invDpr = 1.0 / cache.pixelRatio;
    _singleTransform[0] = invDpr;
    _singleTransform[1] = 0.0;
    _singleTransform[2] = dstX;
    _singleTransform[3] = dstY;
    _atlasPaint.filterQuality = quality;
    if (tintColor != null) {
      _singleColor[0] = tintColor.toARGB32();
      canvas.drawRawAtlas(
        img,
        _singleTransform,
        _singleRect,
        _singleColor,
        ui.BlendMode.modulate,
        null,
        _atlasPaint,
      );
    } else {
      canvas.drawRawAtlas(
        img,
        _singleTransform,
        _singleRect,
        null,
        null,
        null,
        _atlasPaint,
      );
    }
  }

  /// Blits one line of already-resolved [rasters] using the shared glyph atlas
  /// when possible, falling back to `Canvas.drawImageRect` for oversized glyphs
  /// or when an eviction occurred mid-draw.
  static void drawResolvedLine(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5TextLine line,
    List<Flut5CachedText> rasters,
    double startX,
    double y,
    double spacing,
    Paint fallbackPaint,
    Color tintColor,
    FilterQuality quality,
  ) {
    final count = rasters.length;
    if (count == 0) return;

    cache.ensureAtlasPacked(rasters);
    _ensureCapacity(count);

    final invDpr = 1.0 / cache.pixelRatio;
    final argb = tintColor.toARGB32();
    _atlasPaint.filterQuality = quality;

    Flut5GlyphAtlasPage? activePage;
    int queued = 0;

    void flushAtlas() {
      if (queued == 0) return;
      final pageImage = activePage?.image;
      if (pageImage != null) {
        canvas.drawRawAtlas(
          pageImage,
          Float32List.sublistView(_transforms, 0, queued * 4),
          Float32List.sublistView(_rects, 0, queued * 4),
          Int32List.sublistView(_colors, 0, queued),
          ui.BlendMode.modulate,
          null,
          _atlasPaint,
        );
      }
      queued = 0;
      activePage = null;
    }

    for (var i = 0; i < count; i++) {
      final cached = rasters[i];
      final dstX = startX + line.offsetWithSpacing(i, spacing) - cached.leftPad;
      final slot = cached.atlasSlot;
      if (slot == null || !slot.isValid) {
        flushAtlas();
        canvas.drawImageRect(
          cached.image,
          cached.srcRect,
          Rect.fromLTWH(dstX, y, cached.blitWidth, cached.blitHeight),
          fallbackPaint,
        );
        continue;
      }
      if (activePage != null && !identical(activePage, slot.page)) {
        flushAtlas();
      }
      activePage = slot.page;
      final o = queued * 4;
      _transforms[o] = invDpr;
      _transforms[o + 1] = 0.0;
      _transforms[o + 2] = dstX;
      _transforms[o + 3] = y;
      _rects[o] = slot.left;
      _rects[o + 1] = slot.top;
      _rects[o + 2] = slot.right;
      _rects[o + 3] = slot.bottom;
      _colors[queued] = argb;
      queued++;
    }
    flushAtlas();
  }

  /// Blits an untinted white glyph mask for a line inside a gradient
  /// `saveLayer` via `Canvas.drawRawAtlas`, avoiding per-glyph `drawImageRect`
  /// calls.
  static void drawResolvedMaskLine(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5TextLine line,
    List<Flut5CachedText> rasters,
    double startX,
    double y,
    double spacing,
    Paint maskPaint,
  ) {
    final count = rasters.length;
    if (count == 0) return;

    cache.ensureAtlasPacked(rasters);
    _ensureCapacity(count);

    final invDpr = 1.0 / cache.pixelRatio;
    _atlasPaint.filterQuality = maskPaint.filterQuality;

    Flut5GlyphAtlasPage? activePage;
    int queued = 0;

    void flushAtlas() {
      if (queued == 0) return;
      final pageImage = activePage?.image;
      if (pageImage != null) {
        canvas.drawRawAtlas(
          pageImage,
          Float32List.sublistView(_transforms, 0, queued * 4),
          Float32List.sublistView(_rects, 0, queued * 4),
          null,
          null,
          null,
          _atlasPaint,
        );
      }
      queued = 0;
      activePage = null;
    }

    for (var i = 0; i < count; i++) {
      final cached = rasters[i];
      final dstX = startX + line.offsetWithSpacing(i, spacing) - cached.leftPad;
      final slot = cached.atlasSlot;
      if (slot == null || !slot.isValid) {
        flushAtlas();
        canvas.drawImageRect(
          cached.image,
          cached.srcRect,
          Rect.fromLTWH(dstX, y, cached.blitWidth, cached.blitHeight),
          maskPaint,
        );
        continue;
      }
      if (activePage != null && !identical(activePage, slot.page)) {
        flushAtlas();
      }
      activePage = slot.page;
      final o = queued * 4;
      _transforms[o] = invDpr;
      _transforms[o + 1] = 0.0;
      _transforms[o + 2] = dstX;
      _transforms[o + 3] = y;
      _rects[o] = slot.left;
      _rects[o + 1] = slot.top;
      _rects[o + 2] = slot.right;
      _rects[o + 3] = slot.bottom;
      queued++;
    }
    flushAtlas();
  }

  /// Blits one line of shadows (hard or baked blur/spread silhouettes) via the
  /// shared glyph atlas in a single `Canvas.drawRawAtlas` per atlas page.
  static void drawShadowLine(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5TextLine line,
    List<Flut5CachedText> rasters,
    List<Flut5ShadowRaster>? bakedShadows,
    double startX,
    double y,
    double spacing,
    Flut5ShadowSpec shadow,
    FilterQuality quality,
  ) {
    final count = rasters.length;
    if (count == 0) return;

    if (bakedShadows == null) {
      cache.ensureAtlasPacked(rasters);
    } else {
      cache.ensureShadowsAtlasPacked(bakedShadows);
    }
    _ensureCapacity(count);

    final invDpr = 1.0 / cache.pixelRatio;
    final argb = shadow.color.toARGB32();
    final offX = shadow.offset.dx;
    final offY = shadow.offset.dy;
    _atlasPaint.filterQuality = quality;

    Flut5GlyphAtlasPage? activePage;
    int queued = 0;

    void flushAtlas() {
      if (queued == 0) return;
      final pageImage = activePage?.image;
      if (pageImage != null) {
        canvas.drawRawAtlas(
          pageImage,
          Float32List.sublistView(_transforms, 0, queued * 4),
          Float32List.sublistView(_rects, 0, queued * 4),
          Int32List.sublistView(_colors, 0, queued),
          ui.BlendMode.modulate,
          null,
          _atlasPaint,
        );
      }
      queued = 0;
      activePage = null;
    }

    for (var i = 0; i < count; i++) {
      final cached = rasters[i];
      final baseX = startX + line.offsetWithSpacing(i, spacing) - cached.leftPad;
      if (bakedShadows == null) {
        final slot = cached.atlasSlot;
        if (slot == null || !slot.isValid) {
          flushAtlas();
          shadow.paintText(
            canvas,
            cached,
            Rect.fromLTWH(baseX, y, cached.blitWidth, cached.blitHeight),
          );
          continue;
        }
        if (activePage != null && !identical(activePage, slot.page)) {
          flushAtlas();
        }
        activePage = slot.page;
        final o = queued * 4;
        _transforms[o] = invDpr;
        _transforms[o + 1] = 0.0;
        _transforms[o + 2] = baseX + offX;
        _transforms[o + 3] = y + offY;
        _rects[o] = slot.left;
        _rects[o + 1] = slot.top;
        _rects[o + 2] = slot.right;
        _rects[o + 3] = slot.bottom;
        _colors[queued] = argb;
        queued++;
      } else {
        final baked = bakedShadows[i];
        final slot = baked.atlasSlot;
        if (slot == null || !slot.isValid) {
          flushAtlas();
          canvas.drawImageRect(
            baked.image,
            baked.srcRect,
            Rect.fromLTWH(
              baseX + offX - baked.pad,
              y + offY - baked.pad,
              baked.size.width,
              baked.size.height,
            ),
            shadow.textTintPaint,
          );
          continue;
        }
        if (activePage != null && !identical(activePage, slot.page)) {
          flushAtlas();
        }
        activePage = slot.page;
        final o = queued * 4;
        _transforms[o] = invDpr;
        _transforms[o + 1] = 0.0;
        _transforms[o + 2] = baseX + offX - baked.pad;
        _transforms[o + 3] = y + offY - baked.pad;
        _rects[o] = slot.left;
        _rects[o + 1] = slot.top;
        _rects[o + 2] = slot.right;
        _rects[o + 3] = slot.bottom;
        _colors[queued] = argb;
        queued++;
      }
    }
    flushAtlas();
  }

  /// Blits an entire batch of plain solid-colour `textDynamic` entries
  /// (potentially spanning different strings, sizes, colours, shadows,
  /// positions, rotations, and uniform scales) in minimal `Canvas.drawRawAtlas`
  /// calls against [Flut5TextCache]'s glyph atlas.
  static void drawBatch(Canvas canvas, List<Flut5TextDynamicEntry> entries) {
    var hasAnyShadow = false;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].shadow != null) {
        hasAnyShadow = true;
        break;
      }
    }
    if (!hasAnyShadow) {
      _drawGlyphRange(canvas, entries, 0, entries.length);
      return;
    }

    // Group consecutive non-overlapping entries so all their shadows draw in
    // one atlas pass followed by all their glyph ink in one atlas pass; flush
    // immediately on overlap to keep exact painter's-algorithm z-order.
    var runStart = 0;
    final runBoxes = <Rect>[];
    for (var i = 0; i < entries.length; i++) {
      final box = entries[i].shadowedBounds();
      var overlaps = false;
      for (var j = 0; j < runBoxes.length; j++) {
        if (box.overlaps(runBoxes[j])) {
          overlaps = true;
          break;
        }
      }
      if (overlaps) {
        _drawShadowRange(canvas, entries, runStart, i);
        _drawGlyphRange(canvas, entries, runStart, i);
        runStart = i;
        runBoxes.clear();
      }
      runBoxes.add(box);
    }
    if (runStart < entries.length) {
      _drawShadowRange(canvas, entries, runStart, entries.length);
      _drawGlyphRange(canvas, entries, runStart, entries.length);
    }
  }

  static void _drawShadowRange(
    Canvas canvas,
    List<Flut5TextDynamicEntry> entries,
    int startIdx,
    int endIdx,
  ) {
    final cache = Flut5TextCache.instance;
    final quality = cache.textBlitQuality;
    _atlasPaint.filterQuality = quality;

    Flut5GlyphAtlasPage? activePage;
    int queued = 0;

    void flushAtlas() {
      if (queued == 0) return;
      final pageImage = activePage?.image;
      if (pageImage != null) {
        canvas.drawRawAtlas(
          pageImage,
          Float32List.sublistView(_transforms, 0, queued * 4),
          Float32List.sublistView(_rects, 0, queued * 4),
          Int32List.sublistView(_colors, 0, queued),
          ui.BlendMode.modulate,
          null,
          _atlasPaint,
        );
      }
      queued = 0;
      activePage = null;
    }

    for (var e = startIdx; e < endIdx; e++) {
      final entry = entries[e];
      final shadow = entry.shadow;
      if (shadow == null || entry.text.isEmpty) continue;

      final double lineHeight = entry.textLeading != null
          ? entry.fontSize * entry.textLeading!
          : cache.measureLineHeight(
              fontFamily: entry.fontFamily,
              fontSize: entry.fontSize,
              fontWeight: entry.fontWeight,
              fontStyle: entry.fontStyle,
              fontVariations: entry.fontVariations,
              fontVariationKey: entry.fontVariationKey,
            );

      final lines = cache
          .getOrCreateLayout(
            text: entry.text,
            fontFamily: entry.fontFamily,
            fontSize: entry.fontSize,
            fontWeight: entry.fontWeight,
            fontStyle: entry.fontStyle,
            letterSpacing: entry.maxWidth == null
                ? 0.0
                : entry.letterSpacing ?? 0.0,
            maxWidth: entry.maxWidth,
            fontVariations: entry.fontVariations,
            fontVariationKey: entry.fontVariationKey,
          )
          .lines;

      if (lines.isEmpty) continue;

      final double spacing = entry.maxWidth == null
          ? entry.letterSpacing ?? 0.0
          : 0.0;
      final double fa = entry.foldA;
      final double fb = entry.foldB;
      final double fdx = entry.foldDx;
      final double fdy = entry.foldDy;
      final bool hasLinear = fa != 1.0 || fb != 0.0;
      final int argb = shadow.color.toARGB32();
      final double offX = shadow.offset.dx;
      final double offY = shadow.offset.dy;
      final bool isSoft = shadow.blur > 0 || shadow.spread > 0;
      final int style = entry.paintingStyle;
      final double sw = entry.strokeWidth;

      double cursorY = entry.y;
      for (var li = 0; li < lines.length; li++) {
        final line = lines[li];
        final glyphCount = line.glyphs.length;
        if (glyphCount == 0) {
          cursorY += lineHeight;
          continue;
        }

        final lineWidth = line.widthWithSpacing(spacing);
        double startX = entry.x;
        if (entry.textAlign == TextAlign.center) {
          startX -= lineWidth / 2;
        } else if (entry.textAlign == TextAlign.right ||
            entry.textAlign == TextAlign.end) {
          startX -= lineWidth;
        }

        final gen = cache.textureGeneration;
        final rasters = <Flut5CachedText>[];
        final bakedList = isSoft ? <Flut5ShadowRaster>[] : null;
        for (var gi = 0; gi < glyphCount; gi++) {
          final g = cache.getOrCreate(
            text: line.glyphs[gi],
            fontFamily: entry.fontFamily,
            fontSize: entry.fontSize,
            fontWeight: entry.fontWeight,
            fontStyle: entry.fontStyle,
            textLeading: null,
            align: TextAlign.left,
            paintingStyle: style,
            strokeWidth: sw,
            fontVariations: entry.fontVariations,
            fontVariationKey: entry.fontVariationKey,
          );
          rasters.add(g);
          if (bakedList != null) {
            bakedList.add(shadow.resolveBakedShadow(g)!);
          }
        }

        if (gen != cache.textureGeneration) {
          // Cache evicted mid-line — re-fetch glyph by glyph safely.
          flushAtlas();
          if (hasLinear) {
            canvas.save();
            canvas.transform(
              Float64List.fromList([
                fa,
                fb,
                0,
                0,
                -fb,
                fa,
                0,
                0,
                0,
                0,
                1,
                0,
                fdx,
                fdy,
                0,
                1,
              ]),
            );
          }
          for (var gi = 0; gi < glyphCount; gi++) {
            final g = cache.getOrCreate(
              text: line.glyphs[gi],
              fontFamily: entry.fontFamily,
              fontSize: entry.fontSize,
              fontWeight: entry.fontWeight,
              fontStyle: entry.fontStyle,
              textLeading: null,
              align: TextAlign.left,
              paintingStyle: style,
              strokeWidth: sw,
              fontVariations: entry.fontVariations,
              fontVariationKey: entry.fontVariationKey,
            );
            final gx = startX + line.offsetWithSpacing(gi, spacing) - g.leftPad;
            shadow.paintText(
              canvas,
              g,
              Rect.fromLTWH(
                hasLinear ? gx : gx + fdx,
                hasLinear ? cursorY : cursorY + fdy,
                g.blitWidth,
                g.blitHeight,
              ),
            );
          }
          if (hasLinear) canvas.restore();
          cursorY += lineHeight;
          continue;
        }

        if (bakedList == null) {
          cache.ensureAtlasPacked(rasters);
        } else {
          cache.ensureShadowsAtlasPacked(bakedList);
        }
        final invDpr = 1.0 / cache.pixelRatio;
        final scos = fa * invDpr;
        final ssin = fb * invDpr;
        _ensureCapacity(queued + glyphCount);

        for (var gi = 0; gi < glyphCount; gi++) {
          final g = rasters[gi];
          final baseX =
              startX + line.offsetWithSpacing(gi, spacing) - g.leftPad;
          final baked = bakedList?[gi];
          final slot = baked == null ? g.atlasSlot : baked.atlasSlot;
          final pad = baked?.pad ?? 0.0;
          final sx = baseX + offX - pad;
          final sy = cursorY + offY - pad;
          if (slot == null || !slot.isValid) {
            flushAtlas();
            if (hasLinear) {
              canvas.save();
              canvas.transform(
                Float64List.fromList([
                  fa,
                  fb,
                  0,
                  0,
                  -fb,
                  fa,
                  0,
                  0,
                  0,
                  0,
                  1,
                  0,
                  fdx,
                  fdy,
                  0,
                  1,
                ]),
              );
              shadow.paintText(
                canvas,
                g,
                Rect.fromLTWH(baseX, cursorY, g.blitWidth, g.blitHeight),
              );
              canvas.restore();
            } else {
              shadow.paintText(
                canvas,
                g,
                Rect.fromLTWH(
                  baseX + fdx,
                  cursorY + fdy,
                  g.blitWidth,
                  g.blitHeight,
                ),
              );
            }
            continue;
          }
          if (activePage != null && !identical(activePage, slot.page)) {
            flushAtlas();
            _ensureCapacity(queued + (glyphCount - gi));
          }
          activePage = slot.page;
          final o = queued * 4;
          _transforms[o] = scos;
          _transforms[o + 1] = ssin;
          if (hasLinear) {
            _transforms[o + 2] = fa * sx - fb * sy + fdx;
            _transforms[o + 3] = fb * sx + fa * sy + fdy;
          } else {
            _transforms[o + 2] = sx + fdx;
            _transforms[o + 3] = sy + fdy;
          }
          _rects[o] = slot.left;
          _rects[o + 1] = slot.top;
          _rects[o + 2] = slot.right;
          _rects[o + 3] = slot.bottom;
          _colors[queued] = argb;
          queued++;
        }

        cursorY += lineHeight;
      }
    }
    flushAtlas();
  }

  static void _drawGlyphRange(
    Canvas canvas,
    List<Flut5TextDynamicEntry> entries,
    int startIdx,
    int endIdx,
  ) {
    final cache = Flut5TextCache.instance;
    final quality = cache.textBlitQuality;
    _atlasPaint.filterQuality = quality;

    Flut5GlyphAtlasPage? activePage;
    int queued = 0;

    void flushAtlas() {
      if (queued == 0) return;
      final pageImage = activePage?.image;
      if (pageImage != null) {
        canvas.drawRawAtlas(
          pageImage,
          Float32List.sublistView(_transforms, 0, queued * 4),
          Float32List.sublistView(_rects, 0, queued * 4),
          Int32List.sublistView(_colors, 0, queued),
          ui.BlendMode.modulate,
          null,
          _atlasPaint,
        );
      }
      queued = 0;
      activePage = null;
    }

    for (var e = startIdx; e < endIdx; e++) {
      final entry = entries[e];
      if (entry.text.isEmpty) continue;

      final double lineHeight = entry.textLeading != null
          ? entry.fontSize * entry.textLeading!
          : cache.measureLineHeight(
              fontFamily: entry.fontFamily,
              fontSize: entry.fontSize,
              fontWeight: entry.fontWeight,
              fontStyle: entry.fontStyle,
              fontVariations: entry.fontVariations,
              fontVariationKey: entry.fontVariationKey,
            );

      final lines = cache
          .getOrCreateLayout(
            text: entry.text,
            fontFamily: entry.fontFamily,
            fontSize: entry.fontSize,
            fontWeight: entry.fontWeight,
            fontStyle: entry.fontStyle,
            letterSpacing: entry.maxWidth == null
                ? 0.0
                : entry.letterSpacing ?? 0.0,
            maxWidth: entry.maxWidth,
            fontVariations: entry.fontVariations,
            fontVariationKey: entry.fontVariationKey,
          )
          .lines;

      if (lines.isEmpty) continue;

      final double spacing = entry.maxWidth == null
          ? entry.letterSpacing ?? 0.0
          : 0.0;
      final double fa = entry.foldA;
      final double fb = entry.foldB;
      final double fdx = entry.foldDx;
      final double fdy = entry.foldDy;
      final bool hasLinear = fa != 1.0 || fb != 0.0;
      final int argb = entry.color.toARGB32();
      final int style = entry.paintingStyle;
      final double sw = entry.strokeWidth;

      double cursorY = entry.y;
      for (var li = 0; li < lines.length; li++) {
        final line = lines[li];
        final glyphCount = line.glyphs.length;
        if (glyphCount == 0) {
          cursorY += lineHeight;
          continue;
        }

        final lineWidth = line.widthWithSpacing(spacing);
        double startX = entry.x;
        if (entry.textAlign == TextAlign.center) {
          startX -= lineWidth / 2;
        } else if (entry.textAlign == TextAlign.right ||
            entry.textAlign == TextAlign.end) {
          startX -= lineWidth;
        }

        final kept = cache.resolvedGlyphs(line, style, sw);
        List<Flut5CachedText>? rasters = kept;
        if (rasters == null) {
          final gen = cache.textureGeneration;
          final fetched = <Flut5CachedText>[];
          for (var gi = 0; gi < glyphCount; gi++) {
            fetched.add(
              cache.getOrCreate(
                text: line.glyphs[gi],
                fontFamily: entry.fontFamily,
                fontSize: entry.fontSize,
                fontWeight: entry.fontWeight,
                fontStyle: entry.fontStyle,
                textLeading: null,
                align: TextAlign.left,
                paintingStyle: style,
                strokeWidth: sw,
                fontVariations: entry.fontVariations,
                fontVariationKey: entry.fontVariationKey,
              ),
            );
          }
          if (gen == cache.textureGeneration) {
            cache.rememberGlyphs(line, style, sw, fetched, gen);
            rasters = fetched;
          } else {
            // Cache evicted mid-line (very small budget) — re-fetch and draw
            // each glyph directly to avoid touching evicted handles.
            flushAtlas();
            _fallbackPaint
              ..colorFilter = ColorFilter.mode(entry.color, ui.BlendMode.srcIn)
              ..filterQuality = quality;
            if (hasLinear) {
              canvas.save();
              canvas.transform(
                Float64List.fromList([
                  fa,
                  fb,
                  0,
                  0,
                  -fb,
                  fa,
                  0,
                  0,
                  0,
                  0,
                  1,
                  0,
                  fdx,
                  fdy,
                  0,
                  1,
                ]),
              );
            }
            for (var gi = 0; gi < glyphCount; gi++) {
              final g = cache.getOrCreate(
                text: line.glyphs[gi],
                fontFamily: entry.fontFamily,
                fontSize: entry.fontSize,
                fontWeight: entry.fontWeight,
                fontStyle: entry.fontStyle,
                textLeading: null,
                align: TextAlign.left,
                paintingStyle: style,
                strokeWidth: sw,
                fontVariations: entry.fontVariations,
                fontVariationKey: entry.fontVariationKey,
              );
              final gx =
                  startX + line.offsetWithSpacing(gi, spacing) - g.leftPad;
              canvas.drawImageRect(
                g.image,
                g.srcRect,
                Rect.fromLTWH(
                  hasLinear ? gx : gx + fdx,
                  hasLinear ? cursorY : cursorY + fdy,
                  g.blitWidth,
                  g.blitHeight,
                ),
                _fallbackPaint,
              );
            }
            if (hasLinear) canvas.restore();
            cursorY += lineHeight;
            continue;
          }
        }

        cache.ensureAtlasPacked(rasters);
        final invDpr = 1.0 / cache.pixelRatio;
        final scos = fa * invDpr;
        final ssin = fb * invDpr;
        _ensureCapacity(queued + glyphCount);

        for (var gi = 0; gi < glyphCount; gi++) {
          final g = rasters[gi];
          final localX =
              startX + line.offsetWithSpacing(gi, spacing) - g.leftPad;
          final slot = g.atlasSlot;
          if (slot == null || !slot.isValid) {
            flushAtlas();
            _fallbackPaint
              ..colorFilter = ColorFilter.mode(entry.color, ui.BlendMode.srcIn)
              ..filterQuality = quality;
            if (hasLinear) {
              canvas.save();
              canvas.transform(
                Float64List.fromList([
                  fa,
                  fb,
                  0,
                  0,
                  -fb,
                  fa,
                  0,
                  0,
                  0,
                  0,
                  1,
                  0,
                  fdx,
                  fdy,
                  0,
                  1,
                ]),
              );
              canvas.drawImageRect(
                g.image,
                g.srcRect,
                Rect.fromLTWH(localX, cursorY, g.blitWidth, g.blitHeight),
                _fallbackPaint,
              );
              canvas.restore();
            } else {
              canvas.drawImageRect(
                g.image,
                g.srcRect,
                Rect.fromLTWH(
                  localX + fdx,
                  cursorY + fdy,
                  g.blitWidth,
                  g.blitHeight,
                ),
                _fallbackPaint,
              );
            }
            continue;
          }
          if (activePage != null && !identical(activePage, slot.page)) {
            flushAtlas();
            _ensureCapacity(queued + (glyphCount - gi));
          }
          activePage = slot.page;
          final o = queued * 4;
          _transforms[o] = scos;
          _transforms[o + 1] = ssin;
          if (hasLinear) {
            _transforms[o + 2] = fa * localX - fb * cursorY + fdx;
            _transforms[o + 3] = fb * localX + fa * cursorY + fdy;
          } else {
            _transforms[o + 2] = localX + fdx;
            _transforms[o + 3] = cursorY + fdy;
          }
          _rects[o] = slot.left;
          _rects[o + 1] = slot.top;
          _rects[o + 2] = slot.right;
          _rects[o + 3] = slot.bottom;
          _colors[queued] = argb;
          queued++;
        }

        cursorY += lineHeight;
      }
    }
    flushAtlas();
  }
}

/// One queued entry in a [TextDynamicBatchRenderItem].
class Flut5TextDynamicEntry({
  required final String text,
  required final double x,
  required final double y,
  final double? maxWidth,
  required final String fontFamily,
  required final double fontSize,
  required final FontWeight fontWeight,
  required final FontStyle fontStyle,
  required final TextAlign textAlign,
  required final double? textLeading,
  final double? letterSpacing,
  required final Color color,
  required final int paintingStyle,
  required final double strokeWidth,
  required final double foldA,
  required final double foldB,
  required final double foldDx,
  required final double foldDy,
  final Flut5ShadowSpec? shadow,
  final List<FontVariation>? fontVariations,
  final String fontVariationKey = '',
}) {
  Rect approximateBounds() {
    final lines = text.split('\n');
    int longest = 0;
    for (final line in lines) {
      if (line.length > longest) longest = line.length;
    }
    final width = maxWidth ?? (longest * fontSize * 0.55);
    final height = lines.length * fontSize * 1.3;
    double left = x;
    if (textAlign == TextAlign.center) {
      left -= width / 2;
    } else if (textAlign == TextAlign.right || textAlign == TextAlign.end) {
      left -= width;
    }
    if (foldA == 1.0 && foldB == 0.0) {
      return Rect.fromLTWH(left + foldDx, y + foldDy, width, height);
    }
    final r = left + width;
    final b = y + height;
    final x0 = foldA * left - foldB * y + foldDx;
    final y0 = foldB * left + foldA * y + foldDy;
    final x1 = foldA * r - foldB * y + foldDx;
    final y1 = foldB * r + foldA * y + foldDy;
    final x2 = foldA * r - foldB * b + foldDx;
    final y2 = foldB * r + foldA * b + foldDy;
    final x3 = foldA * left - foldB * b + foldDx;
    final y3 = foldB * left + foldA * b + foldDy;
    return Rect.fromLTRB(
      math.min(math.min(x0, x1), math.min(x2, x3)),
      math.min(math.min(y0, y1), math.min(y2, y3)),
      math.max(math.max(x0, x1), math.max(x2, x3)),
      math.max(math.max(y0, y1), math.max(y2, y3)),
    );
  }

  /// Conservative bounds including any shadow halo, used for z-order overlap
  /// checks when batching shadowed dynamic text entries.
  Rect shadowedBounds() {
    final base = approximateBounds();
    final s = shadow;
    if (s == null) return base;
    final scale = math.sqrt(foldA * foldA + foldB * foldB);
    final pad = (s.spread + s.blur * 1.5 + 4.0) * scale;
    final sx = foldA * s.offset.dx - foldB * s.offset.dy;
    final sy = foldB * s.offset.dx + foldA * s.offset.dy;
    return base.expandToInclude(base.shift(Offset(sx, sy)).inflate(pad));
  }
}

/// Coalesces consecutive plain `textDynamic` calls — across strings, colours,
/// sizes, translations, rotations, and uniform scales — into batched
/// `Canvas.drawRawAtlas` calls against [Flut5TextCache]'s glyph atlas.
class TextDynamicBatchRenderItem(final List<Flut5TextDynamicEntry> entries)
    extends Flut5RenderItem {
  @override
  late final Rect? bounds = _computeBounds();

  Rect? _computeBounds() {
    Rect? acc;
    for (var i = 0; i < entries.length; i++) {
      final b = entries[i].approximateBounds();
      acc = acc == null ? b : acc.expandToInclude(b);
    }
    return acc;
  }

  @override
  void execute(Canvas canvas) {
    Flut5GlyphAtlasBlitter.drawBatch(canvas, entries);
  }
}
