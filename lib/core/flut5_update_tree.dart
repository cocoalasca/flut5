import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Deferred widget-tree updates for the Flut5 framework.
///
/// `draw()` runs inside `CustomPainter.paint`, i.e. in the paint step of
/// [SchedulerPhase.persistentCallbacks]. The frame's build step is already
/// over by then, so anything that dirties the widget tree from `draw()` —
/// `setState`, writing a `ValueNotifier`, marking a render object dirty — is
/// illegal:
///
/// * In debug, `Element.markNeedsBuild` flags the element dirty and *then*
///   throws `Build scheduled during frame.` before the element reaches the
///   dirty list. Every later `markNeedsBuild` short-circuits on `if (dirty)
///   return;`, so the widget silently stops rebuilding forever. The exception
///   is reported once and easily missed.
/// * In release the assert is compiled out and the rebuild simply lands one
///   frame late.
///
/// [updateTree], [Flut5ValueNotifier] and [Flut5ChangeNotifier] all push the
/// write out of the paint step and into the end of the frame, where the tree
/// is writable again.

/// True while the framework is inside the part of the frame that builds, lays
/// out and paints the widget tree — the window in which dirtying the tree is
/// illegal. Every other phase (idle, transient callbacks, mid-frame
/// microtasks, post-frame callbacks) is safe to write from.
bool get _treeIsLocked =>
    SchedulerBinding.instance.schedulerPhase ==
    SchedulerPhase.persistentCallbacks;

final List<VoidCallback> _pending = <VoidCallback>[];
bool _flushScheduled = false;

/// Queues [action] to run once the current frame has finished painting.
/// One post-frame callback covers however many actions are queued.
void _deferToFrameEnd(VoidCallback action) {
  _pending.add(action);
  if (_flushScheduled) return;
  _flushScheduled = true;
  SchedulerBinding.instance.addPostFrameCallback(
    _flush,
    debugLabel: 'flut5.updateTree',
  );
}

void _flush(Duration _) {
  _flushScheduled = false;
  // Drain a copy. An action that calls updateTree() again is running in the
  // postFrameCallbacks phase, where the tree is writable, so it executes
  // inline rather than appending to the list being iterated.
  final actions = List<VoidCallback>.of(_pending);
  _pending.clear();
  for (final action in actions) {
    try {
      action();
    } catch (error, stack) {
      // One bad callback must not swallow the rest of the queue.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'flut5',
          context: ErrorDescription('while running an updateTree() callback'),
        ),
      );
    }
  }
}

/// Runs [update] at a point in the frame where touching the widget tree is
/// legal — the `setState` of Flut5.
///
/// Use it for anything in `draw()` that reaches out of the sketch and into
/// Flutter: writing a notifier you did not create, calling a widget's
/// callback, marking your own `CustomPainter` dirty.
///
/// ```dart
/// @override
/// void draw() {
///   // ...
///   if (_score != _lastScore) {
///     _lastScore = _score;
///     updateTree(() => widgetScore.value = _score);
///   }
/// }
/// ```
///
/// When called from a phase where the tree is already writable — a pointer
/// callback, a timer, `setup()`, another `updateTree` callback — [update] runs
/// **synchronously**, so nothing is delayed for no reason. Called from
/// `draw()` it runs at the end of the current frame and the change is visible
/// on the next one. Either way the callback runs exactly once; it is not
/// retained across frames.
///
/// Only notify on real change, as above. `updateTree` makes a per-frame write
/// safe, not free — every write still costs whatever rebuild the listener
/// triggers.
///
/// To push a value to a listener, prefer [Flut5ValueNotifier], which applies
/// this rule on every write and coalesces repeats within a frame.
void updateTree(VoidCallback update) {
  if (!_treeIsLocked) {
    update();
    return;
  }
  _deferToFrameEnd(update);
}

/// A [ValueNotifier] that is safe to write from inside `draw()`.
///
/// A plain `ValueNotifier` written from `draw()` notifies its listeners in the
/// middle of the paint step, which freezes the listening widget (see the notes
/// at the top of this file). [Flut5ValueNotifier] holds the write until the
/// frame ends and publishes it there instead:
///
/// ```dart
/// class Game extends Flut5Sketch {
///   final score = Flut5ValueNotifier<int>(0);
///
///   @override
///   void draw() {
///     if (hit) score.value++;   // safe, no updateTree() needed
///   }
/// }
///
/// // In the widget, unchanged — it is an ordinary ValueListenable:
/// ValueListenableBuilder<int>(
///   valueListenable: sketch.score,
///   builder: (context, value, _) => Text('$value'),
/// )
/// ```
///
/// Writes within one frame are **coalesced**: only the last one is published,
/// through a single notification, so a value written every frame costs one
/// rebuild per frame rather than one per write.
///
/// Reads see pending writes ([value] returns what the sketch just wrote, not
/// the last published value), so `if (n.value != x) n.value = x;` behaves the
/// way it reads inside `draw()`. Listeners are still notified only once the
/// frame ends.
///
/// Written from outside `draw()` it behaves exactly like `ValueNotifier` —
/// published immediately, no deferral, no latency.
class Flut5ValueNotifier<T> extends ValueNotifier<T> {
  /// Creates a notifier holding [value].
  Flut5ValueNotifier(super.value);

  /// Sentinel for "no write is waiting" — distinct from any `T`, including
  /// `null`, so a nullable notifier can queue a null write.
  static final Object _unset = Object();

  Object? _pendingWrite = _unset;
  bool _disposed = false;

  /// Whether a write made during `draw()` is still waiting for the frame to
  /// end. Listeners have not seen it yet.
  bool get hasPendingWrite => !identical(_pendingWrite, _unset);

  /// The value last published to listeners, ignoring any pending write.
  ///
  /// [value] is normally the one you want; this is for code that needs to know
  /// what the widget tree is currently showing.
  T get publishedValue => super.value;

  @override
  T get value => hasPendingWrite ? _pendingWrite as T : super.value;

  @override
  set value(T newValue) {
    if (!_treeIsLocked) {
      // Writable right now: publish immediately, and drop any queued write —
      // this one supersedes it.
      _pendingWrite = _unset;
      super.value = newValue;
      return;
    }
    // Inside draw(). Keep only the last write of the frame, and queue the
    // publish once however many writes land.
    final alreadyQueued = hasPendingWrite;
    _pendingWrite = newValue;
    if (alreadyQueued) return;
    _deferToFrameEnd(_publish);
  }

  void _publish() {
    if (_disposed || !hasPendingWrite) return;
    final pending = _pendingWrite as T;
    _pendingWrite = _unset;
    // ValueNotifier compares before notifying, so a value that ends the frame
    // where it started publishes nothing.
    super.value = pending;
  }

  @override
  void dispose() {
    // A queued publish outlives the frame it was made in; make sure it cannot
    // notify through a disposed notifier.
    _disposed = true;
    _pendingWrite = _unset;
    super.dispose();
  }
}

/// Makes [ChangeNotifier.notifyListeners] safe to call from inside `draw()`.
///
/// Same fix as [Flut5ValueNotifier], applied one level down: instead of a
/// notifier that holds a *value*, this holds the *notification*. Mix it onto
/// anything that is already a [ChangeNotifier] and every `notifyListeners()`
/// raised during the paint step is published at the end of the frame instead,
/// where the widget tree is writable again.
///
/// On a sketch — the sketch itself becomes the [Listenable]:
///
/// ```dart
/// class Game extends Flut5Sketch with ChangeNotifier, Flut5ChangeNotifier {
///   int score = 0;
///
///   @override
///   void draw() {
///     if (hit) {
///       score++;
///       notifyListeners();   // safe, no updateTree() needed
///     }
///   }
/// }
///
/// // In the widget, unchanged — it is an ordinary Listenable:
/// ListenableBuilder(
///   listenable: sketch,
///   builder: (context, _) => Text('${sketch.score}'),
/// )
/// ```
///
/// [ChangeNotifier] is a `mixin class`, so it goes in the `with` clause ahead
/// of this one; the order matters, because [Flut5ChangeNotifier] overrides
/// `notifyListeners` and must be applied last.
///
/// On a controller you already own, there is nothing to reorder:
///
/// ```dart
/// class ButtonController extends ChangeNotifier with Flut5ChangeNotifier {}
/// ```
///
/// Notifications raised within one frame are **coalesced**: however many
/// `notifyListeners()` calls a frame makes, listeners are called once, at the
/// end of it. Fields the listener reads are plain fields, so it sees whatever
/// they hold when it finally runs — the last value of the frame, matching
/// `Flut5ValueNotifier`'s coalescing.
///
/// Called from outside `draw()` — a pointer callback, a timer, `setup()` — it
/// behaves exactly like [ChangeNotifier]: published immediately, no deferral,
/// no latency.
///
/// To push a single value rather than a "something changed" signal, prefer
/// [Flut5ValueNotifier]; it adds read-your-writes semantics this mixin cannot
/// offer, since the fields behind a [ChangeNotifier] are written directly.
mixin Flut5ChangeNotifier on ChangeNotifier {
  bool _notifyQueued = false;
  bool _notifierDisposed = false;

  /// Whether a `notifyListeners()` made during `draw()` is still waiting for
  /// the frame to end. Listeners have not been called for it yet.
  bool get hasPendingNotification => _notifyQueued;

  @override
  void notifyListeners() {
    if (!_treeIsLocked) {
      // Writable right now: notify immediately, and drop any queued
      // notification — this one covers it.
      _notifyQueued = false;
      super.notifyListeners();
      return;
    }
    // Inside draw(). Queue one publish for the frame however many calls land.
    if (_notifyQueued) return;
    _notifyQueued = true;
    _deferToFrameEnd(_publishNotification);
  }

  void _publishNotification() {
    if (_notifierDisposed || !_notifyQueued) return;
    _notifyQueued = false;
    super.notifyListeners();
  }

  @override
  void dispose() {
    // A queued publish outlives the frame it was made in; make sure it cannot
    // notify through a disposed notifier.
    _notifierDisposed = true;
    _notifyQueued = false;
    super.dispose();
  }
}
