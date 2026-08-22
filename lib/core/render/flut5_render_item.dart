import 'package:flutter/material.dart';

/// Base class for all drawing commands stored in the Flut5 render queue.
///
/// Contains the data and state necessary to correctly draw the object
/// later in the render pass when the queue is executed.
abstract class Flut5RenderItem {
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
}
