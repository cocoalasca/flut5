import 'package:flutter/material.dart';
import 'flut5_ui_element.dart';
import 'flut5_style_builder.dart';

base class Flut5Checkbox extends Flut5UIElement {
  static const _kDefaultSize = 22.0;

  bool value;
  Function(bool)? _onChanged;
  String _checkTransition = 'fade';

  Flut5Checkbox({
    this.value = false,
    required super.removeElement,
  });

  /// Sets the check-mark appearing/disappearing animation.
  /// Supported values: 'fade', 'scale'.
  void checkTransition(String transition) {
    _checkTransition = transition;
    notifyListeners();
  }

  void changed(Function(bool) callback) {
    _onChanged = callback;
  }

  void setValue(bool val) {
    if (value != val) {
      value = val;
      notifyListeners();
      _onChanged?.call(val);
    }
  }

  /// Builds a fully custom checkbox — no Flutter Checkbox widget.
  /// Supports arbitrary sizing via [dimensions()], all style keys,
  /// and smooth transitions via [Flut5UIScope].
  ///
  /// Supported style keys:
  ///   backgroundColor (unchecked fill), activeBackgroundColor (checked fill),
  ///   checkColor, borderColor, borderWeight, borderRadius,
  ///   shadow, padding
  @override
  Widget buildContent(BuildContext context) {
    final style = effectiveStyleMap();
    final duration = Flut5UIScope.of(context);

    final boxWidth = resolvedWidth ?? _kDefaultSize;
    final boxHeight = resolvedHeight ?? _kDefaultSize;
    final borderRadius = (style['borderRadius'] as num?)?.toDouble() ?? 4.0;
    final borderColor = style['borderColor'] as Color?;
    final borderWeight = (style['borderWeight'] as num?)?.toDouble() ?? 2.0;

    final inactiveFill = style['backgroundColor'] as Color? ?? Colors.transparent;
    final activeFill = style['activeBackgroundColor'] as Color? ?? Colors.blue;
    final bgColor = value ? activeFill : inactiveFill;

    final checkColor = style['checkColor'] as Color? ?? Colors.white;
    final shadows = resolveShadows(style['shadow']);
    final EdgeInsetsGeometry? padding = style['padding'] as EdgeInsetsGeometry?;

    final decoration = BoxDecoration(
      color: bgColor,
      borderRadius: BorderRadius.circular(borderRadius),
      border: borderColor != null
          ? Border.all(color: borderColor, width: borderWeight)
          : null,
      boxShadow: shadows,
    );

    // Checkmark icon sized relative to the box.
    final checkSize = (boxWidth < boxHeight ? boxWidth : boxHeight) * 0.7;

    Widget box;
    if (duration == Duration.zero) {
      box = Container(
        width: boxWidth,
        height: boxHeight,
        decoration: decoration,
        padding: padding,
        alignment: Alignment.center,
        child: value
            ? Icon(Icons.check, color: checkColor, size: checkSize)
            : const SizedBox.shrink(),
      );
    } else {
      box = AnimatedContainer(
        duration: duration,
        curve: Curves.easeInOut,
        width: boxWidth,
        height: boxHeight,
        decoration: decoration,
        padding: padding,
        alignment: Alignment.center,
        child: AnimatedSwitcher(
          duration: duration,
          transitionBuilder: (child, animation) {
            if (_checkTransition == 'scale') {
              return ScaleTransition(scale: animation, child: child);
            }
            return FadeTransition(opacity: animation, child: child);
          },
          child: value
              ? Icon(Icons.check, key: const ValueKey(true), color: checkColor, size: checkSize)
              : const SizedBox.shrink(key: ValueKey(false)),
        ),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setValue(!value),
        child: box,
      ),
    );
  }

  @override
  Widget buildInner(BuildContext context) => const SizedBox.shrink();
}
