import 'package:flutter/material.dart';

import 'flut5_ui_element.dart';

base class Flut5Label(var String text, {required super.removeElement})
    extends Flut5UIElement {
  TextStyle? textStyle;
  VoidCallback? _onPressed;

  void setText(String newText) {
    text = newText;
    notifyListeners();
  }

  void setTextStyle(TextStyle newStyle) {
    textStyle = newStyle;
    notifyListeners();
  }

  void onPressed(VoidCallback callback) {
    _onPressed = callback;
    notifyListeners();
  }

  /// Alias for [onPressed].
  void mousePressed(VoidCallback callback) => onPressed(callback);

  @override
  Widget buildInner(BuildContext context) => Text(text, style: textStyle);

  @override
  Widget buildContent(BuildContext context) {
    if (_onPressed == null) return super.buildContent(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onPressed,
        child: super.buildContent(context),
      ),
    );
  }
}
