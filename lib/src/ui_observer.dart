import 'package:flutter/widgets.dart';

import 'protocol.dart';

class OperatorUiNode {
  const OperatorUiNode({
    required this.id,
    required this.role,
    required this.enabled,
    required this.visible,
    required this.actions,
    this.label,
    this.text,
    this.value,
    this.hint,
    this.bounds,
    this.children = const <OperatorUiNode>[],
    this.data = const <String, Object?>{},
  });

  final String id;
  final OperatorUiRole role;
  final String? label;
  final String? text;
  final Object? value;
  final String? hint;
  final bool enabled;
  final bool visible;
  final ElementBounds? bounds;
  final List<String> actions;
  final List<OperatorUiNode> children;
  final JsonMap data;
}

UiTree buildFlutterUiTree({
  required String rootId,
  required Size viewport,
  required List<OperatorUiNode> nodes,
}) {
  final elements = <UiElement>[];

  void visit(OperatorUiNode node, String? parentId) {
    elements.add(
      UiElement(
        id: node.id,
        role: node.role,
        label: node.label,
        text: node.text,
        value: node.value,
        hint: node.hint,
        enabled: node.enabled,
        visible: node.visible,
        bounds: node.bounds,
        parentId: parentId,
        children: node.children.map((child) => child.id).toList(),
        actions: node.actions,
        data: node.data,
        confidence: node.id.startsWith('operator_') ? 1 : 0.82,
      ),
    );
    for (final child in node.children) {
      visit(child, node.id);
    }
  }

  for (final node in nodes) {
    visit(node, null);
  }

  return UiTree(
    rootId: rootId,
    elements: List<UiElement>.unmodifiable(elements),
    viewport: ViewportSnapshot(width: viewport.width, height: viewport.height),
  );
}

OperatorUiNode operatorButtonNode({
  required String id,
  required String label,
  bool enabled = true,
  bool visible = true,
  ElementBounds? bounds,
}) {
  return OperatorUiNode(
    id: id,
    role: OperatorUiRole.button,
    label: label,
    text: label,
    enabled: enabled,
    visible: visible,
    bounds: bounds,
    actions: const <String>['tap'],
  );
}

OperatorUiNode operatorTextInputNode({
  required String id,
  required String label,
  Object? value,
  bool enabled = true,
  bool visible = true,
  ElementBounds? bounds,
}) {
  return OperatorUiNode(
    id: id,
    role: OperatorUiRole.input,
    label: label,
    value: value,
    enabled: enabled,
    visible: visible,
    bounds: bounds,
    actions: const <String>['focus', 'type', 'clear'],
  );
}
