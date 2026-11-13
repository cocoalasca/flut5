import 'dart:ui' show Color;

// Colour literals the engine core needs. They live here so the renderer does
// not depend on a design-system package (`material_ui`) for two constants.
//
// Not exported from `package:flut5/flut5.dart`: sketch authors keep using
// `Colors.*` from their own Material import.
//
// Both values equal Material's `Colors.black` / `Colors.transparent` and are
// plain [Color]s rather than swatches, so `fillColor == Colors.transparent` in
// sketch code still holds.

/// Opaque black: p5's default fill and stroke colour.
const Color flut5Black = Color(0xFF000000);

/// Fully transparent: the `noFill()` / `noStroke()` sentinel the render paths
/// test against to skip a fill or stroke pass.
const Color flut5Transparent = Color(0x00000000);
