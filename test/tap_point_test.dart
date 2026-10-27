import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

/// tap_point: press exactly at one view point, like a finger, whatever is there.
void main() {
  testWidgets(
    'tap_point presses a row that only listens for finger down and finger up',
    (tester) async {
      var presses = 0;
      final app = await _host(tester, _pressAndReleaseRow(() => presses += 1));
      final centre = tester.getCenter(find.text('Emmanuel'));

      final action = app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tapPoint,
          target: ElementTarget(
            point: FallbackPoint(x: centre.dx, y: centre.dy),
          ),
          purpose: 'tap_point_row',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final result = await _pumpUntilComplete(tester, action);

      expect(result.ok, isTrue, reason: result.error?.message);
      expect(presses, 1, reason: 'exactly one press reached the row');
      expect(result.data['operationPhase'], 'settled');
      expect(result.data['dispatch'], 'in_app_pointer');
      final pressed = result.data['underPointer'] as Map;
      expect(pressed['label'], 'Emmanuel');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'the receipt names the element on top, not a label underneath it',
    (tester) async {
      var presses = 0;
      final app = await _host(
        tester,
        Stack(
          children: <Widget>[
            const Positioned(left: 150, top: 110, child: Text('PIN eingeben')),
            Positioned(
              left: 80,
              top: 90,
              width: 320,
              height: 72,
              child: _pressAndReleaseRow(() => presses += 1),
            ),
          ],
        ),
      );
      final underneath = tester.getCenter(find.text('PIN eingeben'));

      final action = app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tapPoint,
          target: ElementTarget(
            point: FallbackPoint(x: underneath.dx, y: underneath.dy),
          ),
          purpose: 'tap_point_overlay_row',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final result = await _pumpUntilComplete(tester, action);

      expect(result.ok, isTrue, reason: result.error?.message);
      expect(presses, 1, reason: 'the row on top received the press');
      expect((result.data['underPointer'] as Map)['label'], 'Emmanuel');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'tap_point presses a disabled button like a finger; the app decides nothing happens',
    (tester) async {
      var presses = 0;
      final app = await _host(
        tester,
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const ElevatedButton(onPressed: null, child: Text('Fortfahren')),
              TextButton(
                onPressed: () => presses += 1,
                child: const Text('Elsewhere'),
              ),
            ],
          ),
        ),
      );
      final centre = tester.getCenter(find.text('Fortfahren'));

      final action = app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tapPoint,
          target: ElementTarget(
            point: FallbackPoint(x: centre.dx, y: centre.dy),
          ),
          purpose: 'tap_point_disabled_button',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final result = await _pumpUntilComplete(tester, action);

      expect(result.ok, isTrue, reason: result.error?.message);
      expect(
        result.data['operationPhase'],
        'settled',
        reason: 'the press was delivered, not refused',
      );
      expect(presses, 0, reason: 'no other control received the press');
      expect(result.message, contains('Fortfahren'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'the receipt names an unlabelled control from the widget under the finger',
    (tester) async {
      var presses = 0;
      final app = await _host(
        tester,
        Theme(
          // The tester cannot load the Material 3 ripple shader.
          data: ThemeData(splashFactory: NoSplash.splashFactory),
          child: Center(
            child: IconButton(
              onPressed: () => presses += 1,
              icon: const Icon(Icons.expand_more),
            ),
          ),
        ),
      );
      final centre = tester.getCenter(find.byType(IconButton));

      final action = app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tapPoint,
          target: ElementTarget(
            point: FallbackPoint(x: centre.dx, y: centre.dy),
          ),
          purpose: 'tap_point_unlabelled_icon',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final result = await _pumpUntilComplete(tester, action);

      expect(result.ok, isTrue, reason: result.error?.message);
      expect(presses, 1);
      final pressed = result.data['underPointer'] as Map;
      expect(pressed['role'], 'button');
      expect(pressed.containsKey('label'), isFalse);
      expect(result.message, contains('on an unlabelled button'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'the receipt says when the unlabelled control under the finger is disabled',
    (tester) async {
      final app = await _host(
        tester,
        const Center(
          child: IconButton(onPressed: null, icon: Icon(Icons.expand_more)),
        ),
      );
      final centre = tester.getCenter(find.byType(IconButton));

      final action = app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tapPoint,
          target: ElementTarget(
            point: FallbackPoint(x: centre.dx, y: centre.dy),
          ),
          purpose: 'tap_point_disabled_icon',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final result = await _pumpUntilComplete(tester, action);

      expect(result.ok, isTrue, reason: result.error?.message);
      final pressed = result.data['underPointer'] as Map;
      expect(pressed['enabled'], isFalse);
      expect(result.message, contains('on an unlabelled disabled button'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('tap_point outside the view sends nothing', (tester) async {
    var presses = 0;
    final app = await _host(tester, _pressAndReleaseRow(() => presses += 1));

    final action = app.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.tapPoint,
        target: ElementTarget(point: FallbackPoint(x: -4, y: 20)),
        purpose: 'tap_point_outside',
        risk: 1,
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    final result = await _pumpUntilComplete(tester, action);

    expect(result.ok, isFalse);
    expect(result.error?.type, 'point_outside_view');
    expect(result.error?.retryable, isFalse);
    expect(result.data['operationPhase'], 'zero_dispatch');
    expect(presses, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('tap_point travels as a top-level x and y', () {
    final command = operatorActionCommandFromJson(<String, Object?>{
      'type': 'tap_point',
      'x': 12.5,
      'y': 40,
    });
    expect(command.type, OperatorActionType.tapPoint);
    expect(command.target?.point?.x, 12.5);
    expect(command.target?.point?.y, 40);

    final echoed =
        operatorActionResultToJson(ActionResult(ok: true, action: command))['action']
            as Map;
    expect(echoed['type'], 'tap_point');
    expect(echoed['x'], 12.5);
    expect(echoed['y'], 40.0);
  });
}

/// Built like a platform-adaptive row that fires its tap from finger up, with no onTap.
Widget _pressAndReleaseRow(VoidCallback onPressed) => Center(
  child: GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) {},
    onTapUp: (_) => onPressed(),
    child: const ColoredBox(
      color: Colors.white,
      child: SizedBox(
        width: 240,
        height: 56,
        child: Center(child: Text('Emmanuel')),
      ),
    ),
  ),
);

Future<OperatorApp> _host(WidgetTester tester, Widget body) async {
  late OperatorApp app;
  await tester.pumpWidget(
    OperatorAppHost(
      config: const OperatorFlutterConfig(
        appId: 'flutter-tap-point-test',
        environment: OperatorEnvironment.dev,
      ),
      onReady: (ready) => app = ready,
      child: MaterialApp(home: Scaffold(body: body)),
    ),
  );
  await tester.pump();
  return app;
}

Future<ActionResult> _pumpUntilComplete(
  WidgetTester tester,
  Future<ActionResult> action, {
  int maxPumps = 600,
}) async {
  ActionResult? result;
  Object? error;
  StackTrace? stackTrace;
  var completed = false;
  unawaited(
    action.then(
      (value) {
        result = value;
        completed = true;
      },
      onError: (Object caught, StackTrace caughtStack) {
        error = caught;
        stackTrace = caughtStack;
        completed = true;
      },
    ),
  );
  for (var i = 0; i < maxPumps && !completed; i += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (error != null) Error.throwWithStackTrace(error!, stackTrace!);
  expect(completed, isTrue, reason: 'the action did not complete');
  return result!;
}
