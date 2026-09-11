import 'package:flutter/material.dart';

import '../flut5_render_item.dart';

/// Discriminates the three clipping strategies handled by [ClipRenderItem].
enum ClipKind {
  /// Arbitrary-shape clip backed by [Canvas.clipPath]. Supports inversion.
  path,

  /// Axis-aligned rectangular clip backed by [Canvas.clipRect].
  rect,

  /// Axis-aligned rounded rectangular clip backed by [Canvas.clipRRect].
  rounded,
}

/// Applies a clipping mask to all subsequent drawing in the current frame.
///
/// Calls the appropriate `canvas.clip*` method **without** its own
/// `canvas.save()`. The clip narrows the *current* save layer, so it's removed
/// by the next `canvas.restore()` — which a later `pop()` provides. Always wrap
/// the clip between `push()` / `pop()`: the `push()` saves the unclipped state
/// and the `pop()` restores it, lifting the clip. A clip with no enclosing
/// `push()` simply lasts until the end of the frame (p5.js `clip()` semantics).
///
/// Three flavors of clip share this render item:
///
/// * [ClipRenderItem.path] — clip to an arbitrary [Path].
/// * [ClipRenderItem.rect] — clip to an axis-aligned rectangle via
///   [Canvas.clipRect]. Faster than [path] when [invert] is `false`.
/// * [ClipRenderItem.rounded] — clip to a rounded rectangle via
///   [Canvas.clipRRect]. Also faster than the general-purpose path clip
///   when [invert] is `false`.
///
/// All three accept [invert]. When `true`, the masked region becomes a hole
/// instead — the shape is subtracted from a very large covering rect via
/// [Path.combine] with [PathOperation.difference] and the result is fed to
/// [Canvas.clipPath]. The fast `clipRect`/`clipRRect` paths can only express
/// inclusive clips, so inversion always routes through `clipPath`.
///
/// All three also accept [antiAlias] (default `true`). Setting it to `false`
/// produces pixelated edges but avoids the offscreen `saveLayer` that
/// anti-aliased complex clips usually trigger — a real win on hot paths.
class ClipRenderItem._({
  required final ClipKind kind,
  final Path? maskPath,
  final Rect? rect,
  final RRect? rrect,
  final bool invert = false,
  final bool antiAlias = true,
}) extends Flut5RenderItem {
  /// Bounds large enough to cover any practical canvas + transform. Finite
  /// (rather than [Rect.largest]) so [Path.combine] stays numerically sane.
  static const Rect _cover = Rect.fromLTRB(-1e9, -1e9, 1e9, 1e9);

  /// Caches `cover - maskPath` keyed by mask-path identity, so callers
  /// passing a stable [Path] to `clipPath(invert: true)` don't pay the
  /// [Path.combine] cost every frame. Uses [Expando] so the cached inverted
  /// path is garbage-collected once the user drops their reference to the
  /// original mask path. Only [ClipKind.path] benefits — the rect/rrect
  /// cases build fresh `Path` instances per frame and have nothing stable
  /// to key on (and the boolean op on a single rect is cheap anyway).
  static final Expando<Path> _invertedPathCache = Expando<Path>(
    'ClipRenderItem.invertedPath',
  );

  /// Arbitrary-shape clip. Set [invert] to turn the path into a hole.
  /// Set [antiAlias] to `false` to skip AA (faster, pixelated edges).
  ClipRenderItem.path(
    Path maskPath, {
    bool invert = false,
    bool antiAlias = true,
  }) : this._(
         kind: .path,
         maskPath: maskPath,
         invert: invert,
         antiAlias: antiAlias,
       );

  /// Sharp-cornered rectangular clip. Set [invert] to turn the rectangle
  /// into a hole instead (drawn everywhere except inside it).
  ClipRenderItem.rect(Rect rect, {bool invert = false, bool antiAlias = true})
    : this._(kind: .rect, rect: rect, invert: invert, antiAlias: antiAlias);

  /// Rounded rectangular clip. Set [invert] to turn the rounded rectangle
  /// into a hole instead.
  ClipRenderItem.rounded(
    RRect rrect, {
    bool invert = false,
    bool antiAlias = true,
  }) : this._(
         kind: .rounded,
         rrect: rrect,
         invert: invert,
         antiAlias: antiAlias,
       );

  @override
  void execute(Canvas canvas) {
    // No canvas.save() here — the clip narrows the current save layer and is
    // lifted by the restore() that the matching pop() issues. See the class
    // doc for why the save lives in push() rather than in the clip.
    if (invert) {
      canvas.clipPath(_resolveInvertedPath(), doAntiAlias: antiAlias);
      return;
    }
    switch (kind) {
      case .rect:
        canvas.clipRect(rect!, doAntiAlias: antiAlias);
      case .rounded:
        canvas.clipRRect(rrect!, doAntiAlias: antiAlias);
      case .path:
        canvas.clipPath(maskPath!, doAntiAlias: antiAlias);
    }
  }

  /// Builds (or returns the cached) `cover - shape` path used for inverted
  /// clipping. Only the [ClipKind.path] variant memoizes — see
  /// [_invertedPathCache].
  Path _resolveInvertedPath() {
    if (kind == .path) {
      final mask = maskPath!;
      final cached = _invertedPathCache[mask];
      if (cached != null) return cached;
      final cover = Path()..addRect(_cover);
      final inverted = Path.combine(PathOperation.difference, cover, mask);
      _invertedPathCache[mask] = inverted;
      return inverted;
    }
    final shape = Path();
    switch (kind) {
      case .rect:
        shape.addRect(rect!);
      case .rounded:
        shape.addRRect(rrect!);
      case .path:
        // Unreachable — handled above. Listed to satisfy exhaustiveness.
        shape.addPath(maskPath!, Offset.zero);
    }
    final cover = Path()..addRect(_cover);
    return Path.combine(PathOperation.difference, cover, shape);
  }
}
