import 'package:flutter/material.dart';
import 'flut5_ui_element.dart';

base class Flut5Label extends Flut5UIElement {
  String text;
  TextStyle? textStyle;
  VoidCallback? _onPressed;

  Flut5Label(
    this.text, {
    required super.removeElement,
  });

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
