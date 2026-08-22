// p5-style global constants (ARROW, HAND, ...) use SCREAMING_CASE on purpose
// for parity with the p5.js API.
// ignore_for_file: constant_identifier_names

import 'package:flutter/material.dart';

/// p5-style cursor types accepted by [Flut5Cursor.cursor].
enum Flut5CursorType { arrow, cross, hand, move, text, wait }

// p5-style global constants — mirror `cursor(HAND)` / `cursor(ARROW)` usage.
const Flut5CursorType ARROW = .arrow;
const Flut5CursorType CROSS = .cross;
const Flut5CursorType HAND = .hand;
const Flut5CursorType MOVE = .move;
const Flut5CursorType TEXT = .text;
const Flut5CursorType WAIT = .wait;

/// Cursor state for the sketch canvas.
///
/// Mirrors p5.js's `cursor()` / `noCursor()`. The active cursor lives in
/// [cursorNotifier]; [Flut5Canvas] listens to it and updates the [MouseRegion]
/// wrapping the drawing surface.
///
/// ```dart
/// cursor(HAND);
/// cursor(Flut5CursorType.cross);
/// cursor('not-allowed');
/// cursor(SystemMouseCursors.grab); // raw Flutter cursor also accepted
/// noCursor();
/// ```
mixin Flut5Cursor {
  /// Observable current cursor. Read by [Flut5Canvas] to drive a [MouseRegion].
  final ValueNotifier<MouseCursor> cursorNotifier = ValueNotifier(
    SystemMouseCursors.basic,
  );

  /// Current cursor (read-only convenience).
  MouseCursor get currentCursor => cursorNotifier.value;

  /// Sets the cursor over the sketch canvas.
  ///
  /// Accepts:
  /// * a [Flut5CursorType] (or the top-level [ARROW] / [HAND] / … constants),
  /// * a CSS-style string (`'help'`, `'wait'`, `'crosshair'`, `'not-allowed'`,
  ///   `'zoom-in'`, `'zoom-out'`, `'grab'`, `'progress'`, …),
  /// * any [MouseCursor] for full Flutter control.
  ///
  /// Unknown inputs fall back to [SystemMouseCursors.basic].
  void cursor([Object type = Flut5CursorType.arrow]) {
    cursorNotifier.value = _resolveCursor(type);
  }

  /// Hides the cursor over the sketch canvas. Equivalent to p5's `noCursor()`.
  void noCursor() {
    cursorNotifier.value = SystemMouseCursors.none;
  }

  MouseCursor _resolveCursor(Object input) {
    if (input is MouseCursor) return input;
    if (input is Flut5CursorType) {
      switch (input) {
        case .arrow:
          return SystemMouseCursors.basic;
        case .cross:
          return SystemMouseCursors.precise;
        case .hand:
          return SystemMouseCursors.click;
        case .move:
          return SystemMouseCursors.move;
        case .text:
          return SystemMouseCursors.text;
        case .wait:
          return SystemMouseCursors.wait;
      }
    }
    if (input is String) {
      switch (input.toLowerCase()) {
        case 'arrow':
        case 'default':
        case 'basic':
          return SystemMouseCursors.basic;
        case 'cross':
        case 'crosshair':
        case 'precise':
          return SystemMouseCursors.precise;
        case 'hand':
        case 'pointer':
        case 'click':
          return SystemMouseCursors.click;
        case 'grab':
          return SystemMouseCursors.grab;
        case 'grabbing':
          return SystemMouseCursors.grabbing;
        case 'move':
        case 'all-scroll':
          return SystemMouseCursors.move;
        case 'text':
          return SystemMouseCursors.text;
        case 'wait':
          return SystemMouseCursors.wait;
        case 'progress':
          return SystemMouseCursors.progress;
        case 'help':
          return SystemMouseCursors.help;
        case 'not-allowed':
        case 'no-drop':
        case 'forbidden':
          return SystemMouseCursors.forbidden;
        case 'zoom-in':
        case 'zoomin':
          return SystemMouseCursors.zoomIn;
        case 'zoom-out':
        case 'zoomout':
          return SystemMouseCursors.zoomOut;
        case 'resize-up-down':
        case 'ns-resize':
          return SystemMouseCursors.resizeUpDown;
        case 'resize-left-right':
        case 'ew-resize':
          return SystemMouseCursors.resizeLeftRight;
        case 'context-menu':
          return SystemMouseCursors.contextMenu;
        case 'cell':
          return SystemMouseCursors.cell;
        case 'copy':
          return SystemMouseCursors.copy;
        case 'alias':
          return SystemMouseCursors.alias;
        case 'none':
        case 'hidden':
          return SystemMouseCursors.none;
      }
    }
    return SystemMouseCursors.basic;
  }

  /// Disposes the underlying notifier. Called by the engine on teardown.
  void disposeCursor() {
    cursorNotifier.dispose();
  }
}
