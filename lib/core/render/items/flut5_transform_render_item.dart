import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../flut5_render_item.dart';

enum TransformType { push, pop, translate, scale, rotate, matrix }

class TransformRenderItem._(
  final TransformType type, {
  final double? dx,
  final double? dy,
  final double? scaleX,
  final double? scaleY,

  /// Rotation about the z-axis in radians ([TransformType.rotate] only).
  /// A dedicated type — the common `rotate()` call would otherwise allocate
  /// a 16-double matrix per call per frame.
  final double? rotation,
  final Float64List? matrix,
}) extends Flut5RenderItem {
  TransformRenderItem.push() : this._(.push);
  TransformRenderItem.pop() : this._(.pop);
  TransformRenderItem.translate(double? dx, double? dy)
    : this._(.translate, dx: dx, dy: dy);
  TransformRenderItem.scale(double? scaleX, double? scaleY)
    : this._(.scale, scaleX: scaleX, scaleY: scaleY);
  TransformRenderItem.rotate(double? rotation)
    : this._(.rotate, rotation: rotation);
  TransformRenderItem.matrix(List<double> mat)
    : this._(.matrix, matrix: Float64List.fromList(mat));

  @override
  void execute(Canvas canvas) {
    switch (type) {
      case .push:
        canvas.save();
        break;
      case .pop:
        canvas.restore();
        break;
      case .translate:
        canvas.translate(dx!, dy!);
        break;
      case .scale:
        canvas.scale(scaleX!, scaleY ?? scaleX!);
        break;
      case .rotate:
        canvas.rotate(rotation!);
        break;
      case .matrix:
        canvas.transform(matrix!);
        break;
    }
  }
}
