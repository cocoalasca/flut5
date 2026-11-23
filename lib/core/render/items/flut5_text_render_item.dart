import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flut5/text/flut5_text_cache.dart';
import 'package:flut5/text/flut5_text_shaping.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';
import 'flut5_text_dynamic_batch_render_item.dart';

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

  ({double width, double height}) get _block =>
      Flut5TextCache.instance.measureBlock(
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
        fontVariations: fontVariations,
        fontVariationKey: fontVariationKey,
      );

  /// The laid-out text block, as sizes a scroll-mode container. Memoized —
  /// items are immutable once queued. See [Flut5RenderItem.bounds].
  @override
  late final Rect? bounds = _computeBounds();

  Rect _computeBounds() {
    final block = _block;
    return Rect.fromLTWH(_alignedX(x, block.width), y, block.width, block.height);
  }

  /// Everything this text can paint: its block grown by what glyphs reach
  /// past it, its stroke, and its shadow. A `maxHeight` clips the raster,
  /// but a stroke's or shadow's reach past the sides still counts.
  @override
  late final Rect? inkBounds = flut5TextInkBox(
    bounds!,
    fontSize,
    strokePaint?.strokeWidth ?? 0,
    shadow,
  );

  Flut5CachedText _raster(
    Flut5TextCache cache,
    int paintingStyle,
    double strokeWidth,
    int phase,
    double rasterScale,
  ) => cache.getOrCreate(
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
    paintingStyle: paintingStyle,
    strokeWidth: strokeWidth,
    fontVariations: fontVariations,
    fontVariationKey: fontVariationKey,
    subpixelPhase: phase,
    rasterScale: rasterScale,
  );

  late final Flut5GlyphFont _font = Flut5GlyphFont(
    family: fontFamily,
    size: fontSize,
    weight: fontWeight,
    style: fontStyle,
    variations: fontVariations,
    variationKey: fontVariationKey,
  );

  static bool _isPlainPaint(Paint paint) =>
      paint.blendMode == ui.BlendMode.srcOver &&
      paint.shader == null &&
      paint.maskFilter == null &&
      paint.colorFilter == null &&
      paint.imageFilter == null;

  bool get _mayDrawNatively =>
      maxHeight == null &&
      shadow == null &&
      fillGradient == null &&
      strokeGradient == null;

  bool get _hasPlainPaints =>
      (fillPaint == null || _isPlainPaint(fillPaint!)) &&
      (strokePaint == null || _isPlainPaint(strokePaint!));

  void _paintNatively(Canvas canvas) {
    final limit = maxWidth ?? double.infinity;
    final stroke = strokePaint;
    if (stroke != null) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontStyle: fontStyle,
            fontVariations: fontVariations,
            foreground: stroke,
            height: textLeading,
            letterSpacing: letterSpacing,
          ),
        ),
        textAlign: textAlign,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: limit);
      painter.paint(canvas, Offset(_alignedX(x, maxWidth ?? painter.width), y));
      painter.dispose();
    }
    final fill = fillPaint;
    if (fill != null) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontStyle: fontStyle,
            fontVariations: fontVariations,
            foreground: fill,
            height: textLeading,
            letterSpacing: letterSpacing,
          ),
        ),
        textAlign: textAlign,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: limit);
      painter.paint(canvas, Offset(_alignedX(x, maxWidth ?? painter.width), y));
      painter.dispose();
    }
  }

  @override
  bool get keepsCanvasTransform => true;

  @override
  void execute(Canvas canvas) {
    final cache = Flut5TextCache.instance;
    final FilterQuality glyphQuality = cache.textBlitQuality;
    _maskPaint.filterQuality = glyphQuality;

    final grid = Flut5GlyphGrid.of(canvas, cache.pixelRatio);
    final requestedScale = grid.canvasScale;
    final rasterScale = cache.rasterScaleFor(fontSize, requestedScale);

    if (_mayDrawNatively && _hasPlainPaints) {
      final fillGoesNative =
          fillPaint != null &&
          cache.drawsNatively(_font, 0, 0, rasterScale, requestedScale);
      final strokeGoesNative =
          strokePaint != null &&
          cache.drawsNatively(
            _font,
            1,
            strokePaint!.strokeWidth,
            rasterScale,
            requestedScale,
          );
      if (fillGoesNative || strokeGoesNative || flut5HasColorEmoji(text)) {
        _paintNatively(canvas);
        return;
      }
    }

    final aligned = grid.isAligned(1, 0);
    final boxX = _alignedX(x, _block.width);

    // Where the text's pen goes: on the device's pixel grid when the
    // transform allows it, so the raster isn't resampled.
    var penX = boxX, penY = y, phase = 0;
    if (aligned) {
      penX = grid.snapX(boxX);
      phase = grid.phase;
      penY = grid.snapY(y);
    }

    // Shadow Pass (under everything): reuse the cached white glyph image the
    // text itself draws — the FILL silhouette when filled, otherwise the STROKE
    // raster — recolored to the shadow color and blurred, shifted by the offset.
    // Reusing the text's own raster means NO new cache entry (a blurred shadow
    // bakes its silhouette onto that entry), and an outline-only text casts an
    // outline shadow rather than a solid blob.
    final shadowSpec = shadow;
    if (shadowSpec != null) {
      final bool shadowStroke = fillPaint == null && strokePaint != null;
      final isSoft = shadowSpec.blur > 0 || shadowSpec.spread > 0;
      // A hard shadow is a crisp copy and lands on the grid like the text.
      // A soft one has no edge to keep and uses a single raster.
      var shadowPenX = boxX, shadowPenY = y, shadowPhase = 0;
      if (aligned && !isSoft) {
        shadowPenX = grid.snapX(boxX + shadowSpec.offset.dx) - shadowSpec.offset.dx;
        shadowPhase = grid.phase;
        shadowPenY = grid.snapY(y + shadowSpec.offset.dy) - shadowSpec.offset.dy;
      }
      final cachedShadow = _raster(
        cache,
        shadowStroke ? 1 : 0,
        shadowStroke ? strokePaint!.strokeWidth : 0.0,
        shadowPhase,
        rasterScale,
      );
      shadowSpec.paintText(
        canvas,
        cachedShadow,
        Rect.fromLTWH(
          shadowPenX - cachedShadow.leftPad,
          shadowPenY,
          cachedShadow.blitWidth,
          cachedShadow.blitHeight,
        ),
      );
    }

    // Stroke Pass (Bottom)
    if (strokePaint != null) {
      _drawPass(
        canvas,
        _raster(cache, 1, strokePaint!.strokeWidth, phase, rasterScale),
        strokePaint!,
        strokeGradient,
        _strokeTint,
        glyphQuality,
        boxX,
        penX,
        penY,
      );
    }

    // Fill Pass (Top)
    if (fillPaint != null) {
      _drawPass(
        canvas,
        _raster(cache, 0, 0.0, phase, rasterScale),
        fillPaint!,
        fillGradient,
        _fillTint,
        glyphQuality,
        boxX,
        penX,
        penY,
      );
    }
  }

  /// Blits [cached] with its pen at ([penX], [penY]), tinted by [paint] or,
  /// through a layer, masked onto its shader or [gradient].
  void _drawPass(
    Canvas canvas,
    Flut5CachedText cached,
    Paint paint,
    Gradient? gradient,
    _GlyphTint tint,
    FilterQuality glyphQuality,
    double boxX,
    double penX,
    double penY,
  ) {
    // The raster is drawn at its own pixel size, so no texel is resampled.
    final blit = Rect.fromLTWH(
      penX - cached.rasterLeft,
      penY - cached.rasterTop,
      cached.blitWidth,
      cached.blitHeight,
    );
    if (paint.shader == null && gradient == null) {
      canvas.drawImageRect(
        cached.image,
        cached.srcRect,
        blit,
        tint.of(paint, glyphQuality),
      );
      return;
    }
    // The gradient spans the text's box; the layer covers the ink too.
    final box = Rect.fromLTWH(
      boxX - cached.leftPad,
      y,
      cached.drawWidth,
      cached.height,
    );
    final layer = box.expandToInclude(blit);
    _layerPaint
      ..colorFilter = null
      ..blendMode = paint.blendMode
      ..maskFilter = paint.maskFilter
      ..imageFilter = paint.imageFilter;
    canvas.saveLayer(layer, _layerPaint);
    canvas.drawImageRect(cached.image, cached.srcRect, blit, _maskPaint);
    if (gradient != null) {
      final sizeRect = Rect.fromLTWH(0, 0, box.width, box.height);
      _gradientOverlayPaint
        ..shader = _shaderFor(gradient, sizeRect)
        ..blendMode = ui.BlendMode.srcIn;
      canvas.save();
      canvas.translate(box.left, box.top);
      canvas.drawRect(
        layer.shift(Offset(-box.left, -box.top)),
        _gradientOverlayPaint,
      );
      canvas.restore();
    } else {
      _gradientOverlayPaint
        ..shader = paint.shader
        ..blendMode = ui.BlendMode.srcIn;
      canvas.drawRect(layer, _gradientOverlayPaint);
    }
    canvas.restore();
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
