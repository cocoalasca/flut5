// The slider, toggle and checkbox are the only UI elements built from
// Material widgets, imported from `package:material_ui`. Material's widgets
// assert a `Material` ancestor from the same library, so these must render
// inside a `material_ui` app — the setup sketch authors use since Flutter 3.50.
import 'package:flut5/flut5.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late Flut5UI ui;
  setUp(() => ui = Flut5UI());
  tearDown(() => ui.dispose());

  Future<void> pumpElement(WidgetTester tester, Flut5UIElement element) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: element.buildInteractiveListenable),
          ),
        ),
      );

  testWidgets('slider renders a Material Slider', (tester) async {
    await pumpElement(tester, ui.createSlider(0, 10, 4));
    expect(tester.takeException(), isNull);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 4);
  });

  testWidgets('checkbox renders its check icon when checked', (tester) async {
    await pumpElement(tester, ui.createCheckbox(true));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('toggle renders', (tester) async {
    final toggle = ui.createToggle(true);
    await pumpElement(tester, toggle);
    expect(tester.takeException(), isNull);
    expect(toggle.value, isTrue);
  });
}
