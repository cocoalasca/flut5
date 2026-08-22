import 'dart:async';

import '../flut5.dart';

/// Abstract for the Flut5 script.
///
/// Root sketches always own a fresh [Flut5Engine] (via [Flut5.root]) and
/// register it as [Flut5Engine.current], so plain [Flut5] helper classes
/// created during `setup()`/`draw()` adopt it automatically in global mode.
abstract class Flut5Sketch extends Flut5 {
  Flut5Sketch({super.listenEvents = true}) : super.root();

  bool isReady = false;

  /// Flexible props map passed from the parent widget via [Flut5Canvas.props].
  /// Updated before [setup] runs and whenever the parent rebuilds with new props.
  /// Access as `props` inside [setup] or [draw].
  Map<String, dynamic> props = const {};

  FutureOr<void> setup() {}
  void draw() {}
}
