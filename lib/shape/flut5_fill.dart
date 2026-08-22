import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../core/flut5_console.dart';
import '../core/render/flut5_render_queue.dart';

/// Fill color state and background drawing.
mixin Flut5Fill {
  Canvas get canvas;
  Flut5RenderQueue get renderQueue;

  /// Current canvas dimensions, used as the default gradient shader rect.
  /// Provided by [Flut5Engine].
  Size get canvasSize;

  /// The active batch path, or `null` when not batching.
  /// Provided by [Flut5Engine].
  Path? get batchPath;

  /// Current compositing mode for subsequent fill paints.
  /// Provided by [Flut5Color].
  BlendMode get currentBlendMode;

  /// Current blend-mode state version.
  /// Provided by [Flut5Color].
  int get blendVersion;

  /// Called by primitives after they append geometry to [batchPath].
  /// Provided by [Flut5Engine].
  void markBatchDirty();

  /// Current fill color. When a gradient is active this stays opaque so
  /// `fillColor != Colors.transparent` still signals "has fill" downstream.
  Color fillColor = Colors.black;

  /// Current fill gradient, or `null` when filling with a solid color.
  Gradient? fillGradient;

  /// Explicit rect the gradient shader is built against, or `null` to fall
  /// back to the full canvas rect.
  Rect? fillGradientRect;

  /// Incremented whenever fill state changes, used by primitives to avoid
  /// redundant Paint clones when the state hasn't changed between shapes.
  int _fillVersion = 0;
  int get fillVersion => _fillVersion;

  final Paint _fillPaint = Paint()
    ..color = Colors.black
    ..style = PaintingStyle.fill;

  Gradient? _shaderGradient;
  Rect? _shaderRect;

  Paint? _snapshotFillClone;
  int _snapshotFillVersion = -1;
  int _snapshotFillBlendVersion = -1;

  Paint? _snapshotFillNoShaderClone;
  int _snapshotFillNoShaderVersion = -1;
  int _snapshotFillNoShaderBlendVersion = -1;

  /// Per-shape gradient paints for the auto-bounds path, keyed by
  /// (gradient, shape rect). `createShader` allocates a native Skia object,
  /// so shapes whose bounds repeat across frames (static geometry) reuse one
  /// paint instead of allocating a shader per shape per frame. Cleared when
  /// fill/blend state changes; capped so animated bounds (all-miss workloads)
  /// can't grow it without bound. Cached paints are never mutated after
  /// creation, so queued render items can hold them safely across frames.
  final Map<(Gradient, Rect), Paint> _autoGradientFillPaints = {};
  int _autoGradientFillVersion = -1;
  int _autoGradientFillBlendVersion = -1;
  static const int _autoGradientPaintCacheCap = 256;

  Gradient? _backgroundShaderGradient;
  Rect? _backgroundShaderRect;
  ui.Shader? _backgroundShader;

  /// Sets the fill used for subsequent shapes.
  ///
  /// Accepts a [Color] or a [Gradient] (linear/radial/sweep). When passing a
  /// [Gradient], the optional [x], [y], [w], [h] override the shader rect;
  /// otherwise the shader is built against the full canvas.
  /// ```dart
  /// flut5.fill(Colors.red);
  /// flut5.fill(LinearGradient(colors: [Colors.red, Colors.blue]));
  /// flut5.fill(RadialGradient(colors: [...]), 10, 10, 100, 100);
  /// ```
  void fill(Object input, [double? x, double? y, double? w, double? h]) {
    if (batchPath != null) {
      throw FlutterError('fill() cannot be called inside beginBatch/endBatch');
    }
    if (input is Color) {
      if (x != null || y != null || w != null || h != null) {
        Flut5Console.printLater(
          'fill(): x/y/w/h are ignored when the first argument is a Color',
        );
      }
      fillColor = input;
      fillGradient = null;
      fillGradientRect = null;
      _fillPaint.shader = null;
      _fillPaint.color = input;
      _shaderGradient = null;
      _shaderRect = null;
    } else if (input is Gradient) {
      fillGradient = input;
      fillGradientRect = (x != null && y != null && w != null && h != null)
          ? Rect.fromLTWH(x, y, w, h)
          : null;
      fillColor = Colors.black;
      _fillPaint.color = Colors.black;
    } else {
      Flut5Console.printLater(
        'fill(): expected Color or Gradient, got ${input.runtimeType} — ignored',
      );
      return;
    }
    _fillVersion++;
  }

  /// Disables fill — shapes will be drawn outline-only.
  void noFill() {
    if (batchPath != null) {
      throw FlutterError(
        'noFill() cannot be called inside beginBatch/endBatch',
      );
    }
    fillColor = Colors.transparent;
    fillGradient = null;
    fillGradientRect = null;
    _fillPaint.color = Colors.transparent;
    _fillPaint.shader = null;
    _shaderGradient = null;
    _shaderRect = null;
    _fillVersion++;
  }

  /// Like [snapshotFillPaint] but builds the gradient shader against
  /// [shapeBounds] when no explicit [fillGradientRect] has been set.
  /// Gradient shapes never batch, but the per-shape paint (and its shader)
  /// is reused from [_autoGradientFillPaints] whenever the same gradient and
  /// bounds recur — static geometry pays for `createShader` only once.
  Paint? snapshotFillPaintForShape(Rect shapeBounds) {
    if (fillColor == Colors.transparent) return null;
    final gradient = fillGradient;
    if (gradient == null || fillGradientRect != null) return snapshotFillPaint();
    // getFillPaint() first — it can bump the version when the shader rect
    // changes, and the cache epoch below must reflect that.
    final base = getFillPaint();
    if (_autoGradientFillVersion != _fillVersion ||
        _autoGradientFillBlendVersion != blendVersion) {
      _autoGradientFillPaints.clear();
      _autoGradientFillVersion = _fillVersion;
      _autoGradientFillBlendVersion = blendVersion;
    }
    final key = (gradient, shapeBounds);
    final cached = _autoGradientFillPaints[key];
    if (cached != null) return cached;
    if (_autoGradientFillPaints.length >= _autoGradientPaintCacheCap) {
      _autoGradientFillPaints.clear();
    }
    final clone = base.clone()..shader = gradient.createShader(shapeBounds);
    _autoGradientFillPaints[key] = clone;
    return clone;
  }

  /// Returns an identity-stable clone of the active fill paint, or `null`
  /// when fill is transparent. The same [Paint] instance is returned across
  /// calls until fill state changes (version bump), allowing the render
  /// queue to auto-batch by paint identity.
  Paint? snapshotFillPaint() {
    if (fillColor == Colors.transparent) return null;
    final paint = getFillPaint();
    if (_snapshotFillVersion != _fillVersion ||
        _snapshotFillBlendVersion != blendVersion) {
      _snapshotFillClone = paint.clone();
      _snapshotFillVersion = _fillVersion;
      _snapshotFillBlendVersion = blendVersion;
    }
    return _snapshotFillClone;
  }

  /// Like [snapshotFillPaint] but with any gradient shader stripped.
  /// Identity-stable across calls until fill state changes. Used by the text
  /// pipeline when an auto-bounds gradient is active: the render item builds
  /// the shader against the laid-out text bounds at draw time, so the queued
  /// paint must carry everything *except* the shader.
  Paint? snapshotFillPaintNoShader() {
    if (fillColor == Colors.transparent) return null;
    final paint = getFillPaint();
    if (_snapshotFillNoShaderVersion != _fillVersion ||
        _snapshotFillNoShaderBlendVersion != blendVersion) {
      _snapshotFillNoShaderClone = paint.clone()..shader = null;
      _snapshotFillNoShaderVersion = _fillVersion;
      _snapshotFillNoShaderBlendVersion = blendVersion;
    }
    return _snapshotFillNoShaderClone;
  }

  /// Returns the cached fill [Paint], rebuilding its shader if the active
  /// gradient or target rect has changed since the last call.
  Paint getFillPaint() {
    final gradient = fillGradient;
    if (gradient != null) {
      final rect =
          fillGradientRect ??
          Rect.fromLTWH(0, 0, canvasSize.width, canvasSize.height);
      if (_shaderGradient != gradient || _shaderRect != rect) {
        _fillPaint.shader = gradient.createShader(rect);
        _shaderGradient = gradient;
        _shaderRect = rect;
        _fillVersion++;
      }
    }
    _fillPaint.blendMode = currentBlendMode;
    return _fillPaint;
  }

  /// Clears the entire canvas with [input], accepting a [Color] or a
  /// [Gradient]. When passing a [Gradient], the optional [x], [y], [w], [h]
  /// override the shader rect; otherwise it's built against the full canvas.
  ///
  /// Call at the start of `draw()` to redraw the background each frame.
  /// ```dart
  /// flut5.background(Colors.white);
  /// flut5.background(LinearGradient(colors: [Colors.black, Colors.blue]));
  /// flut5.background(RadialGradient(colors: [...]), 0, 0, 200, 200);
  /// ```
  void background(Object input, [double? x, double? y, double? w, double? h]) {
    if (input is Color) {
      if (x != null || y != null || w != null || h != null) {
        Flut5Console.printLater(
          'background(): x/y/w/h are ignored when the first argument is a Color',
        );
      }
      renderQueue.enqueue(BackgroundRenderItem(input));
    } else if (input is Gradient) {
      final hasRect = x != null && y != null && w != null && h != null;
      final rect = hasRect
          ? Rect.fromLTWH(x, y, w, h)
          : Rect.fromLTWH(0, 0, canvasSize.width, canvasSize.height);
      final isOpaque = _gradientIsOpaque(input);
      final paint = Paint()..shader = _backgroundShaderFor(input, rect);
      if (!hasRect && isOpaque) {
        paint.blendMode = BlendMode.src;
      }
      renderQueue.enqueue(
        BackgroundRenderItem.shader(
          paint,
          hasRect ? rect : null,
          isOpaque: isOpaque,
        ),
      );
    } else {
      Flut5Console.printLater(
        'background(): expected Color or Gradient, got ${input.runtimeType} — ignored',
      );
    }
  }

  ui.Shader _backgroundShaderFor(Gradient gradient, Rect rect) {
    if (_backgroundShaderGradient != gradient ||
        _backgroundShaderRect != rect) {
      _backgroundShader = gradient.createShader(rect);
      _backgroundShaderGradient = gradient;
      _backgroundShaderRect = rect;
    }
    return _backgroundShader!;
  }

  bool _gradientIsOpaque(Gradient gradient) {
    for (final color in gradient.colors) {
      if (color.a != 1.0) return false;
    }
    return true;
  }
}
