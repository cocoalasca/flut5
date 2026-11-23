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

  /// The last paint [_canAtlasPaint] said yes to. Queued paints are immutable
  /// snapshots, so its identity stands for its content.
  static Paint? _lastAtlasPaint;

  static bool _canAtlasPaint(Paint paint) {
    if (identical(paint, _lastAtlasPaint)) return true;
    final canAtlas =
        paint.blendMode == ui.BlendMode.srcOver &&
        paint.shader == null &&
        paint.maskFilter == null &&
        paint.colorFilter == null &&
        paint.imageFilter == null;
    if (canAtlas) _lastAtlasPaint = paint;
    return canAtlas;
  }

  static Paint _maskPaintForGlyphs() => _maskPaint;

  // With no wrapping, spacing changes offsets and alignment but never line
  // breaks. Reuse the zero-spacing layout and keep the exact animated value
  // in composition. Wrapped text retains the spacing-dependent layout path.
  double get _compositionSpacing => maxWidth == null ? letterSpacing ?? 0 : 0;

  double _lineWidth(Flut5TextLine line) =>
      line.widthWithSpacing(_compositionSpacing);

  late final Flut5GlyphFont _font = Flut5GlyphFont(
    family: fontFamily,
    size: fontSize,
    weight: fontWeight,
    style: fontStyle,
    variations: fontVariations,
    variationKey: fontVariationKey,
  );

  Rect _lineInkBounds(
    Flut5TextCache cache,
    Flut5TextLine line,
    double lineHeight,
    int paintingStyle,
    double strokeWidth,
    double rasterScale,
  ) {
    double left = 0.0;
    final lineWidth = _lineWidth(line);
    final spacing = _compositionSpacing;
    double right = lineWidth;
    var hasInk = false;

    for (int i = 0; i < line.glyphs.length; i++) {
      final cached = cache.lineGlyph(
        line,
        i,
        _font,
        paintingStyle: paintingStyle,
        strokeWidth: strokeWidth,
        phase: 0,
        rasterScale: rasterScale,
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

  List<Flut5TextLine> get _layoutLines {
    final cache = Flut5TextCache.instance;
    if (maxWidth != null) {
      return cache
          .getOrCreateLayout(
            text: text,
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontStyle: fontStyle,
            letterSpacing: letterSpacing ?? 0.0,
            maxWidth: maxWidth,
            fontVariations: fontVariations,
            fontVariationKey: fontVariationKey,
          )
          .lines;
    }
    final layout = cache.getOrCreateLayout(
      text: text,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      letterSpacing: 0.0,
      maxWidth: null,
      fontVariations: fontVariations,
      fontVariationKey: fontVariationKey,
      allowLigatures: true,
    );
    if ((letterSpacing ?? 0.0) != 0.0 && layout.hasLigatures) {
      return cache
          .getOrCreateLayout(
            text: text,
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontStyle: fontStyle,
            letterSpacing: 0.0,
            maxWidth: null,
            fontVariations: fontVariations,
            fontVariationKey: fontVariationKey,
            allowLigatures: false,
          )
          .lines;
    }
    return layout.lines;
  }

  double get _lineHeight => textLeading != null
      ? fontSize * textLeading!
      : Flut5TextCache.instance.measureLineHeight(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontVariations: fontVariations,
          fontVariationKey: fontVariationKey,
        );

  /// The laid-out text block, as sizes a scroll-mode container. Memoized —
  /// items are immutable once queued. See [Flut5RenderItem.bounds].
  @override
  late final Rect? bounds = _computeBounds();

  Rect _computeBounds() {
    final lines = _layoutLines;
    var left = double.infinity, right = double.negativeInfinity;
    for (final line in lines) {
      final width = _lineWidth(line);
      final start = _alignedX(x, width);
      if (start < left) left = start;
      if (start + width > right) right = start + width;
    }
    if (left > right) left = right = x;
    final height = maxHeight ?? lines.length * _lineHeight;
    return Rect.fromLTRB(left, y, right, y + height);
  }

  /// Everything this text can paint: its block grown by what glyphs reach
  /// past it, its stroke, and its shadow.
  @override
  late final Rect? inkBounds = flut5TextInkBox(
    bounds!,
    fontSize,
    strokePaint?.strokeWidth ?? 0,
    shadow,
  );

  /// Whether this draw has no shadow, gradient or box to clip it to, as the
  /// platform's text renderer needs, before looking at its paints.
  bool get _mayDrawNatively =>
      maxHeight == null &&
      shadow == null &&
      fillGradient == null &&
      strokeGradient == null;

  /// Whether the paints are solid colours, as the platform's text renderer
  /// needs too.
  bool get _hasPlainPaints =>
      (fillPaint == null || _canAtlasPaint(fillPaint!)) &&
      (strokePaint == null || _canAtlasPaint(strokePaint!));

  /// Draws every line through the platform's text renderer, each line's
  /// stroke beneath its fill, as the cached route layers them.
  void _paintNatively(Canvas canvas) {
    final spacing = _compositionSpacing;
    final strokeForeground = strokePaint == null
        ? null
        : (Paint()
            ..color = strokePaint!.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokePaint!.strokeWidth);
    final fillForeground = fillPaint == null
        ? null
        : (Paint()..color = fillPaint!.color);
    if (maxWidth == null) {
      Flut5GlyphAtlasBlitter.paintUnwrappedNatively(
        canvas,
        text,
        _font,
        foregrounds: [?strokeForeground, ?fillForeground],
        x: x,
        y: y,
        spacing: spacing,
        align: textAlign,
        lineHeight: () => _lineHeight,
      );
      return;
    }
    final lines = _layoutLines;
    final lineHeight = _lineHeight;
    var cursorY = y;
    for (final line in lines) {
      if (line.glyphs.isNotEmpty) {
        final startX = _alignedX(x, _lineWidth(line));
        for (final foreground in [strokeForeground, fillForeground]) {
          if (foreground == null) continue;
          Flut5GlyphAtlasBlitter.paintLineNatively(
            canvas,
            line,
            _font,
            foreground: foreground,
            startX: startX,
            y: cursorY,
            spacing: letterSpacing ?? 0,
          );
        }
      }
      cursorY += lineHeight;
    }
  }

  /// Queues and draws one laid-out line: a plain colour or gradient mask goes
  /// through the glyph atlas, a shadow through its own pass, and paints an
  /// atlas can't apply glyph by glyph with [paint].
  void _drawGlyphs(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5GlyphGrid grid,
    double rasterScale,
    Flut5TextLine line,
    double startX,
    double y,
    Paint Function()? paint,
    int paintingStyle,
    double strokeWidth, {
    Flut5ShadowSpec? shadow,
    Paint? sourcePaint,
    bool isMask = false,
  }) {
    if (line.glyphs.isEmpty) return;
    final spacing = _compositionSpacing;
    if (shadow != null) {
      Flut5GlyphAtlasBlitter.drawShadowLine(
        canvas,
        cache,
        line,
        _font,
        grid,
        shadow: shadow,
        paintingStyle: paintingStyle,
        strokeWidth: strokeWidth,
        rasterScale: rasterScale,
        startX: startX,
        y: y,
        spacing: spacing,
      );
    } else {
      Flut5GlyphAtlasBlitter.drawLine(
        canvas,
        cache,
        line,
        _font,
        grid,
        paintingStyle: paintingStyle,
        strokeWidth: strokeWidth,
        rasterScale: rasterScale,
        startX: startX,
        y: y,
        spacing: spacing,
        spriteColor: isMask ? null : sourcePaint?.color.toARGB32(),
        directPaint: paint!,
        useAtlas:
            isMask || (sourcePaint != null && _canAtlasPaint(sourcePaint)),
      );
    }
    Flut5GlyphAtlasBlitter.flush(canvas);
  }

  @override
  bool get keepsCanvasTransform => true;

  @override
  void execute(Canvas canvas) {
    if (text.isEmpty) return;

    final cache = Flut5TextCache.instance;
    final FilterQuality glyphQuality = cache.textBlitQuality;
    _maskPaint.filterQuality = glyphQuality;

    final grid = Flut5GlyphGrid.of(canvas, cache.pixelRatio);
    final requestedScale = grid.canvasScale;
    final rasterScale = cache.rasterScaleFor(fontSize, requestedScale);
    Flut5GlyphAtlasBlitter.setQuality(glyphQuality);

    // Decided before any layout: text that goes native doesn't need one.
    if (_mayDrawNatively) {
      // Both passes are asked, so each counts as seen this frame.
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
      if ((fillGoesNative || strokeGoesNative) && _hasPlainPaints) {
        _paintNatively(canvas);
        return;
      }
    }

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

    // Unwrapped layouts exclude animated spacing from the cache key (split on
    // ligature-bearing runs when spacing is non-zero). Wrapped layouts still
    // bake spacing in because it determines line breaks.
    final lines = _layoutLines;

    if (lines.isEmpty) return;

    // How far a pass's layer has to reach past the layout box for its ink.
    final layerPad =
        fontSize * Flut5TextCache.verticalInkReach +
        (strokePaint?.strokeWidth ?? 0) * 2 +
        2;

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
          final ink = _lineInkBounds(
            cache,
            line,
            lineHeight,
            0,
            0,
            rasterScale,
          );
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
            rasterScale,
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
          grid,
          rasterScale,
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
              _lineInkBounds(cache, line, lineHeight, style, sw, rasterScale);
          final lb = localInk.shift(Offset(lineStartX, cy));
          unionBounds = unionBounds == null
              ? lb
              : unionBounds.expandToInclude(lb);
        }
        cy += lineHeight;
      }

      if (unionBounds != null) {
        final layerBounds = unionBounds.inflate(layerPad);
        _layerPaint
          ..colorFilter = null
          ..blendMode = activePaint.blendMode
          ..maskFilter = activePaint.maskFilter
          ..imageFilter = activePaint.imageFilter;
        canvas.saveLayer(layerBounds, _layerPaint);

        cy = y;
        for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
          final line = lines[lineIndex];
          if (maxHeight != null && (cy - y + lineHeight) > maxHeight!) break;
          if (line.glyphs.isNotEmpty) {
            final lineStartX = _alignedX(x, _lineWidth(line));
            _drawGlyphs(
              canvas,
              cache,
              grid,
              rasterScale,
              line,
              lineStartX,
              cy,
              _maskPaintForGlyphs,
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
            layerBounds.shift(Offset(-gradientOriginX, -y)),
            _gradientOverlayPaint,
          );
          canvas.restore();
        } else {
          _gradientOverlayPaint
            ..shader = activePaint.shader
            ..blendMode = ui.BlendMode.srcIn;
          canvas.drawRect(layerBounds, _gradientOverlayPaint);
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
                rasterScale,
              );
          final lineBounds = localInkBounds
              .shift(Offset(lineStartX, cursorY))
              .inflate(layerPad);
          _layerPaint
            ..colorFilter = null
            ..blendMode = strokePaint!.blendMode
            ..maskFilter = strokePaint!.maskFilter
            ..imageFilter = strokePaint!.imageFilter;
          canvas.saveLayer(lineBounds, _layerPaint);

          _drawGlyphs(
            canvas,
            cache,
            grid,
            rasterScale,
            line,
            lineStartX,
            cursorY,
            _maskPaintForGlyphs,
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
              lineBounds.shift(Offset(-gradientOriginX, -y)),
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
            grid,
            rasterScale,
            line,
            lineStartX,
            cursorY,
            () => _strokeTint.of(strokePaint!, glyphQuality),
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
              _lineInkBounds(cache, line, lineHeight, 0, 0.0, rasterScale);
          final lineBounds = localInkBounds
              .shift(Offset(lineStartX, cursorY))
              .inflate(layerPad);
          _layerPaint
            ..colorFilter = null
            ..blendMode = fillPaint!.blendMode
            ..maskFilter = fillPaint!.maskFilter
            ..imageFilter = fillPaint!.imageFilter;
          canvas.saveLayer(lineBounds, _layerPaint);

          _drawGlyphs(
            canvas,
            cache,
            grid,
            rasterScale,
            line,
            lineStartX,
            cursorY,
            _maskPaintForGlyphs,
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
              lineBounds.shift(Offset(-gradientOriginX, -y)),
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
            grid,
            rasterScale,
            line,
            lineStartX,
            cursorY,
            () => _fillTint.of(fillPaint!, glyphQuality),
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
