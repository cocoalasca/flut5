import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Flut5UI ui;
  setUp(() => ui = Flut5UI());
  tearDown(() => ui.dispose());

  for (final placement in ['append', 'prepend', 'insert']) {
    testWidgets('$placement children are released on removal', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox).first);
      final container = ui.createContainer();
      for (var i = 0; i < 25; i++) {
        final button = ui.createButton('Temporary $i');
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
      expect(ui.elements, [container]);
      ui.clear();
      expect(ui.elements, isEmpty);
    });
  }

  testWidgets('removing a mounted child rebuilds its parent', (tester) async {
    final container = ui.createContainer();
    final button = ui.createButton('Remove me');
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
    final first = ui.createContainer();
    final second = ui.createContainer();
    final button = ui.createButton('Moved');
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
    ui.clear();
  });

  testWidgets('nested removal releases the subtree exactly once', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox).first);
    final parent = ui.createContainer();
    final child = ui.createContainer();
    final button = ui.createButton('Nested');
    parent.append(child);
    child.append(button);
    child.remove();
    expect((parent.buildInner(context) as Row).children, isEmpty);
    expect((child.buildInner(context) as Row).children, isEmpty);
    expect(
      () => ChangeNotifier.debugAssertNotDisposed(button),
      throwsFlutterError,
    );
    ui.clear();
  });

  testWidgets(
    'setChildren disposes old elements and releases their references',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox).first);
      final container = ui.createContainer();
      final button = ui.createButton('Old');
      container.append(button);
      const replacement = Text('Replacement');
      container.setChildren([replacement]);
      expect((container.buildInner(context) as Row).children, [replacement]);
      expect(
        () => ChangeNotifier.debugAssertNotDisposed(button),
        throwsFlutterError,
      );
      ui.clear();
      expect((container.buildInner(context) as Row).children, isEmpty);
    },
  );

  test('rejects ownership cycles without changing the existing tree', () {
    final parent = ui.createContainer();
    final child = ui.createContainer();
    parent.append(child);
    expect(() => parent.append(parent), throwsArgumentError);
    expect(() => child.append(parent), throwsArgumentError);
    expect(ui.elements, [parent]);
    ui.clear();
  });

  test('UI disposal also disposes its remaining children', () {
    final other = Flut5UI();
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
