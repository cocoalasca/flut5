import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import '../core/flut5_console.dart';
import '../core/render/flut5_render_queue.dart';

/// Stroke (outline) color, weight, cap, and join state.
mixin Flut5Stroke {
  /// Current canvas dimensions, used as the default gradient shader rect.
  /// Provided by [Flut5Engine].
  Size get canvasSize;

  /// The frame's render queue. Provided by [Flut5Engine]; used by
  /// [setLineDash] to push the active dash pattern into the queue.
  Flut5RenderQueue get renderQueue;

  /// The active batch path, or `null` when not batching.
  /// Provided by [Flut5Engine].
  Path? get batchPath;

  /// Current compositing mode for subsequent stroke paints.
  /// Provided by [Flut5Color].
  BlendMode get currentBlendMode;

  /// Current blend-mode state version.
  /// Provided by [Flut5Color].
  int get blendVersion;

  /// The active batch point buffer (flat x,y pairs), or `null` when not
  /// batching. Provided by [Flut5Engine]. Drained by [endBatch] into a single
  /// [MultiPointRenderItem] (one GPU call for all points).
  List<double>? get batchPoints;

  /// Called by primitives after they append geometry to [batchPath] so
  /// [endBatch] can skip an O(n) `path.getBounds()` emptiness check.
  /// Provided by [Flut5Engine].
  void markBatchDirty();

  /// Current stroke thickness in pixels. Defaults to 1.0.
  double strokeWeightVal = 1.0;

  /// Active line-dash pattern (alternating on/off lengths in pixels), or
  /// `null` when strokes are solid. Set via [setLineDash].
  List<double>? lineDashVal;

  /// Phase offset into the dash pattern, used to animate "marching ants".
  double lineDashOffsetVal = 0.0;

  /// Current stroke color. When a gradient is active this stays opaque so
  /// `strokeColor != Colors.transparent` still signals "has stroke" downstream.
  Color strokeColor = Colors.black;

  /// Current stroke gradient, or `null` when stroking with a solid color.
  Gradient? strokeGradient;

  /// Explicit rect the gradient shader is built against, or `null` to fall
  /// back to the full canvas rect.
  Rect? strokeGradientRect;

  /// Incremented whenever stroke state changes, used by primitives to avoid
  /// redundant Paint clones when the state hasn't changed between shapes.
  int _strokeVersion = 0;
  int get strokeVersion => _strokeVersion;

  /// What [stroke] / [noStroke] / [strokeWeight] last wrote into the paints.
  /// Lets a repeated call with the same value return early without trusting
  /// [strokeColor] and [strokeWeightVal], which are public fields a sketch
  /// can assign directly.
  Color _appliedStrokeColor = Colors.black;
  double _appliedStrokeWeight = 1.0;

  final Paint _strokePaint = Paint()
    ..color = Colors.black
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.miter;

  final Paint _strokeFillPaint = Paint()
    ..color = Colors.black
    ..style = PaintingStyle.fill
    ..strokeWidth = 1.0
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.miter;

  Gradient? _shaderGradient;
  Rect? _shaderRect;

  Paint? _snapshotStrokeClone;
  int _snapshotStrokeVersion = -1;
  int _snapshotStrokeBlendVersion = -1;
  Paint? _snapshotPointClone;
  int _snapshotPointVersion = -1;
  int _snapshotPointBlendVersion = -1;

  Paint? _snapshotStrokeNoShaderClone;
  int _snapshotStrokeNoShaderVersion = -1;
  int _snapshotStrokeNoShaderBlendVersion = -1;

  /// Per-shape gradient paints for the auto-bounds path, keyed by shape rect
  /// for the one gradient in [_autoGradientStrokeSource]. Mirrors
  /// `Flut5Fill._autoGradientFillPaints`:
  /// repeated bounds reuse one paint instead of a `createShader` per shape
  /// per frame; cleared when stroke/blend state changes, capped so all-miss
  /// workloads can't grow it without bound. Cached paints are never mutated
  /// after creation.
  final Map<Rect, Paint> _autoGradientStrokePaints = {};
  Gradient? _autoGradientStrokeSource;
  int _autoGradientStrokeVersion = -1;
  int _autoGradientStrokeBlendVersion = -1;
  static const int _autoGradientPaintCacheCap = 256;

  /// Sets the stroke used for subsequent shapes.
  ///
  /// Accepts a [Color] or a [Gradient] (linear/radial/sweep). When passing a
  /// [Gradient], the optional [x], [y], [w], [h] override the shader rect;
  /// otherwise the shader is built against the full canvas.
  /// ```dart
  /// flut5.stroke(Colors.blue);
  /// flut5.stroke(LinearGradient(colors: [Colors.red, Colors.blue]));
  /// flut5.stroke(RadialGradient(colors: [...]), 10, 10, 100, 100);
  /// ```
  void stroke(Object input, [double? x, double? y, double? w, double? h]) {
    if (batchPath != null) {
      throw FlutterError(
        'stroke() cannot be called inside beginBatch/endBatch',
      );
    }
    if (input is Color) {
      if (x != null || y != null || w != null || h != null) {
        Flut5Console.printLater(
          'stroke(): x/y/w/h are ignored when the first argument is a Color',
        );
      }
      // Unchanged: keep the version, and with it the paint snapshot the render
      // queue batches by — `stroke(c)` inside a loop must not split the batch.
      if (strokeGradient == null &&
          strokeColor == input &&
          _appliedStrokeColor == input) {
        return;
      }
      _appliedStrokeColor = input;
      strokeColor = input;
      strokeGradient = null;
      strokeGradientRect = null;
      _strokePaint.shader = null;
      _strokeFillPaint.shader = null;
      _strokePaint.color = input;
      _strokeFillPaint.color = input;
      _shaderGradient = null;
      _shaderRect = null;
    } else if (input is Gradient) {
      final rect = (x != null && y != null && w != null && h != null)
          ? Rect.fromLTWH(x, y, w, h)
          : null;
      // Unchanged: keeping the version also keeps the per-shape shader cache.
      if (strokeGradient == input &&
          strokeGradientRect == rect &&
          strokeColor == Colors.black &&
          _appliedStrokeColor == Colors.black) {
        return;
      }
      strokeGradient = input;
      strokeGradientRect = rect;
      _appliedStrokeColor = Colors.black;
      strokeColor = Colors.black;
      _strokePaint.color = Colors.black;
      _strokeFillPaint.color = Colors.black;
    } else {
      Flut5Console.printLater(
        'stroke(): expected Color or Gradient, got ${input.runtimeType} — ignored',
      );
      return;
    }
    _strokeVersion++;
  }

  /// Disables stroke — shapes will be drawn fill-only.
  void noStroke() {
    if (batchPath != null) {
      throw FlutterError(
        'noStroke() cannot be called inside beginBatch/endBatch',
      );
    }
    if (strokeGradient == null &&
        strokeColor == Colors.transparent &&
        _appliedStrokeColor == Colors.transparent) {
      return;
    }
    _appliedStrokeColor = Colors.transparent;
    strokeColor = Colors.transparent;
    strokeGradient = null;
    strokeGradientRect = null;
    _strokePaint.color = Colors.transparent;
    _strokeFillPaint.color = Colors.transparent;
    _strokePaint.shader = null;
    _strokeFillPaint.shader = null;
    _shaderGradient = null;
    _shaderRect = null;
    _strokeVersion++;
  }

  /// Sets the stroke thickness in pixels.
  /// ```dart
  /// flut5.strokeWeight(3.0);
  /// ```
  void strokeWeight(double weight) {
    if (batchPath != null) {
      throw FlutterError(
        'strokeWeight() cannot be called inside beginBatch/endBatch',
      );
    }
    if (strokeWeightVal == weight && _appliedStrokeWeight == weight) return;
    _appliedStrokeWeight = weight;
    strokeWeightVal = weight;
    _strokePaint.strokeWidth = weight;
    _strokeFillPaint.strokeWidth = weight;
    _strokeVersion++;
  }

  /// Sets the line-end cap style ([StrokeCap.round], [StrokeCap.square], [StrokeCap.butt]).
  void strokeCap(StrokeCap cap) {
    if (batchPath != null) {
      throw FlutterError(
        'strokeCap() cannot be called inside beginBatch/endBatch',
      );
    }
    if (_strokePaint.strokeCap == cap) return;
    _strokePaint.strokeCap = cap;
    _strokeFillPaint.strokeCap = cap;
    _strokeVersion++;
  }

  /// Sets the line-join style ([StrokeJoin.round], [StrokeJoin.miter], [StrokeJoin.bevel]).
  void strokeJoin(StrokeJoin join) {
    if (batchPath != null) {
      throw FlutterError(
        'strokeJoin() cannot be called inside beginBatch/endBatch',
      );
    }
    if (_strokePaint.strokeJoin == join) return;
    _strokePaint.strokeJoin = join;
    _strokeFillPaint.strokeJoin = join;
    _strokeVersion++;
  }

  /// Sets the line-dash [pattern] for subsequent strokes — a list of
  /// alternating "on" (drawn) and "off" (gap) lengths in pixels, matching
  /// p5.js / the HTML canvas `setLineDash`. An odd-length pattern is repeated
  /// to make it even (so `[10]` means 10 on, 10 off). [offset] shifts the
  /// starting phase, letting you animate a marching-ants effect.
  ///
  /// Pass an empty list to return to solid strokes (or call [noLineDash]).
  /// Unlike [strokeCap] / [strokeJoin], dashing is applied to the stroke's
  /// path geometry at draw time — Flutter's [Paint] has no dash support — so
  /// it is pushed into the render queue here.
  /// ```dart
  /// flut5.setLineDash([10, 5]);     // 10px dash, 5px gap
  /// flut5.setLineDash([10, 5], 3);  // shifted 3px
  /// ```
  void setLineDash(List<double> pattern, [double offset = 0.0]) {
    if (batchPath != null) {
      throw FlutterError(
        'setLineDash() cannot be called inside beginBatch/endBatch',
      );
    }
    // Unchanged: skip the flush and version bump a dash change needs.
    if (lineDashOffsetVal == offset &&
        (pattern.isEmpty
            ? lineDashVal == null
            : listEquals(lineDashVal, pattern))) {
      return;
    }
    lineDashVal = pattern.isEmpty ? null : List<double>.unmodifiable(pattern);
    lineDashOffsetVal = offset;
    renderQueue.setDashState(lineDashVal, offset);
    _strokeVersion++;
  }

  /// Disables line dashing — subsequent strokes are drawn solid.
  void noLineDash() {
    if (batchPath != null) {
      throw FlutterError(
        'noLineDash() cannot be called inside beginBatch/endBatch',
      );
    }
    if (lineDashVal == null && lineDashOffsetVal == 0.0) return;
    lineDashVal = null;
    lineDashOffsetVal = 0.0;
    renderQueue.setDashState(null, 0.0);
    _strokeVersion++;
  }

  void _refreshStrokeShader() {
    final gradient = strokeGradient;
    if (gradient == null) return;
    final rect =
        strokeGradientRect ??
        Rect.fromLTWH(0, 0, canvasSize.width, canvasSize.height);
    if (_shaderGradient != gradient || _shaderRect != rect) {
      final shader = gradient.createShader(rect);
      _strokePaint.shader = shader;
      _strokeFillPaint.shader = shader;
      _shaderGradient = gradient;
      _shaderRect = rect;
      _strokeVersion++;
    }
  }

  /// Returns the cached stroke [Paint], rebuilding its shader if the active
  /// gradient or target rect has changed since the last call.
  Paint getStrokePaint() {
    _refreshStrokeShader();
    _strokePaint.blendMode = currentBlendMode;
    return _strokePaint;
  }

  /// Returns the cached stroke-fill [Paint] (used for points), rebuilding
  /// its shader if the active gradient or target rect has changed.
  Paint getStrokeFillPaint() {
    _refreshStrokeShader();
    _strokeFillPaint.blendMode = currentBlendMode;
    return _strokeFillPaint;
  }

  /// Like [snapshotStrokePaint] but builds the gradient shader against
  /// [shapeBounds] when no explicit [strokeGradientRect] has been set.
  /// Gradient shapes never batch, but the per-shape paint (and its shader)
  /// is reused from [_autoGradientStrokePaints] whenever the same gradient
  /// and bounds recur — static geometry pays for `createShader` only once.
  Paint? snapshotStrokePaintForShape(Rect shapeBounds) {
    if (strokeColor == Colors.transparent) return null;
    final gradient = strokeGradient;
    if (gradient == null || strokeGradientRect != null) return snapshotStrokePaint();
    // getStrokePaint() first — it can bump the version when the shader rect
    // changes, and the cache epoch below must reflect that.
    final base = getStrokePaint();
    if (_autoGradientStrokeVersion != _strokeVersion ||
        _autoGradientStrokeBlendVersion != blendVersion ||
        !identical(_autoGradientStrokeSource, gradient)) {
      _autoGradientStrokePaints.clear();
      _autoGradientStrokeSource = gradient;
      _autoGradientStrokeVersion = _strokeVersion;
      _autoGradientStrokeBlendVersion = blendVersion;
    }
    final cached = _autoGradientStrokePaints[shapeBounds];
    if (cached != null) return cached;
    if (_autoGradientStrokePaints.length >= _autoGradientPaintCacheCap) {
      _autoGradientStrokePaints.clear();
    }
    final clone = base.clone()..shader = gradient.createShader(shapeBounds);
    _autoGradientStrokePaints[shapeBounds] = clone;
    return clone;
  }

  /// Like [snapshotStrokePaint] but with any gradient shader stripped.
  /// Identity-stable across calls until stroke state changes. Used by the
  /// text pipeline when an auto-bounds gradient is active: the render item
  /// builds the shader against the laid-out text bounds at draw time, so the
  /// queued paint must carry everything *except* the shader.
  Paint? snapshotStrokePaintNoShader() {
    if (strokeColor == Colors.transparent) return null;
    final paint = getStrokePaint();
    if (_snapshotStrokeNoShaderVersion != _strokeVersion ||
        _snapshotStrokeNoShaderBlendVersion != blendVersion) {
      _snapshotStrokeNoShaderClone = paint.clone()..shader = null;
      _snapshotStrokeNoShaderVersion = _strokeVersion;
      _snapshotStrokeNoShaderBlendVersion = blendVersion;
    }
    return _snapshotStrokeNoShaderClone;
  }

  /// Returns an identity-stable clone of the active stroke paint, or `null`
  /// when stroke is transparent. Stable across calls until stroke state
  /// changes, so the render queue can auto-batch by paint identity.
  Paint? snapshotStrokePaint() {
    if (strokeColor == Colors.transparent) return null;
    final paint = getStrokePaint();
    if (_snapshotStrokeVersion != _strokeVersion ||
        _snapshotStrokeBlendVersion != blendVersion) {
      _snapshotStrokeClone = paint.clone();
      _snapshotStrokeVersion = _strokeVersion;
      _snapshotStrokeBlendVersion = blendVersion;
    }
    return _snapshotStrokeClone;
  }

  /// Returns an identity-stable stroke-style point paint (with
  /// [StrokeCap.round]), or `null` when stroke is transparent. Used by
  /// [Canvas.drawRawPoints] batching.
  Paint? snapshotPointPaint() {
    if (strokeColor == Colors.transparent) return null;
    final paint = getStrokePaint();
    if (_snapshotPointVersion != _strokeVersion ||
        _snapshotPointBlendVersion != blendVersion) {
      _snapshotPointClone = paint.clone()..strokeCap = StrokeCap.round;
      _snapshotPointVersion = _strokeVersion;
      _snapshotPointBlendVersion = blendVersion;
    }
    return _snapshotPointClone;
  }
}
