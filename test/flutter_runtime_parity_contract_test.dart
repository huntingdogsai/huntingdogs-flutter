import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

Future<T> _pumpUntilComplete<T>(
  WidgetTester tester,
  Future<T> future, {
  int maxPumps = 80,
  Duration step = const Duration(milliseconds: 50),
}) async {
  var completed = false;
  future.then<void>(
    (_) => completed = true,
    onError: (Object _, StackTrace __) => completed = true,
  );
  for (var attempt = 0; attempt < maxPumps && !completed; attempt += 1) {
    await tester.pump(step);
  }
  if (!completed) {
    throw TestFailure('Flutter action did not complete after $maxPumps pumps');
  }
  return future;
}

void main() {
  test('delivery identity survives Flutter action wire encoding', () {
    const action = ActionCommand(
      type: OperatorActionType.tap,
      target: ElementTarget(id: 'continue'),
      deliveryId: 'delivery-continue-1',
      purpose: 'continue_once',
      risk: 1,
    );
    final encoded = operatorActionResultToJson(
      const ActionResult(ok: true, action: action),
    );
    final encodedAction = encoded['action'] as JsonMap;
    expect(encodedAction['deliveryId'], 'delivery-continue-1');
    expect(
      operatorActionCommandFromJson(encodedAction).deliveryId,
      'delivery-continue-1',
    );
  });

  test('elapsed wait survives Flutter action-result wire encoding', () {
    const action = ActionCommand(
      type: OperatorActionType.wait,
      until: WaitCondition(
        type: 'elapsed',
        duration: Duration(milliseconds: 250),
      ),
      timeout: Duration(milliseconds: 300),
      purpose: 'passive_watch',
      risk: 0,
    );
    final encoded = operatorActionResultToJson(
      const ActionResult(ok: true, action: action),
    );
    final encodedAction = encoded['action'] as JsonMap;
    expect(encodedAction['until'], <String, Object?>{
      'type': 'elapsed',
      'durationMs': 250,
    });
    expect(encodedAction['timeoutMs'], 300);

    final decoded = operatorActionCommandFromJson(encodedAction);
    expect(decoded.until?.type, 'elapsed');
    expect(decoded.until?.duration, const Duration(milliseconds: 250));
    expect(decoded.timeout, const Duration(milliseconds: 300));
  });

  testWidgets(
    'controller value is authoritative when Flutter Semantics is stale',
    (tester) async {
      late OperatorApp app;
      final controller = TextEditingController(text: 'first@example.test');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-runtime-controller-authority',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            home: Scaffold(
              body: Semantics(
                label: 'Email',
                value: 'stale-semantics-value',
                textField: true,
                child: ExcludeSemantics(
                  child: TextField(
                    controller: controller,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final first = await app.operator.getSnapshot(refreshVisual: false);
      final firstEmail = first.ui.elements.singleWhere(
        (element) =>
            element.role == OperatorUiRole.input &&
            element.label?.toLowerCase() == 'email',
      );

      expect(firstEmail.value, 'first@example.test');
      expect(firstEmail.data['source'], 'flutter_runtime');
      expect(firstEmail.data['valueSource'], 'text_editing_controller');

      final typeAction = app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.type,
          target: ElementTarget(
            id: firstEmail.id,
            observationTargetRef: firstEmail.observationTargetRef,
          ),
          text: 'typed@example.test',
          clearFirst: true,
          purpose: 'type_through_exact_runtime_input',
          risk: 1,
        ),
      );
      final typeResult = await _pumpUntilComplete(tester, typeAction);

      expect(typeResult.ok, isTrue, reason: typeResult.error?.message);
      expect(controller.text, 'typed@example.test');
      final typed = await app.operator.getSnapshot(refreshVisual: false);
      expect(
        typed.ui.focusedElementId,
        firstEmail.id,
        reason:
            'focused runtime controls=${typed.ui.elements.where((element) => element.data['focused'] == true).map((element) => '${element.id}:${element.data['widgetType']}:${element.label}').join(', ')}',
      );

      final typedEmail = typed.ui.elements.singleWhere(
        (element) =>
            element.role == OperatorUiRole.input &&
            element.label?.toLowerCase() == 'email',
      );
      final clearAction = app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.clear,
          target: ElementTarget(
            id: typedEmail.id,
            observationTargetRef: typedEmail.observationTargetRef,
          ),
          purpose: 'clear_through_exact_runtime_input',
          risk: 1,
        ),
      );
      final clearResult = await _pumpUntilComplete(tester, clearAction);

      expect(clearResult.ok, isTrue, reason: clearResult.error?.message);
      expect(controller.text, isEmpty);

      controller.text = 'updated@example.test';
      await tester.pump();

      final second = await app.operator.getSnapshot(refreshVisual: false);
      final secondEmail = second.ui.elements.singleWhere(
        (element) =>
            element.role == OperatorUiRole.input &&
            element.label?.toLowerCase() == 'email',
      );

      expect(secondEmail.value, 'updated@example.test');
      expect(secondEmail.value, isNot('stale-semantics-value'));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('secure controller values remain private in runtime snapshots', (
    tester,
  ) async {
    late OperatorApp app;
    final controller = TextEditingController(text: 'private-password');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-runtime-secure-controller',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (ready) => app = ready,
        child: MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final snapshot = await app.operator.getSnapshot(refreshVisual: false);
    final password = snapshot.ui.elements.singleWhere(
      (element) =>
          element.role == OperatorUiRole.input &&
          element.label == 'Password' &&
          element.data['source'] == 'flutter_runtime',
    );

    expect(password.value, '[SECURE_FIELD]');
    expect(password.data['secure'], isTrue);
    expect(controller.text, 'private-password');
    expect(snapshot.capabilities.privacy['capturesSecureFields'], isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'live controls keep stable targets while replaced controls are retired',
    (tester) async {
      late OperatorApp app;
      late StateSetter rebuild;
      var generation = 0;
      var leftPresses = 0;
      var rightPresses = 0;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-runtime-observation-identity',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            theme: ThemeData(splashFactory: NoSplash.splashFactory),
            home: Scaffold(
              body: ExcludeSemantics(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return Row(
                      children: <Widget>[
                        ElevatedButton(
                          key: ValueKey<String>('left-$generation'),
                          onPressed: () => setState(() => leftPresses += 1),
                          child: const Text('Edit'),
                        ),
                        ElevatedButton(
                          key: const ValueKey<String>('right'),
                          onPressed: () => setState(() => rightPresses += 1),
                          child: const Text('Edit'),
                        ),
                        Text('left=$leftPresses right=$rightPresses'),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final first = await app.operator.getSnapshot(refreshVisual: false);
      final firstEdits = first.ui.elements
          .where(
            (element) =>
                element.role == OperatorUiRole.button &&
                element.label == 'Edit' &&
                element.data['source'] == 'flutter_runtime',
          )
          .toList(growable: false);

      expect(firstEdits, hasLength(2));
      final firstRefs = firstEdits
          .map((element) => element.observationTargetRef)
          .whereType<FlutterObservationTargetRef>()
          .toList(growable: false);
      expect(firstRefs, hasLength(2));
      expect(
        firstRefs.map((reference) => reference.ticketId).toSet(),
        hasLength(2),
      );
      expect(
        firstRefs.every(
          (reference) => reference.snapshotId == first.snapshotId,
        ),
        isTrue,
      );

      final left = firstEdits.singleWhere(
        (element) => element.platformId.toString().contains('left-0'),
      );
      final firstRight = firstEdits.singleWhere(
        (element) => element.platformId.toString().contains('right'),
      );

      rebuild(() => generation += 1);
      await tester.pump();

      final staleResult = await app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(
            id: left.id,
            observationTargetRef: left.observationTargetRef,
          ),
          purpose: 'refuse_replaced_flutter_element',
          risk: 1,
        ),
      );
      expect(staleResult.ok, isFalse);
      expect(staleResult.error?.type, 'semantic_reobservation_required');
      expect(leftPresses, 0);

      final second = await app.operator.getSnapshot(refreshVisual: false);
      final secondEdits = second.ui.elements
          .where(
            (element) =>
                element.role == OperatorUiRole.button &&
                element.label == 'Edit' &&
                element.data['source'] == 'flutter_runtime',
          )
          .toList(growable: false);
      final secondRefs = secondEdits
          .map((element) => element.observationTargetRef)
          .whereType<FlutterObservationTargetRef>()
          .toList(growable: false);

      expect(secondRefs, hasLength(2));
      final currentLeft = secondEdits.singleWhere(
        (element) => element.platformId.toString().contains('left-1'),
      );

      final currentRight = secondEdits.singleWhere(
        (element) => element.platformId.toString().contains('right'),
      );
      expect(
        currentRight.observationTargetRef,
        firstRight.observationTargetRef,
        reason: 'the same mounted right button must keep its target',
      );
      expect(
        currentLeft.observationTargetRef?.ticketId,
        isNot(left.observationTargetRef?.ticketId),
        reason: 'the replaced keyed left button must receive a new target',
      );
      final action = ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(
          id: currentRight.id,
          observationTargetRef: currentRight.observationTargetRef,
        ),
        deliveryId: 'right-edit-delivery-1',
        purpose: 'tap_exact_duplicate_runtime_control',
        risk: 1,
      );
      final tapAction = app.binding.adapter.execute(action);
      final joinedReplay = app.binding.adapter.execute(action);
      final tapResult = await _pumpUntilComplete(tester, tapAction);
      final replayResult = await joinedReplay;

      expect(tapResult.ok, isTrue, reason: tapResult.error?.message);
      expect(replayResult.ok, isTrue, reason: replayResult.error?.message);
      expect(rightPresses, 1, reason: 'one in-flight ticket dispatches once');

      final third = await app.operator.getSnapshot(refreshVisual: false);
      final thirdRight = third.ui.elements.singleWhere(
        (element) =>
            element.data['source'] == 'flutter_runtime' &&
            element.platformId.toString().contains('right'),
      );
      expect(thirdRight.observationTargetRef, firstRight.observationTargetRef);
      final secondDelivery = app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(
            id: thirdRight.id,
            observationTargetRef: thirdRight.observationTargetRef,
          ),
          deliveryId: 'right-edit-delivery-2',
          purpose: 'tap_same_live_control_again',
          risk: 1,
        ),
      );
      final secondResult = await _pumpUntilComplete(tester, secondDelivery);
      expect(secondResult.ok, isTrue, reason: secondResult.error?.message);
      expect(rightPresses, 2, reason: 'a distinct delivery must dispatch once');

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background snapshots cannot rotate a model-facing Flutter target',
    (tester) async {
      late OperatorApp app;
      var presses = 0;
      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-runtime-background-observation',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            home: Scaffold(
              body: GestureDetector(
                key: const ValueKey<String>('stable-background-button'),
                onTap: () => presses += 1,
                child: const SizedBox(
                  width: 180,
                  height: 56,
                  child: Center(child: Text('Continue')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final modelSnapshot = await app.operator.getSnapshot(
        refreshVisual: false,
      );
      final target = modelSnapshot.ui.elements.singleWhere(
        (element) =>
            element.data['source'] == 'flutter_runtime' &&
            element.platformId.toString().contains('stable-background-button'),
      );
      final backgroundSnapshot = app.operator.snapshots.first;
      app.operator.captureStateChange(
        source: OperatorStateSource.changeNotifier,
        name: 'UnrelatedState',
        value: <String, Object?>{'revision': 1},
      );
      final emitted = await backgroundSnapshot;
      expect(
        emitted.ui.elements.any(
          (element) => element.observationTargetRef != null,
        ),
        isFalse,
        reason: 'background evidence must not issue action targets',
      );

      final result = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          ActionCommand(
            type: OperatorActionType.tap,
            target: ElementTarget(
              id: target.id,
              observationTargetRef: target.observationTargetRef,
            ),
            deliveryId: 'background-preserved-delivery',
            purpose: 'use_target_after_background_observation',
            risk: 1,
          ),
        ),
      );
      expect(result.ok, isTrue, reason: result.error?.message);
      expect(presses, 1);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'exact Flutter tap proves mechanical delivery without requiring an app effect',
    (tester) async {
      late OperatorApp app;
      var deliveredTaps = 0;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-runtime-mechanical-tap',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            theme: ThemeData(splashFactory: NoSplash.splashFactory),
            home: Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const ValueKey<String>('mechanical-target'),
                  onPressed: () => deliveredTaps += 1,
                  child: const Text('No visible change'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final snapshot = await app.operator.getSnapshot(refreshVisual: false);
      final target = snapshot.ui.elements.singleWhere(
        (element) =>
            element.data['source'] == 'flutter_runtime' &&
            element.data['debugKey'].toString().contains('mechanical-target'),
      );
      final command = ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(
          id: target.id,
          observationTargetRef: target.observationTargetRef,
        ),
        purpose: 'prove_mechanical_delivery_only',
        risk: 1,
      );
      final firstFuture = app.binding.adapter.execute(command);
      final replayFuture = app.binding.adapter.execute(command);
      final first = await _pumpUntilComplete(tester, firstFuture);
      final replay = await replayFuture;

      expect(first.ok, isTrue, reason: first.error?.message);
      expect(
        first.evidence.map((entry) => entry.condition),
        contains('tap.mechanical_delivery.acknowledged'),
      );
      expect(deliveredTaps, 1);
      expect(replay.ok, isTrue, reason: replay.error?.message);
      expect(
        deliveredTaps,
        1,
        reason: 'a delivered ticket must never tap twice',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('exact Flutter tap refuses an unrelated covering control', (
    tester,
  ) async {
    late OperatorApp app;
    var intendedTaps = 0;
    var coveringTaps = 0;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-runtime-occluded-tap',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (ready) => app = ready,
        child: MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                height: 64,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    ElevatedButton(
                      key: const ValueKey<String>('covered-target'),
                      onPressed: () => intendedTaps += 1,
                      child: const Text('Covered target'),
                    ),
                    GestureDetector(
                      key: const ValueKey<String>('covering-control'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => coveringTaps += 1,
                      child: const ColoredBox(color: Colors.transparent),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final snapshot = await app.operator.getSnapshot(refreshVisual: false);
    final target = snapshot.ui.elements.singleWhere(
      (element) =>
          element.data['source'] == 'flutter_runtime' &&
          element.data['debugKey'].toString().contains('covered-target'),
    );
    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(
            id: target.id,
            observationTargetRef: target.observationTargetRef,
          ),
          purpose: 'refuse_occluded_exact_target',
          risk: 1,
        ),
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error?.type, 'target_hit_test_mismatch');
    expect(
      result.error?.message,
      startsWith('No click was sent. At the control dispatch point '),
    );
    expect(
      result.error?.message,
      contains('the hit test did not include the intended control ${target.id}.'),
    );
    expect(
      result.error?.message,
      endsWith(
        'Consider re-examining the screenshot to see if the control is blocked.',
      ),
    );
    expect(intendedTaps, 0);
    expect(
      coveringTaps,
      0,
      reason: 'occlusion refusal must happen before input',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('nested scroll mutates only the exact runtime scroll owner', (
    tester,
  ) async {
    late OperatorApp app;
    final outer = ScrollController();
    final inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-runtime-nested-scroll-owner',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (ready) => app = ready,
        child: MaterialApp(
          home: Scaffold(
            body: ExcludeSemantics(
              child: ListView(
                key: const ValueKey<String>('outer-scroll'),
                controller: outer,
                children: <Widget>[
                  const SizedBox(height: 32),
                  SizedBox(
                    height: 240,
                    child: ListView(
                      key: const ValueKey<String>('inner-scroll'),
                      controller: inner,
                      children: <Widget>[
                        ElevatedButton(
                          onPressed: () {},
                          child: const Text('Nested action'),
                        ),
                        const SizedBox(height: 800),
                      ],
                    ),
                  ),
                  const SizedBox(height: 800),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final snapshot = await app.operator.getSnapshot(refreshVisual: false);
    final nestedAction = snapshot.ui.elements.singleWhere(
      (element) =>
          element.role == OperatorUiRole.button &&
          element.label == 'Nested action' &&
          element.data['source'] == 'flutter_runtime',
    );
    final innerOwner = snapshot.ui.elements.singleWhere(
      (element) =>
          element.data['source'] == 'flutter_runtime' &&
          element.data['debugKey'].toString().contains('inner-scroll') &&
          element.scrollOwner != null,
    );

    expect(nestedAction.bounds, isNotNull);
    expect(innerOwner.scrollOwner?.kind, 'element');
    expect(innerOwner.scrollOwner?.axes, contains('y'));
    expect(innerOwner.scrollOwner?.offsetY, 0);
    expect(innerOwner.scrollOwner?.canScrollDown, isTrue);

    final action = app.binding.adapter.execute(
      ActionCommand(
        type: OperatorActionType.scroll,
        container: ElementTarget(
          id: innerOwner.id,
          observationTargetRef: innerOwner.observationTargetRef,
        ),
        direction: 'down',
        amount: 'small',
        purpose: 'scroll_exact_nested_owner',
        risk: 1,
      ),
    );
    final result = await _pumpUntilComplete(tester, action);

    expect(result.ok, isTrue, reason: result.error?.message);
    expect(inner.offset, greaterThan(0));
    expect(outer.offset, 0);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scroll into view follows the exact mounted target owner chain', (
    tester,
  ) async {
    late OperatorApp app;
    final outer = ScrollController();
    final inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-runtime-scroll-into-view',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (ready) => app = ready,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 320,
              child: SingleChildScrollView(
                key: const ValueKey<String>('outer-reveal-owner'),
                controller: outer,
                child: Column(
                  children: <Widget>[
                    const SizedBox(height: 460),
                    SizedBox(
                      height: 220,
                      child: SingleChildScrollView(
                        key: const ValueKey<String>('inner-reveal-owner'),
                        controller: inner,
                        child: Column(
                          children: <Widget>[
                            const SizedBox(height: 420),
                            ElevatedButton(
                              key: const ValueKey<String>('deep-action'),
                              onPressed: () {},
                              child: const Text('Deep action'),
                            ),
                            const SizedBox(height: 120),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 240),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = await app.operator.getSnapshot(refreshVisual: false);
    final deepAction = before.ui.elements.singleWhere(
      (element) =>
          element.role == OperatorUiRole.button &&
          element.label == 'Deep action' &&
          element.data['source'] == 'flutter_runtime',
    );

    expect(deepAction.rendered, isTrue);
    expect(deepAction.inViewport, isFalse);
    expect(deepAction.visible, isFalse);
    expect(deepAction.actions, contains('scrollIntoView'));
    expect(deepAction.observationTargetRef, isNotNull);

    final action = app.binding.adapter.execute(
      ActionCommand(
        type: OperatorActionType.scrollIntoView,
        target: ElementTarget(
          id: deepAction.id,
          observationTargetRef: deepAction.observationTargetRef,
        ),
        alignment: 'nearest',
        purpose: 'reveal_exact_nested_flutter_target',
        risk: 1,
      ),
    );
    final result = await _pumpUntilComplete(tester, action);

    expect(result.ok, isTrue, reason: result.error?.message);
    expect(outer.offset, greaterThan(0));
    expect(inner.offset, greaterThan(0));
    final after = await app.operator.getSnapshot(refreshVisual: false);
    final revealed = after.ui.elements.singleWhere(
      (element) => element.id == deepAction.id,
    );
    expect(revealed.inViewport, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'hover drag and touch use exact mounted Flutter runtime targets',
    (tester) async {
      late OperatorApp app;
      var hoverCount = 0;
      var dragUpdates = 0;
      var touchTaps = 0;
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-runtime-pointer-parity',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  MouseRegion(
                    key: const ValueKey<String>('hover-target'),
                    onEnter: (_) => hoverCount += 1,
                    child: SizedBox(
                      width: 160,
                      height: 48,
                      child: ElevatedButton(
                        key: const ValueKey<String>('overlapping-real-button'),
                        onPressed: () {},
                        child: const Text('Hover target'),
                      ),
                    ),
                  ),
                  Row(
                    children: <Widget>[
                      GestureDetector(
                        key: const ValueKey<String>('drag-source'),
                        onPanUpdate: (_) => dragUpdates += 1,
                        child: const SizedBox(
                          width: 120,
                          height: 48,
                          child: Text('Drag source'),
                        ),
                      ),
                      MouseRegion(
                        key: const ValueKey<String>('drag-destination'),
                        onHover: (_) {},
                        child: const SizedBox(
                          width: 120,
                          height: 48,
                          child: Text('Drag destination'),
                        ),
                      ),
                    ],
                  ),
                  GestureDetector(
                    key: const ValueKey<String>('touch-target'),
                    onTap: () => touchTaps += 1,
                    child: const SizedBox(
                      width: 160,
                      height: 48,
                      child: Text('Touch target'),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      key: const ValueKey<String>('touch-scroll-owner'),
                      controller: scroll,
                      children: const <Widget>[SizedBox(height: 900)],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<ActionResult> execute(ActionCommand command) async {
        final future = app.binding.adapter.execute(command);
        return _pumpUntilComplete(
          tester,
          future,
          step: const Duration(milliseconds: 40),
        );
      }

      UiElement control(AppSnapshot snapshot, String key) =>
          snapshot.ui.elements.singleWhere(
            (element) =>
                element.data['source'] == 'flutter_runtime' &&
                element.data['debugKey'].toString().contains(key),
          );
      ElementTarget target(UiElement element) => ElementTarget(
        id: element.id,
        observationTargetRef: element.observationTargetRef,
      );

      var snapshot = await app.operator.getSnapshot(refreshVisual: false);
      final hover = control(snapshot, 'hover-target');
      expect(hover.actions, contains('hover'));
      expect(hover.actions, isNot(contains('tap')));
      expect(hover.actions, isNot(contains('drag')));
      expect(hover.actions, isNot(contains('touch')));
      final overlappingButton = control(snapshot, 'overlapping-real-button');
      expect(overlappingButton.bounds?.x, hover.bounds?.x);
      expect(overlappingButton.bounds?.y, hover.bounds?.y);
      expect(overlappingButton.bounds?.width, hover.bounds?.width);
      expect(overlappingButton.bounds?.height, hover.bounds?.height);
      expect(overlappingButton.actions, containsAll(<String>['tap', 'touch']));
      expect(overlappingButton.actions, isNot(contains('hover')));
      expect(overlappingButton.actions, isNot(contains('drag')));
      final hoverResult = await execute(
        ActionCommand(
          type: OperatorActionType.hover,
          target: target(hover),
          purpose: 'hover_exact_flutter_target',
          risk: 0,
        ),
      );
      expect(hoverResult.ok, isTrue, reason: hoverResult.error?.message);
      expect(hoverCount, 1);

      snapshot = await app.operator.getSnapshot(refreshVisual: false);
      final source = control(snapshot, 'drag-source');
      final destination = control(snapshot, 'drag-destination');
      expect(source.actions, contains('drag'));
      expect(source.actions, contains('touch'));
      expect(source.actions, isNot(contains('tap')));
      expect(source.actions, isNot(contains('hover')));
      expect(destination.actions, contains('hover'));
      expect(destination.actions, isNot(contains('tap')));
      expect(destination.actions, isNot(contains('drag')));
      expect(destination.actions, isNot(contains('touch')));
      final dragResult = await execute(
        ActionCommand(
          type: OperatorActionType.drag,
          source: target(source),
          destination: target(destination),
          mode: 'pointer',
          purpose: 'drag_between_exact_flutter_targets',
          risk: 1,
        ),
      );
      expect(dragResult.ok, isTrue, reason: dragResult.error?.message);
      expect(dragUpdates, greaterThan(0));

      snapshot = await app.operator.getSnapshot(refreshVisual: false);
      final touch = control(snapshot, 'touch-target');
      expect(touch.actions, containsAll(<String>['tap', 'touch']));
      expect(touch.actions, isNot(contains('hover')));
      expect(touch.actions, isNot(contains('drag')));
      final touchResult = await execute(
        ActionCommand(
          type: OperatorActionType.touch,
          gesture: 'tap',
          target: target(touch),
          purpose: 'touch_exact_flutter_target',
          risk: 1,
        ),
      );
      expect(touchResult.ok, isTrue, reason: touchResult.error?.message);
      expect(touchTaps, 1);

      snapshot = await app.operator.getSnapshot(refreshVisual: false);
      final scrollOwner = control(snapshot, 'touch-scroll-owner');
      expect(scrollOwner.actions, containsAll(<String>['scroll', 'touch']));
      expect(scrollOwner.actions, isNot(contains('tap')));
      expect(scrollOwner.actions, isNot(contains('hover')));
      expect(scrollOwner.actions, isNot(contains('drag')));
      final swipeResult = await execute(
        ActionCommand(
          type: OperatorActionType.touch,
          gesture: 'swipe',
          start: target(scrollOwner),
          direction: 'up',
          distancePx: 180,
          duration: const Duration(milliseconds: 240),
          purpose: 'swipe_exact_flutter_scroll_owner',
          risk: 1,
        ),
      );
      expect(swipeResult.ok, isTrue, reason: swipeResult.error?.message);
      expect(scroll.offset, greaterThan(0));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
