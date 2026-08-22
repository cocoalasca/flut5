---
trigger: always
description: Whenever a public method, getter, setter, or field is added to Flut5Engine or any of its mixins/base classes, a matching forwarder must also be added to the Flut5 class in lib/flut5.dart
---

# Engine Forwarder Rule

Any public method, getter, setter, or field added to `Flut5Engine` or any class/mixin it extends or uses (`Flut5Fill`, `Flut5Stroke`, `Flut52DPrimitives`, `Flut5Transform`, `Flut5Trigonometry`, `Flut5Text`, `Flut5Noise`, `Flut5Vertex`, `Flut5UI`, etc.) **must** have a matching one-line forwarder in the `Flut5` class in `lib/flut5.dart`.

## Why

`Flut5` is the user-facing base class. Users extend it and write `ellipse(...)`, `rotate(...)`, `mouseX`, etc. directly — without the `flut5.` prefix. If a forwarder is missing, the feature works via `flut5.foo()` but not via the shorthand `foo()`, which is the expected API.

## How to apply

After adding a public member anywhere in the engine layer, immediately add its forwarder in `lib/flut5.dart` under the appropriate section comment (e.g. `// ── Text`, `// ── Transform`). Follow the existing style:

- **Method:** `ReturnType methodName(Params) => flut5.methodName(params);`
- **Getter:** `Type get name => flut5.name;`
- **Setter:** `set name(Type v) => flut5.name = v;`
- **Getter + setter pair:** add both.

If no matching section exists, add a new one with a comment header.

## What counts as "public"

- No leading underscore (`_`)
- Declared directly on the class/mixin (not inherited from Flutter/Dart core types)
- Intended to be called by sketch authors (not internal engine plumbing only used between mixins)

## What does NOT need a forwarder

- Private members (`_name`)
- Members that are already inherited by `Flut5` through `Flut5EventMixin` or other mixins applied directly to `Flut5`
- Internal helpers only used between mixins (e.g. `renderQueue`, `batchPath` — these are already forwarded and are a special case)
