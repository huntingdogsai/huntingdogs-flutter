import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

/// Presses in a row: a tap, click or tap_point with count presses that many
/// times, as fast fingers do, and a tap that presses once refuses more presses
/// before anything is pressed.
void main() {
  test('count and intervalMs travel with tap, click and tap_point', () {
    for (final type in <String>['tap', 'click', 'tap_point']) {
      final command = operatorActionCommandFromJson(<String, Object?>{
        'type': type,
        if (type == 'tap_point') ...<String, Object?>{'x': 10, 'y': 20},
        if (type != 'tap_point') 'target': <String, Object?>{'id': 'send'},
        'count': 2,
        'intervalMs': 0,
      });
      expect(command.count, 2, reason: type);
      expect(command.interval, Duration.zero, reason: type);
      final echoed =
          operatorActionResultToJson(
                ActionResult(ok: true, action: command),
              )['action']
              as Map;
      expect(echoed['count'], 2, reason: type);
      expect(echoed['intervalMs'], 0, reason: type);
    }
    final plain = operatorActionCommandFromJson(<String, Object?>{
      'type': 'tap',
      'target': <String, Object?>{'id': 'send'},
    });
    expect(plain.count, isNull);
    expect(plain.interval, isNull);
    final echoedPlain =
        operatorActionResultToJson(
              ActionResult(ok: true, action: plain),
            )['action']
            as Map;
    expect(echoedPlain.containsKey('count'), isFalse);
    expect(echoedPlain.containsKey('intervalMs'), isFalse);
    expect(
      operatorActionCommandFromJson(<String, Object?>{
        'type': 'tap',
        'target': <String, Object?>{'id': 'send'},
        'count': 10,
        'intervalMs': 1000,
      }).count,
      10,
      reason: 'ten presses a second apart is the most',
    );
  });

  test('presses out of range are refused before they reach the app', () {
    final cases = <String, Map<String, Object?>>{
      'no presses': <String, Object?>{'count': 0},
      'eleven presses': <String, Object?>{'count': 11},
      'part of a press': <String, Object?>{'count': 1.5},
      'a count in words': <String, Object?>{'count': 'two'},
      'a negative wait': <String, Object?>{'count': 2, 'intervalMs': -1},
      'a wait over a second': <String, Object?>{'count': 2, 'intervalMs': 1001},
      'part of a millisecond': <String, Object?>{'count': 2, 'intervalMs': 0.5},
    };
    for (final entry in cases.entries) {
      expect(
        () => operatorActionCommandFromJson(<String, Object?>{
          'type': 'tap',
          'target': <String, Object?>{'id': 'send'},
          ...entry.value,
        }),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });

  testWidgets('the SDK says it presses several times in a row', (tester) async {
    final app = await _host(tester, const Center(child: Text('Ready')));
    final snapshot = await app.operator.getSnapshot(
      refreshVisual: false,
      refreshStorageProviders: false,
    );
    expect(snapshot.capabilities.actions['repeatedPress'], isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an exact control is pressed twice in a row, 40 ms apart by default',
    (tester) async {
      final pressedAt = <Duration>[];
      final app = await _host(
        tester,
        Center(
          child: ElevatedButton(
            key: const ValueKey<String>('send-target'),
            onPressed:
                () => pressedAt.add(
                  tester.binding.clock.now().difference(_epoch),
                ),
            child: const Text('Send'),
          ),
        ),
      );
      final target = await _runtimeTarget(app, 'send-target');

      final result = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          ActionCommand(
            type: OperatorActionType.tap,
            target: target,
            count: 2,
            purpose: 'double_tap_send',
            risk: 1,
          ),
        ),
      );

      expect(result.ok, isTrue, reason: result.error?.message);
      expect(
        pressedAt,
        hasLength(2),
        reason: 'both presses reached the button',
      );
      expect(
        pressedAt[1] - pressedAt[0],
        greaterThanOrEqualTo(const Duration(milliseconds: 40)),
      );
      expect(result.data['presses'], <String, Object?>{
        'count': 2,
        'intervalMs': 40,
      });
      expect(
        result.message,
        'Delivered pointer taps to exact Flutter target ${target.id} '
        '2 times in a row, with a 40 ms wait between presses',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('one press stays one press and reports no presses in a row', (
    tester,
  ) async {
    var presses = 0;
    final app = await _host(
      tester,
      Center(
        child: ElevatedButton(
          key: const ValueKey<String>('once-target'),
          onPressed: () => presses += 1,
          child: const Text('Once'),
        ),
      ),
    );
    final target = await _runtimeTarget(app, 'once-target');
    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.click,
          target: target,
          count: 1,
          purpose: 'single_press',
          risk: 1,
        ),
      ),
    );
    expect(result.ok, isTrue, reason: result.error?.message);
    expect(presses, 1);
    expect(result.data.containsKey('presses'), isFalse);
    expect(
      result.message,
      'Delivered one pointer tap to exact Flutter target ${target.id}',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a double tap at a point counts as a double tap in Flutter', (
    tester,
  ) async {
    var doubleTaps = 0;
    final app = await _host(
      tester,
      Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () => doubleTaps += 1,
          child: const SizedBox(
            width: 200,
            height: 80,
            child: Center(child: Text('Like')),
          ),
        ),
      ),
    );
    final centre = tester.getCenter(find.text('Like'));

    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tapPoint,
          target: ElementTarget(
            point: FallbackPoint(x: centre.dx, y: centre.dy),
          ),
          count: 2,
          purpose: 'double_tap_like',
          risk: 1,
        ),
      ),
    );

    expect(result.ok, isTrue, reason: result.error?.message);
    expect(
      doubleTaps,
      1,
      reason: 'the default wait is long enough for a double tap',
    );
    expect(result.data['presses'], <String, Object?>{
      'count': 2,
      'intervalMs': 40,
    });
    expect(
      result.message,
      contains('on "Like" 2 times in a row, with a 40 ms wait between presses'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tap_point presses three times as fast as asked', (tester) async {
    var presses = 0;
    final app = await _host(
      tester,
      Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (_) => presses += 1,
          child: const SizedBox(width: 200, height: 80),
        ),
      ),
    );

    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tapPoint,
          target: ElementTarget(point: FallbackPoint(x: 400, y: 300)),
          count: 3,
          interval: Duration.zero,
          purpose: 'triple_tap',
          risk: 1,
        ),
      ),
    );

    expect(result.ok, isTrue, reason: result.error?.message);
    expect(presses, 3);
    expect(result.data['presses'], <String, Object?>{
      'count': 3,
      'intervalMs': 0,
    });
    expect(
      result.message,
      contains('3 times in a row, with a 0 ms wait between presses'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a tap found by its words presses once, so more presses are refused',
    (tester) async {
      var presses = 0;
      final app = await _host(
        tester,
        Center(
          child: ElevatedButton(
            onPressed: () => presses += 1,
            child: const Text('Send'),
          ),
        ),
      );

      final result = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          const ActionCommand(
            type: OperatorActionType.tap,
            target: ElementTarget(label: 'Send'),
            count: 2,
            purpose: 'double_tap_by_words',
            risk: 1,
          ),
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.type, 'repeated_press_unsupported');
      expect(result.error?.retryable, isFalse);
      expect(result.data['operationPhase'], 'zero_dispatch');
      expect(presses, 0, reason: 'nothing was pressed');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'a registered action runs once per action, so more presses are refused',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-repeated-press-registry',
          environment: OperatorEnvironment.dev,
        ),
      );
      final registry = OperatorActionRegistry();
      var invoked = 0;
      registry.registerAction(id: 'send', handler: () => invoked += 1);

      final refused = await registry.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(id: 'send'),
          count: 2,
        ),
        operator,
      );
      expect(refused?.ok, isFalse);
      expect(refused?.error?.type, 'repeated_press_unsupported');
      expect(refused?.data['operationPhase'], 'zero_dispatch');
      expect(invoked, 0);

      final once = await registry.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(id: 'send'),
        ),
        operator,
      );
      expect(once?.ok, isTrue);
      expect(invoked, 1);
    },
  );
}

final _epoch = DateTime.utc(2000);

Future<ElementTarget> _runtimeTarget(OperatorApp app, String key) async {
  final snapshot = await app.operator.getSnapshot(
    refreshVisual: false,
    refreshStorageProviders: false,
  );
  final element = snapshot.ui.elements.singleWhere(
    (element) =>
        element.data['source'] == 'flutter_runtime' &&
        element.data['debugKey'].toString().contains(key),
  );
  return ElementTarget(
    id: element.id,
    observationTargetRef: element.observationTargetRef,
  );
}

Future<OperatorApp> _host(WidgetTester tester, Widget body) async {
  late OperatorApp app;
  await tester.pumpWidget(
    OperatorAppHost(
      config: const OperatorFlutterConfig(
        appId: 'flutter-repeated-press-test',
        environment: OperatorEnvironment.dev,
      ),
      onReady: (ready) => app = ready,
      child: MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: body),
      ),
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
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (error != null) Error.throwWithStackTrace(error!, stackTrace!);
  expect(completed, isTrue, reason: 'the action did not complete');
  return result!;
}
