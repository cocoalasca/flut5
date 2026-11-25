import 'dart:ui' as ui show Image;
import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

import '../image/flut5_image_shadows.dart';
import '../text/flut5_text_cache.dart';
import 'flut5_color_resolver.dart';
import 'flut5_console.dart';
import 'flut5_engine_colors.dart';
import 'render/flut5_render_queue.dart';
import 'render/items/flut5_text_dynamic_batch_render_item.dart'
    show Flut5GlyphGrid;

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
class Flut5ShadowSpec(
  /// Shadow color (alpha included).
  final Color color,

  /// Offset of the shadow from the shape, in logical pixels.
  final Offset offset,

  /// Blur radius applied to the silhouette, in CSS `box-shadow` terms.
  /// Converted to a Gaussian sigma via [Shadow.convertRadiusToSigma]
  /// (exactly like Flutter's own [BoxShadow.toPaint]), so the same number
  /// gives the same softness as CSS. `0` keeps a hard edge.
  final double blur,

  /// Outward growth of the silhouette before blurring, in logical pixels.
  /// Shapes approximate it by fattening the outline; text dilates the glyph
  /// raster. `0` disables it.
  final double spread,
) {
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

  /// Tint paint for text shadows: recolours a white glyph raster — or the
  /// spread and blurred silhouette [paintText] bakes from one — to the shadow
  /// color. Sampled at the text cache's blit quality so the shadow resamples
  /// exactly like the glyphs it sits beneath.
  late final Paint textTintPaint = Paint()
    ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn)
    ..filterQuality = _textQuality;

  final FilterQuality _textQuality = Flut5TextCache.instance.textBlitQuality;

  /// Spread grows the glyphs by a morphological [ImageFilter.dilate], then
  /// the blur softens them (CSS order). `null` when the shadow is neither.
  late final ImageFilter? _silhouetteFilter = _buildSilhouetteFilter();

  ImageFilter? _buildSilhouetteFilter() {
    final blurred = blur > 0
        ? ImageFilter.blur(
            sigmaX: _blurSigma,
            sigmaY: _blurSigma,
            tileMode: TileMode.decal,
          )
        : null;
    if (spread <= 0) return blurred;
    final dilate = ImageFilter.dilate(radiusX: spread, radiusY: spread);
    return blurred == null
        ? dilate
        : ImageFilter.compose(outer: blurred, inner: dilate);
  }

  late final Paint _textBakePaint = Paint()
    ..imageFilter = _silhouetteFilter
    ..filterQuality = _textQuality;

  /// What tells baked silhouettes apart — by value, so a shadow set again
  /// with the same numbers reuses the bakes of the last.
  late final Object _textBakeKey = (blur, spread, _textQuality);

  /// Returns the baked shadow silhouette for [text], or `null` when this shadow
  /// has neither blur nor spread (a hard shadow blits [text] directly).
  Flut5ShadowRaster? resolveBakedShadow(Flut5CachedText text) {
    if (blur <= 0 && spread <= 0) return null;
    return Flut5TextCache.instance.bakedShadow(
      text,
      _textBakeKey,
      _textBakePaint,
      spread + (blur > 0 ? 3 * _blurSigma : 0),
    );
  }

  /// Draws the shadow of the white text raster [text] whose box is at [dst]
  /// (its left edge [Flut5CachedText.leftPad] before the pen, its top the top
  /// of the line): the raster recoloured, spread and blurred, shifted by
  /// [offset].
  ///
  /// Filtering every glyph every frame cost ~0.15 ms of GPU time per glyph
  /// on Impeller (150 shadowed characters: 22 ms a frame). A spread or
  /// blurred shadow is instead baked once into a silhouette kept with the
  /// raster ([Flut5TextCache.bakedShadow]), so a frame only blits it.
  void paintText(Canvas canvas, Flut5CachedText text, Rect dst) {
    final left = dst.left + text.leftPad - text.rasterLeft + offset.dx;
    final top = dst.top - text.rasterTop + offset.dy;
    final baked = resolveBakedShadow(text);
    if (baked == null) {
      canvas.drawImageRect(
        text.image,
        text.srcRect,
        Rect.fromLTWH(left, top, text.blitWidth, text.blitHeight),
        textTintPaint,
      );
      return;
    }
    canvas.drawImageRect(
      baked.image,
      baked.srcRect,
      Rect.fromLTWH(
        left - baked.pad,
        top - baked.pad,
        baked.size.width,
        baked.size.height,
      ),
      textTintPaint,
    );
  }

  /// Tint paint for image shadows: recolours a bitmap — or the spread and
  /// blurred silhouette [paintImage] bakes from one — to the shadow color.
  /// Sampled at the [FilterQuality.medium] images blit with.
  late final Paint imageTintPaint = Paint()
    ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn)
    ..filterQuality = FilterQuality.medium;

  /// Layer paint for a soft image shadow drawn live, see [paintImage].
  late final Paint _imageLayerPaint = Paint()..imageFilter = _silhouetteFilter;

  /// Draws the shadow of [src] of [image] laid out at [dst]. A bitmap's own
  /// alpha is the silhouette, so a transparent PNG casts a soft shadow shaped
  /// like its content rather than a rectangular blob.
  ///
  /// A spread or blurred shadow takes an offscreen pass. It is baked once the
  /// same draw repeats ([Flut5ImageShadows]), so a frame only blits it; a draw
  /// that doesn't repeat, like a sprite whose size animates, is filtered live.
  void paintImage(Canvas canvas, ui.Image image, Rect src, Rect dst) {
    final at = dst.shift(offset);
    final filter = _silhouetteFilter;
    if (filter == null) {
      canvas.drawImageRect(image, src, at, imageTintPaint);
      return;
    }
    final reach = spread + (blur > 0 ? 3 * _blurSigma : 0);
    final canvasScale = Flut5GlyphGrid.effectiveScaleFor(canvas);
    final baked = Flut5ImageShadows.silhouette(
      image: image,
      src: src,
      size: Size(dst.width.abs(), dst.height.abs()),
      pixelRatio: Flut5TextCache.instance.pixelRatio * canvasScale,
      filterKey: (blur, spread),
      filter: filter,
      reach: reach,
    );
    if (baked == null) {
      canvas.saveLayer(at.inflate(reach + 2), _imageLayerPaint);
      canvas.drawImageRect(image, src, at, imageTintPaint);
      canvas.restore();
      return;
    }
    canvas.drawImageRect(
      baked.image,
      baked.srcRect,
      Rect.fromLTWH(
        at.left - baked.pad,
        at.top - baked.pad,
        baked.size.width,
        baked.size.height,
      ),
      imageTintPaint,
    );
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
  Color _shadowColor = flut5Black;
  bool _shadowActive = false;

  /// Enables a drop shadow for subsequent drawing.
  ///
  /// [offsetX]/[offsetY] shift the shadow and [blur] softens it. [blur] is a
  /// CSS-style blur *radius* (converted to a Gaussian sigma internally, the
  /// same way Flutter's [BoxShadow] does), so values copied from a CSS
  /// `box-shadow` look the same here. The fourth argument, [spreadOrColor],
  /// is overloaded so [spread] can be skipped: pass a [num] to grow the
  /// silhouette, or a color ([Color], hex / CSS `rgb()`/`rgba()` string, or
  /// 1–4 element numeric list) to set the shadow color directly (with spread
  /// `0`). A fifth [color] argument sets the color after an explicit spread
  /// (also accepting a grayscale [num]). When no color is supplied the current
  /// shadow color is kept (black until changed via [shadow] or [shadowFill]).
  /// Argument order mirrors CSS `box-shadow`, and spread applies to shapes,
  /// lines, points, and text.
  ///
  /// ```dart
  /// shadow(4, 4, 8);                     // soft black drop shadow
  /// shadow(1, 1, 6, Colors.cyan);        // color, no spread
  /// shadow(1, 1, 6, '#00ffff80');        // hex color, no spread
  /// shadow(0, 0, 12, 4, Colors.cyan);    // colored glow with spread
  /// shadow(0, 0, 12, 4, [0, 255, 255]);  // RGB list with spread
  /// noShadow();                          // turn it off
  /// ```
  void shadow(
    double offsetX,
    double offsetY,
    double blur, [
    Object? spreadOrColor,
    Object? color,
  ]) {
    double spread = 0;
    Color? resolvedColor;
    if (spreadOrColor is num) {
      spread = spreadOrColor.toDouble();
      if (color != null) {
        resolvedColor = flut5TryResolveSingleColor(color);
        if (resolvedColor == null) {
          throw ArgumentError.value(
            color,
            'color',
            'shadow() 5th argument must be a Color, hex/rgb String, '
                'grayscale num, or 1–4 element List<num>',
          );
        }
      }
    } else if (spreadOrColor != null) {
      final parsed = flut5TryResolveSingleColor(spreadOrColor);
      if (parsed == null) {
        throw ArgumentError(
          'shadow() 4th argument must be a spread (num) or a color '
          '(Color, hex/rgb String, or List<num>). '
          'Got ${spreadOrColor.runtimeType}.',
        );
      }
      if (color != null) {
        throw ArgumentError(
          'shadow(): pass color once — as the 4th OR 5th argument, not both.',
        );
      }
      resolvedColor = parsed;
    } else if (color != null) {
      resolvedColor = flut5TryResolveSingleColor(color);
      if (resolvedColor == null) {
        throw ArgumentError.value(
          color,
          'color',
          'shadow() 5th argument must be a Color, hex/rgb String, '
              'grayscale num, or 1–4 element List<num>',
        );
      }
    }
    _shadowOffset = Offset(offsetX, offsetY);
    _shadowBlur = blur;
    _shadowSpread = spread;
    if (resolvedColor != null) _shadowColor = resolvedColor;
    _shadowActive = true;
    _pushShadow();
  }

  /// Changes only the shadow color, keeping the current offset, blur and
  /// spread. Takes visible effect when a shadow is active (set via [shadow]).
  ///
  /// Accepts a [Color], p5-style numeric values (`0..255`), a hex / CSS
  /// `rgb()`/`rgba()` string, or a 1–4 element numeric list.
  void shadowFill(Object input, [num? a, num? b, num? c]) {
    if (input is Color && a == null && b == null && c == null) {
      _shadowColor = input;
      if (_shadowActive) _pushShadow();
      return;
    }
    final res = flut5ResolveColorArgs('shadowFill', input, a, b, c);
    if (res.error != null) {
      Flut5Console.printLater('${res.error} — ignored');
      return;
    }
    if (res.warning != null) {
      Flut5Console.printLater(res.warning!);
    }
    _shadowColor = res.color ?? Color(res.argb!);
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
