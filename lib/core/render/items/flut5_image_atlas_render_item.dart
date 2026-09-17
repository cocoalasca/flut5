import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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
  required final Rect _bounds,
}) extends Flut5RenderItem {
  /// Shared blit paint, reconfigured in place each draw — same pattern as
  /// [ImageRenderItem], so a frame full of sprite runs allocates no [Paint]s.
  static final Paint _blitPaint = Paint()..filterQuality = FilterQuality.medium;

  /// Number of blits merged into this item. Always >= 2 — the queue emits a
  /// drawImageRect item for a run of one (with its own transform if needed).
  int get spriteCount => transforms.length ~/ 4;

  /// Union of every sprite's destination rect, accumulated as the run was
  /// built rather than recomputed from the float32 buffers.
  @override
  Rect? get bounds => _bounds;

  @override
  void execute(Canvas canvas) {
    _blitPaint.blendMode = blendMode;
    // colors/blendMode null: per-sprite tinting is unused, and drawRawAtlas
    // asserts the two travel together. cullRect null: the queue does not clip
    // the run, so there is no tighter hint to give than the atlas itself.
    if (!preserveRotatedEdges) {
      canvas.drawRawAtlas(
        image,
        transforms,
        rects,
        null,
        null,
        null,
        _blitPaint,
      );
      return;
    }
    // Queue data can still coalesce across rotations, but preserve the
    // primitive renderer for rotated quads. Only axis-aligned runs use atlas.
    final matrix = Float64List.fromList([
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
    ]);
    var start = 0;
    for (var i = 0; i < transforms.length; i += 4) {
      if (transforms[i + 1] == 0) continue;
      if (start < i) {
        canvas.drawRawAtlas(
          image,
          Float32List.sublistView(transforms, start, i),
          Float32List.sublistView(rects, start, i),
          null,
          null,
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
      canvas.drawRawAtlas(
        image,
        Float32List.sublistView(transforms, start),
        Float32List.sublistView(rects, start),
        null,
        null,
        null,
        _blitPaint,
      );
    }
  }
}
