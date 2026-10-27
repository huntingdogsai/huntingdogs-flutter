import 'dart:convert';

import 'protocol.dart';

/// The JSON of [snapshot], with each number JSON cannot carry sent empty and
/// listed (see [operatorReadableJson]). [readable] false leaves such numbers
/// in place, for a caller that trims the snapshot first and makes it readable
/// last, so the listed paths match what is sent.
JsonMap operatorSnapshotToJson(AppSnapshot snapshot, {bool readable = true}) {
  final json = _snapshotToJson(snapshot);
  return readable ? operatorReadableJson(json) as JsonMap : json;
}

JsonMap operatorRuntimeEventToJson(OperatorRuntimeEvent event) =>
    _runtimeEventToJson(event);

ActionCommand operatorActionCommandFromJson(Object? value) =>
    _actionFromJson(value);

ActionCommand operatorActionCommandFromEnvelopeJson(Object? value) =>
    _actionFromJson(_fieldOrSelf(value, 'action'));

JsonMap operatorActionResultToJson(ActionResult result) =>
    _actionResultToJson(result);

JsonMap operatorCapabilitiesToJson(OperatorCapabilities capabilities) =>
    _capabilitiesToJson(capabilities);

String operatorPlatformName(OperatorPlatform platform) =>
    _platformName(platform);

String operatorRuntimeEventTypeName(OperatorRuntimeEventType type) =>
    _runtimeEventTypeName(type);

JsonMap operatorRedactionToJson(RedactionReport report) =>
    _redactionToJson(report);

List<JsonMap> operatorVisualFramesToJson(List<VisualFrame> frames) =>
    frames.map(_visualFrameToJson).toList();

List<JsonMap> operatorVisualCaptureTargetsToJson(
  List<VisualCaptureTarget> targets,
) => targets.map(_visualCaptureTargetToJson).toList();

/// [message] ready for JSON, which cannot carry a number that is not a number
/// (such as 0 ÷ 0) or is infinite. Each such number is sent empty, and where it
/// was is listed under `unreadableValues`, so one such value never stops the
/// whole message. Parts without one are sent as they are, uncopied.
Object? operatorReadableJson(Object? message) {
  if (!_hasUnreadableNumber(message)) return message;
  final listed = <JsonMap>[];
  var found = 0;
  final path = <Object?>[];
  Object? readable(Object? value, String? item) {
    if (value is double && !value.isFinite) {
      found += 1;
      if (listed.length < _maxListedUnreadableValues) {
        listed.add(<String, Object?>{
          'path': _unreadablePath(path),
          if (item != null) 'item': item,
          'value': value.isNaN ? 'NaN' : (value > 0 ? 'Infinity' : '-Infinity'),
        });
      }
      return null;
    }
    if (!_hasUnreadableNumber(value)) return value;
    Object? inside(Object? segment, Object? child, String? around) {
      path.add(segment);
      final sent = readable(child, around);
      path.removeLast();
      return sent;
    }

    if (value is Map) {
      final around = _unreadableItem(value, item);
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): inside(entry.key, entry.value, around),
      };
    }
    final list = value as List<Object?>;
    return <Object?>[
      for (var index = 0; index < list.length; index++)
        inside(index, list[index], item),
    ];
  }

  final sent = readable(message, null);
  // A message that is not an object has nowhere to carry the list; its
  // unreadable numbers are still sent empty.
  if (sent is! JsonMap) return sent;
  final earlier = sent['unreadableValues'];
  final earlierValues =
      earlier is Map && earlier['values'] is List
          ? earlier['values'] as List<Object?>
          : const <Object?>[];
  final earlierMore =
      earlier is Map && earlier['more'] is int ? earlier['more'] as int : 0;
  final values =
      <Object?>[
        ...earlierValues,
        ...listed,
      ].take(_maxListedUnreadableValues).toList();
  final more = earlierValues.length + earlierMore + found - values.length;
  return <String, Object?>{
    ...sent,
    'unreadableValues': <String, Object?>{
      'note':
          'These values were not numbers (such as 0 ÷ 0) or were infinite, '
          'so they are empty in this message. Each path is where the value '
          'sat in the message as the app sent it.',
      'values': values,
      if (more > 0) 'more': more,
    },
  };
}

/// The JSON text of [message], with every number JSON cannot carry sent empty
/// and listed (see [operatorReadableJson]), and any other value JSON cannot
/// carry sent as its text, so no single value stops the whole message. A number
/// JSON cannot carry inside a value's own toJson() is sent as its text too.
String operatorEncodeJson(Object? message) =>
    jsonEncode(operatorReadableJson(message), toEncodable: _encodableJsonValue);

/// A value jsonEncode cannot write itself: its toJson() when that gives JSON,
/// which is what jsonEncode uses by default, and otherwise its text, as event
/// payloads send such values (see [_eventPayloadToJsonValue]).
Object? _encodableJsonValue(Object? value) {
  try {
    final Object? json = (value as dynamic).toJson();
    if (json is Map) {
      return <String, Object?>{
        for (final entry in json.entries) entry.key.toString(): entry.value,
      };
    }
    if (json == null ||
        json is bool ||
        json is String ||
        json is List ||
        (json is num && json.isFinite)) {
      return json;
    }
  } catch (_) {
    // No toJson(), or one that fails: the value is sent as its text.
  }
  if (value is DateTime) return value.toIso8601String();
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  return value.toString();
}

const int _maxListedUnreadableValues = 20;

bool _hasUnreadableNumber(Object? value) => switch (value) {
  double() => !value.isFinite,
  Map() => value.values.any(_hasUnreadableNumber),
  List() => value.any(_hasUnreadableNumber),
  _ => false,
};

/// Where an unreadable number sat, from the message's root: `$.ui.elements[3]`.
String _unreadablePath(List<Object?> path) {
  final text = StringBuffer(r'$');
  for (final segment in path) {
    text.write(segment is int ? '[$segment]' : '.$segment');
  }
  return text.toString();
}

/// What an object holding an unreadable number is. An object that names itself
/// (label, name, id or key) or its widget or state type is described by that;
/// one that only states a category (role or type) is described by it only when
/// nothing around it says more, so a scroll owner's category never hides the
/// element it belongs to.
String? _unreadableItem(Map<Object?, Object?> value, String? around) {
  String? field(List<String> keys) {
    for (final key in keys) {
      final text = value[key];
      if (text is String && text.trim().isNotEmpty) {
        final trimmed = text.trim();
        return trimmed.length <= 60 ? trimmed : '${trimmed.substring(0, 59)}…';
      }
    }
    return null;
  }

  final name = field(const <String>['label', 'name', 'id', 'key']);
  final type = field(const <String>['widget', 'state']);
  if (name == null && type == null && around != null) return around;
  final kind = type ?? field(const <String>['role', 'type']);
  if (kind == null && name == null) return around;
  return <String>[
    if (kind != null) kind,
    if (name != null) '"$name"',
  ].join(' ');
}

JsonMap operatorVerifyPayload(Object? payload, JsonMap afterSnapshot) {
  final root = _asMap(payload);
  final request = _asMap(root['request']);
  final planned = _asMap(request['action']);
  final commandMap = _asMap(planned['command'] ?? planned);
  final expected = _list(planned['expected'] ?? commandMap['expected']);
  final result = _asMap(request['result']);
  final after = _asMap(request['after'] ?? afterSnapshot);

  final evidence = <JsonMap>[];
  var ok = result['ok'] == true;
  for (final condition in expected.map(_asMap)) {
    final item = _verifyCondition(condition, after);
    evidence.add(item);
    ok = ok && item['ok'] == true;
  }

  return <String, Object?>{
    'ok': ok,
    'evidence': evidence,
    if (!ok) 'reason': 'Flutter live bridge verification failed',
  };
}

JsonMap _verifyCondition(JsonMap condition, JsonMap snapshot) {
  final source = condition['source']?.toString();
  if (source == 'route') {
    final current = _asMap(_asMap(snapshot['route'])['current']);
    final ok =
        (condition['path'] == null || current['path'] == condition['path']) &&
        (condition['name'] == null || current['name'] == condition['name']);
    return _evidence(
      'route',
      'route matches',
      ok,
      (current['path'] ?? current['name'])?.toString(),
    );
  }
  if (source == 'state') {
    final store = _findStateStore(_list(snapshot['state']), condition['store']);
    final value = _stateValueAtPath(_asMap(store)['value'], condition['path']);
    final ok =
        condition.containsKey('equals')
            ? _deepEquals(value, condition['equals'])
            : condition.containsKey('includes')
            ? _includes(value, condition['includes'])
            : value != null;
    return _evidence(
      'state',
      'state matches',
      ok,
      condition['store']?.toString(),
    );
  }
  if (source == 'network') {
    final events = _list(_asMap(snapshot['network'])['events']).map(_asMap);
    final match = events.toList().reversed.any((event) {
      final request = _asMap(event['request']);
      final response = _asMap(event['response']);
      if (condition['method'] != null &&
          request['method']?.toString().toUpperCase() !=
              condition['method']?.toString().toUpperCase())
        return false;
      if (condition['path'] != null && request['path'] != condition['path']) {
        return false;
      }
      if (condition['status'] != null &&
          response['status'] != condition['status'])
        return false;
      if (condition['ok'] != null && response['ok'] != condition['ok']) {
        return false;
      }
      return true;
    });
    return _evidence(
      'network',
      'network matches',
      match,
      condition['path']?.toString(),
    );
  }
  if (source == 'ui') {
    final elements = _list(_asMap(snapshot['ui'])['elements']).map(_asMap);
    final target = _asMap(condition['target']);
    final match = elements.any((element) {
      if (target['id'] != null && element['id'] != target['id']) return false;
      if (target['text'] != null && element['text'] != target['text']) {
        return false;
      }
      if (target['label'] != null && element['label'] != target['label']) {
        return false;
      }
      if (condition['visible'] != null &&
          element['visible'] != condition['visible'])
        return false;
      if (condition['textIncludes'] != null &&
          !(element['text']?.toString() ?? '').contains(
            condition['textIncludes'].toString(),
          ))
        return false;
      if (condition['labelIncludes'] != null &&
          !(element['label']?.toString() ?? '').contains(
            condition['labelIncludes'].toString(),
          ))
        return false;
      return true;
    });
    return _evidence('ui', 'ui matches', match, target['id']?.toString());
  }
  if (source == 'log') {
    final logs = _list(snapshot['logs']).map(_asMap);
    if (condition['absentLevel'] != null) {
      final found = logs.any((log) => log['level'] == condition['absentLevel']);
      return _evidence(
        'log',
        'log level absent',
        !found,
        condition['absentLevel']?.toString(),
      );
    }
  }
  return _evidence(source ?? 'action', 'condition not checked', true);
}

JsonMap? _findStateStore(List<Object?> stores, Object? name) {
  for (final item in stores) {
    final store = _asMap(item);
    if (name == null || store['name'] == name) return store;
  }
  return null;
}

JsonMap _evidence(String source, String condition, bool ok, [String? detail]) =>
    <String, Object?>{
      'source': source,
      'condition': condition,
      'ok': ok,
      if (detail != null) 'detail': detail,
    };

Object? _stateValueAtPath(Object? value, Object? path) {
  final direct = _valueAtPath(value, path);
  if (direct != null || path == null || path == r'$' || path == '') {
    return direct;
  }
  if (value is Map && value.containsKey('state')) {
    return _valueAtPath(value['state'], path);
  }
  return null;
}

Object? _valueAtPath(Object? value, Object? path) {
  if (path == null || path == r'$' || path == '') return value;
  var current = value;
  for (final part in path.toString().split('.')) {
    if (current is Map) {
      current = current[part];
    } else {
      return null;
    }
  }
  return current;
}

bool _includes(Object? value, Object? expected) {
  if (value is List) {
    return value.any((item) => _matchesSubset(item, expected));
  }
  return _matchesSubset(value, expected);
}

bool _matchesSubset(Object? value, Object? expected) {
  if (expected is Map && value is Map) {
    return expected.entries.every(
      (entry) => _deepEquals(value[entry.key], entry.value),
    );
  }
  return _deepEquals(value, expected);
}

bool _deepEquals(Object? left, Object? right) =>
    jsonEncode(left) == jsonEncode(right);

Object? _fieldOrSelf(Object? payload, String field) {
  final map = _asMap(payload);
  return map[field] ?? payload;
}

ActionCommand _actionFromJson(Object? value) {
  final map = _asMap(value);
  final type = _actionType(map['type']);
  return ActionCommand(
    type: type,
    target:
        map['target'] == null
            ? _tapPointTarget(type, map)
            : _targetFromJson(map['target']),
    networkConditions:
        type == OperatorActionType.setNetworkConditions
            ? _networkConditionsFromJson(map['conditions'])
            : null,
    to: type == OperatorActionType.supplyMedia ? _mediaStandIn(map) : null,
    media:
        type == OperatorActionType.supplyMedia
            ? _suppliedMediaFromJson(map)
            : null,
    startIn: type == OperatorActionType.supplyMedia ? _mediaStartIn(map) : null,
    count: _pressesInARow(type) ? _pressCount(map) : null,
    interval: _pressesInARow(type) ? _pressInterval(map) : null,
    text: map['text']?.toString(),
    clearFirst: map['clearFirst'] as bool?,
    focusTarget: map['focusTarget'] as bool?,
    modifiers: _list(map['modifiers']).map((item) => item.toString()).toList(),
    source: map['source'] == null ? null : _targetFromJson(map['source']),
    destination:
        map['destination'] == null ? null : _targetFromJson(map['destination']),
    start: map['start'] == null ? null : _targetFromJson(map['start']),
    gesture: map['gesture']?.toString(),
    distancePx:
        map['distancePx'] is num ? (map['distancePx'] as num).toDouble() : null,
    duration:
        map['durationMs'] is num
            ? Duration(milliseconds: (map['durationMs'] as num).round())
            : null,
    direction: map['direction']?.toString(),
    amount: map['amount']?.toString(),
    container:
        map['container'] == null ? null : _targetFromJson(map['container']),
    alignment: map['alignment']?.toString(),
    role: map['role']?.toString(),
    maxSteps: map['maxSteps'] is num ? (map['maxSteps'] as num).round() : null,
    routeName: map['routeName']?.toString(),
    path: map['path']?.toString(),
    params: _jsonMap(map['params']),
    mode: map['mode']?.toString(),
    until: map['until'] == null ? null : _waitConditionFromJson(map['until']),
    timeout:
        map['timeoutMs'] is num
            ? Duration(milliseconds: (map['timeoutMs'] as num).round())
            : null,
    reason: map['reason']?.toString(),
    message: map['message']?.toString(),
    options: _list(map['options']).map((item) => item.toString()).toList(),
    payload: map['payload'],
    url: map['url']?.toString(),
    method: map['method']?.toString(),
    headers: _stringMap(map['headers']),
    match:
        map['match'] == null ? null : _networkMockMatchFromJson(map['match']),
    response:
        map['response'] == null
            ? null
            : _networkMockResponseFromJson(map['response']),
    firebase:
        map['firebase'] == null
            ? null
            : _firebaseMockMatchFromJson(map['firebase']),
    firebaseResponse:
        map['firebaseResponse'] == null
            ? null
            : _firebaseMockResponseFromJson(map['firebaseResponse']),
    ttl:
        map['ttlMs'] is num
            ? Duration(milliseconds: (map['ttlMs'] as num).round())
            : null,
    store: map['store']?.toString(),
    value: map['value'],
    area: map['area']?.toString(),
    key: map['key']?.toString(),
    namespace: map['namespace']?.toString(),
    metadataOnly: map['metadataOnly'] as bool?,
    storageSource: map['source']?.toString(),
    valueType: map['valueType']?.toString(),
    formId: map['formId']?.toString(),
    fields: _list(map['fields']).map(_formFieldPatchFromJson).toList(),
    stateMode: map['mode']?.toString(),
    scope: map['scope']?.toString(),
    actionId: map['actionId']?.toString(),
    deliveryId: map['deliveryId']?.toString(),
    purpose: map['purpose']?.toString(),
    risk: map['risk'] is num ? (map['risk'] as num).round() : null,
    expected:
        _list(map['expected']).map(_verificationConditionFromJson).toList(),
  );
}

FormFieldPatch _formFieldPatchFromJson(Object? value) {
  final map = _asMap(value);
  return FormFieldPatch(
    id: map['id']?.toString(),
    name: map['name']?.toString(),
    value: map['value'],
    checked: map['checked'] as bool?,
    selected: map['selected'] as bool?,
    errors: _list(map['errors']).map((item) => item.toString()).toList(),
  );
}

NetworkMockMatch _networkMockMatchFromJson(Object? value) {
  final map = _asMap(value);
  return NetworkMockMatch(
    method: map['method']?.toString(),
    url: map['url']?.toString(),
    urlContains: map['urlContains']?.toString(),
    urlPattern: map['urlPattern']?.toString(),
    path: map['path']?.toString(),
    pathContains: map['pathContains']?.toString(),
    pathPattern: map['pathPattern']?.toString(),
    query: _jsonMap(map['query']),
    headers: _stringMap(map['headers']),
  );
}

NetworkMockResponse _networkMockResponseFromJson(Object? value) {
  final map = _asMap(value);
  final error = _asMap(map['error']);
  return NetworkMockResponse(
    status: map['status'] is num ? (map['status'] as num).round() : 200,
    headers: _stringMap(map['headers']),
    body: map['body'],
    delay:
        map['delayMs'] is num
            ? Duration(milliseconds: (map['delayMs'] as num).round())
            : null,
    error:
        error.isEmpty
            ? null
            : NetworkError(
              type: error['type']?.toString() ?? 'MockNetworkError',
              message: error['message']?.toString() ?? 'Mock network error',
              retryable: true,
            ),
  );
}

ElementTarget _targetFromJson(Object? value) {
  final map = _asMap(value);
  return ElementTarget(
    id: map['id']?.toString(),
    role: map['role']?.toString(),
    label: map['label']?.toString(),
    text: map['text']?.toString(),
    selector: map['selector']?.toString(),
    point: map['point'] == null ? null : _fallbackPointFromJson(map['point']),
    listContext:
        map['listContext'] == null
            ? null
            : _listContextFromJson(map['listContext']),
    fallbackBounds:
        map['fallbackBounds'] == null
            ? null
            : _fallbackPointFromJson(map['fallbackBounds']),
    confidence:
        map['confidence'] is num ? (map['confidence'] as num).toDouble() : null,
    observationTargetRef:
        map['observationTargetRef'] == null
            ? null
            : _flutterObservationTargetRefFromJson(map['observationTargetRef']),
  );
}

FlutterObservationTargetRef _flutterObservationTargetRefFromJson(
  Object? value,
) {
  final map = _asMap(value);
  return FlutterObservationTargetRef(
    version: map['version']?.toString() ?? '',
    ticketId: map['ticketId']?.toString() ?? '',
    snapshotId: map['snapshotId']?.toString() ?? '',
  );
}

ListContextTarget _listContextFromJson(Object? value) {
  final map = _asMap(value);
  return ListContextTarget(
    listId: map['listId']?.toString(),
    itemText: map['itemText']?.toString(),
    itemIndex:
        map['itemIndex'] is num ? (map['itemIndex'] as num).round() : null,
  );
}

FallbackPoint _fallbackPointFromJson(Object? value) {
  final map = _asMap(value);
  return FallbackPoint(
    x: (map['x'] as num?)?.toDouble() ?? 0,
    y: (map['y'] as num?)?.toDouble() ?? 0,
  );
}

FirebaseMockMatch _firebaseMockMatchFromJson(Object? value) {
  final map = _asMap(value);
  return FirebaseMockMatch(
    service: map['service']?.toString() ?? '',
    operation: map['operation']?.toString() ?? '',
    path: map['path']?.toString(),
    pathContains: map['pathContains']?.toString(),
    pathPattern: map['pathPattern']?.toString(),
    name: map['name']?.toString(),
    nameContains: map['nameContains']?.toString(),
    namePattern: map['namePattern']?.toString(),
    bucket: map['bucket']?.toString(),
    bucketContains: map['bucketContains']?.toString(),
    bucketPattern: map['bucketPattern']?.toString(),
    parameters: _jsonMap(map['parameters']),
  );
}

FirebaseMockResponse _firebaseMockResponseFromJson(Object? value) {
  final map = _asMap(value);
  final errorValue = map['error'];
  return FirebaseMockResponse(
    value: map['value'],
    delay:
        map['delayMs'] is num
            ? Duration(milliseconds: (map['delayMs'] as num).round())
            : null,
    error:
        errorValue is Map
            ? NetworkError(
              type: errorValue['type']?.toString() ?? 'FirebaseMockError',
              message: errorValue['message']?.toString() ?? '',
              retryable:
                  errorValue['retryable'] is bool
                      ? errorValue['retryable'] as bool
                      : null,
            )
            : null,
  );
}

WaitCondition _waitConditionFromJson(Object? value) {
  final map = _asMap(value);
  return WaitCondition(
    type: map['type']?.toString() ?? 'state',
    path: map['path']?.toString(),
    routeName: map['routeName']?.toString(),
    target: map['target'] == null ? null : _targetFromJson(map['target']),
    visible: map['visible'] as bool?,
    duration:
        map['durationMs'] is num
            ? Duration(milliseconds: (map['durationMs'] as num).round())
            : null,
    method: map['method']?.toString(),
    ok: map['ok'] as bool?,
    store: map['store']?.toString(),
    statePath: map['path']?.toString(),
    equals: map['equals'],
  );
}

VerificationCondition _verificationConditionFromJson(Object? value) {
  final map = _asMap(value);
  return VerificationCondition(
    source: _verificationSource(map['source']),
    target: map['target'] == null ? null : _targetFromJson(map['target']),
    textIncludes: map['textIncludes']?.toString(),
    labelIncludes: map['labelIncludes']?.toString(),
    visible: map['visible'] as bool?,
    store: map['store']?.toString(),
    path: map['path']?.toString(),
    equals: map['equals'],
    includes: map['includes'],
    method: map['method']?.toString(),
    status: map['status'] is num ? (map['status'] as num).round() : null,
    ok: map['ok'] as bool?,
    name: map['name']?.toString(),
    area: map['area']?.toString(),
    key: map['key']?.toString(),
    namespace: map['namespace']?.toString(),
    metadataOnly: map['metadataOnly'] as bool?,
    formId: map['formId']?.toString(),
    fieldId: map['fieldId']?.toString(),
    checked: map['checked'] as bool?,
    selected: map['selected'] as bool?,
    value: map['value'],
    errorsInclude: map['errorsInclude']?.toString(),
    absentLevel: map['absentLevel']?.toString(),
  );
}

JsonMap _snapshotToJson(AppSnapshot snapshot) => <String, Object?>{
  'snapshotId': snapshot.snapshotId,
  'timestamp': snapshot.timestamp.toIso8601String(),
  'app': <String, Object?>{
    'appId': snapshot.app.appId,
    'name': snapshot.app.name,
    'platform': _platformName(snapshot.app.platform),
    'framework': snapshot.app.framework,
    'version': snapshot.app.version,
    'environment': snapshot.app.environment.name,
  },
  'userSession': <String, Object?>{
    'authenticated': snapshot.userSession.authenticated,
    'role': snapshot.userSession.role,
    'locale': snapshot.userSession.locale,
    'permissions': snapshot.userSession.permissions,
  },
  'route': _routeToJson(snapshot.route),
  'ui': _uiToJson(snapshot.ui),
  'state': snapshot.state.map(_stateToJson).toList(),
  'forms': snapshot.forms.map(_formToJson).toList(),
  'network': <String, Object?>{
    'events': snapshot.network.events.map(_networkToJson).toList(),
  },
  'logs': snapshot.logs.map(_logToJson).toList(),
  'errors': snapshot.errors.map(_errorToJson).toList(),
  'dialogs': snapshot.dialogs.map(_dialogToJson).toList(),
  if (snapshot.storage != null) 'storage': _storageToJson(snapshot.storage!),
  if (snapshot.visual != null) 'visual': _visualToJson(snapshot.visual!),
  'capabilities': _capabilitiesToJson(snapshot.capabilities),
  'redactions': _redactionToJson(snapshot.redactions),
};

JsonMap _runtimeEventToJson(OperatorRuntimeEvent event) => <String, Object?>{
  'type': _runtimeEventTypeName(event.type),
  'sequence': event.sequence,
  'timestamp': event.timestamp.toIso8601String(),
  if (event.snapshotId != null) 'snapshotId': event.snapshotId,
  // The payload carries its own list, since hosts keep an event's payload.
  'payload': operatorReadableJson(_eventPayloadToJsonValue(event.payload)),
};

Object? _eventPayloadToJsonValue(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  if (value is DateTime) return value.toIso8601String();
  if (value is AppSnapshot) return _snapshotToJson(value);
  if (value is RouteState) return _routeToJson(value);
  if (value is RouteEntry) return _routeEntryToJson(value);
  if (value is UiTree) return _uiToJson(value);
  if (value is UiElement) return _elementToJson(value);
  if (value is StateStoreSnapshot) return _stateToJson(value);
  if (value is FormSnapshot) return _formToJson(value);
  if (value is FormFieldSnapshot) return _formFieldToJson(value);
  if (value is FormFieldPatch) return _formFieldPatchToJson(value);
  if (value is NetworkEvent) return _networkToJson(value);
  if (value is NetworkRequest) {
    return <String, Object?>{
      'method': value.method,
      'url': value.url,
      'path': value.path,
      'query': value.query,
      'headers': value.headers,
      'body': value.body,
    };
  }
  if (value is NetworkResponse) {
    return <String, Object?>{
      'status': value.status,
      'ok': value.ok,
      'headers': value.headers,
      'body': value.body,
    };
  }
  if (value is NetworkError) {
    return <String, Object?>{
      'type': value.type,
      'message': value.message,
      'retryable': value.retryable,
    };
  }
  if (value is LogEvent) return _logToJson(value);
  if (value is ErrorSnapshot) return _errorToJson(value);
  if (value is DialogState) return _dialogToJson(value);
  if (value is StorageSnapshot) return _storageToJson(value);
  if (value is StorageEntrySnapshot) return _storageEntryToJson(value);
  if (value is VisualSnapshot) return _visualToJson(value);
  if (value is VisualFrame) return _visualFrameToJson(value);
  if (value is VisualElementRegion) return _visualRegionToJson(value);
  if (value is VisualTextRegion) return _visualTextRegionToJson(value);
  if (value is ElementBounds) return _boundsToJson(value);
  if (value is OperatorCapabilities) return _capabilitiesToJson(value);
  if (value is RedactionReport) return _redactionToJson(value);
  if (value is List) return value.map(_eventPayloadToJsonValue).toList();
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _eventPayloadToJsonValue(entry.value),
    };
  }
  return value.toString();
}

JsonMap _routeToJson(RouteState route) => <String, Object?>{
  'current': _routeEntryToJson(route.current),
  'stack': route.stack.map(_routeEntryToJson).toList(),
  if (route.previous != null) 'previous': _routeEntryToJson(route.previous!),
};

JsonMap _routeEntryToJson(RouteEntry entry) => <String, Object?>{
  'name': entry.name,
  'path': entry.path,
  'screenClass': entry.screenClass,
  'title': entry.title,
  'params': entry.params,
};

JsonMap _uiToJson(UiTree ui) => <String, Object?>{
  'rootId': ui.rootId,
  'elements': ui.elements.map(_elementToJson).toList(),
  'visibleTexts': _visibleTextsForUi(ui),
  'focusedElementId': ui.focusedElementId,
  'viewport': <String, Object?>{
    'width': ui.viewport.width,
    'height': ui.viewport.height,
    'scrollX': ui.viewport.scrollX,
    'scrollY': ui.viewport.scrollY,
  },
};

JsonMap _elementToJson(UiElement element) => <String, Object?>{
  'id': element.id,
  'platformId': element.platformId,
  'role': element.role == null ? null : _uiRoleName(element.role!),
  'label': element.label,
  'text': element.text,
  'value': element.value,
  'hint': element.hint,
  'enabled': element.enabled,
  'visible': element.visible,
  'selected': element.selected,
  'checked': element.checked,
  'rendered': element.rendered,
  'inViewport': element.inViewport,
  if (element.bounds != null)
    'bounds': <String, Object?>{
      'x': element.bounds!.x,
      'y': element.bounds!.y,
      'width': element.bounds!.width,
      'height': element.bounds!.height,
    },
  'parentId': element.parentId,
  'children': element.children,
  'actions': element.actions,
  if (element.observationTargetRef != null)
    'observationTargetRef': _flutterObservationTargetRefToJson(
      element.observationTargetRef!,
    ),
  if (element.scrollOwner != null)
    'scrollOwner': _scrollOwnerToJson(element.scrollOwner!),
  'data': element.data,
  'confidence': element.confidence,
};

JsonMap _flutterObservationTargetRefToJson(
  FlutterObservationTargetRef reference,
) => <String, Object?>{
  'version': reference.version,
  'ticketId': reference.ticketId,
  'snapshotId': reference.snapshotId,
};

JsonMap _scrollOwnerToJson(UiScrollOwnerFacts owner) => <String, Object?>{
  'kind': owner.kind,
  'axes': owner.axes,
  'offset': <String, double>{'x': owner.offsetX, 'y': owner.offsetY},
  'maxOffset': <String, double>{'x': owner.maxOffsetX, 'y': owner.maxOffsetY},
  'canScroll': <String, bool>{
    'up': owner.canScrollUp,
    'down': owner.canScrollDown,
    'left': owner.canScrollLeft,
    'right': owner.canScrollRight,
  },
  'viewport': <String, double>{
    'width': owner.viewportWidth,
    'height': owner.viewportHeight,
  },
};

List<String> _visibleTextsForUi(UiTree ui) {
  final texts = <String>[];
  final seen = <String>{};
  for (final element in ui.elements) {
    if (!element.visible) continue;
    for (final value in <Object?>[
      element.label,
      element.text,
      element.value,
      element.hint,
    ]) {
      if (value is! String) continue;
      final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty || seen.contains(text)) continue;
      seen.add(text);
      texts.add(text);
      break;
    }
  }
  return List<String>.unmodifiable(texts);
}

JsonMap _stateToJson(StateStoreSnapshot state) => <String, Object?>{
  'source': _stateSourceName(state.source),
  'name': state.name,
  'value': state.value,
  'schema': state.schema,
  'confidence': state.confidence,
  'redacted': state.redacted,
};

JsonMap _formToJson(FormSnapshot form) => <String, Object?>{
  'id': form.id,
  'name': form.name,
  'route': form.route,
  'visible': form.visible,
  'enabled': form.enabled,
  'submitted': form.submitted,
  'fields': form.fields.map(_formFieldToJson).toList(),
  'confidence': form.confidence,
};

JsonMap _formFieldToJson(FormFieldSnapshot field) => <String, Object?>{
  'id': field.id,
  'name': field.name,
  'role': field.role,
  'label': field.label,
  'value': field.value,
  'placeholder': field.placeholder,
  'checked': field.checked,
  'selected': field.selected,
  'enabled': field.enabled,
  'visible': field.visible,
  'secure': field.secure,
  'required': field.required,
  'errors': field.errors,
  'confidence': field.confidence,
};

JsonMap _networkToJson(NetworkEvent event) => <String, Object?>{
  'id': event.id,
  'timestamp': event.timestamp.toIso8601String(),
  'request': <String, Object?>{
    'method': event.request.method,
    'url': event.request.url,
    'path': event.request.path,
    'query': event.request.query,
    'headers': event.request.headers,
    'body': event.request.body,
  },
  if (event.response != null)
    'response': <String, Object?>{
      'status': event.response!.status,
      'ok': event.response!.ok,
      'headers': event.response!.headers,
      'body': event.response!.body,
    },
  if (event.error != null)
    'error': <String, Object?>{
      'type': event.error!.type,
      'message': event.error!.message,
      'retryable': event.error!.retryable,
    },
  'tags': event.tags,
  'redacted': event.redacted,
};

JsonMap _logToJson(LogEvent log) => <String, Object?>{
  'id': log.id,
  'timestamp': log.timestamp.toIso8601String(),
  'level': log.level,
  'message': log.message,
  'source': _logSourceToJson(log.source),
  'data': log.data,
  'redacted': log.redacted,
};

String _logSourceToJson(OperatorLogSource source) {
  switch (source) {
    case OperatorLogSource.app:
      return 'app';
    case OperatorLogSource.operatorRuntime:
      return 'operator';
    case OperatorLogSource.network:
      return 'network';
    case OperatorLogSource.system:
      return 'system';
    case OperatorLogSource.unknown:
      return 'unknown';
  }
}

JsonMap _errorToJson(ErrorSnapshot error) => <String, Object?>{
  'id': error.id,
  'timestamp': error.timestamp.toIso8601String(),
  'type': error.type,
  'message': error.message,
  'stack': error.stack,
  'source': error.source,
  'handled': error.handled,
  'fatal': error.fatal,
  'data': error.data,
  'redacted': error.redacted,
};

JsonMap _dialogToJson(DialogState dialog) => <String, Object?>{
  'id': dialog.id,
  'role': dialog.role,
  'title': dialog.title,
  'message': dialog.message,
  'buttons': dialog.buttons,
  'visible': dialog.visible,
  'confidence': dialog.confidence,
};

JsonMap _storageToJson(StorageSnapshot storage) => <String, Object?>{
  'entries': storage.entries.map(_storageEntryToJson).toList(),
};

JsonMap _storageEntryToJson(StorageEntrySnapshot entry) => <String, Object?>{
  'area': entry.area,
  'key': entry.key,
  'value': entry.value,
  'valueType': entry.valueType,
  'sizeBytes': entry.sizeBytes,
  'namespace': entry.namespace,
  'source': entry.source,
  'updatedAt': entry.updatedAt?.toIso8601String(),
  'confidence': entry.confidence,
  'metadataOnly': entry.metadataOnly,
  'redacted': entry.redacted,
};

JsonMap _visualToJson(VisualSnapshot visual) => <String, Object?>{
  'capturedAt': visual.capturedAt.toIso8601String(),
  'source': visual.source,
  'frames': visual.frames.map(_visualFrameToJson).toList(),
  if (visual.captureTargets.isNotEmpty)
    'captureTargets':
        visual.captureTargets.map(_visualCaptureTargetToJson).toList(),
  'regions': visual.regions.map(_visualRegionToJson).toList(),
  'ocr': visual.ocr.map(_visualTextRegionToJson).toList(),
  'analysis': visual.analysis,
  'redacted': visual.redacted,
  'metadata': visual.metadata,
};

JsonMap _visualFrameToJson(VisualFrame frame) => <String, Object?>{
  'id': frame.id,
  if (frame.surfaceId != null) 'surfaceId': frame.surfaceId,
  if (frame.documentGeneration != null)
    'documentGeneration': frame.documentGeneration,
  if (frame.surfaceClip != null)
    'surfaceClip': _boundsToJson(frame.surfaceClip!),
  if (frame.surfaceScale != null)
    'surfaceScale': <String, Object?>{
      'x': frame.surfaceScale!.x,
      'y': frame.surfaceScale!.y,
    },
  'format': frame.format,
  'encoding': frame.encoding,
  'data': frame.data,
  'width': frame.width,
  'height': frame.height,
  'pixelRatio': frame.pixelRatio,
  'hash': frame.hash,
  'metadataOnly': frame.metadataOnly,
  'source': frame.source,
  'redacted': frame.redacted,
};

JsonMap _visualCaptureTargetToJson(VisualCaptureTarget target) =>
    <String, Object?>{
      'targetId': target.targetId,
      'kind': target.kind,
      if (target.documentGeneration != null)
        'documentGeneration': target.documentGeneration,
      'frameIds': target.frameIds,
      if (target.unavailableReason != null)
        'unavailableReason': target.unavailableReason,
      if (target.transportOmittedFrameCount != null)
        'transportOmittedFrameCount': target.transportOmittedFrameCount,
    };

JsonMap _visualRegionToJson(VisualElementRegion region) => <String, Object?>{
  'elementId': region.elementId,
  'role': region.role,
  'label': region.label,
  'text': region.text,
  if (region.bounds != null) 'bounds': _boundsToJson(region.bounds!),
  'parentId': region.parentId,
  'visible': region.visible,
  'confidence': region.confidence,
};

JsonMap _visualTextRegionToJson(VisualTextRegion region) => <String, Object?>{
  'text': region.text,
  if (region.bounds != null) 'bounds': _boundsToJson(region.bounds!),
  'confidence': region.confidence,
};

JsonMap _boundsToJson(ElementBounds bounds) => <String, Object?>{
  'x': bounds.x,
  'y': bounds.y,
  'width': bounds.width,
  'height': bounds.height,
};

JsonMap _capabilitiesToJson(OperatorCapabilities capabilities) =>
    <String, Object?>{
      'observes': capabilities.observes,
      'actions': capabilities.actions,
      'selectors': capabilities.selectors,
      'verification': capabilities.verification,
      'privacy': capabilities.privacy,
      'virtualization': capabilities.virtualization,
    };

JsonMap _redactionToJson(RedactionReport report) => <String, Object?>{
  'redacted': report.redacted,
  'fields': report.fields,
  'paths': report.paths,
};

JsonMap _actionResultToJson(ActionResult result) => <String, Object?>{
  'ok': result.ok,
  'action': _actionToJson(result.action),
  'message': result.message,
  if (result.error != null)
    'error': <String, Object?>{
      'type': result.error!.type,
      'message': result.error!.message,
      'retryable': result.error!.retryable,
    },
  if (result.data.isNotEmpty) 'data': result.data,
  'evidence': result.evidence.map(_verificationEvidenceToJson).toList(),
};

/// A `tap_point` names its view point at the top level; the SDK carries it on the target.
ElementTarget? _tapPointTarget(OperatorActionType type, JsonMap map) {
  final x = map['x'];
  final y = map['y'];
  if (type != OperatorActionType.tapPoint || x is! num || y is! num) return null;
  return ElementTarget(point: FallbackPoint(x: x.toDouble(), y: y.toDouble()));
}

/// The longest supply_media delay: words are due at most one hour after the clip arrives. A web
/// timer cannot wait longer than about 24 days and would fire at once.
const int _maxMediaStartInMs = 3600000;

/// The stand-in a supply_media file is for.
String _mediaStandIn(JsonMap map) {
  final to = map['to'];
  if (to != 'camera' && to != 'microphone') {
    throw const FormatException('supply_media to must be camera or microphone');
  }
  return to as String;
}

/// The file a supply_media carries, named by the sha256 the run's store gave it; null takes the
/// file back. Its bytes travel beside it as base64.
OperatorSuppliedMedia? _suppliedMediaFromJson(JsonMap map) {
  final media = map['media'];
  if (media == null) return null;
  final file = _asMap(media);
  final digest = file['digest'];
  final mediaType = file['mediaType'];
  final data = map['dataBase64'];
  if (digest is! String || mediaType is! String || data is! String) {
    throw const FormatException(
      'supply_media media needs its digest and mediaType, and the bytes as dataBase64',
    );
  }
  return OperatorSuppliedMedia(
    bytes: base64Decode(data),
    mediaId: digest,
    mediaType: mediaType,
  );
}

/// When the words are due: whole milliseconds up to an hour, for the microphone only.
Duration? _mediaStartIn(JsonMap map) {
  final raw = map['startInMs'];
  if (raw == null) return null;
  if (map['to'] != 'microphone' ||
      raw is! num ||
      raw != raw.roundToDouble() ||
      raw < 0 ||
      raw > _maxMediaStartInMs) {
    throw const FormatException(
      'supply_media startInMs must be whole milliseconds from 0 to $_maxMediaStartInMs, for the microphone only',
    );
  }
  return Duration(milliseconds: raw.toInt());
}

/// The most presses one tap, click or tap_point makes in a row.
const int _maxPressCount = 10;

/// The longest wait from one press's release to the next press.
const int _maxPressIntervalMs = 1000;

/// The actions that press, and so can press several times in a row: tap, click and tap_point.
bool _pressesInARow(OperatorActionType type) =>
    type == OperatorActionType.tap ||
    type == OperatorActionType.click ||
    type == OperatorActionType.tapPoint;

/// Presses in a row for a tap, click or tap_point; a count out of range refuses the whole action.
int? _pressCount(JsonMap map) {
  final raw = map['count'];
  if (raw == null) return null;
  if (raw is! num ||
      raw != raw.roundToDouble() ||
      raw < 1 ||
      raw > _maxPressCount) {
    throw const FormatException(
      'count must be a whole number from 1 to $_maxPressCount',
    );
  }
  return raw.toInt();
}

/// The wait from one press's release to the next; a wait out of range refuses the whole action.
Duration? _pressInterval(JsonMap map) {
  final raw = map['intervalMs'];
  if (raw == null) return null;
  if (raw is! num ||
      raw != raw.roundToDouble() ||
      raw < 0 ||
      raw > _maxPressIntervalMs) {
    throw const FormatException(
      'intervalMs must be whole milliseconds from 0 to $_maxPressIntervalMs',
    );
  }
  return Duration(milliseconds: raw.toInt());
}

/// Validated link conditions; a malformed field rejects the whole request instead of half-applying.
OperatorNetworkConditions _networkConditionsFromJson(Object? value) {
  final map = _asMap(value);
  num? number(String key, {bool positive = false}) {
    final raw = map[key];
    if (raw == null) return null;
    if (raw is! num || !raw.isFinite || raw < 0 || (positive && raw == 0)) {
      throw FormatException(
        'network conditions $key must be a ${positive ? 'positive' : 'non-negative'} number',
      );
    }
    return raw;
  }

  final offline = map['offline'];
  if (offline != null && offline is! bool) {
    throw const FormatException('network conditions offline must be true or false');
  }
  final failureRate = number('failureRate');
  if (failureRate != null && failureRate > 1) {
    throw const FormatException('network conditions failureRate must be between 0 and 1');
  }
  final failureStatus = number('failureStatus');
  if (failureStatus != null && (failureStatus < 100 || failureStatus > 599)) {
    throw const FormatException('network conditions failureStatus must be an HTTP status');
  }
  final seed = map['seed'];
  return OperatorNetworkConditions(
    offline: offline as bool?,
    latencyMs: number('latencyMs')?.round(),
    jitterMs: number('jitterMs')?.round(),
    downloadKbps: number('downloadKbps', positive: true)?.toDouble(),
    uploadKbps: number('uploadKbps', positive: true)?.toDouble(),
    failureRate: failureRate?.toDouble(),
    failureStatus: failureStatus?.round(),
    seed: seed == null ? null : seed.toString(),
  );
}

JsonMap _actionToJson(ActionCommand action) => <String, Object?>{
  'type': _actionTypeName(action.type),
  if (action.type == OperatorActionType.tapPoint && action.target?.point != null)
    ...<String, Object?>{
      'x': action.target!.point!.x,
      'y': action.target!.point!.y,
    },
  if (action.networkConditions != null)
    'conditions': action.networkConditions!.toJson(),
  if (action.target != null) 'target': _targetToJson(action.target!),
  'text': action.text,
  'clearFirst': action.clearFirst,
  'focusTarget': action.focusTarget,
  'modifiers': action.modifiers,
  if (action.source != null) 'source': _targetToJson(action.source!),
  if (action.destination != null)
    'destination': _targetToJson(action.destination!),
  if (action.start != null) 'start': _targetToJson(action.start!),
  'gesture': action.gesture,
  'distancePx': action.distancePx,
  if (action.duration != null) 'durationMs': action.duration!.inMilliseconds,
  'direction': action.direction,
  'amount': action.amount,
  if (action.container != null) 'container': _targetToJson(action.container!),
  'alignment': action.alignment,
  'role': action.role,
  'maxSteps': action.maxSteps,
  'routeName': action.routeName,
  'path': action.path,
  'params': action.params,
  'mode': action.mode,
  if (action.until != null) 'until': _waitConditionToJson(action.until!),
  if (action.timeout != null) 'timeoutMs': action.timeout!.inMilliseconds,
  'reason': action.reason,
  'message': action.message,
  'options': action.options,
  'payload': action.payload,
  'url': action.url,
  'method': action.method,
  'headers': action.headers,
  if (action.match != null) 'match': _networkMockMatchToJson(action.match!),
  if (action.response != null)
    'response': _networkMockResponseToJson(action.response!),
  if (action.firebase != null)
    'firebase': _firebaseMockMatchToJson(action.firebase!),
  if (action.firebaseResponse != null)
    'firebaseResponse': _firebaseMockResponseToJson(action.firebaseResponse!),
  if (action.ttl != null) 'ttlMs': action.ttl!.inMilliseconds,
  // The file is named, never sent back: its bytes stay in the app.
  if (action.type == OperatorActionType.supplyMedia) ...<String, Object?>{
    'to': action.to,
    'media':
        action.media == null
            ? null
            : <String, Object?>{
              'mediaId': action.media!.mediaId,
              'mediaType': action.media!.mediaType,
              'bytes': action.media!.bytes.length,
            },
    if (action.startIn != null) 'startInMs': action.startIn!.inMilliseconds,
  },
  if (action.count != null) 'count': action.count,
  if (action.interval != null) 'intervalMs': action.interval!.inMilliseconds,
  'store': action.store,
  'value': action.value,
  'area': action.area,
  'key': action.key,
  'namespace': action.namespace,
  'metadataOnly': action.metadataOnly,
  'source': action.storageSource,
  'valueType': action.valueType,
  'formId': action.formId,
  'fields': action.fields.map(_formFieldPatchToJson).toList(),
  'scope': action.scope,
  'actionId': action.actionId,
  'deliveryId': action.deliveryId,
  'purpose': action.purpose,
  'risk': action.risk,
  'expected': action.expected.map(_verificationConditionToJson).toList(),
};

JsonMap _waitConditionToJson(WaitCondition condition) => <String, Object?>{
  'type': condition.type,
  if ((condition.statePath ?? condition.path) != null)
    'path': condition.statePath ?? condition.path,
  if (condition.routeName != null) 'routeName': condition.routeName,
  if (condition.target != null) 'target': _targetToJson(condition.target!),
  if (condition.visible != null) 'visible': condition.visible,
  if (condition.duration != null)
    'durationMs': condition.duration!.inMilliseconds,
  if (condition.method != null) 'method': condition.method,
  if (condition.ok != null) 'ok': condition.ok,
  if (condition.store != null) 'store': condition.store,
  if (condition.equals != null) 'equals': condition.equals,
};

JsonMap _formFieldPatchToJson(FormFieldPatch field) => <String, Object?>{
  'id': field.id,
  'name': field.name,
  'value': field.value,
  'checked': field.checked,
  'selected': field.selected,
  'errors': field.errors,
};

JsonMap _networkMockMatchToJson(NetworkMockMatch match) => <String, Object?>{
  'method': match.method,
  'url': match.url,
  'urlContains': match.urlContains,
  'urlPattern': match.urlPattern,
  'path': match.path,
  'pathContains': match.pathContains,
  'pathPattern': match.pathPattern,
  'query': match.query,
  'headers': match.headers,
};

JsonMap _networkMockResponseToJson(NetworkMockResponse response) =>
    <String, Object?>{
      'status': response.status,
      'headers': response.headers,
      'body': response.body,
      if (response.delay != null) 'delayMs': response.delay!.inMilliseconds,
      if (response.error != null)
        'error': <String, Object?>{
          'type': response.error!.type,
          'message': response.error!.message,
        },
    };

JsonMap _firebaseMockMatchToJson(FirebaseMockMatch match) => <String, Object?>{
  'service': match.service,
  'operation': match.operation,
  'path': match.path,
  'pathContains': match.pathContains,
  'pathPattern': match.pathPattern,
  'name': match.name,
  'nameContains': match.nameContains,
  'namePattern': match.namePattern,
  'bucket': match.bucket,
  'bucketContains': match.bucketContains,
  'bucketPattern': match.bucketPattern,
  'parameters': match.parameters,
};

JsonMap _firebaseMockResponseToJson(FirebaseMockResponse response) =>
    <String, Object?>{
      'value': response.value,
      if (response.delay != null) 'delayMs': response.delay!.inMilliseconds,
      if (response.error != null)
        'error': <String, Object?>{
          'type': response.error!.type,
          'message': response.error!.message,
          'retryable': response.error!.retryable,
        },
    };

JsonMap _targetToJson(ElementTarget target) => <String, Object?>{
  'id': target.id,
  'role': target.role,
  'label': target.label,
  'text': target.text,
  'selector': target.selector,
  if (target.point != null)
    'point': <String, Object?>{'x': target.point!.x, 'y': target.point!.y},
  if (target.listContext != null)
    'listContext': <String, Object?>{
      'listId': target.listContext!.listId,
      'itemText': target.listContext!.itemText,
      'itemIndex': target.listContext!.itemIndex,
    },
  if (target.fallbackBounds != null)
    'fallbackBounds': <String, Object?>{
      'x': target.fallbackBounds!.x,
      'y': target.fallbackBounds!.y,
    },
  if (target.observationTargetRef != null)
    'observationTargetRef': _flutterObservationTargetRefToJson(
      target.observationTargetRef!,
    ),
  'confidence': target.confidence,
};

JsonMap _verificationEvidenceToJson(VerificationEvidence evidence) =>
    <String, Object?>{
      'source': _verificationSourceName(evidence.source),
      'condition': evidence.condition,
      'ok': evidence.ok,
      'detail': evidence.detail,
    };

JsonMap _verificationConditionToJson(VerificationCondition condition) =>
    <String, Object?>{
      'source': _verificationSourceName(condition.source),
      if (condition.target != null) 'target': _targetToJson(condition.target!),
      'textIncludes': condition.textIncludes,
      'labelIncludes': condition.labelIncludes,
      'visible': condition.visible,
      'store': condition.store,
      'path': condition.path,
      'equals': condition.equals,
      'includes': condition.includes,
      'method': condition.method,
      'status': condition.status,
      'ok': condition.ok,
      'name': condition.name,
      'area': condition.area,
      'key': condition.key,
      'namespace': condition.namespace,
      'metadataOnly': condition.metadataOnly,
      'formId': condition.formId,
      'fieldId': condition.fieldId,
      'checked': condition.checked,
      'selected': condition.selected,
      'value': condition.value,
      'errorsInclude': condition.errorsInclude,
      'absentLevel': condition.absentLevel,
    };

OperatorActionType _actionType(Object? value) {
  switch (value?.toString()) {
    case 'tap_point':
      return OperatorActionType.tapPoint;
    case 'tap':
      return OperatorActionType.tap;
    case 'click':
      return OperatorActionType.click;
    case 'type':
      return OperatorActionType.type;
    case 'clear':
      return OperatorActionType.clear;
    case 'hover':
      return OperatorActionType.hover;
    case 'key':
      return OperatorActionType.key;
    case 'drag':
      return OperatorActionType.drag;
    case 'touch':
      return OperatorActionType.touch;
    case 'scroll':
      return OperatorActionType.scroll;
    case 'scroll_into_view':
    case 'scrollIntoView':
      return OperatorActionType.scrollIntoView;
    case 'scroll_to':
    case 'scrollTo':
      return OperatorActionType.scrollTo;
    case 'navigate':
      return OperatorActionType.navigate;
    case 'wait':
      return OperatorActionType.wait;
    case 'capture_visual':
    case 'captureVisual':
      return OperatorActionType.captureVisual;
    case 'ask_user':
    case 'askUser':
      return OperatorActionType.askUser;
    case 'confirm':
      return OperatorActionType.confirm;
    case 'install_network_mock':
    case 'installNetworkMock':
      return OperatorActionType.installNetworkMock;
    case 'probe_network_virtualization':
    case 'probeNetworkVirtualization':
      return OperatorActionType.probeNetworkVirtualization;
    case 'install_firebase_mock':
    case 'installFirebaseMock':
      return OperatorActionType.installFirebaseMock;
    case 'probe_firebase_virtualization':
    case 'probeFirebaseVirtualization':
      return OperatorActionType.probeFirebaseVirtualization;
    case 'supply_media':
    case 'supplyMedia':
      return OperatorActionType.supplyMedia;
    case 'inject_state':
    case 'injectState':
      return OperatorActionType.injectState;
    case 'inject_storage':
    case 'injectStorage':
      return OperatorActionType.injectStorage;
    case 'clear_storage':
    case 'clearStorage':
      return OperatorActionType.clearStorage;
    case 'inject_form':
    case 'injectForm':
      return OperatorActionType.injectForm;
    case 'clear_simulation':
    case 'clearSimulation':
      return OperatorActionType.clearSimulation;
    case 'set_network_conditions':
    case 'setNetworkConditions':
      return OperatorActionType.setNetworkConditions;
    case 'clear_network_conditions':
    case 'clearNetworkConditions':
      return OperatorActionType.clearNetworkConditions;
  }
  throw ArgumentError('Unknown action type $value');
}

OperatorVerificationSource _verificationSource(Object? value) {
  switch (value?.toString()) {
    case 'action':
      return OperatorVerificationSource.action;
    case 'ui':
      return OperatorVerificationSource.ui;
    case 'state':
      return OperatorVerificationSource.state;
    case 'network':
      return OperatorVerificationSource.network;
    case 'route':
      return OperatorVerificationSource.route;
    case 'storage':
      return OperatorVerificationSource.storage;
    case 'form':
      return OperatorVerificationSource.form;
    case 'log':
      return OperatorVerificationSource.log;
  }
  throw ArgumentError('Unknown verification source $value');
}

String _actionTypeName(OperatorActionType type) {
  switch (type) {
    case OperatorActionType.tapPoint:
      return 'tap_point';
    case OperatorActionType.askUser:
      return 'ask_user';
    case OperatorActionType.captureVisual:
      return 'capture_visual';
    case OperatorActionType.installNetworkMock:
      return 'install_network_mock';
    case OperatorActionType.probeNetworkVirtualization:
      return 'probe_network_virtualization';
    case OperatorActionType.installFirebaseMock:
      return 'install_firebase_mock';
    case OperatorActionType.probeFirebaseVirtualization:
      return 'probe_firebase_virtualization';
    case OperatorActionType.supplyMedia:
      return 'supply_media';
    case OperatorActionType.injectState:
      return 'inject_state';
    case OperatorActionType.injectStorage:
      return 'inject_storage';
    case OperatorActionType.clearStorage:
      return 'clear_storage';
    case OperatorActionType.injectForm:
      return 'inject_form';
    case OperatorActionType.clearSimulation:
      return 'clear_simulation';
    case OperatorActionType.setNetworkConditions:
      return 'set_network_conditions';
    case OperatorActionType.clearNetworkConditions:
      return 'clear_network_conditions';
    case OperatorActionType.scrollIntoView:
      return 'scroll_into_view';
    case OperatorActionType.scrollTo:
      return 'scroll_to';
    default:
      return type.name;
  }
}

String _verificationSourceName(OperatorVerificationSource source) =>
    source.name;

String _runtimeEventTypeName(OperatorRuntimeEventType type) => type.name;

String _platformName(OperatorPlatform platform) =>
    platform == OperatorPlatform.reactNative ? 'react_native' : platform.name;

String _uiRoleName(OperatorUiRole role) =>
    role == OperatorUiRole.switchRole ? 'switch' : role.name;

String _stateSourceName(OperatorStateSource source) {
  switch (source) {
    case OperatorStateSource.setState:
      return 'set_state';
    case OperatorStateSource.changeNotifier:
      return 'change_notifier';
    case OperatorStateSource.valueNotifier:
      return 'value_notifier';
    case OperatorStateSource.inheritedWidget:
      return 'inherited_widget';
    default:
      return source.name;
  }
}

JsonMap _jsonMap(Object? value) => _asMap(value);

JsonMap _asMap(Object? value) {
  if (value is Map) {
    return value.map((key, child) => MapEntry(key.toString(), child));
  }
  return <String, Object?>{};
}

List<Object?> _list(Object? value) => value is List ? value : const <Object?>[];

Map<String, String> _stringMap(Object? value) {
  if (value is Map) {
    return value.map(
      (key, child) => MapEntry(key.toString(), child.toString()),
    );
  }
  return const <String, String>{};
}
