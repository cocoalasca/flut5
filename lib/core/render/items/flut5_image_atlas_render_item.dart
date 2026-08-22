import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../flut5_render_item.dart';

/// A run of blits that all sample the same bitmap, drawn in one
/// [Canvas.drawRawAtlas] call instead of one `drawImageRect` each.
///
/// `Flut5RenderQueue.appendImage` coalesces consecutive `image()` calls into
/// this item whenever they share a source [ui.Image] and each one scales
/// proportionally. A mosaic or particle field collapses to a single GPU call;
/// measured on a 60×40 tile grid, display-list recording drops from ~486µs to
/// ~25µs.
///
/// Layout of the two buffers, 4 floats per sprite (the raw form
/// [Canvas.drawAtlas] packs internally):
/// * [transforms] — `scos, ssin, tx, ty`. `scos` is the uniform scale and
///   `ssin` is always `0`: Flut5 rotation lives on the canvas transform, which
///   is shared by every sprite in a run, so no per-sprite rotation is needed.
/// * [rects] — `left, top, right, bottom` of the source sub-rectangle.
///
/// Coordinates are float32 here where a lone [ImageRenderItem] keeps doubles.
/// The precision floor is the same one the engine already lives with — Skia
/// path geometry is float32 throughout — and at a scale factor near 1 the
/// worst-case placement error is well under a thousandth of a pixel.
class ImageAtlasRenderItem extends Flut5RenderItem {
  /// Shared blit paint, reconfigured in place each draw — same pattern as
  /// [ImageRenderItem], so a frame full of sprite runs allocates no [Paint]s.
  static final Paint _blitPaint = Paint()..filterQuality = FilterQuality.medium;

  /// The single bitmap every sprite in this run samples.
  final ui.Image image;

  /// Packed `scos, ssin, tx, ty` per sprite.
  final Float32List transforms;

  /// Packed `left, top, right, bottom` source rect per sprite.
  final Float32List rects;

  /// Compositing mode captured from the engine when the run opened. A change
  /// mid-run closes the run, so one mode covers the whole batch.
  final BlendMode blendMode;

  final Rect _bounds;

  ImageAtlasRenderItem({
    required this.image,
    required this.transforms,
    required this.rects,
    required this.blendMode,
    required Rect bounds,
  }) : _bounds = bounds;

  /// Number of blits merged into this item. Always >= 2 — the queue emits a
  /// plain [ImageRenderItem] for a run of one.
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
    canvas.drawRawAtlas(image, transforms, rects, null, null, null, _blitPaint);
  }
}
