import 'package:flutter/material.dart';

import 'render/flut5_render_queue.dart';

/// Pixelation scopes: everything drawn between [beginPixelate] and
/// [endPixelate] is shown as square blocks of one averaged colour each.
mixin Flut5Pixelate {
  /// The render queue, provided by [Flut5Engine].
  Flut5RenderQueue get renderQueue;

  /// Canvas size in logical pixels, provided by [Flut5Engine].
  double get width;
  double get height;

  /// The explicit-batch path, provided by [Flut5Engine].
  Path? get batchPath;

  /// Starts pixelating: everything drawn until the matching [endPixelate] is
  /// shown as [blockSize]×[blockSize] blocks, in logical pixels, each the
  /// average colour of what was drawn there.
  ///
  /// The scope is pixelated as one picture, so shapes inside it still batch
  /// and overlapping shapes share their blocks. Blocks line up with the
  /// canvas origin whatever transform is active, so separate scopes share
  /// one grid. A [blockSize] below `1` draws the scope unpixelated.
  ///
  /// Like [push]/[pop], the scope keeps its transforms to itself:
  /// [endPixelate] restores the transform that was active here. Scopes nest.
  /// A scope left open is closed at the end of `draw()`, with a warning.
  ///
  /// ```dart
  /// beginPixelate(8);
  /// circle(100, 100, 80);
  /// text('retro', 60, 200);
  /// endPixelate();
  /// ```
  void beginPixelate(double blockSize) {
    if (batchPath != null) {
      throw FlutterError(
        'beginPixelate() cannot be called inside beginBatch/endBatch',
      );
    }
    renderQueue.beginPixelate(blockSize, width, height);
  }

  /// Ends the innermost [beginPixelate] scope.
  void endPixelate() {
    if (batchPath != null) {
      throw FlutterError(
        'endPixelate() cannot be called inside beginBatch/endBatch',
      );
    }
    renderQueue.endPixelate();
  }
}
