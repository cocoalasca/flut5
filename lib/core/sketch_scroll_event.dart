import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import '../math/flut5_vector.dart';

/// Normalized Flut5 payload for mouse-wheel / trackpad scroll callbacks.
///
/// Dispatched once per raw `PointerScrollEvent` to [Flut5EventMixin.mouseWheel]
/// (and [Flut5EventMixin.onMouseWheel]). Unlike the per-frame
/// [Flut5WheelSample] used internally by scroll-mode containers, this is *not*
/// accumulated — each event produces one [SketchScrollEvent].
///
/// [location] is the local pointer position inside the canvas where the wheel
/// motion occurred. [scrollDelta] is the per-event scroll delta in logical
/// pixels: positive `y` scrolls down, positive `x` scrolls right.
@immutable
final class SketchScrollEvent {
  final Offset location;
  final Flut5Vector scrollDelta;
  final PointerScrollEvent rawEvent;

  const SketchScrollEvent({
    required this.location,
    required this.scrollDelta,
    required this.rawEvent,
  });
}
