@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

Future<T> _pumpUntilComplete<T>(
  WidgetTester tester,
  Future<T> future, {
  required String operation,
  int maxPumps = 200,
  Duration step = const Duration(milliseconds: 50),
}) async {
  var completed = false;
  future.then<void>(
    (_) => completed = true,
    onError: (Object _, StackTrace __) => completed = true,
  );
  for (var attempt = 0; attempt < maxPumps && !completed; attempt += 1) {
    await tester.pump(step);
    // JS promise callbacks run on the browser event loop, outside the widget
    // test's fake clock. Yield briefly to both schedulers before pumping the
    // next Flutter frame.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  if (!completed) {
    throw TestFailure('Flutter Web bridge $operation did not complete');
  }
  return future;
}

void main() {
  test('the public Operator Flutter package compiles for Flutter Web', () {
    const config = OperatorFlutterConfig(
      appId: 'flutter-web-entrypoint-contract',
      environment: OperatorEnvironment.dev,
    );

    expect(config.appId, 'flutter-web-entrypoint-contract');
  });

  testWidgets('OperatorAppHost installs the versioned page-local bridge', (
    tester,
  ) async {
    var presses = 0;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-web-page-bridge-contract',
          environment: OperatorEnvironment.dev,
        ),
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                TextField(
                  focusNode: focusNode,
                  decoration: const InputDecoration(labelText: 'Bridge key'),
                ),
                ElevatedButton(
                  onPressed: () => presses += 1,
                  child: const Text('Bridge action'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final bridge = globalContext.getProperty<JSObject?>(
      operatorFlutterPageBridgeGlobal.toJS,
    );
    expect(bridge, isNotNull);
    expect(
      bridge!.getProperty<JSString>('protocolVersion'.toJS).toDart,
      operatorFlutterPageBridgeProtocolVersion,
    );
    expect(
      bridge.getProperty<JSString>('uiAuthority'.toJS).toDart,
      'flutter_runtime',
    );

    final healthJson = bridge.callMethod<JSString>('getHealth'.toJS).toDart;
    final health = jsonDecode(healthJson) as Map<String, Object?>;
    expect(health['appId'], 'flutter-web-page-bridge-contract');
    expect(health['framework'], 'flutter');
    expect(
      health['methods'],
      containsAll(<String>[
        'getHealth',
        'getSnapshot',
        'getCapabilities',
        'getEvents',
        'execute',
        'prepareKeyTarget',
      ]),
    );

    final snapshotPromise = bridge.callMethod<JSPromise<JSString>>(
      'getSnapshot'.toJS,
      jsonEncode(<String, Object?>{'issueActionTargets': true}).toJS,
    );
    final snapshotJson =
        (await _pumpUntilComplete(
          tester,
          snapshotPromise.toDart,
          operation: 'getSnapshot',
        )).toDart;
    final snapshot = jsonDecode(snapshotJson) as Map<String, Object?>;
    final ui = snapshot['ui']! as Map<String, Object?>;
    final controls =
        (ui['elements']! as List<Object?>).cast<Map<String, Object?>>();
    final button = controls.singleWhere(
      (element) =>
          element['label'] == 'Bridge action' &&
          element['data'] is Map &&
          (element['data']! as Map<Object?, Object?>)['source'] ==
              'flutter_runtime',
    );
    expect(button['observationTargetRef'], isA<Map>());
    final keyTarget = controls.singleWhere(
      (element) =>
          element['label'] == 'Bridge key' &&
          element['data'] is Map &&
          (element['data']! as Map<Object?, Object?>)['source'] ==
              'flutter_runtime',
    );
    expect((keyTarget['actions']! as List<Object?>), contains('key'));

    final prepareKeyPromise = bridge.callMethod<JSPromise<JSString>>(
      'prepareKeyTarget'.toJS,
      jsonEncode(<String, Object?>{
        'action': <String, Object?>{
          'type': 'key',
          'key': 'Enter',
          'target': <String, Object?>{
            'id': keyTarget['id'],
            'observationTargetRef': keyTarget['observationTargetRef'],
          },
          'focusTarget': true,
        },
      }).toJS,
    );
    final prepareKey =
        jsonDecode(
              (await _pumpUntilComplete(
                tester,
                prepareKeyPromise.toDart,
                operation: 'prepareKeyTarget',
              )).toDart,
            )
            as Map<String, Object?>;
    expect(prepareKey['ok'], isTrue);
    expect(focusNode.hasFocus, isTrue);

    final executePromise = bridge.callMethod<JSPromise<JSString>>(
      'execute'.toJS,
      jsonEncode(<String, Object?>{
        'action': <String, Object?>{
          'type': 'tap',
          'target': <String, Object?>{
            'id': button['id'],
            'observationTargetRef': button['observationTargetRef'],
          },
          'purpose': 'prove_page_bridge_action_round_trip',
          'risk': 1,
        },
      }).toJS,
    );
    final resultJson =
        (await _pumpUntilComplete(
          tester,
          executePromise.toDart,
          operation: 'execute',
        )).toDart;
    final result = jsonDecode(resultJson) as Map<String, Object?>;
    expect(result['ok'], isTrue);
    expect(presses, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(
      globalContext.getProperty<JSAny?>(operatorFlutterPageBridgeGlobal.toJS),
      isNull,
    );
  });

  testWidgets(
    'the page bridge sends a screen and events holding a number JSON cannot carry',
    (tester) async {
      late OperatorApp app;
      final ratio = ValueNotifier<double>(double.nan);
      addTearDown(ratio.dispose);
      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-web-page-bridge-unreadable',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<double>(
                valueListenable: ratio,
                builder: (context, value, _) => const Text('Tasks done'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bridge =
          globalContext.getProperty<JSObject?>(
            operatorFlutterPageBridgeGlobal.toJS,
          )!;

      final snapshotPromise = bridge.callMethod<JSPromise<JSString>>(
        'getSnapshot'.toJS,
        jsonEncode(<String, Object?>{'issueActionTargets': false}).toJS,
      );
      final snapshot =
          jsonDecode(
                (await _pumpUntilComplete(
                  tester,
                  snapshotPromise.toDart,
                  operation: 'getSnapshot',
                )).toDart,
              )
              as Map<String, Object?>;
      expect(
        (snapshot['unreadableValues']! as Map<Object?, Object?>)['values'],
        contains(
          allOf(
            containsPair('item', 'ValueListenableBuilder<double>'),
            containsPair('value', 'NaN'),
          ),
        ),
      );

      app.binding.adapter.operator.captureLog(
        'debug',
        'unreadable',
        data: <String, Object?>{'ratio': double.nan},
      );
      // The bridge receives the app's events on the next turn.
      await tester.pump();
      final events =
          jsonDecode(
                bridge
                    .callMethod<JSString>(
                      'getEvents'.toJS,
                      jsonEncode(<String, Object?>{'afterSequence': 0}).toJS,
                    )
                    .toDart,
              )
              as Map<String, Object?>;
      final logged = (events['events']! as List<Object?>)
          .cast<Map<Object?, Object?>>()
          .map((event) => event['payload'])
          .whereType<Map<Object?, Object?>>()
          .firstWhere((payload) => payload['message'] == 'unreadable');
      expect(
        (logged['unreadableValues']! as Map<Object?, Object?>)['values'],
        contains(
          allOf(
            containsPair('path', r'$.data.ratio'),
            containsPair('value', 'NaN'),
          ),
        ),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'the page bridge sends an endless list and its scroll, whose end is infinite',
    (tester) async {
      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-web-page-bridge-endless-list',
            environment: OperatorEnvironment.dev,
          ),
          child: MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                itemBuilder:
                    (context, index) =>
                        SizedBox(height: 60, child: Text('Row $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bridge =
          globalContext.getProperty<JSObject?>(
            operatorFlutterPageBridgeGlobal.toJS,
          )!;

      final snapshotPromise = bridge.callMethod<JSPromise<JSString>>(
        'getSnapshot'.toJS,
        jsonEncode(<String, Object?>{'issueActionTargets': true}).toJS,
      );
      final snapshot =
          jsonDecode(
                (await _pumpUntilComplete(
                  tester,
                  snapshotPromise.toDart,
                  operation: 'getSnapshot',
                )).toDart,
              )
              as Map<String, Object?>;
      expect(
        (snapshot['unreadableValues']! as Map<Object?, Object?>)['values'],
        contains(
          allOf(
            containsPair('path', endsWith('.scrollOwner.maxOffset.y')),
            containsPair('value', 'Infinity'),
          ),
        ),
      );

      final center = tester.getCenter(find.byType(ListView));
      final found =
          jsonDecode(
                bridge
                    .callMethod<JSString>(
                      'inspectPoint'.toJS,
                      jsonEncode(<String, Object?>{
                        'x': center.dx,
                        'y': center.dy,
                        'scrollDirection': 'down',
                      }).toJS,
                    )
                    .toDart,
              )
              as Map<String, Object?>;
      final list = found['control']! as Map<String, Object?>;
      final executePromise = bridge.callMethod<JSPromise<JSString>>(
        'execute'.toJS,
        jsonEncode(<String, Object?>{
          'action': <String, Object?>{
            'type': 'scroll',
            'direction': 'down',
            'amount': '100',
            'container': <String, Object?>{
              'id': list['id'],
              'point': <String, Object?>{'x': center.dx, 'y': center.dy},
              'observationTargetRef': list['observationTargetRef'],
            },
            'purpose': 'prove_an_infinite_scroll_end_reaches_the_host',
            'risk': 0,
          },
        }).toJS,
      );
      final result =
          jsonDecode(
                (await _pumpUntilComplete(
                  tester,
                  executePromise.toDart,
                  operation: 'execute',
                )).toDart,
              )
              as Map<String, Object?>;
      expect(result['ok'], isTrue);
      final scroll =
          (result['data']! as Map<Object?, Object?>)['scroll']!
              as Map<Object?, Object?>;
      expect(scroll['outcome'], 'moved');
      expect(scroll['max'], isNull);
      expect(
        (result['unreadableValues']! as Map<Object?, Object?>)['values'],
        contains(
          allOf(
            containsPair('path', r'$.data.scroll.max'),
            containsPair('value', 'Infinity'),
          ),
        ),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'the page bridge sends a screen whose controls hold the app\'s own values',
    (tester) async {
      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-web-page-bridge-app-values',
            environment: OperatorEnvironment.dev,
          ),
          child: MaterialApp(
            home: Scaffold(
              body: const Column(
                children: <Widget>[
                  Radio<_TaskType>(
                    value: _TaskType.scheduled,
                    // ignore: deprecated_member_use
                    groupValue: _TaskType.closed,
                    // ignore: deprecated_member_use
                    onChanged: null,
                  ),
                  Radio<_TaskType>(
                    value: _TaskType.closed,
                    // ignore: deprecated_member_use
                    groupValue: _TaskType.closed,
                    // ignore: deprecated_member_use
                    onChanged: null,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bridge =
          globalContext.getProperty<JSObject?>(
            operatorFlutterPageBridgeGlobal.toJS,
          )!;

      // The screen arrives whole; each control's value is sent as its text.
      final snapshotPromise = bridge.callMethod<JSPromise<JSString>>(
        'getSnapshot'.toJS,
        jsonEncode(<String, Object?>{'issueActionTargets': false}).toJS,
      );
      final snapshot =
          jsonDecode(
                (await _pumpUntilComplete(
                  tester,
                  snapshotPromise.toDart,
                  operation: 'getSnapshot',
                )).toDart,
              )
              as Map<String, Object?>;
      final values =
          ((snapshot['ui']! as Map<Object?, Object?>)['elements']!
                  as List<Object?>)
              .cast<Map<Object?, Object?>>()
              .map((element) => element['value'])
              .whereType<String>();
      expect(
        values,
        containsAll(<String>['_TaskType.scheduled', '_TaskType.closed']),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

enum _TaskType { scheduled, closed }
