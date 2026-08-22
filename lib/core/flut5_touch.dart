import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;

import '../math/flut5_vector.dart';

/// One active pointer (finger, mouse button, or stylus) currently pressed
/// on the canvas. Used by [Flut5Engine.touches] to support multi-touch
/// interactions, mirroring p5.js's `touches` array.
///
/// [id] is a stable per-pointer identifier provided by Flutter — it stays
/// constant across move events for the same finger and is unique while the
/// pointer remains pressed.
///
/// [x] / [y] are the current local canvas coordinates.
/// [px] / [py] are the coordinates from the previous move event for this
/// pointer (equal to [x] / [y] on the initial down event).
///
/// [velocity] is the average velocity (px / move sample) over the last
/// `avgMouseFrames` samples for this specific pointer. It is the zero
/// vector on the initial down event (no history yet).
///
/// [kind] is the device that produced the pointer (touch, mouse, stylus, …).
/// Scroll-mode containers use it to tell touch-drag from mouse-drag so the
/// `containerOverscrollInput` mode can restrict mouse input without affecting
/// touch on mobile. Defaults to [PointerDeviceKind.touch].
@immutable
final class Flut5Touch {
  final int id;
  final double x;
  final double y;
  final double px;
  final double py;
  final Flut5Vector velocity;
  final PointerDeviceKind kind;

  Flut5Touch({
    required this.id,
    required this.x,
    required this.y,
    required this.px,
    required this.py,
    Flut5Vector? velocity,
    this.kind = PointerDeviceKind.touch,
  }) : velocity = velocity ?? Flut5Vector.zero();
}
