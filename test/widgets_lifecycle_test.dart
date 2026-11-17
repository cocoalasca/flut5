import 'package:flut5/flut5.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// A helper that is not a sketch. Built during `setup()`, it adopts the
/// sketch's engine (global mode), so its `flut5Widgets` is the sketch's.
class _LegendHelper() extends Flut5 {
  late final Flut5Label legend = flut5Widgets.createLabel('Legend');
}

/// Creates its widgets through the unprefixed `flut5Widgets` entry point.
class _WidgetSketch() extends Flut5Sketch {
  late Flut5Button resetButton;
  late _LegendHelper helper;

  @override
  void setup() {
    resetButton = flut5Widgets.createButton('Reset')..position(20, 30);
    helper = _LegendHelper()..legend.position(20, 60);
  }
}

void main() {
  group('flut5Widgets entry point', () {
    setUp(() {
      Flut5.instanceMode = false;
      Flut5Engine.current = null;
      Flut5Canvas.debugResetMultiCanvasWarning();
    });

    testWidgets('a sketch and its helpers create widgets on its canvas', (
      tester,
    ) async {
      final sketch = _WidgetSketch();
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 300,
            child: Flut5Canvas(sketch: sketch),
          ),
        ),
      );
      // setup() runs in a post-frame callback and the ticker never settles.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(sketch.flut5Widgets, same(sketch.flut5.flut5Widgets));
      expect(sketch.helper.flut5Widgets, same(sketch.flut5Widgets));
      expect(sketch.flut5Widgets.elements, [
        sketch.resetButton,
        sketch.helper.legend,
      ]);
      expect(find.text('Reset'), findsOneWidget);
      expect(find.text('Legend'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Reset')),
        tester.getTopLeft(find.byType(Flut5Canvas)) + const Offset(20, 30),
      );
    });
  });

  late Flut5Widgets widgets;
  setUp(() => widgets = Flut5Widgets());
  tearDown(() => widgets.dispose());

  for (final placement in ['append', 'prepend', 'insert']) {
    testWidgets('$placement children are released on removal', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox).first);
      final container = widgets.createContainer();
      for (var i = 0; i < 25; i++) {
        final button = widgets.createButton('Temporary $i');
        switch (placement) {
          case 'append':
            container.append(button);
          case 'prepend':
            container.prepend(button);
          case 'insert':
            container.insert(0, button);
        }
        button.remove();
      }
      expect((container.buildInner(context) as Row).children, isEmpty);
      expect(widgets.elements, [container]);
      widgets.clear();
      expect(widgets.elements, isEmpty);
    });
  }

  testWidgets('removing a mounted child rebuilds its parent', (tester) async {
    final container = widgets.createContainer();
    final button = widgets.createButton('Remove me');
    container.append(button);
    await tester.pumpWidget(
      MaterialApp(home: Builder(builder: container.buildInteractiveListenable)),
    );
    expect(find.text('Remove me'), findsOneWidget);
    button.remove();
    await tester.pump();
    expect(find.text('Remove me'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('moving and reordering a child keeps a single owner', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox).first);
    final first = widgets.createContainer();
    final second = widgets.createContainer();
    final button = widgets.createButton('Moved');
    first.append(button);
    second.append(button);
    second.prepend(button);
    second.insert(99, button);
    expect((first.buildInner(context) as Row).children, isEmpty);
    expect((second.buildInner(context) as Row).children, hasLength(1));
    first.remove();
    button.setLabel('Still alive');
    button.remove();
    expect((second.buildInner(context) as Row).children, isEmpty);
    widgets.clear();
  });

  testWidgets('nested removal releases the subtree exactly once', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox).first);
    final parent = widgets.createContainer();
    final child = widgets.createContainer();
    final button = widgets.createButton('Nested');
    parent.append(child);
    child.append(button);
    child.remove();
    expect((parent.buildInner(context) as Row).children, isEmpty);
    expect((child.buildInner(context) as Row).children, isEmpty);
    expect(
      () => ChangeNotifier.debugAssertNotDisposed(button),
      throwsFlutterError,
    );
    widgets.clear();
  });

  testWidgets(
    'setChildren disposes old elements and releases their references',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox).first);
      final container = widgets.createContainer();
      final button = widgets.createButton('Old');
      container.append(button);
      const replacement = Text('Replacement');
      container.setChildren([replacement]);
      expect((container.buildInner(context) as Row).children, [replacement]);
      expect(
        () => ChangeNotifier.debugAssertNotDisposed(button),
        throwsFlutterError,
      );
      widgets.clear();
      expect((container.buildInner(context) as Row).children, isEmpty);
    },
  );

  test('rejects ownership cycles without changing the existing tree', () {
    final parent = widgets.createContainer();
    final child = widgets.createContainer();
    parent.append(child);
    expect(() => parent.append(parent), throwsArgumentError);
    expect(() => child.append(parent), throwsArgumentError);
    expect(widgets.elements, [parent]);
    widgets.clear();
  });

  test('UI disposal also disposes its remaining children', () {
    final other = Flut5Widgets();
    final parent = other.createContainer();
    final button = other.createButton('Owned');
    parent.append(button);
    other.dispose();
    expect(other.elements, isEmpty);
    expect(
      () => ChangeNotifier.debugAssertNotDisposed(button),
      throwsFlutterError,
    );
  });
}
