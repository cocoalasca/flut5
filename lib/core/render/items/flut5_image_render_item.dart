import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../flut5_render_item.dart';
import '../../flut5_shadow.dart';

/// Blits [src] out of a decoded bitmap into [dst].
///
/// A bitmap is a GPU texture op, so — like text — it cannot merge into the
/// queue's shared [Path] batch. It is queued as its own item, with the
/// folded translate already baked into [dst] by
/// `Flut5RenderQueue.appendImage`, so surrounding shapes keep batching.
class ImageRenderItem({
  /// The bitmap to sample. Owned by the `Flut5Image` that queued it, which
  /// checks it is not disposed before enqueuing.
  required final ui.Image image,

  /// Source rectangle in image pixels.
  required final Rect src,

  /// Destination rectangle in canvas coordinates.
  required final Rect dst,

  /// Compositing mode captured from the engine at queue time, so `blendMode()`
  /// applies to images exactly as it does to shapes and text.
  required final BlendMode blendMode,

  /// Drop shadow cast beneath the image, or `null` for none.
  final Flut5ShadowSpec? shadow,
}) extends Flut5RenderItem {
  /// Shared blit paint, reconfigured in place each draw — the same pattern as
  /// `TextRenderItem`'s tint paint, so a frame full of images allocates no
  /// [Paint]s.
  ///
  /// [FilterQuality.medium] matches Flutter's own `paintImage` default: it
  /// keeps a downscaled photo from aliasing, and costs nothing extra at 1:1.
  static final Paint _blitPaint = Paint()..filterQuality = FilterQuality.medium;

  @override
  Rect? get bounds => dst;

  @override
  void execute(Canvas canvas) {
    final s = shadow;
    if (s != null) {
      // The image's own alpha is the silhouette: recoloured, spread and
      // blurred by the shared raster-tint pipeline, so a PNG with
      // transparency casts a shadow shaped like its content rather than a
      // rectangular blob.
      canvas.drawImageRect(image, src, dst.shift(s.offset), s.imageTintPaint);
    }
    _blitPaint.blendMode = blendMode;
    canvas.drawImageRect(image, src, dst, _blitPaint);
  }
}
