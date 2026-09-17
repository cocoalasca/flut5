import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flut5/text/flut5_text_cache.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

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
}) extends Flut5RenderItem {
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

  static Gradient? _cachedFillGradient;
  static Rect? _cachedFillBounds;
  static ui.Shader? _cachedFillShader;

  static Gradient? _cachedStrokeGradient;
  static Rect? _cachedStrokeBounds;
  static ui.Shader? _cachedStrokeShader;

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

  /// Blits one laid-out line: a flat loop over the line's drawable glyphs
  /// with pre-baked offsets — one cache fetch per glyph, no measurement.
  void _drawGlyphs(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5TextLine line,
    double startX,
    double y,
    Paint paint,
    int paintingStyle,
    double strokeWidth,
  ) {
    final spacing = _compositionSpacing;
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
      );
      final dst = Rect.fromLTWH(
        startX + line.offsetWithSpacing(i, spacing) - cached.leftPad,
        y,
        cached.drawWidth,
        cached.height,
      );
      canvas.drawImageRect(cached.image, cached.srcRect, dst, paint);
    }
  }

  @override
  void execute(Canvas canvas) {
    if (text.isEmpty) return;

    final cache = Flut5TextCache.instance;
    final FilterQuality glyphQuality = cache.textBlitQuality;
    _tintPaint.filterQuality = glyphQuality;
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
    // stroke), so no new cache entry is created and an outline-only text
    // casts an outline shadow. One save/translate wraps the whole pass.
    final shadowSpec = shadow;
    if (shadowSpec != null) {
      final bool shadowStroke = fillPaint == null && strokePaint != null;
      canvas.save();
      canvas.translate(shadowSpec.offset.dx, shadowSpec.offset.dy);
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
          shadowSpec.textTintPaint,
          shadowStroke ? 1 : 0,
          shadowStroke ? strokePaint!.strokeWidth : 0.0,
        );
        cursorY += lineHeight;
      }
      canvas.restore();
      cursorY = y;
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
          );

          if (strokeGradient != null) {
            if (!identical(_cachedStrokeGradient, strokeGradient) ||
                _cachedStrokeBounds != gradientBounds) {
              _cachedStrokeShader = strokeGradient!.createShader(
                gradientBounds!,
              );
              _cachedStrokeGradient = strokeGradient;
              _cachedStrokeBounds = gradientBounds;
            }
            _gradientOverlayPaint
              ..shader = _cachedStrokeShader
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
          _tintPaint
            ..colorFilter = ColorFilter.mode(
              strokePaint!.color,
              ui.BlendMode.srcIn,
            )
            ..blendMode = strokePaint!.blendMode
            ..maskFilter = strokePaint!.maskFilter
            ..imageFilter = strokePaint!.imageFilter;

          _drawGlyphs(
            canvas,
            cache,
            line,
            lineStartX,
            cursorY,
            _tintPaint,
            1,
            strokePaint!.strokeWidth,
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
          );

          if (fillGradient != null) {
            if (!identical(_cachedFillGradient, fillGradient) ||
                _cachedFillBounds != gradientBounds) {
              _cachedFillShader = fillGradient!.createShader(gradientBounds!);
              _cachedFillGradient = fillGradient;
              _cachedFillBounds = gradientBounds;
            }
            _gradientOverlayPaint
              ..shader = _cachedFillShader
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
          _tintPaint
            ..colorFilter = ColorFilter.mode(
              fillPaint!.color,
              ui.BlendMode.srcIn,
            )
            ..blendMode = fillPaint!.blendMode
            ..maskFilter = fillPaint!.maskFilter
            ..imageFilter = fillPaint!.imageFilter;

          _drawGlyphs(
            canvas,
            cache,
            line,
            lineStartX,
            cursorY,
            _tintPaint,
            0,
            0.0,
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
