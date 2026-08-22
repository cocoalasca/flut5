import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../text/flut5_text_cache.dart';
import 'render/flut5_render_queue.dart';

/// Immutable descriptor of an active drop shadow.
///
/// Built once per [Flut5Shadow.shadow] / [Flut5Shadow.shadowFill] change, so the
/// same instance is reused — identity-stable — across every shape drawn under it
/// until the shadow changes. That lets the render queue treat a run of shadowed
/// shapes as sharing one shadow without re-comparing fields.
///
/// A shadow is realized as an offset, blurred copy drawn *beneath* each shape.
/// Flutter's `Canvas.drawShadow` is intentionally not used: it is elevation-
/// based and exposes no arbitrary offset / blur radius / spread / color.
class Flut5ShadowSpec {
  Flut5ShadowSpec(this.color, this.offset, this.blur, this.spread);

  /// Shadow color (alpha included).
  final Color color;

  /// Offset of the shadow from the shape, in logical pixels.
  final Offset offset;

  /// Blur radius applied to the silhouette, in CSS `box-shadow` terms.
  /// Converted to a Gaussian sigma via [Shadow.convertRadiusToSigma]
  /// (exactly like Flutter's own [BoxShadow.toPaint]), so the same number
  /// gives the same softness as CSS. `0` keeps a hard edge.
  final double blur;

  /// Outward growth of the silhouette before blurring, in logical pixels.
  /// Shapes approximate it by fattening the outline; text dilates the glyph
  /// raster. `0` disables it.
  final double spread;

  /// CSS blur radius → Gaussian sigma, matching [BoxShadow.toPaint].
  double get _blurSigma => Shadow.convertRadiusToSigma(blur);

  MaskFilter? get _blurFilter =>
      blur > 0 ? MaskFilter.blur(BlurStyle.normal, _blurSigma) : null;

  /// Filled silhouette paint — the shadow color, optionally blurred.
  late final Paint fillPaint = Paint()
    ..color = color
    ..maskFilter = _blurFilter;

  /// Outline paint that grows a filled silhouette by [spread] (a stroke centred
  /// on the edge, so half its width lands outside). `null` when [spread] is `0`.
  late final Paint? spreadPaint = spread > 0
      ? (Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = spread * 2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..maskFilter = _blurFilter)
      : null;

  /// Tint paint for text shadows: recolours the cached white glyph image to
  /// the shadow color, then applies spread and blur — see
  /// [_buildRasterTintPaint]. Sampled at the text cache's blit quality so the
  /// shadow resamples exactly like the glyphs it sits beneath.
  late final Paint textTintPaint = _buildRasterTintPaint(
    Flut5TextCache.instance.textBlitQuality,
  );

  /// Tint paint for image shadows — the same recolour/spread/blur pipeline as
  /// [textTintPaint], sampled at the [FilterQuality.medium] images blit with.
  /// A bitmap's own alpha is the silhouette, so a transparent PNG casts a
  /// shadow shaped like its content rather than a rectangular blob.
  late final Paint imageTintPaint = _buildRasterTintPaint(FilterQuality.medium);

  /// Builds a shadow paint that recolours an existing raster — a glyph
  /// texture or a bitmap — to the shadow color, then applies spread and blur.
  /// Spread is realized as a morphological [ImageFilter.dilate] composed
  /// inside the blur (grow first, soften after — CSS order), so no extra
  /// rasters are generated; when spread is `0` the cheaper [MaskFilter] blur
  /// is used instead.
  Paint _buildRasterTintPaint(FilterQuality quality) {
    final p = Paint()
      ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn)
      ..filterQuality = quality;
    if (spread > 0) {
      final dilate = ImageFilter.dilate(radiusX: spread, radiusY: spread);
      p.imageFilter = blur > 0
          ? ImageFilter.compose(
              outer: ImageFilter.blur(
                sigmaX: _blurSigma,
                sigmaY: _blurSigma,
                tileMode: TileMode.decal,
              ),
              inner: dilate,
            )
          : dilate;
    } else {
      p.maskFilter = _blurFilter;
    }
    return p;
  }

  // One-entry memo for [strokeShadowPaint]. Specs are identity-stable across
  // frames and batching hands the same paint snapshot to a whole run, so the
  // memo removes a Paint allocation per shadowed line/point item per frame.
  Paint? _strokeShadowPaint;
  Paint? _strokeShadowSource;
  double _strokeShadowWidth = -1;

  /// Returns a shadow paint that matches a stroked primitive (line / point /
  /// stroke-only shape): the shadow color and blur at [width] thickness —
  /// defaulting to the source width fattened by [spread] on both sides —
  /// reusing [source]'s cap and join. Memoized on [source] identity, which is
  /// safe because paint snapshots are immutable once handed to the queue (the
  /// batcher's identity-coalescing relies on the same invariant).
  Paint strokeShadowPaint(Paint source, [double? width]) {
    final w = width ?? source.strokeWidth + spread * 2;
    final cached = _strokeShadowPaint;
    if (cached != null &&
        identical(source, _strokeShadowSource) &&
        w == _strokeShadowWidth) {
      return cached;
    }
    _strokeShadowSource = source;
    _strokeShadowWidth = w;
    return _strokeShadowPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = source.strokeCap
      ..strokeJoin = source.strokeJoin
      ..maskFilter = _blurFilter;
  }

  /// Draws an area shape's shadow beneath it. Uses a filled silhouette when the
  /// shape has a [sourceFill]; otherwise traces the [sourceStroke] outline so a
  /// stroke-only shape casts an outline shadow rather than a filled blob.
  /// [geometry] paints the shape's path with the supplied paint.
  void paintShape(
    Canvas canvas,
    Paint? sourceFill,
    Paint? sourceStroke,
    void Function(Paint paint) geometry,
  ) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    if (sourceFill != null) {
      geometry(fillPaint);
      final sp = spreadPaint;
      if (sp != null) geometry(sp);
    } else if (sourceStroke != null) {
      geometry(strokeShadowPaint(sourceStroke));
    }
    canvas.restore();
  }
}

/// Drop-shadow state for shapes, custom shapes, lines, points, and text.
///
/// Like [fill]/[stroke], shadow is persistent engine state: once [shadow] is
/// called, every subsequent drawn shape casts an offset, blurred shadow until
/// [noShadow] is called. When inactive there is zero added cost — shapes batch
/// exactly as before.
mixin Flut5Shadow {
  /// The render queue, provided by [Flut5Engine].
  Flut5RenderQueue get renderQueue;

  Offset _shadowOffset = Offset.zero;
  double _shadowBlur = 0;
  double _shadowSpread = 0;
  Color _shadowColor = Colors.black;
  bool _shadowActive = false;

  /// Enables a drop shadow for subsequent drawing.
  ///
  /// [offsetX]/[offsetY] shift the shadow and [blur] softens it. [blur] is a
  /// CSS-style blur *radius* (converted to a Gaussian sigma internally, the
  /// same way Flutter's [BoxShadow] does), so values copied from a CSS
  /// `box-shadow` look the same here. The fourth argument, [spreadOrColor],
  /// is overloaded so [spread] can be skipped: pass a [num] to grow the
  /// silhouette, or a [Color] to set the shadow color directly (with spread
  /// `0`). A fifth [color] argument sets the color after an explicit spread.
  /// When no color is supplied the current shadow color is kept (black until
  /// changed via [shadow] or [shadowFill]). Argument order mirrors CSS
  /// `box-shadow`, and spread applies to shapes, lines, points, and text.
  ///
  /// ```dart
  /// shadow(4, 4, 8);                  // soft black drop shadow
  /// shadow(1, 1, 6, Colors.cyan);     // color, no spread
  /// shadow(0, 0, 12, 4, Colors.cyan); // colored glow with spread
  /// noShadow();                       // turn it off
  /// ```
  void shadow(
    double offsetX,
    double offsetY,
    double blur, [
    Object? spreadOrColor,
    Color? color,
  ]) {
    double spread = 0;
    Color? resolvedColor = color;
    if (spreadOrColor is num) {
      spread = spreadOrColor.toDouble();
    } else if (spreadOrColor is Color) {
      if (color != null) {
        throw ArgumentError(
          'shadow(): pass color once — as the 4th OR 5th argument, not both.',
        );
      }
      resolvedColor = spreadOrColor;
    } else if (spreadOrColor != null) {
      throw ArgumentError(
        'shadow() 4th argument must be a spread (num) or a Color. '
        'Got ${spreadOrColor.runtimeType}.',
      );
    }
    _shadowOffset = Offset(offsetX, offsetY);
    _shadowBlur = blur;
    _shadowSpread = spread;
    if (resolvedColor != null) _shadowColor = resolvedColor;
    _shadowActive = true;
    _pushShadow();
  }

  /// Changes only the shadow [color], keeping the current offset, blur and
  /// spread. Takes visible effect when a shadow is active (set via [shadow]).
  void shadowFill(Color color) {
    _shadowColor = color;
    if (_shadowActive) _pushShadow();
  }

  /// Disables the drop shadow. Subsequent shapes draw with no shadow (and
  /// resume batching). The offset/blur/spread/color are retained, so a later
  /// [shadow] call can re-enable with the same values.
  void noShadow() {
    // Already off — nothing to clear or flush, so this is a true no-op (no batch
    // split). Guards the common case of calling noShadow() defensively when no
    // shadow was ever active.
    if (!_shadowActive) return;
    _shadowActive = false;
    renderQueue.setShadowState(null);
  }

  void _pushShadow() {
    // shadow(...) with unchanged values every draw() is the common p5-style
    // pattern (like fill/stroke). Keeping the existing spec preserves its
    // identity-stability across frames — its lazy Paints stay warm — and,
    // crucially, skips the batch flushes in setShadowState.
    final cur = renderQueue.activeShadow;
    if (cur != null &&
        cur.color == _shadowColor &&
        cur.offset == _shadowOffset &&
        cur.blur == _shadowBlur &&
        cur.spread == _shadowSpread) {
      return;
    }
    renderQueue.setShadowState(
      Flut5ShadowSpec(_shadowColor, _shadowOffset, _shadowBlur, _shadowSpread),
    );
  }
}
