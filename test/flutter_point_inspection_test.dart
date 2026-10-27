import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

Future<T> _pumpResult<T>(WidgetTester tester, Future<T> result) async {
  var settled = false;
  result.then<void>(
    (_) => settled = true,
    onError: (Object _, StackTrace __) => settled = true,
  );
  for (var i = 0; i < 80 && !settled; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!settled) throw TestFailure('Input did not settle');
  return result;
}

void main() {
  for (final secure in [false, true]) {
    testWidgets('point lookup is read-only; secure=$secure', (tester) async {
      late OperatorApp app;
      final controller = TextEditingController(text: 'Chris');
      final focus = FocusNode();
      var clicks = 0;
      var changes = 0;
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'point-inspection',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  TextField(
                    controller: controller,
                    focusNode: focus,
                    obscureText: secure,
                    decoration: InputDecoration(
                      labelText: 'First Name',
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.info),
                        tooltip: 'Details',
                        onPressed: () => clicks++,
                      ),
                    ),
                    onChanged: (_) => changes++,
                  ),
                  ElevatedButton(
                    onPressed: () => clicks++,
                    child: const Text('Save'),
                  ),
                  const TextField(
                    enabled: false,
                    decoration: InputDecoration(labelText: 'Disabled'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final snapshot = await app.operator.getSnapshot(
        refreshVisual: false,
        refreshStorageProviders: false,
      );
      final inspector =
          app.binding.adapter.actuator as OperatorFlutterPointInspector;
      final field = snapshot.ui.elements.singleWhere(
        (e) => e.label == 'First Name' && e.role == OperatorUiRole.input,
      );
      final p =
          tester.getTopLeft(find.byType(TextField).first) +
          const Offset(40, 25);
      // Read the live controller, not just the value in the preceding snapshot.
      controller.value = const TextEditingValue(
        text: 'Chris QA',
        selection: TextSelection.collapsed(offset: 8),
      );
      final before = controller.value;
      final result = inspector.inspectPoint(p.dx, p.dy);
      expect(result['status'], 'found');
      final control = result['control']! as Map;
      expect(control['id'], field.id);
      expect(control['value'], secure ? '[SECURE_FIELD]' : 'Chris QA');
      expect(control['label'], 'First Name');
      final textPoint = tester.getCenter(find.byType(EditableText).first);
      final textControl =
          inspector.inspectPoint(textPoint.dx, textPoint.dy)['control']! as Map;
      expect(
        textControl['id'],
        field.id,
        reason: 'Internal text scrolling must resolve to the field',
      );
      expect(
        (control['observationTargetRef']! as Map)['ticketId'],
        field.observationTargetRef!.ticketId,
      );
      expect(controller.value, before);
      expect(focus.hasFocus, false);
      expect(changes, 0);
      expect(clicks, 0);
      final icon = tester.getCenter(find.byTooltip('Details'));
      final child = inspector.inspectPoint(icon.dx, icon.dy)['control']! as Map;
      expect(
        child['label'],
        'Details',
      ); // nested button, not its enclosing field
      final button = tester.getCenter(
        find.widgetWithText(ElevatedButton, 'Save'),
      );
      expect(
        (inspector.inspectPoint(button.dx, button.dy)['control']!
            as Map)['label'],
        'Save',
      );
      expect(clicks, 0);
      final disabled = tester.getCenter(find.byType(TextField).last);
      expect(
        inspector.inspectPoint(disabled.dx, disabled.dy)['status'],
        'not_found',
      );
      expect(inspector.inspectPoint(700, 500)['status'], 'not_found');
      expect(() => inspector.inspectPoint(-1, 20), throwsStateError);
      expect(() => inspector.inspectPoint(double.nan, 20), throwsStateError);
      // The lookup ticket is copyable into the real structured-input path. This
      // subsequent action intentionally types; the lookup above changed nothing.
      final ref = control['observationTargetRef']! as Map;
      final typed = await _pumpResult(
        tester,
        app.binding.adapter.execute(
          ActionCommand(
            type: OperatorActionType.type,
            target: ElementTarget(
              id: control['id']! as String,
              observationTargetRef: FlutterObservationTargetRef(
                ticketId: ref['ticketId']! as String,
                snapshotId: ref['snapshotId']! as String,
              ),
            ),
            text: '!',
            clearFirst: false,
          ),
        ),
      );
      expect(typed.ok, true);
      expect(controller.text, 'Chris QA!');
      expect(changes, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  testWidgets('opaque overlay never resolves to the covered button', (
    tester,
  ) async {
    late OperatorApp app;
    late StateSetter rebuild;
    var covered = false;
    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'point-overlay',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (ready) => app = ready,
        child: MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Stack(
                children: [
                  Center(
                    child: ElevatedButton(
                      onPressed: () {},
                      child: const Text('Covered'),
                    ),
                  ),
                  if (covered)
                    const Positioned.fill(
                      child: AbsorbPointer(
                        child: ColoredBox(color: Colors.white),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await app.operator.getSnapshot(
      refreshVisual: false,
      refreshStorageProviders: false,
    );
    final inspector =
        app.binding.adapter.actuator as OperatorFlutterPointInspector;
    final p = tester.getCenter(find.widgetWithText(ElevatedButton, 'Covered'));
    final beforeOverlay = inspector.inspectPoint(p.dx, p.dy);
    expect(beforeOverlay['status'], 'found');
    rebuild(() => covered = true);
    await tester.pump();
    expect(inspector.inspectPoint(p.dx, p.dy)['status'], 'not_found');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a point lookup refuses a control replaced since the screenshot',
    (tester) async {
      late OperatorApp app;
      late StateSetter rebuild;
      var replaced = false;
      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'point-replaced',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return Center(
                  child: ElevatedButton(
                    key: ValueKey(replaced),
                    onPressed: () {},
                    child: const Text('Same label'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await app.operator.getSnapshot(
        refreshVisual: false,
        refreshStorageProviders: false,
      );
      final inspector =
          app.binding.adapter.actuator as OperatorFlutterPointInspector;
      final point = tester.getCenter(find.byType(ElevatedButton));
      final beforeReplacement = inspector.inspectPoint(point.dx, point.dy);
      expect(beforeReplacement['status'], 'found');
      rebuild(() => replaced = true);
      await tester.pump();
      expect(
        () => inspector.inspectPoint(point.dx, point.dy),
        throwsStateError,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  // The option paints in the Overlay but is the portal's element child in the page. An app may
  // also wrap every screen in a KeyboardListener (an idle timer, say); that listener handles no
  // press, so it must not hide the tappable row inside it.
  for (final appWideKeyboardListener in [false, true]) {
    testWidgets(
      'a point on an option in an overlay list finds the row and a plain tap selects it; '
      'app-wide KeyboardListener=$appWideKeyboardListener',
      (tester) async {
        late OperatorApp app;
        final field = TextEditingController();
        addTearDown(field.dispose);
        final keys = FocusNode();
        addTearDown(keys.dispose);
        final page = MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: ListView(
              children: <Widget>[
                const SizedBox(height: 100),
                RawAutocomplete<String>(
                  textEditingController: field,
                  focusNode: FocusNode(),
                  optionsBuilder:
                      (value) => [for (var i = 0; i < 12; i++) 'Option $i'],
                  fieldViewBuilder:
                      (context, controller, focusNode, onSubmit) => TextField(
                        controller: controller,
                        focusNode: focusNode,
                      ),
                  optionsViewBuilder:
                      (context, onSelected, options) => Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4,
                          child: SizedBox(
                            width: 300,
                            height: 175,
                            child: ListView(
                              children: <Widget>[
                                for (final option in options)
                                  InkWell(
                                    onTap: () => onSelected(option),
                                    child: SizedBox(
                                      height: 48,
                                      child: Text(option),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                ),
                for (var i = 0; i < 20; i++)
                  SizedBox(height: 60, child: Text('Page row $i')),
              ],
            ),
          ),
        );
        await tester.pumpWidget(
          OperatorAppHost(
            config: const OperatorFlutterConfig(
              appId: 'overlay-point',
              environment: OperatorEnvironment.dev,
            ),
            onReady: (ready) => app = ready,
            child:
                appWideKeyboardListener
                    ? KeyboardListener(
                      focusNode: keys,
                      includeSemantics: false,
                      onKeyEvent: (_) {},
                      child: page,
                    )
                    : page,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(TextField));
        await tester.pumpAndSettle();
        await app.operator.getSnapshot(
          refreshVisual: false,
          refreshStorageProviders: false,
        );
        final inspector =
            app.binding.adapter.actuator as OperatorFlutterPointInspector;
        final point = tester.getCenter(find.text('Option 1'));
        final found = inspector.inspectPoint(point.dx, point.dy);
        expect(found['status'], 'found');
        final control = found['control']! as Map;
        expect(
          control['role'],
          'button',
          reason: 'the row, not the list behind it',
        );
        expect(control['label'], 'Option 1');
        expect(control['actions'], contains('tap'));
        final tapped = await _pumpResult(
          tester,
          app.binding.adapter.execute(
            ActionCommand(
              type: OperatorActionType.tapPoint,
              target: ElementTarget(
                point: FallbackPoint(x: point.dx, y: point.dy),
              ),
              purpose: 'select_overlay_option',
              risk: 1,
            ),
          ),
        );
        expect(tapped.ok, true, reason: tapped.error?.message);
        expect(
          (tapped.data as Map)['underPointer'],
          containsPair('label', 'Option 1'),
        );
        await tester.pumpAndSettle();
        expect(field.text, 'Option 1');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
