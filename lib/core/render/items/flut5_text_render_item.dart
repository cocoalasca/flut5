import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flut5/text/flut5_text_cache.dart';
import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

class TextRenderItem extends Flut5RenderItem {
  /// Shared paint for GPU tinting — reconfigured in place each draw to avoid
  /// per-frame allocations. Its `filterQuality` is stamped from
  /// [Flut5TextCache.textBlitQuality] in [execute].
  static final Paint _tintPaint = Paint();

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

  // One-entry shader caches — avoids calling createShader every frame when
  // the gradient and text bounds haven't changed. Keyed by object identity
  // (same pattern as Flut5Fill / Flut5Stroke).
  static Gradient? _cachedFillGradient;
  static Rect? _cachedFillBounds;
  static ui.Shader? _cachedFillShader;

  static Gradient? _cachedStrokeGradient;
  static Rect? _cachedStrokeBounds;
  static ui.Shader? _cachedStrokeShader;
  final String text;
  final double x;
  final double y;
  final double? maxWidth;
  final double? maxHeight;

  final String fontFamily;
  final double fontSize;
  final FontWeight fontWeight;
  final FontStyle fontStyle;
  final TextAlign textAlign;
  final double? textLeading;
  final double? letterSpacing;

  final Paint? fillPaint;
  final Paint? strokePaint;

  /// When non-null, the shader is built against the text block's actual
  /// bounds at draw time rather than using the pre-baked shader in [fillPaint].
  final Gradient? fillGradient;

  /// When non-null, the shader is built against the text block's actual
  /// bounds at draw time rather than using the pre-baked shader in [strokePaint].
  final Gradient? strokeGradient;

  /// Drop shadow drawn beneath the text, or `null` for none.
  final Flut5ShadowSpec? shadow;

  TextRenderItem({
    required this.text,
    required this.x,
    required this.y,
    this.maxWidth,
    this.maxHeight,
    required this.fontFamily,
    required this.fontSize,
    required this.fontWeight,
    required this.fontStyle,
    required this.textAlign,
    required this.textLeading,
    this.letterSpacing,
    this.fillPaint,
    this.strokePaint,
    this.fillGradient,
    this.strokeGradient,
    this.shadow,
  });

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
    _tintPaint.filterQuality = glyphQuality;
    _maskPaint.filterQuality = glyphQuality;
    double? painterWidth;
    double dx = x;

    // Shadow Pass (under everything): reuse the cached white glyph image the
    // text itself draws — the FILL silhouette when filled, otherwise the STROKE
    // raster — recolored to the shadow color and blurred, shifted by the offset.
    // Reusing the text's own raster means NO new cache entry, and an outline-
    // only text casts an outline shadow rather than a solid blob.
    final shadowSpec = shadow;
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
      );
      final sdx = _alignedX(x, cachedShadow.width);
      final sdst = Rect.fromLTWH(
        sdx - cachedShadow.leftPad,
        y,
        cachedShadow.drawWidth,
        cachedShadow.height,
      );
      canvas.drawImageRect(
        cachedShadow.image,
        cachedShadow.srcRect,
        sdst.shift(shadowSpec.offset),
        shadowSpec.textTintPaint,
      );
    }

    // Stroke Pass (Bottom)
    if (strokePaint != null) {
      final cachedStroke = cache.getOrCreate(
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
      );

      painterWidth = cachedStroke.width;
      dx = _alignedX(x, painterWidth);

      final dst = Rect.fromLTWH(
        dx - cachedStroke.leftPad,
        y,
        cachedStroke.drawWidth,
        cachedStroke.height,
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
          dst,
          _maskPaint,
        );
        if (strokeGradient != null) {
          final sizeRect = Rect.fromLTWH(0, 0, dst.width, dst.height);
          if (!identical(_cachedStrokeGradient, strokeGradient) ||
              _cachedStrokeBounds != sizeRect) {
            _cachedStrokeShader = strokeGradient!.createShader(sizeRect);
            _cachedStrokeGradient = strokeGradient;
            _cachedStrokeBounds = sizeRect;
          }
          _gradientOverlayPaint
            ..shader = _cachedStrokeShader
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
        _tintPaint
          ..colorFilter = ColorFilter.mode(
            strokePaint!.color,
            ui.BlendMode.srcIn,
          )
          ..blendMode = strokePaint!.blendMode
          ..maskFilter = strokePaint!.maskFilter
          ..imageFilter = strokePaint!.imageFilter;
        canvas.drawImageRect(
          cachedStroke.image,
          cachedStroke.srcRect,
          dst,
          _tintPaint,
        );
      }
    }

    // Fill Pass (Top)
    if (fillPaint != null) {
      final cachedFill = cache.getOrCreate(
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
          dst,
          _maskPaint,
        );
        if (fillGradient != null) {
          final sizeRect = Rect.fromLTWH(0, 0, dst.width, dst.height);
          if (!identical(_cachedFillGradient, fillGradient) ||
              _cachedFillBounds != sizeRect) {
            _cachedFillShader = fillGradient!.createShader(sizeRect);
            _cachedFillGradient = fillGradient;
            _cachedFillBounds = sizeRect;
          }
          _gradientOverlayPaint
            ..shader = _cachedFillShader
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
        _tintPaint
          ..colorFilter = ColorFilter.mode(fillPaint!.color, ui.BlendMode.srcIn)
          ..blendMode = fillPaint!.blendMode
          ..maskFilter = fillPaint!.maskFilter
          ..imageFilter = fillPaint!.imageFilter;
        canvas.drawImageRect(
          cachedFill.image,
          cachedFill.srcRect,
          dst,
          _tintPaint,
        );
      }
    }
  }
}
