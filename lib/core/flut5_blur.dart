import 'package:flutter/material.dart';

import 'render/flut5_render_queue.dart';

/// Blur for everything drawn: shapes, custom shapes, lines, points, text and
/// images — per draw with [blur]/[noBlur], or for a group with
/// [beginBlur]/[endBlur].
///
/// Like [fill]/[shadow], [blur] is persistent engine state: once called,
/// every subsequent draw is blurred until [noBlur] is called. When inactive
/// there is zero added cost — shapes batch exactly as before.
mixin Flut5Blur {
  /// The render queue, provided by [Flut5Engine].
  Flut5RenderQueue get renderQueue;

  /// The explicit-batch path, provided by [Flut5Engine].
  Path? get batchPath;

  /// Blurs everything drawn after this call by a Gaussian of standard
  /// deviation [radius], in logical pixels.
  ///
  /// [radius] means what it means in CSS `filter: blur()` and Canvas 2D's
  /// `ctx.filter`, so values copied from either look the same here. That is
  /// softer than the same number given to [shadow], whose blur follows CSS
  /// `box-shadow` (roughly half the sigma). `0` turns blur off, like
  /// [noBlur].
  ///
  /// Each draw is blurred on its own, together with its stroke and shadow.
  /// Blurred draws therefore never auto-batch. A shape with a plain fill and
  /// no stroke is cheap to blur; anything else (strokes, lines, points,
  /// gradients, shadows, text, images) costs an offscreen layer per draw —
  /// to blur many such shapes as one, use [beginBlur]/[endBlur]. Like stroke
  /// weight, the radius scales with `scale()`. `background()` is never
  /// blurred. The layer is Flutter's own blur, with its Impeller limits —
  /// see [beginBlur].
  ///
  /// ```dart
  /// blur(4);
  /// circle(100, 100, 80); // soft-edged
  /// noBlur();
  /// circle(200, 100, 80); // sharp again
  /// ```
  void blur(double radius) => renderQueue.setBlurState(radius);

  /// Turns blur off. Subsequent draws are sharp and resume batching.
  void noBlur() => renderQueue.setBlurState(0);

  /// Starts a blur group: everything drawn until the matching [endBlur] is
  /// blurred together, as one picture, by [radius] (the same CSS
  /// `filter: blur()` value as [blur]).
  ///
  /// Unlike [blur], which blurs each draw on its own, the group is drawn
  /// first and blurred once — like CSS `filter` on a container — so where
  /// shapes overlap you see the blur of the combined picture. Shapes inside
  /// still batch, and the whole group costs one offscreen layer. A
  /// `background()` inside the group is blurred with it; its edges fade at
  /// the canvas border. `0` draws the group sharp.
  ///
  /// The group uses Flutter's built-in layer blur, the same one as the
  /// `ImageFiltered` widget. On Impeller it trims the faint outer edge of
  /// the halo and leaves a blur under about one device pixel sharp; this
  /// includes a small radius inside a `beginPixelate()` scope, where the
  /// radius shrinks by the block size. Skia draws an exact Gaussian.
  ///
  /// Like [push]/[pop], the group keeps its transforms to itself: [endBlur]
  /// restores the transform that was active here. Groups nest, also with
  /// `beginPixelate()` scopes, but cannot cross them. A group left open is
  /// closed at the end of `draw()`, with a warning.
  ///
  /// ```dart
  /// beginBlur(6);
  /// for (final star in stars) circle(star.x, star.y, 3); // one batch
  /// endBlur();
  /// ```
  void beginBlur(double radius) {
    if (batchPath != null) {
      throw FlutterError(
        'beginBlur() cannot be called inside beginBatch/endBatch',
      );
    }
    renderQueue.beginBlur(radius);
  }

  /// Ends the innermost [beginBlur] group.
  void endBlur() {
    if (batchPath != null) {
      throw FlutterError(
        'endBlur() cannot be called inside beginBatch/endBatch',
      );
    }
    renderQueue.endBlur();
  }
}
