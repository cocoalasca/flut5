---
trigger: model_decision
description: Guidelines for creating or modifying Flut5 UI elements (buttons, labels, sliders, containers, or new element types)
---

# Flut5 UI Element Rules

## Multi-shadow support
All UI elements support multiple shadows via the `shadow` style key. When creating new element types or adding default styles:

- The `shadow` key accepts: a single `BoxShadow`, a `List<BoxShadow>`, a `Map` with keys `color`/`blur`/`spread`/`offsetX`/`offsetY`, or a `List<Map>`.
- Shadows are resolved by `resolveShadows()` in `flut5_style_builder.dart` and passed to `BoxDecoration.boxShadow`.
- Shadows animate automatically via `AnimatedContainer` when transitions are enabled.
- Shadows work with `style()`, `hoverStyle()`, and `styleFocus()`.

## Build pipeline
When creating new UI element types, follow the existing pipeline:
1. `buildInner()` — return the raw widget (no styling)
2. `buildContent()` — override only if element-specific wrappers are needed (e.g. GestureDetector on buttons); always call `super.buildContent()` for style application
3. `buildInteractive()` — rarely needs override; handles hover/click state
4. `build()` — do not override; handles positioning and per-element rebuild isolation
