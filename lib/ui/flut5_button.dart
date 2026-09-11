import 'package:flutter/material.dart';

import 'flut5_ui_element.dart';

base class Flut5Button(var String label, {required super.removeElement})
    extends Flut5UIElement {
  VoidCallback? _onPressed;
  VoidCallback? _onReleased;

  void onPressed(VoidCallback callback) {
    _onPressed = callback;
    notifyListeners();
  }

  /// Alias for [onPressed].
  void mousePressed(VoidCallback callback) => onPressed(callback);

  void onReleased(VoidCallback callback) {
    _onReleased = callback;
    notifyListeners();
  }

  /// Alias for [onReleased].
  void mouseReleased(VoidCallback callback) => onReleased(callback);

  void setLabel(String newLabel) {
    label = newLabel;
    notifyListeners();
  }

  @override
  Widget buildInner(BuildContext context) => Text(label);

  @override
  Widget buildContent(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onPressed,
        onTapUp: _onReleased != null ? (_) => _onReleased!() : null,
        child: super.buildContent(context),
      ),
    );
  }
}
