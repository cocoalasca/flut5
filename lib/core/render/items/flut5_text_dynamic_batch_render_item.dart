import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flut5/text/flut5_text_cache.dart';
import 'package:flut5/text/flut5_text_shaping.dart';

import '../../flut5_shadow.dart';
import '../flut5_overlap_index.dart';
import '../flut5_render_item.dart';

/// How a canvas maps text onto the device's pixels, read once per draw.
///
/// Text engines place a glyph on a quarter of a device pixel along x and on
/// a whole pixel along y. Drawing a cached glyph raster anywhere else
/// resamples it, which is what makes bitmap text look soft. So wherever the
/// transform keeps pixels square and upright, a glyph takes the raster for
/// its quarter ([phase]) and is blitted on a whole pixel, which comes out
/// exactly as the engine would have drawn it.
final class Flut5GlyphGrid._() {
  /// The canvas scale when the current replay began: what the display or a
  /// trail capture contributes, as opposed to the sketch's own `scale()`.
  /// `0` outside a replay.
  static double _replayScale = 0;

  /// Set while replaying a pixelate scope: its canvas is block resolution,
  /// and text there is meant to come out averaged. A scope too fine to
  /// pixelate draws on its parent's canvas, so a change here also ends what
  /// was read from that canvas.
  static bool get pixelating => _pixelating;
  static set pixelating(bool value) {
    if (value == _pixelating) return;
    _pixelating = value;
    _lastReadCanvas = null;
  }

  static bool _pixelating = false;

  static final Flut5GlyphGrid _shared = Flut5GlyphGrid._();

  // Reading a canvas's transform is a call into the engine, and most items
  // of a replay leave it alone. So the last read stands while a replay runs
  // items that keep the transform ([beforeItem]); [_lastReadCanvas] is null
  // whenever it can't be trusted.
  static bool _readsStayValid = false;
  static Canvas? _lastReadCanvas;
  static double _lastReadPixelRatio = 0;

  static void beginReplay(Canvas canvas) {
    final m = canvas.getTransform();
    _replayScale = math.sqrt(m[0] * m[0] + m[1] * m[1]);
    _readsStayValid = false;
    _lastReadCanvas = null;
  }

  static void endReplay() {
    _replayScale = 0;
    pixelating = false;
    _readsStayValid = false;
    _lastReadCanvas = null;
  }

  /// Told by a replay before each item, with whether the item puts the
  /// canvas back on the transform it found. Reads made during one that
  /// doesn't are never reused.
  @pragma('vm:prefer-inline')
  static void beforeItem(bool keepsTransform) {
    _readsStayValid = keepsTransform;
    if (!keepsTransform) _lastReadCanvas = null;
  }

  /// The grid of [canvas] as it stands now. One shared object: read it, use
  /// it, and don't hold it across another draw.
  static Flut5GlyphGrid of(Canvas canvas, double pixelRatio) {
    if (_readsStayValid &&
        identical(canvas, _lastReadCanvas) &&
        pixelRatio == _lastReadPixelRatio) {
      return _shared;
    }
    _shared._read(canvas, pixelRatio);
    _lastReadCanvas = _readsStayValid ? canvas : null;
    _lastReadPixelRatio = pixelRatio;
    return _shared;
  }

  /// Sketch-level scale on [canvas] relative to the current replay base,
  /// quantized to 1/64 so rotation noise does not churn offscreen shadow bakes.
  static double effectiveScaleFor(Canvas canvas) {
    final m = canvas.getTransform();
    final a = m[0], b = m[1], c = m[4], d = m[5];
    final sx = math.sqrt(a * a + b * b);
    final sy = math.sqrt(c * c + d * d);
    final mag = math.max(sx, sy);
    if (!mag.isFinite || mag <= 0) return 1.0;
    final base = _replayScale > 0 ? _replayScale : mag;
    final scale = (mag / base).clamp(0.125, 8.0);
    return (scale * 64).roundToDouble() / 64;
  }

  /// Squared uniform scale added onto [canvas] on top of the current replay
  /// base, or `-1` when the canvas transform is non-uniform or skewed.
  static double canvasLinearScaleSq(Canvas canvas) {
    final m = canvas.getTransform();
    if (m[3] != 0 || m[7] != 0 || m[15] != 1) return -1;
    final a = m[0], b = m[1], c = m[4], d = m[5];
    final sx2 = a * a + b * b;
    final sy2 = c * c + d * d;
    if (!(sx2 > 0) || !sx2.isFinite || !(sy2 > 0) || !sy2.isFinite) return -1;
    final dot = a * c + b * d;
    if (dot.abs() > math.max(sx2, sy2) * 1e-4) return -1;
    if ((sx2 - sy2).abs() > math.max(sx2, sy2) * 1e-4) return -1;
    final base = _replayScale > 0 ? _replayScale : math.sqrt(sx2);
    if (!(base > 0) || !base.isFinite) return -1;
    return sx2 / (base * base);
  }

  /// How much the sketch's transforms on the canvas scale text, so rasters
  /// can be made at that density. `1` when they don't keep it uniform.
  double canvasScale = 1;

  /// The raster to use for the x last given to [snapX], in quarters of a
  /// device pixel.
  int phase = 0;

  double _scale = 1;
  double _translateX = 0;
  double _translateY = 0;
  double _canvasToDevice = 1;
  double _deviceToCanvas = 1;
  double _originX = 0;
  bool _isUpright = false;

  void _read(Canvas canvas, double pixelRatio) {
    final m = canvas.getTransform();
    final a = m[0], b = m[1], c = m[4], d = m[5];
    final isFlat = m[3] == 0 && m[7] == 0 && m[15] == 1;
    final magnitude = math.sqrt(a * a + b * b);
    final tolerance = magnitude * 1e-5;
    final isSimilarity =
        isFlat &&
        magnitude > 0 &&
        (a - d).abs() <= tolerance &&
        (b + c).abs() <= tolerance;
    final base = _replayScale > 0
        ? _replayScale
        : (magnitude > 0 ? magnitude : 1.0);
    canvasScale = pixelating || !isSimilarity ? 1 : magnitude / base;
    _scale = a;
    _translateX = m[12];
    _translateY = m[13];
    // On screen the canvas is in logical pixels and the display's ratio is
    // applied after it; a capture canvas already carries the ratio. Any
    // other base puts the device's pixels somewhere this can't tell.
    final baseIsLogical = (base - 1).abs() < 1e-3;
    final baseIsDevice = (base - pixelRatio).abs() < 1e-3;
    _canvasToDevice = baseIsLogical ? pixelRatio : 1;
    _deviceToCanvas = 1 / (_canvasToDevice * a);
    _originX = _translateX / a;
    _isUpright =
        isSimilarity &&
        !pixelating &&
        b == 0 &&
        c == 0 &&
        a > 0 &&
        (baseIsLogical || baseIsDevice);
  }

  /// Whether text transformed by a fold of [foldA], [foldB] lands upright
  /// on the device's pixels, so [snapX] and [snapY] apply.
  bool isAligned(double foldA, double foldB) =>
      _isUpright && foldB == 0 && foldA > 0;

  /// [x], in the canvas's current coordinates, moved to the whole device
  /// pixel of its quarter-pixel position. Sets [phase] to that quarter.
  @pragma('vm:prefer-inline')
  double snapX(double x) {
    final device = (_scale * x + _translateX) * _canvasToDevice;
    if (!device.isFinite) {
      phase = 0;
      return x;
    }
    final quarters = (device * Flut5TextCache.subpixelPhases + 0.5).floor();
    phase = quarters & (Flut5TextCache.subpixelPhases - 1);
    final whole = quarters >> 2;
    return whole * _deviceToCanvas - _originX;
  }

  /// [y], in the canvas's current coordinates, moved to the nearest whole
  /// device pixel.
  double snapY(double y) {
    final device = (_scale * y + _translateY) * _canvasToDevice;
    if (!device.isFinite) return y;
    return ((device + 0.5).floorToDouble() / _canvasToDevice - _translateY) /
        _scale;
  }
}

/// Everything a block of text can paint, in the coordinates of its layout
/// [box]: glyphs reaching past their line, a stroke, and a shadow's halo.
Rect flut5TextInkBox(
  Rect box,
  double fontSize,
  double strokeWidth,
  Flut5ShadowSpec? shadow,
) {
  final ink = box.inflate(
    fontSize * Flut5TextCache.verticalInkReach + strokeWidth * 2 + 2,
  );
  if (shadow == null) return ink;
  final halo = shadow.blur > 0
      ? 3 * Shadow.convertRadiusToSigma(shadow.blur)
      : 0.0;
  return ink.expandToInclude(
    ink.shift(shadow.offset).inflate(shadow.spread + halo),
  );
}

/// Queues glyphs as sprites of the shared atlas pages and emits them with
/// `Canvas.drawRawAtlas`, one call per run on the same page.
///
/// Reused synchronously during `execute(canvas)`: Skia and Impeller copy the
/// typed arrays when recording `drawRawAtlas`, so static scratch buffers avoid
/// per-frame allocations once warmed. Every draw method leaves sprites queued
/// so consecutive lines share a call; end with [flush].
class Flut5GlyphAtlasBlitter._() {
  static Float32List _transforms = Float32List(128 * 4);
  static Float32List _rects = Float32List(128 * 4);
  static Int32List _colors = Int32List(128);
  static int _queued = 0;
  static Flut5GlyphAtlasPage? _queuedPage;
  static bool _queuedTinted = false;

  static final Paint _atlasPaint = Paint();
  static final Paint _tintPaint = Paint();
  static Color? _tintPaintColor;
  static final Paint _emojiDirectPaint = Paint();
  static int? _emojiDirectAlpha;
  static FilterQuality? _emojiDirectQuality;
  static final Flut5OverlapIndex _runBoxes = Flut5OverlapIndex();
  static final Float64List _scratchMatrix = Float64List(16)
    ..[10] = 1
    ..[15] = 1;
  static final Paint _nativeFillPaint = Paint();
  static final Paint _nativeStrokePaint = Paint()..style = PaintingStyle.stroke;

  /// Sets the sampling for sprites queued from now on.
  static void setQuality(FilterQuality quality) {
    _atlasPaint.filterQuality = quality;
  }

  /// Draws the queued sprites.
  static void flush(Canvas canvas) {
    final page = _queuedPage;
    if (_queued > 0 && page != null) {
      final image = Flut5TextCache.instance.committedAtlasImage(page);
      if (image != null) {
        canvas.drawRawAtlas(
          image,
          Float32List.sublistView(_transforms, 0, _queued * 4),
          Float32List.sublistView(_rects, 0, _queued * 4),
          _queuedTinted ? Int32List.sublistView(_colors, 0, _queued) : null,
          _queuedTinted ? ui.BlendMode.modulate : null,
          null,
          _atlasPaint,
        );
      }
    }
    _queued = 0;
    _queuedPage = null;
  }

  /// Makes room for [sprites] queued in all, keeping those already queued.
  static void _reserveSprites(int sprites) {
    if (sprites <= _colors.length) return;
    var capacity = _colors.length * 2;
    while (capacity < sprites) {
      capacity *= 2;
    }
    _transforms = Float32List(capacity * 4)
      ..setRange(0, _queued * 4, _transforms);
    _rects = Float32List(capacity * 4)..setRange(0, _queued * 4, _rects);
    _colors = Int32List(capacity)..setRange(0, _queued, _colors);
  }

  static void _queueSprite(
    Canvas canvas,
    Flut5GlyphAtlasSlot slot,
    double scaledCos,
    double scaledSin,
    double translateX,
    double translateY,
    int? color,
  ) {
    final tinted = color != null;
    if (_queued > 0 &&
        (!identical(_queuedPage, slot.page) || _queuedTinted != tinted)) {
      flush(canvas);
    }
    _queuedPage = slot.page;
    _queuedTinted = tinted;
    _reserveSprites(_queued + 1);
    final offset = _queued * 4;
    _transforms[offset] = scaledCos;
    _transforms[offset + 1] = scaledSin;
    _transforms[offset + 2] = translateX;
    _transforms[offset + 3] = translateY;
    _rects[offset] = slot.left;
    _rects[offset + 1] = slot.top;
    _rects[offset + 2] = slot.right;
    _rects[offset + 3] = slot.bottom;
    if (tinted) _colors[_queued] = color;
    _queued++;
  }

  /// Draws an image too big for the atlas, or that found no room on it, at
  /// ([translateX], [translateY]) under the fold's rotation and scale.
  static void _drawDirect(
    Canvas canvas,
    ui.Image image,
    Rect source,
    double translateX,
    double translateY,
    double width,
    double height,
    double foldA,
    double foldB,
    Paint paint,
  ) {
    if (foldB == 0 && foldA > 0) {
      canvas.drawImageRect(
        image,
        source,
        Rect.fromLTWH(translateX, translateY, width * foldA, height * foldA),
        paint,
      );
      return;
    }
    _scratchMatrix[0] = foldA;
    _scratchMatrix[1] = foldB;
    _scratchMatrix[4] = -foldB;
    _scratchMatrix[5] = foldA;
    _scratchMatrix[12] = translateX;
    _scratchMatrix[13] = translateY;
    canvas.save();
    canvas.transform(_scratchMatrix);
    canvas.drawImageRect(
      image,
      source,
      Rect.fromLTWH(0, 0, width, height),
      paint,
    );
    canvas.restore();
  }

  static Paint _emojiPaint(int argb, FilterQuality quality) {
    final alpha = (argb >> 24) & 0xFF;
    if (alpha != _emojiDirectAlpha || quality != _emojiDirectQuality) {
      _emojiDirectAlpha = alpha;
      _emojiDirectQuality = quality;
      _emojiDirectPaint
        ..filterQuality = quality
        ..colorFilter = alpha >= 255
            ? null
            : ColorFilter.mode(
                Color.fromARGB(alpha, 255, 255, 255),
                ui.BlendMode.modulate,
              );
    }
    return _emojiDirectPaint;
  }

  // What [_entryTint] tints to, set per entry so that a batch hands out one
  // function instead of a closure each.
  static Color _entryTintColor = const Color(0x00000000);
  static FilterQuality _entryTintQuality = FilterQuality.low;

  /// The paint tinting a white glyph to the current entry's colour, for
  /// glyphs drawn without the atlas.
  static Paint _entryTint() {
    if (_entryTintColor != _tintPaintColor) {
      _tintPaintColor = _entryTintColor;
      _tintPaint.colorFilter = ColorFilter.mode(
        _entryTintColor,
        ui.BlendMode.srcIn,
      );
    }
    return _tintPaint..filterQuality = _entryTintQuality;
  }

  /// Queues the glyphs of [line] with its pen starting at ([startX], [y]).
  ///
  /// [spriteColor] tints the white rasters; `null` leaves them white, as a
  /// mask. [directPaint] gives the paint for the glyphs the atlas can't take,
  /// and all of them when [useAtlas] is off, for paints an atlas can't apply;
  /// it is only called when one is drawn, as building a tint isn't free. The
  /// fold is the part of the transform baked into coordinates by the render
  /// queue.
  static void drawLine(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5TextLine line,
    Flut5GlyphFont font,
    Flut5GlyphGrid grid, {
    required int paintingStyle,
    required double strokeWidth,
    required double rasterScale,
    required double startX,
    required double y,
    required double spacing,
    required int? spriteColor,
    required Paint Function() directPaint,
    bool useAtlas = true,
    bool isShadow = false,
    double foldA = 1,
    double foldB = 0,
    double foldDx = 0,
    double foldDy = 0,
  }) {
    final glyphCount = line.glyphs.length;
    if (glyphCount == 0) return;
    final aligned = grid.isAligned(foldA, foldB);
    final snappedY = aligned ? grid.snapY(foldA * y + foldDy) : 0.0;
    var pass = cache.linePass(line, paintingStyle, strokeWidth, rasterScale);
    var pixelsPerUnit = 0.0;
    var perPixel = 0.0;
    final tinted = spriteColor != null;
    if (_queued > 0 && _queuedTinted != tinted) flush(canvas);
    _queuedTinted = tinted;
    final checkEmoji =
        !isShadow && paintingStyle == 0 && tinted && useAtlas;
    // Room for the whole line, so the buffers stay put through the loop.
    _reserveSprites(_queued + glyphCount);
    final transforms = _transforms, rects = _rects, colors = _colors;
    for (var i = 0; i < glyphCount; i++) {
      final penX = startX + line.offsetWithSpacing(i, spacing);
      var phase = 0;
      var snappedX = 0.0;
      if (aligned) {
        snappedX = grid.snapX(foldA * penX + foldDx);
        phase = grid.phase;
      }
      var raster = cache.keptGlyph(pass, i, phase);
      if (raster == null) {
        raster = cache.lineGlyph(
          line,
          i,
          font,
          paintingStyle: paintingStyle,
          strokeWidth: strokeWidth,
          phase: phase,
          rasterScale: rasterScale,
        );
        pass = cache.linePass(line, paintingStyle, strokeWidth, rasterScale);
      }
      final double translateX, translateY;
      if (aligned) {
        translateX = snappedX - foldA * raster.rasterLeft;
        translateY = snappedY - foldA * raster.rasterTop;
      } else {
        final left = penX - raster.rasterLeft;
        final top = y - raster.rasterTop;
        translateX = foldA * left - foldB * top + foldDx;
        translateY = foldB * left + foldA * top + foldDy;
      }
      final slot = useAtlas ? cache.atlasSlotFor(raster) : null;
      final preserveEmoji = checkEmoji && flut5HasColorEmoji(line.glyphs[i]);
      if (slot != null) {
        if (raster.pixelsPerUnit != pixelsPerUnit) {
          pixelsPerUnit = raster.pixelsPerUnit;
          perPixel = 1 / pixelsPerUnit;
        }
        final page = slot.page;
        if (!identical(_queuedPage, page)) {
          if (_queued > 0) flush(canvas);
          _queuedPage = page;
        }
        final sprite = _queued++;
        final offset = sprite * 4;
        transforms[offset] = foldA * perPixel;
        transforms[offset + 1] = foldB * perPixel;
        transforms[offset + 2] = translateX;
        transforms[offset + 3] = translateY;
        rects[offset] = slot.left;
        rects[offset + 1] = slot.top;
        rects[offset + 2] = slot.right;
        rects[offset + 3] = slot.bottom;
        if (tinted) {
          colors[sprite] = preserveEmoji
              ? (spriteColor & 0xFF000000) | 0x00FFFFFF
              : spriteColor;
        }
      } else {
        flush(canvas);
        _drawDirect(
          canvas,
          raster.image,
          raster.srcRect,
          translateX,
          translateY,
          raster.blitWidth,
          raster.blitHeight,
          foldA,
          foldB,
          preserveEmoji
              ? _emojiPaint(spriteColor, _atlasPaint.filterQuality)
              : directPaint(),
        );
      }
    }
  }

  /// Queues the shadow of [line]. A hard shadow is a recoloured copy of the
  /// glyphs and lands on the pixel grid as they do. A soft one blits its
  /// baked silhouette where it falls: blurred, it has no edge to keep sharp.
  static void drawShadowLine(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5TextLine line,
    Flut5GlyphFont font,
    Flut5GlyphGrid grid, {
    required Flut5ShadowSpec shadow,
    required int paintingStyle,
    required double strokeWidth,
    required double rasterScale,
    required double startX,
    required double y,
    required double spacing,
    double foldA = 1,
    double foldB = 0,
    double foldDx = 0,
    double foldDy = 0,
  }) {
    final offsetX = shadow.offset.dx, offsetY = shadow.offset.dy;
    final color = shadow.color.toARGB32();
    if (shadow.blur <= 0 && shadow.spread <= 0) {
      drawLine(
        canvas,
        cache,
        line,
        font,
        grid,
        paintingStyle: paintingStyle,
        strokeWidth: strokeWidth,
        rasterScale: rasterScale,
        startX: startX + offsetX,
        y: y + offsetY,
        spacing: spacing,
        spriteColor: color,
        directPaint: () => shadow.textTintPaint,
        isShadow: true,
        foldA: foldA,
        foldB: foldB,
        foldDx: foldDx,
        foldDy: foldDy,
      );
      return;
    }
    for (var i = 0; i < line.glyphs.length; i++) {
      final raster = cache.lineGlyph(
        line,
        i,
        font,
        paintingStyle: paintingStyle,
        strokeWidth: strokeWidth,
        phase: 0,
        rasterScale: rasterScale,
      );
      final baked = shadow.resolveBakedShadow(raster)!;
      final left =
          startX +
          line.offsetWithSpacing(i, spacing) +
          offsetX -
          raster.rasterLeft -
          baked.pad;
      final top = y + offsetY - raster.rasterTop - baked.pad;
      final translateX = foldA * left - foldB * top + foldDx;
      final translateY = foldB * left + foldA * top + foldDy;
      final slot = cache.atlasSlotForShadow(baked);
      if (slot != null) {
        final perPixel = 1 / raster.pixelsPerUnit;
        _queueSprite(
          canvas,
          slot,
          foldA * perPixel,
          foldB * perPixel,
          translateX,
          translateY,
          color,
        );
      } else {
        flush(canvas);
        _drawDirect(
          canvas,
          baked.image,
          baked.srcRect,
          translateX,
          translateY,
          baked.size.width,
          baked.size.height,
          foldA,
          foldB,
          shadow.textTintPaint,
        );
      }
    }
  }

  /// Draws [line] through the platform's text renderer instead of the glyph
  /// cache, with [foreground] carrying its colour and stroke and [spacing]
  /// its full letter spacing.
  static void paintLineNatively(
    Canvas canvas,
    Flut5TextLine line,
    Flut5GlyphFont font, {
    required Paint foreground,
    required double startX,
    required double y,
    required double spacing,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: line.sourceText,
        style: TextStyle(
          fontFamily: font.family,
          fontSize: font.size,
          fontWeight: font.weight,
          fontStyle: font.style,
          fontVariations: font.variations,
          foreground: foreground,
          letterSpacing: spacing == 0 ? null : spacing,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(startX - spacing / 2, y));
    painter.dispose();
  }

  /// Draws [text], which has no wrapping, through the platform's text
  /// renderer: a paragraph per line, with each of [foregrounds] painted in
  /// order. Works without the per-glyph layout, which for a size that
  /// animates would be measured to be used once.
  static void paintUnwrappedNatively(
    Canvas canvas,
    String text,
    Flut5GlyphFont font, {
    required List<Paint> foregrounds,
    required double x,
    required double y,
    required double spacing,
    required TextAlign align,
    required double Function() lineHeight,
  }) {
    final isSingleLine = !text.contains('\n');
    final sourceLines = isSingleLine ? [text] : text.split('\n');
    var lineY = y;
    for (var l = 0; l < sourceLines.length; l++) {
      final sourceLine = sourceLines[l];
      if (sourceLine.isNotEmpty) {
        var startX = x;
        for (var p = 0; p < foregrounds.length; p++) {
          final painter = TextPainter(
            text: TextSpan(
              text: sourceLine,
              style: TextStyle(
                fontFamily: font.family,
                fontSize: font.size,
                fontWeight: font.weight,
                fontStyle: font.style,
                fontVariations: font.variations,
                foreground: foregrounds[p],
                letterSpacing: spacing == 0 ? null : spacing,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          if (p == 0) {
            // The paragraph counts spacing after the last glyph too; the
            // line's width, which alignment goes by, doesn't.
            final lineWidth = painter.width - spacing;
            if (align == TextAlign.center) {
              startX = x - lineWidth / 2;
            } else if (align == TextAlign.right || align == TextAlign.end) {
              startX = x - lineWidth;
            }
          }
          // A paragraph puts half the spacing before each glyph; the glyph
          // route starts its first glyph on the pen.
          painter.paint(canvas, Offset(startX - spacing / 2, lineY));
          painter.dispose();
        }
      }
      if (!isSingleLine) lineY += lineHeight();
    }
  }

  static bool _entryDrawsNatively(
    Flut5TextCache cache,
    Flut5GlyphGrid grid,
    Flut5TextDynamicEntry entry,
  ) {
    if (entry.shadow != null) return false;
    final requestedScale = entry.foldScale * grid.canvasScale;
    final rasterScale = cache.rasterScaleFor(entry.fontSize, requestedScale);
    if (cache.drawsNatively(
      entry.font,
      entry.paintingStyle,
      entry.strokeWidth,
      rasterScale,
      requestedScale,
    )) {
      return true;
    }
    return entry.strokeColor != null &&
        cache.drawsNatively(
          entry.font,
          1,
          entry.strokeWidth,
          rasterScale,
          requestedScale,
        );
  }

  /// Blits an entire batch of plain solid-colour `textDynamic` entries
  /// (potentially spanning different strings, sizes, colours, shadows,
  /// outlined+filled pairs, positions, rotations, and uniform scales) in
  /// minimal `Canvas.drawRawAtlas` calls against [Flut5TextCache]'s glyph atlas.
  static void drawBatch(Canvas canvas, List<Flut5TextDynamicEntry> entries) {
    final cache = Flut5TextCache.instance;
    final grid = Flut5GlyphGrid.of(canvas, cache.pixelRatio);
    setQuality(cache.textBlitQuality);
    var hasAnyShadow = false;
    var hasAnyStrokeFill = false;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].shadow != null) hasAnyShadow = true;
      if (entries[i].strokeColor != null) hasAnyStrokeFill = true;
      if (hasAnyShadow && hasAnyStrokeFill) break;
    }
    if (!hasAnyShadow && !hasAnyStrokeFill) {
      _drawGlyphRange(canvas, cache, grid, entries, 0, entries.length);
      flush(canvas);
      return;
    }

    // Group consecutive non-overlapping entries so all their shadows, stroke
    // under-passes (for fill+stroke entries), and fills/single passes each
    // batch cleanly in drawRawAtlas while preserving exact painter's order on
    // any overlap.
    var runStart = 0;
    final runBoxes = _runBoxes..clear();
    void flushRun(int end) {
      if (runStart >= end) return;
      if (hasAnyShadow) {
        _drawShadowRange(canvas, cache, grid, entries, runStart, end);
      }
      if (hasAnyStrokeFill) {
        _drawStrokeFillPassRange(canvas, cache, grid, entries, runStart, end);
      }
      _drawGlyphRange(canvas, cache, grid, entries, runStart, end);
    }

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (i == runStart &&
          entry.shadow == null &&
          entry.strokeColor == null &&
          _entryDrawsNatively(cache, grid, entry)) {
        flush(canvas);
        _paintEntryNatively(canvas, entry);
        runStart = i + 1;
        continue;
      }
      final box = entry.inkBounds();
      if (runBoxes.overlaps(box.left, box.top, box.right, box.bottom)) {
        flushRun(i);
        runStart = i;
        runBoxes.clear();
      }
      runBoxes.add(box.left, box.top, box.right, box.bottom);
    }
    if (runStart < entries.length) {
      flushRun(entries.length);
    }
    runBoxes.clear();
    flush(canvas);
  }

  static void _drawShadowRange(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5GlyphGrid grid,
    List<Flut5TextDynamicEntry> entries,
    int startIndex,
    int endIndex,
  ) {
    for (var e = startIndex; e < endIndex; e++) {
      final entry = entries[e];
      final shadow = entry.shadow;
      if (shadow == null || entry.text.isEmpty) continue;
      final rasterScale = cache.rasterScaleFor(
        entry.fontSize,
        entry.foldScale * grid.canvasScale,
      );
      var lineY = entry.y;
      for (final line in entry.lines) {
        drawShadowLine(
          canvas,
          cache,
          line,
          entry.font,
          grid,
          shadow: shadow,
          paintingStyle: entry.paintingStyle,
          strokeWidth: entry.strokeWidth,
          rasterScale: rasterScale,
          startX: entry.startXOf(line),
          y: lineY,
          spacing: entry.spacing,
          foldA: entry.foldA,
          foldB: entry.foldB,
          foldDx: entry.foldDx,
          foldDy: entry.foldDy,
        );
        lineY += entry.lineHeight;
      }
    }
  }

  /// Draws the stroke under-pass of all `strokeColor != null` entries in
  /// `[startIndex, endIndex)` that don't fall back to per-line interleaving or
  /// native painting.
  static void _drawStrokeFillPassRange(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5GlyphGrid grid,
    List<Flut5TextDynamicEntry> entries,
    int startIndex,
    int endIndex,
  ) {
    final quality = cache.textBlitQuality;
    for (var e = startIndex; e < endIndex; e++) {
      final entry = entries[e];
      final strokeCol = entry.strokeColor;
      if (strokeCol == null ||
          entry.text.isEmpty ||
          entry.needsPerLineStrokeFill ||
          _entryDrawsNatively(cache, grid, entry)) {
        continue;
      }
      final requestedScale = entry.foldScale * grid.canvasScale;
      final rasterScale = cache.rasterScaleFor(entry.fontSize, requestedScale);
      final argb = strokeCol.toARGB32();
      _entryTintColor = strokeCol;
      _entryTintQuality = quality;
      var lineY = entry.y;
      for (final line in entry.lines) {
        drawLine(
          canvas,
          cache,
          line,
          entry.font,
          grid,
          paintingStyle: 1,
          strokeWidth: entry.strokeWidth,
          rasterScale: rasterScale,
          startX: entry.startXOf(line),
          y: lineY,
          spacing: entry.spacing,
          spriteColor: argb,
          directPaint: _entryTint,
          foldA: entry.foldA,
          foldB: entry.foldB,
          foldDx: entry.foldDx,
          foldDy: entry.foldDy,
        );
        lineY += entry.lineHeight;
      }
    }
  }

  static void _drawGlyphRange(
    Canvas canvas,
    Flut5TextCache cache,
    Flut5GlyphGrid grid,
    List<Flut5TextDynamicEntry> entries,
    int startIndex,
    int endIndex,
  ) {
    final quality = cache.textBlitQuality;
    for (var e = startIndex; e < endIndex; e++) {
      final entry = entries[e];
      if (entry.text.isEmpty) continue;
      final requestedScale = entry.foldScale * grid.canvasScale;
      final rasterScale = cache.rasterScaleFor(entry.fontSize, requestedScale);
      if (_entryDrawsNatively(cache, grid, entry)) {
        flush(canvas);
        _paintEntryNatively(canvas, entry);
        continue;
      }
      if (entry.needsPerLineStrokeFill) {
        final strokeCol = entry.strokeColor!;
        final strokeArgb = strokeCol.toARGB32();
        final fillArgb = entry.color.toARGB32();
        var lineY = entry.y;
        for (final line in entry.lines) {
          final startX = entry.startXOf(line);
          _entryTintColor = strokeCol;
          _entryTintQuality = quality;
          drawLine(
            canvas,
            cache,
            line,
            entry.font,
            grid,
            paintingStyle: 1,
            strokeWidth: entry.strokeWidth,
            rasterScale: rasterScale,
            startX: startX,
            y: lineY,
            spacing: entry.spacing,
            spriteColor: strokeArgb,
            directPaint: _entryTint,
            foldA: entry.foldA,
            foldB: entry.foldB,
            foldDx: entry.foldDx,
            foldDy: entry.foldDy,
          );
          _entryTintColor = entry.color;
          drawLine(
            canvas,
            cache,
            line,
            entry.font,
            grid,
            paintingStyle: 0,
            strokeWidth: 0.0,
            rasterScale: rasterScale,
            startX: startX,
            y: lineY,
            spacing: entry.spacing,
            spriteColor: fillArgb,
            directPaint: _entryTint,
            foldA: entry.foldA,
            foldB: entry.foldB,
            foldDx: entry.foldDx,
            foldDy: entry.foldDy,
          );
          lineY += entry.lineHeight;
        }
        continue;
      }
      final color = entry.color.toARGB32();
      _entryTintColor = entry.color;
      _entryTintQuality = quality;
      final passStrokeWidth = entry.paintingStyle == 1
          ? entry.strokeWidth
          : 0.0;
      var lineY = entry.y;
      for (final line in entry.lines) {
        drawLine(
          canvas,
          cache,
          line,
          entry.font,
          grid,
          paintingStyle: entry.paintingStyle,
          strokeWidth: passStrokeWidth,
          rasterScale: rasterScale,
          startX: entry.startXOf(line),
          y: lineY,
          spacing: entry.spacing,
          spriteColor: color,
          directPaint: _entryTint,
          foldA: entry.foldA,
          foldB: entry.foldB,
          foldDx: entry.foldDx,
          foldDy: entry.foldDy,
        );
        lineY += entry.lineHeight;
      }
    }
  }

  static void _paintEntryNatively(Canvas canvas, Flut5TextDynamicEntry entry) {
    final List<Paint> foregrounds;
    if (entry.strokeColor != null) {
      _nativeStrokePaint
        ..color = entry.strokeColor!
        ..strokeWidth = entry.strokeWidth;
      _nativeFillPaint.color = entry.color;
      foregrounds = [_nativeStrokePaint, _nativeFillPaint];
    } else if (entry.paintingStyle == 1) {
      _nativeStrokePaint
        ..color = entry.color
        ..strokeWidth = entry.strokeWidth;
      foregrounds = [_nativeStrokePaint];
    } else {
      _nativeFillPaint.color = entry.color;
      foregrounds = [_nativeFillPaint];
    }
    final isFolded =
        entry.foldA != 1 ||
        entry.foldB != 0 ||
        entry.foldDx != 0 ||
        entry.foldDy != 0;
    if (isFolded) {
      _scratchMatrix[0] = entry.foldA;
      _scratchMatrix[1] = entry.foldB;
      _scratchMatrix[4] = -entry.foldB;
      _scratchMatrix[5] = entry.foldA;
      _scratchMatrix[12] = entry.foldDx;
      _scratchMatrix[13] = entry.foldDy;
      canvas.save();
      canvas.transform(_scratchMatrix);
    }
    if (entry.maxWidth == null) {
      paintUnwrappedNatively(
        canvas,
        entry.text,
        entry.font,
        foregrounds: foregrounds,
        x: entry.x,
        y: entry.y,
        spacing: entry.spacing,
        align: entry.textAlign,
        lineHeight: () => entry.lineHeight,
      );
    } else {
      var lineY = entry.y;
      for (final line in entry.lines) {
        if (line.glyphs.isNotEmpty) {
          final startX = entry.startXOf(line);
          for (var p = 0; p < foregrounds.length; p++) {
            paintLineNatively(
              canvas,
              line,
              entry.font,
              foreground: foregrounds[p],
              startX: startX,
              y: lineY,
              spacing: entry.letterSpacing ?? 0,
            );
          }
        }
        lineY += entry.lineHeight;
      }
    }
    if (isFolded) canvas.restore();
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
  final Color? strokeColor,
  required final double foldA,
  required final double foldB,
  required final double foldDx,
  required final double foldDy,

  /// The fold's scale, tracked apart from [foldA] and [foldB] so rounding in
  /// a rotation can't change the density glyphs are rasterized at.
  final double foldScale = 1,
  final Flut5ShadowSpec? shadow,
  final List<FontVariation>? fontVariations,
  final String fontVariationKey = '',
}) {
  late final Flut5GlyphFont font = Flut5GlyphFont(
    family: fontFamily,
    size: fontSize,
    weight: fontWeight,
    style: fontStyle,
    variations: fontVariations,
    variationKey: fontVariationKey,
  );

  /// Spacing applied when composing the glyphs. Wrapped layouts have it
  /// baked in, because it decides their line breaks.
  double get spacing => maxWidth == null ? letterSpacing ?? 0 : 0;

  late final List<Flut5TextLine> lines = _resolveLines();

  List<Flut5TextLine> _resolveLines() {
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

  late final double lineHeight = textLeading != null
      ? fontSize * textLeading!
      : Flut5TextCache.instance.measureLineHeight(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontVariations: fontVariations,
          fontVariationKey: fontVariationKey,
        );

  /// Whether a multi-line outlined+filled entry has tight line spacing where
  /// a later line's stroke can touch an earlier line's fill, requiring per-line
  /// stroke-then-fill ordering.
  late final bool needsPerLineStrokeFill =
      strokeColor != null && lines.length > 1 && lineHeight < fontSize * 1.15;

  /// Where [line]'s pen starts along x, after alignment.
  double startXOf(Flut5TextLine line) {
    if (textAlign == TextAlign.center) {
      return x - line.widthWithSpacing(spacing) / 2;
    }
    if (textAlign == TextAlign.right || textAlign == TextAlign.end) {
      return x - line.widthWithSpacing(spacing);
    }
    return x;
  }

  /// The laid-out block before the fold.
  late final Rect _localBox = _computeLocalBox();

  Rect _computeLocalBox() {
    var left = double.infinity, right = double.negativeInfinity;
    for (final line in lines) {
      final start = startXOf(line);
      final end = start + line.widthWithSpacing(spacing);
      if (start < left) left = start;
      if (end > right) right = end;
    }
    if (left > right) left = right = x;
    return Rect.fromLTRB(left, y, right, y + lines.length * lineHeight);
  }

  Rect _folded(Rect rect) {
    if (foldA == 1 && foldB == 0) return rect.shift(Offset(foldDx, foldDy));
    final x0 = foldA * rect.left - foldB * rect.top + foldDx;
    final y0 = foldB * rect.left + foldA * rect.top + foldDy;
    final x1 = foldA * rect.right - foldB * rect.top + foldDx;
    final y1 = foldB * rect.right + foldA * rect.top + foldDy;
    final x2 = foldA * rect.right - foldB * rect.bottom + foldDx;
    final y2 = foldB * rect.right + foldA * rect.bottom + foldDy;
    final x3 = foldA * rect.left - foldB * rect.bottom + foldDx;
    final y3 = foldB * rect.left + foldA * rect.bottom + foldDy;
    return Rect.fromLTRB(
      math.min(math.min(x0, x1), math.min(x2, x3)),
      math.min(math.min(y0, y1), math.min(y2, y3)),
      math.max(math.max(x0, x1), math.max(x2, x3)),
      math.max(math.max(y0, y1), math.max(y2, y3)),
    );
  }

  late final Rect _layoutBounds = _folded(_localBox);

  late final Rect _inkBounds = _folded(
    flut5TextInkBox(
      _localBox,
      fontSize,
      (paintingStyle == 1 || strokeColor != null) ? strokeWidth : 0,
      shadow,
    ),
  );

  /// The laid-out text block in queue space, for sizing scroll containers.
  Rect layoutBounds() => _layoutBounds;

  /// Everything this entry can paint, shadow included, in queue space.
  Rect inkBounds() => _inkBounds;
}

/// Coalesces consecutive plain `textDynamic` calls — across strings, colours,
/// sizes, translations, rotations, and uniform scales — into batched
/// `Canvas.drawRawAtlas` calls against [Flut5TextCache]'s glyph atlas.
class TextDynamicBatchRenderItem(final List<Flut5TextDynamicEntry> entries)
    extends Flut5RenderItem {
  @override
  late final Rect? bounds = _union((entry) => entry.layoutBounds());

  @override
  late final Rect? inkBounds = _union((entry) => entry.inkBounds());

  Rect? _union(Rect Function(Flut5TextDynamicEntry) boxOf) {
    Rect? union;
    for (var i = 0; i < entries.length; i++) {
      final box = boxOf(entries[i]);
      union = union == null ? box : union.expandToInclude(box);
    }
    return union;
  }

  @override
  bool get keepsCanvasTransform => true;

  @override
  void execute(Canvas canvas) {
    Flut5GlyphAtlasBlitter.drawBatch(canvas, entries);
  }
}
