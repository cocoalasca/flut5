## 0.0.1

* Release removed container children and transfer ownership when moving them
  between containers. Clear child references during UI teardown.
* Cancel previous event subscriptions when calling `listenEvents()` again.
* Expire unused text-cache entries after 600 Flutter frames, refreshing their
  lifetime on each hit. Add the shared `textCacheTimeout([frames])` setting.
* Require Dart 3.14 and Flutter 3.50 or later.
* Move off the deprecated `package:flutter/material.dart`. The engine core now
  imports only `package:flutter/widgets.dart`; the slider, toggle, and checkbox
  use the standalone `material_ui` package, which is now a dependency.
  **Apps must build their widget tree with `material_ui`**
  (`import 'package:material_ui/material_ui.dart';`). Its `Material` is a
  different type from the deprecated framework copy, so a flut5 slider inside a
  `package:flutter/material.dart` `Scaffold` throws "No Material widget found".
  Run `dart fix --apply --code=migrate_design_widgets` in the app to migrate.
* Adopt primary constructors throughout the package, tests, and bundled example,
  preserving existing constructor names, arguments, and initialization behavior.
  The `use_primary_constructors` lint now enforces them, including an explicit
  `()` on classes and enums that relied on an implicit default constructor.
