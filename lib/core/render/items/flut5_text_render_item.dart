import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flut5/text/flut5_text_cache.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

class TextRenderItem({
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

  /// When non-null, the shader is built against the text block's actual
  /// bounds at draw time rather than using the pre-baked shader in [fillPaint].
  final Gradient? fillGradient,

  /// When non-null, the shader is built against the text block's actual
  /// bounds at draw time rather than using the pre-baked shader in [strokePaint].
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

  // Bounded shader cache — avoids calling createShader every frame when
  // multiple gradient labels draw with stable bounds.
  static const int _shaderCacheCap = 64;
  static final Map<(Gradient, Rect), ui.Shader> _shaderCache = {};

  static ui.Shader _shaderFor(Gradient gradient, Rect bounds) {
    final key = (gradient, bounds);
    final cached = _shaderCache[key];
    if (cached != null) return cached;
    if (_shaderCache.length >= _shaderCacheCap) _shaderCache.clear();
    return _shaderCache[key] = gradient.createShader(bounds);
  }
  double _alignedX(double originalX, double width) {
    if (textAlign == TextAlign.center) return originalX - width / 2;
    if (textAlign == TextAlign.right || textAlign == TextAlign.end) {
      return originalX - width;
    }
    return originalX;
  }

  /// Approximate text block bounds used for scroll-mode container sizing.
  /// Avoids the cost of glyph measurement: width/height are estimated from the
  /// character count and [fontSize] (or the explicit [maxWidth]/[maxHeight]),
  /// which is close enough to bound scrolling. Memoized — items are immutable
  /// once queued. See [Flut5RenderItem.bounds].
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

  @override
  void execute(Canvas canvas) {
    final cache = Flut5TextCache.instance;
    final FilterQuality glyphQuality = cache.textBlitQuality;
    _maskPaint.filterQuality = glyphQuality;
    double? painterWidth;
    double dx = x;

    // Shadow Pass (under everything): reuse the cached white glyph image the
    // text itself draws — the FILL silhouette when filled, otherwise the STROKE
    // raster — recolored to the shadow color and blurred, shifted by the offset.
    // Reusing the text's own raster means NO new cache entry (a blurred shadow
    // bakes its silhouette onto that entry), and an outline-only text casts an
    // outline shadow rather than a solid blob. Keep the lookup so the fill or
    // stroke pass below reuses it without a second cache hash lookup.
    final shadowSpec = shadow;
    Flut5CachedText? shadowCachedFill;
    Flut5CachedText? shadowCachedStroke;
    if (shadowSpec != null) {
      final bool shadowStroke = fillPaint == null && strokePaint != null;
      final cachedShadow = cache.getOrCreate(
        text: text,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        fontFamily: fontFamily,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        textLeading: textLeading,
        letterSpacing: letterSpacing,
        align: textAlign,
        paintingStyle: shadowStroke ? 1 : 0,
        strokeWidth: shadowStroke ? strokePaint!.strokeWidth : 0.0,
        fontVariations: fontVariations,
        fontVariationKey: fontVariationKey,
      );
      if (shadowStroke) {
        shadowCachedStroke = cachedShadow;
      } else {
        shadowCachedFill = cachedShadow;
      }
      final sdx = _alignedX(x, cachedShadow.width);
      shadowSpec.paintText(
        canvas,
        cachedShadow,
        // At the raster's own pixel size, so no texel is resampled.
        Rect.fromLTWH(
          sdx - cachedShadow.leftPad,
          y,
          cachedShadow.blitWidth,
          cachedShadow.blitHeight,
        ),
      );
    }

    // Stroke Pass (Bottom)
    if (strokePaint != null) {
      final cachedStroke =
          shadowCachedStroke ??
          cache.getOrCreate(
            text: text,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontStyle: fontStyle,
            textLeading: textLeading,
            letterSpacing: letterSpacing,
            align: textAlign,
            paintingStyle: 1, // Stroke
            strokeWidth: strokePaint!.strokeWidth,
            fontVariations: fontVariations,
            fontVariationKey: fontVariationKey,
          );

      painterWidth = cachedStroke.width;
      dx = _alignedX(x, painterWidth);

      final dst = Rect.fromLTWH(
        dx - cachedStroke.leftPad,
        y,
        cachedStroke.drawWidth,
        cachedStroke.height,
      );
      // The raster is drawn at its own pixel size, so no texel is
      // resampled: a fraction of a pixel past [dst], which still bounds the
      // layer and the gradient.
      final blit = Rect.fromLTWH(
        dst.left,
        dst.top,
        cachedStroke.blitWidth,
        cachedStroke.blitHeight,
      );

      if (strokePaint!.shader != null || strokeGradient != null) {
        _layerPaint
          ..colorFilter = null
          ..blendMode = strokePaint!.blendMode
          ..maskFilter = strokePaint!.maskFilter
          ..imageFilter = strokePaint!.imageFilter;
        canvas.saveLayer(dst, _layerPaint);
        canvas.drawImageRect(
          cachedStroke.image,
          cachedStroke.srcRect,
          blit,
          _maskPaint,
        );
        if (strokeGradient != null) {
          final sizeRect = Rect.fromLTWH(0, 0, dst.width, dst.height);
          _gradientOverlayPaint
            ..shader = _shaderFor(strokeGradient!, sizeRect)
            ..blendMode = ui.BlendMode.srcIn;
          canvas.save();
          canvas.translate(dst.left, dst.top);
          canvas.drawRect(sizeRect, _gradientOverlayPaint);
          canvas.restore();
        } else {
          _gradientOverlayPaint
            ..shader = strokePaint!.shader
            ..blendMode = ui.BlendMode.srcIn;
          canvas.drawRect(dst, _gradientOverlayPaint);
        }
        canvas.restore();
      } else {
        canvas.drawImageRect(
          cachedStroke.image,
          cachedStroke.srcRect,
          blit,
          _strokeTint.of(strokePaint!, glyphQuality),
        );
      }
    }

    // Fill Pass (Top)
    if (fillPaint != null) {
      final cachedFill =
          (shadowCachedFill != null && !shadowCachedFill.image.debugDisposed)
          ? shadowCachedFill
          : cache.getOrCreate(
              text: text,
              maxWidth: maxWidth,
              maxHeight: maxHeight,
              fontFamily: fontFamily,
              fontSize: fontSize,
              fontWeight: fontWeight,
              fontStyle: fontStyle,
              textLeading: textLeading,
              letterSpacing: letterSpacing,
              align: textAlign,
              paintingStyle: 0, // Fill
              strokeWidth: 0.0,
              fontVariations: fontVariations,
              fontVariationKey: fontVariationKey,
            );

      if (painterWidth == null) {
        dx = _alignedX(x, cachedFill.width);
      }

      final dst = Rect.fromLTWH(
        dx - cachedFill.leftPad,
        y,
        cachedFill.drawWidth,
        cachedFill.height,
      );
      // The raster is drawn at its own pixel size, so no texel is
      // resampled: a fraction of a pixel past [dst], which still bounds the
      // layer and the gradient.
      final blit = Rect.fromLTWH(
        dst.left,
        dst.top,
        cachedFill.blitWidth,
        cachedFill.blitHeight,
      );

      if (fillPaint!.shader != null || fillGradient != null) {
        _layerPaint
          ..colorFilter = null
          ..blendMode = fillPaint!.blendMode
          ..maskFilter = fillPaint!.maskFilter
          ..imageFilter = fillPaint!.imageFilter;
        canvas.saveLayer(dst, _layerPaint);
        canvas.drawImageRect(
          cachedFill.image,
          cachedFill.srcRect,
          blit,
          _maskPaint,
        );
        if (fillGradient != null) {
          final sizeRect = Rect.fromLTWH(0, 0, dst.width, dst.height);
          _gradientOverlayPaint
            ..shader = _shaderFor(fillGradient!, sizeRect)
            ..blendMode = ui.BlendMode.srcIn;
          canvas.save();
          canvas.translate(dst.left, dst.top);
          canvas.drawRect(sizeRect, _gradientOverlayPaint);
          canvas.restore();
        } else {
          _gradientOverlayPaint
            ..shader = fillPaint!.shader
            ..blendMode = ui.BlendMode.srcIn;
          canvas.drawRect(dst, _gradientOverlayPaint);
        }
        canvas.restore();
      } else {
        canvas.drawImageRect(
          cachedFill.image,
          cachedFill.srcRect,
          blit,
          _fillTint.of(fillPaint!, glyphQuality),
        );
      }
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
