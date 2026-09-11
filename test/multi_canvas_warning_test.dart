import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

class _EmptySketch extends Flut5Sketch;

/// Two fixed-size canvases side by side, each hosting its own sketch.
Widget _twoCanvases() => MaterialApp(
  home: Scaffold(
    body: Row(
      children: [
        SizedBox(
          width: 100,
          height: 100,
          child: Flut5Canvas(sketch: _EmptySketch()),
        ),
        SizedBox(
          width: 100,
          height: 100,
          child: Flut5Canvas(sketch: _EmptySketch()),
        ),
      ],
    ),
  ),
);

Widget _oneCanvas() => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 100,
      height: 100,
      child: Flut5Canvas(sketch: _EmptySketch()),
    ),
  ),
);

void main() {
  setUp(() {
    Flut5.instanceMode = false;
    Flut5Engine.current = null;
    Flut5Canvas.debugResetMultiCanvasWarning();
  });

  testWidgets('global mode + two canvases fires the advice once', (
    tester,
  ) async {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };

    await tester.pumpWidget(_twoCanvases());
    // Let the post-frame check run and a paint flush the queued warning.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));

    // Restore before asserting: the test framework verifies foundation debug
    // vars are unset before addTearDown runs, so it must be reset in-body.
    debugPrint = original;

    expect(Flut5Canvas.debugMultiCanvasWarned, isTrue);
    final advice = logs.where((l) => l.contains('Multiple Flut5Canvas'));
    expect(
      advice,
      hasLength(1),
      reason: 'warning must be printed exactly once',
    );
    expect(advice.first, contains('Flut5.instanceMode = true'));
  });

  testWidgets('instance mode + two canvases does not warn', (tester) async {
    Flut5.instanceMode = true;

    await tester.pumpWidget(_twoCanvases());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(Flut5Canvas.debugMultiCanvasWarned, isFalse);
  });

  testWidgets('global mode + single canvas does not warn', (tester) async {
    await tester.pumpWidget(_oneCanvas());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(Flut5Canvas.debugMultiCanvasWarned, isFalse);
  });
}
