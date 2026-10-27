import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

/// scroll_to: find a control by visible text inside one scroll container,
/// stepping the container until the control is built, then reveal it.
void main() {
  testWidgets(
    'scroll_to steps a lazily built list until the row exists, then reveals it',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final app = await _host(tester, _lazyRows(controller));
      expect(
        find.text('Row 150'),
        findsNothing,
        reason: 'the row is not built until the list is scrolled near it',
      );

      final action = app.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.scrollTo,
          text: 'row 150',
          purpose: 'scroll_to_row',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final result = await _pumpUntilComplete(tester, action);

      expect(result.ok, isTrue, reason: result.error?.message);
      final facts = _scrollTo(result);
      expect(facts['found'], isTrue);
      expect(facts['revealed'], isTrue);
      expect(facts['reachedEnd'], isFalse);
      expect(facts['steps'], greaterThan(0));
      final control = facts['control'] as Map;
      expect(control['label'], 'Row 150');
      expect(control['role'], 'text');
      expect(control['inViewport'], isTrue);
      expect(controller.offset, greaterThan(0));
      expect(find.text('Row 150'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scroll_to reports the end honestly when the text never appears',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final app = await _host(tester, _lazyRows(controller));

      final action = app.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.scrollTo,
          text: 'Row 999',
          maxSteps: 50,
          purpose: 'scroll_to_missing_row',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final result = await _pumpUntilComplete(tester, action);

      expect(result.ok, isFalse);
      expect(result.error?.type, 'scroll_to_not_found');
      expect(result.error?.retryable, isFalse);
      final facts = _scrollTo(result);
      expect(facts['found'], isFalse);
      expect(facts['reachedEnd'], isTrue);
      expect(facts['steps'], greaterThan(10));
      expect(controller.offset, controller.position.maxScrollExtent);
      expect(
        result.error?.message,
        contains('unlabelled scrollable ${facts['ownerId']} at'),
        reason: 'the answer names the list it searched',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scroll_to scrolls nothing and names the lists when a pop-up list sits over a scrollable page',
    (tester) async {
      final page = ScrollController();
      final popup = ScrollController();
      addTearDown(page.dispose);
      addTearDown(popup.dispose);
      final app = await _host(
        tester,
        Stack(
          children: <Widget>[
            _lazyRows(
              page,
              count: 60,
              builder: (index) => Text('Page row $index'),
            ),
            Positioned(
              top: 100,
              left: 20,
              width: 300,
              height: 150,
              child: Material(
                elevation: 4,
                child: ListView.builder(
                  controller: popup,
                  itemCount: 25,
                  itemBuilder:
                      (_, index) => SizedBox(
                        height: 48,
                        child: Text(
                          index == 20 ? 'Target entry' : 'Profile $index',
                        ),
                      ),
                ),
              ),
            ),
          ],
        ),
      );

      final guessed = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          const ActionCommand(
            type: OperatorActionType.scrollTo,
            text: 'Target entry',
            purpose: 'scroll_to_without_container',
            risk: 1,
          ),
        ),
      );
      expect(guessed.ok, isFalse);
      expect(guessed.error?.type, 'scroll_container_required');
      expect(guessed.data['operationPhase'], 'zero_dispatch');
      final containers = (_scrollTo(guessed)['containers'] as List).cast<Map>();
      expect(containers, hasLength(2));
      expect(
        page.offset,
        0,
        reason: 'the page behind the pop-up is not scrolled',
      );
      expect(popup.offset, 0, reason: 'no list is guessed at');
      for (final container in containers) {
        expect(guessed.error?.message, contains('${container['id']}'));
      }

      final popupContainer = containers.singleWhere(
        (container) => ((container['bounds'] as Map)['height'] as num) < 200,
      );
      final named = app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.scrollTo,
          text: 'Target entry',
          container: ElementTarget(id: popupContainer['id'] as String),
          purpose: 'scroll_to_in_popup',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final found = await _pumpUntilComplete(tester, named);
      expect(found.ok, isTrue, reason: found.error?.message);
      expect((_scrollTo(found)['control'] as Map)['label'], 'Target entry');
      expect(popup.offset, greaterThan(0));
      expect(page.offset, 0, reason: 'only the named list moved');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scroll_to does not count a text field as a scroll container',
    (tester) async {
      final list = ScrollController();
      addTearDown(list.dispose);
      final app = await _host(
        tester,
        Column(
          children: <Widget>[
            Expanded(child: _lazyRows(list)),
            const TextField(minLines: 3, maxLines: 3),
            const TextField(),
          ],
        ),
      );

      final action = app.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.scrollTo,
          text: 'Row 120',
          purpose: 'scroll_to_beside_text_fields',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final result = await _pumpUntilComplete(tester, action);

      expect(result.ok, isTrue, reason: result.error?.message);
      expect((_scrollTo(result)['control'] as Map)['label'], 'Row 120');
      expect(list.offset, greaterThan(0));

      final sideways = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          const ActionCommand(
            type: OperatorActionType.scrollTo,
            text: 'Row 1',
            direction: 'right',
            purpose: 'scroll_to_sideways_without_container',
            risk: 1,
          ),
        ),
      );
      expect(
        sideways.error?.type,
        'scroll_owner_unavailable',
        reason: 'single-line text fields scroll sideways, but they are not lists',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scroll_to names both lists when a searchable field\'s options list is open, and searches the one named',
    (tester) async {
      final page = ScrollController();
      addTearDown(page.dispose);
      final app = await _host(tester, _searchableField(page));
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await app.operator.getSnapshot(
        refreshVisual: false,
        refreshStorageProviders: false,
      );

      final unnamed = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          const ActionCommand(
            type: OperatorActionType.scrollTo,
            text: 'Target entry',
            purpose: 'scroll_to_without_container',
            risk: 1,
          ),
        ),
      );
      expect(unnamed.error?.type, 'scroll_container_required');
      final containers = (_scrollTo(unnamed)['containers'] as List).cast<Map>();
      expect(containers, hasLength(2));
      for (final container in containers) {
        expect(
          container['observationTargetRef'],
          isNotNull,
          reason: 'each list carries the ticket the host turns into its target',
        );
      }
      final options = containers.singleWhere(
        (container) => ((container['bounds'] as Map)['height'] as num) < 200,
      );

      final named = app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.scrollTo,
          text: 'Target entry',
          container: ElementTarget(id: options['id'] as String),
          purpose: 'scroll_to_in_options',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final found = await _pumpUntilComplete(tester, named);
      expect(found.ok, isTrue, reason: found.error?.message);
      expect((_scrollTo(found)['control'] as Map)['label'], 'Target entry');
      expect(page.offset, 0, reason: 'only the options list moved');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('scroll_to stops at the step limit without claiming the end', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final app = await _host(tester, _lazyRows(controller));

    final action = app.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.scrollTo,
        text: 'Row 199',
        maxSteps: 2,
        purpose: 'scroll_to_limited',
        risk: 1,
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    final result = await _pumpUntilComplete(tester, action);

    expect(result.ok, isFalse);
    expect(result.error?.type, 'scroll_to_not_found');
    expect(result.error?.retryable, isTrue);
    final facts = _scrollTo(result);
    expect(facts['steps'], 2);
    expect(facts['reachedEnd'], isFalse);
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(controller.position.maxScrollExtent));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scroll_to reveals nothing when two controls match', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final app = await _host(
      tester,
      _lazyRows(
        controller,
        builder:
            (index) => index < 2 ? const Text('Duplicate') : Text('Row $index'),
      ),
    );

    final action = app.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.scrollTo,
        text: 'Duplicate',
        purpose: 'scroll_to_ambiguous',
        risk: 1,
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    final result = await _pumpUntilComplete(tester, action);

    expect(result.ok, isFalse);
    expect(result.error?.type, 'scroll_to_ambiguous');
    final facts = _scrollTo(result);
    expect(facts['found'], isFalse);
    expect(facts['ambiguous'], isTrue);
    expect(facts['matches'], hasLength(2));
    expect(controller.offset, 0, reason: 'nothing moved');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'scroll_to fails honestly when the found text cannot be brought into view',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final app = await _host(
        tester,
        ListView(
          controller: controller,
          children: <Widget>[
            for (var index = 0; index < 60; index++)
              if (index == 10)
                // The text exists and paints, but a fixed clip keeps it 3500
                // pixels below its row: no scroll can reveal it.
                const SizedBox(
                  height: 48,
                  child: ClipRect(
                    child: OverflowBox(
                      maxHeight: 4000,
                      alignment: Alignment.topCenter,
                      child: Column(
                        children: <Widget>[
                          SizedBox(height: 3500),
                          Text('Hidden target'),
                        ],
                      ),
                    ),
                  ),
                )
              else
                SizedBox(height: 48, child: Center(child: Text('Row $index'))),
          ],
        ),
      );

      final action = app.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.scrollTo,
          text: 'Hidden target',
          purpose: 'scroll_to_clipped',
          risk: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final result = await _pumpUntilComplete(tester, action);

      expect(result.ok, isFalse);
      expect(result.error?.type, 'action_effect_unverified');
      final facts = _scrollTo(result);
      expect(facts['found'], isTrue);
      expect(facts['revealed'], isFalse);
      expect((facts['control'] as Map)['inViewport'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('scroll_to honours the role filter and refuses invalid input', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final app = await _host(
      tester,
      _lazyRows(
        controller,
        builder:
            (index) =>
                index == 150
                    ? ElevatedButton(
                      onPressed: () {},
                      child: const Text('Row 150'),
                    )
                    : Text('Row $index'),
      ),
    );

    final action = app.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.scrollTo,
        text: 'Row 150',
        role: 'button',
        purpose: 'scroll_to_button',
        risk: 1,
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    final result = await _pumpUntilComplete(tester, action);
    expect(result.ok, isTrue, reason: result.error?.message);
    final control = _scrollTo(result)['control'] as Map;
    expect(control['role'], 'button');
    expect(control['label'], 'Row 150');
    expect(control['id'], isNotNull);

    for (final invalid in <ActionCommand>[
      const ActionCommand(
        type: OperatorActionType.scrollTo,
        text: '   ',
        purpose: 'scroll_to_blank',
        risk: 1,
      ),
      const ActionCommand(
        type: OperatorActionType.scrollTo,
        text: 'Row 1',
        role: 'widget',
        purpose: 'scroll_to_bad_role',
        risk: 1,
      ),
      const ActionCommand(
        type: OperatorActionType.scrollTo,
        text: 'Row 1',
        maxSteps: 0,
        purpose: 'scroll_to_bad_steps',
        risk: 1,
      ),
      const ActionCommand(
        type: OperatorActionType.scrollTo,
        text: 'Row 1',
        direction: 'sideways',
        purpose: 'scroll_to_bad_direction',
        risk: 1,
      ),
    ]) {
      final offset = controller.offset;
      final refused = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(invalid),
      );
      expect(refused.ok, isFalse, reason: invalid.purpose);
      expect(
        refused.data['operationPhase'],
        'zero_dispatch',
        reason: invalid.purpose,
      );
      expect(controller.offset, offset, reason: 'invalid input never scrolls');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<OperatorApp> _host(WidgetTester tester, Widget body) async {
  late OperatorApp app;
  await tester.pumpWidget(
    OperatorAppHost(
      config: const OperatorFlutterConfig(
        appId: 'flutter-scroll-to-test',
        environment: OperatorEnvironment.dev,
      ),
      onReady: (ready) => app = ready,
      child: MaterialApp(home: Scaffold(body: body)),
    ),
  );
  await tester.pump();
  return app;
}

Widget _lazyRows(
  ScrollController controller, {
  int count = 200,
  Widget Function(int index)? builder,
}) => ListView.builder(
  controller: controller,
  itemCount: count,
  itemBuilder:
      (_, index) => SizedBox(
        height: 48,
        child: Center(child: builder?.call(index) ?? Text('Row $index')),
      ),
);

/// A page list holding a searchable field whose options open over it, as an
/// autocomplete or searchable dropdown does, with the wanted option out of view.
Widget _searchableField(ScrollController page) {
  final names = [
    for (var i = 0; i < 25; i++) i == 20 ? 'Target entry' : 'Option $i',
  ];
  return ListView(
    controller: page,
    children: <Widget>[
      const SizedBox(height: 100),
      RawAutocomplete<String>(
        optionsBuilder:
            (value) => names.where(
              (name) => name.toLowerCase().contains(value.text.toLowerCase()),
            ),
        fieldViewBuilder:
            (context, controller, focusNode, onSubmit) =>
                TextField(controller: controller, focusNode: focusNode),
        optionsViewBuilder:
            (context, onSelected, options) => Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                child: SizedBox(
                  width: 300,
                  height: 175,
                  child: ListView.builder(
                    itemCount: options.length,
                    itemBuilder: (context, index) {
                      final name = options.elementAt(index);
                      return InkWell(
                        onTap: () => onSelected(name),
                        child: SizedBox(height: 48, child: Text(name)),
                      );
                    },
                  ),
                ),
              ),
            ),
      ),
      for (var i = 0; i < 30; i++)
        SizedBox(height: 60, child: Text('Page row $i')),
    ],
  );
}

Map<String, Object?> _scrollTo(ActionResult result) =>
    (result.data['scrollTo'] as Map).cast<String, Object?>();

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
