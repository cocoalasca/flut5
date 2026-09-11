import 'package:flutter/material.dart';

import 'flut5_ui_element.dart';
import 'flut5_style_builder.dart';

base class Flut5Toggle({var bool value = false, required super.removeElement})
    extends Flut5UIElement {
  Function(bool)? _onChanged;

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

  /// Builds the complete toggle visual — track + animated thumb.
  /// Does NOT call super so the base Container wrapper is skipped;
  /// all decoration (track color, border, shadow) is handled here.
  ///
  /// Supported style keys:
  ///   backgroundColor (inactive track), activeBackgroundColor (active track),
  ///   trackColor (alias for backgroundColor), activeTrackColor (alias for activeBackgroundColor),
  ///   trackWidth, trackHeight,
  ///   borderRadius, borderColor, borderWeight, shadow (track shadow),
  ///   thumbColor, activeThumbColor, thumbShadow,
  ///   thumbBorderColor, thumbBorderWeight, thumbBorderRadius
  @override
  Widget buildContent(BuildContext context) {
    final style = effectiveStyleMap();
    final duration = Flut5UIScope.of(context);

    // dimensions() takes priority; fall back to style keys then hardcoded defaults.
    final trackWidth =
        resolvedWidth ?? (style['trackWidth'] as num?)?.toDouble() ?? 50.0;
    final trackHeight =
        resolvedHeight ?? (style['trackHeight'] as num?)?.toDouble() ?? 28.0;
    final trackRadius =
        (style['borderRadius'] as num?)?.toDouble() ?? trackHeight / 2;

    final inactiveTrackColor =
        style['backgroundColor'] as Color? ??
        style['trackColor'] as Color? ??
        Colors.grey.shade300;
    final activeTrackColor =
        style['activeBackgroundColor'] as Color? ??
        style['activeTrackColor'] as Color? ??
        Colors.blue;
    final trackColor = value ? activeTrackColor : inactiveTrackColor;

    final trackBorderColor = style['borderColor'] as Color?;
    final trackBorderWeight =
        (style['borderWeight'] as num?)?.toDouble() ?? 1.0;
    final trackShadows = resolveShadows(style['shadow']);

    // Thumb
    final thumbSize = trackHeight - 4.0;
    final thumbPadding = 2.0;
    final thumbLeft = value
        ? trackWidth - thumbSize - thumbPadding
        : thumbPadding;

    final baseThumbColor = style['thumbColor'] as Color? ?? Colors.white;
    final thumbFill = value
        ? (style['activeThumbColor'] as Color? ?? baseThumbColor)
        : baseThumbColor;
    final thumbShadows = resolveShadows(style['thumbShadow']);
    final thumbBorderColor = style['thumbBorderColor'] as Color?;
    final thumbBorderWeight =
        (style['thumbBorderWeight'] as num?)?.toDouble() ?? 1.5;
    final thumbBorderRadius = (style['thumbBorderRadius'] as num?)?.toDouble();

    final thumbDecoration = BoxDecoration(
      color: thumbFill,
      borderRadius: BorderRadius.circular(thumbBorderRadius ?? thumbSize / 2),
      border: thumbBorderColor != null
          ? Border.all(color: thumbBorderColor, width: thumbBorderWeight)
          : null,
      boxShadow: thumbShadows,
    );

    Widget track;
    if (duration == Duration.zero) {
      track = Container(
        width: trackWidth,
        height: trackHeight,
        decoration: BoxDecoration(
          color: trackColor,
          borderRadius: BorderRadius.circular(trackRadius),
          border: trackBorderColor != null
              ? Border.all(color: trackBorderColor, width: trackBorderWeight)
              : null,
          boxShadow: trackShadows,
        ),
      );
    } else {
      track = AnimatedContainer(
        duration: duration,
        curve: Curves.easeInOut,
        width: trackWidth,
        height: trackHeight,
        decoration: BoxDecoration(
          color: trackColor,
          borderRadius: BorderRadius.circular(trackRadius),
          border: trackBorderColor != null
              ? Border.all(color: trackBorderColor, width: trackBorderWeight)
              : null,
          boxShadow: trackShadows,
        ),
      );
    }

    Widget thumb;
    if (duration == Duration.zero) {
      thumb = Positioned(
        left: thumbLeft,
        top: thumbPadding,
        child: Container(
          width: thumbSize,
          height: thumbSize,
          decoration: thumbDecoration,
        ),
      );
    } else {
      thumb = AnimatedPositioned(
        duration: duration,
        curve: Curves.easeInOut,
        left: thumbLeft,
        top: thumbPadding,
        child: Container(
          width: thumbSize,
          height: thumbSize,
          decoration: thumbDecoration,
        ),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setValue(!value),
        child: SizedBox(
          width: trackWidth,
          height: trackHeight,
          child: Stack(clipBehavior: Clip.none, children: [track, thumb]),
        ),
      ),
    );
  }

  @override
  Widget buildInner(BuildContext context) => const SizedBox.shrink();
}
