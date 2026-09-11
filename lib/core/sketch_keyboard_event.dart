import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Normalized Flut5 keyboard payload used by sketch keyboard callbacks.
///
/// [key] follows the p5-style idea of the most useful text for the key:
/// printable key presses use the produced character, while special keys use
/// Flutter's logical key label such as `Enter`, `Escape`, or `Arrow Left`.
///
/// [keyCode] is p5-inspired: printable ASCII keys use their uppercase code
/// unit and common control/navigation keys use their JavaScript keyCode value.
@immutable
final class const SketchKeyboardEvent({
  required final String key,
  required final int keyCode,
  required final KeyEvent rawEvent,
  required final LogicalKeyboardKey logicalKey,
  required final PhysicalKeyboardKey physicalKey,
  required final String? character,
  required final bool repeat,
});
