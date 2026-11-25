// ignore_for_file: constant_identifier_names

import 'package:flutter/widgets.dart';

import 'flut5_color_resolver.dart';

/// p5-style blend mode constants for [Flut5Color.blendMode].
const BlendMode BLEND = BlendMode.srcOver;
const BlendMode ADD = BlendMode.plus;
const BlendMode DARKEST = BlendMode.darken;
const BlendMode LIGHTEST = BlendMode.lighten;
const BlendMode EXCLUSION = BlendMode.exclusion;
const BlendMode MULTIPLY = BlendMode.multiply;
const BlendMode SCREEN = BlendMode.screen;
const BlendMode REPLACE = BlendMode.src;
const BlendMode REMOVE = BlendMode.dstOut;
const BlendMode DIFFERENCE = BlendMode.difference;
const BlendMode OVERLAY = BlendMode.overlay;
const BlendMode HARD_LIGHT = BlendMode.hardLight;
const BlendMode SOFT_LIGHT = BlendMode.softLight;
const BlendMode DODGE = BlendMode.colorDodge;
const BlendMode BURN = BlendMode.colorBurn;

/// Flutter does not expose a separate subtract blend operation; [DIFFERENCE]
/// is the closest available 2D equivalent.
const BlendMode SUBTRACT = BlendMode.difference;

/// Color utilities for the Flut5 Engine.
mixin Flut5Color {
  /// The active batch path, or `null` when not batching.
  ///
  /// Provided by [Flut5Engine]. Blend mode changes are blocked during a batch
  /// because all batched shapes share one captured paint state.
  Path? get batchPath;

  BlendMode _currentBlendMode = BLEND;
  int _blendVersion = 0;

  /// Current Flutter blend mode used by fill and stroke paints.
  BlendMode get currentBlendMode => _currentBlendMode;

  /// Incremented whenever [blendMode] changes, so paint snapshots can refresh.
  int get blendVersion => _blendVersion;

  /// Sets how subsequent shapes and text composite with pixels already on the
  /// canvas.
  ///
  /// Use the p5-style constants exported by Flut5:
  /// ```dart
  /// flut5.blendMode(ADD);
  /// flut5.blendMode(MULTIPLY);
  /// flut5.blendMode(BLEND);
  /// ```
  ///
  /// Flutter's [BlendMode] values are also accepted directly.
  void blendMode(BlendMode mode) {
    if (batchPath != null) {
      throw FlutterError(
        'blendMode() cannot be called inside beginBatch/endBatch',
      );
    }
    if (_currentBlendMode == mode) return;
    _currentBlendMode = mode;
    _blendVersion++;
  }

  /// Creates a [Color] from p5-style numeric values, a hex / CSS string,
  /// a numeric list, or an existing [Color].
  ///
  /// Accepted forms:
  /// - `color(gray)` / `color(gray, alpha)` — grayscale (`0..255`)
  /// - `color(r, g, b)` / `color(r, g, b, alpha)` — RGB / RGBA (`0..255`)
  /// - `color('#f0a')`, `color('#f0a8')`, `color('#ff00aa')`, `color('#ff00aa80')`
  ///   (plus optional `alpha` override: `color('#ff00aa', 128)`)
  /// - `color('rgb(255, 0, 170)')`, `color('rgba(255, 0, 170, 0.5)')`
  /// - `color([255, 0, 170])`, `color([255, 0, 170, 128])`
  /// - `color(Colors.red)` / `color(Colors.red, 128)`
  ///
  /// Throws an [ArgumentError] if the arguments do not form a valid color.
  Color color(Object input, [num? a, num? b, num? c]) {
    final res = flut5ResolveColorArgs('color', input, a, b, c);
    if (res.error != null) {
      throw ArgumentError(res.error);
    }
    if (res.warning != null) {
      throw ArgumentError(
        'color(): too many arguments when first argument is a ${input.runtimeType}',
      );
    }
    return res.color ?? Color(res.argb!);
  }

  /// Linearly blends [c1] toward [c2] by [amt] (0.0 = full [c1], 1.0 = full [c2]).
  ///
  /// Both [c1] and [c2] accept a [Color], a hex / CSS `rgb()`/`rgba()` string,
  /// a grayscale [num] (`0..255`), or a 1–4 element numeric [List].
  ///
  /// [amt] is clamped to `[0.0, 1.0]`.
  /// ```dart
  /// final mid = flut5.lerpColor(Colors.red, Colors.blue, 0.5);
  /// final hexMid = flut5.lerpColor('#ff0000', '#0000ff', 0.5);
  /// ```
  Color lerpColor(Object c1, Object c2, double amt) {
    final resolved1 = flut5TryResolveSingleColor(c1);
    if (resolved1 == null) {
      throw ArgumentError.value(c1, 'c1', 'Invalid color value for lerpColor()');
    }
    final resolved2 = flut5TryResolveSingleColor(c2);
    if (resolved2 == null) {
      throw ArgumentError.value(c2, 'c2', 'Invalid color value for lerpColor()');
    }
    return Color.lerp(resolved1, resolved2, amt.clamp(0.0, 1.0))!;
  }
}
