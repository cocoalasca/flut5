import 'dart:ui' as ui;

import '../flut5_console.dart';

/// The package's fragment shaders, loaded once per process.
///
/// Loading is asynchronous. [Flut5Canvas] starts it when it is created,
/// without waiting — an engine asset load never completes under a widget
/// test's fake clock, so awaiting it would stall `setup()` — and it normally
/// lands before the first frame. Code that replays a render queue on its own
/// canvas, tests included, should await [load] first.
abstract final class Flut5Shaders {
  static Future<void>? _loading;
  static bool _loaded = false;
  static ui.FragmentProgram? _palette;

  /// Whether [load] has started and not finished yet.
  static bool get isLoading => _loading != null && !_loaded;

  /// Snaps an image to the nearest colours of a palette — see
  /// `shaders/flut5_palette.frag`. `null` until [load] completes, or when
  /// the shader could not be loaded.
  static ui.FragmentProgram? get palette => _palette;

  /// Loads every shader. Safe to call any number of times; never throws — a
  /// shader that fails to load stays `null`, with a console warning.
  static Future<void> load() => _loading ??= _load();

  static Future<void> _load() async {
    _palette = await _program('flut5_palette.frag');
    _loaded = true;
  }

  /// Loads [name] under the key an app sees for a package asset, falling
  /// back to the bare key the package's own tests and example see.
  static Future<ui.FragmentProgram?> _program(String name) async {
    Object? failure;
    for (final key in ['packages/flut5/shaders/$name', 'shaders/$name']) {
      try {
        return await ui.FragmentProgram.fromAsset(key);
      } catch (e) {
        failure = e;
      }
    }
    Flut5Console.printLater(
      'Flut5: could not load the shader $name ($failure). Features that '
      'need it will draw without it.',
    );
    return null;
  }
}
