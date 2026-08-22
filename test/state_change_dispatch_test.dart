import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// A helper object of the kind a sketch spawns for its particles — it reaches
/// props through the same `listenEvents: true` subscription it uses for
/// pointer events, with no `stateListener` flag at the call site.
class _Helper extends Flut5 {
  _Helper({super.flut5}) : super(listenEvents: true);

  final List<Map<String, dynamic>> received = [];

  @override
  void onStateChange(Map<String, dynamic> props) => received.add(props);
}

class _CountingSketch extends Flut5Sketch {
  final List<Map<String, dynamic>> received = [];

  /// Built in the constructor body rather than `setup()` so these tests do not
  /// depend on a canvas actually painting — only the first Flut5Canvas mounted
  /// in a test file runs setup()/draw() under flutter_test.
  late final _Helper helper;

  _CountingSketch() {
    helper = _Helper(flut5: flut5);
  }

  @override
  void onStateChange(Map<String, dynamic> props) => received.add(props);
}

/// Rebuilds the canvas with whatever props the test last set.
class _Host extends StatefulWidget {
  final _CountingSketch sketch;
  const _Host({required this.sketch});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  Map<String, dynamic> props = {'count': 0};

  void update(Map<String, dynamic> next) => setState(() => props = next);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 100,
        height: 100,
        child: Flut5Canvas(sketch: widget.sketch, props: props),
      ),
    ),
  );
}

void main() {
  setUp(() {
    Flut5.instanceMode = false;
    Flut5Engine.current = null;
  });

  Future<_CountingSketch> mounted(WidgetTester tester) async {
    final sketch = _CountingSketch();
    await tester.pumpWidget(_Host(sketch: sketch));
    await tester.pump();
    return sketch;
  }

  /// Applies new props and lets the broadcast microtask drain.
  Future<void> setProps(WidgetTester tester, Map<String, dynamic> next) async {
    tester.state<_HostState>(find.byType(_Host)).update(next);
    await tester.pump();
  }

  testWidgets('a props change reaches the sketch exactly once', (tester) async {
    final sketch = await mounted(tester);
    expect(sketch.received, isEmpty, reason: 'mounting is not a change');

    await setProps(tester, {'count': 1});

    // Stream delivery must not double up with a direct onStateChange call.
    expect(sketch.received, hasLength(1));
    expect(sketch.received.single['count'], 1);
  });

  testWidgets('an unchanged props map does not re-dispatch', (tester) async {
    final sketch = await mounted(tester);

    // Equal by value to the initial map, different instance.
    await setProps(tester, {'count': 0});

    expect(sketch.received, isEmpty);
  });

  testWidgets('a helper with listenEvents: true receives props too', (
    tester,
  ) async {
    final sketch = await mounted(tester);

    await setProps(tester, {'count': 7});

    // No `stateListener: true` anywhere — the receiver alone opts in.
    expect(sketch.helper.received, hasLength(1));
    expect(sketch.helper.received.single['count'], 7);
  });

  testWidgets('every subscriber sees each change once, in order', (
    tester,
  ) async {
    final sketch = await mounted(tester);

    await setProps(tester, {'count': 1});
    await setProps(tester, {'count': 2});
    await setProps(tester, {'count': 3});

    expect(sketch.received.map((p) => p['count']), [1, 2, 3]);
    expect(sketch.helper.received.map((p) => p['count']), [1, 2, 3]);
  });

  testWidgets('the props field is updated synchronously with the rebuild', (
    tester,
  ) async {
    final sketch = await mounted(tester);

    await setProps(tester, {'count': 42});

    // Callback delivery moved to a microtask, but the field itself is still
    // assigned in didUpdateWidget — so draw() never reads a stale value.
    expect(sketch.props['count'], 42);
  });

  testWidgets('a disposed sketch stops receiving props', (tester) async {
    final sketch = await mounted(tester);
    await setProps(tester, {'count': 1});
    expect(sketch.received, hasLength(1));

    await tester.pumpWidget(const SizedBox());
    sketch.flut5.events.addStateChange({'count': 2});
    await tester.pump();

    expect(sketch.received, hasLength(1), reason: 'subscription was cancelled');
  });
}
