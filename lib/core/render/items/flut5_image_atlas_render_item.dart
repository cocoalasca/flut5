import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../flut5_render_item.dart';

/// A run of blits sampling the same bitmap. Compatible axis-aligned sprites
/// use [Canvas.drawRawAtlas]; per-sprite rotations can keep individual image
/// draws to preserve edge antialiasing via [preserveRotatedEdges].
///
/// `Flut5RenderQueue.appendImage` coalesces consecutive `image()` calls into
/// this item whenever they share a source [ui.Image] and each one scales
/// proportionally. An axis-aligned mosaic collapses to a single canvas call;
/// measured on a 60×40 tile grid, display-list recording drops from ~486µs to
/// ~25µs.
///
/// Layout of the two buffers, 4 floats per sprite (the raw form
/// [Canvas.drawAtlas] packs internally):
/// * [transforms] — `scos, ssin, tx, ty`: scale times cosine/sine of the
///   sprite rotation, followed by its translated origin.
/// * [rects] — `left, top, right, bottom` of the source sub-rectangle.
///
/// Coordinates are float32 here where a lone [ImageRenderItem] keeps doubles.
/// The precision floor is the same one the engine already lives with — Skia
/// path geometry is float32 throughout — and at a scale factor near 1 the
/// worst-case placement error is well under a thousandth of a pixel.
class ImageAtlasRenderItem({
  /// The single bitmap every sprite in this run samples.
  required final ui.Image image,

  /// Packed `scos, ssin, tx, ty` per sprite.
  required final Float32List transforms,

  /// Packed `left, top, right, bottom` source rect per sprite.
  required final Float32List rects,

  /// Preserve drawImageRect edge antialiasing for sprites with per-sprite
  /// rotation. drawRawAtlas does not antialias those quad edges equivalently.
  /// Existing callers default to the original all-atlas rendering.
  final bool preserveRotatedEdges = false,

  /// Compositing mode captured from the engine when the run opened. A change
  /// mid-run closes the run, so one mode covers the whole batch.
  required final BlendMode blendMode,

  /// Optional per-sprite ARGB32 multiplicative tints (one int per sprite),
  /// allowing differently-tinted sprites of the same image to stay in a single
  /// [Canvas.drawRawAtlas] call. `null` when no sprite in the run is tinted.
  final Int32List? colors,

  /// Sampling quality for this bitmap run.
  final FilterQuality filterQuality = FilterQuality.medium,
  required final Rect _bounds,
}) extends Flut5RenderItem {
  /// Shared blit paint, reconfigured in place each draw — same pattern as
  /// [ImageRenderItem], so a frame full of sprite runs allocates no [Paint]s.
  static final Paint _blitPaint = Paint()..filterQuality = FilterQuality.medium;

  /// Per-sprite transform for rotated sprites. [Canvas.transform] copies it,
  /// so one buffer serves every sprite; only the four linear entries and the
  /// translation are ever written.
  static final Float64List _matrix = Float64List(16)
    ..[10] = 1
    ..[15] = 1;

  /// Bounded LRU cache of 1px transparent-padded copies for images drawn as
  /// rotated full-image atlas runs. A 1px transparent border lets
  /// [Canvas.drawRawAtlas] antialias all four rotated quad edges in the GPU
  /// texture sampler in a single draw call instead of falling back to one
  /// `drawImageRect` per sprite.
  static const int _maxPaddedExtent = 512;
  static const int _maxPaddedEntries = 32;
  static final LinkedHashMap<ui.Image, ui.Image> _paddedCache =
      LinkedHashMap<ui.Image, ui.Image>.identity();
  static Float32List _paddedTransforms = Float32List(64 * 4);
  static Float32List _paddedRects = Float32List(64 * 4);
  static final Paint _padCopyPaint = Paint()
    ..blendMode = BlendMode.src
    ..filterQuality = FilterQuality.none
    ..isAntiAlias = false;

  /// Diagnostic counter incremented whenever a rotated run takes the 1px
  /// transparent-padded single-`drawRawAtlas` fast path.
  @visibleForTesting
  static int debugPaddedAtlasDraws = 0;

  /// Releases the cached 1px-padded copy for [source] when [source] is
  /// disposed or replaced. Called by `Flut5ImageHandles`.
  static void evictPadded(ui.Image source) {
    _paddedCache.remove(source)?.dispose();
  }

  /// Clears all cached 1px-padded atlas copies.
  @visibleForTesting
  static void clearPaddedCache() {
    for (final padded in _paddedCache.values) {
      padded.dispose();
    }
    _paddedCache.clear();
  }

  static bool _isTransparentIdentityBlend(BlendMode mode) =>
      mode == BlendMode.srcOver ||
      mode == BlendMode.plus ||
      mode == BlendMode.multiply ||
      mode == BlendMode.screen ||
      mode == BlendMode.lighten;

  static ui.Image _paddedCopy(ui.Image source) {
    final hit = _paddedCache.remove(source);
    if (hit != null) {
      _paddedCache[source] = hit;
      return hit;
    }
    if (_paddedCache.length >= _maxPaddedEntries) {
      final oldestKey = _paddedCache.keys.first;
      _paddedCache.remove(oldestKey)?.dispose();
    }
    final w = source.width;
    final h = source.height;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImage(source, const Offset(1, 1), _padCopyPaint);
    final picture = recorder.endRecording();
    final padded = picture.toImageSync(w + 2, h + 2);
    picture.dispose();
    _paddedCache[source] = padded;
    return padded;
  }

  static void _ensurePaddedCapacity(int floatCount) {
    if (_paddedTransforms.length >= floatCount) return;
    int len = _paddedTransforms.length * 2;
    while (len < floatCount) {
      len *= 2;
    }
    _paddedTransforms = Float32List(len);
    _paddedRects = Float32List(len);
  }

  /// Attempts to draw the entire rotated run in one [Canvas.drawRawAtlas] call
  /// using a cached 1px transparent-padded copy of [image].
  ///
  /// Returns `true` when every sprite samples the full source bitmap and
  /// [blendMode] leaves transparent border texels invisible. Cropped sprites
  /// fall back to individual `drawImageRect` draws so neighboring image texels
  /// can never bleed into the cropped edge.
  bool _tryDrawPaddedRotatedAtlas(
    Canvas canvas,
    Int32List? tintColors,
    BlendMode? tintMode,
  ) {
    if (filterQuality == FilterQuality.none ||
        !_isTransparentIdentityBlend(blendMode)) {
      return false;
    }
    final w = image.width;
    final h = image.height;
    if (w <= 0 || h <= 0 || w > _maxPaddedExtent || h > _maxPaddedExtent) {
      return false;
    }
    final fw = w.toDouble();
    final fh = h.toDouble();
    final len = transforms.length;
    var hasRotated = false;
    for (var i = 0; i < len; i += 4) {
      if (rects[i] != 0.0 ||
          rects[i + 1] != 0.0 ||
          rects[i + 2] != fw ||
          rects[i + 3] != fh) {
        return false;
      }
      final scos = transforms[i];
      final ssin = transforms[i + 1];
      if (ssin != 0.0) {
        hasRotated = true;
        // 1px transparent padding matches 1-screen-pixel geometric edge AA
        // only when 1 source texel ≈ 1 screen pixel (|scale| ≈ 1). Upscaled
        // opaque-edged sprites would soften across `scale` screen pixels, and
        // downscaled sprites would mip-bleed the transparent border — keep
        // exact drawImageRect AA for those.
        final scaleSq = scos * scos + ssin * ssin;
        if (scaleSq < 0.96 || scaleSq > 1.04) {
          return false;
        }
      }
    }
    if (!hasRotated) return false;

    final padded = _paddedCopy(image);
    _ensurePaddedCapacity(len);
    final pw = (w + 2).toDouble();
    final ph = (h + 2).toDouble();
    final outT = _paddedTransforms;
    final outR = _paddedRects;
    for (var i = 0; i < len; i += 4) {
      final scos = transforms[i];
      final ssin = transforms[i + 1];
      outT[i] = scos;
      outT[i + 1] = ssin;
      outT[i + 2] = transforms[i + 2] - scos + ssin;
      outT[i + 3] = transforms[i + 3] - ssin - scos;
      outR[i] = 0.0;
      outR[i + 1] = 0.0;
      outR[i + 2] = pw;
      outR[i + 3] = ph;
    }
    debugPaddedAtlasDraws++;
    canvas.drawRawAtlas(
      padded,
      Float32List.sublistView(outT, 0, len),
      Float32List.sublistView(outR, 0, len),
      tintColors,
      tintMode,
      null,
      _blitPaint,
    );
    return true;
  }

  /// Number of blits merged into this item. Always >= 2 — the queue emits a
  /// drawImageRect item for a run of one (with its own transform if needed).
  int get spriteCount => transforms.length ~/ 4;

  /// Union of every sprite's destination rect, accumulated as the run was
  /// built rather than recomputed from the float32 buffers.
  @override
  Rect? get bounds => _bounds;

  @override
  void execute(Canvas canvas) {
    final tintColors = colors;
    final tintMode = tintColors == null ? null : BlendMode.modulate;
    _blitPaint
      ..blendMode = blendMode
      ..filterQuality = filterQuality
      ..colorFilter = null;
    // cullRect null: the queue does not clip the run, so there is no tighter
    // hint to give than the atlas itself.
    if (!preserveRotatedEdges) {
      canvas.drawRawAtlas(
        image,
        transforms,
        rects,
        tintColors,
        tintMode,
        null,
        _blitPaint,
      );
      return;
    }
    if (_tryDrawPaddedRotatedAtlas(canvas, tintColors, tintMode)) {
      return;
    }
    // Queue data can still coalesce across rotations, but preserve the
    // primitive renderer for rotated quads. Only axis-aligned runs use atlas.
    final matrix = _matrix;
    var start = 0;
    for (var i = 0; i < transforms.length; i += 4) {
      if (transforms[i + 1] == 0) continue;
      if (start < i) {
        _blitPaint.colorFilter = null;
        canvas.drawRawAtlas(
          image,
          Float32List.sublistView(transforms, start, i),
          Float32List.sublistView(rects, start, i),
          tintColors == null
              ? null
              : Int32List.sublistView(tintColors, start >> 2, i >> 2),
          tintMode,
          null,
          _blitPaint,
        );
      }
      final scos = transforms[i], ssin = transforms[i + 1];
      matrix[0] = scos;
      matrix[1] = ssin;
      matrix[4] = -ssin;
      matrix[5] = scos;
      matrix[12] = transforms[i + 2];
      matrix[13] = transforms[i + 3];
      final src = Rect.fromLTRB(
        rects[i],
        rects[i + 1],
        rects[i + 2],
        rects[i + 3],
      );
      final argb = tintColors?[i >> 2];
      _blitPaint.colorFilter = argb == null || argb == 0xFFFFFFFF
          ? null
          : ColorFilter.mode(Color(argb), BlendMode.modulate);
      canvas.save();
      canvas.transform(matrix);
      canvas.drawImageRect(
        image,
        src,
        Rect.fromLTWH(0, 0, src.width, src.height),
        _blitPaint,
      );
      canvas.restore();
      start = i + 4;
    }
    if (start < transforms.length) {
      _blitPaint.colorFilter = null;
      canvas.drawRawAtlas(
        image,
        Float32List.sublistView(transforms, start),
        Float32List.sublistView(rects, start),
        tintColors == null
            ? null
            : Int32List.sublistView(tintColors, start >> 2),
        tintMode,
        null,
        _blitPaint,
      );
    }
  }
}
