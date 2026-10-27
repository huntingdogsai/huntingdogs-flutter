import 'dart:async';

import 'package:flutter/foundation.dart' show DiagnosticsProperty;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

/// Reading the screen, and scrolling to a control, must not change the app beyond the scroll. After
/// each one no app element may depend on anything new, and a later push/pop must leave the list's
/// ScrollPosition, and a listener the app put on it, as an unobserved app has them. 'none' is the
/// control run: the same app, never read.
void main() {
  for (final read in [
    'none',
    'observation',
    'point read',
    'scroll_to',
    'scroll_to an already built row',
    'scroll_to inside a nested list',
    'scroll_to refusal',
    'scroll_into_view',
  ]) {
    testWidgets('$read leaves the app unchanged', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final app = await _host(
        tester,
        navigator,
        _page(
          controller,
          twoLists: read == 'scroll_to refusal',
          nested: read == 'scroll_to inside a nested list',
        ),
      );
      controller.jumpTo(300);
      await tester.pump();
      final position = controller.position;
      var scrollingNotified = 0;
      position.isScrollingNotifier.addListener(() => scrollingNotified++);
      final appRoot = tester.element(find.byType(MaterialApp));
      // Reads that act on a control need its current target: that observation is not measured.
      AppSnapshot? observed;
      if (read == 'point read' || read == 'scroll_into_view') {
        observed = await app.operator.getSnapshot(
          refreshVisual: false,
          refreshStorageProviders: false,
        );
      }
      final before = _dependencies(appRoot);
      expect(
        before.values.any((dependencies) => dependencies.isNotEmpty),
        isTrue,
        reason: 'the framework diagnostics no longer report dependencies',
      );

      switch (read) {
        case 'observation':
          await app.operator.getSnapshot(
            refreshVisual: false,
            refreshStorageProviders: false,
          );
        case 'point read':
          final inspector =
              app.binding.adapter.actuator as OperatorFlutterPointInspector;
          final point = tester.getCenter(find.text('Row 8'));
          expect(inspector.inspectPoint(point.dx, point.dy)['status'], 'found');
        case 'scroll_to':
        case 'scroll_to an already built row':
        case 'scroll_to inside a nested list':
        case 'scroll_to refusal':
          final nested = read == 'scroll_to inside a nested list';
          final result = await _pumpUntilComplete(
            tester,
            app.binding.adapter.execute(
              ActionCommand(
                type: OperatorActionType.scrollTo,
                text:
                    nested
                        ? 'Card 8'
                        : read == 'scroll_to' || read == 'scroll_to refusal'
                        ? 'Row 60'
                        : 'Row 8',
                direction: nested ? 'right' : null,
                purpose: 'scroll_to_row',
                risk: 1,
              ),
            ),
          );
          if (read == 'scroll_to refusal') {
            expect(result.error?.type, 'scroll_container_required');
          } else {
            expect(result.ok, isTrue, reason: result.error?.message);
          }
        case 'scroll_into_view':
          final row = observed!.ui.elements.firstWhere(
            (element) =>
                element.label == 'Row 12' &&
                element.actions.contains('scrollIntoView'),
          );
          final result = await _pumpUntilComplete(
            tester,
            app.binding.adapter.execute(
              ActionCommand(
                type: OperatorActionType.scrollIntoView,
                target: ElementTarget(
                  id: row.id,
                  observationTargetRef: row.observationTargetRef,
                ),
                purpose: 'reveal_row',
                risk: 1,
              ),
            ),
          );
          expect(result.ok, isTrue, reason: result.error?.message);
      }

      expect(
        _gained(before, _dependencies(appRoot)),
        isEmpty,
        reason: 'reading made app elements depend on something new',
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Next')),
        ),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        identical(controller.position, position),
        isTrue,
        reason: 'the push/pop replaced the list ScrollPosition',
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(
        scrollingNotified,
        greaterThan(0),
        reason: 'the app listener on the position no longer hears scrolling',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('controls on a page covered by another are not offered', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final app = await _host(
      tester,
      navigator,
      _page(controller, twoLists: false, nested: false),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('Next'))),
      ),
    );
    await tester.pumpAndSettle();
    final snapshot = await app.operator.getSnapshot(
      refreshVisual: false,
      refreshStorageProviders: false,
    );
    final covered = snapshot.ui.elements.where(
      (element) =>
          element.label == 'Button' ||
          element.text == 'Button' ||
          element.label == 'Row 2' ||
          element.text == 'Row 2',
    );
    expect(
      covered.where(
        (element) =>
            element.rendered == true || element.observationTargetRef != null,
      ),
      isEmpty,
      reason: 'a control on the covered page was offered as visible or given a target',
    );
    expect(
      snapshot.ui.elements.any(
        (element) => element.label == 'Next' || element.text == 'Next',
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<OperatorApp> _host(
  WidgetTester tester,
  GlobalKey<NavigatorState> navigator,
  Widget body,
) async {
  late OperatorApp app;
  await tester.pumpWidget(
    OperatorAppHost(
      config: const OperatorFlutterConfig(
        appId: 'flutter-observer-side-effect-test',
        environment: OperatorEnvironment.dev,
      ),
      onReady: (ready) => app = ready,
      child: MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(body: body),
      ),
    ),
  );
  await tester.pump();
  return app;
}

/// Text, a button, a text field and a list of tappable rows. With [twoLists] a second list shares
/// the screen, so scroll_to must be told which to use; with [nested] one row still on screen after
/// the list's first scroll is a sideways list of cards, the last of them past the screen's edge.
Widget _page(
  ScrollController controller, {
  required bool twoLists,
  required bool nested,
}) => Column(
  children: <Widget>[
    const Text('Heading'),
    ElevatedButton(onPressed: () {}, child: const Text('Button')),
    const TextField(),
    Expanded(
      child: ListView.builder(
        controller: controller,
        itemCount: 100,
        itemBuilder:
            (_, index) =>
                nested && index == 7
                    ? SizedBox(
                      height: 80,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: <Widget>[
                          for (var card = 0; card < 12; card++)
                            SizedBox(width: 90, child: Text('Card $card')),
                        ],
                      ),
                    )
                    : ListTile(title: Text('Row $index'), onTap: () {}),
      ),
    ),
    if (twoLists)
      SizedBox(
        height: 120,
        child: ListView(
          children: <Widget>[for (var i = 0; i < 20; i++) Text('Other $i')],
        ),
      ),
  ],
);

/// Every element under [root] with the inherited elements it depends on, read
/// from the framework's own diagnostics.
Map<Element, Set<InheritedElement>> _dependencies(Element root) {
  final dependencies = <Element, Set<InheritedElement>>{};
  void walk(Element element) {
    final found = <InheritedElement>{};
    for (final property in element.toDiagnosticsNode().getProperties()) {
      if (property is DiagnosticsProperty<Set<InheritedElement>> &&
          property.name == 'dependencies') {
        found.addAll(property.value ?? const <InheritedElement>{});
      }
    }
    dependencies[element] = found;
    element.visitChildren(walk);
  }

  walk(root);
  return dependencies;
}

/// Dependencies that elements present before the read have gained since.
List<String> _gained(
  Map<Element, Set<InheritedElement>> before,
  Map<Element, Set<InheritedElement>> after,
) => <String>[
  for (final entry in after.entries)
    if (before[entry.key] case final previous?)
      for (final dependency in entry.value.difference(previous))
        '${entry.key.widget.runtimeType} now depends on '
            '${dependency.widget.runtimeType}',
];

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
