import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

/// A receipt says whether input was sent. A tap or typing the SDK refuses before any input is
/// marked zero_dispatch, so the Tester reads "nothing was sent" and can look again, instead of
/// "the tool failed, uncertain"; an action that already moved the app is never marked so.
void main() {
  testWidgets('an unknown target is refused with nothing sent', (tester) async {
    var presses = 0;
    final app = await _host(
      tester,
      Center(
        child: ElevatedButton(
          key: const ValueKey<String>('stale-target'),
          onPressed: () => presses += 1,
          child: const Text('Send'),
        ),
      ),
    );
    final target = await _runtimeTarget(app, 'stale-target');
    final unknown = ElementTarget(
      id: target.id,
      observationTargetRef: FlutterObservationTargetRef(
        version: target.observationTargetRef!.version,
        snapshotId: target.observationTargetRef!.snapshotId,
        ticketId: 'not-${target.observationTargetRef!.ticketId}',
      ),
    );

    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tap,
          target: unknown,
          purpose: 'tap_unknown_target',
          risk: 1,
        ),
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error?.type, 'semantic_reobservation_required');
    expect(result.data['operationPhase'], 'zero_dispatch');
    expect(presses, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a disabled control is refused with nothing sent', (
    tester,
  ) async {
    final app = await _host(
      tester,
      const Center(
        child: ElevatedButton(
          key: ValueKey<String>('disabled-target'),
          onPressed: null,
          child: Text('Send'),
        ),
      ),
    );
    final target = await _runtimeTarget(app, 'disabled-target');

    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tap,
          target: target,
          purpose: 'tap_disabled_target',
          risk: 1,
        ),
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error?.type, 'target_not_actionable');
    expect(result.data['operationPhase'], 'zero_dispatch');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a covered control is refused with nothing sent', (tester) async {
    var intended = 0;
    var covering = 0;
    final app = await _host(
      tester,
      Center(
        child: SizedBox(
          width: 220,
          height: 64,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: ElevatedButton(
                  key: const ValueKey<String>('covered-target'),
                  onPressed: () => intended += 1,
                  child: const Text('Covered'),
                ),
              ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => covering += 1,
                  child: const ColoredBox(color: Color(0x01000000)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final target = await _runtimeTarget(app, 'covered-target');

    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tap,
          target: target,
          purpose: 'tap_covered_target',
          risk: 1,
        ),
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error?.type, 'target_hit_test_mismatch');
    expect(result.data['operationPhase'], 'zero_dispatch');
    expect(intended, 0);
    expect(covering, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('insertion into masked text is refused with nothing typed', (
    tester,
  ) async {
    final typed = <String>[];
    final app = await _host(
      tester,
      Center(
        child: Semantics(
          label: 'Secret',
          value: '•••••',
          textField: true,
          obscured: true,
          onSetText: typed.add,
          child: const SizedBox(width: 220, height: 48),
        ),
      ),
    );

    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.type,
          target: ElementTarget(label: 'Secret'),
          text: 'x',
          clearFirst: false,
          purpose: 'insert_into_masked_text',
          risk: 1,
        ),
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error?.type, 'text_editing_value_unavailable');
    expect(result.data['operationPhase'], 'zero_dispatch');
    expect(typed, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a target that goes away as the view scrolls to it is no refusal',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var scrolled = false;
      final app = await _host(
        tester,
        SizedBox(
          height: 320,
          child: StatefulBuilder(
            builder:
                (context, setState) =>
                    NotificationListener<ScrollUpdateNotification>(
                      onNotification: (_) {
                        if (!scrolled) setState(() => scrolled = true);
                        return false;
                      },
                      child: SingleChildScrollView(
                        controller: scroll,
                        child: Column(
                          children: <Widget>[
                            const SizedBox(height: 600),
                            if (scrolled)
                              const Text('Gone')
                            else
                              ElevatedButton(
                                key: const ValueKey<String>('leaving-target'),
                                onPressed: () {},
                                child: const Text('Leaving'),
                              ),
                            const SizedBox(height: 200),
                          ],
                        ),
                      ),
                    ),
          ),
        ),
      );
      final target = await _runtimeTarget(app, 'leaving-target');

      final result = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          ActionCommand(
            type: OperatorActionType.scrollIntoView,
            target: target,
            alignment: 'start',
            purpose: 'reveal_leaving_target',
            risk: 1,
          ),
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.type, 'semantic_reobservation_required');
      expect(result.data['operationPhase'], 'dispatched_unknown_effect');
      expect(scroll.offset, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'typing into an input that is not there is refused with nothing typed',
    (tester) async {
      final app = await _host(
        tester,
        const Center(child: Text('Nothing to type into')),
      );

      final result = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          const ActionCommand(
            type: OperatorActionType.type,
            target: ElementTarget(label: 'Absent input'),
            text: 'x',
            purpose: 'type_absent_input',
            risk: 1,
          ),
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.type, 'target_not_found');
      expect(result.data['operationPhase'], 'zero_dispatch');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a key target whose field cannot take focus is refused with nothing sent',
    (tester) async {
      final app = await _host(
        tester,
        const Center(
          child: SizedBox(
            width: 260,
            child: TextField(
              key: ValueKey<String>('unfocusable-field'),
              canRequestFocus: false,
              decoration: InputDecoration(
                suffixIcon: IconButton(
                  onPressed: _noop,
                  icon: Icon(Icons.clear),
                ),
              ),
            ),
          ),
        ),
      );
      final snapshot = await app.operator.getSnapshot(
        refreshVisual: false,
        refreshStorageProviders: false,
      );
      final field = snapshot.ui.elements.singleWhere(
        (element) =>
            element.data['source'] == 'flutter_runtime' &&
            element.role == OperatorUiRole.input &&
            element.data['debugKey'].toString().contains('unfocusable-field'),
      );
      expect(field.actions, contains('key'));
      final target = ElementTarget(
        id: field.id,
        observationTargetRef: field.observationTargetRef,
      );
      final actuator =
          app.binding.adapter.actuator as OperatorFlutterHostKeyActuator;

      final result = await _pumpUntilComplete(
        tester,
        actuator.prepareHostKey(
          ActionCommand(
            type: OperatorActionType.key,
            target: target,
            key: 'Enter',
            purpose: 'key_into_unfocusable_field',
            risk: 1,
          ),
          app.operator,
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.type, 'target_not_focusable');
      expect(result.data['operationPhase'], 'zero_dispatch');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('an HTML5 drag is refused with nothing sent', (tester) async {
    final app = await _host(
      tester,
      const Center(child: Text('Nothing to drag')),
    );

    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.drag,
          mode: 'html5',
          source: ElementTarget(label: 'From'),
          destination: ElementTarget(label: 'To'),
          purpose: 'drag_html5',
          risk: 1,
        ),
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error?.type, 'unsupported_action');
    expect(result.data['operationPhase'], 'zero_dispatch');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a swipe in no known direction is refused with nothing sent', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final app = await _host(
      tester,
      ListView(
        controller: scroll,
        children: <Widget>[
          for (var row = 0; row < 40; row += 1) Text('Row $row'),
        ],
      ),
    );

    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.touch,
          gesture: 'swipe',
          direction: 'sideways',
          purpose: 'swipe_unknown_direction',
          risk: 1,
        ),
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error?.type, 'unsupported_action');
    expect(result.data['operationPhase'], 'zero_dispatch');
    expect(scroll.offset, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'scrolling into view with an unknown alignment is refused with nothing sent',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final app = await _host(
        tester,
        SizedBox(
          height: 320,
          child: SingleChildScrollView(
            controller: scroll,
            child: Column(
              children: <Widget>[
                const SizedBox(height: 600),
                ElevatedButton(
                  key: const ValueKey<String>('aligned-target'),
                  onPressed: () {},
                  child: const Text('Aligned'),
                ),
                const SizedBox(height: 200),
              ],
            ),
          ),
        ),
      );
      final target = await _runtimeTarget(app, 'aligned-target');

      final result = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          ActionCommand(
            type: OperatorActionType.scrollIntoView,
            target: target,
            alignment: 'middle',
            purpose: 'reveal_with_unknown_alignment',
            risk: 1,
          ),
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.type, 'unsupported_action');
      expect(result.data['operationPhase'], 'zero_dispatch');
      expect(scroll.offset, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

void _noop() {}

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
        appId: 'flutter-operation-phase-test',
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
