import 'package:flutter/widgets.dart';

import 'flut5_color_resolver.dart';
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
  /// Pass a [palette] to limit the blocks to its colours: each block takes
  /// the palette colour nearest its average, judged by eye (in the OKLab
  /// colour space) rather than by raw RGB distance. Every block comes
  /// out solid in an exact palette colour, or empty: a block counts as drawn
  /// when what's drawn in it covers at least half of it, so shapes keep
  /// their size and their edges stay sharp wherever the background is drawn.
  /// A shape under half opacity with nothing behind it inside the scope
  /// falls below that and is left out. A translucent palette colour still
  /// thins the blocks that take it. Without a palette, or with an empty one,
  /// blocks keep their average colour and coverage. Matching runs once per
  /// block, so a long palette costs little.
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
  ///
  /// // Four-shade handheld look (Color objects, hex strings, or RGB lists).
  /// beginPixelate(4, ['#0F380F', '#306230', '#8BAC0F', '#9BBC0F']);
  /// background(Colors.white);
  /// circle(100, 100, 80);
  /// endPixelate();
  /// ```
  void beginPixelate(double blockSize, [List<Object>? palette]) {
    if (batchPath != null) {
      throw FlutterError(
        'beginPixelate() cannot be called inside beginBatch/endBatch',
      );
    }
    List<Color>? resolvedPalette;
    if (palette != null) {
      if (palette is List<Color>) {
        resolvedPalette = palette;
      } else {
        resolvedPalette = List<Color>.generate(palette.length, (i) {
          final resolved = flut5TryResolveSingleColor(palette[i]);
          if (resolved == null) {
            throw ArgumentError.value(
              palette[i],
              'palette[$i]',
              'beginPixelate() palette entries must be a Color, hex/rgb '
                  'String, grayscale num, or 1–4 element List<num>',
            );
          }
          return resolved;
        }, growable: false);
      }
    }
    renderQueue.beginPixelate(
      blockSize,
      width,
      height,
      palette: resolvedPalette,
    );
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
