import 'package:flutter/material.dart';

import 'flut5_ui_element.dart';

MainAxisAlignment _parseJustify(String justify) => switch (justify) {
  'end' => MainAxisAlignment.end,
  'center' => MainAxisAlignment.center,
  'spaceBetween' => MainAxisAlignment.spaceBetween,
  'spaceAround' => MainAxisAlignment.spaceAround,
  'spaceEvenly' => MainAxisAlignment.spaceEvenly,
  _ => MainAxisAlignment.start,
};

CrossAxisAlignment _parseAlign(String align) => switch (align) {
  'end' => CrossAxisAlignment.end,
  'center' => CrossAxisAlignment.center,
  'stretch' => CrossAxisAlignment.stretch,
  'baseline' => CrossAxisAlignment.baseline,
  _ => CrossAxisAlignment.start,
};

base class Flut5Container({
  var String direction = 'row',
  var double gap = 0,
  var String align = 'start',
  var String justify = 'start',
  required super.removeElement,
  required final Function(Flut5UIElement) detachElement,
}) extends Flut5UIElement {
  SizedBox? _cachedSpacer;

  /// Unified children list — holds either [Widget] or [Flut5UIElement], in insertion order.
  final List<Object> _items = [];

  @override
  void style(dynamic props, [dynamic value]) {
    super.style(props, value);
    final resolved = props is String
        ? {props: value}
        : props as Map<String, dynamic>;
    if (resolved.containsKey('align') && resolved['align'] != null)
      align = resolved['align'] as String;
    if (resolved.containsKey('justify') && resolved['justify'] != null)
      justify = resolved['justify'] as String;
    if (resolved.containsKey('gap') && resolved['gap'] != null) {
      gap = (resolved['gap'] as num).toDouble();
      _cachedSpacer = null;
    }
    if (resolved.containsKey('direction') && resolved['direction'] != null) {
      direction = resolved['direction'] as String;
      _cachedSpacer = null;
    }
  }

  void setChildren(List<Widget> children) {
    for (final item in _items) {
      if (item is Flut5UIElement) item.dispose();
    }
    _items.clear();
    _items.addAll(children);
    notifyListeners();
  }

  void addChild(Widget child) {
    _items.add(child);
    notifyListeners();
  }

  /// Detaches [element] from the top-level UI stack and adds it as the last child.
  void append(Flut5UIElement element) {
    detachElement(element);
    _items.add(element);
    notifyListeners();
  }

  /// Detaches [element] from the top-level UI stack and inserts it as the first child.
  void prepend(Flut5UIElement element) {
    detachElement(element);
    _items.insert(0, element);
    notifyListeners();
  }

  /// Detaches [element] and inserts it at [index]. Appends if [index] exceeds the list length.
  void insert(int index, Flut5UIElement element) {
    detachElement(element);
    _items.insert(index.clamp(0, _items.length), element);
    notifyListeners();
  }

  @override
  void dispose() {
    super.dispose();
    for (final item in _items) {
      if (item is Flut5UIElement) item.dispose();
    }
  }

  /// Wraps each Flut5UIElement child in its own ListenableBuilder so child
  /// property changes rebuild only that child — not the entire container.
  List<Widget> _resolveItems(BuildContext context) {
    return _items.map((item) {
      if (item is Flut5UIElement)
        return item.buildInteractiveListenable(context);
      return item as Widget;
    }).toList();
  }

  List<Widget> _childrenWithGap(BuildContext context) {
    final resolved = _resolveItems(context);
    if (gap <= 0 || resolved.isEmpty) return resolved;
    _cachedSpacer ??= direction == 'column'
        ? SizedBox(height: gap)
        : SizedBox(width: gap);
    final spacer = _cachedSpacer!;
    return [
      for (int i = 0; i < resolved.length; i++) ...[
        resolved[i],
        if (i < resolved.length - 1) spacer,
      ],
    ];
  }

  @override
  Widget buildInner(BuildContext context) {
    final mainAxis = _parseJustify(justify);
    final crossAxis = _parseAlign(align);
    final children = _childrenWithGap(context);

    if (direction == 'column') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: mainAxis,
        crossAxisAlignment: crossAxis,
        children: children,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: mainAxis,
      crossAxisAlignment: crossAxis,
      children: children,
    );
  }
}
