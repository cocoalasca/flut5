import 'package:flutter/material.dart';
import 'flut5_ui_element.dart';
import 'flut5_style_builder.dart';

base class Flut5Slider extends Flut5UIElement {
  double min;
  double max;
  double value;
  Axis _direction = Axis.horizontal;
  Function(double)? _onChanged;

  Flut5Slider(
    this.min,
    this.max, {
    this.value = 0.0,
    required super.removeElement,
  });

  /// Sets the slider orientation. Defaults to [Axis.horizontal].
  void direction(Axis axis) {
    if (_direction != axis) {
      _direction = axis;
      notifyListeners();
    }
  }

  void changed(Function(double) callback) {
    _onChanged = callback;
  }

  void setValue(double val) {
    if (value != val) {
      value = val;
      notifyListeners();
    }
  }

  /// Wraps super's styled content in a [SliderTheme] so slider-specific style
  /// keys are picked up by the [Slider] inside [buildInner].
  /// Hover/click states automatically apply because [effectiveStyleMap] merges
  /// overrides, and [buildInteractive] triggers a rebuild on state change.
  ///
  /// Supported style keys:
  ///   thumbColor, thumbSize, thumbShadow, thumbBorderColor, thumbBorderWeight, thumbBorderRadius
  ///   trackHeight, trackColor (Color or gradient), activeTrackColor (Color or gradient),
  ///   trackBorderColor, trackBorderWeight, trackBorderRadius, shadow (track shadow)
  @override
  Widget buildContent(BuildContext context) {
    final style = effectiveStyleMap();
    final theme = _buildSliderTheme(context, style);
    return SliderTheme(
      data: theme,
      child: super.buildContent(context),
    );
  }

  SliderThemeData _buildSliderTheme(BuildContext context, Map<String, dynamic> style) {
    final base = SliderTheme.of(context);

    final thumbRadius = (style['thumbSize'] as num?)?.toDouble();
    final shadows = resolveShadows(style['thumbShadow']);
    final thumbBorderColor = style['thumbBorderColor'] as Color?;
    final thumbBorderWeight = (style['thumbBorderWeight'] as num?)?.toDouble() ?? 1.5;

    final thumbBorderRadius = (style['thumbBorderRadius'] as num?)?.toDouble();
    final needsThumbShape = thumbRadius != null || shadows != null ||
        thumbBorderColor != null || thumbBorderRadius != null;
    final thumbShape = needsThumbShape
        ? _CustomRoundThumbShape(
            enabledThumbRadius: thumbRadius ?? 10.0,
            shadows: shadows,
            borderColor: thumbBorderColor,
            borderWeight: thumbBorderWeight,
            borderRadius: thumbBorderRadius,
          )
        : null;

    final trackBorderColor = style['trackBorderColor'] as Color?;
    final trackBorderWeight = (style['trackBorderWeight'] as num?)?.toDouble() ?? 1.0;
    final trackShadows = resolveShadows(style['shadow']);
    final trackBorderRadius = (style['trackBorderRadius'] as num?)?.toDouble();
    final rawTrackColor = style['trackColor'];
    final trackGradient = resolveLinearGradient(rawTrackColor);
    final trackSolidColor = trackGradient == null && rawTrackColor is Color ? rawTrackColor : null;
    final rawActiveColor = style['activeTrackColor'];
    final activeGradient = resolveLinearGradient(rawActiveColor);
    final activeSolidColor = activeGradient == null && rawActiveColor is Color ? rawActiveColor : null;
    final needsTrackShape = trackBorderColor != null || trackShadows != null ||
        trackBorderRadius != null || trackGradient != null || activeGradient != null;
    final trackShape = needsTrackShape
        ? _CustomRoundedRectTrackShape(
            borderColor: trackBorderColor,
            borderWeight: trackBorderWeight,
            shadows: trackShadows,
            borderRadius: trackBorderRadius,
            gradient: trackGradient,
            activeGradient: activeGradient,
          )
        : null;

    return base.copyWith(
      thumbColor: style['thumbColor'] as Color?,
      activeTrackColor: activeSolidColor,
      inactiveTrackColor: trackSolidColor,
      trackHeight: (style['trackHeight'] as num?)?.toDouble(),
      thumbShape: thumbShape,
      trackShape: trackShape,
      overlayShape: SliderComponentShape.noOverlay,
    );
  }

  @override
  Widget buildInner(BuildContext context) {
    final slider = Slider(
      min: min,
      max: max,
      value: value,
      onChanged: (val) {
        value = val;
        notifyListeners();
        if (_onChanged != null) {
          _onChanged!(val);
        }
      },
    );
    // Vertical: rotate 270° so dragging up increases the value.
    if (_direction == Axis.vertical) {
      return RotatedBox(quarterTurns: 3, child: slider);
    }
    return slider;
  }
}

/// Round (or rounded-rect) thumb shape with optional shadows and border stroke.
/// When [borderRadius] is set the thumb is painted as a rounded rectangle
/// instead of a circle — [enabledThumbRadius] controls half the side length.
class _CustomRoundThumbShape extends RoundSliderThumbShape {
  final List<BoxShadow>? shadows;
  final Color? borderColor;
  final double borderWeight;
  final double? borderRadius;

  const _CustomRoundThumbShape({
    super.enabledThumbRadius = 10.0,
    this.shadows,
    this.borderColor,
    this.borderWeight = 1.5,
    this.borderRadius,
  });

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    if (borderRadius != null) {
      // Rounded-rect thumb: paint entirely manually so we control the shape.
      final size = enabledThumbRadius * 2;
      final rect = Rect.fromCenter(center: center, width: size, height: size);
      final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius!));
      final canvas = context.canvas;

      // Shadows beneath. toPaint() converts blurRadius → sigma the CSS way,
      // matching how BoxDecoration renders the same style map on other
      // elements; spreadRadius grows the silhouette before blurring.
      if (shadows != null) {
        for (final shadow in shadows!) {
          canvas.drawRRect(
            rrect.inflate(shadow.spreadRadius).shift(shadow.offset),
            shadow.toPaint(),
          );
        }
      }
      // Fill.
      canvas.drawRRect(
        rrect,
        Paint()..color = sliderTheme.thumbColor ?? Colors.white,
      );
      // Border.
      if (borderColor != null) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = borderColor!
            ..style = PaintingStyle.stroke
            ..strokeWidth = borderWeight,
        );
      }
    } else {
      // Circle thumb: use default painting + optional shadow/border.
      // toPaint() converts blurRadius → sigma the CSS way, matching how
      // BoxDecoration renders the same style map on other elements.
      if (shadows != null) {
        final canvas = context.canvas;
        for (final shadow in shadows!) {
          canvas.drawCircle(
            center + shadow.offset,
            enabledThumbRadius + shadow.spreadRadius,
            shadow.toPaint(),
          );
        }
      }

      super.paint(
        context,
        center,
        activationAnimation: activationAnimation,
        enableAnimation: enableAnimation,
        isDiscrete: isDiscrete,
        labelPainter: labelPainter,
        parentBox: parentBox,
        sliderTheme: sliderTheme,
        textDirection: textDirection,
        value: value,
        textScaleFactor: textScaleFactor,
        sizeWithOverflow: sizeWithOverflow,
      );

      if (borderColor != null) {
        context.canvas.drawCircle(
          center,
          enabledThumbRadius,
          Paint()
            ..color = borderColor!
            ..style = PaintingStyle.stroke
            ..strokeWidth = borderWeight,
        );
      }
    }
  }
}

/// Rounded rect track shape with optional gradient, shadows, border, and corner radius.
/// Both [gradient] (inactive) and [activeGradient] (progress) use the full track rect
/// as shader bounds — stops are in track-space (0.0 = start, 1.0 = end of full track).
/// [borderRadius] overrides the default fully-rounded corners (height / 2).
class _CustomRoundedRectTrackShape extends RoundedRectSliderTrackShape {
  final List<BoxShadow>? shadows;
  final Color? borderColor;
  final double borderWeight;
  final double? borderRadius;
  final LinearGradient? gradient;
  final LinearGradient? activeGradient;

  const _CustomRoundedRectTrackShape({
    this.shadows,
    this.borderColor,
    this.borderWeight = 1.0,
    this.borderRadius,
    this.gradient,
    this.activeGradient,
  });

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
    double additionalActiveTrackHeight = 2,
  }) {
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(borderRadius ?? trackRect.height / 2);
    final rrect = RRect.fromRectAndRadius(trackRect, radius);

    // Paint shadows beneath the track. toPaint() converts blurRadius → sigma
    // the CSS way, matching how BoxDecoration renders the same style map on
    // other elements; spreadRadius grows the silhouette before blurring.
    if (shadows != null) {
      for (final shadow in shadows!) {
        context.canvas.drawRRect(
          rrect.inflate(shadow.spreadRadius).shift(shadow.offset),
          shadow.toPaint(),
        );
      }
    }

    // Active rect (progress side), inactive rect (remaining side) — LTR/RTL aware.
    final activeRect = textDirection == TextDirection.ltr
        ? Rect.fromLTRB(trackRect.left, trackRect.top, thumbCenter.dx, trackRect.bottom)
        : Rect.fromLTRB(thumbCenter.dx, trackRect.top, trackRect.right, trackRect.bottom);
    final inactiveRect = textDirection == TextDirection.ltr
        ? Rect.fromLTRB(thumbCenter.dx, trackRect.top, trackRect.right, trackRect.bottom)
        : Rect.fromLTRB(trackRect.left, trackRect.top, thumbCenter.dx, trackRect.bottom);

    if (gradient != null || activeGradient != null) {
      // Gradient path: paint manually, clip to track shape.
      // Shader bounds always use the full trackRect so stop positions are
      // consistent regardless of thumb position (0.0 = track start, 1.0 = track end).
      final canvas = context.canvas;
      canvas.save();
      canvas.clipRRect(rrect);

      // Inactive background.
      if (gradient != null) {
        canvas.drawRect(trackRect, Paint()..shader = gradient!.createShader(trackRect));
      } else if (sliderTheme.inactiveTrackColor != null) {
        canvas.drawRect(inactiveRect, Paint()..color = sliderTheme.inactiveTrackColor!);
      }

      // Active (progress) portion — gradient clipped to thumb position.
      if (activeGradient != null) {
        canvas.drawRect(activeRect, Paint()..shader = activeGradient!.createShader(trackRect));
      } else if (sliderTheme.activeTrackColor != null) {
        canvas.drawRect(activeRect, Paint()..color = sliderTheme.activeTrackColor!);
      }

      canvas.restore();
    } else {
      // Solid path: delegate to super (uses sliderTheme colors).
      super.paint(
        context,
        offset,
        parentBox: parentBox,
        sliderTheme: sliderTheme,
        enableAnimation: enableAnimation,
        thumbCenter: thumbCenter,
        secondaryOffset: secondaryOffset,
        isEnabled: isEnabled,
        isDiscrete: isDiscrete,
        textDirection: textDirection,
        additionalActiveTrackHeight: additionalActiveTrackHeight,
      );
    }

    // Paint border on top of the track.
    if (borderColor != null) {
      context.canvas.drawRRect(
        rrect,
        Paint()
          ..color = borderColor!
          ..style = PaintingStyle.stroke
          ..strokeWidth = borderWeight,
      );
    }
  }
}
