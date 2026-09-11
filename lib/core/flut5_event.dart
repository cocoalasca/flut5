import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'dart:async';

import '../math/flut5_vector.dart';
import 'flut5_engine.dart';
import 'sketch_keyboard_event.dart';
import 'flut5_touch.dart';
import 'flut5_wheel.dart';
import 'sketch_pointer_event.dart';
import 'sketch_scroll_event.dart';

/// Event payload containing the previous and new size of the canvas.
///
/// Dispatched whenever the canvas dimensions change (e.g. window resize,
/// orientation change).
@immutable
final class const ResizeEvent(
  /// The canvas size before the change (p5 convention: `p` prefix = previous).
  final Size psize,

  /// The canvas size after the change.
  final Size size,
);

/// The phase of a buffered per-frame pointer event. Mirrors the four
/// sketch-level pointer callbacks ([Flut5EventMixin.onPointerDown],
/// [Flut5EventMixin.onPointerUp], [Flut5EventMixin.onPointerMove],
/// [Flut5EventMixin.onPointerDragged]).
enum Flut5PointerPhase { down, up, move, drag }

/// One pointer event captured during a frame, tagged with its [phase]. Buffered
/// by [Flut5Event] and read by scroll-mode-style consumers such as the
/// `endContainer()` helper, which dispatches them to per-container callbacks.
@immutable
final class const Flut5FramePointerEvent(
  final Flut5PointerPhase phase,
  final SketchPointerEvent event,
);

/// A mixin that provides event-handling capabilities to a Sketch.
///
/// Listens to internal streams from the engine and provides lifecycle overrides
/// such as [onPointerDown] for custom sketch interaction.
mixin Flut5EventMixin {
  StreamSubscription<SketchPointerEvent>? _pointerDownSub;
  StreamSubscription<SketchPointerEvent>? _pointerUpSub;
  StreamSubscription<SketchPointerEvent>? _pointerMoveSub;
  StreamSubscription<SketchPointerEvent>? _pointerDraggedSub;
  StreamSubscription<SketchKeyboardEvent>? _keyPressedSub;
  StreamSubscription<SketchKeyboardEvent>? _keyReleasedSub;
  StreamSubscription<SketchKeyboardEvent>? _keyTypedSub;
  StreamSubscription<ResizeEvent>? _resizeSub;
  StreamSubscription<SketchScrollEvent>? _scrollSub;
  StreamSubscription<Map<String, dynamic>>? _stateChangeSub;

  /// Subscribes to pointer, keyboard, resize, scroll and props state-change
  /// events broadcasted by the [Flut5Engine].
  void listenEvents(Flut5Engine engine) {
    _pointerDownSub = engine.events.pointerDownStream.listen(onPointerDown);
    _pointerUpSub = engine.events.pointerUpStream.listen(onPointerUp);
    _pointerMoveSub = engine.events.pointerMoveStream.listen(onPointerMove);
    _pointerDraggedSub = engine.events.pointerDraggedStream.listen(
      onPointerDragged,
    );
    _keyPressedSub = engine.events.keyPressedStream.listen(onKeyPressed);
    _keyReleasedSub = engine.events.keyReleasedStream.listen(onKeyReleased);
    _keyTypedSub = engine.events.keyTypedStream.listen(onKeyTyped);
    _resizeSub = engine.events.resizeStream.listen(onResize);
    _scrollSub = engine.events.scrollStream.listen(onMouseWheel);
    _stateChangeSub = engine.events.stateChangeStream.listen(onStateChange);
  }

  /// Override this method to handle pointer down (touch/click) events.
  void onPointerDown(SketchPointerEvent e) {}

  /// Override this method to handle pointer up (release) events.
  void onPointerUp(SketchPointerEvent e) {}

  /// Override this method to handle pointer move events (no button pressed).
  void onPointerMove(SketchPointerEvent e) {}

  /// Override this method to handle pointer drag events (pointer down + move).
  void onPointerDragged(SketchPointerEvent e) {}

  /// Override this method to handle keyboard press events.
  ///
  /// By default this forwards to [keyPressed] for sketches that prefer p5-style
  /// callback names.
  void onKeyPressed(SketchKeyboardEvent e) => keyPressed(e);

  /// Override this method to handle keyboard release events.
  ///
  /// By default this forwards to [keyReleased] for sketches that prefer p5-style
  /// callback names.
  void onKeyReleased(SketchKeyboardEvent e) => keyReleased(e);

  /// Override this method to handle printable keyboard typed events.
  ///
  /// By default this forwards to [keyTyped] for sketches that prefer p5-style
  /// callback names.
  void onKeyTyped(SketchKeyboardEvent e) => keyTyped(e);

  /// p5-style alias for [onKeyPressed].
  void keyPressed(SketchKeyboardEvent e) {}

  /// p5-style alias for [onKeyReleased].
  void keyReleased(SketchKeyboardEvent e) {}

  /// p5-style alias for [onKeyTyped].
  void keyTyped(SketchKeyboardEvent e) {}

  /// Override this method to handle mouse-wheel / trackpad scroll events.
  ///
  /// By default this forwards to [mouseWheel] for sketches that prefer
  /// p5-style callback names.
  void onMouseWheel(SketchScrollEvent e) => mouseWheel(e);

  /// p5-style alias for [onMouseWheel].
  void mouseWheel(SketchScrollEvent e) {}

  /// Override this method to handle canvas resize events.
  void onResize(ResizeEvent e) {}

  /// Override this method to react to [Flut5Canvas.props] changes.
  /// Called whenever the parent widget rebuilds with a props map that differs
  /// from the previous one. The sketch is NOT reset — [setup] and [draw]
  /// continue normally.
  ///
  /// Delivered to every [Flut5EventMixin] object subscribed via [listenEvents]
  /// — the sketch itself and any helper class constructed with
  /// `listenEvents: true` — so a `Particle` reacts to props the same way it
  /// reacts to pointer events.
  ///
  /// Not called before the first [Flut5Sketch.setup]; read `props` directly
  /// there for the initial value.
  void onStateChange(Map<String, dynamic> props) {}

  /// Subscribes to the state-change stream broadcasted by the [Flut5Engine].
  ///
  /// Deprecated: state changes now arrive through [listenEvents] alongside
  /// every other event. Construct with `listenEvents: true` and override
  /// [onStateChange] instead.
  @Deprecated(
    'State changes now arrive through listenEvents(). Construct with '
    'listenEvents: true and override onStateChange instead. '
    'This will be removed in a future release.',
  )
  void listenStateChanges(Flut5Engine engine) {
    _stateChangeSub?.cancel();
    // ignore: deprecated_member_use_from_same_package
    _stateChangeSub = engine.events.stateChangeStream.listen(onStateStream);
  }

  /// Override this method to react to streamed props changes.
  ///
  /// Deprecated: override [onStateChange] instead, which now receives the same
  /// events for any object subscribed via [listenEvents]. Existing overrides
  /// keep working — the default implementation forwards to [onStateChange].
  @Deprecated(
    'Override onStateChange instead. '
    'This will be removed in a future release.',
  )
  void onStateStream(Map<String, dynamic> props) => onStateChange(props);

  /// Cancels all active event subscriptions.
  void disposeEvents() {
    _pointerDownSub?.cancel();
    _pointerUpSub?.cancel();
    _pointerMoveSub?.cancel();
    _pointerDraggedSub?.cancel();
    _keyPressedSub?.cancel();
    _keyReleasedSub?.cancel();
    _keyTypedSub?.cancel();
    _resizeSub?.cancel();
    _scrollSub?.cancel();
    _stateChangeSub?.cancel();
  }
}

/// Core event manager for the Flut5 Engine.
///
/// Contains [StreamController]s for pointer and canvas events.
/// The canvas widget dispatches events here, and any attached
/// [Flut5EventMixin] listeners receive them via broadcast streams.
final class Flut5Event({
  final void Function(SketchPointerEvent event)? onPointerPositionChanged,
  final void Function(SketchKeyboardEvent event)? onKeyboardChanged,
}) {
  final StreamController<SketchPointerEvent> _pointerDownController =
      StreamController<SketchPointerEvent>.broadcast();

  /// A broadcast stream of [SketchPointerEvent]s occurring on the canvas.
  Stream<SketchPointerEvent> get pointerDownStream =>
      _pointerDownController.stream;

  final StreamController<SketchPointerEvent> _pointerUpController =
      StreamController<SketchPointerEvent>.broadcast();

  /// A broadcast stream of [SketchPointerEvent]s occurring on the canvas.
  Stream<SketchPointerEvent> get pointerUpStream => _pointerUpController.stream;

  final StreamController<SketchPointerEvent> _pointerMoveController =
      StreamController<SketchPointerEvent>.broadcast();

  /// A broadcast stream of [SketchPointerEvent]s occurring on the canvas.
  /// Only fires when no pointer button is pressed (hover).
  Stream<SketchPointerEvent> get pointerMoveStream =>
      _pointerMoveController.stream;

  final StreamController<SketchPointerEvent> _pointerDraggedController =
      StreamController<SketchPointerEvent>.broadcast();

  /// A broadcast stream of [SketchPointerEvent]s occurring while the pointer
  /// is pressed (drag). When dragging, [pointerMoveStream] does not fire.
  Stream<SketchPointerEvent> get pointerDraggedStream =>
      _pointerDraggedController.stream;

  final StreamController<SketchKeyboardEvent> _keyPressedController =
      StreamController<SketchKeyboardEvent>.broadcast();

  /// A broadcast stream of keyboard press events.
  Stream<SketchKeyboardEvent> get keyPressedStream =>
      _keyPressedController.stream;

  final StreamController<SketchKeyboardEvent> _keyReleasedController =
      StreamController<SketchKeyboardEvent>.broadcast();

  /// A broadcast stream of keyboard release events.
  Stream<SketchKeyboardEvent> get keyReleasedStream =>
      _keyReleasedController.stream;

  final StreamController<SketchKeyboardEvent> _keyTypedController =
      StreamController<SketchKeyboardEvent>.broadcast();

  /// A broadcast stream of printable keyboard typed events.
  Stream<SketchKeyboardEvent> get keyTypedStream => _keyTypedController.stream;

  final StreamController<ResizeEvent> _resizeController =
      StreamController<ResizeEvent>.broadcast();

  /// A broadcast stream of [ResizeEvent]s occurring when the canvas size changes.
  Stream<ResizeEvent> get resizeStream => _resizeController.stream;

  final StreamController<SketchScrollEvent> _scrollController =
      StreamController<SketchScrollEvent>.broadcast();

  /// A broadcast stream of mouse-wheel / trackpad scroll events.
  Stream<SketchScrollEvent> get scrollStream => _scrollController.stream;

  final StreamController<Map<String, dynamic>> _stateChangeController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// A broadcast stream of props maps dispatched whenever [Flut5Canvas.props]
  /// changes. Subscribed automatically by [Flut5EventMixin.listenEvents].
  Stream<Map<String, dynamic>> get stateChangeStream =>
      _stateChangeController.stream;

  /// Tracks whether a pointer button is currently pressed.
  bool _pointerIsDown = false;

  /// Whether any pointer (finger / mouse button / stylus) is currently pressed
  /// on the canvas. Mirrors p5.js's `mouseIsPressed`. Equivalent to
  /// `touches.isNotEmpty`.
  bool get pointerIsDown => _pointerIsDown;

  Offset? _previousPointerLocation;

  /// Per-pointer state for currently pressed fingers / mouse buttons / styluses.
  /// Keyed by the Flutter pointer id so multi-touch gestures stay distinct.
  final Map<int, Flut5Touch> _activeTouches = {};

  /// All pointers currently pressed on the canvas. Empty when nothing is down.
  /// Each [Flut5Touch] carries its own `x`, `y`, `px`, `py`, and `id`, making
  /// this the entry point for multi-touch interactions.
  List<Flut5Touch> get touches =>
      List<Flut5Touch>.unmodifiable(_activeTouches.values);

  /// Accumulated wheel delta for the current frame, summed across every
  /// [PointerScrollEvent] received since the last [clearPendingWheel]. Stays
  /// `0` / null when no wheel motion is buffered.
  double _wheelDeltaX = 0;
  double _wheelDeltaY = 0;
  Offset? _wheelLocation;

  /// The buffered wheel sample for the current frame, or `null` when no wheel
  /// motion occurred. Read by scroll-mode containers and cleared once per frame
  /// by the painter via [clearPendingWheel].
  Flut5WheelSample? get pendingWheel {
    final loc = _wheelLocation;
    if (loc == null) return null;
    return Flut5WheelSample(
      dx: _wheelDeltaX,
      dy: _wheelDeltaY,
      x: loc.dx,
      y: loc.dy,
    );
  }

  /// Discards the buffered wheel sample. Called once per frame after `draw()`
  /// so a wheel event drives scrolling for exactly one frame.
  void clearPendingWheel() {
    _wheelDeltaX = 0;
    _wheelDeltaY = 0;
    _wheelLocation = null;
  }

  /// Discrete pointer events captured since the last [clearPendingPointerEvents].
  /// Read once per frame by `endContainer()` to dispatch per-container
  /// pointer callbacks, then cleared by the painter after `draw()`.
  final List<Flut5FramePointerEvent> _frameEvents = [];

  /// Upper bound on buffered per-frame events, so a paused / offscreen sketch
  /// (which stops clearing the buffer) cannot accumulate without limit.
  static const int _maxFrameEvents = 240;

  /// The pointer events buffered for the current frame, in arrival order, or an
  /// empty list when none occurred. Drained once per frame via
  /// [clearPendingPointerEvents].
  List<Flut5FramePointerEvent> get pendingPointerEvents =>
      List<Flut5FramePointerEvent>.unmodifiable(_frameEvents);

  /// Discards the buffered per-frame pointer events. Called once per frame after
  /// `draw()` so each event is dispatched to containers exactly once.
  void clearPendingPointerEvents() {
    _frameEvents.clear();
  }

  void _bufferFrameEvent(Flut5PointerPhase phase, SketchPointerEvent event) {
    _frameEvents.add(Flut5FramePointerEvent(phase, event));
    if (_frameEvents.length > _maxFrameEvents) {
      _frameEvents.removeRange(0, _frameEvents.length - _maxFrameEvents);
    }
  }

  /// Per-pointer rolling history of recent local positions, used to compute
  /// the average velocity exposed on [SketchPointerEvent.velocity] and
  /// [Flut5Touch.velocity]. Capped at [_avgMouseFrames] entries per pointer.
  final Map<int, List<Offset>> _pointerHistory = {};

  int _avgMouseFrames = 15;

  /// Number of recent move samples used to compute the average velocity
  /// reported on pointer events and touches. Defaults to 10.
  int get avgMouseFrames => _avgMouseFrames;
  set avgMouseFrames(int n) {
    if (n < 1) {
      throw ArgumentError.value(n, 'avgMouseFrames', 'must be >= 1');
    }
    _avgMouseFrames = n;
    for (final h in _pointerHistory.values) {
      if (h.length > n) h.removeRange(0, h.length - n);
    }
  }

  void _pushPointerHistory(int pointerId, Offset location) {
    final h = _pointerHistory.putIfAbsent(pointerId, () => <Offset>[]);
    h.add(location);
    if (h.length > _avgMouseFrames) {
      h.removeRange(0, h.length - _avgMouseFrames);
    }
  }

  Flut5Vector _avgVelocityFor(int pointerId) {
    final h = _pointerHistory[pointerId];
    if (h == null || h.length < 2) return Flut5Vector.zero();
    final first = h.first;
    final last = h.last;
    final n = h.length - 1;
    return Flut5Vector((last.dx - first.dx) / n, (last.dy - first.dy) / n);
  }

  static final Map<LogicalKeyboardKey, int> _p5KeyCodeOverrides = {
    LogicalKeyboardKey.backspace: 8,
    LogicalKeyboardKey.tab: 9,
    LogicalKeyboardKey.enter: 13,
    LogicalKeyboardKey.numpadEnter: 13,
    LogicalKeyboardKey.shiftLeft: 16,
    LogicalKeyboardKey.shiftRight: 16,
    LogicalKeyboardKey.controlLeft: 17,
    LogicalKeyboardKey.controlRight: 17,
    LogicalKeyboardKey.altLeft: 18,
    LogicalKeyboardKey.altRight: 18,
    LogicalKeyboardKey.pause: 19,
    LogicalKeyboardKey.capsLock: 20,
    LogicalKeyboardKey.escape: 27,
    LogicalKeyboardKey.space: 32,
    LogicalKeyboardKey.pageUp: 33,
    LogicalKeyboardKey.pageDown: 34,
    LogicalKeyboardKey.end: 35,
    LogicalKeyboardKey.home: 36,
    LogicalKeyboardKey.arrowLeft: 37,
    LogicalKeyboardKey.arrowUp: 38,
    LogicalKeyboardKey.arrowRight: 39,
    LogicalKeyboardKey.arrowDown: 40,
    LogicalKeyboardKey.insert: 45,
    LogicalKeyboardKey.delete: 46,
    LogicalKeyboardKey.metaLeft: 91,
    LogicalKeyboardKey.metaRight: 92,
    LogicalKeyboardKey.f1: 112,
    LogicalKeyboardKey.f2: 113,
    LogicalKeyboardKey.f3: 114,
    LogicalKeyboardKey.f4: 115,
    LogicalKeyboardKey.f5: 116,
    LogicalKeyboardKey.f6: 117,
    LogicalKeyboardKey.f7: 118,
    LogicalKeyboardKey.f8: 119,
    LogicalKeyboardKey.f9: 120,
    LogicalKeyboardKey.f10: 121,
    LogicalKeyboardKey.f11: 122,
    LogicalKeyboardKey.f12: 123,
  };

  SketchPointerEvent _normalizePointerEvent(
    PointerEvent event, {
    bool withVelocity = false,
  }) {
    final location = event.localPosition;
    Flut5Vector? velocity;
    if (withVelocity) {
      _pushPointerHistory(event.pointer, location);
      velocity = _avgVelocityFor(event.pointer);
    }
    final normalized = SketchPointerEvent(
      location: location,
      plocation: _previousPointerLocation ?? location,
      rawEvent: event,
      velocity: velocity,
    );
    _previousPointerLocation = location;
    return normalized;
  }

  void _addPointerMoveLikeEvent(SketchPointerEvent event) {
    onPointerPositionChanged?.call(event);
    if (_pointerIsDown) {
      _bufferFrameEvent(Flut5PointerPhase.drag, event);
      if (!_pointerDraggedController.isClosed) {
        _pointerDraggedController.add(event);
      }
    } else {
      _bufferFrameEvent(Flut5PointerPhase.move, event);
      if (!_pointerMoveController.isClosed) {
        _pointerMoveController.add(event);
      }
    }
  }

  /// Adds a new pointer-down event to the internal stream.
  void addPointerDown(PointerDownEvent event) {
    _pointerIsDown = true;
    final loc = event.localPosition;
    _pointerHistory[event.pointer] = <Offset>[loc];
    _activeTouches[event.pointer] = Flut5Touch(
      id: event.pointer,
      x: loc.dx,
      y: loc.dy,
      px: loc.dx,
      py: loc.dy,
      kind: event.kind,
    );
    final normalized = _normalizePointerEvent(event);
    _bufferFrameEvent(Flut5PointerPhase.down, normalized);
    if (!_pointerDownController.isClosed) {
      _pointerDownController.add(normalized);
    }
  }

  /// Adds a new pointer-up event to the internal stream.
  void addPointerUp(PointerUpEvent event) {
    _activeTouches.remove(event.pointer);
    _pointerHistory.remove(event.pointer);
    _pointerIsDown = _activeTouches.isNotEmpty;
    final normalized = _normalizePointerEvent(event);
    _bufferFrameEvent(Flut5PointerPhase.up, normalized);
    if (!_pointerUpController.isClosed) {
      _pointerUpController.add(normalized);
    }
  }

  /// Removes a pointer that was cancelled (e.g. gesture stolen by an ancestor).
  /// Keeps [touches] from leaking stale entries.
  void addPointerCancel(PointerCancelEvent event) {
    _activeTouches.remove(event.pointer);
    _pointerHistory.remove(event.pointer);
    _pointerIsDown = _activeTouches.isNotEmpty;
  }

  /// Routes to [pointerDraggedStream] if the pointer is down,
  /// otherwise routes to [pointerMoveStream].
  void addPointerMove(PointerMoveEvent event) {
    final normalized = _normalizePointerEvent(event, withVelocity: true);
    final prev = _activeTouches[event.pointer];
    if (prev != null) {
      final loc = event.localPosition;
      _activeTouches[event.pointer] = Flut5Touch(
        id: event.pointer,
        x: loc.dx,
        y: loc.dy,
        px: prev.x,
        py: prev.y,
        velocity: normalized.velocity,
        kind: event.kind,
      );
    }
    _addPointerMoveLikeEvent(normalized);
  }

  /// Adds a new hover event to the move stream and updates pointer position.
  void addPointerHover(PointerHoverEvent event) {
    _addPointerMoveLikeEvent(_normalizePointerEvent(event, withVelocity: true));
  }

  /// Handles a pointer signal (mouse wheel / trackpad scroll). Accumulates the
  /// scroll delta into the per-frame buffer read by scroll-mode containers and
  /// broadcasts a [SketchScrollEvent] for the [Flut5EventMixin.mouseWheel]
  /// callback. Non-scroll signals are ignored.
  void addPointerScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final loc = event.localPosition;
    final delta = event.scrollDelta;
    _wheelDeltaX += delta.dx;
    _wheelDeltaY += delta.dy;
    _wheelLocation = loc;
    if (!_scrollController.isClosed) {
      _scrollController.add(
        SketchScrollEvent(
          location: loc,
          scrollDelta: Flut5Vector(delta.dx, delta.dy),
          rawEvent: event,
        ),
      );
    }
  }

  SketchKeyboardEvent _normalizeKeyboardEvent(KeyEvent event) {
    final key = _keyFor(event);
    final normalized = SketchKeyboardEvent(
      key: key,
      keyCode: _keyCodeFor(event.logicalKey, key),
      rawEvent: event,
      logicalKey: event.logicalKey,
      physicalKey: event.physicalKey,
      character: event.character,
      repeat: event is KeyRepeatEvent,
    );
    onKeyboardChanged?.call(normalized);
    return normalized;
  }

  String _keyFor(KeyEvent event) {
    final character = event.character;
    if (character != null && character.isNotEmpty) return character;
    final label = event.logicalKey.keyLabel;
    if (label.isNotEmpty) return label;
    return event.logicalKey.debugName ?? '';
  }

  int _keyCodeFor(LogicalKeyboardKey logicalKey, String key) {
    final override = _p5KeyCodeOverrides[logicalKey];
    if (override != null) return override;
    final label = logicalKey.keyLabel;
    if (label.length == 1) return label.toUpperCase().codeUnitAt(0);
    if (key.length == 1) return key.toUpperCase().codeUnitAt(0);
    return logicalKey.keyId;
  }

  bool _isTypedKeyboardEvent(SketchKeyboardEvent event) {
    final character = event.character;
    return character != null &&
        character.isNotEmpty &&
        !LogicalKeyboardKey.isControlCharacter(character);
  }

  /// Adds a new keyboard event to the internal streams.
  ///
  /// [KeyDownEvent] and [KeyRepeatEvent] emit [keyPressedStream]. Printable
  /// down/repeat events also emit [keyTypedStream]. [KeyUpEvent] emits
  /// [keyReleasedStream].
  void addKeyEvent(KeyEvent event) {
    final normalized = _normalizeKeyboardEvent(event);
    if (event is KeyUpEvent) {
      if (!_keyReleasedController.isClosed) {
        _keyReleasedController.add(normalized);
      }
      return;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (!_keyPressedController.isClosed) {
        _keyPressedController.add(normalized);
      }
      if (_isTypedKeyboardEvent(normalized) && !_keyTypedController.isClosed) {
        _keyTypedController.add(normalized);
      }
    }
  }

  /// Adds a new [ResizeEvent] to the internal stream.
  void addResize(ResizeEvent event) {
    if (!_resizeController.isClosed) _resizeController.add(event);
  }

  /// Adds a new state-change props map to the stream.
  /// Dispatched by [Flut5Canvas] whenever its props map changes by value.
  void addStateChange(Map<String, dynamic> props) {
    if (!_stateChangeController.isClosed) _stateChangeController.add(props);
  }

  /// Closes all active [StreamController]s.
  /// Should be called during the Engine's disposal phase.
  void dispose() {
    if (!_pointerDownController.isClosed) _pointerDownController.close();
    if (!_pointerUpController.isClosed) _pointerUpController.close();
    if (!_pointerMoveController.isClosed) _pointerMoveController.close();
    if (!_pointerDraggedController.isClosed) _pointerDraggedController.close();
    if (!_keyPressedController.isClosed) _keyPressedController.close();
    if (!_keyReleasedController.isClosed) _keyReleasedController.close();
    if (!_keyTypedController.isClosed) _keyTypedController.close();
    if (!_resizeController.isClosed) _resizeController.close();
    if (!_scrollController.isClosed) _scrollController.close();
    if (!_stateChangeController.isClosed) _stateChangeController.close();
  }
}
