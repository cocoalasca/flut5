import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// A sketch whose `draw()` body is supplied by the test, so each case can
/// exercise a different write pattern from inside the paint phase.
class _EmitSketch extends Flut5Sketch {
  _EmitSketch(this.onDraw);

  final void Function(_EmitSketch sketch) onDraw;

  /// 1 on the first frame that actually drew.
  int frames = 0;

  @override
  void draw() {
    frames++;
    background(const Color(0xFF000000));
    onDraw(this);
  }
}

Widget _host(Flut5Sketch sketch, Widget readout) => MaterialApp(
  home: Scaffold(
    body: Stack(
      children: [
        SizedBox(width: 200, height: 200, child: Flut5Canvas(sketch: sketch)),
        readout,
      ],
    ),
  ),
);

void main() {
  setUp(() {
    Flut5.instanceMode = false;
    Flut5Engine.current = null;
    Flut5Canvas.debugResetMultiCanvasWarning();
  });

  /// `setup()` runs in a post-frame callback and completes asynchronously; the
  /// ticker runs forever so pumpAndSettle is not an option.
  Future<void> run(
    WidgetTester tester,
    Flut5Sketch sketch, {
    Widget readout = const SizedBox.shrink(),
    int frames = 8,
  }) async {
    await tester.pumpWidget(_host(sketch, readout));
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  group('Flut5ValueNotifier', () {
    testWidgets('a write from draw() publishes without throwing', (
      tester,
    ) async {
      final score = Flut5ValueNotifier<int>(0);
      final seen = <int>[];
      score.addListener(() => seen.add(score.value));

      var next = 1;
      await run(tester, _EmitSketch((_) => score.value = next++));

      expect(tester.takeException(), isNull);
      expect(seen, isNotEmpty);
      // Exactly one publish per drawn frame, in order, nothing dropped.
      expect(seen, List<int>.generate(seen.length, (i) => i + 1));
    });

    testWidgets('repeat writes in one frame coalesce to the last value', (
      tester,
    ) async {
      final n = Flut5ValueNotifier<int>(0);
      var notifications = 0;
      n.addListener(() => notifications++);

      await run(
        tester,
        _EmitSketch((_) {
          n.value = 10;
          n.value = 20;
          n.value = 30;
        }),
      );

      // Three writes a frame across many frames, but the value only ever
      // *ends* a frame at 30 — so one notification, total.
      expect(notifications, 1);
      expect(n.value, 30);
    });

    testWidgets('reads inside draw() see the pending write', (tester) async {
      final n = Flut5ValueNotifier<int>(0);
      int? readBack;
      int? published;
      bool? pendingFlag;

      await run(
        tester,
        _EmitSketch((sketch) {
          if (sketch.frames != 1) return;
          n.value = 42;
          readBack = n.value;
          published = n.publishedValue;
          pendingFlag = n.hasPendingWrite;
        }),
      );

      expect(readBack, 42, reason: 'value must read back what draw() wrote');
      expect(published, 0, reason: 'listeners had not been notified yet');
      expect(pendingFlag, isTrue);
      expect(n.hasPendingWrite, isFalse, reason: 'the frame ended');
      expect(n.publishedValue, 42);
    });

    testWidgets('a write from outside the frame publishes immediately', (
      tester,
    ) async {
      final n = Flut5ValueNotifier<int>(0);
      n.value = 7;

      expect(n.hasPendingWrite, isFalse);
      expect(n.publishedValue, 7);
    });

    testWidgets('the listening widget keeps rebuilding', (tester) async {
      final n = Flut5ValueNotifier<int>(0);
      final rendered = <int>[];
      var next = 1;

      await run(
        tester,
        _EmitSketch((_) => n.value = next++),
        readout: ValueListenableBuilder<int>(
          valueListenable: n,
          builder: (_, value, _) {
            rendered.add(value);
            return Text('score $value');
          },
        ),
        frames: 12,
      );

      expect(tester.takeException(), isNull);
      // 0 from the initial build, then one rebuild per publish, in order and
      // with no gaps — the widget never got stuck.
      expect(rendered.length, greaterThan(3));
      expect(rendered, List<int>.generate(rendered.length, (i) => i));
      expect(find.text('score ${rendered.last}'), findsOneWidget);
    });

    testWidgets('disposing drops a write queued earlier in the frame', (
      tester,
    ) async {
      final n = Flut5ValueNotifier<int>(0);

      await run(
        tester,
        _EmitSketch((sketch) {
          if (sketch.frames != 2) return;
          n.value = 5;
          n.dispose();
        }),
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('updateTree', () {
    testWidgets('runs synchronously when the tree is already writable', (
      tester,
    ) async {
      var ran = false;
      updateTree(() => ran = true);

      expect(SchedulerBinding.instance.schedulerPhase, SchedulerPhase.idle);
      expect(ran, isTrue);
    });

    testWidgets('defers to the end of the frame when called from draw()', (
      tester,
    ) async {
      SchedulerPhase? phase;
      var runs = 0;

      await run(
        tester,
        _EmitSketch((sketch) {
          if (sketch.frames != 2) return;
          updateTree(() {
            runs++;
            phase = SchedulerBinding.instance.schedulerPhase;
          });
        }),
      );

      expect(runs, 1, reason: 'the callback runs once, not every frame');
      expect(phase, SchedulerPhase.postFrameCallbacks);
    });

    testWidgets('a plain setState from draw() still runs', (tester) async {
      final calls = <String>[];

      await run(
        tester,
        _EmitSketch((sketch) {
          if (sketch.frames > 3) return;
          calls.add('draw${sketch.frames}');
          updateTree(() => calls.add('update${sketch.frames}'));
        }),
      );

      // Every deferred callback lands after the draw() that queued it, and
      // before the next frame's draw().
      expect(calls, ['draw1', 'update1', 'draw2', 'update2', 'draw3', 'update3']);
    });

    testWidgets('one bad callback does not swallow the rest', (tester) async {
      var reached = false;

      await run(
        tester,
        _EmitSketch((sketch) {
          if (sketch.frames != 2) return;
          updateTree(() => throw StateError('boom'));
          updateTree(() => reached = true);
        }),
      );

      expect(tester.takeException(), isA<StateError>());
      expect(reached, isTrue);
    });
  });

  group('the hazard this exists for', () {
    testWidgets('a plain ValueNotifier written from draw() throws', (
      tester,
    ) async {
      final raw = ValueNotifier<int>(0);
      var next = 1;

      await run(
        tester,
        _EmitSketch((_) => raw.value = next++),
        readout: ValueListenableBuilder<int>(
          valueListenable: raw,
          builder: (_, value, _) => Text('raw $value'),
        ),
      );

      // markNeedsBuild flags the element dirty and *then* throws, so the
      // widget never reaches the dirty list and stops rebuilding for good.
      expect(tester.takeException(), isNotNull);
      expect(find.text('raw 0'), findsOneWidget);
    });
  });
}
