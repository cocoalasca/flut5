import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../flut5_render_item.dart';

enum TransformType { push, pop, translate, scale, rotate, matrix }

class TransformRenderItem extends Flut5RenderItem {
  final TransformType type;
  final double? dx;
  final double? dy;
  final double? scaleX;
  final double? scaleY;

  /// Rotation about the z-axis in radians ([TransformType.rotate] only).
  /// A dedicated type — the common `rotate()` call would otherwise allocate
  /// a 16-double matrix per call per frame.
  final double? rotation;
  final Float64List? matrix;

  TransformRenderItem.push() : type = .push, dx = null, dy = null, scaleX = null, scaleY = null, rotation = null, matrix = null;
  TransformRenderItem.pop() : type = .pop, dx = null, dy = null, scaleX = null, scaleY = null, rotation = null, matrix = null;
  TransformRenderItem.translate(this.dx, this.dy) : type = .translate, scaleX = null, scaleY = null, rotation = null, matrix = null;
  TransformRenderItem.scale(this.scaleX, this.scaleY) : type = .scale, dx = null, dy = null, rotation = null, matrix = null;
  TransformRenderItem.rotate(this.rotation) : type = .rotate, dx = null, dy = null, scaleX = null, scaleY = null, matrix = null;

  TransformRenderItem.matrix(List<double> mat)
      : type = .matrix,
        matrix = Float64List.fromList(mat),
        dx = null, dy = null, scaleX = null, scaleY = null, rotation = null;

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
