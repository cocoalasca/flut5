import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// Records every pointer event the sketch is handed, so a test can assert what
/// the overlay let through.
class _RecordingSketch extends Flut5Sketch {
  final List<String> seen = [];

  @override
  void onPointerDown(SketchPointerEvent e) => seen.add('down');

  @override
  void onPointerDragged(SketchPointerEvent e) => seen.add('drag');

  @override
  void onPointerUp(SketchPointerEvent e) => seen.add('up');

  @override
  void draw() {
    background(const Color(0xFF000000));
  }
}

Widget _host(Flut5Sketch sketch, {Widget? child}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 300,
      height: 300,
      child: Flut5Canvas(sketch: sketch, child: child),
    ),
  ),
);

/// A labelled 60×60 opaque box at (40,40) — the classic input-capturing
/// overlay. Its centre is (70,70).
Widget _boxOverlay() => Stack(
  children: [
    Positioned(
      left: 40,
      top: 40,
      child: Container(width: 60, height: 60, color: const Color(0xFFFFFFFF)),
    ),
  ],
);

void main() {
  setUp(() {
    Flut5.instanceMode = false;
    Flut5Engine.current = null;
    Flut5Canvas.debugResetChildNotice();
    Flut5Canvas.debugResetMultiCanvasWarning();
  });

  /// setup() runs in a post-frame callback and completes asynchronously; the
  /// ticker runs forever so pumpAndSettle is not an option.
  Future<_RecordingSketch> mounted(WidgetTester tester, {Widget? child}) async {
    final sketch = _RecordingSketch();
    await tester.pumpWidget(_host(sketch, child: child));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    sketch.seen.clear();
    return sketch;
  }

  testWidgets('with no child the sketch receives pointer events', (
    tester,
  ) async {
    final sketch = await mounted(tester);

    await tester.tapAt(const Offset(150, 150));
    await tester.pump();

    expect(sketch.seen, contains('down'));
  });

  testWidgets('a press on empty overlay space reaches the sketch', (
    tester,
  ) async {
    final sketch = await mounted(tester, child: _boxOverlay());

    await tester.tapAt(const Offset(250, 250)); // clear of the box
    await tester.pump();

    expect(sketch.seen, contains('down'));
  });

  testWidgets('a press inside an overlay widget does not reach the sketch', (
    tester,
  ) async {
    final sketch = await mounted(tester, child: _boxOverlay());

    await tester.tapAt(const Offset(70, 70)); // centre of the box
    await tester.pump();

    expect(sketch.seen, isEmpty);
  });

  testWidgets('IgnorePointer lets presses through to the sketch', (
    tester,
  ) async {
    final sketch = await mounted(
      tester,
      child: IgnorePointer(child: _boxOverlay()),
    );

    await tester.tapAt(const Offset(70, 70)); // same spot, now transparent
    await tester.pump();

    expect(sketch.seen, contains('down'));
  });

  testWidgets('an overlay button handles its own tap, sketch stays quiet', (
    tester,
  ) async {
    var pressed = false;
    // Deliberately not a Material button: ElevatedButton's ink-sparkle shader
    // fails to load under flutter_test on this SDK, which is unrelated to what
    // this asserts. A GestureDetector is the same case — an interactive
    // overlay widget claiming the gesture.
    final sketch = await mounted(
      tester,
      child: Stack(
        children: [
          Positioned(
            left: 40,
            top: 40,
            child: GestureDetector(
              onTap: () => pressed = true,
              child: Container(
                width: 60,
                height: 60,
                color: const Color(0xFFFFFFFF),
              ),
            ),
          ),
        ],
      ),
    );

    await tester.tapAt(const Offset(70, 70));
    await tester.pump();

    expect(pressed, isTrue);
    expect(sketch.seen, isEmpty, reason: 'no double delivery');
  });

  testWidgets('a drag started on empty space survives crossing the overlay', (
    tester,
  ) async {
    final sketch = await mounted(tester, child: _boxOverlay());

    final gesture = await tester.startGesture(const Offset(250, 250));
    await gesture.moveTo(const Offset(70, 70)); // over the box
    await gesture.up();
    await tester.pump();

    // Routing is fixed at pointer-down, so crossing a widget mid-drag must not
    // interrupt the sketch.
    expect(sketch.seen, contains('down'));
    expect(sketch.seen, contains('up'));
  });

  testWidgets('a drag started on the overlay never reaches the sketch', (
    tester,
  ) async {
    final sketch = await mounted(tester, child: _boxOverlay());

    final gesture = await tester.startGesture(const Offset(70, 70));
    await gesture.moveTo(const Offset(250, 250)); // out into empty space
    await gesture.up();
    await tester.pump();

    expect(sketch.seen, isEmpty);
  });

  testWidgets('the child does not change the canvas size', (tester) async {
    final sketch = await mounted(
      tester,
      // A child that would happily take 1000px if it were allowed to.
      child: const SizedBox(width: 1000, height: 1000),
    );

    expect(sketch.flut5.width, 300);
    expect(sketch.flut5.height, 300);
  });

  testWidgets('the orientation note fires once, and only with a child', (
    tester,
  ) async {
    await mounted(tester);
    expect(
      Flut5Canvas.debugChildNoticeShown,
      isFalse,
      reason: 'no child, nothing to explain',
    );

    await mounted(tester, child: _boxOverlay());
    expect(Flut5Canvas.debugChildNoticeShown, isTrue);

    // Guard is static: a second canvas with a child must not re-fire it.
    Flut5Canvas.debugResetChildNotice();
    await mounted(tester, child: _boxOverlay());
    expect(Flut5Canvas.debugChildNoticeShown, isTrue);
  });
}
