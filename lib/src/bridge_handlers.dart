import 'dart:async';
import 'dart:convert';

import 'adapter.dart';
import 'capture_diagnostics.dart';
import 'page_bridge_contract.dart';
import 'protocol.dart';
import 'wire_codec.dart';

const _maxRetainedBridgeEvents = 256;

/// Transport-neutral implementation of the Flutter bridge methods.
///
/// The page-local bridge (Flutter Web, called through the browser) and the
/// loopback HTTP bridge (native builds, called through `adb forward` or the
/// simulator's localhost) both delegate here, so the host sees one contract
/// whichever cable carries it. Inputs are accepted either as JSON text or as
/// already decoded JSON so each transport can pass what it has.
class OperatorFlutterBridgeHandlers {
  OperatorFlutterBridgeHandlers(this.adapter)
    : installationId =
          '${DateTime.now().toUtc().microsecondsSinceEpoch}-${identityHashCode(adapter)}' {
    _subscription = adapter.events.listen((event) {
      if (_closed) return;
      _events.add(event);
      if (_events.length > _maxRetainedBridgeEvents) {
        _events.removeRange(0, _events.length - _maxRetainedBridgeEvents);
      }
    });
  }

  final OperatorFlutterAdapter adapter;

  /// One id per installed bridge. A host that stored an id from an earlier
  /// installation must not drive a newer one with it.
  final String installationId;
  final List<OperatorRuntimeEvent> _events = <OperatorRuntimeEvent>[];
  StreamSubscription<OperatorRuntimeEvent>? _subscription;
  bool _closed = false;

  bool get closed => _closed;

  /// Methods every transport offers. A transport appends its own extras.
  List<String> get methods => <String>[
    'getHealth',
    'getSnapshot',
    'getCapabilities',
    'getEvents',
    'execute',
    'observedOperations',
    if (adapter.actuator is OperatorFlutterPointInspector) 'inspectPoint',
    if (adapter.actuator is OperatorFlutterHostKeyActuator) 'prepareKeyTarget',
  ];

  JsonMap health({List<String> transportMethods = const <String>[]}) =>
      <String, Object?>{
        'ok': !_closed,
        'protocolVersion': operatorFlutterPageBridgeProtocolVersion,
        'uiAuthority': 'flutter_runtime',
        'appId': adapter.operator.config.appId,
        'appVersion': adapter.operator.config.version,
        'framework': 'flutter',
        'platform': 'flutter',
        'installationId': installationId,
        'methods': <String>[...methods, ...transportMethods],
      };

  Future<JsonMap> snapshot(Object? request) {
    final map = _mapOf(request);
    final traceId = map['diagnosticTraceId'];
    return operatorCaptureTraceScope(
      traceId is String ? traceId : 'page-snapshot',
      () async {
        final snapshot = await operatorCaptureAsyncStage(
          'sdk.snapshot',
          () => adapter.operator.getSnapshot(
            issueActionTargets: map['issueActionTargets'] != false,
          ),
        );
        return operatorCaptureStage(
          'sdk.serialize',
          () => operatorSnapshotToJson(snapshot),
        );
      },
    );
  }

  Future<JsonMap> capabilities() async {
    final snapshot = await adapter.operator.getSnapshot(
      issueActionTargets: false,
    );
    return operatorCapabilitiesToJson(snapshot.capabilities);
  }

  JsonMap events(Object? request) {
    final map = _mapOf(request);
    final afterValue = map['afterSequence'];
    final afterSequence = afterValue is num ? afterValue.toInt() : 0;
    final selected = _events
        .where((event) => event.sequence > afterSequence)
        .map(operatorRuntimeEventToJson)
        .toList(growable: false);
    final lastSequence =
        _events.isEmpty ? afterSequence : _events.last.sequence;
    return <String, Object?>{
      'events': selected,
      'lastSequence': lastSequence,
      'overflow':
          _events.isNotEmpty && afterSequence < _events.first.sequence - 1,
    };
  }

  /// Health, snapshot and the events after `afterSequence` in one round trip:
  /// the shape the browser host assembles from three page calls.
  Future<JsonMap> capture(
    Object? request, {
    List<String> transportMethods = const <String>[],
  }) async {
    final map = _mapOf(request);
    return <String, Object?>{
      'health': health(transportMethods: transportMethods),
      'snapshot': await snapshot(map),
      'eventBatch': events(map),
    };
  }

  Future<JsonMap> execute(Object? actionJson) async {
    final action = operatorActionCommandFromEnvelopeJson(_decode(actionJson));
    final result = await adapter.execute(action);
    return operatorActionResultToJson(result);
  }

  /// Synchronous control validation precedes arming, so a rejection here is
  /// explicit, unlike a lost transport response with an unknown effect.
  JsonMap observedOperations(Object? requestJson) {
    try {
      if (_closed ||
          adapter.operator.config.environment ==
              OperatorEnvironment.production) {
        throw StateError('observed_operations_unavailable');
      }
      final request = Map<String, Object?>.from(_mapOf(requestJson));
      if (request['kind'] == 'arm' && adapter.operator.hasActiveFirebaseMocks) {
        throw StateError('observed_fault_conflicts_with_firebase_mock');
      }
      return adapter.operator.observedOperations.control(request);
    } catch (error) {
      return <String, Object?>{'rejected': true, 'error': error.toString()};
    }
  }

  JsonMap inspectPoint(Object? requestJson) {
    final inspector = adapter.actuator;
    if (_closed || inspector is! OperatorFlutterPointInspector) {
      throw StateError('point_inspection_unavailable');
    }
    final request = _decode(requestJson);
    if (request is! Map || request['x'] is! num || request['y'] is! num) {
      throw const FormatException('inspectPoint requires numeric x and y');
    }
    return (inspector as OperatorFlutterPointInspector).inspectPoint(
      (request['x'] as num).toDouble(),
      (request['y'] as num).toDouble(),
      scrollDirection: request['scrollDirection'] as String?,
    );
  }

  Future<JsonMap> prepareKeyTarget(Object? actionJson) async {
    final actuator = adapter.actuator;
    OperatorFlutterHostKeyActuator? hostKeyActuator;
    if (actuator is OperatorFlutterHostKeyActuator) {
      hostKeyActuator = actuator as OperatorFlutterHostKeyActuator;
    }
    final action = operatorActionCommandFromEnvelopeJson(_decode(actionJson));
    if (hostKeyActuator == null) {
      return operatorActionResultToJson(
        ActionResult(
          ok: false,
          action: action,
          error: const ActionError(
            type: 'flutter_host_key_unavailable',
            message:
                'The installed Flutter actuator cannot prepare exact browser key input',
          ),
        ),
      );
    }
    final result = await hostKeyActuator.prepareHostKey(
      action,
      adapter.operator,
    );
    return operatorActionResultToJson(result);
  }

  /// In-app rendering of the current frame. Native hosts use it as the camera
  /// the browser provided on the web; it cannot see platform views or the
  /// system keyboard, which the host may add from a device screenshot.
  Future<JsonMap> captureVisual(Object? request) async {
    if (_closed) throw StateError('visual_capture_unavailable');
    final map = _mapOf(request);
    final reason = map['reason'];
    final captured = await adapter.operator.captureVisualResult(
      reason is String && reason.isNotEmpty ? reason : 'bridge_capture_visual',
    );
    return <String, Object?>{
      'frames': operatorVisualFramesToJson(captured.frames),
      'captureTargets': operatorVisualCaptureTargetsToJson(
        captured.captureTargets,
      ),
    };
  }

  void close() {
    if (_closed) return;
    adapter.operator.observedOperations.clearAll();
    _closed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _events.clear();
  }

  static Object? _decode(Object? value) {
    if (value is String) {
      final text = value.trim();
      if (text.isEmpty) return const <String, Object?>{};
      return jsonDecode(text);
    }
    return value;
  }

  static Map<Object?, Object?> _mapOf(Object? value) {
    final decoded = _decode(value);
    return decoded is Map ? decoded : const <Object?, Object?>{};
  }
}
