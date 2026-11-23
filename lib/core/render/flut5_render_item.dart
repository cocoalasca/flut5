import 'package:flutter/widgets.dart';

/// Base class for all drawing commands stored in the Flut5 render queue.
///
/// Contains the data and state necessary to correctly draw the object
/// later in the render pass when the queue is executed.
abstract class Flut5RenderItem() {
  /// Executes the deferred drawing command onto the provided [Canvas].
  void execute(Canvas canvas);

  /// Axis-aligned bounding box of this item's drawn geometry, expressed in the
  /// item's *local* coordinate space (before any queued transform is applied).
  ///
  /// Returns `null` for items that draw no measurable content (transforms,
  /// clips, full-canvas backgrounds). Used by
  /// `Flut5RenderQueue.contentBoundsFrom` to size a scroll-mode container's
  /// content. Stroke width is intentionally ignored — the small inflation is
  /// not worth the per-item cost.
  Rect? get bounds => null;

  /// Everything this item paints, in its local coordinates, for items whose
  /// paint can't be worked out from [bounds] — text, whose glyphs reach past
  /// its layout box. `null` for every other item. Read through
  /// `flut5PaintBounds`, which handles those.
  Rect? get inkBounds => null;

  /// Whether the canvas is back on the transform it had once [execute]
  /// returns, so what a replay read from it still holds for the next item.
  /// Off by default: an item that says nothing is assumed to move it.
  bool get keepsCanvasTransform => false;
}
