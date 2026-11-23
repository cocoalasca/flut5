import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flut5/text/flut5_text_cache.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';
import 'flut5_text_dynamic_batch_render_item.dart';

class TextDynamicRenderItem({
  required final String text,
  required final double x,
  required final double y,
  final double? maxWidth,
  final double? maxHeight,
  required final String fontFamily,
  required final double fontSize,
  required final FontWeight fontWeight,
  required final FontStyle fontStyle,
  required final TextAlign textAlign,
  required final double? textLeading,
  final double? letterSpacing,
  final Paint? fillPaint,
  final Paint? strokePaint,

  /// When non-null, the shader is built against the full text block bounds at
  /// draw time rather than using the pre-baked shader in [fillPaint].
  final Gradient? fillGradient,

  /// When non-null, the shader is built against the full text block bounds at
  /// draw time rather than using the pre-baked shader in [strokePaint].
  final Gradient? strokeGradient,

  /// Drop shadow drawn beneath the text, or `null` for none.
  final Flut5ShadowSpec? shadow,

  /// Active variable-font axes for rasterization, or `null` when default.
  final List<FontVariation>? fontVariations,

  /// Canonical cache-key string for [fontVariations] (`''` when unused).
  final String fontVariationKey = '',
}) extends Flut5RenderItem {
  /// GPU tint paints for the stroke and fill passes, rebuilt only when the
  /// source paint changes — see [_GlyphTint].
  static final _strokeTint = _GlyphTint();
  static final _fillTint = _GlyphTint();

  /// Untinted blit paint used inside a gradient layer — white glyph pixels
  /// land on the offscreen as-is to act as the srcIn mask. `filterQuality`
  /// is stamped from [Flut5TextCache.textBlitQuality] in [execute].
  static final Paint _maskPaint = Paint();

  /// Gradient overlay paint. Its `shader` and `blendMode` are set per draw.
  static final Paint _gradientOverlayPaint = Paint();

  /// Layer paint used for `saveLayer` in the gradient path. Carries the
  /// user's blend/maskFilter/imageFilter so they behave identically to the
  /// solid-color path.
  static final Paint _layerPaint = Paint();

  /// Bounded shader cache — avoids recreating gradient shaders when multiple
  /// gradient text items draw each frame with stable bounds.
  static const int _shaderCacheCap = 64;
  static final Map<(Gradient, Rect), ui.Shader> _shaderCache = {};

  static ui.Shader _shaderFor(Gradient gradient, Rect bounds) {
    final key = (gradient, bounds);
    final cached = _shaderCache[key];
    if (cached != null) return cached;
    if (_shaderCache.length >= _shaderCacheCap) _shaderCache.clear();
    return _shaderCache[key] = gradient.createShader(bounds);
  }

  static bool _canAtlasPaint(Paint paint) =>
      paint.blendMode == ui.BlendMode.srcOver &&
      paint.shader == null &&
      paint.maskFilter == null &&
      paint.colorFilter == null &&
      paint.imageFilter == null;

  // With no wrapping, spacing changes offsets and alignment but never line
  // breaks. Reuse the zero-spacing layout and keep the exact animated value
  // in composition. Wrapped text retains the spacing-dependent layout path.
  double get _compositionSpacing => maxWidth == null ? letterSpacing ?? 0 : 0;

  double _lineWidth(Flut5TextLine line) =>
      line.widthWithSpacing(_compositionSpacing);

  Rect _lineInkBounds(
    Flut5TextCache cache,
    Flut5TextLine line,
    double lineHeight,
    int paintingStyle,
    double strokeWidth,
  ) {
    double left = 0.0;
    final lineWidth = _lineWidth(line);
    final spacing = _compositionSpacing;
    double right = lineWidth;
    var hasInk = false;

    for (int i = 0; i < line.glyphs.length; i++) {
      final cached = cache.getOrCreate(
        text: line.glyphs[i],
        fontFamily: fontFamily,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        textLeading: null,
        align: TextAlign.left,
        paintingStyle: paintingStyle,
        strokeWidth: strokeWidth,
        fontVariations: fontVariations,
        fontVariationKey: fontVariationKey,
      );
      final glyphLeft = line.offsetWithSpacing(i, spacing) - cached.leftPad;
      final glyphRight = glyphLeft + cached.drawWidth;
      if (!hasInk) {
        left = glyphLeft < 0.0 ? glyphLeft : 0.0;
        right = glyphRight > lineWidth ? glyphRight : lineWidth;
        hasInk = true;
      } else {
        if (glyphLeft < left) left = glyphLeft;
        if (glyphRight > right) right = glyphRight;
      }
    }

    return Rect.fromLTWH(left, 0, right - left, lineHeight);
  }

  double _alignedX(double originalX, double lineWidth) {
    if (textAlign == TextAlign.center) return originalX - lineWidth / 2;
    if (textAlign == TextAlign.right || textAlign == TextAlign.end) {
      return originalX - lineWidth;
    }
    return originalX;
  }

  /// Approximate text block bounds used for scroll-mode container sizing.
  /// Avoids glyph measurement: width/height are estimated from the character
  /// count and [fontSize] (or the explicit [maxWidth]/[maxHeight]). Memoized —
  /// items are immutable once queued. See [Flut5RenderItem.bounds].
  @override
  late final Rect? bounds = _computeBounds();

  Rect _computeBounds() {
    final lines = text.split('\n');
    int longest = 0;
    for (final line in lines) {
      if (line.length > longest) longest = line.length;
    }
    final width = maxWidth ?? (longest * fontSize * 0.55);
    final height = maxHeight ?? (lines.length * fontSize * 1.3);
    return Rect.fromLTWH(_alignedX(x, width), y, width, height);
  }

  /// Blits one laid-out line: resolves the line's glyphs from the cache and
  /// emits a single `Canvas.drawRawAtlas` when painting with a plain colour or
  /// gradient mask, falling back to `drawImageRect` for filters, shadows,
  /// oversized glyphs, or mid-line eviction.
  void _drawGlyphs(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5TextLine line,
    double startX,
    double y,
    Paint? paint,
    int paintingStyle,
    double strokeWidth, {
    Flut5ShadowSpec? shadow,
    Paint? sourcePaint,
    bool isMask = false,
  }) {
    final spacing = _compositionSpacing;
    final glyphCount = line.glyphs.length;
    if (glyphCount == 0) return;

    if (shadow != null) {
      final generation = cache.textureGeneration;
      final isSoft = shadow.blur > 0 || shadow.spread > 0;
      final fetched = <Flut5CachedText>[];
      final bakedShadows = isSoft ? <Flut5ShadowRaster>[] : null;
      for (int i = 0; i < glyphCount; i++) {
        final cached = cache.getOrCreate(
          text: line.glyphs[i],
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          textLeading: null,
          align: TextAlign.left,
          paintingStyle: paintingStyle,
          strokeWidth: strokeWidth,
          fontVariations: fontVariations,
          fontVariationKey: fontVariationKey,
        );
        fetched.add(cached);
        if (bakedShadows != null) {
          bakedShadows.add(shadow.resolveBakedShadow(cached)!);
        }
      }
      if (generation == cache.textureGeneration) {
        Flut5GlyphAtlasBlitter.drawShadowLine(
          canvas,
          cache,
          line,
          fetched,
          bakedShadows,
          startX,
          y,
          spacing,
          shadow,
          cache.textBlitQuality,
        );
      } else {
        // Eviction happened mid-line (very small cache budget) — re-fetch and
        // paint glyph by glyph safely.
        for (int i = 0; i < glyphCount; i++) {
          final cached = cache.getOrCreate(
            text: line.glyphs[i],
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontStyle: fontStyle,
            textLeading: null,
            align: TextAlign.left,
            paintingStyle: paintingStyle,
            strokeWidth: strokeWidth,
            fontVariations: fontVariations,
            fontVariationKey: fontVariationKey,
          );
          final dst = Rect.fromLTWH(
            startX + line.offsetWithSpacing(i, spacing) - cached.leftPad,
            y,
            cached.blitWidth,
            cached.blitHeight,
          );
          shadow.paintText(canvas, cached, dst);
        }
      }
      return;
    }

    final useAtlas =
        isMask || (sourcePaint != null && _canAtlasPaint(sourcePaint));

    final kept = cache.resolvedGlyphs(line, paintingStyle, strokeWidth);
    if (kept != null) {
      if (useAtlas) {
        if (isMask) {
          Flut5GlyphAtlasBlitter.drawResolvedMaskLine(
            canvas,
            cache,
            line,
            kept,
            startX,
            y,
            spacing,
            paint!,
          );
        } else {
          Flut5GlyphAtlasBlitter.drawResolvedLine(
            canvas,
            cache,
            line,
            kept,
            startX,
            y,
            spacing,
            paint!,
            sourcePaint!.color,
            cache.textBlitQuality,
          );
        }
        return;
      }
      for (int i = 0; i < glyphCount; i++) {
        final cached = kept[i];
        canvas.drawImageRect(
          cached.image,
          cached.srcRect,
          Rect.fromLTWH(
            startX + line.offsetWithSpacing(i, spacing) - cached.leftPad,
            y,
            cached.blitWidth,
            cached.blitHeight,
          ),
          paint!,
        );
      }
      return;
    }

    final generation = cache.textureGeneration;
    final fetched = <Flut5CachedText>[];
    for (int i = 0; i < glyphCount; i++) {
      final cached = cache.getOrCreate(
        text: line.glyphs[i],
        fontFamily: fontFamily,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        textLeading: null,
        align: TextAlign.left,
        paintingStyle: paintingStyle,
        strokeWidth: strokeWidth,
        fontVariations: fontVariations,
        fontVariationKey: fontVariationKey,
      );
      fetched.add(cached);
      if (!useAtlas) {
        // At the raster's own pixel size, so no texel is resampled.
        final dst = Rect.fromLTWH(
          startX + line.offsetWithSpacing(i, spacing) - cached.leftPad,
          y,
          cached.blitWidth,
          cached.blitHeight,
        );
        canvas.drawImageRect(cached.image, cached.srcRect, dst, paint!);
      }
    }
    final intact = generation == cache.textureGeneration;
    if (intact) {
      cache.rememberGlyphs(
        line,
        paintingStyle,
        strokeWidth,
        fetched,
        generation,
      );
    }
    if (useAtlas) {
      if (intact) {
        if (isMask) {
          Flut5GlyphAtlasBlitter.drawResolvedMaskLine(
            canvas,
            cache,
            line,
            fetched,
            startX,
            y,
            spacing,
            paint!,
          );
        } else {
          Flut5GlyphAtlasBlitter.drawResolvedLine(
            canvas,
            cache,
            line,
            fetched,
            startX,
            y,
            spacing,
            paint!,
            sourcePaint!.color,
            cache.textBlitQuality,
          );
        }
      } else {
        // Cache evicted mid-line — re-fetch each glyph safely and blit via
        // the same drawRawAtlas path for bit-exact parity with packed runs.
        final quality = cache.textBlitQuality;
        final tint = isMask ? null : sourcePaint!.color;
        for (int i = 0; i < glyphCount; i++) {
          final cached = cache.getOrCreate(
            text: line.glyphs[i],
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontStyle: fontStyle,
            textLeading: null,
            align: TextAlign.left,
            paintingStyle: paintingStyle,
            strokeWidth: strokeWidth,
            fontVariations: fontVariations,
            fontVariationKey: fontVariationKey,
          );
          Flut5GlyphAtlasBlitter.drawSingleGlyph(
            canvas,
            cache,
            cached,
            startX + line.offsetWithSpacing(i, spacing) - cached.leftPad,
            y,
            quality,
            tintColor: tint,
          );
        }
      }
    }
  }

  @override
  void execute(Canvas canvas) {
    if (text.isEmpty) return;

    final cache = Flut5TextCache.instance;
    final FilterQuality glyphQuality = cache.textBlitQuality;
    _maskPaint.filterQuality = glyphQuality;

    // Line height: composition-time value.
    // If textLeading is set, compute from fontSize * multiplier.
    // Otherwise, use the font's default line height from the metrics cache —
    // a texture-cache fetch here would consume a texture slot per font size.
    final double lineHeight;
    if (textLeading != null) {
      lineHeight = fontSize * textLeading!;
    } else {
      lineHeight = cache.measureLineHeight(
        fontFamily: fontFamily,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        fontVariations: fontVariations,
        fontVariationKey: fontVariationKey,
      );
    }

    // Unwrapped layouts exclude animated spacing from the cache key.
    // Wrapped layouts still bake it in because it determines line breaks.
    final lines = cache
        .getOrCreateLayout(
          text: text,
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          letterSpacing: maxWidth == null ? 0.0 : letterSpacing ?? 0.0,
          maxWidth: maxWidth,
          fontVariations: fontVariations,
          fontVariationKey: fontVariationKey,
        )
        .lines;

    if (lines.isEmpty) return;

    // When auto-bounds gradients are active, compute a size-only rect so the
    // cache key is position-independent. gradientOriginX tracks where that
    // (0,0) local space sits on the canvas for the translate below.
    Rect? gradientBounds;
    double gradientOriginX = 0;
    // Keep only measurements, never texture references: drawing may evict
    // glyph images under a small cache budget. These lists live for one draw
    // and are allocated only when auto-bounds gradients need a first pass.
    final fillInkBounds = fillGradient == null
        ? null
        : List<Rect?>.filled(lines.length, null);
    final strokeInkBounds = strokeGradient == null
        ? null
        : List<Rect?>.filled(lines.length, null);
    if (fillGradient != null || strokeGradient != null) {
      Rect? visualBounds;
      for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
        final line = lines[lineIndex];
        if (!line.hasChars) continue;
        final lineStartX = _alignedX(x, _lineWidth(line));
        Rect? localBounds;
        if (fillInkBounds != null) {
          final ink = _lineInkBounds(cache, line, lineHeight, 0, 0);
          fillInkBounds[lineIndex] = ink;
          localBounds = ink;
        }
        if (strokeInkBounds != null && strokePaint != null) {
          final ink = _lineInkBounds(
            cache,
            line,
            lineHeight,
            1,
            strokePaint!.strokeWidth,
          );
          strokeInkBounds[lineIndex] = ink;
          localBounds = localBounds == null
              ? ink
              : localBounds.expandToInclude(ink);
        }
        final lineBounds =
            (localBounds ?? Rect.fromLTWH(0, 0, _lineWidth(line), lineHeight))
                .shift(Offset(lineStartX, 0));
        visualBounds = visualBounds == null
            ? lineBounds
            : visualBounds.expandToInclude(lineBounds);
      }
      if (visualBounds != null) {
        gradientOriginX = visualBounds.left;
        gradientBounds = Rect.fromLTWH(
          0,
          0,
          visualBounds.width,
          lineHeight * lines.length,
        );
      }
    }

    // ── Phase 2: Render ────────────────────────────────────────────────

    final bool clip = maxHeight != null;
    if (clip) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(x, y, maxWidth ?? double.infinity, maxHeight!),
      );
    }

    double cursorY = y;

    // ── Shadow pass (under every line) ──
    // All line shadows draw before any glyphs, so a lower line's blurred
    // shadow can never land on top of the previous line's text — matching the
    // static TextRenderItem (whole block shadowed beneath everything) and CSS.
    // Re-blits each line's glyphs recolored to the shadow color and blurred,
    // reusing the raster the text itself draws (fill when filled, else
    // stroke), so no new cache entry is created — a blurred shadow bakes its
    // silhouette onto that entry — and an outline-only text casts an outline
    // shadow.
    final shadowSpec = shadow;
    if (shadowSpec != null) {
      final bool shadowStroke = fillPaint == null && strokePaint != null;
      for (final line in lines) {
        if (maxHeight != null && (cursorY - y + lineHeight) > maxHeight!) break;
        if (line.glyphs.isEmpty) {
          cursorY += lineHeight;
          continue;
        }
        _drawGlyphs(
          canvas,
          cache,
          line,
          _alignedX(x, _lineWidth(line)),
          cursorY,
          null,
          shadowStroke ? 1 : 0,
          shadowStroke ? strokePaint!.strokeWidth : 0.0,
          shadow: shadowSpec,
        );
        cursorY += lineHeight;
      }
      cursorY = y;
    }

    // Collapse single-pass gradient text across all visible lines into ONE
    // saveLayer instead of one saveLayer per line. When both stroke and fill
    // are active we keep per-line stroke-under-fill ordering when lines could
    // vertically overlap, preserving exact overlap fidelity.
    final bool strokeIsGradient =
        strokePaint != null &&
        (strokePaint!.shader != null || strokeGradient != null);
    final bool fillIsGradient =
        fillPaint != null &&
        (fillPaint!.shader != null || fillGradient != null);

    if ((strokeIsGradient && fillPaint == null) ||
        (fillIsGradient && strokePaint == null)) {
      final bool isStroke = strokeIsGradient;
      final Paint activePaint = isStroke ? strokePaint! : fillPaint!;
      final Gradient? activeGradient = isStroke ? strokeGradient : fillGradient;
      final List<Rect?>? precomputedInk = isStroke
          ? strokeInkBounds
          : fillInkBounds;
      final int style = isStroke ? 1 : 0;
      final double sw = isStroke ? strokePaint!.strokeWidth : 0.0;

      Rect? unionBounds;
      double cy = y;
      for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
        final line = lines[lineIndex];
        if (maxHeight != null && (cy - y + lineHeight) > maxHeight!) break;
        if (line.glyphs.isNotEmpty) {
          final lineStartX = _alignedX(x, _lineWidth(line));
          final localInk =
              precomputedInk?[lineIndex] ??
              _lineInkBounds(cache, line, lineHeight, style, sw);
          final lb = localInk.shift(Offset(lineStartX, cy));
          unionBounds = unionBounds == null
              ? lb
              : unionBounds.expandToInclude(lb);
        }
        cy += lineHeight;
      }

      if (unionBounds != null) {
        _layerPaint
          ..colorFilter = null
          ..blendMode = activePaint.blendMode
          ..maskFilter = activePaint.maskFilter
          ..imageFilter = activePaint.imageFilter;
        canvas.saveLayer(unionBounds, _layerPaint);

        cy = y;
        for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
          final line = lines[lineIndex];
          if (maxHeight != null && (cy - y + lineHeight) > maxHeight!) break;
          if (line.glyphs.isNotEmpty) {
            final lineStartX = _alignedX(x, _lineWidth(line));
            _drawGlyphs(
              canvas,
              cache,
              line,
              lineStartX,
              cy,
              _maskPaint,
              style,
              sw,
              isMask: true,
            );
          }
          cy += lineHeight;
        }

        if (activeGradient != null) {
          _gradientOverlayPaint
            ..shader = _shaderFor(activeGradient, gradientBounds!)
            ..blendMode = ui.BlendMode.srcIn;
          canvas.save();
          canvas.translate(gradientOriginX, y);
          canvas.drawRect(
            Rect.fromLTWH(
              unionBounds.left - gradientOriginX,
              unionBounds.top - y,
              unionBounds.width,
              unionBounds.height,
            ),
            _gradientOverlayPaint,
          );
          canvas.restore();
        } else {
          _gradientOverlayPaint
            ..shader = activePaint.shader
            ..blendMode = ui.BlendMode.srcIn;
          canvas.drawRect(unionBounds, _gradientOverlayPaint);
        }
        canvas.restore();
      }
      if (clip) canvas.restore();
      return;
    }

    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      final line = lines[lineIndex];
      if (maxHeight != null && (cursorY - y + lineHeight) > maxHeight!) break;
      if (line.glyphs.isEmpty) {
        // Empty or whitespace-only line — nothing to blit, just advance.
        cursorY += lineHeight;
        continue;
      }

      final double lineStartX = _alignedX(x, _lineWidth(line));

      // ── Stroke pass (bottom) ──
      if (strokePaint != null) {
        if (strokePaint!.shader != null || strokeGradient != null) {
          final localInkBounds =
              strokeInkBounds?[lineIndex] ??
              _lineInkBounds(
                cache,
                line,
                lineHeight,
                1,
                strokePaint!.strokeWidth,
              );
          final lineBounds = localInkBounds.shift(Offset(lineStartX, cursorY));
          _layerPaint
            ..colorFilter = null
            ..blendMode = strokePaint!.blendMode
            ..maskFilter = strokePaint!.maskFilter
            ..imageFilter = strokePaint!.imageFilter;
          canvas.saveLayer(lineBounds, _layerPaint);

          _drawGlyphs(
            canvas,
            cache,
            line,
            lineStartX,
            cursorY,
            _maskPaint,
            1,
            strokePaint!.strokeWidth,
            isMask: true,
          );

          if (strokeGradient != null) {
            _gradientOverlayPaint
              ..shader = _shaderFor(strokeGradient!, gradientBounds!)
              ..blendMode = ui.BlendMode.srcIn;
            canvas.save();
            canvas.translate(gradientOriginX, y);
            canvas.drawRect(
              Rect.fromLTWH(
                lineBounds.left - gradientOriginX,
                cursorY - y,
                lineBounds.width,
                lineBounds.height,
              ),
              _gradientOverlayPaint,
            );
            canvas.restore();
          } else {
            _gradientOverlayPaint
              ..shader = strokePaint!.shader
              ..blendMode = ui.BlendMode.srcIn;
            canvas.drawRect(lineBounds, _gradientOverlayPaint);
          }
          canvas.restore();
        } else {
          _drawGlyphs(
            canvas,
            cache,
            line,
            lineStartX,
            cursorY,
            _strokeTint.of(strokePaint!, glyphQuality),
            1,
            strokePaint!.strokeWidth,
            sourcePaint: strokePaint,
          );
        }
      }

      // ── Fill pass (top) ──
      if (fillPaint != null) {
        if (fillPaint!.shader != null || fillGradient != null) {
          final localInkBounds =
              fillInkBounds?[lineIndex] ??
              _lineInkBounds(cache, line, lineHeight, 0, 0.0);
          final lineBounds = localInkBounds.shift(Offset(lineStartX, cursorY));
          _layerPaint
            ..colorFilter = null
            ..blendMode = fillPaint!.blendMode
            ..maskFilter = fillPaint!.maskFilter
            ..imageFilter = fillPaint!.imageFilter;
          canvas.saveLayer(lineBounds, _layerPaint);

          _drawGlyphs(
            canvas,
            cache,
            line,
            lineStartX,
            cursorY,
            _maskPaint,
            0,
            0.0,
            isMask: true,
          );

          if (fillGradient != null) {
            _gradientOverlayPaint
              ..shader = _shaderFor(fillGradient!, gradientBounds!)
              ..blendMode = ui.BlendMode.srcIn;
            canvas.save();
            canvas.translate(gradientOriginX, y);
            canvas.drawRect(
              Rect.fromLTWH(
                lineBounds.left - gradientOriginX,
                cursorY - y,
                lineBounds.width,
                lineBounds.height,
              ),
              _gradientOverlayPaint,
            );
            canvas.restore();
          } else {
            _gradientOverlayPaint
              ..shader = fillPaint!.shader
              ..blendMode = ui.BlendMode.srcIn;
            canvas.drawRect(lineBounds, _gradientOverlayPaint);
          }
          canvas.restore();
        } else {
          _drawGlyphs(
            canvas,
            cache,
            line,
            lineStartX,
            cursorY,
            _fillTint.of(fillPaint!, glyphQuality),
            0,
            0.0,
            sourcePaint: fillPaint,
          );
        }
      }

      cursorY += lineHeight;
    }

    if (clip) {
      canvas.restore();
    }
  }
}

/// The tint paint for one text pass: [of]'s source colour applied to the
/// white glyph raster, with its blend mode and filters. Rebuilt only when
/// the source paint or the glyph quality changes — queued paints are
/// immutable snapshots, so identity stands for content, and the colour
/// filter is a native object not worth rebuilding on every draw.
class _GlyphTint() {
  Paint? _source;
  FilterQuality? _quality;
  final Paint _paint = Paint();

  Paint of(Paint source, FilterQuality quality) {
    if (identical(source, _source) && quality == _quality) return _paint;
    _source = source;
    _quality = quality;
    return _paint
      ..colorFilter = ColorFilter.mode(source.color, ui.BlendMode.srcIn)
      ..blendMode = source.blendMode
      ..maskFilter = source.maskFilter
      ..imageFilter = source.imageFilter
      ..filterQuality = quality;
  }
}
