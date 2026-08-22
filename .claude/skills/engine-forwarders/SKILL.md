---
name: engine-forwarders
description: Use whenever a public method, getter, setter, or field is added to or edited on Flut5Engine or any of its mixins (Flut5Fill, Flut5Stroke, Flut52DPrimitives, Flut5Transform, Flut5Clip, Flut5Trigonometry, Flut5Text, Flut5Noise, Flut5Vertex, Flut5UI, Flut5Cursor, etc.). Ensures the matching one-line forwarder is also added to the Flut5 base class in lib/flut5.dart so sketch authors can call the member unprefixed.
---

# Engine forwarder skill

When you add or edit a **public** member (method / getter / setter / field) on `Flut5Engine` or any mixin it composes, you must add a matching one-line forwarder in the `Flut5` class at `lib/flut5.dart`.

Without the forwarder, the feature works as `flut5.foo(...)` but not as the bare `foo(...)` that sketch authors expect — both forms are part of the public API and must stay in sync.

## When to apply

- New public method on a mixin used by `Flut5Engine` → add a method forwarder.
- New public getter / setter / field → add the getter (and setter if writable).
- Renamed public member → update the forwarder name to match.
- Removed public member → remove the forwarder.

Do **not** add a forwarder for:
- Private members (leading `_`).
- Members already exposed via a mixin applied directly to `Flut5` (e.g. `Flut5EventMixin`).
- Internal cross-mixin plumbing that sketches aren't meant to call.

## How to apply

In `lib/flut5.dart`, add the forwarder under the appropriate `// ── <Section>` header (create one if none fits):

- Method: `ReturnType name(Params) => flut5.name(params);`
- Getter: `Type get name => flut5.name;`
- Setter: `set name(Type v) => flut5.name = v;`

## Canonical rule

The full project rule (with rationale and edge cases) lives at [`.agent/rules/engine-forwarders.md`](../../.agent/rules/engine-forwarders.md). This skill is the trigger surface — that file is the source of truth.
