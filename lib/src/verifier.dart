import 'dart:convert';

import 'protocol.dart';

class OperatorVerifier {
  VerificationResult verify(VerificationRequest request) {
    final evidence = <VerificationEvidence>[
      VerificationEvidence(
        source: OperatorVerificationSource.action,
        condition: 'adapter action returned ok',
        ok: request.result.ok,
        detail: request.result.message ?? request.result.error?.message,
      ),
    ];

    if (!request.result.ok) {
      return VerificationResult(
        ok: false,
        evidence: evidence,
        reason: request.result.error?.message ?? 'Action failed',
      );
    }

    for (final condition in request.action.expected) {
      evidence.add(_evaluateCondition(condition, request.after));
    }

    final failed = evidence.where((item) => !item.ok).toList();
    return VerificationResult(
      ok: failed.isEmpty,
      evidence: evidence,
      reason: failed.isEmpty ? null : failed.first.detail,
    );
  }
}

VerificationEvidence _evaluateCondition(
  VerificationCondition condition,
  AppSnapshot snapshot,
) {
  switch (condition.source) {
    case OperatorVerificationSource.ui:
      return _verifyUi(condition, snapshot);
    case OperatorVerificationSource.state:
      return _verifyState(condition, snapshot.state);
    case OperatorVerificationSource.network:
      return _verifyNetwork(condition, snapshot.network.events);
    case OperatorVerificationSource.route:
      return _verifyRoute(condition, snapshot.route);
    case OperatorVerificationSource.storage:
      return _verifyStorage(condition, snapshot);
    case OperatorVerificationSource.form:
      return _verifyForm(condition, snapshot);
    case OperatorVerificationSource.log:
      return _verifyLogs(condition, snapshot.logs);
    case OperatorVerificationSource.action:
      return const VerificationEvidence(
        source: OperatorVerificationSource.action,
        condition: 'action condition is not user-authored',
        ok: true,
      );
  }
}

VerificationEvidence _verifyUi(
  VerificationCondition condition,
  AppSnapshot snapshot,
) {
  final element =
      condition.target != null
          ? _resolveElement(snapshot.ui, condition.target!)
          : snapshot.ui.elements.cast<UiElement?>().firstWhere((candidate) {
            if (candidate == null) return false;
            final textOk =
                condition.textIncludes == null ||
                (candidate.text ?? '').toLowerCase().contains(
                  condition.textIncludes!.toLowerCase(),
                );
            final labelOk =
                condition.labelIncludes == null ||
                (candidate.label ?? '').toLowerCase().contains(
                  condition.labelIncludes!.toLowerCase(),
                );
            return textOk && labelOk;
          }, orElse: () => null);
  final expectedVisible = condition.visible ?? true;
  final ok = element != null && element.visible == expectedVisible;
  return VerificationEvidence(
    source: OperatorVerificationSource.ui,
    condition: _describe(condition),
    ok: ok,
    detail: ok ? element.id : 'Expected UI element was not visible',
  );
}

VerificationEvidence _verifyState(
  VerificationCondition condition,
  List<StateStoreSnapshot> stores,
) {
  final candidates =
      condition.store == null
          ? stores
          : stores.where((store) => store.name == condition.store);
  for (final store in candidates) {
    final value = stateValueAtPath(store.value, condition.path ?? r'$');
    final hasComparator =
        condition.equals != null || condition.includes != null;
    if (!hasComparator && value != null) {
      return VerificationEvidence(
        source: OperatorVerificationSource.state,
        condition: _describe(condition),
        ok: true,
        detail: store.name,
      );
    }
    if (condition.equals != null && _deepEqual(value, condition.equals)) {
      return VerificationEvidence(
        source: OperatorVerificationSource.state,
        condition: _describe(condition),
        ok: true,
        detail: store.name,
      );
    }
    if (condition.includes != null &&
        _includesValue(value, condition.includes)) {
      return VerificationEvidence(
        source: OperatorVerificationSource.state,
        condition: _describe(condition),
        ok: true,
        detail: store.name,
      );
    }
  }
  return VerificationEvidence(
    source: OperatorVerificationSource.state,
    condition: _describe(condition),
    ok: false,
    detail: 'No state store satisfied ${condition.path ?? r'$'}',
  );
}

VerificationEvidence _verifyNetwork(
  VerificationCondition condition,
  List<NetworkEvent> events,
) {
  final matching = events.reversed.cast<NetworkEvent?>().firstWhere((event) {
    if (event == null) return false;
    if (condition.method != null &&
        event.request.method.toUpperCase() != condition.method!.toUpperCase()) {
      return false;
    }
    if (condition.path != null && event.request.path != condition.path)
      return false;
    if (condition.status != null && event.response?.status != condition.status)
      return false;
    if (condition.ok != null && event.response?.ok != condition.ok)
      return false;
    return true;
  }, orElse: () => null);
  return VerificationEvidence(
    source: OperatorVerificationSource.network,
    condition: _describe(condition),
    ok: matching != null,
    detail:
        matching == null
            ? 'Network event not found'
            : '${matching.request.method} ${matching.request.path ?? matching.request.url}',
  );
}

VerificationEvidence _verifyRoute(
  VerificationCondition condition,
  RouteState route,
) {
  final ok =
      (condition.path == null || route.current.path == condition.path) &&
      (condition.name == null || route.current.name == condition.name);
  return VerificationEvidence(
    source: OperatorVerificationSource.route,
    condition: _describe(condition),
    ok: ok,
    detail: route.current.name ?? route.current.path,
  );
}

VerificationEvidence _verifyStorage(
  VerificationCondition condition,
  AppSnapshot snapshot,
) {
  final entry = snapshot.storage?.entries
      .cast<StorageEntrySnapshot?>()
      .firstWhere((candidate) {
        if (candidate == null) return false;
        if (condition.area != null && candidate.area != condition.area)
          return false;
        if (condition.key != null && candidate.key != condition.key)
          return false;
        if (condition.namespace != null &&
            candidate.namespace != condition.namespace)
          return false;
        if (condition.metadataOnly != null &&
            candidate.metadataOnly != condition.metadataOnly)
          return false;
        return true;
      }, orElse: () => null);
  final value =
      condition.path == null
          ? entry?.value
          : stateValueAtPath(entry?.value, condition.path!);
  final ok =
      entry != null &&
      (condition.equals == null || _deepEqual(value, condition.equals)) &&
      (condition.includes == null || _includesValue(value, condition.includes));
  return VerificationEvidence(
    source: OperatorVerificationSource.storage,
    condition: _describe(condition),
    ok: ok,
    detail:
        entry == null
            ? 'Storage entry not found'
            : '${entry.area}:${entry.key}',
  );
}

VerificationEvidence _verifyForm(
  VerificationCondition condition,
  AppSnapshot snapshot,
) {
  final forms =
      condition.formId == null
          ? snapshot.forms
          : snapshot.forms.where((form) => form.id == condition.formId);
  FormSnapshot? matchedForm;
  FormFieldSnapshot? matchedField;
  for (final form in forms) {
    for (final field in form.fields) {
      if (condition.fieldId != null && field.id != condition.fieldId) continue;
      if (condition.name != null && field.name != condition.name) continue;
      matchedForm = form;
      matchedField = field;
      break;
    }
    if (matchedField != null) break;
  }
  final ok =
      matchedField != null &&
      (condition.value == null ||
          _deepEqual(matchedField.value, condition.value)) &&
      (condition.checked == null ||
          matchedField.checked == condition.checked) &&
      (condition.selected == null ||
          matchedField.selected == condition.selected) &&
      (condition.errorsInclude == null ||
          matchedField.errors.any(
            (error) => error.contains(condition.errorsInclude!),
          ));
  return VerificationEvidence(
    source: OperatorVerificationSource.form,
    condition: _describe(condition),
    ok: ok,
    detail:
        matchedField == null
            ? 'Form field not found'
            : '${matchedForm!.id}:${matchedField.id}',
  );
}

VerificationEvidence _verifyLogs(
  VerificationCondition condition,
  List<LogEvent> logs,
) {
  if (condition.absentLevel != null) {
    final found = logs.cast<LogEvent?>().firstWhere(
      (log) => log?.level == condition.absentLevel,
      orElse: () => null,
    );
    return VerificationEvidence(
      source: OperatorVerificationSource.log,
      condition: _describe(condition),
      ok: found == null,
      detail: found?.message,
    );
  }

  final found =
      condition.textIncludes == null
          ? null
          : logs.cast<LogEvent?>().firstWhere(
            (log) =>
                log?.message.toLowerCase().contains(
                  condition.textIncludes!.toLowerCase(),
                ) ??
                false,
            orElse: () => null,
          );
  return VerificationEvidence(
    source: OperatorVerificationSource.log,
    condition: _describe(condition),
    ok: found != null,
    detail: found?.message,
  );
}

UiElement? _resolveElement(UiTree ui, ElementTarget target) {
  if (target.id != null) {
    final byId = ui.elements.cast<UiElement?>().firstWhere(
      (element) => element?.id == target.id || element?.platformId == target.id,
      orElse: () => null,
    );
    if (byId != null) return byId;
  }
  return ui.elements.cast<UiElement?>().firstWhere((element) {
    if (element == null) return false;
    final roleOk =
        target.role == null || _roleName(element.role) == target.role;
    final labelOk =
        target.label == null ||
        (element.label ?? '').toLowerCase().contains(
          target.label!.toLowerCase(),
        );
    final textOk =
        target.text == null ||
        (element.text ?? '').toLowerCase().contains(target.text!.toLowerCase());
    return roleOk && labelOk && textOk;
  }, orElse: () => null);
}

Object? stateValueAtPath(Object? value, String path) {
  final direct = valueAtPath(value, path);
  if (direct != null || path == r'$' || path.isEmpty) return direct;
  if (value is Map && value.containsKey('state')) {
    return valueAtPath(value['state'], path);
  }
  return null;
}

Object? valueAtPath(Object? value, String path) {
  if (path == r'$' || path.isEmpty) return value;
  final parts = path
      .replaceAllMapped(RegExp(r'\[(\d+)\]'), (match) => '.${match.group(1)}')
      .split('.')
      .where((part) => part.isNotEmpty);
  Object? cursor = value;
  for (final part in parts) {
    if (cursor == null) return null;
    if (cursor is List) {
      final index = int.tryParse(part);
      if (index == null || index < 0 || index >= cursor.length) return null;
      cursor = cursor[index];
      continue;
    }
    if (cursor is Map) {
      cursor = cursor[part];
      continue;
    }
    return null;
  }
  return cursor;
}

bool _includesValue(Object? value, Object? expected) {
  if (value is List)
    return value.any((entry) => _matchesExpected(entry, expected));
  if (value is String && expected is String) return value.contains(expected);
  return false;
}

bool _matchesExpected(Object? value, Object? expected) {
  if (expected is! Map) return _deepEqual(value, expected);
  if (value is! Map) return false;
  return expected.entries.every(
    (entry) => _matchesExpected(value[entry.key], entry.value),
  );
}

bool _deepEqual(Object? left, Object? right) {
  if (identical(left, right) || left == right) return true;
  return jsonEncode(_sortValue(left)) == jsonEncode(_sortValue(right));
}

Object? _sortValue(Object? value) {
  if (value is List) return value.map(_sortValue).toList();
  if (value is Map) {
    final entries =
        value.entries.toList()..sort(
          (left, right) => left.key.toString().compareTo(right.key.toString()),
        );
    return Map<String, Object?>.fromEntries(
      entries.map(
        (entry) => MapEntry(entry.key.toString(), _sortValue(entry.value)),
      ),
    );
  }
  return value;
}

String _describe(VerificationCondition condition) {
  return [
    condition.source.name,
    condition.path,
    condition.store,
    condition.method,
    condition.status,
    condition.name,
    condition.textIncludes,
    condition.labelIncludes,
  ].whereType<Object>().join(':');
}

String? _roleName(OperatorUiRole? role) {
  if (role == null) return null;
  if (role == OperatorUiRole.switchRole) return 'switch';
  return role.name;
}
