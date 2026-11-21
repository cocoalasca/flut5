## 0.0.1

* **Breaking:** widgets are now created through `flut5Widgets`, callable
  unprefixed from any `Flut5` subclass: `flut5Widgets.createButton('Reset')`,
  `flut5Widgets.createSlider(0, 1)`, and likewise for labels, toggles,
  checkboxes and containers. It replaces `ui` / `flut5.ui`. `Flut5UI` is
  renamed `Flut5Widgets`, the engine field `ui` is now `flut5Widgets`, and
  the files moved from `lib/ui/` to `lib/widgets/`. To migrate, replace
  `flut5.ui.` and `ui.` with `flut5Widgets.`.
* **Breaking:** steering is now global. `seek`, `arrive` and `flee` are
  engine methods callable unprefixed from any `Flut5` subclass, like
  `springForce`. They take the body's `position` and `velocity` as
  `Flut5Vector`s, plus `maxVelocity`/`maxForce` (defaults `4`/`0.1`), and
  return the steering force: `ball.applyForce(seek(ball.position,
  ball.velocity, target))`. The `Flut5Steering` mixin no longer gives a class
  `position`/`velocity`/`acceleration`, `applyForce`, `configSteering`,
  `setDamping` or `updateSteering`. Use a `Flut5PhysicsParticle` or your own
  vectors instead. The unused `Flut5SteeringNavigation` mixin is removed.
  `steeringTurboMode`, `steeringReturnMode` and `resetSteeringMode` now set
  the mode for one engine, not the whole process.
* Add `separation(position, velocity, neighbors, {separationRadius})`, the
  flocking rule that steers a body away from crowding neighbors. Each
  neighbor within the radius pushes it away, weighted by `1 / distance`, and
  the result is a steering force like `seek`'s. The body's own position can
  be in `neighbors`; it is skipped.
* Add `cohesion(position, velocity, neighbors, {cohesionRadius})`, the
  flocking rule that steers a body toward the center of its neighbors. It
  averages the neighbors within the radius and seeks that point. Like
  `separation`, it skips the body's own position.
* Add `softmax(values, [temperature])`, which turns a list of numbers into
  probabilities that sum to 1. A temperature below 1 sharpens the result
  toward the largest input, above 1 flattens it, and 0 gives all of it to
  the largest. It subtracts the maximum first, so large inputs don't
  overflow.
* Add `exp(n)`, Euler's number raised to the power `n`, as in p5.js.
* Add `randomWeightedIndex(weights)`, which picks a random index with
  probability proportional to its weight. The weights don't need to sum to
  1, and it follows `randomSeed`. Pair it with `softmax` to pick by score.
* Add `softmaxWeightedSelection(values, [temperature])`, which runs
  `softmax` then `randomWeightedIndex` in one call to pick an index by
  score. The temperature defaults to 1, like `softmax`.
* With a `beginPixelate` palette, every block now comes out solid in an
  exact palette colour, or empty: a block is drawn when what's drawn in it
  covers at least half of it, so edges stay sharp even with no background
  inside the scope. A shape under half opacity with nothing behind it inside
  the scope is left out.
* Release removed container children and transfer ownership when moving them
  between containers. Clear child references during UI teardown.
* Cancel previous event subscriptions when calling `listenEvents()` again.
* Expire unused text-cache entries after 600 Flutter frames, refreshing their
  lifetime on each hit. Add the shared `textCacheTimeout([frames])` setting.
* Require Dart 3.14 and Flutter 3.50 or later.
* Move off the deprecated `package:flutter/material.dart`. Engine files import
  `package:flutter/widgets.dart`; the slider is built on the standalone
  `material_ui` package, which is now a dependency (the toggle and checkbox
  take only colour and icon constants from it).
* UI elements work in any app: one built with `material_ui`, one still on the
  deprecated `package:flutter/material.dart`, or a plain `WidgetsApp`. The
  slider brings its own transparent `Material`, since `material_ui`'s is a
  different type from the framework's and the slider would otherwise throw
  "No Material widget found". It reads the app's theme only from a
  `material_ui` app, so migrating is recommended:
  `dart fix --apply --code=migrate_design_widgets`.
* Adopt primary constructors throughout the package, tests, and bundled example,
  preserving existing constructor names, arguments, and initialization behavior.
  The `use_primary_constructors` lint now enforces them, including an explicit
  `()` on classes and enums that relied on an implicit default constructor.
