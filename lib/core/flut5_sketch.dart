import 'dart:async';

import '../flut5.dart';

/// Abstract for the Flut5 script.
///
/// Root sketches always own a fresh [Flut5Engine] (via [Flut5.root]) and
/// register it as [Flut5Engine.current], so plain [Flut5] helper classes
/// created during `setup()`/`draw()` adopt it automatically in global mode.
abstract class Flut5Sketch({super.listenEvents = true}) extends Flut5 {
  this : super.root();

  bool isReady = false;

  FutureOr<void> setup() {}
  void draw() {}
}
