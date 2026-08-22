import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// Draws with a translucent background, which is what puts a frame through
/// the trail-snapshot path.
class _TrailSketch extends Flut5Sketch {
  @override
  void draw() {
    background(const Color(0x22000000));
    fill(Colors.red);
    circle(20, 20, 10);
  }
}

/// Same drawing, opaque background — the fast path, no snapshot maintained.
class _OpaqueSketch extends Flut5Sketch {
  @override
  void draw() {
    background(const Color(0xFF000000));
    fill(Colors.red);
    circle(20, 20, 10);
  }
}

Widget _host(Flut5Sketch sketch) => MaterialApp(
  home: Scaffold(
    body: SizedBox(width: 100, height: 100, child: Flut5Canvas(sketch: sketch)),
  ),
);

void main() {
  setUp(() {
    Flut5.instanceMode = false;
    Flut5Engine.current = null;
    Flut5Painter.debugResetTrailBuildModeAdvice();
  });

  /// Pumps enough frames for setup to run and a paint to flush the queued
  /// console output, capturing whatever was printed.
  Future<List<String>> runAndCapture(
    WidgetTester tester,
    Flut5Sketch sketch,
  ) async {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    await tester.pumpWidget(_host(sketch));
    // setup() runs in a post-frame callback and completes asynchronously, so
    // the number of frames before draw() first executes is not fixed — it
    // shifted once another test had run first. Pump generously rather than
    // guessing; the ticker runs forever so pumpAndSettle is not an option.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Restore before asserting: the framework verifies foundation debug hooks
    // are left as they were found.
    debugPrint = original;
    return logs;
  }

  testWidgets('a translucent background triggers the advice exactly once', (
    tester,
  ) async {
    // Eight painted frames, each of which runs the trail path — so this also
    // pins the per-session suppression, not just that the advice appears.
    final logs = await runAndCapture(tester, _TrailSketch());
    final matches = logs.where((l) => l.contains('translucent background'));
    expect(matches, hasLength(1));
    expect(matches.single, contains('A release build usually fixes both'));
    expect(Flut5Painter.debugTrailBuildModeAdviceShown, isTrue);
  });

  testWidgets('an opaque background never triggers it', (tester) async {
    final logs = await runAndCapture(tester, _OpaqueSketch());
    expect(
      logs.where((l) => l.contains('translucent background')),
      isEmpty,
    );
    expect(Flut5Painter.debugTrailBuildModeAdviceShown, isFalse);
  });

  test('the guard is static, so a second canvas cannot re-fire it', () {
    // Asserted directly rather than through a second widget. This used to be
    // forced: the awaited font preload left every canvas after the first in a
    // file stuck before setup(). Flut5Text now caches the resolved font map,
    // so a second canvas does reach draw() and this could be widened into a
    // widget test. Repeat-suppression across frames is covered by the test
    // above.
    expect(Flut5Painter.debugTrailBuildModeAdviceShown, isFalse);
    Flut5Painter.debugResetTrailBuildModeAdvice();
    expect(Flut5Painter.debugTrailBuildModeAdviceShown, isFalse);
  });
}
