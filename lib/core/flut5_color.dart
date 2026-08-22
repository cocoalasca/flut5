// ignore_for_file: constant_identifier_names

import 'package:flutter/material.dart';

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

  /// Linearly blends [c1] toward [c2] by [amt] (0.0 = full [c1], 1.0 = full [c2]).
  ///
  /// [amt] is clamped to [0.0, 1.0].
  /// ```dart
  /// final mid = flut5.lerpColor(Colors.red, Colors.blue, 0.5);
  /// ```
  Color lerpColor(Color c1, Color c2, double amt) {
    return Color.lerp(c1, c2, amt.clamp(0.0, 1.0))!;
  }
}
