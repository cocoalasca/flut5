import 'package:flutter/widgets.dart';

/// One colour of a `beginPixelate()` palette.
///
/// A block whose average colour is nearest [fill] is drawn in [fill]. Give
/// the colour a [stroke] to outline it: a block of this colour is drawn in
/// [stroke] instead when one of its four side neighbours holds another
/// palette colour or nothing at all. The outline sits inside the area, one
/// block thick; diagonal neighbours and the canvas border don't count.
///
/// Where two colours that both have a stroke meet, the one later in the
/// palette draws the edge and the earlier one keeps its fill there, so the
/// outline stays one block thick.
///
/// ```dart
/// beginPixelate(6, [
///   PaletteColor(Color(0xFF1A1C2C)),
///   PaletteColor(Color(0xFFEF7D57), stroke: Color(0xFF5D275D)),
/// ]);
/// ```
class const PaletteColor(
  /// The colour a block takes when its average is nearest this one.
  final Color fill, {

  /// The colour this one's blocks take along an edge, or `null` for no
  /// outline.
  final Color? stroke,
}) {
  @override
  bool operator ==(Object other) =>
      other is PaletteColor && other.fill == fill && other.stroke == stroke;

  @override
  int get hashCode => Object.hash(fill, stroke);

  @override
  String toString() => stroke == null
      ? 'PaletteColor($fill)'
      : 'PaletteColor($fill, stroke: $stroke)';
}
