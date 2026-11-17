import 'package:flutter/widgets.dart';

import 'flut5_ui_element.dart';
import 'flut5_button.dart';
import 'flut5_label.dart';
import 'flut5_container.dart';
import 'flut5_slider.dart';
import 'flut5_toggle.dart';
import 'flut5_checkbox.dart';

/// Creates and owns a sketch's widgets: buttons, labels, sliders, toggles,
/// checkboxes and containers.
///
/// Sketches reach it as `flut5Widgets`, unprefixed from any [Flut5] subclass:
///
/// ```dart
/// final reset = flut5Widgets.createButton('Reset');
/// reset.position(20, 20);
/// ```
///
/// Each widget starts at `(0, 0)` and is drawn above the canvas, placed by
/// its `position(x, y)`. A widget appended to a container is laid out by
/// that container instead.
final class Flut5Widgets() extends ChangeNotifier {
  final List<Flut5UIElement> _elements = [];
  List<Flut5UIElement> get elements => List.unmodifiable(_elements);
  bool _disposed = false;

  int _transitionMs = 300;
  int get transitionMs => _transitionMs;

  /// Sets the duration in milliseconds for widget style and position
  /// transitions (hover, click, `position`). Defaults to 300; call with 0 to
  /// turn animation off.
  void transitionDuration(int ms) {
    _transitionMs = ms;
    notifyListeners();
  }

  Flut5Button createButton(String label) {
    var btn = Flut5Button(label, removeElement: _removeElement);
    _elements.add(btn);
    notifyListeners();
    return btn;
  }

  Flut5Label createLabel(String text) {
    var lbl = Flut5Label(text, removeElement: _removeElement);
    _elements.add(lbl);
    notifyListeners();
    return lbl;
  }

  Flut5Slider createSlider(double min, double max, [double value = 0.0]) {
    var sld = Flut5Slider(
      min,
      max,
      value: value,
      removeElement: _removeElement,
    );
    _elements.add(sld);
    notifyListeners();
    return sld;
  }

  Flut5Toggle createToggle([bool value = false]) {
    var toggle = Flut5Toggle(value: value, removeElement: _removeElement);
    _elements.add(toggle);
    notifyListeners();
    return toggle;
  }

  Flut5Checkbox createCheckbox([bool value = false]) {
    var checkbox = Flut5Checkbox(value: value, removeElement: _removeElement);
    _elements.add(checkbox);
    notifyListeners();
    return checkbox;
  }

  Flut5Container createContainer({
    String direction = 'row',
    double gap = 0,
    String align = 'start',
    String justify = 'start',
  }) {
    var container = Flut5Container(
      direction: direction,
      gap: gap,
      align: align,
      justify: justify,
      removeElement: _removeElement,
      detachElement: _detachElement,
    );
    _elements.add(container);
    notifyListeners();
    return container;
  }

  void _removeElement(Flut5UIElement element) {
    element.dispose();
    _elements.remove(element);
    if (!_disposed) notifyListeners();
  }

  void _detachElement(Flut5UIElement element) {
    _elements.remove(element);
    if (!_disposed) notifyListeners();
  }

  void clear() {
    final elements = List<Flut5UIElement>.of(_elements);
    _elements.clear();
    for (final element in elements) {
      element.dispose();
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    clear();
    super.dispose();
  }
}
