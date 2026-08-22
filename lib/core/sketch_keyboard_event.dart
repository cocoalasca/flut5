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
final class SketchKeyboardEvent {
  final String key;
  final int keyCode;
  final KeyEvent rawEvent;
  final LogicalKeyboardKey logicalKey;
  final PhysicalKeyboardKey physicalKey;
  final String? character;
  final bool repeat;

  const SketchKeyboardEvent({
    required this.key,
    required this.keyCode,
    required this.rawEvent,
    required this.logicalKey,
    required this.physicalKey,
    required this.character,
    required this.repeat,
  });
}
