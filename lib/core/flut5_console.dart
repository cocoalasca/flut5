import 'package:flutter/foundation.dart';

/// Deferred warning queue for the Flut5 framework.
///
/// Instead of printing warnings inline (which floods the console when called
/// inside [draw]), messages are queued with [printLater] and printed once per
/// frame via [flush]. Duplicate messages are collapsed into a single line with
/// a call count.
///
/// [flush] is called automatically by the framework at the end of each paint
/// cycle and after [setup]. You do not need to call it manually.
///
/// Accessible from anywhere — no engine reference needed:
/// ```dart
/// Flut5Console.printLater('strokeWeight not set, using default');
/// // At end of frame → [flut5] strokeWeight not set, using default (×60)
/// ```
/// Global shorthand for [Flut5Console.printLater].
///
/// Lets you queue a deferred warning from anywhere without referencing
/// [Flut5Console]:
/// ```dart
/// printLater('strokeWeight not set, using default');
/// ```
void printLater(String message) => Flut5Console.printLater(message);

class Flut5Console._() {
  static final Map<String, int> _queue = {};

  /// Queues [message] to be printed at the end of the current frame.
  /// Calling the same message multiple times increments its count instead
  /// of printing a duplicate line.
  static void printLater(String message) {
    _queue[message] = (_queue[message] ?? 0) + 1;
  }

  /// Prints all queued messages and clears the queue.
  /// Called automatically by the framework — no need to call this manually.
  static void flush() {
    if (_queue.isEmpty) return;
    for (final entry in _queue.entries) {
      if (entry.value == 1) {
        debugPrint('[flut5] ${entry.key}');
      } else {
        debugPrint('[flut5] ${entry.key} (${entry.value} times called)');
      }
    }
    _queue.clear();
  }
}
