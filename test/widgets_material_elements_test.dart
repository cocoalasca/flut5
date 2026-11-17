// The slider is flut5's only UI element built from a Material widget
// (`material_ui`'s `Slider`); the toggle and checkbox are custom widgets that
// borrow colour and icon constants. All three must render whatever the app
// around them is built with: `material_ui`, the deprecated
// `package:flutter/material.dart` (whose `Material` is a different type), or
// no Material library at all.
// ignore_for_file: deprecated_member_use
import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart' as legacy;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

typedef _AppBuilder = Widget Function(WidgetBuilder body);

void main() {
  late Flut5Widgets widgets;
  setUp(() => widgets = Flut5Widgets());
  tearDown(() => widgets.dispose());

  final apps = <String, _AppBuilder>{
    'a material_ui app': (body) => MaterialApp(
      home: Scaffold(body: Builder(builder: body)),
    ),
    'a legacy flutter/material app': (body) => legacy.MaterialApp(
      home: legacy.Scaffold(body: Builder(builder: body)),
    ),
    // With a home route, so there is a Navigator and its Overlay, which
    // Slider needs in any app.
    'a plain WidgetsApp': (body) => WidgetsApp(
      color: const Color(0xFF000000),
      // Loose constraints, as a Scaffold body gives: a bare route would
      // stretch the element over the whole screen.
      home: Align(
        alignment: Alignment.topLeft,
        child: Builder(builder: body),
      ),
      pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, _) => builder(context),
      ),
    ),
  };

  for (final MapEntry(key: appName, value: app) in apps.entries) {
    group('in $appName', () {
      testWidgets('slider renders and follows a drag', (tester) async {
        final slider = widgets.createSlider(0, 10, 4);
        double? reported;
        slider.changed((value) => reported = value);
        await tester.pumpWidget(app(slider.buildInteractiveListenable));
        expect(tester.takeException(), isNull);
        expect(tester.widget<Slider>(find.byType(Slider)).value, 4);

        await tester.drag(find.byType(Slider), const Offset(120, 0));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(slider.value, greaterThan(4));
        expect(reported, slider.value);
      });

      testWidgets('checkbox shows its check only when checked', (tester) async {
        final checkbox = widgets.createCheckbox(true);
        await tester.pumpWidget(app(checkbox.buildInteractiveListenable));
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.check), findsOneWidget);
      });

      testWidgets('toggle flips when tapped', (tester) async {
        final toggle = widgets.createToggle(false);
        bool? reported;
        toggle.changed((value) => reported = value);
        await tester.pumpWidget(app(toggle.buildInteractiveListenable));
        expect(tester.takeException(), isNull);

        await tester.tap(find.byType(GestureDetector).first);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(toggle.value, isTrue);
        expect(reported, isTrue);
      });
    });
  }
}
