import 'package:flutter/material.dart';

import 'flut5_style_builder.dart';

/// Passes the UI transition duration down the widget tree to all UI elements.
class const Flut5UIScope({
  required final Duration transitionDuration,
  required super.child,
  super.key,
}) extends InheritedWidget {
  static Duration of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<Flut5UIScope>()
            ?.transitionDuration ??
        Duration.zero;
  }

  @override
  bool updateShouldNotify(Flut5UIScope old) =>
      transitionDuration != old.transitionDuration;
}

/// Represents a dimension value: a fixed number or [Flut5Dim.fitContent].
class const Flut5Dim._fixed(final double? _fixed) {
  const Flut5Dim._() : this._fixed(null);

  /// Creates a fixed-pixel dimension.
  factory Flut5Dim(double value) => Flut5Dim._fixed(value);

  /// Sizes to the natural size of the content. This is the default.
  static const fitContent = Flut5Dim._();

  double? get value => _fixed;
}

/// Base class for all Flut5 UI elements.
///
/// Each element is its own [ChangeNotifier] — property changes (position, style,
/// content) rebuild only that element's widget subtree, not the entire UI layer.
///
/// Build pipeline (innermost → outermost):
///   [buildInner]       — subclass defines the raw widget (e.g. Text, Slider)
///   [buildContent]     — wraps with style: padding, backgroundColor, text props, animations
///   [buildInteractive] — wraps with hover/click state listeners (local rebuild only)
///   [build]            — wraps with ListenableBuilder + Positioned for canvas placement
///
/// Use [buildInteractiveListenable] instead of [build] when placing the element
/// inside a container — it wraps in a per-element ListenableBuilder without Positioned.
abstract base class Flut5UIElement({
  required final Function(Flut5UIElement) removeElement,
}) with ChangeNotifier {
  double x = 0;
  double y = 0;
  Object _widthDim = Flut5Dim.fitContent;
  Object _heightDim = Flut5Dim.fitContent;
  Widget? _widgetContent;
  final ValueNotifier<bool> _hovered = ValueNotifier(false);
  final ValueNotifier<bool> _clicked = ValueNotifier(false);
  late final Listenable _interactionListenable = Listenable.merge([
    _hovered,
    _clicked,
  ]);
  Map<String, dynamic> _styleMap = const {};
  Map<String, dynamic> _hoverStyleMap = const {};
  Map<String, dynamic> _focusStyleMap = const {};
  BoxDecoration? _cachedStyleDecoration;

  /// Moves the element to the given position on the canvas.
  /// WARNING: Avoid calling every frame (e.g. inside draw()). For elements
  /// that must follow moving objects at 60fps, draw directly on the canvas
  /// instead. UI elements are designed for infrequent updates.
  void position(double x, double y) {
    if (this.x != x || this.y != y) {
      this.x = x;
      this.y = y;
      notifyListeners();
    }
  }

  /// Sets width and height. Each value can be a [num] (fixed pixels)
  /// or [Flut5Dim.fitContent] (natural content size, the default).
  void dimensions(Object width, Object height) {
    if (_widthDim == width && _heightDim == height) return;
    _widthDim = width;
    _heightDim = height;
    notifyListeners();
  }

  void style(dynamic props, [dynamic value]) {
    final resolved = props is String
        ? {props: value}
        : Map<String, dynamic>.from(props as Map);
    _styleMap = {..._styleMap, ...resolved}..removeWhere((k, v) => v == null);
    _cachedStyleDecoration = null;
    notifyListeners();
  }

  void hoverStyle(dynamic props, [dynamic value]) {
    final resolved = props is String
        ? {props: value}
        : Map<String, dynamic>.from(props as Map);
    _hoverStyleMap = {..._hoverStyleMap, ...resolved}
      ..removeWhere((k, v) => v == null);
    notifyListeners();
  }

  void styleFocus(dynamic props, [dynamic value]) {
    final resolved = props is String
        ? {props: value}
        : Map<String, dynamic>.from(props as Map);
    _focusStyleMap = {..._focusStyleMap, ...resolved}
      ..removeWhere((k, v) => v == null);
    notifyListeners();
  }

  /// Replaces the element's default widget with a fully custom one.
  /// The [Positioned] wrapper (x, y, dimensions) is preserved.
  void content(Widget widget) {
    _widgetContent = widget;
    notifyListeners();
  }

  /// The resolved fixed width in pixels, or null when the element is set to fitContent.
  /// Subclasses can use this to honour [dimensions] when rendering their own sized widgets.
  double? get resolvedWidth => _resolveDim(_widthDim);

  /// The resolved fixed height in pixels, or null when the element is set to fitContent.
  double? get resolvedHeight => _resolveDim(_heightDim);

  void remove() {
    removeElement(this);
  }

  /// Override in subclasses to clean up subscriptions, controllers, etc.
  /// Always call [super.dispose()] when overriding.
  @override
  void dispose() {
    _hovered.dispose();
    _clicked.dispose();
    super.dispose();
  }

  /// Returns the effective style map, merging hover overrides when hovered.
  Map<String, dynamic> effectiveStyleMap() {
    if (_clicked.value && _focusStyleMap.isNotEmpty) {
      return {..._styleMap, ..._focusStyleMap};
    }
    if (_hovered.value && _hoverStyleMap.isNotEmpty) {
      return {..._styleMap, ..._hoverStyleMap};
    }
    return _styleMap;
  }

  /// Step 1 of the build pipeline.
  /// Subclasses implement this to return their core widget (e.g. Text, Slider).
  /// No styling, padding, or positioning should be applied here.
  Widget buildInner(BuildContext context);

  /// Step 2 of the build pipeline.
  /// Wraps [buildInner] with the element's visual style.
  /// Subclasses may override to add element-specific wrappers around the styled output.
  Widget buildContent(BuildContext context) {
    // Use custom widget override if set, otherwise build normally.
    Widget inner = _widgetContent ?? buildInner(context);

    // Resolve which style map is active: click > hover > base.
    final effectiveMap = effectiveStyleMap();
    if (effectiveMap.isEmpty) return inner;

    final duration = Flut5UIScope.of(context);

    // Apply text style props (fontFamily, fontSize, etc.) via DefaultTextStyle so
    // they propagate to any Text widgets below. Non-text widgets silently ignore it.
    final textStyle = buildTextStyle(effectiveMap);
    if (textStyle != null) {
      if (duration == Duration.zero) {
        inner = DefaultTextStyle.merge(style: textStyle, child: inner);
      } else {
        // AnimatedDefaultTextStyle interpolates between text styles smoothly.
        final mergedStyle = DefaultTextStyle.of(context).style.merge(textStyle);
        inner = AnimatedDefaultTextStyle(
          duration: duration,
          curve: Curves.easeInOut,
          style: mergedStyle,
          child: inner,
        );
      }
    }

    // Only add a Container/AnimatedContainer if box props are present.
    // Skipping it avoids unnecessary layout overhead for text-only styles.
    final bool hasBoxProps = effectiveMap.keys.any(
      (k) =>
          k == 'backgroundColor' ||
          k == 'borderColor' ||
          k == 'borderWeight' ||
          k == 'borderRadius' ||
          k == 'padding' ||
          k == 'shadow',
    );
    if (!hasBoxProps) return inner;

    // Cache the base decoration to avoid rebuilding it on every frame.
    // Hover/click states get a fresh decoration since effectiveMap differs.
    final decoration = identical(effectiveMap, _styleMap)
        ? (_cachedStyleDecoration ??= buildDecoration(_styleMap))
        : buildDecoration(effectiveMap);

    final EdgeInsetsGeometry? padding =
        effectiveMap['padding'] as EdgeInsetsGeometry?;

    // Use AnimatedContainer when transitions are enabled so backgroundColor, border,
    // borderRadius, and padding interpolate smoothly on state changes.
    if (duration == Duration.zero) {
      return Container(decoration: decoration, padding: padding, child: inner);
    }
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeInOut,
      decoration: decoration,
      padding: padding,
      child: inner,
    );
  }

  /// Step 3 of the build pipeline.
  /// Wraps [buildContent] with hover/click state tracking when hoverStyle or
  /// styleFocus is set. Uses a local ListenableBuilder so only this element
  /// rebuilds on state changes — not the entire canvas UI layer.
  /// Does NOT add positioning — use this when placing the element inside a container.
  Widget buildInteractive(BuildContext context) {
    final bool needsInteraction =
        _hoverStyleMap.isNotEmpty || _focusStyleMap.isNotEmpty;
    // Fast path: skip the ListenableBuilder overhead if no interaction styles are set.
    if (!needsInteraction) return buildContent(context);

    return ListenableBuilder(
      listenable:
          _interactionListenable, // fires when _hovered or _clicked changes
      builder: (ctx, _) {
        Widget inner = buildContent(ctx);
        // MouseRegion tracks pointer enter/exit to toggle _hovered.
        if (_hoverStyleMap.isNotEmpty) {
          inner = MouseRegion(
            onEnter: (_) => _hovered.value = true,
            onExit: (_) => _hovered.value = false,
            child: inner,
          );
        }
        // Listener uses opaque hit-testing so pointer events fire on padding
        // areas even when no fill/background is painted there.
        if (_focusStyleMap.isNotEmpty) {
          inner = Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _clicked.value = true,
            onPointerUp: (_) => _clicked.value = false,
            onPointerCancel: (_) => _clicked.value = false,
            child: inner,
          );
        }
        return inner;
      },
    );
  }

  /// Wraps [buildInteractive] in a per-element [ListenableBuilder] so property
  /// changes (position, style, content) rebuild only this element — not the
  /// entire UI layer. Use this inside containers instead of [build].
  Widget buildInteractiveListenable(BuildContext context) {
    return ListenableBuilder(
      key: ObjectKey(this),
      listenable: this,
      builder: (ctx, _) => buildInteractive(ctx),
    );
  }

  /// Step 4 of the build pipeline.
  /// Wraps in a per-element [ListenableBuilder] + Positioned/AnimatedPositioned.
  /// Property changes rebuild only this element's subtree, not sibling elements.
  /// Call [buildInteractiveListenable] instead when nesting inside a Flut5Container.
  Widget build(BuildContext context) {
    return ListenableBuilder(
      key: ObjectKey(this),
      listenable: this,
      builder: (context, _) {
        final Widget child = buildInteractive(context);

        // AnimatedPositioned smoothly interpolates x/y/w/h when transitions are enabled.
        final duration = Flut5UIScope.of(context);
        if (duration == Duration.zero) {
          return Positioned(
            left: x,
            top: y,
            width: _resolveDim(_widthDim),
            height: _resolveDim(_heightDim),
            child: child,
          );
        }
        return AnimatedPositioned(
          duration: duration,
          curve: Curves.easeInOut,
          left: x,
          top: y,
          width: _resolveDim(_widthDim),
          height: _resolveDim(_heightDim),
          child: child,
        );
      },
    );
  }

  static double? _resolveDim(Object dim) {
    if (dim is num) return dim.toDouble();
    if (dim is Flut5Dim) return dim.value;
    return null;
  }
}
