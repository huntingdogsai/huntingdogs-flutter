import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

Future<T> _pumpUntilComplete<T>(WidgetTester tester, Future<T> future) async {
  var completed = false;
  future.then<void>(
    (_) => completed = true,
    onError: (Object _, StackTrace __) => completed = true,
  );
  for (var attempt = 0; attempt < 80 && !completed; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!completed) throw TestFailure('Flutter typing did not complete');
  return future;
}

const _cases = <
  ({
    String name,
    String before,
    TextSelection selection,
    String inserted,
    bool? clearFirst,
    String after,
    int caret,
  })
>[
  (
    name: 'append at end',
    before: 'Chris',
    selection: TextSelection.collapsed(offset: 5),
    inserted: ' QA3',
    clearFirst: false,
    after: 'Chris QA3',
    caret: 9,
  ),
  (
    name: 'insert in middle',
    before: 'Chris',
    selection: TextSelection.collapsed(offset: 2),
    inserted: '--',
    clearFirst: false,
    after: 'Ch--ris',
    caret: 4,
  ),
  (
    name: 'insert at start',
    before: 'Chris',
    selection: TextSelection.collapsed(offset: 0),
    inserted: 'Dr ',
    clearFirst: false,
    after: 'Dr Chris',
    caret: 3,
  ),
  (
    name: 'replace selected text',
    before: 'Chris',
    selection: TextSelection(baseOffset: 1, extentOffset: 4),
    inserted: 'at',
    clearFirst: false,
    after: 'Cats',
    caret: 3,
  ),
  (
    name: 'replace reversed selection',
    before: 'Chris',
    selection: TextSelection(baseOffset: 4, extentOffset: 1),
    inserted: 'at',
    clearFirst: false,
    after: 'Cats',
    caret: 3,
  ),
  (
    name: 'replace full selection',
    before: 'Chris',
    selection: TextSelection(baseOffset: 0, extentOffset: 5),
    inserted: 'Ada',
    clearFirst: false,
    after: 'Ada',
    caret: 3,
  ),
  (
    name: 'explicit replacement ignores cursor',
    before: 'Chris',
    selection: TextSelection.collapsed(offset: 2),
    inserted: 'Ada',
    clearFirst: true,
    after: 'Ada',
    caret: 3,
  ),
  (
    name: 'omitted flag keeps replacement default',
    before: 'Chris',
    selection: TextSelection(baseOffset: 1, extentOffset: 4),
    inserted: 'Ada',
    clearFirst: null,
    after: 'Ada',
    caret: 3,
  ),
  (
    name: 'no established selection uses end',
    before: 'Chris',
    selection: TextSelection.collapsed(offset: -1),
    inserted: ' QA3',
    clearFirst: false,
    after: 'Chris QA3',
    caret: 9,
  ),
  (
    name: 'empty field',
    before: '',
    selection: TextSelection.collapsed(offset: 0),
    inserted: 'Ada',
    clearFirst: false,
    after: 'Ada',
    caret: 3,
  ),
  (
    name: 'empty insertion preserves unselected text',
    before: 'Chris',
    selection: TextSelection.collapsed(offset: 2),
    inserted: '',
    clearFirst: false,
    after: 'Chris',
    caret: 2,
  ),
  (
    name: 'empty replacement clears',
    before: 'Chris',
    selection: TextSelection.collapsed(offset: 2),
    inserted: '',
    clearFirst: true,
    after: '',
    caret: 0,
  ),
  (
    name: 'Unicode uses Flutter UTF-16 selection offsets',
    before: 'A😀Z',
    selection: TextSelection.collapsed(offset: 3),
    inserted: 'é',
    clearFirst: false,
    after: 'A😀éZ',
    caret: 4,
  ),
];

void main() {
  for (final flag in <bool?>[false, true, null]) {
    test('clearFirst $flag survives the action wire', () {
      final action = ActionCommand(
        type: OperatorActionType.type,
        target: const ElementTarget(id: 'input'),
        text: ' QA3',
        clearFirst: flag,
      );
      final encoded = operatorActionResultToJson(
        ActionResult(ok: true, action: action),
      );
      final decoded = operatorActionCommandFromJson(
        encoded['action'] as JsonMap,
      );
      expect(decoded.clearFirst, flag);
    });
  }

  for (final exactRuntimeTarget in <bool>[true, false]) {
    for (final example in _cases) {
      testWidgets(
        '${exactRuntimeTarget ? 'exact runtime' : 'widget fallback'}: ${example.name}',
        (tester) async {
          late OperatorApp app;
          final controller = TextEditingController.fromValue(
            TextEditingValue(
              text: example.before,
              selection: example.selection,
            ),
          );
          final changes = <String>[];
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            OperatorAppHost(
              config: const OperatorFlutterConfig(
                appId: 'flutter-typing-clear-first',
                environment: OperatorEnvironment.dev,
              ),
              onReady: (ready) => app = ready,
              child: MaterialApp(
                home: Scaffold(
                  body: StatefulBuilder(
                    builder:
                        (context, setState) => Column(
                          children: [
                            Semantics(
                              label: 'Name',
                              value: 'stale-semantics-value',
                              textField: true,
                              child: ExcludeSemantics(
                                child: TextField(
                                  controller: controller,
                                  decoration: const InputDecoration(
                                    labelText: 'Name',
                                  ),
                                  onChanged:
                                      (text) =>
                                          setState(() => changes.add(text)),
                                ),
                              ),
                            ),
                            Text('Callback: ${changes.lastOrNull ?? "none"}'),
                          ],
                        ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final snapshot = await app.operator.getSnapshot(refreshVisual: false);
          final input = snapshot.ui.elements.singleWhere(
            (element) =>
                element.role == OperatorUiRole.input && element.label == 'Name',
          );
          final result = await _pumpUntilComplete(
            tester,
            app.binding.adapter.execute(
              ActionCommand(
                type: OperatorActionType.type,
                target:
                    exactRuntimeTarget
                        ? ElementTarget(id: input.id)
                        : const ElementTarget(label: 'Name'),
                text: example.inserted,
                clearFirst: example.clearFirst,
              ),
            ),
          );
          expect(result.ok, isTrue, reason: result.error?.message);
          if (exactRuntimeTarget) {
            final facts = (result.data as Map)['typing'] as Map;
            expect(facts['before'], example.before);
            expect(facts['after'], example.after);
            expect(facts['changed'], example.before != example.after);
            expect(facts['matchesRequested'], isTrue);
          }
          expect(controller.text, example.after);
          expect(
            controller.selection,
            TextSelection.collapsed(offset: example.caret),
          );
          expect(changes, [example.after]);
          expect(find.text('Callback: ${example.after}'), findsOneWidget);
          final after = await app.operator.getSnapshot(refreshVisual: false);
          expect(
            after.ui.elements
                .singleWhere((element) => element.id == input.id)
                .value,
            example.after,
          );

          // Clear must ignore clearFirst:false and empty the same controller.
          final cleared = await _pumpUntilComplete(
            tester,
            app.binding.adapter.execute(
              ActionCommand(
                type: OperatorActionType.clear,
                target:
                    exactRuntimeTarget
                        ? ElementTarget(id: input.id)
                        : const ElementTarget(label: 'Name'),
                clearFirst: false,
              ),
            ),
          );
          expect(cleared.ok, isTrue, reason: cleared.error?.message);
          expect(controller.text, '');
          expect(
            controller.selection,
            const TextSelection.collapsed(offset: 0),
          );
          expect(changes.last, '');
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('secure controller insertion keeps snapshot redaction', (
    tester,
  ) async {
    late OperatorApp app;
    final controller = TextEditingController.fromValue(
      const TextEditingValue(
        text: 'synthetic-secret',
        selection: TextSelection.collapsed(offset: 9),
      ),
    );
    final changes = <String>[];
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-typing-secure-controller',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (ready) => app = ready,
        child: MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
              onChanged: changes.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final snapshot = await app.operator.getSnapshot(refreshVisual: false);
    final input = snapshot.ui.elements.singleWhere(
      (element) =>
          element.role == OperatorUiRole.input && element.label == 'Password',
    );
    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.type,
          target: ElementTarget(id: input.id),
          text: '-test',
          clearFirst: false,
        ),
      ),
    );
    expect(result.ok, isTrue, reason: result.error?.message);
    expect(controller.text, 'synthetic-test-secret');
    expect(controller.selection, const TextSelection.collapsed(offset: 14));
    expect(changes, ['synthetic-test-secret']);
    final after = await app.operator.getSnapshot(refreshVisual: false);
    final afterInput = after.ui.elements.singleWhere(
      (element) => element.id == input.id,
    );
    expect(afterInput.value, input.value);
    expect(afterInput.value, isNot(controller.text));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('form injection still assigns the whole value', (tester) async {
    late OperatorApp app;
    final controller = TextEditingController.fromValue(
      const TextEditingValue(
        text: 'Chris',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    final changes = <String>[];
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-typing-form-injection',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (ready) => app = ready,
        child: MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: changes.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final result = await _pumpUntilComplete(
      tester,
      app.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.injectForm,
          clearFirst: false,
          fields: [FormFieldPatch(name: 'Name', value: 'Ada')],
        ),
      ),
    );
    expect(result.ok, isTrue, reason: result.error?.message);
    expect(controller.text, 'Ada');
    expect(controller.selection, const TextSelection.collapsed(offset: 3));
    expect(changes, ['Ada']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final disabled in <bool>[true, false]) {
    testWidgets(
      'exact ${disabled ? 'disabled' : 'read-only'} input is not edited',
      (tester) async {
        late OperatorApp app;
        final controller = TextEditingController(text: 'Chris');
        final changes = <String>[];
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          OperatorAppHost(
            config: const OperatorFlutterConfig(
              appId: 'flutter-typing-uneditable',
              environment: OperatorEnvironment.dev,
            ),
            onReady: (ready) => app = ready,
            child: MaterialApp(
              home: Scaffold(
                body: TextField(
                  controller: controller,
                  enabled: !disabled,
                  readOnly: !disabled,
                  decoration: const InputDecoration(labelText: 'Name'),
                  onChanged: changes.add,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final snapshot = await app.operator.getSnapshot(refreshVisual: false);
        final input = snapshot.ui.elements.singleWhere(
          (element) =>
              element.role == OperatorUiRole.input && element.label == 'Name',
        );
        final result = await _pumpUntilComplete(
          tester,
          app.binding.adapter.execute(
            ActionCommand(
              type: OperatorActionType.type,
              target: ElementTarget(id: input.id),
              text: ' QA3',
              clearFirst: false,
            ),
          ),
        );
        expect(result.ok, isFalse);
        expect(controller.text, 'Chris');
        expect(changes, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final example in _cases) {
    testWidgets('semantics fallback: ${example.name}', (tester) async {
      late OperatorApp app;
      var value = TextEditingValue(
        text: example.before,
        selection: example.selection,
      );
      final changes = <String>[];
      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-typing-semantics',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  return _SemanticInput(
                    value: value,
                    onText:
                        (text) => setState(() {
                          changes.add(text);
                          value = TextEditingValue(
                            text: text,
                            selection: TextSelection.collapsed(
                              offset: text.length,
                            ),
                          );
                        }),
                    onSelection:
                        (selection) => setState(() {
                          value = value.copyWith(selection: selection);
                        }),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final result = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          ActionCommand(
            type: OperatorActionType.type,
            target: const ElementTarget(label: 'Semantic input'),
            text: example.inserted,
            clearFirst: example.clearFirst,
          ),
        ),
      );
      expect(result.ok, isTrue, reason: result.error?.message);
      expect(value.text, example.after);
      expect(value.selection, TextSelection.collapsed(offset: example.caret));
      expect(changes, [example.after]);
      expect(find.text('Value: ${example.after}'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'obscured semantics alone cannot reconstruct text for insertion',
    (tester) async {
      late OperatorApp app;
      final changes = <String>[];
      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-typing-obscured-semantics',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (ready) => app = ready,
          child: MaterialApp(
            home: Scaffold(
              body: _SemanticInput(
                value: const TextEditingValue(
                  text: '•••••',
                  selection: TextSelection.collapsed(offset: 5),
                ),
                obscured: true,
                onText: changes.add,
                onSelection: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final result = await _pumpUntilComplete(
        tester,
        app.binding.adapter.execute(
          const ActionCommand(
            type: OperatorActionType.type,
            target: ElementTarget(label: 'Semantic input'),
            text: 'x',
            clearFirst: false,
          ),
        ),
      );
      expect(result.ok, isFalse);
      expect(result.error?.type, 'text_editing_value_unavailable');
      expect(changes, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

// A real semantics-only editable control: no TextField/EditableText controller is
// available to Watchdog. Its app callbacks and rendered value are the oracle.
class _SemanticInput extends SingleChildRenderObjectWidget {
  _SemanticInput({
    required this.value,
    required this.onText,
    required this.onSelection,
    this.obscured = false,
  }) : super(child: ExcludeSemantics(child: Text('Value: ${value.text}')));

  final TextEditingValue value;
  final ValueChanged<String> onText;
  final ValueChanged<TextSelection> onSelection;
  final bool obscured;

  @override
  _RenderSemanticInput createRenderObject(BuildContext context) =>
      _RenderSemanticInput(value, onText, onSelection, obscured);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSemanticInput renderObject,
  ) {
    renderObject
      ..value = value
      ..onText = onText
      ..onSelection = onSelection
      ..obscured = obscured
      ..markNeedsSemanticsUpdate();
  }
}

class _RenderSemanticInput extends RenderProxyBox {
  _RenderSemanticInput(
    this.value,
    this.onText,
    this.onSelection,
    this.obscured,
  );
  TextEditingValue value;
  ValueChanged<String> onText;
  ValueChanged<TextSelection> onSelection;
  bool obscured;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..isTextField = true
      ..isObscured = obscured
      ..textDirection = TextDirection.ltr
      ..label = 'Semantic input'
      ..value = value.text
      ..textSelection = value.selection
      ..onSetText = onText
      ..onSetSelection = onSelection;
  }
}
