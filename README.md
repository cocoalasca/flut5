<!--
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/tools/pub/writing-package-pages).

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/to/develop-packages).
-->

TODO: Put a short description of the package here that helps potential users
know whether this package might be useful for them.

## Features

TODO: List what your package can do. Maybe include images, gifs, or videos.

## Getting started

Requires Dart 3.13 or later and Flutter 3.47 or later. The package, bundled
example, and sibling demos use Dart 3.13 primary constructors.

Run `flutter pub get` after upgrading Flutter, then restart the Dart analysis
server in your editor so it picks up the new SDK and language version.

## Usage

TODO: Include short and useful examples for package users. Add longer examples
to `/example` folder.

```dart
const like = 'sample';
```

Text caches expire entries after **600 unused Flutter frames** by default. A
cache hit refreshes the entry's lifetime. Set the timeout from any sketch:

```dart
textCacheTimeout(1200); // Keep entries for up to 1200 unused frames.
final timeout = textCacheTimeout(); // Read the shared setting.
```

The timeout applies to text textures, layouts, and measurements across all
sketches. Values must be positive integers. Cleanup runs after painting and
releases expired textures; existing cache size and byte limits still apply.
Frames are counted once per Flutter frame, regardless of canvas count. At
60 FPS, 600 frames is about 10 seconds; expiration pauses while no frames run.

## Additional information

TODO: Tell users more about the package: where to find more information, how to
contribute to the package, how to file issues, what response they can expect
from the package authors, and more.
