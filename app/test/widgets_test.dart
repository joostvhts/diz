import 'package:diz/src/api/bridge_client.dart';
import 'package:diz/src/app.dart';
import 'package:diz/src/settings.dart';
import 'package:diz/src/state/lights_controller.dart';
import 'package:diz/src/ui/control_panel.dart';
import 'package:diz/src/ui/home_screen.dart';
import 'package:diz/src/ui/widgets/color_wheel.dart';
import 'package:diz_core/diz_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

void main() {
  late FakeLightsApi api;
  late LightsController controller;

  Future<void> pumpHome(WidgetTester tester) async {
    api = FakeLightsApi([colorLight, whiteLight, offlineLight]);
    controller = LightsController(
      api: api,
      pollInterval: const Duration(hours: 1),
      throttleInterval: Duration.zero,
    )..start();
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(controller: controller, onChangeBridge: () {}),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> tearDownHome(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  Finder tileSwitch(String id) =>
      find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(Switch));

  testWidgets('lists the group and every light with its state', (tester) async {
    await pumpHome(tester);
    expect(find.text('All lights'), findsOneWidget);
    expect(find.text('1 of 2 on · 1 offline'), findsOneWidget);
    expect(find.text('Desk'), findsOneWidget);
    expect(find.text('60% · 2700 K'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(tester.widget<Switch>(tileSwitch(offlineLight.id)).onChanged, isNull);
    await tearDownHome(tester);
  });

  testWidgets('toggling a light and the group sends commands', (tester) async {
    await pumpHome(tester);
    await tester.tap(tileSwitch(colorLight.id));
    await tester.pump();
    expect(api.commands.last, (colorLight.id, const SetStateCommand(on: false)));
    expect(find.text('Off'), findsNWidgets(2));

    final groupSwitch = find.descendant(
      of: find.ancestor(of: find.text('All lights'), matching: find.byType(Card)),
      matching: find.byType(Switch),
    );
    await tester.tap(groupSwitch);
    await tester.pump();
    expect(api.commands.last, (groupKey, const SetStateCommand(on: true)));
    await tearDownHome(tester);
  });

  testWidgets('control sheet sets white presets and colors', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.text('Desk'));
    await tester.pumpAndSettle();

    expect(find.text('Brightness'), findsOneWidget);
    expect(find.text('White'), findsOneWidget);
    await tester.tap(find.text('Cool'));
    await tester.pump();
    expect(api.commands.last, (colorLight.id, const SetStateCommand(kelvin: 6500)));

    await tester.tap(find.text('Color'));
    await tester.pumpAndSettle();
    final wheel = find.byType(ColorWheel);
    expect(wheel, findsOneWidget);
    final box = tester.getRect(
      find.descendant(of: wheel, matching: find.byType(CustomPaint)).first,
    );
    // Near the right edge of the wheel: hue 0 (red), high saturation.
    await tester.tapAt(box.center + Offset(box.width * 0.45, 0));
    await tester.pump();
    final (id, command) = api.commands.last;
    expect(id, colorLight.id);
    expect(command.rgb!.r, 255);
    expect(command.rgb!.g, lessThan(40));
    expect(command.rgb!.b, lessThan(40));
    await tearDownHome(tester);
  });

  testWidgets('white-only lights get no color tab', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.text('Hallway'));
    await tester.pumpAndSettle();
    expect(find.text('Color temperature'), findsOneWidget);
    expect(find.byType(SegmentedButton<Object>), findsNothing);
    expect(find.text('Color'), findsNothing);
    expect(find.text('Candle'), findsNothing, reason: '2200 K is outside this bulb\'s range');
    await tearDownHome(tester);
  });

  group('control sheet on a phone', () {
    const height = 900.0;
    const navigationBar = 48.0;
    const handle = 48.0;

    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(400, height);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: navigationBar);
      tester.view.viewPadding = const FakeViewPadding(bottom: navigationBar);
      addTearDown(tester.view.reset);
    }

    final sheet = find.byType(BottomSheet);
    Finder inSheet(Finder finder) => find.descendant(of: sheet, matching: finder);

    /// A short flick: up goes to the next larger size, down to the next smaller
    /// one (closing the sheet below the panel's height).
    Future<void> swipe(WidgetTester tester, {required bool up}) async {
      await tester.fling(inSheet(find.text('Brightness')), Offset(0, up ? -100 : 100), 1500);
      await tester.pumpAndSettle();
    }

    /// The sheet is as tall as the handle, the panel and the navigation bar.
    void expectPanelHeight(WidgetTester tester) {
      final sheetRect = tester.getRect(sheet);
      final panel = tester.getRect(find.byType(ControlPanel));
      expect(sheetRect.bottom, height, reason: 'the sheet runs under the navigation bar');
      expect(panel.bottom, moreOrLessEquals(height - navigationBar, epsilon: 1));
      expect(sheetRect.top, moreOrLessEquals(panel.top - handle, epsilon: 1));
      expect(sheetRect.top, greaterThan(100), reason: 'not full screen');
    }

    testWidgets('keeps the panel above the navigation bar', (tester) async {
      phone(tester);
      await pumpHome(tester);
      await tester.tap(find.text('Desk'));
      await tester.pumpAndSettle();
      expectPanelHeight(tester);
      await tearDownHome(tester);
    });

    testWidgets('swiping up makes it full screen, swiping down closes it', (tester) async {
      phone(tester);
      await pumpHome(tester);
      await tester.tap(find.text('Desk'));
      await tester.pumpAndSettle();
      final top = tester.getRect(sheet).top;

      await swipe(tester, up: true);
      expect(tester.getRect(sheet).top, 0);

      await swipe(tester, up: false);
      expect(tester.getRect(sheet).top, moreOrLessEquals(top, epsilon: 1));
      expectPanelHeight(tester);

      await swipe(tester, up: false);
      expect(sheet, findsNothing);
      await tearDownHome(tester);
    });

    testWidgets('follows the panel height when switching tabs', (tester) async {
      phone(tester);
      await pumpHome(tester);
      await tester.tap(find.text('Desk'));
      await tester.pumpAndSettle();
      final white = tester.getRect(sheet).height;

      await tester.tap(inSheet(find.text('Color')));
      await tester.pumpAndSettle();
      expectPanelHeight(tester);
      expect(tester.getRect(sheet).height, greaterThan(white));

      // After the sheet has been dragged, too.
      await swipe(tester, up: true);
      await swipe(tester, up: false);
      await tester.tap(inSheet(find.text('White')));
      await tester.pumpAndSettle();
      expectPanelHeight(tester);
      expect(tester.getRect(sheet).height, moreOrLessEquals(white, epsilon: 1));

      // Full screen stays full screen.
      await swipe(tester, up: true);
      await tester.tap(inSheet(find.text('Color')));
      await tester.pumpAndSettle();
      expect(tester.getRect(sheet).top, 0);
      await tearDownHome(tester);
    });

    testWidgets('tapping the handle switches to full screen and back', (tester) async {
      phone(tester);
      await pumpHome(tester);
      await tester.tap(find.text('Desk'));
      await tester.pumpAndSettle();
      final top = tester.getRect(sheet).top;

      await tester.tap(find.bySemanticsLabel('Resize the controls'));
      await tester.pumpAndSettle();
      expect(tester.getRect(sheet).top, 0);

      await tester.tap(find.bySemanticsLabel('Resize the controls'));
      await tester.pumpAndSettle();
      expect(tester.getRect(sheet).top, moreOrLessEquals(top, epsilon: 1));
      await tearDownHome(tester);
    });
  });

  testWidgets('wide screens show the controls in a side pane', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpHome(tester);
    expect(find.text('Select a light'), findsOneWidget);
    await tester.tap(find.text('Desk'));
    await tester.pump();
    expect(find.text('Brightness'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await tearDownHome(tester);
  });

  testWidgets('first run: connect to a bridge, then show the lights', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    final fake = FakeLightsApi([colorLight]);
    Uri? requestedUrl;
    String? requestedToken;
    await tester.pumpWidget(
      DizApp(
        settings: settings,
        apiFactory: (url, token) {
          requestedUrl = url;
          requestedToken = token;
          return fake;
        },
      ),
    );
    expect(find.text('Welcome to Diz'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Bridge address'), 'lights.example.com');
    await tester.enterText(
      find.widgetWithText(TextField, 'Access token'),
      ' secret-token-0123456789 ',
    );
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(requestedUrl.toString(), 'https://lights.example.com/');
    expect(requestedToken, 'secret-token-0123456789');
    expect(settings.bridgeUrl, requestedUrl);
    expect(settings.apiToken, 'secret-token-0123456789');
    expect(find.text('Desk'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a rejected token is reported on the token field', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    final fake = FakeLightsApi([colorLight])
      ..failWith = const BridgeException('nope', statusCode: 401);
    await tester.pumpWidget(DizApp(settings: settings, apiFactory: (url, token) => fake));
    await tester.enterText(find.widgetWithText(TextField, 'Bridge address'), 'lights.example.com');
    await tester.enterText(
      find.widgetWithText(TextField, 'Access token'),
      'wrong-token-0123456789',
    );
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump();
    expect(find.text('The bridge rejected this token.'), findsOneWidget);
    expect(find.text('Welcome to Diz'), findsOneWidget);
    expect(settings.bridgeUrl, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
