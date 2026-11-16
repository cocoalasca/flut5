## 0.0.1

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
