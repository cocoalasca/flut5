import 'package:flutter/material.dart';

import 'flut5_console.dart';
import 'flut5_transform.dart';
import 'render/flut5_render_queue.dart';

/// A mixin that adds p5.js-style `clip()` masking to the Flut5 Engine.
///
/// Shapes drawn inside the callback passed to [clip] define a mask region.
/// Anything drawn *after* the `clip()` call (and before a matching `pop()`)
/// is clipped to that region — or, with `invert: true`, clipped *out* of it.
///
/// Wrap a `clip()` between [push] and [pop] to confine the mask to a section
/// of the sketch. The `push`/`pop` pair from [Flut5Transform] does the work:
/// `push()` saves the unclipped state, `clip()` narrows that state with
/// `canvas.clipPath()` (no `save()` of its own), and `pop()` restores it,
/// lifting the clip. A `clip()` left without a matching `pop()` simply stays
/// in effect until the end of the frame (p5.js `clip()` semantics).
///
/// Three entry points are exposed:
///
/// * [clip] — the p5.js-style callback API. Rebuilds the mask `Path` every
///   frame; convenient but expensive for static masks.
/// * [clipPath] — pass a pre-built [Path] (or a [List] of [Offset] points
///   for a polygon). Best for static masks because the Path can be built
///   once and reused, which also unlocks the inverted-clip cache on
///   [ClipRenderItem].
/// * [clipRect] — axis-aligned rectangular clip (with optional rounded
///   corners). Uses Flutter's fast [Canvas.clipRect] / [Canvas.clipRRect].
///
/// All three accept `invert` (turn the mask into a hole) and `antiAlias`
/// (set to `false` to skip the offscreen `saveLayer` that anti-aliased
/// complex clips usually trigger).
mixin Flut5Clip on Flut5Transform {
  /// Defines a clipping mask from the shapes drawn by [callback]. Any shape
  /// drawn after this call is masked by the union of those shapes.
  ///
  /// Pass `invert: true` to turn the mask into holes — subsequent shapes
  /// are drawn everywhere *except* inside the mask.
  ///
  /// Pass `antiAlias: false` to skip clip anti-aliasing. Edges become
  /// pixelated, but Flutter is much less likely to allocate an offscreen
  /// layer — a real speedup for complex masks on hot paths.
  ///
  /// The masking effect lasts until the next `pop()`. Wrap `clip()` between
  /// `push()` / `pop()` to scope it, so the masked region doesn't leak into
  /// the rest of the frame.
  ///
  /// Note: this rebuilds the mask `Path` every frame by re-running
  /// [callback]. For a mask that doesn't change frame-to-frame, prefer
  /// [clipPath] with a pre-built [Path].
  void clip(
    void Function() callback, {
    bool invert = false,
    bool antiAlias = true,
  }) {
    renderQueue.beginClipRecording();
    try {
      callback();
    } finally {
      final mask = renderQueue.endClipRecording();
      renderQueue.enqueue(
        ClipRenderItem.path(mask, invert: invert, antiAlias: antiAlias),
      );
    }
  }

  /// Cache-friendly alternative to [clip] that takes a pre-built mask.
  ///
  /// [source] may be:
  ///
  /// * A Flutter [Path] — used directly. Build the path once outside
  ///   `draw()` and pass the same instance every frame to skip the work
  ///   that [clip] does when re-running its callback. With `invert: true`
  ///   the combined `cover - path` is memoized internally and reused for
  ///   as long as the [Path] reference stays alive.
  /// * A `List<Offset>` — built into a closed polygon (`moveTo` → `lineTo`s
  ///   → `close`). The polygon `Path` is constructed inside this call, so
  ///   passing the same list each frame still rebuilds. For maximum reuse,
  ///   convert the list to a [Path] yourself once and pass that instead.
  ///
  /// `invert` and `antiAlias` behave like on [clip]. Like [clip], the
  /// effect lasts until the next [pop]; wrap in `push()` / `pop()` to
  /// scope it.
  ///
  /// ```dart
  /// // Built once, reused every frame — no per-frame Path allocation,
  /// // and the inverted form is cached.
  /// final logoMask = Path()
  ///   ..addOval(const Rect.fromLTWH(10, 10, 80, 80))
  ///   ..close();
  ///
  /// @override
  /// void draw() {
  ///   flut5.push();
  ///   flut5.clipPath(logoMask);
  ///   flut5.background(Colors.red);
  ///   flut5.pop();
  /// }
  /// ```
  void clipPath(
    Object source, {
    bool invert = false,
    bool antiAlias = true,
  }) {
    final Path path;
    if (source is Path) {
      path = source;
    } else if (source is List<Offset>) {
      if (source.length < 3) {
        Flut5Console.printLater(
          'clipPath(): List<Offset> needs at least 3 points to form a '
          'polygon — clip ignored.',
        );
        return;
      }
      path = Path()..moveTo(source[0].dx, source[0].dy);
      for (int i = 1; i < source.length; i++) {
        path.lineTo(source[i].dx, source[i].dy);
      }
      path.close();
    } else {
      throw ArgumentError(
        'clipPath() expects a Path or a List<Offset>, '
        'got ${source.runtimeType}.',
      );
    }
    renderQueue.enqueue(
      ClipRenderItem.path(path, invert: invert, antiAlias: antiAlias),
    );
  }

  /// Simpler axis-aligned alternative to [clip].
  ///
  /// Clips all subsequent drawing to the rectangle at ([x], [y]) with size
  /// [w] × [h]. When [radius] is provided and greater than zero, the four
  /// corners are rounded by that radius and Flutter's [Canvas.clipRRect] is
  /// used; otherwise [Canvas.clipRect] is used directly — both faster than
  /// the general-purpose `clipPath` that [clip] relies on.
  ///
  /// Pass `invert: true` to turn the rectangle (or rounded rectangle) into
  /// a hole instead — subsequent drawing renders everywhere *except* inside
  /// it. Inverted clips always go through `clipPath`, so they don't get the
  /// fast-path speedup.
  ///
  /// Pass `antiAlias: false` to skip AA at the clip edges. Mostly useful
  /// for the rounded-rect or inverted variants on hot paths.
  ///
  /// Like [clip], the effect lasts until the next [pop]. Wrap the call
  /// between [push] / [pop] to scope the clip.
  ///
  /// ```dart
  /// flut5.push();
  /// flut5.clipRect(20, 20, 60, 60, radius: 12);
  /// flut5.fill(Colors.red);
  /// flut5.rect(0, 0, 100, 100); // only the rounded interior shows.
  /// flut5.pop();
  ///
  /// // Inverted: punch a rounded rect hole in the canvas.
  /// flut5.push();
  /// flut5.clipRect(20, 20, 60, 60, radius: 12, invert: true);
  /// flut5.background(Colors.blue); // blue everywhere except the hole.
  /// flut5.pop();
  /// ```
  void clipRect(
    double x,
    double y,
    double w,
    double h, {
    double? radius,
    bool invert = false,
    bool antiAlias = true,
  }) {
    final rect = Rect.fromLTWH(x, y, w, h);
    if (radius != null && radius > 0) {
      renderQueue.enqueue(
        ClipRenderItem.rounded(
          RRect.fromRectAndRadius(rect, Radius.circular(radius)),
          invert: invert,
          antiAlias: antiAlias,
        ),
      );
    } else {
      renderQueue.enqueue(
        ClipRenderItem.rect(rect, invert: invert, antiAlias: antiAlias),
      );
    }
  }
}
