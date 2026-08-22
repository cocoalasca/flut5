# AGENTS.md

Guidance for AI coding agents working on the Flut5 package. Mirrors the Claude-specific configuration in `.agent/rules/` and `.claude/skills/` for agents (Codex, Cursor, Continue, Aider, etc.) that do not read those folders by default.

## Project layout (orientation)

- `lib/flut5.dart` — public entry point. Exports every public file and defines the `Flut5` base class that sketch authors extend.
- `lib/core/flut5_engine.dart` — the engine instance, composed from mixins (`Flut5Fill`, `Flut5Stroke`, `Flut52DPrimitives`, `Flut5Vertex`, `Flut5Transform`, `Flut5Clip`, `Flut5Text`, `Flut5Cursor`, etc.).
- `lib/core/render/` — deferred render queue and per-item executors. All drawing goes through `Flut5RenderQueue`.
- `lib/shape/`, `lib/text/`, `lib/image/`, `lib/math/`, `lib/ui/` — feature areas; each surface is a mixin on the engine.

## Project rules

### Engine forwarders (always apply)

Whenever you add, rename, or remove a **public** member (method / getter / setter / field) on `Flut5Engine` or any of its mixins, you **must** also add / rename / remove the matching one-line forwarder in the `Flut5` class in `lib/flut5.dart`.

Reason: `Flut5` is the class sketch authors extend. They call `ellipse(...)`, `clip(...)`, `mouseX`, etc. directly, without the `flut5.` prefix. If a forwarder is missing, the bare form silently fails to compile while the prefixed form keeps working — a partial API.

**Apply when:**
- A public method is added or edited on any class/mixin reachable from `Flut5Engine`.
- A public getter / setter / field is added.
- A public member is renamed or removed.

**Skip when:**
- The member is private (leading `_`).
- The member is already exposed via a mixin applied directly to `Flut5` (e.g. `Flut5EventMixin`).
- It's internal cross-mixin plumbing not meant for sketch authors.

**Forwarder style** (under the appropriate `// ── Section` header in `lib/flut5.dart`):

```dart
// Method
ReturnType name(Params) => flut5.name(params);

// Getter / setter
Type get name => flut5.name;
set name(Type v) => flut5.name = v;
```

Full rule with rationale and edge cases: [`.agent/rules/engine-forwarders.md`](.agent/rules/engine-forwarders.md).

### UI elements

See [`.agent/rules/ui-elements.md`](.agent/rules/ui-elements.md) for the corresponding rule covering `Flut5UI` element conventions.

## Mapping to per-tool configuration

- **Claude Code** — reads `.agent/rules/*.md` (always-loaded if `trigger: always`) and `.claude/skills/*/SKILL.md` (invokable). The `engine-forwarders` skill mirrors the rule above as a trigger surface.
- **Cursor / Codex / other agents** — read this file. Apply the rules above directly.

When in doubt, the canonical rule files in `.agent/rules/` win — this file is a summary for agents that can't reach them.
