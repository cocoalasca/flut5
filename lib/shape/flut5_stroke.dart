import 'dart:typed_data';
import 'dart:ui' as ui show ColorSpace;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import '../core/flut5_color_resolver.dart';
import '../core/flut5_engine_colors.dart';
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
  Color strokeColor = flut5Black;

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
  Color _appliedStrokeColor = flut5Black;
  double _appliedStrokeWeight = 1.0;

  final Paint _strokePaint = Paint()
    ..color = flut5Black
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.miter;

  final Paint _strokeFillPaint = Paint()
    ..color = flut5Black
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

  /// Snapshots of plain colour strokes, keyed by `(color, strokeWidth, cap,
  /// join)`, mirroring `Flut5Fill._plainFillSnapshots`. Lets stroke-only and
  /// point/line palette sketches return the identical [Paint] instance whenever
  /// a style recurs, unlocking open multi-colour batching and avoiding a
  /// `Paint` clone on every colour switch.
  static const int _plainStrokeSnapshotSlots = 1024;
  static const int _plainStrokeSnapshotProbes = 4;

  final List<Color?> _plainStrokeColors = List.filled(
    _plainStrokeSnapshotSlots,
    null,
  );
  final Float64List _plainStrokeWidths = Float64List(_plainStrokeSnapshotSlots);
  final Uint8List _plainStrokeStyleBits = Uint8List(_plainStrokeSnapshotSlots);
  final List<Paint?> _plainStrokeSnapshots = List.filled(
    _plainStrokeSnapshotSlots,
    null,
  );
  int _plainStrokeBlendVersion = -1;
  int _plainStrokeReplaced = 0;

  final List<Color?> _plainPointColors = List.filled(
    _plainStrokeSnapshotSlots,
    null,
  );
  final Float64List _plainPointWidths = Float64List(_plainStrokeSnapshotSlots);
  final Uint8List _plainPointJoins = Uint8List(_plainStrokeSnapshotSlots);
  final List<Paint?> _plainPointSnapshots = List.filled(
    _plainStrokeSnapshotSlots,
    null,
  );
  int _plainPointBlendVersion = -1;
  int _plainPointReplaced = 0;

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
  /// Accepts:
  /// - A [Color], optionally with an alpha (`0..255`) override:
  ///   `stroke(Colors.blue)`, `stroke(Colors.blue, 128)`
  /// - p5-style numeric values (`0..255`):
  ///   `stroke(gray)`, `stroke(gray, alpha)`, `stroke(r, g, b)`, `stroke(r, g, b, alpha)`
  /// - A hex or CSS `rgb()`/`rgba()` string (with optional alpha override):
  ///   `stroke('#00aaff')`, `stroke('#0af8')`, `stroke('#00aaff80')`
  /// - A 1–4 element numeric list: `stroke([0, 170, 255])`
  /// - A [Gradient] (linear/radial/sweep); optional [a], [b], [c], [d] specify
  ///   the shader rect `(x, y, w, h)` (otherwise built against the full canvas).
  /// ```dart
  /// flut5.stroke(Colors.blue);
  /// flut5.stroke(255, 100, 50);
  /// flut5.stroke('#00aaff');
  /// flut5.stroke(LinearGradient(colors: [Colors.red, Colors.blue]));
  /// flut5.stroke(RadialGradient(colors: [...]), 10, 10, 100, 100);
  /// ```
  void stroke(Object input, [num? a, num? b, num? c, num? d]) {
    if (batchPath != null) {
      throw FlutterError(
        'stroke() cannot be called inside beginBatch/endBatch',
      );
    }
    if (input is Color && a == null && b == null && c == null && d == null) {
      _applyStrokeColor(input);
      return;
    }
    if (input is Gradient) {
      final rect = (a != null && b != null && c != null && d != null)
          ? Rect.fromLTWH(
              a.toDouble(),
              b.toDouble(),
              c.toDouble(),
              d.toDouble(),
            )
          : null;
      // Unchanged: keeping the version also keeps the per-shape shader cache.
      if (strokeGradient == input &&
          strokeGradientRect == rect &&
          strokeColor == flut5Black &&
          _appliedStrokeColor == flut5Black) {
        return;
      }
      strokeGradient = input;
      strokeGradientRect = rect;
      _appliedStrokeColor = flut5Black;
      strokeColor = flut5Black;
      _strokePaint.color = flut5Black;
      _strokeFillPaint.color = flut5Black;
      _strokeVersion++;
      return;
    }
    final res = flut5ResolveColorArgs('stroke', input, a, b, c, d, true);
    if (res.error != null) {
      Flut5Console.printLater('${res.error} — ignored');
      return;
    }
    if (res.warning != null) {
      Flut5Console.printLater(res.warning!);
    }
    if (res.color != null) {
      _applyStrokeColor(res.color!);
    } else {
      _applyStrokeArgb(res.argb!);
    }
  }

  void _applyStrokeArgb(int argb) {
    if (strokeGradient == null &&
        strokeColor.colorSpace == ui.ColorSpace.sRGB &&
        strokeColor.toARGB32() == argb &&
        _appliedStrokeColor.colorSpace == ui.ColorSpace.sRGB &&
        _appliedStrokeColor.toARGB32() == argb) {
      return;
    }
    _applyStrokeColor(Color(argb));
  }

  void _applyStrokeColor(Color color) {
    // Unchanged: keep the version, and with it the paint snapshot the render
    // queue batches by — `stroke(c)` inside a loop must not split the batch.
    if (strokeGradient == null &&
        strokeColor == color &&
        _appliedStrokeColor == color) {
      return;
    }
    _appliedStrokeColor = color;
    strokeColor = color;
    strokeGradient = null;
    strokeGradientRect = null;
    _strokePaint.shader = null;
    _strokeFillPaint.shader = null;
    _strokePaint.color = color;
    _strokeFillPaint.color = color;
    _shaderGradient = null;
    _shaderRect = null;
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
        strokeColor == flut5Transparent &&
        _appliedStrokeColor == flut5Transparent) {
      return;
    }
    _appliedStrokeColor = flut5Transparent;
    strokeColor = flut5Transparent;
    strokeGradient = null;
    strokeGradientRect = null;
    _strokePaint.color = flut5Transparent;
    _strokeFillPaint.color = flut5Transparent;
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
    if (strokeColor == flut5Transparent) return null;
    final gradient = strokeGradient;
    if (gradient == null || strokeGradientRect != null) {
      return snapshotStrokePaint();
    }
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
    if (strokeColor == flut5Transparent) return null;
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
  /// changes, so the render queue can auto-batch by paint identity. A plain
  /// colour stroke gets the same instance back whenever its colour, weight,
  /// cap, and join recur, so never mutate the returned [Paint].
  Paint? snapshotStrokePaint() {
    if (strokeColor == flut5Transparent) return null;
    final paint = getStrokePaint();
    if (_snapshotStrokeVersion != _strokeVersion ||
        _snapshotStrokeBlendVersion != blendVersion) {
      _snapshotStrokeClone = strokeGradient == null
          ? _plainStrokeSnapshot(paint)
          : paint.clone();
      _snapshotStrokeVersion = _strokeVersion;
      _snapshotStrokeBlendVersion = blendVersion;
    }
    return _snapshotStrokeClone;
  }

  Paint _plainStrokeSnapshot(Paint paint) {
    final colors = _plainStrokeColors;
    final widths = _plainStrokeWidths;
    final styleBits = _plainStrokeStyleBits;
    final snapshots = _plainStrokeSnapshots;
    if (_plainStrokeBlendVersion != blendVersion) {
      colors.fillRange(0, _plainStrokeSnapshotSlots, null);
      snapshots.fillRange(0, _plainStrokeSnapshotSlots, null);
      _plainStrokeBlendVersion = blendVersion;
    }
    final color = paint.color;
    final width = paint.strokeWidth;
    final bits = paint.strokeCap.index | (paint.strokeJoin.index << 2);
    final rawHash =
        color.toARGB32() ^ (width.hashCode * 0x517CC1B7) ^ (bits * 0x9E3779B1);
    final home = (rawHash * 0x9E3779B1) >>> 12;
    var slot = 0;
    for (var probe = 0; probe < _plainStrokeSnapshotProbes; probe++) {
      slot = (home + probe) & (_plainStrokeSnapshotSlots - 1);
      final kept = colors[slot];
      if (kept == null) break;
      if (kept == color && widths[slot] == width && styleBits[slot] == bits) {
        return snapshots[slot]!;
      }
      if (probe == _plainStrokeSnapshotProbes - 1) {
        slot =
            (home + _plainStrokeReplaced++ % _plainStrokeSnapshotProbes) &
            (_plainStrokeSnapshotSlots - 1);
      }
    }
    final snapshot = paint.clone();
    colors[slot] = color;
    widths[slot] = width;
    styleBits[slot] = bits;
    snapshots[slot] = snapshot;
    return snapshot;
  }

  /// Returns an identity-stable stroke-style point paint (with
  /// [StrokeCap.round]), or `null` when stroke is transparent. Used by
  /// [Canvas.drawRawPoints] batching.
  Paint? snapshotPointPaint() {
    if (strokeColor == flut5Transparent) return null;
    final paint = getStrokePaint();
    if (_snapshotPointVersion != _strokeVersion ||
        _snapshotPointBlendVersion != blendVersion) {
      _snapshotPointClone = strokeGradient == null
          ? _plainPointSnapshot(paint)
          : (paint.clone()..strokeCap = StrokeCap.round);
      _snapshotPointVersion = _strokeVersion;
      _snapshotPointBlendVersion = blendVersion;
    }
    return _snapshotPointClone;
  }

  Paint _plainPointSnapshot(Paint paint) {
    final colors = _plainPointColors;
    final widths = _plainPointWidths;
    final joins = _plainPointJoins;
    final snapshots = _plainPointSnapshots;
    if (_plainPointBlendVersion != blendVersion) {
      colors.fillRange(0, _plainStrokeSnapshotSlots, null);
      snapshots.fillRange(0, _plainStrokeSnapshotSlots, null);
      _plainPointBlendVersion = blendVersion;
    }
    final color = paint.color;
    final width = paint.strokeWidth;
    final join = paint.strokeJoin.index;
    final rawHash =
        color.toARGB32() ^ (width.hashCode * 0x517CC1B7) ^ (join * 0x9E3779B1);
    final home = (rawHash * 0x9E3779B1) >>> 12;
    var slot = 0;
    for (var probe = 0; probe < _plainStrokeSnapshotProbes; probe++) {
      slot = (home + probe) & (_plainStrokeSnapshotSlots - 1);
      final kept = colors[slot];
      if (kept == null) break;
      if (kept == color && widths[slot] == width && joins[slot] == join) {
        return snapshots[slot]!;
      }
      if (probe == _plainStrokeSnapshotProbes - 1) {
        slot =
            (home + _plainPointReplaced++ % _plainStrokeSnapshotProbes) &
            (_plainStrokeSnapshotSlots - 1);
      }
    }
    final snapshot = paint.clone()..strokeCap = StrokeCap.round;
    colors[slot] = color;
    widths[slot] = width;
    joins[slot] = join;
    snapshots[slot] = snapshot;
    return snapshot;
  }
}
