import 'package:flutter/foundation.dart';

/// Accumulated mouse-wheel / trackpad scroll for the current frame.
///
/// Wheel (`PointerScrollEvent`) signals arrive asynchronously between frames.
/// [Flut5Event] sums their deltas into a single sample and records the
/// canvas-local position the motion happened at, so scroll-mode containers can
/// decide whether the cursor was over them. The sample lives for exactly one
/// frame: the painter clears it right after `draw()`.
///
/// [dx] / [dy] are the summed scroll deltas in logical pixels (positive `dy`
/// means scrolling down, positive `dx` means scrolling right — the raw
/// `PointerScrollEvent.scrollDelta` convention). [x] / [y] are the local canvas
/// coordinates of the most recent wheel event in the frame.
///
/// Because the buffer is frame-cleared rather than consumed per reader, two
/// stacked scroll containers under the same cursor will both receive the same
/// sample — an accepted edge case.
@immutable
final class const Flut5WheelSample({
  required final double dx,
  required final double dy,
  required final double x,
  required final double y,
});
