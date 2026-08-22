import 'package:flutter/material.dart';

import '../math/flut5_vector.dart';

/// Normalized Flut5 pointer payload used by all sketch pointer callbacks.
///
/// [location] is the current local pointer position inside the canvas.
/// [plocation] is the previous local pointer position seen by Flut5, which is
/// especially useful for move and drag interactions.
///
/// [velocity] is the average pointer velocity (px / frame) over the last
/// `avgMouseFrames` move samples for this pointer, expressed as a 2D
/// [Flut5Vector]. It is populated for move and drag events; it is `null` on
/// down, up, and other non-positional events.
@immutable
final class SketchPointerEvent {
  final Offset location;
  final Offset plocation;
  final PointerEvent rawEvent;
  final Flut5Vector? velocity;

  const SketchPointerEvent({
    required this.location,
    required this.plocation,
    required this.rawEvent,
    this.velocity,
  });
}
