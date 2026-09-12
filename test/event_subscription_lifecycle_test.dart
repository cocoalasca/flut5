import 'package:flut5/flut5.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Listener with Flut5EventMixin {
  final Map<String, int> counts = {};
  void _record(String event) =>
      counts.update(event, (n) => n + 1, ifAbsent: () => 1);

  @override
  void onPointerDown(SketchPointerEvent e) => _record('down');
  @override
  void onPointerUp(SketchPointerEvent e) => _record('up');
  @override
  void onPointerMove(SketchPointerEvent e) => _record('move');
  @override
  void onPointerDragged(SketchPointerEvent e) => _record('drag');
  @override
  void onKeyPressed(SketchKeyboardEvent e) => _record('pressed');
  @override
  void onKeyReleased(SketchKeyboardEvent e) => _record('released');
  @override
  void onKeyTyped(SketchKeyboardEvent e) => _record('typed');
  @override
  void onResize(ResizeEvent e) => _record('resize');
  @override
  void onMouseWheel(SketchScrollEvent e) => _record('scroll');
  @override
  void onStateChange(Map<String, dynamic> props) => _record('state');
}

void _emitAll(Flut5Engine engine) {
  engine.events
    ..addPointerHover(const PointerHoverEvent())
    ..addPointerDown(const PointerDownEvent())
    ..addPointerMove(const PointerMoveEvent())
    ..addPointerUp(const PointerUpEvent())
    ..addKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'a',
        timeStamp: Duration.zero,
      ),
    )
    ..addKeyEvent(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      ),
    )
    ..addResize(const ResizeEvent(Size.zero, Size(100, 100)))
    ..addPointerScroll(const PointerScrollEvent(scrollDelta: Offset(0, 10)))
    ..addStateChange({'updated': true});
}

void main() {
  late Flut5Engine engine;
  late _Listener listener;
  setUp(() {
    engine = Flut5Engine();
    listener = _Listener();
  });
  tearDown(() {
    listener.disposeEvents();
    engine.events.dispose();
    engine.ui.dispose();
    engine.disposeCursor();
  });

  test(
    'repeated registration delivers each event once, then cancels all',
    () async {
      listener.listenEvents(engine);
      listener.listenEvents(engine);
      _emitAll(engine);
      await Future<void>.delayed(Duration.zero);
      expect(listener.counts, {
        for (final name in [
          'down',
          'up',
          'move',
          'drag',
          'pressed',
          'released',
          'typed',
          'resize',
          'scroll',
          'state',
        ])
          name: 1,
      });
      listener.counts.clear();
      listener.disposeEvents();
      listener.disposeEvents();
      _emitAll(engine);
      await Future<void>.delayed(Duration.zero);
      expect(listener.counts, isEmpty);
    },
  );

  test('switching engines stops delivery from the old engine', () async {
    final other = Flut5Engine();
    addTearDown(() {
      other.events.dispose();
      other.ui.dispose();
      other.disposeCursor();
    });
    listener.listenEvents(engine);
    listener.listenEvents(other);
    _emitAll(engine);
    await Future<void>.delayed(Duration.zero);
    expect(listener.counts, isEmpty);
    _emitAll(other);
    await Future<void>.delayed(Duration.zero);
    expect(listener.counts, hasLength(10));
    expect(listener.counts.values, everyElement(1));
  });

  test('can subscribe again after disposal', () async {
    listener.listenEvents(engine);
    listener.disposeEvents();
    listener.listenEvents(engine);
    _emitAll(engine);
    await Future<void>.delayed(Duration.zero);
    expect(listener.counts, hasLength(10));
    expect(listener.counts.values, everyElement(1));
  });

  test('legacy state registration is replaced and disposed too', () async {
    // ignore: deprecated_member_use_from_same_package
    listener.listenStateChanges(engine);
    listener.listenEvents(engine);
    engine.events.addStateChange({});
    await Future<void>.delayed(Duration.zero);
    expect(listener.counts, {'state': 1});
    // ignore: deprecated_member_use_from_same_package
    listener.listenStateChanges(engine);
    listener.disposeEvents();
    engine.events.addStateChange({});
    await Future<void>.delayed(Duration.zero);
    expect(listener.counts, {'state': 1});
  });
}
