import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'network_virtualization_probe.dart'
    if (dart.library.js_interop) 'network_virtualization_probe_web.dart';
import 'protocol.dart';
import 'runtime.dart';
import 'verifier.dart';

abstract class OperatorFlutterActuator {
  Future<ActionResult?> execute(
    ActionCommand command,
    OperatorFlutter operator,
  );
}

/// Optional Web-host handshake used only for targeted keyboard input. Flutter
/// owns exact widget identity/focus; the browser host owns the real key event.
abstract class OperatorFlutterHostKeyActuator {
  Future<ActionResult> prepareHostKey(
    ActionCommand command,
    OperatorFlutter operator,
  );
}

/// Optional read-only Web lookup. Coordinates are Flutter logical/page CSS
/// pixels; implementations must not dispatch input or change focus/selection.
abstract class OperatorFlutterPointInspector {
  JsonMap inspectPoint(double x, double y, {String? scrollDirection});
}

class OperatorFlutterAdapter {
  OperatorFlutterAdapter(
    this.operator, {
    OperatorFlutterActuator? actuator,
    OperatorVerifier? verifier,
  }) : actuator = actuator ?? DefaultOperatorFlutterActuator(),
       verifier = verifier ?? OperatorVerifier();

  final OperatorFlutter operator;
  final OperatorFlutterActuator actuator;
  final OperatorVerifier verifier;

  Future<AppSnapshot> getSnapshot() => operator.getSnapshot();

  Stream<AppSnapshot> get snapshots => operator.snapshots;

  Stream<OperatorRuntimeEvent> get events => operator.events;

  Future<ActionResult> execute(ActionCommand action) async {
    final delegated = await actuator.execute(action, operator);
    if (delegated != null) return delegated;

    if (action.type == OperatorActionType.askUser) {
      return ActionResult(
        ok: false,
        action: action,
        error: ActionError(
          type: 'user_input_required',
          message: action.message ?? 'User input required',
        ),
      );
    }

    if (action.type == OperatorActionType.confirm) {
      return ActionResult(ok: true, action: action, message: action.message);
    }

    return ActionResult(
      ok: false,
      action: action,
      error: ActionError(
        type: 'unsupported_action',
        message: 'No Flutter actuator handled ${action.type.name}',
      ),
    );
  }

  VerificationResult verify(VerificationRequest request) =>
      verifier.verify(request);
}

/// The media stand-in's take-back for a clear, or null without a stand-in. A stand-in that throws
/// is a failed receipt, like an integration whose network-conditions listener fails.
Future<ActionResult?> _takeBackMedia(
  OperatorFlutter operator,
  ActionCommand command,
) async {
  try {
    return await operator.runVirtualizationProbe('media', command);
  } catch (error) {
    return ActionResult(
      ok: false,
      action: command,
      error: ActionError(type: 'simulation_cleanup_failed', message: '$error'),
    );
  }
}

/// Whether an integration's network-conditions receipt reports that its part did not apply.
bool _integrationFailed(Map<String, Object?> receipt) {
  if (receipt['error'] != null) return true;
  final firestore = receipt['firestore'];
  final failures = firestore is Map ? firestore['failures'] : null;
  return failures is List && failures.isNotEmpty;
}

class DefaultOperatorFlutterActuator implements OperatorFlutterActuator {
  @override
  Future<ActionResult?> execute(
    ActionCommand command,
    OperatorFlutter operator,
  ) async {
    if (command.type == OperatorActionType.navigate) {
      final path = command.path;
      if (path == null) {
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'missing_route',
            message: 'Navigation path is required',
          ),
        );
      }
      operator.captureRoute(path: path, name: command.routeName);
      return ActionResult(
        ok: true,
        action: command,
        message: 'Navigated to $path',
      );
    }

    if (command.type == OperatorActionType.wait) {
      await _waitFor(command, operator);
      return ActionResult(
        ok: true,
        action: command,
        message: 'Wait condition satisfied',
      );
    }

    if (command.type == OperatorActionType.captureVisual) {
      final captured = await operator.captureVisualResult(
        command.reason ?? 'Explicit visual capture',
      );
      final frames = captured.frames;
      final pixelFrames = frames.where(_hasDeliverablePixels).toList();
      final observation = await operator.getSnapshot(
        refreshVisual: false,
        refreshProviders: false,
        visualFrames: frames,
        visualCaptureTargets: captured.captureTargets,
      );
      final visualCapture =
          observation.visual?.analysis['visualCapture'] as JsonMap? ??
          const <String, Object?>{};
      if (pixelFrames.isEmpty) {
        return ActionResult(
          ok: false,
          action: command,
          data: <String, Object?>{'visualCapture': visualCapture},
          error: const ActionError(
            type: 'visual_capture_unavailable',
            message:
                'Flutter visual capture produced no deliverable PNG, JPEG, or WebP frame',
            retryable: false,
          ),
        );
      }
      return ActionResult(
        ok: true,
        action: command,
        message: 'Captured ${pixelFrames.length} valid visual frame(s)',
        data: <String, Object?>{'visualCapture': visualCapture},
      );
    }

    if (command.type == OperatorActionType.installNetworkMock) {
      final blocked = _simulationBlocked(operator, command, 'Network mocking');
      if (blocked != null) return blocked;
      final match = command.match;
      final response = command.response;
      if (match == null || response == null) {
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'invalid_network_mock',
            message: 'Network mock requires match and response',
          ),
        );
      }
      final id = operator.installNetworkMock(match, response, ttl: command.ttl);
      return ActionResult(
        ok: true,
        action: command,
        message: 'Installed network mock $id',
      );
    }

    if (command.type == OperatorActionType.probeNetworkVirtualization) {
      return probeOperatorNetworkVirtualization(operator, command);
    }

    if (command.type == OperatorActionType.installFirebaseMock) {
      final blocked = _simulationBlocked(operator, command, 'Firebase mocking');
      if (blocked != null) return blocked;
      final match = command.firebase;
      final response = command.firebaseResponse;
      if (match == null || response == null) {
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'invalid_firebase_mock',
            message: 'Firebase mock requires firebase and firebaseResponse',
          ),
        );
      }
      final id = operator.installFirebaseMock(
        match,
        response,
        ttl: command.ttl,
      );
      return ActionResult(
        ok: true,
        action: command,
        message: 'Installed Firebase mock $id',
      );
    }

    if (command.type == OperatorActionType.probeFirebaseVirtualization) {
      final blocked = _simulationBlocked(
        operator,
        command,
        'Firebase virtualization probing',
      );
      if (blocked != null) return blocked;
      final result = await operator.runVirtualizationProbe('firebase', command);
      if (result != null) return result;
      return ActionResult(
        ok: false,
        action: command,
        error: const ActionError(
          type: 'firebase_virtualization_probe_unavailable',
          message:
              'No Firebase virtualization probe is registered. Install huntingdogs_firebase and enable OperatorFirebaseVirtualization.integration().',
        ),
      );
    }

    if (command.type == OperatorActionType.supplyMedia) {
      final blocked = _simulationBlocked(operator, command, 'Media supply');
      if (blocked != null) return blocked;
      final result = await operator.runVirtualizationProbe('media', command);
      if (result != null) return result;
      return ActionResult(
        ok: false,
        action: command,
        error: const ActionError(
          type: 'media_stand_in_unavailable',
          message:
              'No media stand-in is registered. Install huntingdogs_media and enable OperatorMediaVirtualization.integration().',
        ),
      );
    }

    if (command.type == OperatorActionType.injectState) {
      final blocked = _simulationBlocked(operator, command, 'State injection');
      if (blocked != null) return blocked;
      final store = command.store;
      if (store == null) {
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'invalid_state_injection',
            message: 'State injection requires a store name',
          ),
        );
      }
      operator.injectState(store, command.value, mode: command.stateMode);
      return ActionResult(
        ok: true,
        action: command,
        message: 'Injected state $store',
      );
    }

    if (command.type == OperatorActionType.injectStorage) {
      final blocked = _simulationBlocked(
        operator,
        command,
        'Storage injection',
      );
      if (blocked != null) return blocked;
      final area = command.area;
      final key = command.key;
      if (area == null || key == null) {
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'invalid_storage_injection',
            message: 'Storage injection requires area and key',
          ),
        );
      }
      final persisted = await _injectSharedPreferencesStorage(command);
      operator.injectStorage(
        area: area,
        key: key,
        value: command.value,
        namespace: command.namespace,
        valueType: command.valueType,
        metadataOnly: command.metadataOnly ?? false,
        source: command.storageSource,
        mode: command.mode,
      );
      return ActionResult(
        ok: true,
        action: command,
        message:
            'Injected storage $area:$key${persisted ? ' and persisted shared_preferences' : ''}',
      );
    }

    if (command.type == OperatorActionType.clearStorage) {
      final blocked = _simulationBlocked(operator, command, 'Storage clearing');
      if (blocked != null) return blocked;
      final persisted = await _clearSharedPreferencesStorage(command);
      operator.clearStorage(
        area: command.area,
        key: command.key,
        namespace: command.namespace,
      );
      return ActionResult(
        ok: true,
        action: command,
        message:
            'Cleared storage ${command.area ?? '*'}:${command.key ?? '*'}${persisted ? ' and persisted shared_preferences' : ''}',
      );
    }

    if (command.type == OperatorActionType.injectForm) {
      final blocked = _simulationBlocked(operator, command, 'Form injection');
      if (blocked != null) return blocked;
      operator.injectFormFields(command.fields, mode: command.mode);
      return ActionResult(
        ok: true,
        action: command,
        message: 'Injected ${command.fields.length} form field(s)',
      );
    }

    if (command.type == OperatorActionType.setNetworkConditions) {
      final blocked = _simulationBlocked(
        operator,
        command,
        'Network conditions',
      );
      if (blocked != null) return blocked;
      final conditions = command.networkConditions;
      if (conditions == null || conditions.isEmpty) {
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'network_conditions_invalid',
            message:
                'set_network_conditions needs offline, latencyMs, jitterMs, downloadKbps, uploadKbps or failureRate',
            retryable: false,
          ),
        );
      }
      // Integrations (such as Firebase clients, which do not use dart:io) apply their part
      // before this reports success, so the receipt is true when the next action runs.
      final integrations = await operator.applyNetworkConditions(conditions);
      final generation = operator.networkConditionsGeneration;
      return ActionResult(
        ok: true,
        action: command,
        message:
            conditions.offline == true
                ? 'App network set offline (generation $generation); a request that fails is the proof'
                : 'App network conditions set (generation $generation)',
        data: <String, Object?>{
          'generation': generation,
          'conditions': conditions.toJson(),
          'appliesTo': <String>[
            'dart_io_http',
            'dart_io_http_isolates',
            for (final receipt in integrations)
              ...(receipt['appliesTo'] as List<Object?>? ?? const <Object?>[])
                  .whereType<String>(),
          ],
          if (integrations.isNotEmpty) 'integrations': integrations,
        },
      );
    }

    if (command.type == OperatorActionType.clearNetworkConditions) {
      final integrations = await operator.applyNetworkConditions(null);
      return ActionResult(
        ok: true,
        action: command,
        message: 'App network conditions cleared',
        data: <String, Object?>{
          'generation': operator.networkConditionsGeneration,
          if (integrations.isNotEmpty) 'integrations': integrations,
        },
      );
    }

    if (command.type == OperatorActionType.clearSimulation) {
      // A full clear ends network conditions too: every integration restores its part (retrying one
      // that failed before), and the cleanup is confirmed only when each one reports success.
      final scope = command.scope ?? 'all';
      // Supplied media goes back first, while its records still belong to the test that ends. A
      // stand-in that fails reports it, and the rest of the cleanup still runs.
      final media =
          scope == 'all' || scope == 'media'
              ? await _takeBackMedia(operator, command)
              : null;
      final integrations =
          scope == 'all'
              ? await operator.applyNetworkConditions(null)
              : const <Map<String, Object?>>[];
      operator.clearSimulation(scope);
      final unrestored = integrations.where(_integrationFailed).toList();
      if (unrestored.isNotEmpty) {
        return ActionResult(
          ok: false,
          action: command,
          error: ActionError(
            type: 'simulation_cleanup_failed',
            message:
                media == null || media.ok
                    ? 'An app integration did not restore its network conditions'
                    : 'An app integration did not restore its network conditions, and the media stand-in did not take its files back: ${media.error?.message ?? 'no reason given'}',
            retryable: false,
          ),
          data: <String, Object?>{
            'integrations': integrations,
            if (media != null) 'media': media.data,
          },
        );
      }
      if (media != null && !media.ok) {
        return ActionResult(
          ok: false,
          action: command,
          error: ActionError(
            type: 'simulation_cleanup_failed',
            message:
                'The media stand-in did not take its files back: ${media.error?.message ?? 'no reason given'}',
            retryable: false,
          ),
          data: <String, Object?>{
            if (integrations.isNotEmpty) 'integrations': integrations,
            'media': media.data,
          },
        );
      }
      return ActionResult(
        ok: true,
        action: command,
        message: 'Cleared simulation ${command.scope ?? 'all'}',
        data: <String, Object?>{
          if (integrations.isNotEmpty) 'integrations': integrations,
          if (media != null) 'media': media.data,
        },
      );
    }

    return null;
  }

  Future<bool> _injectSharedPreferencesStorage(ActionCommand command) async {
    if (!_isSharedPreferencesArea(command.area)) return false;
    final key = command.key;
    if (key == null) return false;

    try {
      Object? value = command.value;
      final preferences = SharedPreferencesAsync();
      if (command.mode == 'merge') {
        final existing = await preferences.getString(key);
        if (existing != null) {
          try {
            final decoded = jsonDecode(existing);
            if (decoded is Map && value is Map) {
              value = <String, Object?>{
                for (final entry in decoded.entries)
                  entry.key.toString(): entry.value,
                for (final entry in value.entries)
                  entry.key.toString(): entry.value,
              };
            }
          } catch (_) {
            // Existing value is not JSON, so replace it below.
          }
        }
      }

      if (value == null) {
        await preferences.remove(key);
      } else if (value is bool) {
        await preferences.setBool(key, value);
      } else if (value is int) {
        await preferences.setInt(key, value);
      } else if (value is double) {
        await preferences.setDouble(key, value);
      } else if (value is String) {
        await preferences.setString(key, value);
      } else if (value is List<String>) {
        await preferences.setStringList(key, value);
      } else {
        await preferences.setString(key, jsonEncode(value));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _clearSharedPreferencesStorage(ActionCommand command) async {
    if (!_isSharedPreferencesArea(command.area)) return false;
    final key = command.key;
    if (key == null) return false;
    try {
      await SharedPreferencesAsync().remove(key);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _isSharedPreferencesArea(String? area) {
    final normalized = area?.replaceAll('_', '').toLowerCase();
    return normalized == 'sharedpreferences';
  }

  Future<void> _waitFor(ActionCommand command, OperatorFlutter operator) async {
    final until = command.until;
    if (until == null) return;
    final timeout = command.timeout ?? const Duration(seconds: 2);
    if (until.type == 'network_event') {
      final path = until.path?.trim();
      if (path == null || path.isEmpty) {
        throw ArgumentError('network_event requires one exact non-empty path');
      }
      await operator.events
          .where((event) => event.type == OperatorRuntimeEventType.network)
          .map((event) => event.payload)
          .where((payload) => payload is NetworkEvent)
          .cast<NetworkEvent>()
          .firstWhere((event) => _networkEventMatchesWait(event, until))
          .timeout(timeout);
      return;
    }
    final started = DateTime.now();
    while (DateTime.now().difference(started) <= timeout) {
      final snapshot = await operator.getSnapshot();
      if (_conditionMet(until, snapshot)) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Timed out waiting for ${until.type}', timeout);
  }

  bool _conditionMet(WaitCondition condition, AppSnapshot snapshot) {
    if (condition.type == 'route') {
      return condition.path == null ||
          snapshot.route.current.path == condition.path;
    }
    if (condition.type == 'state') {
      return snapshot.state.any(
        (store) =>
            store.name == condition.store &&
            valueAtPath(store.value, condition.statePath ?? r'$') != null,
      );
    }
    return true;
  }
}

bool _hasDeliverablePixels(VisualFrame frame) {
  return operatorFlutterVisualFrameHasUsablePixels(frame);
}

bool _networkEventMatchesWait(NetworkEvent event, WaitCondition condition) {
  if (event.request.path != condition.path) return false;
  final method = condition.method;
  if (method != null &&
      event.request.method.toUpperCase() != method.toUpperCase()) {
    return false;
  }
  final ok = condition.ok;
  if (ok != null && event.response?.ok != ok) return false;
  return true;
}

ActionResult? _simulationBlocked(
  OperatorFlutter operator,
  ActionCommand command,
  String feature,
) {
  if (operator.config.environment != OperatorEnvironment.production)
    return null;
  return ActionResult(
    ok: false,
    action: command,
    error: ActionError(
      type: 'simulation_blocked',
      message: '$feature is only available in dev or staging',
    ),
  );
}
