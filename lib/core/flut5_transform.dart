import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../math/flut5_trigonometry.dart';
import 'render/flut5_render_queue.dart';

/// A mixin that provides canvas transformation capabilities for the Flut5 Engine.
///
/// Mirrors the p5.js transformation API:
/// * [push] / [pop] — save and restore the drawing state.
/// * [translate] — displace the coordinate system.
/// * [rotate], [rotateX], [rotateY], [rotateZ] — rotate the coordinate system.
/// * [scale] — scale the coordinate system.
/// * [shearX] / [shearY] — skew along an axis.
/// * [applyMatrix] — apply an arbitrary 4×4 transformation matrix.
/// * [resetMatrix] — restore the default transformation.
mixin Flut5Transform on Flut5Trigonometry {
  /// A pre-allocated matrix reused across calls to avoid per-frame allocation.
  ///
  /// IMPORTANT: This is safe only because [TransformRenderItem.matrix] copies
  /// the storage via `Float64List.fromList()`. If that copy is ever removed,
  /// all queued transforms would silently share the same backing data.
  final Matrix4 _scratch = Matrix4.identity();

  /// Access to the deferred rendering queue.
  Flut5RenderQueue get renderQueue;

  // ---------------------------------------------------------------------------
  // Push / Pop
  // ---------------------------------------------------------------------------

  /// Saves the current drawing style settings and transformations.
  ///
  /// Pure-translation scopes are folded by the render queue: no canvas
  /// `save()` is emitted unless a rotation/scale/skew (or a clip) makes one
  /// necessary, so batched shapes keep coalescing across push/pop pairs.
  void push() => renderQueue.pushTransform();

  /// Restores the drawing state to what it was before the last [push] call.
  void pop() => renderQueue.popTransform();

  // ---------------------------------------------------------------------------
  // Translate
  // ---------------------------------------------------------------------------

  /// Displaces objects within the display window.
  ///
  /// [x] and [y] specify the horizontal / vertical translation.
  /// The optional [z] applies a depth translation via a 4×4 matrix.
  ///
  /// 2D translations are folded into geometry at append time (no render
  /// item is queued), so translating between shapes doesn't break batching.
  void translate(double x, double y, [double z = 0]) {
    if (z != 0) {
      _scratch.setIdentity();
      _scratch.setTranslationRaw(x, y, z);
      renderQueue.applyTransform(TransformRenderItem.matrix(_scratch.storage));
    } else {
      renderQueue.translateTransform(x, y);
    }
  }

  // ---------------------------------------------------------------------------
  // Rotate
  // ---------------------------------------------------------------------------

  /// Rotates the coordinate system.
  ///
  /// The [angle] respects the current [AngleMode] set by the engine.
  void rotate(double angle) {
    renderQueue.applyTransform(TransformRenderItem.rotate(toRadians(angle)));
  }

  /// Rotates the coordinate system about the x-axis.
  void rotateX(double angle) {
    _scratch.setIdentity();
    _scratch.setRotationX(toRadians(angle));
    renderQueue.applyTransform(TransformRenderItem.matrix(_scratch.storage));
  }

  /// Rotates the coordinate system about the y-axis.
  void rotateY(double angle) {
    _scratch.setIdentity();
    _scratch.setRotationY(toRadians(angle));
    renderQueue.applyTransform(TransformRenderItem.matrix(_scratch.storage));
  }

  /// Rotates the coordinate system about the z-axis.
  /// Equivalent to [rotate].
  void rotateZ(double angle) => rotate(angle);

  // ---------------------------------------------------------------------------
  // Scale
  // ---------------------------------------------------------------------------

  /// Scales the coordinate system.
  ///
  /// If [y] is omitted, both axes are scaled uniformly by [x].
  void scale(double x, [double? y]) => renderQueue.applyTransform(TransformRenderItem.scale(x, y ?? x));

  // ---------------------------------------------------------------------------
  // Shear
  // ---------------------------------------------------------------------------

  /// Shears the x-axis by [angle] so that shapes appear skewed.
  ///
  /// Internally uses `tan(angle)` to compute the shear factor,
  /// matching the p5.js `shearX()` behaviour.
  void shearX(double angle) {
    _scratch.setIdentity();
    _scratch.setEntry(0, 1, math.tan(toRadians(angle)));
    renderQueue.applyTransform(TransformRenderItem.matrix(_scratch.storage));
  }

  /// Shears the y-axis by [angle] so that shapes appear skewed.
  ///
  /// Internally uses `tan(angle)` to compute the shear factor,
  /// matching the p5.js `shearY()` behaviour.
  void shearY(double angle) {
    _scratch.setIdentity();
    _scratch.setEntry(1, 0, math.tan(toRadians(angle)));
    renderQueue.applyTransform(TransformRenderItem.matrix(_scratch.storage));
  }

  // ---------------------------------------------------------------------------
  // Matrix
  // ---------------------------------------------------------------------------

  /// Applies a 4×4 transformation matrix to the coordinate system.
  ///
  /// Expects a 16-element list in column-major order.
  void applyMatrix(List<double> matrix4x4) {
    if (matrix4x4.length != 16) {
      throw ArgumentError(
        'applyMatrix requires a 16-element List representing a 4×4 matrix.',
      );
    }
    // Copy into the scratch matrix to avoid a fresh Float64List allocation.
    _scratch.storage.setAll(0, matrix4x4);
    renderQueue.applyTransform(TransformRenderItem.matrix(_scratch.storage));
  }

  /// Resets the coordinate system to the identity matrix.
  ///
  /// Requires a prior [push] call — it pops the current state and immediately
  /// pushes a fresh one. Calling without a matching [push] will pop the root
  /// canvas save state, potentially corrupting subsequent rendering.
  void resetMatrix() {
    renderQueue.popTransform();
    renderQueue.pushTransform();
  }
}
