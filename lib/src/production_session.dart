import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'adapter.dart';
import 'protocol.dart';
import 'runtime.dart';
import 'wire_codec.dart';

export 'action_registry.dart';
export 'wire_codec.dart';

typedef OperatorBundledAppMapLoader = FutureOr<Object?> Function();
typedef OperatorHttpClientFactory = HttpClient Function();

const _commandResultUploadAttempts = 3;
const _commandResultUploadRetryBaseDelay = Duration(milliseconds: 100);
const _defaultCommandPollWait = Duration(seconds: 1);
const _defaultOperatorRequestTimeout = Duration(seconds: 10);
const _localDevCommandExecutionTimeout = Duration(seconds: 20);
const _localDevCommandPollWait = Duration(milliseconds: 500);
const _localDevCommandResultUploadTimeout = Duration(seconds: 10);
const _localDevCommandRetryDelayMax = Duration(seconds: 2);
const _defaultContextPublishTimeout = Duration(seconds: 2);
const _remoteCommandRetryDelayMax = Duration(seconds: 30);
const _resultStreamHedgeDelay = Duration(milliseconds: 200);
const _resultStreamFlushTimeout = Duration(milliseconds: 750);

final class _OperatorControlPlaneHttpOverrides extends HttpOverrides {}

HttpClient _defaultOperatorHttpClientFactory() =>
    _OperatorControlPlaneHttpOverrides().createHttpClient(null);

Future<Map<String, Object?>> _operatorPostJsonInBackgroundIsolate(
  Map<String, Object?> input,
) async {
  final uri = Uri.parse(input['uri']! as String);
  final timeoutMs = input['timeoutMs']! as int;
  final timeout = Duration(milliseconds: timeoutMs);
  final body = input['body'];
  final token = input['token'] as String?;
  final sessionSecret = input['sessionSecret'] as String?;
  final resultCompletedAt = _parseIsoDate(input['resultCompletedAt']);
  final client = _defaultOperatorHttpClientFactory();
  final requestStartedAt = DateTime.now();
  try {
    final request = await client.openUrl('POST', uri).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      ContentType.json.mimeType,
    );
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (sessionSecret != null) {
      request.headers.set('x-operator-session-secret', sessionSecret);
    }
    final uploadStartedAt = DateTime.now();
    final timing = <String, Object?>{
      'resultTransport': 'post_isolate',
      'resultUploadIsolate': true,
      'clientOpenMs':
          uploadStartedAt.difference(requestStartedAt).inMilliseconds,
      'uploadStartedAt': uploadStartedAt.toUtc().toIso8601String(),
      if (resultCompletedAt != null)
        'completedToUploadStartMs':
            uploadStartedAt
                .toUtc()
                .difference(resultCompletedAt.toUtc())
                .inMilliseconds,
    };
    if (body is Map<String, Object?>) {
      final existing = body['clientTiming'];
      if (existing is Map<String, Object?>) {
        existing.addAll(timing);
      } else {
        body['clientTiming'] = timing;
      }
    }
    request.add(utf8.encode(operatorEncodeJson(body)));
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join().timeout(timeout);
    final decoded =
        text.trim().isEmpty
            ? <String, Object?>{}
            : jsonDecode(text) as Map<String, Object?>;
    return <String, Object?>{
      'status': response.statusCode,
      'body': decoded,
      'timing': timing,
    };
  } finally {
    client.close(force: true);
  }
}

DateTime? _parseIsoDate(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

class OperatorProductionSessionConfig {
  const OperatorProductionSessionConfig({
    required this.endpoint,
    required this.sessionId,
    required this.appId,
    this.userId,
    this.platform = 'flutter',
    this.appVersion,
    this.token,
    this.sessionSecret,
    this.deviceId,
    this.operatorControlConsent = false,
    this.approvedPurposes = const <String>[],
    this.consentExpiresAt,
    this.pollWait = const Duration(seconds: 1),
    this.contextStreamInterval = const Duration(seconds: 1),
    this.contextPublishTimeout = _defaultContextPublishTimeout,
    this.runtimeEventDebounce = const Duration(milliseconds: 250),
    this.requestTimeout = _defaultOperatorRequestTimeout,
    this.commandExecutionTimeout = const Duration(seconds: 8),
    this.commandResultUploadTimeout = const Duration(seconds: 3),
    this.appMapManifest,
    this.bundledAppMap,
    this.bundledAppMapLoader,
    this.appMapManifestAssetPath = 'assets/operator/appmap-manifest.json',
    this.appMapAssetPath = 'assets/operator/appmap.json',
    this.uploadBundledAppMapWhenMissing = true,
    this.controlClientFactory,
  });

  final Uri endpoint;
  final String sessionId;
  final String appId;
  final String? userId;
  final String platform;
  final String? appVersion;
  final String? token;
  final String? sessionSecret;
  final String? deviceId;
  final bool operatorControlConsent;
  final List<String> approvedPurposes;
  final DateTime? consentExpiresAt;
  final Duration pollWait;
  final Duration contextStreamInterval;
  final Duration contextPublishTimeout;
  final Duration runtimeEventDebounce;
  final Duration requestTimeout;
  final Duration commandExecutionTimeout;
  final Duration commandResultUploadTimeout;
  final OperatorAppMapManifest? appMapManifest;
  final Object? bundledAppMap;
  final OperatorBundledAppMapLoader? bundledAppMapLoader;
  final String? appMapManifestAssetPath;
  final String? appMapAssetPath;
  final bool uploadBundledAppMapWhenMissing;
  final OperatorHttpClientFactory? controlClientFactory;
}

class OperatorFlutterProductionSession {
  OperatorFlutterProductionSession({
    required this.adapter,
    required this.config,
    HttpClient? client,
    HttpClient? commandClient,
    HttpClient? resultClient,
    OperatorHttpClientFactory? resultClientFactory,
  }) : _client =
           client ??
           (config.controlClientFactory ?? _defaultOperatorHttpClientFactory)(),
       _commandClient =
           commandClient ??
           client ??
           (config.controlClientFactory ?? _defaultOperatorHttpClientFactory)(),
       _resultClientFactory =
           resultClientFactory ??
           config.controlClientFactory ??
           _defaultOperatorHttpClientFactory,
       _ownsResultClient =
           resultClient == null &&
           (resultClientFactory != null || client == null),
       _resultClient =
           resultClient ?? (resultClientFactory == null ? client : null),
       _useBackgroundResultPost =
           client == null &&
           commandClient == null &&
           resultClient == null &&
           resultClientFactory == null &&
           config.controlClientFactory == null;

  final OperatorFlutterAdapter adapter;
  final OperatorProductionSessionConfig config;
  final HttpClient _client;
  final HttpClient _commandClient;
  final OperatorHttpClientFactory _resultClientFactory;
  final bool _ownsResultClient;
  final bool _useBackgroundResultPost;
  HttpClient? _resultClient;
  bool _connected = false;
  bool _closed = false;
  Future<void>? _loop;
  Future<void>? _contextLoop;
  StreamSubscription<AppSnapshot>? _runtimeSnapshotSubscription;
  Timer? _runtimeSnapshotTimer;
  final Completer<void> _closeSignal = Completer<void>();
  int _consecutiveLoopFailures = 0;
  int _consecutiveSnapshotFailures = 0;
  DateTime? _lastSnapshotPublishedAt;
  bool _reportedSlowCommandPolling = false;
  bool _reportedLocalDevPollOverride = false;
  bool _reportedLocalDevExecutionTimeoutOverride = false;
  bool _reportedLocalDevResultTimeoutOverride = false;
  Future<void>? _activeSnapshotPublish;
  DateTime? _activeSnapshotPublishStartedAt;
  String? _activeSnapshotPublishReason;
  bool _pendingSnapshotPublish = false;
  final Map<String, _CompletedProductionCommand> _completedCommands =
      <String, _CompletedProductionCommand>{};
  final Map<String, Future<void>> _resultUploads = <String, Future<void>>{};
  HttpClientRequest? _resultStreamRequest;
  Future<HttpClientRequest>? _resultStreamOpening;
  bool _resultStreamSupported = false;
  bool _resultStreamUnavailable = false;

  Future<void> connect() async {
    if (_connected) return;
    final appMapManifest = await _resolveAppMapManifest();
    final connectResponse = await _requestJson(
      'POST',
      _sessionUri('connect'),
      body: <String, Object?>{
        'appId': config.appId,
        'userId': config.userId,
        'platform': config.platform,
        'appVersion': config.appVersion,
        'deviceId': config.deviceId,
        if (appMapManifest != null) 'appMapManifest': appMapManifest.toJson(),
        'consent': _consentPayload(
          operatorControl: config.operatorControlConsent,
          approvedPurposes: config.approvedPurposes,
          expiresAt: config.consentExpiresAt,
        ),
      },
    );
    await _applyConnectSetupActions(connectResponse);
    _resultStreamSupported = _connectSupportsResultStream(connectResponse);
    _resultStreamUnavailable = false;
    _connected = true;
    if (_resultStreamSupported && !_shouldUseResultStream) {
      adapter.operator.captureLog(
        'debug',
        'operator command result stream ignored; POST result upload remains primary',
        source: OperatorLogSource.operatorRuntime,
        data: const <String, Object?>{
          'reason': 'stream_delivery_has_no_server_ack',
          'resultPostAck': true,
        },
      );
    }
    if (_shouldUseResultStream) {
      unawaited(_warmResultStream());
    }
    if (_shouldUploadBundledAppMap(connectResponse) && appMapManifest != null) {
      await uploadAppMap(manifest: appMapManifest);
    }
    await publishSnapshot(reason: 'connect');
  }

  bool _connectSupportsResultStream(Map<String, Object?> response) {
    final transport = response['transport'];
    if (transport is Map<String, Object?>) {
      return transport['resultStream'] == true;
    }
    final session = response['session'];
    if (session is Map<String, Object?>) {
      final sessionTransport = session['transport'];
      if (sessionTransport is Map<String, Object?>) {
        return sessionTransport['resultStream'] == true;
      }
    }
    return false;
  }

  Future<void> _warmResultStream() async {
    try {
      await _ensureResultStream();
    } catch (error) {
      if (_closed) return;
      _resultStreamUnavailable = true;
      _closeResultStream();
      adapter.operator.captureLog(
        'debug',
        'operator command result stream warm-up failed; POST fallback active',
        source: OperatorLogSource.operatorRuntime,
        data: <String, Object?>{
          'failureSummary': _transportFailureSummary(error),
        },
      );
    }
  }

  Future<void> _applyConnectSetupActions(Map<String, Object?> response) async {
    final session = response['session'];
    final rawActions =
        session is Map<String, Object?> ? session['setupActions'] : null;
    if (rawActions is! Iterable) return;
    var applied = 0;
    for (final rawAction in rawActions) {
      try {
        final action = operatorActionCommandFromJson(rawAction);
        final result = await adapter
            .execute(action)
            .timeout(config.commandExecutionTimeout);
        if (result.ok) {
          applied += 1;
          continue;
        }
        adapter.operator.captureLog(
          'warn',
          'operator connect setup action failed',
          source: OperatorLogSource.operatorRuntime,
          data: <String, Object?>{
            'type': action.type.name,
            'errorType': result.error?.type,
            'message': result.error?.message ?? result.message,
          },
        );
      } catch (error, stack) {
        if (_closed) return;
        adapter.operator.captureLog(
          'warn',
          'operator connect setup action threw',
          source: OperatorLogSource.operatorRuntime,
          data: <String, Object?>{
            'failureSummary': _transportFailureSummary(error),
            'stack': stack.toString(),
          },
        );
      }
    }
    if (applied > 0) {
      adapter.operator.captureLog(
        'debug',
        'operator connect setup actions applied',
        source: OperatorLogSource.operatorRuntime,
        data: <String, Object?>{'count': applied},
      );
    }
  }

  Future<void> uploadAppMap({OperatorAppMapManifest? manifest}) async {
    final appMapManifest = manifest ?? await _resolveAppMapManifest();
    if (appMapManifest == null) {
      throw StateError('Operator AppMap upload requires an AppMap manifest.');
    }
    final appMap = await _resolveBundledAppMap();
    if (appMap == null) {
      throw StateError('Operator AppMap upload requires a bundled AppMap.');
    }
    await _requestJson(
      'POST',
      _sessionUri('appmap'),
      body: <String, Object?>{
        'manifest': appMapManifest.toJson(),
        'appMap': appMap,
      },
    );
  }

  Future<void> updateConsent({
    required bool operatorControl,
    Iterable<String> approvedPurposes = const <String>[],
    DateTime? expiresAt,
  }) async {
    await connect();
    await _requestJson(
      'POST',
      _sessionUri('consent'),
      body: <String, Object?>{
        'consent': _consentPayload(
          operatorControl: operatorControl,
          approvedPurposes: approvedPurposes,
          expiresAt: expiresAt,
        ),
      },
    );
  }

  Future<void> publishSnapshot({String reason = 'manual'}) async {
    final snapshot = await adapter.getSnapshot();
    final full = operatorSnapshotToJson(snapshot);
    try {
      await _requestJson(
        'POST',
        _sessionUri('snapshot'),
        body: <String, Object?>{
          'snapshot': full,
          'reason': reason,
          'clientPublishedAt': DateTime.now().toUtc().toIso8601String(),
        },
      );
      _lastSnapshotPublishedAt = DateTime.now().toUtc();
      adapter.operator.releaseVisualPixels(
        snapshot.visual?.frames ?? const <VisualFrame>[],
      );
      return;
    } catch (error) {
      if (_closed) rethrow;
      final compact = _compactPublishedSnapshotToJson(snapshot);
      await _requestJson(
        'POST',
        _sessionUri('snapshot'),
        body: <String, Object?>{
          'snapshot': compact,
          'reason': reason,
          'clientPublishedAt': DateTime.now().toUtc().toIso8601String(),
        },
      );
      _lastSnapshotPublishedAt = DateTime.now().toUtc();
      adapter.operator.releaseVisualPixels(
        snapshot.visual?.frames ?? const <VisualFrame>[],
      );
      adapter.operator.captureLog(
        'warn',
        'operator production full snapshot upload failed; compact snapshot uploaded',
        data: <String, Object?>{'error': error.toString()},
      );
    }
  }

  Future<void> _publishCompactSnapshot({required String reason}) async {
    final snapshot = await adapter.operator.getSnapshot(refreshVisual: false);
    final compact = _compactPublishedSnapshotToJson(snapshot);
    await _publishSnapshotPayload(
      snapshotJson: compact,
      reason: reason,
      timeout: _contextPublishTimeout,
    );
    adapter.operator.releaseVisualPixels(
      snapshot.visual?.frames ?? const <VisualFrame>[],
    );
  }

  Future<void> _publishSnapshotPayload({
    required JsonMap snapshotJson,
    required String reason,
    Duration? timeout,
  }) async {
    await _requestJson(
      'POST',
      _sessionUri('snapshot'),
      body: <String, Object?>{
        'snapshot': snapshotJson,
        'reason': reason,
        'clientPublishedAt': DateTime.now().toUtc().toIso8601String(),
      },
      timeout: timeout,
    );
    _lastSnapshotPublishedAt = DateTime.now().toUtc();
  }

  Future<ActionResult> _publishResult({
    required String commandId,
    required ActionResult result,
    required DateTime? completedAt,
    AppSnapshot? snapshot,
  }) async {
    _reportLocalDevResultTimeoutIfNeeded();
    final snapshotJson =
        snapshot == null ? null : _commandResultSnapshotToJson(snapshot);
    final resultForUpload =
        snapshot != null && _operatorFlutterSnapshotHasVisualData(snapshot)
            ? _withFlutterTransportVisualCaptureSummary(result, snapshotJson)
            : result;
    // The result lists its own numbers JSON cannot carry: the host keeps the
    // result, not the upload around it.
    final resultJson =
        operatorReadableJson(operatorActionResultToJson(resultForUpload))
            as JsonMap;
    for (var attempt = 1; attempt <= _commandResultUploadAttempts; attempt++) {
      final attemptStartedAt = DateTime.now();
      final completedToAttemptStartMs =
          completedAt == null
              ? null
              : attemptStartedAt.toUtc().difference(completedAt).inMilliseconds;
      adapter.operator.captureLog(
        'debug',
        'operator command result upload attempt started',
        source: OperatorLogSource.operatorRuntime,
        data: <String, Object?>{
          'commandId': commandId,
          'attempt': attempt,
          if (completedToAttemptStartMs != null)
            'completedToAttemptStartMs': completedToAttemptStartMs,
        },
      );
      final clientTiming = <String, Object?>{
        'uploadAttempt': attempt,
        'uploadAttemptStartedAt': attemptStartedAt.toUtc().toIso8601String(),
        if (completedToAttemptStartMs != null)
          'completedToAttemptStartMs': completedToAttemptStartMs,
      };
      try {
        await _publishResultPayload(
          commandId: commandId,
          resultJson: resultJson,
          snapshotJson: snapshotJson,
          completedAt: completedAt,
          clientTiming: clientTiming,
        );
        final attemptMs =
            DateTime.now().difference(attemptStartedAt).inMilliseconds;
        adapter.operator.captureLog(
          'debug',
          'operator command result upload attempt completed',
          source: OperatorLogSource.operatorRuntime,
          data: <String, Object?>{
            'commandId': commandId,
            'attempt': attempt,
            'attemptMs': attemptMs,
            if (clientTiming['clientOpenMs'] != null)
              'clientOpenMs': clientTiming['clientOpenMs'],
            if (clientTiming['completedToUploadStartMs'] != null)
              'completedToUploadStartMs':
                  clientTiming['completedToUploadStartMs'],
          },
        );
        if (attempt > 1) {
          adapter.operator.captureLog(
            'debug',
            'operator command result upload recovered',
            data: <String, Object?>{'commandId': commandId, 'attempt': attempt},
          );
        }
        return resultForUpload;
      } catch (error) {
        if (_closed || attempt == _commandResultUploadAttempts) rethrow;
        _recycleResultClientAfterFailure(error);
        final attemptMs =
            DateTime.now().difference(attemptStartedAt).inMilliseconds;
        adapter.operator.captureLog(
          'debug',
          'operator command result upload will retry',
          data: <String, Object?>{
            'commandId': commandId,
            'attempt': attempt,
            'attemptMs': attemptMs,
            'failureSummary': _transportFailureSummary(error),
            'retryable': true,
          },
        );
        await Future<void>.delayed(
          _commandResultUploadRetryBaseDelay * attempt,
        );
      }
    }
    return resultForUpload;
  }

  Future<void> _scheduleResultUpload({
    required String commandId,
    required ActionResult result,
    required DateTime? completedAt,
    AppSnapshot? snapshot,
  }) {
    final active = _resultUploads[commandId];
    if (active != null) return active;
    final task = () async {
      try {
        var resultSnapshot = snapshot;
        var resultForUpload = result;
        final deferSnapshot = _shouldDeferCommandResultSnapshot(result.action);
        if (resultSnapshot == null) {
          if (deferSnapshot) {
            resultForUpload = _withCommandResultSnapshotDeferredEvidence(
              result,
              commandId: commandId,
              reason:
                  'explicit_expected_conditions_delegate_observation_to_bridge',
            );
          } else {
            final captured = await _captureCommandResultSnapshot(
              commandId: commandId,
            );
            resultSnapshot = captured.snapshot;
            if (resultSnapshot != null) {
              resultForUpload = _withCommandResultSnapshotEvidence(
                result,
                commandId: commandId,
                snapshot: resultSnapshot,
                snapshotMs: captured.snapshotMs ?? 0,
              );
            }
          }
        }
        final uploadedResult = await _publishResult(
          commandId: commandId,
          result: resultForUpload,
          completedAt: completedAt,
          snapshot: resultSnapshot,
        );
        _releaseCompletedCommandVisualPixels(
          commandId: commandId,
          result: uploadedResult,
          sourceSnapshot: resultSnapshot,
        );
        if (deferSnapshot && resultSnapshot == null) {
          _rememberCompletedCommandResult(
            commandId: commandId,
            result: resultForUpload,
          );
          unawaited(
            _publishDeferredCommandResultSnapshot(commandId: commandId),
          );
        }
        adapter.operator.captureLog(
          'debug',
          'operator command result uploaded',
          data: <String, Object?>{
            'commandId': commandId,
            'ok': resultForUpload.ok,
            'errorType': resultForUpload.error?.type,
            'snapshotId': resultSnapshot?.snapshotId,
          },
        );
      } catch (error, stack) {
        if (_closed) return;
        adapter.operator.captureLog(
          'warn',
          'operator command result upload exhausted',
          source: OperatorLogSource.operatorRuntime,
          data: <String, Object?>{
            'commandId': commandId,
            'failureSummary': _transportFailureSummary(error),
            'retryable': true,
            'stack': stack.toString(),
          },
        );
      } finally {
        _resultUploads.remove(commandId);
      }
    }();
    _resultUploads[commandId] = task;
    return task;
  }

  bool _shouldDeferCommandResultSnapshot(ActionCommand action) {
    return action.expected.isNotEmpty;
  }

  void _rememberCompletedCommandResult({
    required String commandId,
    required ActionResult result,
  }) {
    final completed = _completedCommands[commandId];
    if (completed == null) return;
    _completedCommands[commandId] = _CompletedProductionCommand(
      result: result,
      snapshot: completed.snapshot,
      completedAt: completed.completedAt,
    );
  }

  void _releaseCompletedCommandVisualPixels({
    required String commandId,
    required ActionResult result,
    required AppSnapshot? sourceSnapshot,
  }) {
    final completed = _completedCommands[commandId];
    if (completed == null) return;
    if (sourceSnapshot != null) {
      adapter.operator.releaseVisualPixels(
        sourceSnapshot.visual?.frames ?? const <VisualFrame>[],
      );
    }
    _completedCommands[commandId] = _CompletedProductionCommand(
      result: result,
      snapshot:
          sourceSnapshot == null
              ? completed.snapshot
              : _operatorFlutterSnapshotWithoutVisualPixels(sourceSnapshot),
      completedAt: completed.completedAt,
    );
  }

  Future<void> _publishDeferredCommandResultSnapshot({
    required String commandId,
  }) async {
    final captured = await _captureCommandResultSnapshot(commandId: commandId);
    final snapshot = captured.snapshot;
    if (snapshot == null || _closed) return;
    try {
      await _publishSnapshotPayload(
        snapshotJson: _compactPublishedSnapshotToJson(snapshot),
        reason: 'command_result',
        timeout: _commandResultUploadTimeout,
      );
    } catch (error, stack) {
      if (_closed) return;
      adapter.operator.captureLog(
        'debug',
        'operator deferred command result snapshot upload failed',
        source: OperatorLogSource.operatorRuntime,
        data: <String, Object?>{
          'commandId': commandId,
          'failureSummary': _transportFailureSummary(error),
          'stack': stack.toString(),
        },
      );
    }
  }

  void _recycleResultClientAfterFailure(Object error) {
    if (!_ownsResultClient || _closed) return;
    _closeResultStream();
    _closeOwnedResultClient(force: true);
    _resultStreamUnavailable = false;
    adapter.operator.captureLog(
      'debug',
      'operator command result transport recycled',
      source: OperatorLogSource.operatorRuntime,
      data: <String, Object?>{
        'failureSummary': _transportFailureSummary(error),
      },
    );
  }

  void _closeOwnedResultClient({required bool force}) {
    if (!_ownsResultClient) return;
    final client = _resultClient;
    if (client == null) return;
    client.close(force: force);
    _resultClient = null;
  }

  void _closeResultStream() {
    final request = _resultStreamRequest;
    _resultStreamOpening = null;
    if (request == null) return;
    adapter.operator.suppressOperatorRuntimeZoneError(
      'Request has been aborted',
      ttl: const Duration(seconds: 10),
    );
    request.abort();
    _resultStreamRequest = null;
  }

  HttpClient _commandResultClient() {
    final existing = _resultClient;
    if (existing != null) return existing;
    final created = _resultClientFactory();
    _resultClient = created;
    return created;
  }

  Future<void> _publishResultPayload({
    required String commandId,
    required JsonMap resultJson,
    required JsonMap? snapshotJson,
    required DateTime? completedAt,
    JsonMap? clientTiming,
  }) async {
    final payload = <String, Object?>{
      'commandId': commandId,
      'result': resultJson,
      if (snapshotJson != null) 'snapshot': snapshotJson,
      if (clientTiming != null) 'clientTiming': clientTiming,
    };
    if (await _tryPublishResultStreamPayload(
      payload: payload,
      timing: clientTiming,
      completedAt: completedAt,
      postFallback:
          () => _publishResultPostPayload(
            payload: payload,
            timing: clientTiming,
            completedAt: completedAt,
            transport: 'post_hedge',
          ),
    )) {
      return;
    }
    await _publishResultPostPayload(
      payload: payload,
      timing: clientTiming,
      completedAt: completedAt,
      transport: 'post',
    );
  }

  Future<void> _publishResultPostPayload({
    required JsonMap payload,
    required JsonMap? timing,
    required DateTime? completedAt,
    required String transport,
  }) async {
    final effectiveTransport =
        _useBackgroundResultPost && transport == 'post'
            ? 'post_isolate'
            : transport;
    timing?['resultTransport'] = effectiveTransport;
    if (_useBackgroundResultPost && transport == 'post') {
      await _requestJsonInBackgroundIsolate(
        _sessionUri('results'),
        body: payload,
        timeout: _commandResultUploadTimeout,
        resultUploadTiming: timing,
        resultCompletedAt: completedAt,
      );
      return;
    }
    await _requestJson(
      'POST',
      _sessionUri('results'),
      body: payload,
      timeout: _commandResultUploadTimeout,
      client: _commandResultClient(),
      resultUploadTiming: timing,
      resultCompletedAt: completedAt,
    );
  }

  Future<void> _requestJsonInBackgroundIsolate(
    Uri uri, {
    required Object body,
    required Duration timeout,
    required JsonMap? resultUploadTiming,
    required DateTime? resultCompletedAt,
  }) async {
    final backgroundRequest = <String, Object?>{
      'uri': uri.toString(),
      'body': body,
      'timeoutMs': timeout.inMilliseconds,
      if (config.token != null) 'token': config.token,
      if (config.sessionSecret != null) 'sessionSecret': config.sessionSecret,
      if (resultCompletedAt != null)
        'resultCompletedAt': resultCompletedAt.toUtc().toIso8601String(),
    };
    final response = await Isolate.run<Map<String, Object?>>(
      () => _operatorPostJsonInBackgroundIsolate(backgroundRequest),
    ).timeout(timeout);
    final backgroundTiming = response['timing'];
    if (resultUploadTiming != null &&
        backgroundTiming is Map<String, Object?>) {
      resultUploadTiming.addAll(backgroundTiming);
    }
    final status = response['status'];
    if (status is int && (status < 200 || status >= 300)) {
      throw HttpException(
        'Operator production session failed: ${response['body']}',
        uri: uri,
      );
    }
  }

  Future<bool> _tryPublishResultStreamPayload({
    required JsonMap payload,
    required JsonMap? timing,
    required DateTime? completedAt,
    required Future<void> Function() postFallback,
  }) async {
    if (!_shouldUseResultStream || _resultStreamUnavailable || _closed) {
      return false;
    }
    final request = _resultStreamRequest;
    if (request == null) return false;

    Object? streamError;
    StackTrace? streamStackTrace;
    Object? postError;
    StackTrace? postStackTrace;
    var streamDelivered = false;
    var postDelivered = false;

    final streamFuture = () async {
      final requestStartedAt = DateTime.now();
      try {
        timing?['resultTransport'] = 'stream';
        _stampResultUploadTiming(
          timing: timing,
          requestStartedAt: requestStartedAt,
          completedAt: completedAt,
        );
        request.add(utf8.encode('${operatorEncodeJson(payload)}\n'));
        final timeout =
            _commandResultUploadTimeout < _resultStreamFlushTimeout
                ? _commandResultUploadTimeout
                : _resultStreamFlushTimeout;
        await _withRequestTimeout(
          request.flush(),
          timeout,
          'Operator POST ${_sessionUri('results-stream').path} stream flush',
          abortRequest: request,
        );
        streamDelivered = true;
        return const _ResultDeliveryAttempt('stream', true);
      } catch (error, stackTrace) {
        if (_closed) {
          return const _ResultDeliveryAttempt('stream', false);
        }
        streamError = error;
        streamStackTrace = stackTrace;
        final fallbackMs =
            DateTime.now().difference(requestStartedAt).inMilliseconds;
        timing?['streamFallbackMs'] = fallbackMs;
        timing?['streamFallbackReason'] = _transportFailureSummary(error);
        _resultStreamUnavailable = true;
        _closeResultStream();
        adapter.operator.captureLog(
          'debug',
          'operator command result stream unavailable; falling back to POST',
          source: OperatorLogSource.operatorRuntime,
          data: <String, Object?>{
            'failureSummary': _transportFailureSummary(error),
          },
        );
        return const _ResultDeliveryAttempt('stream', false);
      }
    }();

    final postFuture = () async {
      await Future<void>.delayed(_resultStreamHedgeDelay);
      if (_closed || streamDelivered) {
        return const _ResultDeliveryAttempt('post', false);
      }
      try {
        timing?['streamHedgeDelayMs'] = _resultStreamHedgeDelay.inMilliseconds;
        await postFallback();
        postDelivered = true;
        return const _ResultDeliveryAttempt('post', true);
      } catch (error, stackTrace) {
        postError = error;
        postStackTrace = stackTrace;
        return const _ResultDeliveryAttempt('post', false);
      }
    }();

    final first = await Future.any(<Future<_ResultDeliveryAttempt>>[
      streamFuture,
      postFuture,
    ]);
    if (first.delivered) return true;

    final second =
        first.channel == 'stream' ? await postFuture : await streamFuture;
    if (second.delivered || streamDelivered || postDelivered) return true;
    if (postError != null) {
      Error.throwWithStackTrace(
        postError!,
        postStackTrace ?? StackTrace.current,
      );
    }
    if (streamError != null && first.channel != 'stream') {
      Error.throwWithStackTrace(
        streamError!,
        streamStackTrace ?? StackTrace.current,
      );
    }
    return false;
  }

  Future<HttpClientRequest> _ensureResultStream() async {
    final existing = _resultStreamRequest;
    if (existing != null) return existing;
    final opening = _resultStreamOpening;
    if (opening != null) return opening;
    final task = () async {
      final request = await _requestStream(
        'POST',
        _sessionUri('results-stream'),
        timeout: _commandResultUploadTimeout,
        client: _commandResultClient(),
      );
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/x-ndjson',
      );
      _resultStreamRequest = request;
      return request;
    }();
    _resultStreamOpening = task;
    try {
      return await task;
    } finally {
      if (identical(_resultStreamOpening, task)) {
        _resultStreamOpening = null;
      }
    }
  }

  bool get _shouldUseResultStream =>
      _resultStreamSupported && _supportsAcknowledgedResultStreamClient;

  bool get _supportsAcknowledgedResultStreamClient => false;

  Future<_CommandResultSnapshotCapture> _captureCommandResultSnapshot({
    required String commandId,
  }) async {
    if (_closed) return const _CommandResultSnapshotCapture();
    try {
      final snapshotStartedAt = DateTime.now();
      final snapshot = await adapter.operator.getSnapshot(
        refreshVisual: false,
        refreshProviders: false,
      );
      final snapshotMs =
          DateTime.now().difference(snapshotStartedAt).inMilliseconds;
      final completed = _completedCommands[commandId];
      if (completed != null) {
        _completedCommands[commandId] = _CompletedProductionCommand(
          result: completed.result,
          snapshot: snapshot,
          completedAt: completed.completedAt,
        );
      }
      adapter.operator.captureLog(
        'debug',
        'operator command result snapshot prepared',
        data: <String, Object?>{
          'commandId': commandId,
          'snapshotId': snapshot.snapshotId,
          'snapshotMs': snapshotMs,
        },
      );
      return _CommandResultSnapshotCapture(
        snapshot: snapshot,
        snapshotMs: snapshotMs,
      );
    } catch (error) {
      if (_closed) return const _CommandResultSnapshotCapture();
      adapter.operator.captureLog(
        'warn',
        'operator command result snapshot preparation failed',
        data: <String, Object?>{
          'commandId': commandId,
          'failureSummary': _transportFailureSummary(error),
        },
      );
      return const _CommandResultSnapshotCapture();
    }
  }

  Future<T> _withRequestTimeout<T>(
    Future<T> future,
    Duration? timeout,
    String label, {
    HttpClientRequest? abortRequest,
  }) {
    if (timeout == null || timeout <= Duration.zero) return future;
    return future.timeout(
      timeout,
      onTimeout: () {
        if (abortRequest != null) {
          _drainLateOperatorTransportFailure(future);
          _abortOperatorRequest(abortRequest);
        }
        throw TimeoutException(
          '$label exceeded ${timeout.inMilliseconds}ms',
          timeout,
        );
      },
    );
  }

  void _drainLateOperatorTransportFailure<T>(Future<T> future) {
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (_closed) return;
          adapter.operator.captureLog(
            _isOperatorAbortError(error) ? 'debug' : 'warn',
            _isOperatorAbortError(error)
                ? 'operator late transport abort drained'
                : 'operator late transport error drained',
            source: OperatorLogSource.operatorRuntime,
            data: <String, Object?>{
              'failureSummary': _transportFailureSummary(error),
              if (!_isOperatorAbortError(error)) 'stack': stack.toString(),
            },
          );
        },
      ),
    );
  }

  Future<Map<String, Object?>> _requestJson(
    String method,
    Uri uri, {
    Object? body,
    Duration? timeout,
    HttpClient? client,
    JsonMap? resultUploadTiming,
    DateTime? resultCompletedAt,
  }) async {
    final httpClient = client ?? _client;
    final effectiveTimeout = timeout ?? _operatorRequestTimeout;
    final requestStartedAt = DateTime.now();
    final request = await _withRequestTimeout(
      httpClient.openUrl(method, uri),
      _remainingRequestTimeout(
        startedAt: requestStartedAt,
        timeout: effectiveTimeout,
        label: 'Operator $method ${uri.path} request',
      ),
      'Operator $method ${uri.path} open',
    );
    request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    if (config.token != null) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${config.token}',
      );
    }
    if (config.sessionSecret != null) {
      request.headers.set('x-operator-session-secret', config.sessionSecret!);
    }
    if (body != null) {
      _stampResultUploadTiming(
        timing: resultUploadTiming,
        requestStartedAt: requestStartedAt,
        completedAt: resultCompletedAt,
      );
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        ContentType.json.mimeType,
      );
      request.add(utf8.encode(operatorEncodeJson(body)));
    }
    final response = await _withRequestTimeout(
      request.close(),
      _remainingRequestTimeout(
        startedAt: requestStartedAt,
        timeout: effectiveTimeout,
        label: 'Operator $method ${uri.path} request',
      ),
      'Operator $method ${uri.path} close',
      abortRequest: request,
    );
    final text = await _withRequestTimeout(
      response.transform(utf8.decoder).join(),
      _remainingRequestTimeout(
        startedAt: requestStartedAt,
        timeout: effectiveTimeout,
        label: 'Operator $method ${uri.path} request',
      ),
      'Operator $method ${uri.path} response',
      abortRequest: request,
    );
    final decoded =
        text.trim().isEmpty
            ? <String, Object?>{}
            : jsonDecode(text) as Map<String, Object?>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Operator production session failed: $decoded',
        uri: uri,
      );
    }
    return decoded;
  }

  Future<HttpClientRequest> _requestStream(
    String method,
    Uri uri, {
    Duration? timeout,
    HttpClient? client,
  }) async {
    final httpClient = client ?? _client;
    final effectiveTimeout = timeout ?? _operatorRequestTimeout;
    final requestStartedAt = DateTime.now();
    final request = await _withRequestTimeout(
      httpClient.openUrl(method, uri),
      _remainingRequestTimeout(
        startedAt: requestStartedAt,
        timeout: effectiveTimeout,
        label: 'Operator $method ${uri.path} stream',
      ),
      'Operator $method ${uri.path} stream open',
    );
    request.bufferOutput = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/x-ndjson');
    if (config.token != null) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${config.token}',
      );
    }
    if (config.sessionSecret != null) {
      request.headers.set('x-operator-session-secret', config.sessionSecret!);
    }
    return request;
  }

  void _stampResultUploadTiming({
    required JsonMap? timing,
    required DateTime requestStartedAt,
    required DateTime? completedAt,
  }) {
    if (timing == null) return;
    final uploadStartedAt = DateTime.now();
    timing['clientOpenMs'] =
        uploadStartedAt.difference(requestStartedAt).inMilliseconds;
    timing['uploadStartedAt'] = uploadStartedAt.toUtc().toIso8601String();
    if (completedAt != null) {
      timing['completedToUploadStartMs'] =
          uploadStartedAt.toUtc().difference(completedAt).inMilliseconds;
    }
  }

  Duration? _remainingRequestTimeout({
    required DateTime startedAt,
    required Duration? timeout,
    required String label,
  }) {
    if (timeout == null || timeout <= Duration.zero) return timeout;
    final remaining = timeout - DateTime.now().difference(startedAt);
    if (remaining <= Duration.zero) {
      throw TimeoutException(
        '$label exceeded ${timeout.inMilliseconds}ms',
        timeout,
      );
    }
    return remaining;
  }

  String _transportFailureSummary(Object error) {
    if (error is TimeoutException) {
      final message = error.message;
      final duration = error.duration?.inMilliseconds ?? 'unknown';
      if (message == null || message.isEmpty) {
        return 'TimeoutException(${duration}ms)';
      }
      return 'TimeoutException(${duration}ms): $message';
    }
    if (error is HttpException) return 'HttpException';
    if (error is SocketException) return 'SocketException';
    return error.runtimeType.toString();
  }

  bool _isOperatorAbortError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('request has been aborted') ||
        message.contains('request aborted');
  }

  void _abortOperatorRequest(HttpClientRequest request) {
    adapter.operator.suppressOperatorRuntimeZoneError(
      'Request has been aborted',
      ttl: const Duration(seconds: 10),
    );
    adapter.operator.suppressOperatorRuntimeZoneError(
      'Request aborted',
      ttl: const Duration(seconds: 10),
    );
    request.abort();
  }

  Future<int> pumpOnce({Duration? wait}) async {
    await connect();
    final commandWait = wait ?? Duration.zero;
    final commandsPayload = await _requestJson(
      'GET',
      _sessionUri('commands').replace(
        queryParameters: <String, String>{
          'waitMs': '${commandWait.inMilliseconds}',
        },
      ),
      client: _commandClient,
      timeout: _commandPollRequestTimeout(commandWait),
    );
    final commands = _asList(commandsPayload['commands']);
    for (final item in commands) {
      await _executeEnvelope(_asMap(item));
    }
    return commands.length;
  }

  Future<void> start() {
    _reportSlowCommandPollingIfNeeded();
    _runtimeSnapshotSubscription ??= adapter.snapshots.listen((_) {
      _scheduleRuntimeSnapshotPublish();
    });
    _contextLoop ??= _runContextLoop();
    _loop ??= _runLoop();
    return _loop!;
  }

  void _reportSlowCommandPollingIfNeeded() {
    final effectivePollWait = _commandPollWait;
    if (_usesLocalDevBridge &&
        config.pollWait > effectivePollWait &&
        !_reportedLocalDevPollOverride) {
      _reportedLocalDevPollOverride = true;
      adapter.operator.captureLog(
        'info',
        'operator local dev command polling interval reduced',
        source: OperatorLogSource.operatorRuntime,
        data: <String, Object?>{
          'configuredPollWaitMs': config.pollWait.inMilliseconds,
          'effectivePollWaitMs': effectivePollWait.inMilliseconds,
          'endpointHost': config.endpoint.host,
        },
      );
    }
    _reportLocalDevResultTimeoutIfNeeded();
    _reportLocalDevExecutionTimeoutIfNeeded();
    if (_reportedSlowCommandPolling ||
        effectivePollWait <= const Duration(seconds: 2)) {
      return;
    }
    _reportedSlowCommandPolling = true;
    adapter.operator.captureLog(
      'warn',
      'operator command polling interval is high',
      source: OperatorLogSource.operatorRuntime,
      data: <String, Object?>{
        'pollWaitMs': config.pollWait.inMilliseconds,
        'effectivePollWaitMs': effectivePollWait.inMilliseconds,
        'recommendation':
            'Use OPERATOR_POLL_WAIT_MS=500 or a low pollWait for local AI QA sessions.',
      },
    );
  }

  void _reportLocalDevResultTimeoutIfNeeded() {
    final effectiveTimeout = _commandResultUploadTimeout;
    if (!_usesLocalDevBridge ||
        config.commandResultUploadTimeout >= effectiveTimeout ||
        _reportedLocalDevResultTimeoutOverride) {
      return;
    }
    _reportedLocalDevResultTimeoutOverride = true;
    adapter.operator.captureLog(
      'info',
      'operator local dev command result timeout increased',
      source: OperatorLogSource.operatorRuntime,
      data: <String, Object?>{
        'configuredTimeoutMs': config.commandResultUploadTimeout.inMilliseconds,
        'effectiveTimeoutMs': effectiveTimeout.inMilliseconds,
        'endpointHost': config.endpoint.host,
      },
    );
  }

  void _reportLocalDevExecutionTimeoutIfNeeded() {
    final effectiveTimeout = _commandExecutionTimeout;
    if (!_usesLocalDevBridge ||
        config.commandExecutionTimeout >= effectiveTimeout ||
        _reportedLocalDevExecutionTimeoutOverride) {
      return;
    }
    _reportedLocalDevExecutionTimeoutOverride = true;
    adapter.operator.captureLog(
      'info',
      'operator local dev command execution timeout increased',
      source: OperatorLogSource.operatorRuntime,
      data: <String, Object?>{
        'configuredTimeoutMs': config.commandExecutionTimeout.inMilliseconds,
        'effectiveTimeoutMs': effectiveTimeout.inMilliseconds,
        'endpointHost': config.endpoint.host,
      },
    );
  }

  Future<void> close() async {
    _closed = true;
    if (!_closeSignal.isCompleted) {
      _closeSignal.complete();
    }
    _runtimeSnapshotTimer?.cancel();
    _runtimeSnapshotTimer = null;
    await _runtimeSnapshotSubscription?.cancel();
    _runtimeSnapshotSubscription = null;
    _closeResultStream();
    _client.close(force: true);
    if (!identical(_commandClient, _client)) {
      _commandClient.close(force: true);
    }
    final resultClient = _resultClient;
    if (resultClient != null &&
        !identical(resultClient, _client) &&
        !identical(resultClient, _commandClient)) {
      resultClient.close(force: true);
    }
    _resultClient = null;
    _detachLoopsAfterClose();
  }

  void _detachLoopsAfterClose() {
    final loops = <Future<void>>[
      if (_loop != null) _loop!,
      if (_contextLoop != null) _contextLoop!,
    ];
    if (loops.isEmpty) return;
    for (final loop in loops) {
      unawaited(
        loop.catchError((Object _) {
          // Closing forcefully aborts in-flight transport. The loop has already
          // observed _closed, so these errors are teardown noise.
        }),
      );
    }
    _loop = null;
    _contextLoop = null;
  }

  @visibleForTesting
  Future<void> drainResultUploadsForTest() async {
    while (_resultUploads.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.from(_resultUploads.values));
    }
  }

  @visibleForTesting
  Duration get effectiveCommandPollWaitForTest => _commandPollWait;

  @visibleForTesting
  Duration get effectiveCommandExecutionTimeoutForTest =>
      _commandExecutionTimeout;

  @visibleForTesting
  Duration get effectiveCommandResultUploadTimeoutForTest =>
      _commandResultUploadTimeout;

  @visibleForTesting
  bool shouldReconnectAfterPollingFailureForTest(Object error) =>
      _shouldReconnectAfterPollingFailure(error);

  @visibleForTesting
  void reportCommandPollingHealthForTest() {
    _reportSlowCommandPollingIfNeeded();
  }

  @visibleForTesting
  Duration retryDelayForFailureCountForTest(int consecutiveFailures) =>
      _retryDelayForFailures(consecutiveFailures);

  Future<void> _runContextLoop() async {
    while (!_closed) {
      try {
        await connect();
        await _publishSnapshotSafely(reason: 'context_tick');
        _consecutiveSnapshotFailures = 0;
      } catch (error, stack) {
        if (_closed) break;
        _connected = false;
        _consecutiveSnapshotFailures += 1;
        adapter.operator.captureLog(
          'warn',
          'operator production context stream will retry after failure',
          data: <String, Object?>{
            'error': error.toString(),
            'failureCount': _consecutiveSnapshotFailures,
            'retryDelayMs': _retryDelay.inMilliseconds,
            if (_consecutiveSnapshotFailures <= 2) 'stack': stack.toString(),
          },
        );
      }
      if (_closed) break;
      await _delayOrClosed(_contextStreamDelay);
    }
  }

  Future<void> _runLoop() async {
    while (!_closed) {
      try {
        final pollStartedAt = DateTime.now();
        await connect();
        final commandCount = await pumpOnce(wait: _commandPollWait);
        if (_closed) break;
        await _publishHeartbeatSnapshot(commandCount: commandCount);
        _consecutiveLoopFailures = 0;
        await _delayRemainingPollInterval(
          startedAt: pollStartedAt,
          commandCount: commandCount,
        );
      } catch (error, stack) {
        if (_closed) break;
        if (_shouldReconnectAfterPollingFailure(error)) {
          _connected = false;
        }
        _consecutiveLoopFailures += 1;
        adapter.operator.captureLog(
          'warn',
          'operator production polling will retry after failure',
          data: <String, Object?>{
            'error': error.toString(),
            'failureCount': _consecutiveLoopFailures,
            'retryDelayMs': _retryDelay.inMilliseconds,
            'willReconnect': !_connected,
            if (_consecutiveLoopFailures <= 2) 'stack': stack.toString(),
          },
        );
        await _delayOrClosed(_retryDelay);
      }
    }
  }

  Future<void> _delayRemainingPollInterval({
    required DateTime startedAt,
    required int commandCount,
  }) async {
    if (commandCount > 0 || _closed || _commandPollWait <= Duration.zero) {
      return;
    }
    final elapsed = DateTime.now().difference(startedAt);
    final remaining = _commandPollWait - elapsed;
    if (remaining > Duration.zero) {
      await _delayOrClosed(remaining);
    }
  }

  Future<void> _delayOrClosed(Duration delay) async {
    if (_closed || delay <= Duration.zero) return;
    final completer = Completer<void>();
    Timer? timer;
    void complete() {
      timer?.cancel();
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    timer = Timer(delay, complete);
    _closeSignal.future.then((_) => complete());
    await completer.future;
  }

  Future<void> _publishHeartbeatSnapshot({required int commandCount}) async {
    if (_contextLoop != null) return;
    final lastPublishedAt = _lastSnapshotPublishedAt;
    final stale =
        lastPublishedAt == null ||
        DateTime.now().toUtc().difference(lastPublishedAt) >= _commandPollWait;
    if (commandCount > 0 && !stale) return;
    await _publishSnapshotSafely(reason: 'command_poll');
  }

  @visibleForTesting
  Future<void> publishRuntimeSnapshotForTest({
    String reason = 'runtime_event',
  }) {
    return _publishSnapshotSafely(reason: reason);
  }

  void _scheduleRuntimeSnapshotPublish() {
    if (_closed) return;
    final lastPublishedAt = _lastSnapshotPublishedAt;
    final now = DateTime.now().toUtc();
    final elapsed =
        lastPublishedAt == null ? null : now.difference(lastPublishedAt);
    final delay =
        elapsed == null || elapsed >= config.runtimeEventDebounce
            ? Duration.zero
            : config.runtimeEventDebounce - elapsed;
    _runtimeSnapshotTimer?.cancel();
    _runtimeSnapshotTimer = Timer(delay, () {
      _runtimeSnapshotTimer = null;
      unawaited(_publishSnapshotSafely(reason: 'runtime_event'));
    });
  }

  Future<void> _publishSnapshotSafely({required String reason}) {
    final active = _activeSnapshotPublish;
    if (active != null) {
      if (!_activeSnapshotPublishExpired) {
        _pendingSnapshotPublish = true;
        return active;
      }
      _detachStaleSnapshotPublish(active);
    }
    final task = _drainSnapshotPublishes(reason);
    _activeSnapshotPublish = task;
    _activeSnapshotPublishStartedAt = DateTime.now().toUtc();
    _activeSnapshotPublishReason = reason;
    task.whenComplete(() {
      if (identical(_activeSnapshotPublish, task)) {
        _activeSnapshotPublish = null;
        _activeSnapshotPublishStartedAt = null;
        _activeSnapshotPublishReason = null;
      }
    });
    return task;
  }

  Future<void> _drainSnapshotPublishes(String reason) async {
    var nextReason = reason;
    do {
      _pendingSnapshotPublish = false;
      try {
        final publish = _publishCompactSnapshot(reason: nextReason);
        await _withSnapshotPublishTimeout(publish, reason: nextReason);
        if (_consecutiveSnapshotFailures > 0) {
          adapter.operator.captureLog(
            'debug',
            'operator production snapshot stream upload recovered',
            source: OperatorLogSource.operatorRuntime,
            data: <String, Object?>{
              'failureCount': _consecutiveSnapshotFailures,
            },
          );
        }
        _consecutiveSnapshotFailures = 0;
      } catch (error) {
        if (_closed) return;
        _consecutiveSnapshotFailures += 1;
        adapter.operator.captureLog(
          _consecutiveSnapshotFailures >= 3 ? 'warn' : 'debug',
          'operator production snapshot stream upload failed',
          source: OperatorLogSource.operatorRuntime,
          data: <String, Object?>{
            'reason': nextReason,
            'error': error.toString(),
            'failureCount': _consecutiveSnapshotFailures,
            'retryable': _consecutiveSnapshotFailures < 3,
          },
        );
      }
      nextReason = 'runtime_event';
    } while (_pendingSnapshotPublish && !_closed);
  }

  bool get _activeSnapshotPublishExpired {
    final startedAt = _activeSnapshotPublishStartedAt;
    if (startedAt == null) return false;
    return DateTime.now().toUtc().difference(startedAt) >
        _contextPublishTimeout;
  }

  Future<void> _withSnapshotPublishTimeout(
    Future<void> publish, {
    required String reason,
  }) async {
    try {
      await publish.timeout(_contextPublishTimeout);
    } on TimeoutException {
      _drainLateSnapshotPublish(publish, reason: reason);
      rethrow;
    }
  }

  void _detachStaleSnapshotPublish(Future<void> active) {
    final reason = _activeSnapshotPublishReason ?? 'unknown';
    final startedAt = _activeSnapshotPublishStartedAt;
    _activeSnapshotPublish = null;
    _activeSnapshotPublishStartedAt = null;
    _activeSnapshotPublishReason = null;
    _pendingSnapshotPublish = false;
    _drainLateSnapshotPublish(active, reason: reason);
    adapter.operator.captureLog(
      'warn',
      'operator production snapshot stream detached stale publish',
      source: OperatorLogSource.operatorRuntime,
      data: <String, Object?>{
        'reason': reason,
        if (startedAt != null)
          'ageMs': DateTime.now().toUtc().difference(startedAt).inMilliseconds,
        'timeoutMs': _contextPublishTimeout.inMilliseconds,
      },
    );
  }

  void _drainLateSnapshotPublish(
    Future<void> publish, {
    required String reason,
  }) {
    unawaited(
      publish.then<void>(
        (_) {
          if (_closed) return;
          adapter.operator.captureLog(
            'debug',
            'operator late snapshot stream upload drained',
            source: OperatorLogSource.operatorRuntime,
            data: <String, Object?>{'reason': reason},
          );
        },
        onError: (Object error, StackTrace stack) {
          if (_closed) return;
          adapter.operator.captureLog(
            _isOperatorAbortError(error) ? 'debug' : 'warn',
            _isOperatorAbortError(error)
                ? 'operator late snapshot stream abort drained'
                : 'operator late snapshot stream error drained',
            source: OperatorLogSource.operatorRuntime,
            data: <String, Object?>{
              'reason': reason,
              'failureSummary': _transportFailureSummary(error),
              if (!_isOperatorAbortError(error)) 'stack': stack.toString(),
            },
          );
        },
      ),
    );
  }

  Duration get _contextStreamDelay {
    final interval = config.contextStreamInterval;
    if (interval <= Duration.zero) return const Duration(seconds: 1);
    return interval;
  }

  Duration get _contextPublishTimeout {
    final configured = config.contextPublishTimeout;
    if (configured <= Duration.zero) return _defaultContextPublishTimeout;
    return configured;
  }

  Duration get _commandPollWait {
    final configured =
        config.pollWait <= Duration.zero
            ? _defaultCommandPollWait
            : config.pollWait;
    if (_usesLocalDevBridge && configured > _localDevCommandPollWait) {
      return _localDevCommandPollWait;
    }
    return configured;
  }

  Duration get _commandExecutionTimeout {
    final configured = config.commandExecutionTimeout;
    if (_usesLocalDevBridge &&
        configured > Duration.zero &&
        configured < _localDevCommandExecutionTimeout) {
      return _localDevCommandExecutionTimeout;
    }
    return configured;
  }

  Duration get _commandResultUploadTimeout {
    final configured = config.commandResultUploadTimeout;
    if (_usesLocalDevBridge &&
        configured > Duration.zero &&
        configured < _localDevCommandResultUploadTimeout) {
      return _localDevCommandResultUploadTimeout;
    }
    return configured;
  }

  Duration get _operatorRequestTimeout {
    final configured = config.requestTimeout;
    if (configured <= Duration.zero) return _defaultOperatorRequestTimeout;
    return configured;
  }

  Duration _commandPollRequestTimeout(Duration wait) {
    final effectiveWait = wait <= Duration.zero ? Duration.zero : wait;
    return effectiveWait + _operatorRequestTimeout;
  }

  bool get _usesLocalDevBridge {
    if (adapter.operator.config.environment == OperatorEnvironment.production) {
      return false;
    }
    final host = config.endpoint.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  bool _shouldReconnectAfterPollingFailure(Object error) {
    return error.toString().toLowerCase().contains('session_not_found');
  }

  Duration get _retryDelay {
    return _retryDelayForFailures(_consecutiveLoopFailures);
  }

  Duration _retryDelayForFailures(int consecutiveFailures) {
    final exponent = math.min(consecutiveFailures - 1, 6);
    final maxDelay =
        _usesLocalDevBridge
            ? _localDevCommandRetryDelayMax
            : _remoteCommandRetryDelayMax;
    final milliseconds = math.min(
      maxDelay.inMilliseconds,
      250 * (1 << math.max(0, exponent)),
    );
    return Duration(milliseconds: milliseconds);
  }

  Future<void> _executeEnvelope(Map<String, Object?> envelope) async {
    final commandId = envelope['commandId']?.toString();
    if (commandId == null) {
      adapter.operator.captureLog(
        'error',
        'operator production command missing commandId',
        data: <String, Object?>{'envelopeKeys': envelope.keys.toList()},
      );
      return;
    }
    final completed = _completedCommands[commandId];
    if (completed != null) {
      adapter.operator.captureLog(
        'debug',
        'operator duplicate command redelivered; reuploading cached result',
        data: <String, Object?>{
          'commandId': commandId,
          'type': completed.result.action.type.name,
          'ok': completed.result.ok,
        },
      );
      unawaited(
        _scheduleResultUpload(
          commandId: commandId,
          result: completed.result,
          snapshot: completed.snapshot,
          completedAt: completed.completedAt,
        ),
      );
      return;
    }
    late final ActionCommand action;
    try {
      action = operatorActionCommandFromJson(envelope['action']);
    } catch (error, stack) {
      final fallback = _invalidCommandPlaceholder(envelope['action']);
      final result = ActionResult(
        ok: false,
        action: fallback,
        error: ActionError(
          type: 'invalid_command',
          message: error.toString(),
          retryable: false,
        ),
        evidence: <VerificationEvidence>[
          VerificationEvidence(
            source: OperatorVerificationSource.action,
            condition: 'command.invalid_payload',
            ok: false,
            detail:
                'The SDK polled a command but could not parse it. The command loop stayed alive and uploaded this failure result.',
          ),
        ],
      );
      _rememberCompletedCommand(
        commandId: commandId,
        result: result,
        snapshot: null,
        completedAt: DateTime.now().toUtc(),
      );
      adapter.operator.captureLog(
        'error',
        'operator production command invalid',
        data: <String, Object?>{
          'commandId': commandId,
          'error': error.toString(),
          'stack': stack.toString(),
        },
      );
      unawaited(
        _scheduleResultUpload(
          commandId: commandId,
          result: result,
          completedAt: _completedCommands[commandId]?.completedAt,
        ),
      );
      return;
    }
    final commandStartedAt = DateTime.now();
    final commandExecutionTimeout = _commandExecutionTimeout;
    late ActionResult result;
    AppSnapshot? commandResultSnapshot;
    int? commandResultSnapshotMs;
    Timer? commandWatchdog;
    adapter.operator.captureLog(
      'debug',
      'operator command received',
      data: <String, Object?>{
        'commandId': commandId,
        'type': action.type.name,
        'purpose': action.purpose,
      },
    );
    try {
      final executionStartedAt = DateTime.now();
      commandWatchdog = Timer(commandExecutionTimeout, () {
        adapter.operator.captureLog(
          'warn',
          'operator command execution still pending at timeout boundary',
          data: <String, Object?>{
            'commandId': commandId,
            'type': action.type.name,
            'purpose': action.purpose,
            'configuredTimeoutMs':
                config.commandExecutionTimeout.inMilliseconds,
            'effectiveTimeoutMs': commandExecutionTimeout.inMilliseconds,
          },
        );
      });
      final execution =
          action.type == OperatorActionType.captureVisual
              ? () async {
                final snapshotStartedAt = DateTime.now();
                final captured = await adapter.operator.captureVisualResult(
                  action.reason ?? 'Explicit visual capture',
                );
                // Bind structured state to only the frames returned by this provider invocation.
                // The retained store may contain stale pixels, and refreshing would capture twice.
                commandResultSnapshot = await adapter.operator.getSnapshot(
                  refreshVisual: false,
                  refreshProviders: false,
                  visualFrames: captured.frames,
                  visualCaptureTargets: captured.captureTargets,
                );
                commandResultSnapshotMs =
                    DateTime.now().difference(snapshotStartedAt).inMilliseconds;
                final analysis = commandResultSnapshot!.visual?.analysis;
                final hasUsablePixels = analysis?['hasUsablePixels'] == true;
                final validFrameCount = analysis?['validFrameCount'];
                final visualCapture =
                    analysis?['visualCapture'] as JsonMap? ??
                    const <String, Object?>{};
                return hasUsablePixels
                    ? ActionResult(
                      ok: true,
                      action: action,
                      data: <String, Object?>{'visualCapture': visualCapture},
                      message:
                          'Captured ${validFrameCount is num ? validFrameCount.toInt() : 1} valid visual frame(s)',
                    )
                    : ActionResult(
                      ok: false,
                      action: action,
                      data: <String, Object?>{'visualCapture': visualCapture},
                      error: const ActionError(
                        type: 'visual_capture_unavailable',
                        message:
                            'The explicit capture produced no valid PNG, JPEG, or WebP pixel frame',
                        retryable: false,
                      ),
                    );
              }()
              : adapter.execute(action);
      result = await execution.timeout(
        commandExecutionTimeout,
        onTimeout:
            () => ActionResult(
              ok: false,
              action: action,
              data:
                  action.type == OperatorActionType.captureVisual
                      ? <String, Object?>{
                        'visualCapture': operatorFlutterVisualCaptureSummary(
                          captureTargets: const <VisualCaptureTarget>[
                            VisualCaptureTarget(
                              targetId: 'runtime-visual-capture',
                              kind: 'provider',
                              frameIds: <String>[],
                              unavailableReason: 'visual_capture_timeout',
                            ),
                          ],
                        ),
                      }
                      : const <String, Object?>{},
              error: ActionError(
                type: 'execution_timeout',
                message:
                    'Operator command execution exceeded ${commandExecutionTimeout.inMilliseconds}ms inside the app.',
                retryable: true,
              ),
              evidence: <VerificationEvidence>[
                VerificationEvidence(
                  source: OperatorVerificationSource.action,
                  condition: 'command.execution_timeout',
                  ok: false,
                  detail:
                      'The SDK polled the command, but the in-app actuator did not complete before the client-side timeout.',
                ),
              ],
            ),
      );
      commandWatchdog.cancel();
      commandWatchdog = null;
      final executionMs =
          DateTime.now().difference(executionStartedAt).inMilliseconds;
      adapter.operator.captureLog(
        'debug',
        'operator command execution completed',
        data: <String, Object?>{
          'commandId': commandId,
          'type': action.type.name,
          'ok': result.ok,
          'errorType': result.error?.type,
          'executionMs': executionMs,
        },
      );
      result = _withCommandTimingEvidence(
        result,
        commandId: commandId,
        executionMs: executionMs,
        totalMs: DateTime.now().difference(commandStartedAt).inMilliseconds,
        snapshotMs: commandResultSnapshotMs,
      );
      if (commandResultSnapshot != null) {
        result = _withCommandResultSnapshotEvidence(
          result,
          commandId: commandId,
          snapshot: commandResultSnapshot!,
          snapshotMs: commandResultSnapshotMs ?? 0,
        );
      }
    } catch (error, stack) {
      commandWatchdog?.cancel();
      commandWatchdog = null;
      result = ActionResult(
        ok: false,
        action: action,
        data:
            action.type == OperatorActionType.captureVisual
                ? <String, Object?>{
                  'visualCapture': operatorFlutterVisualCaptureSummary(
                    captureTargets: const <VisualCaptureTarget>[
                      VisualCaptureTarget(
                        targetId: 'runtime-visual-capture',
                        kind: 'provider',
                        frameIds: <String>[],
                        unavailableReason: 'visual_capture_failed',
                      ),
                    ],
                  ),
                }
                : const <String, Object?>{},
        error: ActionError(
          type: 'execution_exception',
          message: error.toString(),
          retryable: true,
        ),
      );
      result = _withCommandTimingEvidence(
        result,
        commandId: commandId,
        executionMs: DateTime.now().difference(commandStartedAt).inMilliseconds,
        totalMs: DateTime.now().difference(commandStartedAt).inMilliseconds,
      );
      adapter.operator.captureLog(
        'error',
        'operator production command failed',
        data: <String, Object?>{
          'commandId': commandId,
          'error': error.toString(),
          'stack': stack.toString(),
        },
      );
    }
    _rememberCompletedCommand(
      commandId: commandId,
      result: result,
      snapshot: commandResultSnapshot,
      completedAt: DateTime.now().toUtc(),
    );
    unawaited(
      _scheduleResultUpload(
        commandId: commandId,
        result: result,
        snapshot: commandResultSnapshot,
        completedAt: _completedCommands[commandId]?.completedAt,
      ),
    );
    commandWatchdog?.cancel();
  }

  void _rememberCompletedCommand({
    required String commandId,
    required ActionResult result,
    required AppSnapshot? snapshot,
    required DateTime completedAt,
  }) {
    _completedCommands[commandId] = _CompletedProductionCommand(
      result: result,
      snapshot: snapshot,
      completedAt: completedAt,
    );
    while (_completedCommands.length > 200) {
      _completedCommands.remove(_completedCommands.keys.first);
    }
  }

  ActionResult _withCommandTimingEvidence(
    ActionResult result, {
    required String commandId,
    required int executionMs,
    required int totalMs,
    int? snapshotMs,
  }) {
    return ActionResult(
      ok: result.ok,
      action: result.action,
      message: result.message,
      error: result.error,
      data: result.data,
      evidence: <VerificationEvidence>[
        ...result.evidence,
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'command.client_timing',
          ok: true,
          detail: <String>[
            'commandId=$commandId',
            'executionMs=$executionMs',
            if (snapshotMs != null) 'snapshotMs=$snapshotMs',
            'totalMs=$totalMs',
          ].join('; '),
        ),
      ],
    );
  }

  ActionResult _withCommandResultSnapshotEvidence(
    ActionResult result, {
    required String commandId,
    required AppSnapshot snapshot,
    required int snapshotMs,
  }) {
    return ActionResult(
      ok: result.ok,
      action: result.action,
      message: result.message,
      error: result.error,
      data: result.data,
      evidence: <VerificationEvidence>[
        ...result.evidence,
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'command.result_snapshot',
          ok: true,
          detail:
              'commandId=$commandId; snapshotId=${snapshot.snapshotId}; snapshotMs=$snapshotMs; bundledWithResult=true',
        ),
      ],
    );
  }

  ActionResult _withCommandResultSnapshotDeferredEvidence(
    ActionResult result, {
    required String commandId,
    required String reason,
  }) {
    return ActionResult(
      ok: result.ok,
      action: result.action,
      message: result.message,
      error: result.error,
      data: result.data,
      evidence: <VerificationEvidence>[
        ...result.evidence,
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'command.result_snapshot_deferred',
          ok: true,
          detail:
              'commandId=$commandId; reason=$reason; bundledWithResult=false; the result lane acknowledged the command before slow snapshot capture, and the live stream/follow-up command_result snapshot owns observation truth.',
        ),
      ],
    );
  }

  ActionCommand _invalidCommandPlaceholder(Object? rawAction) {
    final rawType =
        rawAction is Map ? rawAction['type']?.toString() : rawAction.toString();
    return ActionCommand(
      type: OperatorActionType.wait,
      until: const WaitCondition(
        type: 'elapsed',
        duration: Duration(milliseconds: 1),
      ),
      timeout: const Duration(milliseconds: 1),
      purpose:
          rawType == null || rawType.isEmpty
              ? 'invalid_command_payload'
              : 'invalid_command_payload:$rawType',
      risk: 0,
    );
  }

  Future<OperatorAppMapManifest?> _resolveAppMapManifest() async {
    if (config.appMapManifest != null) return config.appMapManifest;
    final assetPath = config.appMapManifestAssetPath;
    if (assetPath == null || assetPath.isEmpty) return null;
    final loaded = await _loadJsonAsset(assetPath);
    if (loaded is Map) {
      return OperatorAppMapManifest.fromJson(
        loaded.map((key, value) => MapEntry(key.toString(), value as Object?)),
      );
    }
    return null;
  }

  Future<Object?> _resolveBundledAppMap() async {
    if (config.bundledAppMap != null) return config.bundledAppMap;
    final loader = config.bundledAppMapLoader;
    if (loader != null) return loader();
    final assetPath = config.appMapAssetPath;
    if (assetPath == null || assetPath.isEmpty) return null;
    return _loadJsonAsset(assetPath);
  }

  Future<Object?> _loadJsonAsset(String assetPath) async {
    try {
      final text = await rootBundle.loadString(assetPath);
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  bool _shouldUploadBundledAppMap(Map<String, Object?> connectResponse) {
    if (!config.uploadBundledAppMapWhenMissing) return false;
    final session = _asMap(connectResponse['session']);
    final appMap = _asMap(session['appMap']);
    return appMap['status'] == 'missing';
  }

  Uri _sessionUri(String tail) {
    final base = config.endpoint.toString().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse(
      '$base/v1/operator/sessions/${Uri.encodeComponent(config.sessionId)}/$tail',
    );
  }
}

class _CompletedProductionCommand {
  const _CompletedProductionCommand({
    required this.result,
    required this.snapshot,
    required this.completedAt,
  });

  final ActionResult result;
  final AppSnapshot? snapshot;
  final DateTime completedAt;
}

class _CommandResultSnapshotCapture {
  const _CommandResultSnapshotCapture({this.snapshot, this.snapshotMs});

  final AppSnapshot? snapshot;
  final int? snapshotMs;
}

JsonMap _commandResultSnapshotToJson(AppSnapshot snapshot) =>
    operatorReadableJson(_compactResultSnapshotToJson(snapshot)) as JsonMap;

/// The result snapshot trimmed for upload, with numbers JSON cannot carry still
/// in place: they are listed only after the last trim, so the listed paths are
/// those of the snapshot as sent.
JsonMap _compactResultSnapshotToJson(AppSnapshot snapshot) {
  final json = operatorSnapshotToJson(snapshot, readable: false);
  _compactResultSnapshotState(json);
  _compactResultSnapshotStorage(json);
  _compactResultSnapshotVisual(json, snapshot);
  _compactResultSnapshotList(json['logs'], maxItems: 50, keepLatest: true);
  _compactResultSnapshotList(json['errors'], maxItems: 50, keepLatest: true);
  _compactResultSnapshotList(json['dialogs'], maxItems: 25, keepLatest: true);

  final ui = json['ui'];
  if (ui is Map) {
    _compactResultSnapshotList(ui['elements'], maxItems: 300);
  }

  final network = json['network'];
  if (network is Map) {
    _compactResultSnapshotList(
      network['events'],
      maxItems: 50,
      keepLatest: true,
    );
  }

  return json;
}

bool _operatorFlutterSnapshotHasVisualData(AppSnapshot snapshot) =>
    snapshot.visual?.frames.any((frame) => frame.data != null) == true;

ActionResult _withFlutterTransportVisualCaptureSummary(
  ActionResult result,
  JsonMap? snapshot,
) {
  if (result.action.type != OperatorActionType.captureVisual ||
      snapshot == null) {
    return result;
  }
  final visual = snapshot['visual'];
  final analysis = visual is Map ? visual['analysis'] : null;
  final visualCapture = analysis is Map ? analysis['visualCapture'] : null;
  if (visualCapture is! Map) return result;
  return ActionResult(
    ok: result.ok,
    action: result.action,
    message: result.message,
    error: result.error,
    evidence: result.evidence,
    data: <String, Object?>{
      ...result.data,
      'visualCapture': Map<String, Object?>.from(visualCapture),
    },
  );
}

AppSnapshot _operatorFlutterSnapshotWithoutVisualPixels(AppSnapshot snapshot) {
  final sourceVisual = snapshot.visual;
  if (sourceVisual == null) return snapshot;
  final projection = _selectFlutterVisualTransport(
    _compactVisualCandidates(sourceVisual),
  );
  final captureTargets = _updatedFlutterVisualCaptureTargets(
    sourceVisual.captureTargets,
    projection.omittedFrameIds,
  );
  final transportFrames = projection.selected
      .map(
        (candidate) =>
            projection.pixelFrameIds.contains(candidate.frame.id)
                ? candidate.frame
                : _operatorFlutterMetadataOnlyFrame(candidate.frame),
      )
      .toList(growable: false);
  final metadataFrames = projection.selected
      .map((candidate) => _operatorFlutterMetadataOnlyFrame(candidate.frame))
      .toList(growable: false);
  final transportVisual = VisualSnapshot(
    capturedAt: sourceVisual.capturedAt,
    source: sourceVisual.source,
    frames: transportFrames,
    captureTargets: captureTargets,
    regions: sourceVisual.regions,
    ocr: sourceVisual.ocr,
    redacted: sourceVisual.redacted,
    metadata: sourceVisual.metadata,
    analysis: sourceVisual.analysis,
  );
  final analysis = operatorFlutterResolveVisualAnalysis(
    visual: transportVisual,
    viewport: snapshot.ui.viewport,
  );
  final visual = VisualSnapshot(
    capturedAt: transportVisual.capturedAt,
    source: transportVisual.source,
    frames: metadataFrames,
    captureTargets: transportVisual.captureTargets,
    regions: transportVisual.regions,
    ocr: transportVisual.ocr,
    redacted: transportVisual.redacted,
    metadata: <String, Object?>{
      ...transportVisual.metadata,
      'pixelBacked': analysis['hasUsablePixels'],
      'hasUsablePixels': analysis['hasUsablePixels'],
      'visualTrust': analysis['trust'],
      'visualCaptureComplete':
          (analysis['visualCapture'] as JsonMap?)?['complete'],
    },
    analysis: analysis,
  );
  return AppSnapshot(
    snapshotId: snapshot.snapshotId,
    timestamp: snapshot.timestamp,
    app: snapshot.app,
    userSession: snapshot.userSession,
    route: snapshot.route,
    ui: snapshot.ui,
    state: snapshot.state,
    forms: snapshot.forms,
    network: snapshot.network,
    logs: snapshot.logs,
    errors: snapshot.errors,
    dialogs: snapshot.dialogs,
    storage: snapshot.storage,
    visual: visual,
    capabilities: snapshot.capabilities,
    redactions: snapshot.redactions,
  );
}

JsonMap _compactPublishedSnapshotToJson(AppSnapshot snapshot) {
  final json = _compactResultSnapshotToJson(snapshot);
  final ui = json['ui'];
  if (ui is Map) {
    _compactResultSnapshotList(ui['elements'], maxItems: 200);
  }
  final network = json['network'];
  if (network is Map) {
    _compactResultSnapshotList(
      network['events'],
      maxItems: 40,
      keepLatest: true,
    );
  }
  _compactResultSnapshotList(json['logs'], maxItems: 30, keepLatest: true);
  return operatorReadableJson(json) as JsonMap;
}

void _compactResultSnapshotState(JsonMap snapshot) {
  final state = snapshot['state'];
  if (state is! List) return;

  var totalBytes = 0;
  snapshot['state'] = state
      .map((store) {
        if (store is! Map) return store;
        final encoded = operatorEncodeJson(store);
        totalBytes += encoded.length;
        if (encoded.length <= 64 * 1024 && totalBytes <= 256 * 1024)
          return store;

        return <String, Object?>{
          'source': store['source'],
          'name': store['name'],
          'schema': store['schema'],
          'confidence': store['confidence'],
          'redacted': store['redacted'],
          'value': <String, Object?>{
            'omitted': true,
            'reason': 'too_large_for_command_result',
            'byteLength': encoded.length,
          },
        };
      })
      .toList(growable: false);
}

void _compactResultSnapshotStorage(JsonMap snapshot) {
  final storage = snapshot['storage'];
  if (storage is! Map) return;
  final entries = storage['entries'];
  if (entries is! List) return;
  for (final entry in entries) {
    if (entry is! Map) continue;
    final value = entry['value'];
    if (value == null) continue;
    final encoded = operatorEncodeJson(value);
    if (encoded.length <= 8 * 1024) continue;
    entry['value'] = <String, Object?>{
      'omitted': true,
      'reason': 'too_large_for_snapshot_upload',
      'byteLength': encoded.length,
    };
  }
  _compactResultSnapshotList(entries, maxItems: 100);
}

const int _compactVisualFrameMaxCount = 2;
const int _compactVisualAggregateDataMaxChars = 8 * 1024 * 1024;

void _compactResultSnapshotVisual(
  JsonMap snapshot,
  AppSnapshot sourceSnapshot,
) {
  final visual = snapshot['visual'];
  if (visual is! Map) return;
  final frames = visual['frames'];
  final sourceVisual = sourceSnapshot.visual;
  if (frames is List && sourceVisual != null) {
    final candidates = _compactVisualCandidates(sourceVisual);
    final projection = _selectFlutterVisualTransport(candidates);
    final selected = projection.selected;
    final omittedFrameIds = projection.omittedFrameIds;
    final transportedFrames = <VisualFrame>[];
    final selectedJsonFrames = <Object?>[];
    for (final candidate in selected) {
      final frameJson = frames[candidate.index];
      if (frameJson is! Map) continue;
      final data = frameJson['data'];
      final canKeepData =
          data is String &&
          projection.pixelFrameIds.contains(candidate.frame.id) &&
          frameJson['metadataOnly'] != true;
      if (canKeepData) {
        frameJson['metadataOnly'] = false;
        transportedFrames.add(candidate.frame);
      } else {
        final hadData = data != null;
        frameJson
          ..remove('data')
          ..['metadataOnly'] = true;
        if (hadData) {
          frameJson['dataOmitted'] = 'too_large_for_snapshot_upload';
        }
        transportedFrames.add(
          _operatorFlutterMetadataOnlyFrame(candidate.frame),
        );
      }
      selectedJsonFrames.add(frameJson);
    }
    visual['frames'] = selectedJsonFrames;
    final transportTargets = _recordFlutterVisualTransportOmissions(
      visual,
      sourceVisual.captureTargets,
      omittedFrameIds,
    );
    final transportedVisual = VisualSnapshot(
      capturedAt: sourceVisual.capturedAt,
      source: sourceVisual.source,
      frames: transportedFrames,
      captureTargets: transportTargets,
      regions: sourceVisual.regions,
      ocr: sourceVisual.ocr,
      redacted: sourceVisual.redacted,
      metadata: sourceVisual.metadata,
      analysis: sourceVisual.analysis,
    );
    final analysis = operatorFlutterResolveVisualAnalysis(
      visual: transportedVisual,
      viewport: sourceSnapshot.ui.viewport,
    );
    visual['analysis'] = analysis;
    final metadata = visual['metadata'];
    if (metadata is Map) {
      metadata
        ..['pixelBacked'] = analysis['hasUsablePixels']
        ..['hasUsablePixels'] = analysis['hasUsablePixels']
        ..['visualTrust'] = analysis['trust']
        ..['visualCaptureComplete'] =
            (analysis['visualCapture'] as JsonMap?)?['complete'];
    }
  }
  _compactResultSnapshotList(visual['regions'], maxItems: 200);
  _compactResultSnapshotList(visual['ocr'], maxItems: 100);
}

class _CompactFlutterVisualCandidate {
  const _CompactFlutterVisualCandidate({
    required this.index,
    required this.frame,
    required this.analysis,
    required this.coverageKey,
    required this.area,
    required this.dataChars,
  });

  final int index;
  final VisualFrame frame;
  final JsonMap analysis;
  final String coverageKey;
  final double area;
  final int dataChars;
}

List<_CompactFlutterVisualCandidate> _compactVisualCandidates(
  VisualSnapshot visual,
) {
  final targetByFrameId = <String, String>{};
  for (final target in visual.captureTargets) {
    for (final frameId in target.frameIds) {
      targetByFrameId.putIfAbsent(frameId, () => target.targetId);
    }
  }
  return <_CompactFlutterVisualCandidate>[
    for (var index = 0; index < visual.frames.length; index += 1)
      _CompactFlutterVisualCandidate(
        index: index,
        frame: visual.frames[index],
        analysis: _operatorFlutterFrameTransportAnalysis(visual.frames[index]),
        coverageKey:
            targetByFrameId[visual.frames[index].id] ??
            'surface:${visual.frames[index].surfaceId ?? 'root'}',
        area:
            (visual.frames[index].surfaceClip?.width ??
                visual.frames[index].width) *
            (visual.frames[index].surfaceClip?.height ??
                visual.frames[index].height),
        dataChars: visual.frames[index].data?.length ?? 0,
      ),
  ];
}

JsonMap _operatorFlutterFrameTransportAnalysis(VisualFrame frame) {
  final summary = operatorFlutterResolveVisualAnalysis(
    visual: VisualSnapshot(
      capturedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      source: 'manual',
      frames: <VisualFrame>[frame],
      regions: const <VisualElementRegion>[],
      redacted: frame.redacted,
    ),
    viewport: ViewportSnapshot(width: frame.width, height: frame.height),
  );
  final frames = summary['frames'];
  return frames is List && frames.isNotEmpty && frames.first is JsonMap
      ? frames.first as JsonMap
      : const <String, Object?>{
        'integrity': 'invalid',
        'lowInformation': false,
      };
}

List<_CompactFlutterVisualCandidate> _selectCompactVisualCandidates(
  List<_CompactFlutterVisualCandidate> candidates,
) {
  final ordered = List<_CompactFlutterVisualCandidate>.from(candidates)
    ..sort((left, right) {
      final utility = _compactFlutterVisualUtility(
        right,
      ).compareTo(_compactFlutterVisualUtility(left));
      if (utility != 0) return utility;
      final area = right.area.compareTo(left.area);
      if (area != 0) return area;
      final bytes = left.dataChars.compareTo(right.dataChars);
      if (bytes != 0) return bytes;
      return left.index.compareTo(right.index);
    });
  final selected = <_CompactFlutterVisualCandidate>[];
  var dataChars = 0;
  bool fits(_CompactFlutterVisualCandidate candidate) =>
      candidate.dataChars == 0 ||
      dataChars + candidate.dataChars <= _compactVisualAggregateDataMaxChars;
  void add(_CompactFlutterVisualCandidate? candidate) {
    if (candidate == null || selected.contains(candidate)) return;
    selected.add(candidate);
    if (candidate.dataChars > 0 && fits(candidate)) {
      dataChars += candidate.dataChars;
    }
  }

  for (final candidate in ordered) {
    if (candidate.analysis['integrity'] == 'valid' && fits(candidate)) {
      add(candidate);
      break;
    }
  }
  while (selected.length < _compactVisualFrameMaxCount) {
    final covered = selected.map((candidate) => candidate.coverageKey).toSet();
    _CompactFlutterVisualCandidate? find(
      bool Function(_CompactFlutterVisualCandidate candidate) predicate,
    ) {
      for (final candidate in ordered) {
        if (!selected.contains(candidate) && predicate(candidate)) {
          return candidate;
        }
      }
      return null;
    }

    final next =
        find(
          (candidate) =>
              candidate.analysis['integrity'] == 'valid' &&
              !covered.contains(candidate.coverageKey) &&
              fits(candidate),
        ) ??
        find(
          (candidate) =>
              candidate.analysis['integrity'] == 'valid' && fits(candidate),
        ) ??
        find(fits) ??
        find((_) => true);
    if (next == null) break;
    add(next);
  }
  return selected;
}

class _FlutterVisualTransportSelection {
  const _FlutterVisualTransportSelection({
    required this.selected,
    required this.pixelFrameIds,
    required this.omittedFrameIds,
  });

  final List<_CompactFlutterVisualCandidate> selected;
  final Set<String> pixelFrameIds;
  final Set<String> omittedFrameIds;
}

_FlutterVisualTransportSelection _selectFlutterVisualTransport(
  List<_CompactFlutterVisualCandidate> candidates,
) {
  final selected = _selectCompactVisualCandidates(candidates);
  final selectedIndexes = selected.map((candidate) => candidate.index).toSet();
  final pixelFrameIds = <String>{};
  final omittedFrameIds = <String>{
    for (final candidate in candidates)
      if (!selectedIndexes.contains(candidate.index)) candidate.frame.id,
  };
  var retainedDataChars = 0;
  for (final candidate in selected) {
    final data = candidate.frame.data;
    if (data == null || candidate.frame.metadataOnly == true) continue;
    if (retainedDataChars + data.length <=
        _compactVisualAggregateDataMaxChars) {
      retainedDataChars += data.length;
      pixelFrameIds.add(candidate.frame.id);
    } else {
      omittedFrameIds.add(candidate.frame.id);
    }
  }
  return _FlutterVisualTransportSelection(
    selected: selected,
    pixelFrameIds: pixelFrameIds,
    omittedFrameIds: omittedFrameIds,
  );
}

int _compactFlutterVisualUtility(_CompactFlutterVisualCandidate candidate) {
  if (candidate.analysis['integrity'] == 'valid') {
    return candidate.analysis['lowInformation'] == true ? 3 : 4;
  }
  return candidate.analysis['integrity'] == 'invalid' ? 2 : 1;
}

VisualFrame _operatorFlutterMetadataOnlyFrame(VisualFrame frame) => VisualFrame(
  id: frame.id,
  surfaceId: frame.surfaceId,
  documentGeneration: frame.documentGeneration,
  surfaceClip: frame.surfaceClip,
  surfaceScale: frame.surfaceScale,
  format: frame.format,
  encoding: frame.encoding,
  width: frame.width,
  height: frame.height,
  pixelRatio: frame.pixelRatio,
  hash: frame.hash,
  metadataOnly: true,
  source: frame.source,
  redacted: frame.redacted,
);

List<VisualCaptureTarget> _recordFlutterVisualTransportOmissions(
  Map visual,
  List<VisualCaptureTarget> targets,
  Set<String> omittedFrameIds,
) {
  final updated = _updatedFlutterVisualCaptureTargets(targets, omittedFrameIds);
  if (updated.isNotEmpty) {
    visual['captureTargets'] = <JsonMap>[
      for (final target in updated)
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
        },
    ];
  }
  return updated;
}

List<VisualCaptureTarget> _updatedFlutterVisualCaptureTargets(
  List<VisualCaptureTarget> targets,
  Set<String> omittedFrameIds,
) => targets
    .map((target) {
      final omitted = target.frameIds.where(omittedFrameIds.contains).length;
      return VisualCaptureTarget(
        targetId: target.targetId,
        kind: target.kind,
        documentGeneration: target.documentGeneration,
        frameIds: target.frameIds,
        unavailableReason: target.unavailableReason,
        transportOmittedFrameCount:
            (target.transportOmittedFrameCount ?? 0) + omitted,
      );
    })
    .toList(growable: false);

void _compactResultSnapshotList(
  Object? value, {
  required int maxItems,
  bool keepLatest = false,
}) {
  if (value is! List || value.length <= maxItems) return;
  if (keepLatest) {
    value.removeRange(0, value.length - maxItems);
  } else {
    value.removeRange(maxItems, value.length);
  }
}

class _ResultDeliveryAttempt {
  const _ResultDeliveryAttempt(this.channel, this.delivered);

  final String channel;
  final bool delivered;
}

Map<String, Object?> _consentPayload({
  required bool operatorControl,
  required Iterable<String> approvedPurposes,
  DateTime? expiresAt,
}) => <String, Object?>{
  'operatorControl': operatorControl,
  'approvedPurposes': approvedPurposes.toList(growable: false),
  if (expiresAt != null) 'expiresAt': expiresAt.toIso8601String(),
};

Map<String, Object?> _asMap(Object? value) {
  if (value is Map) {
    return value.map((key, child) => MapEntry(key.toString(), child));
  }
  return <String, Object?>{};
}

List<Object?> _asList(Object? value) =>
    value is List ? value : const <Object?>[];
