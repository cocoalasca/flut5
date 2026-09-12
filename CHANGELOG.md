## 0.0.1

* Release removed container children and transfer ownership when moving them
  between containers. Clear child references during UI teardown.
* Cancel previous event subscriptions when calling `listenEvents()` again.
* Expire unused text-cache entries after 600 Flutter frames, refreshing their
  lifetime on each hit. Add the shared `textCacheTimeout([frames])` setting.
* Require Dart 3.13 and Flutter 3.47 or later.
* Adopt primary constructors throughout the package, tests, and bundled example,
  preserving existing constructor names, arguments, and initialization behavior.
