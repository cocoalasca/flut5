import 'dart:ui' as ui;

/// Keeps a replaced or disposed bitmap alive for as long as a render queue
/// still references it.
///
/// `image()` does not draw immediately: it queues the bitmap's [ui.Image]
/// handle, and the queue replays it later — after `draw()` returns, or after
/// the whole of an `async` `setup()` completes. A sketch that draws an image
/// and then calls `updatePixels()`, `resize()` or `dispose()` on it in the
/// same frame would otherwise free a handle the queue is about to paint.
///
/// So [Flut5Image] never disposes a bitmap it drops directly. It calls
/// [disposeWhenReleased], which frees the handle at once when no queue holds
/// it, and otherwise defers that to the moment the last holding queue is
/// cleared ([release]). The render queue [hold]s a handle when it queues it.
///
/// Process-wide rather than per queue because one image can be queued by
/// several sketches in the same frame. Internal plumbing — not exported from
/// `package:flut5/flut5.dart`.
abstract final class Flut5ImageHandles {
  /// Handle → number of outstanding holds across every render queue.
  static final Map<ui.Image, int> _holdCounts = Map.identity();

  /// Handles whose owner has let go of them while a queue still held them.
  static final Set<ui.Image> _awaitingDisposal = Set.identity();

  /// Records that a render queue is about to paint [image]. Every hold is
  /// matched by one [release] when that queue is cleared.
  static void hold(ui.Image image) {
    _holdCounts[image] = (_holdCounts[image] ?? 0) + 1;
  }

  /// Drops one hold on [image], disposing it if its owner already let it go
  /// and this was the last hold.
  static void release(ui.Image image) {
    final count = _holdCounts[image];
    if (count == null) return;
    if (count > 1) {
      _holdCounts[image] = count - 1;
      return;
    }
    _holdCounts.remove(image);
    if (_awaitingDisposal.remove(image)) image.dispose();
  }

  /// Disposes [image] now, or as soon as the last render queue holding it
  /// is cleared.
  static void disposeWhenReleased(ui.Image image) {
    if (_holdCounts.containsKey(image)) {
      _awaitingDisposal.add(image);
    } else {
      image.dispose();
    }
  }

  /// How many render-queue holds [image] has outstanding. Test-only.
  static int debugHoldCount(ui.Image image) => _holdCounts[image] ?? 0;
}
