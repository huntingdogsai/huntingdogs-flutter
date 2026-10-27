import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

/// Runtime behaviour behind the shared bridge handlers, driven with a pumped
/// widget tree: one-use targets, point inspection, a tap on the inspected
/// control, the in-app camera, and a screen holding a value that is not a
/// number. The HTTP transport is proved in live_bridge_io_test.
void main() {
  testWidgets(
    'the shared handlers issue one-use targets, inspect points and tap them',
    (tester) async {
      late OperatorApp app;
      var presses = 0;
      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-bridge-handlers-runtime',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            // Material's ink sparkle loads a shader asset, which real async
            // (needed for the in-app screenshot) cannot decode in tests.
            theme: ThemeData(splashFactory: NoSplash.splashFactory),
            home: Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => presses++,
                  child: const Text('Bridge tap'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final handlers = OperatorFlutterBridgeHandlers(app.binding.adapter);
      addTearDown(handlers.close);

      // The capture renders an in-app screenshot, which needs real async.
      final capture = (await tester.runAsync(
        () => handlers.capture(<String, Object?>{'issueActionTargets': true}),
      ))!;
      final elements = ((capture['snapshot'] as Map)['ui'] as Map)['elements'] as List;
      final button = elements
          .cast<Map>()
          .firstWhere((element) => element['label'] == 'Bridge tap');
      expect(button['observationTargetRef'], isNotNull, reason: 'one-use target issued');

      final bounds = button['bounds'] as Map;
      final centre = <String, Object?>{
        'x': (bounds['x'] as num) + (bounds['width'] as num) / 2,
        'y': (bounds['y'] as num) + (bounds['height'] as num) / 2,
      };
      final inspected = handlers.inspectPoint(centre);
      expect(inspected['status'], 'found');
      final control = inspected['control'] as Map;
      expect(control['label'], 'Bridge tap');

      final tapped = await _pumpUntilComplete(
        tester,
        handlers.execute(<String, Object?>{
          'action': <String, Object?>{
            'type': 'tap',
            'target': <String, Object?>{
              'id': control['id'],
              'observationTargetRef': control['observationTargetRef'],
            },
            'purpose': 'tap_through_shared_contract',
            'risk': 1,
          },
        }),
      );
      expect(tapped['ok'], isTrue, reason: tapped.toString());
      expect(presses, 1);

      // The in-app camera deliberately renders nothing under the widget-test
      // binding; the route still answers with the capture targets and the
      // reason, which is what a host needs to report an unavailable frame.
      final visual = (await tester.runAsync(
        () => handlers.captureVisual(<String, Object?>{'reason': 'runtime_test'}),
      ))!;
      expect(visual['frames'], isA<List>());
      final targets = (visual['captureTargets'] as List).cast<Map>();
      expect(targets, isNotEmpty, reason: visual.toString());
      expect(targets.first['unavailableReason'], 'provider_returned_no_frame');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a live value that is not a number is sent empty and named, and the screen still arrives',
    (tester) async {
      late OperatorApp app;
      final ratio = ValueNotifier<double>(double.nan);
      addTearDown(ratio.dispose);
      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-bridge-handlers-unreadable',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            theme: ThemeData(splashFactory: NoSplash.splashFactory),
            home: Scaffold(
              body: ValueListenableBuilder<double>(
                valueListenable: ratio,
                builder: (context, value, _) => const Text('Tasks done'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final handlers = OperatorFlutterBridgeHandlers(app.binding.adapter);
      addTearDown(handlers.close);

      final capture =
          (await tester.runAsync(
            () => handlers.capture(<String, Object?>{
              'issueActionTargets': false,
            }),
          ))!;

      expect(() => jsonEncode(capture), returnsNormally);
      final snapshot = capture['snapshot'] as Map;
      final unreadable = snapshot['unreadableValues'] as Map;
      expect(
        unreadable['values'],
        contains(
          allOf(
            containsPair('item', 'ValueListenableBuilder<double>'),
            containsPair('value', 'NaN'),
          ),
        ),
      );
      expect(
        (snapshot['ui'] as Map)['visibleTexts'],
        contains('Tasks done'),
        reason: 'the rest of the screen arrives',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<T> _pumpUntilComplete<T>(
  WidgetTester tester,
  Future<T> future, {
  int maxPumps = 400,
}) async {
  T? result;
  Object? error;
  StackTrace? stackTrace;
  var completed = false;
  unawaited(
    future.then(
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
  expect(completed, isTrue, reason: 'the operation did not complete');
  return result as T;
}
