import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'network_adapters.dart';
import 'observed_operations.dart';
import 'capture_diagnostics.dart';
import 'protocol.dart';
import 'redactor.dart';
import 'route_adapters.dart';
import 'state_adapters.dart';
import 'storage_adapters.dart';

typedef OperatorStateProvider = List<StateStoreSnapshot> Function();
typedef OperatorUiProvider = Iterable<UiElement> Function();
typedef OperatorStorageProvider =
    FutureOr<Iterable<StorageEntrySnapshot>> Function();
typedef OperatorVisualFrameProvider = FutureOr<VisualFrame?> Function();
typedef OperatorRouteRefresher = void Function({required bool emit});
typedef OperatorVirtualizationProbe =
    FutureOr<ActionResult> Function(
      ActionCommand command,
      OperatorFlutter operator,
    );

/// An integration's part of network conditions for traffic outside dart:io (for example a
/// Firebase client). It returns a JSON receipt of what it applied, or null when it has nothing to
/// do; [OperatorFlutter.applyNetworkConditions] waits for it before the action reports success.
typedef OperatorNetworkConditionsListener =
    FutureOr<Map<String, Object?>?> Function(
      OperatorNetworkConditions? conditions,
    );

// Production command-result and model payloads already retain at most two frames. Matching that
// bound here prevents occurrence-specific explicit captures from growing the app process forever.
const int _maxRetainedVisualFrames = 2;

class OperatorVisualCaptureResult {
  const OperatorVisualCaptureResult({
    required this.frames,
    required this.captureTargets,
  });

  final List<VisualFrame> frames;
  final List<VisualCaptureTarget> captureTargets;
}

class OperatorFlutterConfig {
  const OperatorFlutterConfig({
    required this.appId,
    required this.environment,
    this.name,
    this.version,
    this.privacy = const OperatorPrivacyConfig(),
    this.policy = const OperatorPolicyConfig(),
  });

  final String appId;
  final String? name;
  final String? version;
  final OperatorEnvironment environment;
  final OperatorPrivacyConfig privacy;
  final OperatorPolicyConfig policy;
}

class OperatorPrivacyConfig {
  const OperatorPrivacyConfig({
    this.redactFields = const <String>[],
    this.maxBodyBytes = 64000,
    this.captureScreenshots = true,
    this.screenshotPixelRatio = 1,
  });

  final List<String> redactFields;
  final int maxBodyBytes;
  final bool captureScreenshots;
  final double screenshotPixelRatio;
}

class OperatorPolicyConfig {
  const OperatorPolicyConfig({
    this.requireUserConfirmationFor = const <String>[],
    this.allowAutonomousActionsFor = const <String>[],
  });

  final List<String> requireUserConfirmationFor;
  final List<String> allowAutonomousActionsFor;
}

class OperatorFlutter {
  OperatorFlutter._(this.config)
    : redactor = OperatorRedactor(
        fields:
            config.privacy.redactFields.isEmpty
                ? nullSafeDefaultRedactionFields
                : config.privacy.redactFields,
        maxStringLength: config.privacy.maxBodyBytes,
      );

  final OperatorFlutterConfig config;
  final OperatorRedactor redactor;
  final OperatorObservedOperations observedOperations =
      OperatorObservedOperations();

  RouteState _route = const RouteState(current: RouteEntry(path: '/'));
  UiTree _ui = const UiTree(
    rootId: 'flutter-root',
    elements: <UiElement>[],
    viewport: ViewportSnapshot(width: 0, height: 0),
  );
  final List<StateStoreSnapshot> _state = <StateStoreSnapshot>[];
  final Map<String, StateStoreSnapshot> _injectedState =
      <String, StateStoreSnapshot>{};
  final List<_RuntimeNetworkMock> _networkMocks = <_RuntimeNetworkMock>[];
  final List<_RuntimeFirebaseMock> _firebaseMocks = <_RuntimeFirebaseMock>[];
  final Map<String, bool> _virtualizationCapabilities = <String, bool>{
    'networkMocks': true,
    // A registry alone cannot intercept Firebase SDK calls. The optional
    // Firebase integration enables this only after installing its wrappers.
    'firebaseMocks': false,
    'stateInjection': true,
    'storageInjection': true,
    'formInjection': true,
  };
  final List<NetworkEvent> _networkEvents = <NetworkEvent>[];
  final List<LogEvent> _logs = <LogEvent>[];
  final List<ErrorSnapshot> _errors = <ErrorSnapshot>[];
  final List<_OperatorRuntimeErrorSuppression> _operatorErrorSuppressions =
      <_OperatorRuntimeErrorSuppression>[];
  final List<DialogState> _dialogs = <DialogState>[];
  final Map<String, StorageEntrySnapshot> _storage =
      <String, StorageEntrySnapshot>{};
  final Map<String, FormFieldPatch> _formPatches = <String, FormFieldPatch>{};
  final Map<String, VisualFrame> _visualFrames = <String, VisualFrame>{};
  final List<RedactionReport> _redactionReports = <RedactionReport>[];
  final Set<OperatorStateProvider> _stateProviders = <OperatorStateProvider>{};
  final Map<OperatorStateProvider, List<StateStoreSnapshot>>
  _stateProviderLastGood = <OperatorStateProvider, List<StateStoreSnapshot>>{};
  final Map<OperatorStateProvider, _ObservationProviderFailure>
  _stateProviderFailures =
      <OperatorStateProvider, _ObservationProviderFailure>{};
  final Set<OperatorUiProvider> _uiProviders = <OperatorUiProvider>{};
  final Map<OperatorStorageProvider, Set<String>> _storageProviders =
      <OperatorStorageProvider, Set<String>>{};
  final Map<OperatorVisualFrameProvider, String> _visualFrameProviders =
      <OperatorVisualFrameProvider, String>{};
  Future<void> _visualCaptureTail = Future<void>.value();
  int _diagnosticVisualQueueDepth = 0;
  final Set<OperatorRouteRefresher> _routeRefreshers =
      <OperatorRouteRefresher>{};
  final Map<String, OperatorVirtualizationProbe> _virtualizationProbes =
      <String, OperatorVirtualizationProbe>{};
  final Set<VoidCallback> _mockAvailabilityListeners = <VoidCallback>{};
  final Set<OperatorNetworkConditionsListener> _networkConditionsListeners =
      <OperatorNetworkConditionsListener>{};
  Future<List<Map<String, Object?>>> _networkConditionsApplied =
      Future<List<Map<String, Object?>>>.value(const <Map<String, Object?>>[]);
  final Map<String, UiElement> _registeredUiElements = <String, UiElement>{};
  final StreamController<AppSnapshot> _snapshots =
      StreamController<AppSnapshot>.broadcast();
  final StreamController<OperatorRuntimeEvent> _events =
      StreamController<OperatorRuntimeEvent>.broadcast();
  int _counter = 0;
  int _eventCounter = 0;
  int _visualProviderCounter = 0;
  String? _activeSnapshotId;
  bool _activeSnapshotIssuesActionTargets = false;

  static Future<OperatorFlutter> init(OperatorFlutterConfig config) async {
    return OperatorFlutter._(config);
  }

  Stream<AppSnapshot> get snapshots => _snapshots.stream;

  Stream<OperatorRuntimeEvent> get events => _events.stream;

  /// The snapshot currently being assembled by synchronous observation providers.
  ///
  /// UI providers use this only to bind opaque runtime target references to the
  /// exact snapshot that contains them. It is null outside that synchronous
  /// provider pass.
  String? get activeSnapshotId => _activeSnapshotId;

  /// Whether the snapshot currently being assembled is allowed to replace the
  /// model-facing observation-target registry.
  bool get activeSnapshotIssuesActionTargets =>
      _activeSnapshotIssuesActionTargets;

  RouteState get currentRoute => _route;

  RouteObserver<PageRoute<dynamic>> get routeObserver =>
      OperatorRouteObserver(this);

  OperatorNetworkAdapter get networkAdapter => OperatorNetworkAdapter(this);

  VoidCallback addMockAvailabilityListener(VoidCallback listener) {
    _mockAvailabilityListeners.add(listener);
    listener();
    return () => _mockAvailabilityListeners.remove(listener);
  }

  bool get hasActiveNetworkMocks {
    _pruneExpiredNetworkMocks();
    return _networkMocks.isNotEmpty;
  }

  OperatorNetworkConditions? _networkConditions;
  int _networkConditionsGeneration = 0;
  math.Random? _networkConditionsRandom;

  /// Link conditions applied inside the app to every real HTTP request, or null when none.
  OperatorNetworkConditions? get networkConditions => _networkConditions;

  int get networkConditionsGeneration => _networkConditionsGeneration;

  /// Hear every change of network conditions, including the clear at the end of a test. Like
  /// [addMockAvailabilityListener], the listener first hears the conditions already in force, so
  /// an integration bound while conditions hold applies them at once.
  VoidCallback addNetworkConditionsListener(
    OperatorNetworkConditionsListener listener,
  ) {
    _networkConditionsListeners.add(listener);
    if (_networkConditions != null) {
      unawaited(
        Future<Map<String, Object?>?>.sync(
          () => listener(_networkConditions),
        ).then<void>((_) {}, onError: (Object _) {}),
      );
    }
    return () => _networkConditionsListeners.remove(listener);
  }

  /// Set the conditions and wait until every integration has applied its part; returns their
  /// receipts. A listener that fails reports its error instead of failing the others.
  Future<List<Map<String, Object?>>> applyNetworkConditions(
    OperatorNetworkConditions? conditions,
  ) {
    setNetworkConditions(conditions);
    return _networkConditionsApplied;
  }

  void setNetworkConditions(OperatorNetworkConditions? conditions) {
    final active = conditions == null || conditions.isEmpty ? null : conditions;
    // Clearing conditions that are already clear changes nothing and emits nothing; integrations
    // still hear it, so one that failed to restore its part earlier gets another try.
    final changed = active != null || _networkConditions != null;
    if (changed) {
      _networkConditions = active;
      _networkConditionsGeneration += 1;
      _networkConditionsRandom =
          active == null
              ? null
              : math.Random(_networkConditionsSeed(active.seed));
    }
    final listeners = List<OperatorNetworkConditionsListener>.of(
      _networkConditionsListeners,
    );
    _networkConditionsApplied = Future.wait(
      listeners.map(
        (listener) => Future<Map<String, Object?>?>.sync(
          () => listener(active),
        ).then<Map<String, Object?>?>(
          (receipt) => receipt,
          onError: (Object error) => <String, Object?>{'error': '$error'},
        ),
      ),
    ).then(
      (receipts) =>
          receipts.whereType<Map<String, Object?>>().toList(growable: false),
    );
    if (!changed) return;
    // Background isolates learn the conditions through the same lookup port as mocks.
    _emitMockAvailabilityChanged();
    _emitRuntimeEvent(OperatorRuntimeEventType.network, <String, Object?>{
      'networkConditions': active?.toJson(),
      'generation': _networkConditionsGeneration,
    });
    _emit();
  }

  /// One request's share of the active conditions, from the app's single seeded sequence.
  OperatorNetworkDecision? decideNetworkConditions() {
    final conditions = _networkConditions;
    final random = _networkConditionsRandom;
    if (conditions == null || random == null) return null;
    final jitter = conditions.jitterMs ?? 0;
    final spread =
        jitter <= 0 ? 0 : ((random.nextDouble() * 2 - 1) * jitter).round();
    final rate = conditions.failureRate ?? 0;
    return OperatorNetworkDecision(
      generation: _networkConditionsGeneration,
      offline: conditions.offline == true,
      delay: Duration(
        milliseconds: math.max(0, (conditions.latencyMs ?? 0) + spread),
      ),
      fail: rate > 0 && random.nextDouble() < rate,
      failureStatus: conditions.failureStatus,
      downloadKbps: conditions.downloadKbps,
      uploadKbps: conditions.uploadKbps,
    );
  }

  int _networkConditionsSeed(String? seed) {
    if (seed == null) return DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
    var hash = 0x811c9dc5;
    for (final unit in seed.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  bool get hasActiveFirebaseMocks {
    _pruneExpiredFirebaseMocks();
    return _firebaseMocks.isNotEmpty;
  }

  bool get canCaptureScreenshots =>
      config.privacy.captureScreenshots && _visualFrameProviders.isNotEmpty;

  void setVirtualizationCapability(String key, bool enabled) {
    if (key.trim().isEmpty) return;
    if (enabled) {
      _virtualizationCapabilities[key] = true;
    } else {
      _virtualizationCapabilities.remove(key);
    }
    _emitRuntimeEvent(OperatorRuntimeEventType.capabilities, <String, Object?>{
      'virtualization': Map<String, bool>.unmodifiable(
        _virtualizationCapabilities,
      ),
    });
    _emit();
  }

  VoidCallback registerVirtualizationProbe(
    String key,
    OperatorVirtualizationProbe probe,
  ) {
    final normalized = key.trim().toLowerCase();
    if (normalized.isEmpty) return () {};
    _virtualizationProbes[normalized] = probe;
    return () {
      if (_virtualizationProbes[normalized] == probe) {
        _virtualizationProbes.remove(normalized);
      }
    };
  }

  Future<ActionResult?> runVirtualizationProbe(
    String key,
    ActionCommand command,
  ) async {
    final probe = _virtualizationProbes[key.trim().toLowerCase()];
    if (probe == null) return null;
    return probe(command, this);
  }

  OperatorBlocStateObserver get blocObserver =>
      OperatorBlocStateObserver(operator: this);

  OperatorProviderStateObserver get providerObserver =>
      OperatorProviderStateObserver(operator: this);

  OperatorPopularStateAdapters get stateAdapters =>
      OperatorPopularStateAdapters(operator: this);

  OperatorStorageAdapters get storageAdapters => OperatorStorageAdapters(this);

  OperatorRouterAdapter get routerAdapter => OperatorRouterAdapter(this);

  void dispose() {
    observedOperations.close();
    _routeRefreshers.clear();
    _snapshots.close();
    _events.close();
  }

  VoidCallback addRouteRefresher(OperatorRouteRefresher refresher) {
    _routeRefreshers.add(refresher);
    _refreshRouteProviders(emit: true);
    return () => _routeRefreshers.remove(refresher);
  }

  VoidCallback addStateProvider(OperatorStateProvider provider) {
    _stateProviders.add(provider);
    _emitRuntimeEvent(OperatorRuntimeEventType.state, _currentState());
    _emit();
    return () {
      _stateProviders.remove(provider);
      _stateProviderLastGood.remove(provider);
      _stateProviderFailures.remove(provider);
      _emitRuntimeEvent(OperatorRuntimeEventType.state, _currentState());
      _emit();
    };
  }

  VoidCallback addUiProvider(OperatorUiProvider provider) {
    _uiProviders.add(provider);
    final ui = _currentUi();
    _emitRuntimeEvent(OperatorRuntimeEventType.ui, ui);
    _emitRuntimeEvent(OperatorRuntimeEventType.forms, _currentForms(ui));
    _emit();
    return () {
      _uiProviders.remove(provider);
      final ui = _currentUi();
      _emitRuntimeEvent(OperatorRuntimeEventType.ui, ui);
      _emitRuntimeEvent(OperatorRuntimeEventType.forms, _currentForms(ui));
      _emit();
    };
  }

  VoidCallback addStorageProvider(
    OperatorStorageProvider provider, {
    Set<String> replacesCapturedAreas = const <String>{},
  }) {
    _storageProviders[provider] = Set<String>.unmodifiable(
      replacesCapturedAreas,
    );
    return () {
      _storageProviders.remove(provider);
    };
  }

  VoidCallback addVisualFrameProvider(OperatorVisualFrameProvider provider) {
    _visualFrameProviders.putIfAbsent(
      provider,
      () => 'flutter_visual_provider_${++_visualProviderCounter}',
    );
    _emitRuntimeEvent(
      OperatorRuntimeEventType.visual,
      _visualFrames.values.toList(),
    );
    _emit();
    return () {
      _visualFrameProviders.remove(provider);
      _emitRuntimeEvent(
        OperatorRuntimeEventType.visual,
        _visualFrames.values.toList(),
      );
      _emit();
    };
  }

  void captureRoute({
    String? name,
    String? path,
    String? screenClass,
    String? title,
    JsonMap params = const <String, Object?>{},
    bool emit = true,
  }) {
    _route = RouteState(
      current: RouteEntry(
        name: name,
        path: path,
        screenClass: screenClass,
        title: title,
        params: params,
      ),
      previous: _route.current,
      stack: _route.stack,
    );
    if (emit) {
      _emitRuntimeEvent(OperatorRuntimeEventType.route, _route);
      _emit();
    }
  }

  void captureRouteStack(List<RouteEntry> stack) {
    _route = RouteState(
      current: stack.isEmpty ? _route.current : stack.last,
      previous: _route.current,
      stack: List<RouteEntry>.unmodifiable(stack),
    );
    _emitRuntimeEvent(OperatorRuntimeEventType.route, _route);
    _emit();
  }

  void captureUiTree(UiTree ui) {
    _ui = ui;
    final currentUi = _currentUi();
    _emitRuntimeEvent(OperatorRuntimeEventType.ui, currentUi);
    _emitRuntimeEvent(OperatorRuntimeEventType.forms, _currentForms(currentUi));
    _emit();
  }

  void captureUiElement(UiElement element, {String rootId = 'flutter-root'}) {
    _registeredUiElements[element.id] = element;
    _ui = UiTree(
      rootId: rootId,
      elements: List<UiElement>.unmodifiable(_registeredUiElements.values),
      viewport: _ui.viewport,
      focusedElementId: _ui.focusedElementId,
    );
    final currentUi = _currentUi();
    _emitRuntimeEvent(OperatorRuntimeEventType.ui, currentUi);
    _emitRuntimeEvent(OperatorRuntimeEventType.forms, _currentForms(currentUi));
    _emit();
  }

  void removeUiElement(String id, {String rootId = 'flutter-root'}) {
    _registeredUiElements.remove(id);
    _ui = UiTree(
      rootId: rootId,
      elements: List<UiElement>.unmodifiable(_registeredUiElements.values),
      viewport: _ui.viewport,
      focusedElementId: _ui.focusedElementId,
    );
    final currentUi = _currentUi();
    _emitRuntimeEvent(OperatorRuntimeEventType.ui, currentUi);
    _emitRuntimeEvent(OperatorRuntimeEventType.forms, _currentForms(currentUi));
    _emit();
  }

  void captureStateChange({
    required OperatorStateSource source,
    required String name,
    required Object? value,
    double confidence = 1,
    String? schema,
  }) {
    final cleaned = redactor.cleanWithReport(value);
    _addRedactionReport(cleaned.report);
    _state.removeWhere(
      (store) => _sameStateStore(store, source: source, name: name),
    );
    final state = StateStoreSnapshot(
      source: source,
      name: name,
      value: cleaned.value,
      schema: schema,
      confidence: confidence,
      redacted: cleaned.report.redacted,
    );
    _state.add(state);
    _emitRuntimeEvent(OperatorRuntimeEventType.state, state);
    _emit();
  }

  void captureStorageEntry(StorageEntrySnapshot entry) {
    final forceMetadataOnly =
        entry.metadataOnly ||
        _isSensitiveStorageKey(entry.key) ||
        redactor.shouldRedactKey(entry.key);
    final cleaned =
        forceMetadataOnly
            ? const RedactionResult(
              value: null,
              report: RedactionReport(
                redacted: false,
                fields: <String>[],
                paths: <String>[],
              ),
            )
            : redactor.cleanWithReport(entry.value);
    _addRedactionReport(cleaned.report);
    if (forceMetadataOnly && !entry.metadataOnly) {
      _addRedactionReport(
        RedactionReport(
          redacted: true,
          fields: <String>[entry.key],
          paths: <String>['\$.storage.${entry.key}'],
        ),
      );
    }
    final captured = StorageEntrySnapshot(
      area: entry.area,
      key: entry.key,
      value: forceMetadataOnly ? null : cleaned.value,
      valueType: entry.valueType,
      sizeBytes: entry.sizeBytes,
      namespace: entry.namespace,
      source: entry.source,
      updatedAt: entry.updatedAt,
      confidence: entry.confidence,
      metadataOnly: forceMetadataOnly,
      redacted: entry.redacted || forceMetadataOnly || cleaned.report.redacted,
    );
    _storage['${entry.area}:${entry.namespace ?? ''}:${entry.key}'] = captured;
    _emitRuntimeEvent(OperatorRuntimeEventType.storage, captured);
    _emit();
  }

  void removeStorageEntry({
    required String area,
    required String key,
    String? namespace,
  }) {
    _storage.remove(_storageKey(area, namespace, key));
    _emitRuntimeEvent(OperatorRuntimeEventType.storage, <String, Object?>{
      'removed': true,
      'area': area,
      'key': key,
      'namespace': namespace,
    });
    _emit();
  }

  void captureVisualFrame(VisualFrame frame) {
    _retainVisualFrame(frame);
    _emitRuntimeEvent(OperatorRuntimeEventType.visual, frame);
    _emit();
  }

  void clearVisualFrames() {
    _visualFrames.clear();
    _emitRuntimeEvent(OperatorRuntimeEventType.visual, const <VisualFrame>[]);
    _emit();
  }

  void releaseVisualPixels(Iterable<VisualFrame> frames) {
    final releasedIds = frames.map((frame) => frame.id).toSet();
    var changed = false;
    for (final entry in List<MapEntry<String, VisualFrame>>.from(
      _visualFrames.entries,
    )) {
      if (!releasedIds.contains(entry.value.id) || entry.value.data == null) {
        continue;
      }
      _visualFrames[entry.key] = _operatorFlutterFrameWithoutPixels(
        entry.value,
      );
      changed = true;
    }
    if (changed) {
      _emitRuntimeEvent(
        OperatorRuntimeEventType.visual,
        _visualFrames.values.toList(growable: false),
      );
      _emit();
    }
  }

  void injectStorage({
    required String area,
    required String key,
    Object? value,
    String? namespace,
    String? valueType,
    bool metadataOnly = false,
    String? source,
    String? mode,
  }) {
    _assertNonProduction('storage injection');
    final existing = _storage[_storageKey(area, namespace, key)]?.value;
    final nextValue = mode == 'merge' ? _mergeObjects(existing, value) : value;
    captureStorageEntry(
      StorageEntrySnapshot(
        area: area,
        key: key,
        value: nextValue,
        valueType: valueType ?? nextValue?.runtimeType.toString(),
        namespace: namespace,
        source: source ?? 'operator_injection',
        updatedAt: DateTime.now().toUtc(),
        confidence: 1,
        metadataOnly: metadataOnly,
        redacted: false,
      ),
    );
    captureLog(
      'info',
      'storage injected',
      data: <String, Object?>{
        'area': area,
        'key': key,
        'namespace': namespace,
        'mode': mode ?? 'replace',
      },
    );
  }

  void clearStorage({String? area, String? key, String? namespace}) {
    _assertNonProduction('storage clearing');
    _storage.removeWhere(
      (_, entry) =>
          (area == null || entry.area == area) &&
          (key == null || entry.key == key) &&
          (namespace == null || entry.namespace == namespace),
    );
    captureLog(
      'info',
      'storage cleared',
      data: <String, Object?>{'area': area, 'key': key, 'namespace': namespace},
    );
    _emit();
  }

  void injectFormFields(List<FormFieldPatch> fields, {String? mode}) {
    _assertNonProduction('form injection');
    for (final field in fields) {
      final key = field.id ?? field.name;
      if (key == null) continue;
      final existing = _formPatches[key];
      _formPatches[key] =
          mode == 'merge' && existing != null
              ? _mergeFormPatch(existing, field)
              : field;
    }
    captureLog(
      'info',
      'form injected',
      data: <String, Object?>{
        'fields': fields.length,
        'mode': mode ?? 'replace',
      },
    );
    _emitRuntimeEvent(
      OperatorRuntimeEventType.forms,
      _currentForms(_currentUi()),
    );
    _emit();
  }

  void captureNetworkEvent(NetworkEvent event) {
    _networkEvents.add(event);
    if (_networkEvents.length > 200) _networkEvents.removeAt(0);
    _emitRuntimeEvent(OperatorRuntimeEventType.network, event);
    _emit();
  }

  void captureNetworkRequest({
    required String id,
    required NetworkRequest request,
    List<String> tags = const <String>['request'],
  }) {
    final requestCleaned = redactor.cleanWithReport(_requestToMap(request));
    _addRedactionReport(requestCleaned.report);
    captureNetworkEvent(
      NetworkEvent(
        id: id,
        timestamp: DateTime.now().toUtc(),
        request: _requestFromMap(requestCleaned.value as Map<String, Object?>),
        redacted: requestCleaned.report.redacted,
        tags: tags,
      ),
    );
  }

  void captureNetworkResponse({
    required String id,
    required NetworkRequest request,
    required int status,
    required bool ok,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    List<String> tags = const <String>['response'],
  }) {
    final requestCleaned = redactor.cleanWithReport(_requestToMap(request));
    final responseCleaned = redactor.cleanWithReport(<String, Object?>{
      'status': status,
      'ok': ok,
      'headers': headers,
      'body': body,
    });
    _addRedactionReport(requestCleaned.report);
    _addRedactionReport(responseCleaned.report);
    captureNetworkEvent(
      NetworkEvent(
        id: id,
        timestamp: DateTime.now().toUtc(),
        request: _requestFromMap(requestCleaned.value as Map<String, Object?>),
        response: NetworkResponse(
          status: status,
          ok: ok,
          headers: _headersFromCleanedResponse(responseCleaned.value),
          body: (responseCleaned.value as Map<String, Object?>)['body'],
        ),
        redacted:
            requestCleaned.report.redacted || responseCleaned.report.redacted,
        tags: tags,
      ),
    );
  }

  void captureNetworkError({
    required String id,
    required NetworkRequest request,
    required String type,
    required String message,
    bool retryable = true,
    List<String> tags = const <String>['error'],
  }) {
    final requestCleaned = redactor.cleanWithReport(_requestToMap(request));
    _addRedactionReport(requestCleaned.report);
    captureNetworkEvent(
      NetworkEvent(
        id: id,
        timestamp: DateTime.now().toUtc(),
        request: _requestFromMap(requestCleaned.value as Map<String, Object?>),
        error: NetworkError(type: type, message: message, retryable: retryable),
        redacted: requestCleaned.report.redacted,
        tags: tags,
      ),
    );
  }

  void captureLog(
    String level,
    String message, {
    JsonMap data = const <String, Object?>{},
    OperatorLogSource? source,
  }) {
    final cleaned = redactor.cleanWithReport(data);
    _addRedactionReport(cleaned.report);
    final log = _captureLogEntry(
      level,
      message,
      source ?? _inferLogSource(message),
      cleaned.value as JsonMap? ?? const <String, Object?>{},
      cleaned.report.redacted,
    );
    _emitRuntimeEvent(OperatorRuntimeEventType.log, log);
    _emit();
  }

  void clearStateStore(String name, {OperatorStateSource? source}) {
    _state.removeWhere(
      (store) =>
          store.name == name && (source == null || store.source == source),
    );
    _emitRuntimeEvent(OperatorRuntimeEventType.state, <String, Object?>{
      'removed': true,
      'name': name,
    });
    _emit();
  }

  String installNetworkMock(
    NetworkMockMatch match,
    NetworkMockResponse response, {
    Duration? ttl,
  }) {
    final id = makeOperatorId('net_mock', _networkMocks.length + 1);
    _networkMocks.add(
      _RuntimeNetworkMock(
        id: id,
        match: match,
        response: response,
        expiresAt: ttl == null ? null : DateTime.now().toUtc().add(ttl),
      ),
    );
    captureLog(
      'info',
      'network mock installed',
      data: <String, Object?>{'id': id, 'path': match.path},
    );
    _emitMockAvailabilityChanged();
    return id;
  }

  NetworkMockResponse? findNetworkMock(NetworkRequest request) {
    return resolveNetworkMock(request).response;
  }

  OperatorNetworkMockResolution resolveNetworkMock(NetworkRequest request) {
    if (_pruneExpiredNetworkMocks()) _emitMockAvailabilityChanged();
    final candidateCount = _networkMocks.length;
    _RuntimeNetworkMock? bestMock;
    var bestScore = -1;
    for (final mock in _networkMocks) {
      final score = _networkMockMatchScore(mock.match, request);
      if (score == null) continue;
      if (score >= bestScore) {
        bestScore = score;
        bestMock = mock;
      }
    }
    return OperatorNetworkMockResolution(
      request: request,
      matched: bestMock != null,
      mockId: bestMock?.id,
      match: bestMock?.match,
      response: bestMock?.response,
      score: bestMock == null ? null : bestScore,
      candidateCount: candidateCount,
    );
  }

  bool removeNetworkMock(String id) {
    final before = _networkMocks.length;
    _networkMocks.removeWhere((mock) => mock.id == id);
    final removed = _networkMocks.length != before;
    if (removed) _emitMockAvailabilityChanged();
    return removed;
  }

  String installFirebaseMock(
    FirebaseMockMatch match,
    FirebaseMockResponse response, {
    Duration? ttl,
  }) {
    if (observedOperations.hasPending) {
      throw StateError('observed_fault_conflicts_with_firebase_mock');
    }
    final id = makeOperatorId('firebase_mock', _firebaseMocks.length + 1);
    _firebaseMocks.add(
      _RuntimeFirebaseMock(
        id: id,
        match: match,
        response: response,
        expiresAt: ttl == null ? null : DateTime.now().toUtc().add(ttl),
      ),
    );
    captureLog(
      'info',
      'firebase mock installed',
      data: <String, Object?>{
        'id': id,
        'service': match.service,
        'operation': match.operation,
        'path': match.path,
        'name': match.name,
        'bucket': match.bucket,
      },
    );
    _emitMockAvailabilityChanged();
    return id;
  }

  bool removeFirebaseMock(String id) {
    final before = _firebaseMocks.length;
    _firebaseMocks.removeWhere((mock) => mock.id == id);
    final removed = _firebaseMocks.length != before;
    if (removed) _emitMockAvailabilityChanged();
    return removed;
  }

  FirebaseMockResponse? findFirebaseMock(FirebaseMockMatch request) {
    return resolveFirebaseMock(request).response;
  }

  OperatorFirebaseMockResolution resolveFirebaseMock(
    FirebaseMockMatch request,
  ) {
    if (_pruneExpiredFirebaseMocks()) _emitMockAvailabilityChanged();
    final candidateCount = _firebaseMocks.length;
    _RuntimeFirebaseMock? bestMock;
    var bestScore = -1;
    for (final mock in _firebaseMocks) {
      final score = _firebaseMockMatchScore(mock.match, request);
      if (score == null) continue;
      if (score >= bestScore) {
        bestScore = score;
        bestMock = mock;
      }
    }
    return OperatorFirebaseMockResolution(
      request: request,
      matched: bestMock != null,
      mockId: bestMock?.id,
      match: bestMock?.match,
      response: bestMock?.response,
      score: bestMock == null ? null : bestScore,
      candidateCount: candidateCount,
    );
  }

  bool _pruneExpiredNetworkMocks() {
    final before = _networkMocks.length;
    final now = DateTime.now().toUtc();
    _networkMocks.removeWhere(
      (mock) => mock.expiresAt != null && mock.expiresAt!.isBefore(now),
    );
    return _networkMocks.length != before;
  }

  bool _pruneExpiredFirebaseMocks() {
    final before = _firebaseMocks.length;
    final now = DateTime.now().toUtc();
    _firebaseMocks.removeWhere(
      (mock) => mock.expiresAt != null && mock.expiresAt!.isBefore(now),
    );
    return _firebaseMocks.length != before;
  }

  void _emitMockAvailabilityChanged() {
    for (final listener in List<VoidCallback>.of(_mockAvailabilityListeners)) {
      listener();
    }
  }

  void injectState(String store, Object? value, {String? mode}) {
    final existing = _injectedState[store]?.value;
    final nextValue = mode == 'merge' ? _mergeObjects(existing, value) : value;
    final cleaned = redactor.cleanWithReport(nextValue);
    _addRedactionReport(cleaned.report);
    _injectedState[store] = StateStoreSnapshot(
      source: OperatorStateSource.custom,
      name: store,
      value: cleaned.value,
      confidence: 1,
      redacted: cleaned.report.redacted,
    );
    captureLog(
      'info',
      'state injected',
      data: <String, Object?>{'store': store, 'mode': mode ?? 'replace'},
    );
    _emit();
  }

  void clearSimulation(String scope) {
    if (scope == 'firebase_mocks' || scope == 'all')
      observedOperations.clearAll();
    if (scope == 'all' && _networkConditions != null)
      setNetworkConditions(null);
    final hadNetworkMocks = _networkMocks.isNotEmpty;
    final hadFirebaseMocks = _firebaseMocks.isNotEmpty;
    if (scope == 'network_mocks' || scope == 'all') _networkMocks.clear();
    if (scope == 'firebase_mocks' || scope == 'all') _firebaseMocks.clear();
    if ((hadNetworkMocks && _networkMocks.isEmpty) ||
        (hadFirebaseMocks && _firebaseMocks.isEmpty)) {
      _emitMockAvailabilityChanged();
    }
    if (scope == 'state' || scope == 'all') _injectedState.clear();
    if (scope == 'storage' || scope == 'all') _storage.clear();
    if (scope == 'forms' || scope == 'all') _formPatches.clear();
    if (scope == 'all') _networkEvents.clear();
    _emitRuntimeEvent(OperatorRuntimeEventType.network, <String, Object?>{
      'cleared': scope == 'network_mocks' || scope == 'all',
      'scope': scope,
    });
    _emitRuntimeEvent(OperatorRuntimeEventType.state, _currentState());
    _emitRuntimeEvent(OperatorRuntimeEventType.storage, _retainedStorage());
    _emitRuntimeEvent(
      OperatorRuntimeEventType.forms,
      _currentForms(_currentUi()),
    );
    _emitRuntimeEvent(
      OperatorRuntimeEventType.visual,
      _visualFrames.values.toList(),
    );
    captureLog(
      'info',
      'simulation cleared',
      data: <String, Object?>{'scope': scope},
    );
    _emit();
  }

  void captureDialog(DialogState dialog) {
    _dialogs.removeWhere((item) => item.id == dialog.id);
    _dialogs.add(dialog);
    _emitRuntimeEvent(OperatorRuntimeEventType.dialog, dialog);
    _emit();
  }

  void captureFlutterError(FlutterErrorDetails details) {
    captureError(
      type: details.exception.runtimeType.toString(),
      message: details.exceptionAsString(),
      stack: details.stack?.toString(),
      source: details.library ?? 'flutter',
      fatal: false,
      handled: false,
      data: <String, Object?>{'context': details.context?.toString()},
    );
  }

  bool captureZoneError(Object error, StackTrace stackTrace) {
    final message = error.toString();
    if (_consumeOperatorRuntimeErrorSuppression(message) ||
        _isOperatorRuntimeTransportError(message)) {
      captureLog(
        'debug',
        'operator runtime transport error suppressed',
        source: OperatorLogSource.operatorRuntime,
        data: <String, Object?>{
          'type': error.runtimeType.toString(),
          'message': message,
        },
      );
      return true;
    }
    captureError(
      type: error.runtimeType.toString(),
      message: message,
      stack: stackTrace.toString(),
      source: 'zone',
      fatal: false,
      handled: false,
    );
    return false;
  }

  bool _isOperatorRuntimeTransportError(String message) {
    final lower = message.toLowerCase();
    return lower.contains('/v1/operator/') ||
        lower.contains('operator/sessions/') ||
        lower.contains('operator production session') ||
        lower.contains('operator runtime transport');
  }

  void suppressOperatorRuntimeZoneError(
    String messageFragment, {
    Duration ttl = const Duration(seconds: 2),
  }) {
    final fragment = messageFragment.trim();
    if (fragment.isEmpty) return;
    _operatorErrorSuppressions.add(
      _OperatorRuntimeErrorSuppression(
        fragment: fragment,
        expiresAt: DateTime.now().toUtc().add(ttl),
      ),
    );
    if (_operatorErrorSuppressions.length > 20) {
      _operatorErrorSuppressions.removeAt(0);
    }
  }

  void captureError({
    required String type,
    required String message,
    String? stack,
    String? source,
    bool handled = true,
    bool fatal = false,
    JsonMap data = const <String, Object?>{},
  }) {
    final cleaned = redactor.cleanWithReport(data);
    _addRedactionReport(cleaned.report);
    final error = ErrorSnapshot(
      id: makeOperatorId('err', ++_counter),
      timestamp: DateTime.now().toUtc(),
      type: type,
      message: message,
      stack: stack,
      source: source,
      handled: handled,
      fatal: fatal,
      data: cleaned.value as JsonMap? ?? const <String, Object?>{},
      redacted: cleaned.report.redacted,
    );
    _errors.add(error);
    if (_errors.length > 200) _errors.removeAt(0);
    _emitRuntimeEvent(OperatorRuntimeEventType.error, error);
    captureLog(
      'error',
      message,
      data: <String, Object?>{
        'type': type,
        'source': source,
        'handled': handled,
        'fatal': fatal,
      },
    );
  }

  Future<AppSnapshot> getSnapshot({
    bool refreshVisual = true,
    bool refreshProviders = true,
    bool refreshStorageProviders = true,
    bool refreshUiProviders = true,
    bool issueActionTargets = true,
    List<VisualFrame>? visualFrames,
    List<VisualCaptureTarget>? visualCaptureTargets,
  }) async {
    operatorCaptureStage(
      'sdk.routes',
      () => _refreshRouteProviders(emit: false),
    );
    if (refreshVisual)
      await operatorCaptureAsyncStage('sdk.visual', _refreshVisualFrames);
    final snapshotId = makeOperatorId('flutter_snap', ++_counter);
    final previousActiveSnapshotId = _activeSnapshotId;
    final previousIssuesActionTargets = _activeSnapshotIssuesActionTargets;
    _activeSnapshotId = snapshotId;
    _activeSnapshotIssuesActionTargets = issueActionTargets;
    late final UiTree ui;
    try {
      // A snapshot that issues action targets must run the UI providers in
      // this exact snapshot epoch. Reusing a cached tree here would pair the
      // new snapshotId with opaque references issued by an older snapshot.
      ui = operatorCaptureStage(
        'sdk.ui',
        () => _currentUi(
          refreshProviders: refreshUiProviders || issueActionTargets,
        ),
      );
    } finally {
      _activeSnapshotId = previousActiveSnapshotId;
      _activeSnapshotIssuesActionTargets = previousIssuesActionTargets;
    }
    final state = operatorCaptureStage(
      'sdk.state',
      () => _currentState(refreshProviders: refreshProviders),
    );
    final dialogs = _currentDialogs(ui);
    final storage = await operatorCaptureAsyncStage(
      'sdk.storage',
      () => _currentStorage(
        refreshProviders: refreshProviders && refreshStorageProviders,
      ),
    );
    return operatorCaptureStage(
      'sdk.assembly',
      () => AppSnapshot(
        snapshotId: snapshotId,
        timestamp: DateTime.now().toUtc(),
        app: AppInfo(
          appId: config.appId,
          name: config.name ?? config.appId,
          platform: OperatorPlatform.flutter,
          framework: 'flutter',
          version: config.version,
          environment: config.environment,
        ),
        userSession: const UserSession(),
        route: _route,
        ui: ui,
        state: state,
        forms: _currentForms(ui),
        network: NetworkTimeline(
          events: List<NetworkEvent>.unmodifiable(_networkEvents),
        ),
        logs: List<LogEvent>.unmodifiable(_logs),
        errors: List<ErrorSnapshot>.unmodifiable(_errors),
        dialogs: dialogs,
        storage: storage,
        visual: _currentVisual(
          ui,
          framesOverride: visualFrames,
          captureTargetsOverride: visualCaptureTargets,
        ),
        capabilities: flutterCapabilities(
          hasStateProviders: _stateProviders.isNotEmpty || _state.isNotEmpty,
          hasStorageProviders:
              _storageProviders.isNotEmpty || _storage.isNotEmpty,
          capturesScreenshots: canCaptureScreenshots,
          virtualization: _currentVirtualizationCapabilities(),
        ),
        redactions: mergeRedactionReports(_redactionReports),
      ),
    );
  }

  void _refreshRouteProviders({required bool emit}) {
    if (_routeRefreshers.isEmpty) return;
    for (final refresher in List<OperatorRouteRefresher>.of(_routeRefreshers)) {
      try {
        refresher(emit: emit);
      } catch (error, stack) {
        captureLog(
          'warn',
          'route refresher failed',
          source: OperatorLogSource.operatorRuntime,
          data: <String, Object?>{
            'error': error.toString(),
            'stack': stack.toString(),
          },
        );
      }
    }
  }

  Map<String, bool> _currentVirtualizationCapabilities() {
    final hasNetworkMocks = hasActiveNetworkMocks;
    final hasFirebaseMocks = hasActiveFirebaseMocks;
    return <String, bool>{
      ..._virtualizationCapabilities,
      'networkMocks.active': hasNetworkMocks,
      'network.activeMocks': hasNetworkMocks,
      'firebaseMocks.active': hasFirebaseMocks,
      'firebase.activeMocks': hasFirebaseMocks,
    };
  }

  List<DialogState> _currentDialogs(UiTree ui) {
    final explicit = List<DialogState>.from(_dialogs);
    if (explicit.any((dialog) => dialog.visible)) {
      return List<DialogState>.unmodifiable(explicit);
    }
    final inferred = _inferDialogFromUi(ui);
    return List<DialogState>.unmodifiable(<DialogState>[
      ...explicit,
      if (inferred != null) inferred,
    ]);
  }

  DialogState? _inferDialogFromUi(UiTree ui) {
    final visible = ui.elements.where((element) => element.visible).toList();
    final explicitDialog = visible.where(
      (element) => element.role == OperatorUiRole.dialog,
    );
    if (explicitDialog.isNotEmpty) {
      final title = _firstReadableText(explicitDialog) ?? 'Dialog';
      return DialogState(
        id: 'inferred-dialog-${title.hashCode.abs()}',
        role: 'dialog',
        title: title,
        buttons: _dialogButtons(visible),
        visible: true,
        confidence: 0.9,
      );
    }

    final texts =
        visible
            .map(_elementReadableText)
            .whereType<String>()
            .map(_normalizeDialogText)
            .where((text) => text.isNotEmpty)
            .toList();
    final hasClose = texts.any(_looksLikeCloseControl);
    final hasApply = texts.any(_looksLikeApplyControl);
    final hasFilter = texts.any((text) => text.contains('filter'));
    final hasSheetControls = hasClose && hasApply && hasFilter;
    if (!hasSheetControls) return null;
    final title = visible
        .map(_elementReadableText)
        .whereType<String>()
        .firstWhere(
          (text) => _looksLikeDialogTitle(text),
          orElse: () => hasFilter ? 'Filter' : 'Modal',
        );
    return DialogState(
      id: 'inferred-modal-${title.hashCode.abs()}',
      role: 'modal',
      title: title,
      buttons: _dialogButtons(visible),
      visible: true,
      confidence: 0.72,
    );
  }

  String? _firstReadableText(Iterable<UiElement> elements) {
    for (final element in elements) {
      final text = _elementReadableText(element);
      if (text != null && text.trim().isNotEmpty) return text.trim();
    }
    return null;
  }

  String? _elementReadableText(UiElement element) {
    final value = element.value;
    return element.label ??
        element.text ??
        (value is String ? value : null) ??
        element.hint;
  }

  List<String> _dialogButtons(List<UiElement> visible) {
    final primaryActions = <String>[];
    final secondaryActions = <String>[];
    for (final element in visible) {
      if (element.role != OperatorUiRole.button &&
          !element.actions.contains('tap') &&
          !element.actions.contains('click')) {
        continue;
      }
      final text = _elementReadableText(element)?.trim();
      if (text == null || text.isEmpty) continue;
      final normalized = _normalizeDialogText(text);
      if (_isNonActionDialogSemantics(text, normalized)) continue;
      final target =
          _looksLikeDialogActionControl(normalized)
              ? primaryActions
              : secondaryActions;
      if (primaryActions.contains(text) || secondaryActions.contains(text)) {
        continue;
      }
      target.add(text);
    }
    return <String>[...primaryActions, ...secondaryActions].take(12).toList();
  }

  String _normalizeDialogText(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  bool _looksLikeCloseControl(String text) =>
      text == 'close' || text == 'schließen' || text == 'schliessen';

  bool _looksLikeApplyControl(String text) =>
      text == 'apply' ||
      text == 'anwenden' ||
      text == 'done' ||
      text == 'fertig' ||
      text == 'ok';

  bool _looksLikeDialogActionControl(String text) =>
      _looksLikeCloseControl(text) ||
      _looksLikeApplyControl(text) ||
      text == 'cancel' ||
      text == 'abbrechen' ||
      text == 'save' ||
      text == 'speichern' ||
      text.contains(' löschen') ||
      text.endsWith(' löschen') ||
      text.contains(' clear') ||
      text.endsWith(' clear') ||
      text == 'clear';

  bool _isNonActionDialogSemantics(String text, String normalized) {
    if (normalized == 'selected' || normalized == 'not selected') return true;
    if (_looksLikeDialogActionControl(normalized)) return false;
    return text.length > 80;
  }

  bool _looksLikeDialogTitle(String text) {
    final normalized = _normalizeDialogText(text);
    return normalized == 'filter' ||
        normalized.startsWith('filter ') ||
        normalized.contains(' wähle ') ||
        normalized.contains(' choose ');
  }

  VisualSnapshot _currentVisual(
    UiTree ui, {
    List<VisualFrame>? framesOverride,
    List<VisualCaptureTarget>? captureTargetsOverride,
  }) {
    final frames = List<VisualFrame>.unmodifiable(
      framesOverride ?? _visualFrames.values,
    );
    final regions =
        ui.elements
            .map(
              (element) => VisualElementRegion(
                elementId: element.id,
                role: element.role == null ? null : _uiRoleName(element.role!),
                label: element.label,
                text: element.text,
                bounds: element.bounds,
                parentId: element.parentId,
                visible: element.visible,
                confidence: element.confidence,
              ),
            )
            .toList();
    final ocr =
        ui.elements
            .map(_visualTextRegion)
            .whereType<VisualTextRegion>()
            .toList();
    final hasWidgetTreeText = ui.elements.any(
      (element) => element.data['source'] == 'flutter_widget_text',
    );
    final analysis = _visualAnalysis(
      frames: frames,
      captureTargets: captureTargetsOverride,
      regions: regions,
      ocr: ocr,
      viewport: ui.viewport,
    );
    final hasUsablePixels = analysis['hasUsablePixels'] == true;
    return VisualSnapshot(
      capturedAt: DateTime.now().toUtc(),
      source: hasUsablePixels ? 'screenshot' : 'semantic_regions',
      frames: frames,
      captureTargets: List<VisualCaptureTarget>.unmodifiable(
        captureTargetsOverride ?? const <VisualCaptureTarget>[],
      ),
      regions: regions,
      ocr: ocr,
      redacted: frames.any((frame) => frame.redacted),
      metadata: <String, Object?>{
        'pixelBacked': hasUsablePixels,
        'hasUsablePixels': hasUsablePixels,
        'visualTrust': analysis['trust'],
        'visualCaptureComplete':
            (analysis['visualCapture'] as JsonMap?)?['complete'],
        'frameCount': frames.length,
        'regionCount': ui.elements.length,
        'textSource':
            hasWidgetTreeText
                ? 'semantic_ui+flutter_widget_text'
                : 'semantic_ui',
      },
      analysis: analysis,
    );
  }

  Future<void> _refreshVisualFrames() async {
    if (!config.privacy.captureScreenshots) return;
    await _enqueueVisualCapture(_refreshVisualFramesNow);
  }

  Future<void> _refreshVisualFramesNow() async {
    if (!config.privacy.captureScreenshots) return;
    for (final entry
        in Map<OperatorVisualFrameProvider, String>.from(
          _visualFrameProviders,
        ).entries) {
      try {
        final frame = await entry.key();
        if (frame != null) {
          _retainVisualFrame(
            frame,
            slot: _providerVisualSlot(entry.value, frame),
          );
        }
      } catch (error) {
        captureLog(
          'warn',
          'visual frame provider failed',
          data: <String, Object?>{'error': error.toString()},
        );
      }
    }
  }

  /// Captures pixels for one explicit `capture_visual` command.
  ///
  /// The provider must run during this invocation; retained frames never turn a failed capture
  /// into success. Each produced occurrence receives a fresh frame id, while the command-result
  /// snapshot and its capture time remain the causal authority rather than that id by itself.
  Future<List<VisualFrame>> captureVisual(String reason) async {
    return (await captureVisualResult(reason)).frames;
  }

  Future<OperatorVisualCaptureResult> captureVisualResult(String reason) async {
    return _enqueueVisualCapture(() => _captureVisualNow(reason));
  }

  Future<T> _enqueueVisualCapture<T>(Future<T> Function() operation) async {
    final previous = _visualCaptureTail;
    final release = Completer<void>();
    _visualCaptureTail = release.future;
    operatorCaptureMark('sdk.visual_queue', 'enter', {
      'depth': ++_diagnosticVisualQueueDepth,
    });
    try {
      try {
        await previous;
      } catch (_) {
        // A prior capture failure cannot poison the serialization lane.
      }
      operatorCaptureMark('sdk.visual_queue', 'exit', {
        'depth': _diagnosticVisualQueueDepth,
      });
      return await operation();
    } finally {
      _diagnosticVisualQueueDepth--;
      if (!release.isCompleted) release.complete();
    }
  }

  Future<OperatorVisualCaptureResult> _captureVisualNow(String reason) async {
    if (!config.privacy.captureScreenshots) {
      return OperatorVisualCaptureResult(
        frames: const <VisualFrame>[],
        captureTargets:
            _visualFrameProviders.isEmpty
                ? const <VisualCaptureTarget>[
                  VisualCaptureTarget(
                    targetId: 'flutter_visual_capture',
                    kind: 'provider',
                    frameIds: <String>[],
                    unavailableReason: 'no_visual_provider_installed',
                  ),
                ]
                : _visualFrameProviders.values
                    .map(
                      (providerId) => VisualCaptureTarget(
                        targetId: providerId,
                        kind: 'provider',
                        frameIds: const <String>[],
                        unavailableReason: 'screenshot_capture_disabled',
                      ),
                    )
                    .toList(growable: false),
      );
    }
    final captured = <VisualFrame>[];
    final captureTargets = <VisualCaptureTarget>[];
    for (final entry
        in Map<OperatorVisualFrameProvider, String>.from(
          _visualFrameProviders,
        ).entries) {
      try {
        final frame = await entry.key();
        if (frame == null) {
          captureTargets.add(
            VisualCaptureTarget(
              targetId: entry.value,
              kind: 'provider',
              frameIds: const <String>[],
              unavailableReason: 'provider_returned_no_frame',
            ),
          );
          continue;
        }
        final occurrence = VisualFrame(
          id: makeOperatorId('${frame.id}_capture', ++_counter),
          surfaceId: frame.surfaceId,
          documentGeneration: frame.documentGeneration,
          surfaceClip: frame.surfaceClip,
          surfaceScale: frame.surfaceScale,
          format: frame.format,
          encoding: frame.encoding,
          data: frame.data,
          width: frame.width,
          height: frame.height,
          pixelRatio: frame.pixelRatio,
          hash: frame.hash,
          metadataOnly: frame.metadataOnly,
          source: frame.source,
          redacted: frame.redacted,
        );
        _retainVisualFrame(
          occurrence,
          slot: _providerVisualSlot(entry.value, occurrence),
        );
        captured.add(occurrence);
        captureTargets.add(
          VisualCaptureTarget(
            targetId: entry.value,
            kind: 'provider',
            documentGeneration: occurrence.documentGeneration,
            frameIds: <String>[occurrence.id],
          ),
        );
      } catch (error) {
        captureLog(
          'warn',
          'visual frame provider failed',
          data: <String, Object?>{'error': error.toString(), 'reason': reason},
        );
        captureTargets.add(
          VisualCaptureTarget(
            targetId: entry.value,
            kind: 'provider',
            frameIds: const <String>[],
            unavailableReason: 'provider_capture_failed',
          ),
        );
      }
    }
    if (captured.isNotEmpty) {
      _emitRuntimeEvent(
        OperatorRuntimeEventType.visual,
        List<VisualFrame>.unmodifiable(captured),
      );
      _emit();
    }
    if (captureTargets.isEmpty) {
      captureTargets.add(
        const VisualCaptureTarget(
          targetId: 'flutter_visual_capture',
          kind: 'provider',
          frameIds: <String>[],
          unavailableReason: 'no_visual_provider_installed',
        ),
      );
    }
    return OperatorVisualCaptureResult(
      frames: List<VisualFrame>.unmodifiable(captured),
      captureTargets: List<VisualCaptureTarget>.unmodifiable(captureTargets),
    );
  }

  String _providerVisualSlot(String providerId, VisualFrame frame) =>
      '$providerId:${frame.surfaceId ?? 'root'}';

  void _retainVisualFrame(VisualFrame frame, {String? slot}) {
    final retainedSlot = slot ?? 'manual:${frame.surfaceId ?? frame.id}';
    // Reinsert a provider/surface slot so occurrence-specific ids replace the prior pixels from
    // that same source instead of evicting an unrelated provider. A frame id on one surface is
    // one picture: the capture layer's own post-frame capture and a provider refresh of the same
    // boundary replace each other, so a snapshot never lists stale pixels beside current ones.
    _visualFrames.removeWhere(
      (retained, existing) =>
          retained == retainedSlot ||
          (existing.id == frame.id && existing.surfaceId == frame.surfaceId),
    );
    _visualFrames[retainedSlot] = frame;
    while (_visualFrames.length > _maxRetainedVisualFrames) {
      _visualFrames.remove(_visualFrames.keys.first);
    }
  }

  List<FormSnapshot> _currentForms(UiTree ui) {
    final fields =
        ui.elements
            .where(
              (element) =>
                  element.role == OperatorUiRole.input ||
                  element.role == OperatorUiRole.checkbox ||
                  element.role == OperatorUiRole.radio ||
                  element.role == OperatorUiRole.switchRole,
            )
            .map((element) => _formFieldFromElement(element, ui.elements))
            .toList();
    if (fields.isEmpty) return const <FormSnapshot>[];
    return <FormSnapshot>[
      FormSnapshot(
        id: 'flutter-screen-form',
        name:
            _route.current.name ?? _route.current.title ?? _route.current.path,
        route: _route.current.path,
        visible: fields.any((field) => field.visible),
        enabled: fields.any((field) => field.enabled),
        fields: List<FormFieldSnapshot>.unmodifiable(fields),
        confidence: _average(fields.map((field) => field.confidence)),
      ),
    ];
  }

  FormFieldSnapshot _formFieldFromElement(
    UiElement element,
    List<UiElement> elements,
  ) {
    final label = _formFieldLabelForElement(element, elements);
    final secure = _isSecureFormField(element, label);
    return FormFieldSnapshot(
      id: element.id,
      name: element.data['name']?.toString() ?? element.platformId,
      role: element.role == null ? null : _uiRoleName(element.role!),
      label: label,
      value: secure ? '[SECURE_FIELD]' : element.value,
      placeholder: element.data['placeholder']?.toString() ?? element.hint,
      checked: element.checked,
      selected: element.selected,
      enabled: element.enabled,
      visible: element.visible,
      secure: secure,
      required: element.data['required'] as bool?,
      errors:
          (element.data['errors'] as List<Object?>?)
              ?.map((error) => error.toString())
              .toList() ??
          const <String>[],
      confidence: element.confidence,
    );
  }

  bool _isSecureFormField(UiElement element, String? label) {
    if (element.data['secure'] == true ||
        element.data['secureTextEntry'] == true ||
        element.value == '[SECURE_FIELD]') {
      return true;
    }
    final descriptor =
        <String?>[
          label,
          element.label,
          element.text,
          element.hint,
          element.data['name']?.toString(),
          element.platformId,
        ].whereType<String>().join(' ').toLowerCase();
    if (descriptor.contains('password') ||
        descriptor.contains('passcode') ||
        descriptor.contains('pin') ||
        descriptor.contains('otp') ||
        descriptor.contains('secret')) {
      return true;
    }
    return _looksLikeMaskedSecureValue(element.value);
  }

  bool _looksLikeMaskedSecureValue(Object? value) {
    if (value is! String) return false;
    final compact = value.runes.where((rune) => !_isWhitespaceRune(rune));
    final runes = compact.toList(growable: false);
    if (runes.isEmpty) return false;
    return runes.every(_isMaskRune);
  }

  bool _isWhitespaceRune(int rune) =>
      rune == 0x20 || rune == 0x09 || rune == 0x0a || rune == 0x0d;

  bool _isMaskRune(int rune) =>
      rune == 0x002a ||
      rune == 0x00b7 ||
      rune == 0x2022 ||
      rune == 0x2219 ||
      rune == 0x25cf ||
      rune == 0x2b24;

  String? _formFieldLabelForElement(
    UiElement element,
    List<UiElement> elements,
  ) {
    final direct = _nonEmptyText(element.label) ?? _nonEmptyText(element.text);
    if (direct != null) return direct;
    final role = element.role;
    if (role != OperatorUiRole.checkbox &&
        role != OperatorUiRole.radio &&
        role != OperatorUiRole.switchRole) {
      return null;
    }
    final fieldBounds = element.bounds;
    if (fieldBounds == null) return null;

    _FormLabelCandidate? best;
    for (final candidate in elements) {
      if (candidate.id == element.id || candidate.visible == false) continue;
      final text =
          _nonEmptyText(candidate.label) ??
          _nonEmptyText(candidate.text) ??
          _nonEmptyText(candidate.value);
      final candidateBounds = candidate.bounds;
      if (text == null || candidateBounds == null) continue;
      if (_isFormControlRole(candidate.role)) continue;
      final score = _formLabelAssociationScore(
        field: element,
        fieldBounds: fieldBounds,
        candidate: candidate,
        candidateBounds: candidateBounds,
      );
      if (score == null) continue;
      if (best == null || score > best.score) {
        best = _FormLabelCandidate(text, score);
      }
    }
    return best?.label;
  }

  StorageSnapshot? _retainedStorage() {
    final replacedAreas =
        _storageProviders.values.expand((areas) => areas).toSet();
    final entries =
        _storage.values
            .where((entry) => !replacedAreas.contains(entry.area))
            .toList();
    return entries.isEmpty
        ? null
        : StorageSnapshot(entries: List.unmodifiable(entries));
  }

  Future<StorageSnapshot?> _currentStorage({
    bool refreshProviders = true,
  }) async {
    final entries = <StorageEntrySnapshot>[...?_retainedStorage()?.entries];
    if (!refreshProviders) {
      if (entries.isEmpty) return null;
      return StorageSnapshot(
        entries: List<StorageEntrySnapshot>.unmodifiable(entries),
      );
    }
    for (final provider in _storageProviders.keys.toList()) {
      try {
        for (final entry in await provider()) {
          final forceMetadataOnly =
              entry.metadataOnly ||
              _isSensitiveStorageKey(entry.key) ||
              redactor.shouldRedactKey(entry.key);
          final cleaned =
              forceMetadataOnly
                  ? const RedactionResult(
                    value: null,
                    report: RedactionReport(
                      redacted: false,
                      fields: <String>[],
                      paths: <String>[],
                    ),
                  )
                  : redactor.cleanWithReport(entry.value);
          _addRedactionReport(cleaned.report);
          if (forceMetadataOnly && !entry.metadataOnly) {
            _addRedactionReport(
              RedactionReport(
                redacted: true,
                fields: <String>[entry.key],
                paths: <String>['\$.storage.${entry.key}'],
              ),
            );
          }
          entries.add(
            StorageEntrySnapshot(
              area: entry.area,
              key: entry.key,
              value: forceMetadataOnly ? null : cleaned.value,
              valueType: entry.valueType,
              sizeBytes: entry.sizeBytes,
              namespace: entry.namespace,
              source: entry.source,
              updatedAt: entry.updatedAt,
              confidence: entry.confidence,
              metadataOnly: forceMetadataOnly,
              redacted:
                  entry.redacted ||
                  forceMetadataOnly ||
                  cleaned.report.redacted,
            ),
          );
        }
      } catch (error) {
        final cleaned = redactor.cleanWithReport(<String, Object?>{
          'error': error.toString(),
        });
        _addRedactionReport(cleaned.report);
        _captureLogEntry(
          'warn',
          'storage provider failed',
          _inferLogSource('storage provider failed'),
          cleaned.value as JsonMap? ?? const <String, Object?>{},
          cleaned.report.redacted,
        );
      }
    }
    if (entries.isEmpty) return null;
    return StorageSnapshot(
      entries: List<StorageEntrySnapshot>.unmodifiable(entries),
    );
  }

  List<StateStoreSnapshot> _currentState({bool refreshProviders = true}) {
    final stores = <StateStoreSnapshot>[..._state];
    if (refreshProviders) {
      for (final provider in _stateProviders) {
        try {
          final providerStores = <StateStoreSnapshot>[];
          for (final store in provider()) {
            final cleaned = redactor.cleanWithReport(store.value);
            _addRedactionReport(cleaned.report);
            providerStores.add(
              StateStoreSnapshot(
                source: store.source,
                name: store.name,
                value: cleaned.value,
                schema: store.schema,
                confidence: store.confidence,
                redacted: store.redacted || cleaned.report.redacted,
              ),
            );
          }
          _stateProviderLastGood[provider] =
              List<StateStoreSnapshot>.unmodifiable(providerStores);
          _stateProviderFailures.remove(provider);
          for (final store in providerStores) {
            _replaceStateStore(stores, store);
          }
        } catch (error) {
          _recordStateProviderFailure(provider, stores, error);
        }
      }
    }
    for (final injected in _injectedState.values) {
      _replaceStateStore(stores, injected);
    }
    return List<StateStoreSnapshot>.unmodifiable(stores);
  }

  void _replaceStateStore(
    List<StateStoreSnapshot> stores,
    StateStoreSnapshot store,
  ) {
    stores.removeWhere(
      (item) => _sameStateStore(item, source: store.source, name: store.name),
    );
    stores.add(store);
  }

  void _recordStateProviderFailure(
    OperatorStateProvider provider,
    List<StateStoreSnapshot> stores,
    Object error,
  ) {
    final cached =
        _stateProviderLastGood[provider] ?? const <StateStoreSnapshot>[];
    for (final store in cached) {
      _replaceStateStore(stores, store);
    }

    final failure = _stateProviderFailures.update(
      provider,
      (existing) => existing..count += 1,
      ifAbsent: () => _ObservationProviderFailure(),
    );
    failure.lastMessage = error.toString();
    final transient = _isTransientObservationFailure(error);
    final hasCachedState = cached.isNotEmpty;
    final shouldLog =
        failure.count <= 2 || failure.count == 5 || failure.count % 10 == 0;
    if (!shouldLog) return;

    final cleaned = redactor.cleanWithReport(<String, Object?>{
      'error': error.toString(),
      'failureCount': failure.count,
      'transient': transient,
      'usedLastGoodState': hasCachedState,
      'cachedStoreCount': cached.length,
    });
    _addRedactionReport(cleaned.report);
    _captureLogEntry(
      hasCachedState || transient ? 'debug' : 'warn',
      hasCachedState
          ? 'state provider temporarily unavailable; using last observation'
          : 'state provider failed',
      OperatorLogSource.operatorRuntime,
      cleaned.value as JsonMap? ?? const <String, Object?>{},
      cleaned.report.redacted,
    );
  }

  bool _isTransientObservationFailure(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('indexischanging') ||
        message.contains('during build') ||
        message.contains('deactivated widget') ||
        message.contains('not mounted') ||
        message.contains('no element') ||
        message.contains('ancestor lookup');
  }

  UiTree _currentUi({bool refreshProviders = true}) {
    final elements = <UiElement>[
      ..._ui.elements,
      ..._registeredUiElements.values,
    ];
    if (refreshProviders) {
      for (final provider in _uiProviders) {
        try {
          elements.addAll(provider());
        } catch (error) {
          final cleaned = redactor.cleanWithReport(<String, Object?>{
            'error': error.toString(),
          });
          _addRedactionReport(cleaned.report);
          _captureLogEntry(
            'warn',
            'ui provider failed',
            _inferLogSource('ui provider failed'),
            cleaned.value as JsonMap? ?? const <String, Object?>{},
            cleaned.report.redacted,
          );
        }
      }
    }
    final byId = <String, UiElement>{};
    for (final element in elements) {
      byId[element.id] = _patchUiElement(element, _formPatches.values);
    }
    var focusedElementId = _ui.focusedElementId;
    for (final element in byId.values) {
      if (element.data['focused'] == true) {
        focusedElementId = element.id;
        break;
      }
    }
    return UiTree(
      rootId: _ui.rootId,
      elements: List<UiElement>.unmodifiable(byId.values),
      viewport: _resolvedViewport(_ui.viewport, byId.values),
      focusedElementId: focusedElementId,
    );
  }

  LogEvent _captureLogEntry(
    String level,
    String message,
    OperatorLogSource source,
    JsonMap data,
    bool redacted,
  ) {
    final log = LogEvent(
      id: makeOperatorId('log', ++_counter),
      timestamp: DateTime.now().toUtc(),
      level: level,
      message: message,
      source: source,
      data: data,
      redacted: redacted,
    );
    _logs.add(log);
    if (_logs.length > 200) _logs.removeAt(0);
    return log;
  }

  OperatorLogSource _inferLogSource(String message) {
    if (message.startsWith('operator ') ||
        message.startsWith('flutter http ') ||
        message.startsWith('http ') ||
        message == 'visual pixel capture failed' ||
        message == 'shared_preferences observer unavailable' ||
        message == 'storage provider failed' ||
        message == 'state provider failed' ||
        message == 'ui provider failed') {
      return OperatorLogSource.operatorRuntime;
    }
    return OperatorLogSource.app;
  }

  bool _consumeOperatorRuntimeErrorSuppression(String message) {
    final now = DateTime.now().toUtc();
    _operatorErrorSuppressions.removeWhere(
      (suppression) => suppression.expiresAt.isBefore(now),
    );
    final index = _operatorErrorSuppressions.indexWhere(
      (suppression) => message.contains(suppression.fragment),
    );
    if (index < 0) return false;
    _operatorErrorSuppressions.removeAt(index);
    return true;
  }

  void _addRedactionReport(RedactionReport report) {
    _redactionReports.add(report);
    if (_redactionReports.length > 200) _redactionReports.removeAt(0);
  }

  void _assertNonProduction(String operation) {
    if (config.environment == OperatorEnvironment.production) {
      throw StateError('$operation is only available in dev or staging');
    }
  }

  void _emit() {
    if (_snapshots.isClosed) return;
    unawaited(
      getSnapshot(
        refreshVisual: false,
        issueActionTargets: false,
        refreshStorageProviders: false,
      ).then((snapshot) {
        if (!_snapshots.isClosed) _snapshots.add(snapshot);
        _emitRuntimeEvent(
          OperatorRuntimeEventType.snapshot,
          snapshot,
          snapshotId: snapshot.snapshotId,
        );
      }),
    );
  }

  void _emitRuntimeEvent(
    OperatorRuntimeEventType type,
    Object? payload, {
    String? snapshotId,
  }) {
    if (_events.isClosed) return;
    _events.add(
      OperatorRuntimeEvent(
        type: type,
        sequence: ++_eventCounter,
        timestamp: DateTime.now().toUtc(),
        snapshotId: snapshotId,
        payload: payload,
      ),
    );
  }
}

class _OperatorRuntimeErrorSuppression {
  const _OperatorRuntimeErrorSuppression({
    required this.fragment,
    required this.expiresAt,
  });

  final String fragment;
  final DateTime expiresAt;
}

class _ObservationProviderFailure {
  int count = 1;
  String? lastMessage;
}

class OperatorRouteObserver extends RouteObserver<PageRoute<dynamic>> {
  OperatorRouteObserver(this.operator);

  final OperatorFlutter operator;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _capture(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) _capture(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute != null) _capture(previousRoute);
  }

  void _capture(Route<dynamic> route) {
    operator.captureRoute(
      name: route.settings.name,
      path: route.settings.name,
      screenClass: route.runtimeType.toString(),
    );
  }
}

OperatorCapabilities flutterCapabilities({
  required bool hasStateProviders,
  required bool hasStorageProviders,
  required bool capturesScreenshots,
  Map<String, bool> virtualization = const <String, bool>{},
}) {
  return OperatorCapabilities(
    observes: <String, bool>{
      'ui': true,
      'accessibility': true,
      'route': true,
      'network': true,
      'state': hasStateProviders,
      'logs': true,
      'storage': hasStorageProviders,
      'dialogs': true,
    },
    actions: const <String, bool>{
      'tap': true,
      'type': true,
      'clear': true,
      'hover': true,
      'key': kIsWeb,
      'drag': true,
      'touch': true,
      'tapPoint': true,
      'repeatedPress': true,
      'scroll': true,
      'scrollIntoView': true,
      'scrollTo': true,
      'navigateToRoute': true,
      'wait': true,
    },
    selectors: const <String, bool>{
      'stableId': true,
      'accessibilityLabel': true,
      'visibleText': true,
      'cssSelector': false,
      'listContext': true,
      'coordinates': false,
    },
    verification: <String, bool>{
      'ui': true,
      'route': true,
      'network': true,
      'state': hasStateProviders,
      'logs': true,
    },
    privacy: <String, bool>{
      'redactsAtEdge': true,
      'capturesScreenshots': capturesScreenshots,
      'capturesSecureFields': false,
    },
    virtualization: Map<String, bool>.unmodifiable(virtualization),
  );
}

String _uiRoleName(OperatorUiRole role) =>
    role == OperatorUiRole.switchRole ? 'switch' : role.name;

bool _isFormControlRole(OperatorUiRole? role) {
  return role == OperatorUiRole.input ||
      role == OperatorUiRole.checkbox ||
      role == OperatorUiRole.radio ||
      role == OperatorUiRole.switchRole;
}

String? _nonEmptyText(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

double? _formLabelAssociationScore({
  required UiElement field,
  required ElementBounds fieldBounds,
  required UiElement candidate,
  required ElementBounds candidateBounds,
}) {
  if (field.parentId != null && candidate.parentId != field.parentId) {
    return null;
  }
  final verticalOverlap =
      math.min(
        fieldBounds.y + fieldBounds.height,
        candidateBounds.y + candidateBounds.height,
      ) -
      math.max(fieldBounds.y, candidateBounds.y);
  final maxHeight = math.max(fieldBounds.height, candidateBounds.height);
  final centerDistance =
      (fieldBounds.y + fieldBounds.height / 2) -
      (candidateBounds.y + candidateBounds.height / 2);
  final verticalCenterDistance = centerDistance.abs();
  final verticallyRelated =
      verticalOverlap > 0 ||
      verticalCenterDistance <= math.max(10, maxHeight * 0.55);
  if (!verticallyRelated) return null;

  final fieldRight = fieldBounds.x + fieldBounds.width;
  final candidateRight = candidateBounds.x + candidateBounds.width;
  final rightOfControl = candidateBounds.x >= fieldBounds.x;
  final horizontalGap =
      rightOfControl
          ? math.max(0, candidateBounds.x - fieldRight)
          : math.max(0, fieldBounds.x - candidateRight);
  if (horizontalGap > math.max(48, fieldBounds.width * 1.5)) return null;

  final candidateArea = candidateBounds.width * candidateBounds.height;
  final fieldArea = fieldBounds.width * fieldBounds.height;
  if (candidateArea > fieldArea * 30 && fieldArea > 0) return null;

  var score = 100.0;
  if (candidate.parentId == field.parentId) score += 100;
  if (rightOfControl) score += 40;
  score += math.max(0, 60 - verticalCenterDistance);
  score += math.max(0, 40 - horizontalGap);
  if (candidate.role == OperatorUiRole.text) score += 12;
  if (candidate.role == OperatorUiRole.button) score += 8;
  return score;
}

class _FormLabelCandidate {
  const _FormLabelCandidate(this.label, this.score);

  final String label;
  final double score;
}

VisualTextRegion? _visualTextRegion(UiElement element) {
  final value = element.value;
  final text = _firstNonEmpty(<String?>[
    element.text,
    element.label,
    if (value is String || value is num) value.toString(),
    element.hint,
  ]);
  if (text == null) return null;
  return VisualTextRegion(
    text: text,
    bounds: element.bounds,
    confidence: element.confidence > 0.86 ? 0.86 : element.confidence,
  );
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) return value;
  }
  return null;
}

JsonMap _visualAnalysis({
  required List<VisualFrame> frames,
  List<VisualCaptureTarget>? captureTargets,
  required List<VisualElementRegion> regions,
  required List<VisualTextRegion> ocr,
  required ViewportSnapshot viewport,
}) {
  final visible = regions.where((region) => region.visible).toList();
  final texts =
      ocr
          .map((region) => region.text.trim())
          .where((text) => text.isNotEmpty)
          .toSet()
          .take(100)
          .toList();
  final findings = <JsonMap>[];
  final frameAnalysis = <JsonMap>[];
  var aggregateBytes = 0;
  for (final frame in frames.take(_visualFrameInspectionLimit)) {
    var analysis = _inspectOperatorFlutterVisualFrame(frame);
    final encodedBytes = analysis['encodedByteLength'];
    final nextAggregate =
        aggregateBytes + (encodedBytes is int ? encodedBytes : 0);
    if (nextAggregate > _visualAggregateDecodedByteLimit) {
      analysis = <String, Object?>{
        ...analysis,
        'integrity': 'invalid',
        'lowInformation': false,
        'failure': 'aggregate_byte_limit',
      };
    }
    aggregateBytes = nextAggregate;
    frameAnalysis.add(analysis);
  }
  final frameAnalysisOmittedCount = math.max(
    0,
    frames.length - frameAnalysis.length,
  );
  final validFrameCount =
      frameAnalysis
          .where((analysis) => analysis['integrity'] == 'valid')
          .length;
  final trustedFrameCount =
      frameAnalysis
          .where(
            (analysis) =>
                analysis['integrity'] == 'valid' &&
                analysis['lowInformation'] != true,
          )
          .length;
  final invalidFrameCount =
      frameAnalysis
          .where((analysis) => analysis['integrity'] == 'invalid')
          .length +
      frameAnalysisOmittedCount;
  final metadataOnlyFrameCount =
      frameAnalysis
          .where((analysis) => analysis['integrity'] == 'metadata_only')
          .length;
  final hasUsablePixels = validFrameCount > 0;
  final visualCapture = _resolveOperatorFlutterVisualCaptureSummary(
    frames: frames,
    frameAnalysis: frameAnalysis,
    captureTargets: captureTargets,
  );
  final trust =
      !hasUsablePixels
          ? 'untrusted'
          : trustedFrameCount == 0 ||
              invalidFrameCount > 0 ||
              metadataOnlyFrameCount > 0 ||
              visualCapture['complete'] != true
          ? 'partial'
          : 'trusted';
  if (visible.isEmpty) {
    findings.add(<String, Object?>{
      'type': 'no_visible_regions',
      'severity': 'error',
      'message': 'Snapshot has no visible UI regions.',
    });
  }
  if (texts.isEmpty) {
    findings.add(<String, Object?>{
      'type': 'no_visible_text',
      'severity': 'warn',
      'message': 'Snapshot has no readable visual text.',
    });
  }
  final validViewport = viewport.width > 0 && viewport.height > 0;
  if (!validViewport) {
    findings.add(<String, Object?>{
      'type': 'invalid_viewport',
      'severity': 'warn',
      'message':
          'Snapshot viewport is missing or zero-sized; viewport and occlusion findings are suppressed.',
    });
  }
  for (var index = 0; index < frameAnalysis.length; index += 1) {
    final frame = frames[index];
    final analysis = frameAnalysis[index];
    final integrity = analysis['integrity'];
    final failure = analysis['failure'];
    if (integrity == 'metadata_only') {
      findings.add(<String, Object?>{
        'type': 'metadata_only_frame',
        'severity': 'info',
        'frameId': frame.id,
        'message':
            'Visual frame ${frame.id} is metadata-only and does not contain pixels.',
      });
    } else if (integrity == 'invalid') {
      final type =
          failure == 'invalid_dimensions'
              ? 'invalid_frame_size'
              : failure == 'missing_data'
              ? 'missing_frame_data'
              : failure == 'codec_mismatch'
              ? 'frame_codec_mismatch'
              : failure == 'geometry_mismatch'
              ? 'frame_geometry_mismatch'
              : 'invalid_frame_encoding';
      findings.add(<String, Object?>{
        'type': type,
        'severity': 'error',
        'frameId': frame.id,
        'message':
            'Visual frame ${frame.id} failed encoded pixel validation: $failure.',
      });
    } else if (analysis['lowInformation'] == true) {
      findings.add(<String, Object?>{
        'type': 'low_information_frame',
        'severity': 'warn',
        'frameId': frame.id,
        'message':
            'Visual frame ${frame.id} is valid but highly compressed; corroborate detailed claims when no stronger frame exists.',
      });
    }
  }
  if (frameAnalysisOmittedCount > 0) {
    findings.add(<String, Object?>{
      'type': 'invalid_frame_encoding',
      'severity': 'error',
      'message':
          '$frameAnalysisOmittedCount visual frame(s) exceeded the bounded inspection limit.',
    });
  }
  for (final region in visible) {
    if (region.bounds == null && _interactiveVisualRole(region.role)) {
      findings.add(<String, Object?>{
        'type': 'missing_bounds',
        'severity': 'warn',
        'elementId': region.elementId,
        'message':
            'Interactive visual region ${region.elementId} has no bounds.',
      });
    }
    final bounds = region.bounds;
    if (validViewport && bounds != null && _outsideViewport(bounds, viewport)) {
      findings.add(<String, Object?>{
        'type': 'out_of_viewport',
        'severity': 'warn',
        'elementId': region.elementId,
        'message': 'Visual region ${region.elementId} is outside the viewport.',
      });
    }
    if (region.confidence < 0.5) {
      findings.add(<String, Object?>{
        'type': 'low_confidence_region',
        'severity': 'info',
        'elementId': region.elementId,
        'confidence': region.confidence,
        'message':
            'Visual region ${region.elementId} has low extraction confidence.',
      });
    }
  }
  final hasOcclusion =
      validViewport && _appendOcclusionFindings(visible, findings);
  final hasOutOfViewport = findings.any(
    (finding) => finding['type'] == 'out_of_viewport',
  );
  return <String, Object?>{
    'engine': 'operator_visual_v1',
    'pixelBacked': hasUsablePixels,
    'hasUsablePixels': hasUsablePixels,
    'trust': trust,
    'visualCapture': visualCapture,
    'validFrameCount': validFrameCount,
    'trustedFrameCount': trustedFrameCount,
    'invalidFrameCount': invalidFrameCount,
    'metadataOnlyFrameCount': metadataOnlyFrameCount,
    'frameAnalysisOmittedCount': frameAnalysisOmittedCount,
    'frames': frameAnalysis,
    'frameCount': frames.length,
    'visibleRegionCount': visible.length,
    'textCount': texts.length,
    'texts': texts,
    'findings': findings,
    'assertions': <String, Object?>{
      'hasVisibleRegions': visible.isNotEmpty,
      'hasVisibleText': texts.isNotEmpty,
      'hasPixels': hasUsablePixels,
      'hasInteractiveTargets': visible.any(
        (region) => _interactiveVisualRole(region.role),
      ),
      'hasOutOfViewportElements': hasOutOfViewport,
      'hasPossibleOcclusion': hasOcclusion,
    },
  };
}

const int _visualFrameInspectionLimit = 16;
const int _visualCaptureTargetLimit = 16;
const int _visualCaptureTargetIdChars = 160;
const int _visualCaptureReasonChars = 320;
const int _visualFrameDecodedByteLimit = 16 * 1024 * 1024;
const int _visualAggregateDecodedByteLimit = 64 * 1024 * 1024;
const int _visualFrameBase64SourceLimit =
    ((_visualFrameDecodedByteLimit + 2) ~/ 3) * 4 + 1024;
const int _lowInformationFrameArea = 100000;
const int _lowInformationDecodedBytes = 12 * 1024;
const double _visualFrameAspectTolerance = 0.02;
const double _visualSurfaceScaleLimit = 64;

VisualFrame _operatorFlutterFrameWithoutPixels(VisualFrame frame) =>
    VisualFrame(
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

JsonMap operatorFlutterVisualCaptureSummary({
  List<VisualFrame> frames = const <VisualFrame>[],
  List<VisualCaptureTarget>? captureTargets,
}) {
  final frameAnalysis = <JsonMap>[];
  var aggregateBytes = 0;
  for (final frame in frames.take(_visualFrameInspectionLimit)) {
    var analysis = _inspectOperatorFlutterVisualFrame(frame);
    final encodedBytes = analysis['encodedByteLength'];
    final nextAggregate =
        aggregateBytes + (encodedBytes is int ? encodedBytes : 0);
    if (nextAggregate > _visualAggregateDecodedByteLimit) {
      analysis = <String, Object?>{
        ...analysis,
        'integrity': 'invalid',
        'lowInformation': false,
        'failure': 'aggregate_byte_limit',
      };
    }
    aggregateBytes = nextAggregate;
    frameAnalysis.add(analysis);
  }
  return _resolveOperatorFlutterVisualCaptureSummary(
    frames: frames,
    frameAnalysis: frameAnalysis,
    captureTargets: captureTargets,
  );
}

JsonMap operatorFlutterResolveVisualAnalysis({
  required VisualSnapshot visual,
  required ViewportSnapshot viewport,
}) => _visualAnalysis(
  frames: visual.frames,
  captureTargets: visual.captureTargets,
  regions: visual.regions,
  ocr: visual.ocr,
  viewport: viewport,
);

JsonMap _resolveOperatorFlutterVisualCaptureSummary({
  required List<VisualFrame> frames,
  required List<JsonMap> frameAnalysis,
  List<VisualCaptureTarget>? captureTargets,
}) {
  final requestedTargets =
      captureTargets ??
      frames
          .map(
            (frame) => VisualCaptureTarget(
              targetId: frame.surfaceId ?? frame.id,
              kind: frame.surfaceId == null ? 'provider' : 'surface',
              documentGeneration: frame.documentGeneration,
              frameIds: <String>[frame.id],
            ),
          )
          .toList(growable: false);
  final integrityById = <String, JsonMap>{};
  for (final analysis in frameAnalysis) {
    final frameId = analysis['frameId'];
    if (frameId is! String) continue;
    final current = integrityById[frameId];
    if (current == null ||
        _operatorFlutterVisualIntegrityRank(analysis) >
            _operatorFlutterVisualIntegrityRank(current)) {
      integrityById[frameId] = analysis;
    }
  }
  final analyses = <JsonMap>[];
  for (
    var index = 0;
    index < math.min(requestedTargets.length, _visualCaptureTargetLimit);
    index += 1
  ) {
    final target = requestedTargets[index];
    var malformed = false;
    final trimmedTargetId = target.targetId.trim();
    if (trimmedTargetId.isEmpty ||
        trimmedTargetId != target.targetId ||
        trimmedTargetId.length > _visualCaptureTargetIdChars) {
      malformed = true;
    }
    final targetId = _boundedOperatorFlutterVisualText(
      trimmedTargetId.isEmpty ? 'capture-target-${index + 1}' : trimmedTargetId,
      _visualCaptureTargetIdChars,
    );
    final kind =
        target.kind == 'surface' || target.kind == 'provider'
            ? target.kind
            : 'provider';
    if (kind != target.kind) malformed = true;
    final frameReferenceOmitted = math.max(
      0,
      target.frameIds.length - _visualFrameInspectionLimit,
    );
    if (frameReferenceOmitted > 0) malformed = true;
    final frameIds = <String>[];
    for (final rawId in target.frameIds.take(_visualFrameInspectionLimit)) {
      final normalized = rawId.trim();
      if (normalized.isEmpty ||
          normalized != rawId ||
          normalized.length > _visualCaptureTargetIdChars) {
        malformed = true;
      }
      if (normalized.isEmpty) continue;
      final bounded = _boundedOperatorFlutterVisualText(
        normalized,
        _visualCaptureTargetIdChars,
      );
      if (!frameIds.contains(bounded)) frameIds.add(bounded);
    }
    final validFrameIds = <String>[];
    final invalidFrameIds = <String>[];
    for (final frameId in frameIds) {
      if (integrityById[frameId]?['integrity'] == 'valid') {
        validFrameIds.add(frameId);
      } else {
        invalidFrameIds.add(frameId);
      }
    }
    final rawReason = target.unavailableReason;
    final normalizedReason = rawReason?.trim();
    if (rawReason != null &&
        (normalizedReason == null || normalizedReason.isEmpty)) {
      malformed = true;
    }
    var reason =
        normalizedReason == null || normalizedReason.isEmpty
            ? null
            : _boundedOperatorFlutterVisualText(
              normalizedReason,
              _visualCaptureReasonChars,
            );
    final transportOmittedFrameCount =
        target.transportOmittedFrameCount != null &&
                target.transportOmittedFrameCount! >= 0
            ? target.transportOmittedFrameCount!
            : 0;
    if (target.transportOmittedFrameCount != null &&
        target.transportOmittedFrameCount! < 0) {
      malformed = true;
    }
    late final String status;
    if (transportOmittedFrameCount > 0) {
      status = 'transport_omitted';
      reason ??=
          '$transportOmittedFrameCount captured frame(s) were omitted during transport.';
    } else if (malformed ||
        invalidFrameIds.isNotEmpty ||
        (reason != null && validFrameIds.isNotEmpty)) {
      status = 'invalid';
      reason ??=
          frameReferenceOmitted > 0
              ? 'Capture target exceeded the $_visualFrameInspectionLimit-frame reference limit.'
              : 'Capture target did not resolve exclusively to valid delivered frames.';
    } else if (validFrameIds.isNotEmpty) {
      status = 'captured';
    } else {
      status = 'unavailable';
      reason ??= 'Requested capture target returned no frame.';
    }
    analyses.add(<String, Object?>{
      'targetId': targetId,
      'kind': kind,
      if (target.documentGeneration != null)
        'documentGeneration': target.documentGeneration,
      'status': status,
      'validFrameIds': validFrameIds,
      'invalidFrameIds': invalidFrameIds,
      'transportOmittedFrameCount': transportOmittedFrameCount,
      if (reason != null) 'reason': reason,
    });
  }
  int count(String status) =>
      analyses.where((analysis) => analysis['status'] == status).length;
  final targetAnalysisOmittedCount = math.max(
    0,
    requestedTargets.length - analyses.length,
  );
  final capturedTargetCount = count('captured');
  return <String, Object?>{
    'engine': 'operator_visual_capture_v1',
    'complete':
        requestedTargets.isNotEmpty &&
        targetAnalysisOmittedCount == 0 &&
        capturedTargetCount == requestedTargets.length,
    'requestedTargetCount': requestedTargets.length,
    'capturedTargetCount': capturedTargetCount,
    'unavailableTargetCount': count('unavailable'),
    'invalidTargetCount': count('invalid'),
    'transportOmittedTargetCount': count('transport_omitted'),
    'transportOmittedFrameCount': analyses.fold<int>(
      0,
      (total, target) =>
          total + (target['transportOmittedFrameCount'] as int? ?? 0),
    ),
    'targetAnalysisOmittedCount': targetAnalysisOmittedCount,
    'targets': analyses,
  };
}

int _operatorFlutterVisualIntegrityRank(JsonMap analysis) =>
    analysis['integrity'] == 'invalid'
        ? 3
        : analysis['integrity'] == 'metadata_only'
        ? 2
        : 1;

String _boundedOperatorFlutterVisualText(String value, int maximum) =>
    value.length <= maximum
        ? value
        : '${value.substring(0, math.max(0, maximum - 3))}...';

/// Byte- and geometry-backed acceptance used by both visual analysis and `capture_visual`.
bool operatorFlutterVisualFrameHasUsablePixels(VisualFrame frame) =>
    _inspectOperatorFlutterVisualFrame(frame)['integrity'] == 'valid';

JsonMap _inspectOperatorFlutterVisualFrame(VisualFrame frame) {
  final base = <String, Object?>{
    'frameId': frame.id,
    if (frame.surfaceId != null) 'surfaceId': frame.surfaceId,
  };
  if (frame.metadataOnly == true || frame.format == 'metadata') {
    return <String, Object?>{
      ...base,
      'integrity': 'metadata_only',
      'lowInformation': false,
    };
  }
  final extent =
      frame.surfaceClip ??
      ElementBounds(x: 0, y: 0, width: frame.width, height: frame.height);
  final surfaceScaleX = frame.surfaceScale?.x ?? 1;
  final surfaceScaleY = frame.surfaceScale?.y ?? 1;
  if (!frame.width.isFinite ||
      !frame.height.isFinite ||
      !extent.width.isFinite ||
      !extent.height.isFinite ||
      frame.width <= 0 ||
      frame.height <= 0 ||
      extent.width <= 0 ||
      extent.height <= 0) {
    return _invalidVisualFrame(base, 'invalid_dimensions');
  }
  if (!surfaceScaleX.isFinite ||
      !surfaceScaleY.isFinite ||
      surfaceScaleX <= 0 ||
      surfaceScaleY <= 0 ||
      surfaceScaleX > _visualSurfaceScaleLimit ||
      surfaceScaleY > _visualSurfaceScaleLimit) {
    return _invalidVisualFrame(base, 'invalid_surface_scale');
  }
  if (frame.data == null || frame.data!.isEmpty) {
    return _invalidVisualFrame(base, 'missing_data');
  }
  if (frame.format != 'png' &&
      frame.format != 'jpeg' &&
      frame.format != 'webp') {
    return _invalidVisualFrame(base, 'unsupported_format');
  }
  final payload = _normalizedFlutterVisualPayload(frame);
  if (payload == null) return _invalidVisualFrame(base, 'invalid_encoding');
  if (payload.byteLength > _visualFrameDecodedByteLimit) {
    return _invalidVisualFrame(
      base,
      'frame_byte_limit',
      encodedByteLength: payload.byteLength,
    );
  }
  final encoded = _encodedFlutterVisualFrame(payload.bytes);
  if (encoded == null) {
    return _invalidVisualFrame(
      base,
      'unreadable_header',
      encodedByteLength: payload.byteLength,
    );
  }
  final encodedFields = <String, Object?>{
    'encodedFormat': encoded.format,
    'encodedWidth': encoded.width,
    'encodedHeight': encoded.height,
    'encodedByteLength': payload.byteLength,
  };
  if (encoded.format != frame.format ||
      (payload.mimeFormat != null && payload.mimeFormat != frame.format)) {
    return <String, Object?>{
      ..._invalidVisualFrame(base, 'codec_mismatch'),
      ...encodedFields,
    };
  }
  final pixelRatio = frame.pixelRatio ?? 1;
  final encodedAspect = encoded.width / encoded.height;
  final declaredAspect =
      (extent.width * surfaceScaleX) / (extent.height * surfaceScaleY);
  if (!pixelRatio.isFinite ||
      pixelRatio <= 0 ||
      (encodedAspect - declaredAspect).abs() >
          math.max(encodedAspect, declaredAspect) *
              _visualFrameAspectTolerance ||
      (encoded.width - extent.width * surfaceScaleX * pixelRatio).abs() > 1 ||
      (encoded.height - extent.height * surfaceScaleY * pixelRatio).abs() > 1 ||
      (frame.width - extent.width).abs() > 1 ||
      (frame.height - extent.height).abs() > 1) {
    return <String, Object?>{
      ..._invalidVisualFrame(base, 'geometry_mismatch'),
      ...encodedFields,
    };
  }
  final extentArea = extent.width * extent.height;
  final lowInformation =
      extentArea <= 1 ||
      (extentArea > _lowInformationFrameArea &&
          payload.byteLength < _lowInformationDecodedBytes);
  return <String, Object?>{
    ...base,
    'integrity': 'valid',
    'lowInformation': lowInformation,
    ...encodedFields,
  };
}

JsonMap _invalidVisualFrame(
  JsonMap base,
  String failure, {
  int? encodedByteLength,
}) => <String, Object?>{
  ...base,
  'integrity': 'invalid',
  'lowInformation': false,
  'failure': failure,
  if (encodedByteLength != null) 'encodedByteLength': encodedByteLength,
};

class _FlutterVisualPayload {
  const _FlutterVisualPayload({
    required this.bytes,
    required this.byteLength,
    this.mimeFormat,
  });

  final Uint8List bytes;
  final int byteLength;
  final String? mimeFormat;
}

_FlutterVisualPayload? _normalizedFlutterVisualPayload(VisualFrame frame) {
  var encoded = frame.data!;
  if (encoded.length > _visualFrameBase64SourceLimit) return null;
  String? mimeFormat;
  if (encoded.startsWith('data:')) {
    final comma = encoded.indexOf(',');
    if (comma < 0) return null;
    final descriptor = encoded.substring(5, comma).toLowerCase().split(';');
    if (!descriptor.contains('base64')) return null;
    mimeFormat = switch (descriptor.first) {
      'image/png' => 'png',
      'image/jpeg' || 'image/jpg' => 'jpeg',
      'image/webp' => 'webp',
      _ => null,
    };
    if (mimeFormat == null) return null;
    encoded = encoded.substring(comma + 1);
  } else if (frame.encoding == 'data_url') {
    return null;
  }
  if (encoded.isEmpty ||
      encoded.length % 4 == 1 ||
      !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(encoded)) {
    return null;
  }
  try {
    final bytes = base64Decode(base64.normalize(encoded));
    if (bytes.isEmpty) return null;
    return _FlutterVisualPayload(
      bytes: bytes,
      byteLength: bytes.length,
      mimeFormat: mimeFormat,
    );
  } catch (_) {
    return null;
  }
}

class _EncodedFlutterVisualFrame {
  const _EncodedFlutterVisualFrame(this.format, this.width, this.height);

  final String format;
  final int width;
  final int height;
}

_EncodedFlutterVisualFrame? _encodedFlutterVisualFrame(Uint8List bytes) =>
    _pngFlutterVisualFrame(bytes) ??
    _jpegFlutterVisualFrame(bytes) ??
    _webpFlutterVisualFrame(bytes);

_EncodedFlutterVisualFrame? _pngFlutterVisualFrame(Uint8List bytes) {
  const signature = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length < 24) return null;
  for (var index = 0; index < signature.length; index += 1) {
    if (bytes[index] != signature[index]) return null;
  }
  if (!_asciiMatches(bytes, 12, 'IHDR')) return null;
  return _EncodedFlutterVisualFrame(
    'png',
    _readUint32Be(bytes, 16),
    _readUint32Be(bytes, 20),
  );
}

_EncodedFlutterVisualFrame? _jpegFlutterVisualFrame(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return null;
  var offset = 2;
  while (offset + 3 < bytes.length) {
    if (bytes[offset] != 0xff) return null;
    final marker = bytes[offset + 1];
    if (marker == 0xff) {
      offset += 1;
      continue;
    }
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd9)) {
      offset += 2;
      continue;
    }
    if (marker == 0xda) return null;
    final length = (bytes[offset + 2] << 8) + bytes[offset + 3];
    if (length < 2) return null;
    final startOfFrame =
        marker >= 0xc0 &&
        marker <= 0xcf &&
        marker != 0xc4 &&
        marker != 0xc8 &&
        marker != 0xcc;
    if (startOfFrame) {
      if (offset + 9 > bytes.length) return null;
      return _EncodedFlutterVisualFrame(
        'jpeg',
        (bytes[offset + 7] << 8) + bytes[offset + 8],
        (bytes[offset + 5] << 8) + bytes[offset + 6],
      );
    }
    offset += 2 + length;
  }
  return null;
}

_EncodedFlutterVisualFrame? _webpFlutterVisualFrame(Uint8List bytes) {
  if (bytes.length < 16 ||
      !_asciiMatches(bytes, 0, 'RIFF') ||
      !_asciiMatches(bytes, 8, 'WEBP')) {
    return null;
  }
  if (_asciiMatches(bytes, 12, 'VP8X')) {
    if (bytes.length < 30) return null;
    return _EncodedFlutterVisualFrame(
      'webp',
      _readUint24Le(bytes, 24) + 1,
      _readUint24Le(bytes, 27) + 1,
    );
  }
  if (_asciiMatches(bytes, 12, 'VP8 ')) {
    if (bytes.length < 30 ||
        bytes[23] != 0x9d ||
        bytes[24] != 0x01 ||
        bytes[25] != 0x2a) {
      return null;
    }
    return _EncodedFlutterVisualFrame(
      'webp',
      ((bytes[27] << 8) | bytes[26]) & 0x3fff,
      ((bytes[29] << 8) | bytes[28]) & 0x3fff,
    );
  }
  if (_asciiMatches(bytes, 12, 'VP8L')) {
    if (bytes.length < 25 || bytes[20] != 0x2f) return null;
    final bits =
        (bytes[24] << 24) + (bytes[23] << 16) + (bytes[22] << 8) + bytes[21];
    return _EncodedFlutterVisualFrame(
      'webp',
      (bits & 0x3fff) + 1,
      ((bits >> 14) & 0x3fff) + 1,
    );
  }
  return null;
}

int _readUint32Be(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) +
    (bytes[offset + 1] << 16) +
    (bytes[offset + 2] << 8) +
    bytes[offset + 3];

int _readUint24Le(Uint8List bytes, int offset) =>
    bytes[offset] + (bytes[offset + 1] << 8) + (bytes[offset + 2] << 16);

bool _asciiMatches(Uint8List bytes, int offset, String text) {
  if (offset + text.length > bytes.length) return false;
  for (var index = 0; index < text.length; index += 1) {
    if (bytes[offset + index] != text.codeUnitAt(index)) return false;
  }
  return true;
}

bool _interactiveVisualRole(String? role) => <String>{
  'button',
  'link',
  'input',
  'checkbox',
  'radio',
  'switch',
  'tab',
  'listitem',
}.contains(role);

ViewportSnapshot _resolvedViewport(
  ViewportSnapshot viewport,
  Iterable<UiElement> elements,
) {
  if (viewport.width > 0 && viewport.height > 0) return viewport;
  try {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) {
      final view = views.first;
      final size = view.physicalSize / view.devicePixelRatio;
      if (size.width > 0 && size.height > 0) {
        return ViewportSnapshot(
          width: size.width,
          height: size.height,
          scrollX: viewport.scrollX,
          scrollY: viewport.scrollY,
        );
      }
    }
  } catch (_) {
    // Operator can run network/storage capture before a Flutter binding exists.
  }
  var maxX = 0.0;
  var maxY = 0.0;
  for (final element in elements) {
    final bounds = element.bounds;
    if (bounds == null) continue;
    maxX = math.max(maxX, bounds.x + bounds.width);
    maxY = math.max(maxY, bounds.y + bounds.height);
  }
  return ViewportSnapshot(
    width: maxX,
    height: maxY,
    scrollX: viewport.scrollX,
    scrollY: viewport.scrollY,
  );
}

bool _outsideViewport(ElementBounds bounds, ViewportSnapshot viewport) {
  if (viewport.width <= 0 || viewport.height <= 0) return false;
  return bounds.x + bounds.width < 0 ||
      bounds.y + bounds.height < 0 ||
      bounds.x > viewport.width ||
      bounds.y > viewport.height;
}

bool _appendOcclusionFindings(
  List<VisualElementRegion> regions,
  List<JsonMap> findings,
) {
  final bounded =
      regions
          .where(
            (region) =>
                region.bounds != null &&
                region.bounds!.width > 0 &&
                region.bounds!.height > 0,
          )
          .toList();
  var found = false;
  for (var i = 0; i < bounded.length; i += 1) {
    for (var j = i + 1; j < bounded.length; j += 1) {
      final left = bounded[i];
      final right = bounded[j];
      if (!_isVisualOcclusionCandidate(left) ||
          !_isVisualOcclusionCandidate(right)) {
        continue;
      }
      if (_isKnownParentChildRegion(left, right)) continue;
      if (_overlapRatio(left.bounds!, right.bounds!) < 0.85) continue;
      if (_isContainerOverlap(left.bounds!, right.bounds!)) continue;
      found = true;
      findings.add(<String, Object?>{
        'type': 'possible_occlusion',
        'severity': 'warn',
        'elementId': left.elementId,
        'message':
            'Visual regions ${left.elementId} and ${right.elementId} overlap heavily.',
      });
      if (findings.length >= 20) return true;
    }
  }
  return found;
}

bool _isVisualOcclusionCandidate(VisualElementRegion region) {
  return (region.label?.trim().isNotEmpty ?? false) ||
      (region.text?.trim().isNotEmpty ?? false) ||
      region.role == 'input';
}

bool _isKnownParentChildRegion(
  VisualElementRegion left,
  VisualElementRegion right,
) {
  return left.parentId == right.elementId || right.parentId == left.elementId;
}

double _overlapRatio(ElementBounds left, ElementBounds right) {
  final x =
      (left.x + left.width < right.x || right.x + right.width < left.x)
          ? 0.0
          : (_min(left.x + left.width, right.x + right.width) -
              _max(left.x, right.x));
  final y =
      (left.y + left.height < right.y || right.y + right.height < left.y)
          ? 0.0
          : (_min(left.y + left.height, right.y + right.height) -
              _max(left.y, right.y));
  final minArea = _min(left.width * left.height, right.width * right.height);
  return minArea <= 0 ? 0 : (x * y) / minArea;
}

bool _isContainerOverlap(ElementBounds left, ElementBounds right) {
  final leftArea = left.width * left.height;
  final rightArea = right.width * right.height;
  if (leftArea <= 0 || rightArea <= 0) return false;
  if (_containsBounds(left, right) && leftArea > rightArea * 1.25) return true;
  if (_containsBounds(right, left) && rightArea > leftArea * 1.25) return true;
  return false;
}

bool _containsBounds(ElementBounds outer, ElementBounds inner) {
  const tolerance = 1.0;
  return inner.x >= outer.x - tolerance &&
      inner.y >= outer.y - tolerance &&
      inner.x + inner.width <= outer.x + outer.width + tolerance &&
      inner.y + inner.height <= outer.y + outer.height + tolerance;
}

double _min(double left, double right) => left < right ? left : right;
double _max(double left, double right) => left > right ? left : right;

double _average(Iterable<double> values) {
  final list = values.toList(growable: false);
  if (list.isEmpty) return 0;
  final value = list.reduce((left, right) => left + right) / list.length;
  return double.parse(value.toStringAsFixed(2));
}

NetworkRequest networkRequest({
  required String method,
  required String url,
  String? path,
  JsonMap query = const <String, Object?>{},
  Map<String, String> headers = const <String, String>{},
  Object? body,
}) {
  return NetworkRequest(
    method: method.toUpperCase(),
    url: url,
    path: path ?? _pathFromUrl(url),
    query: query,
    headers: headers,
    body: body,
  );
}

String makeOperatorId(String prefix, int counter) => '${prefix}_$counter';

class _RuntimeNetworkMock {
  const _RuntimeNetworkMock({
    required this.id,
    required this.match,
    required this.response,
    this.expiresAt,
  });

  final String id;
  final NetworkMockMatch match;
  final NetworkMockResponse response;
  final DateTime? expiresAt;
}

class _RuntimeFirebaseMock {
  const _RuntimeFirebaseMock({
    required this.id,
    required this.match,
    required this.response,
    this.expiresAt,
  });

  final String id;
  final FirebaseMockMatch match;
  final FirebaseMockResponse response;
  final DateTime? expiresAt;
}

int? _networkMockMatchScore(NetworkMockMatch match, NetworkRequest request) {
  if (request.method.toUpperCase() == 'HEAD' &&
      !_explicitlyTargetsRequest(match)) {
    return null;
  }
  if (_isSystemConnectivityProbe(request) &&
      !_explicitlyTargetsRequest(match)) {
    return null;
  }
  if (match.method != null &&
      match.method!.toUpperCase() != request.method.toUpperCase()) {
    return null;
  }
  if (match.path != null && match.path != request.path) return null;
  if (match.url != null && match.url != request.url) return null;
  if (match.pathContains != null &&
      !(request.path ?? '').contains(match.pathContains!)) {
    return null;
  }
  if (match.urlContains != null && !request.url.contains(match.urlContains!)) {
    return null;
  }
  if (match.pathPattern != null &&
      !_patternMatches(match.pathPattern!, request.path ?? '')) {
    return null;
  }
  if (match.urlPattern != null &&
      !_patternMatches(match.urlPattern!, request.url)) {
    return null;
  }
  for (final entry in match.query.entries) {
    if (!_valuesEqual(request.query[entry.key], entry.value)) return null;
  }
  for (final entry in match.headers.entries) {
    if (request.headers[entry.key] != entry.value &&
        request.headers[entry.key.toLowerCase()] != entry.value) {
      return null;
    }
  }
  return _networkMockSpecificity(match);
}

int _networkMockSpecificity(NetworkMockMatch match) {
  var score = 0;
  if (match.method?.trim().isNotEmpty ?? false) score += 1;
  if (match.url?.trim().isNotEmpty ?? false) score += 100;
  if (match.path?.trim().isNotEmpty ?? false) score += 80;
  if (match.urlPattern?.trim().isNotEmpty ?? false) score += 70;
  if (match.pathPattern?.trim().isNotEmpty ?? false) score += 60;
  if (match.urlContains?.trim().isNotEmpty ?? false) score += 40;
  if (match.pathContains?.trim().isNotEmpty ?? false) score += 30;
  score += match.query.length * 10;
  score += match.headers.length * 10;
  return score;
}

bool _explicitlyTargetsRequest(NetworkMockMatch match) {
  return (match.url != null && match.url!.trim().isNotEmpty) ||
      (match.urlContains != null && match.urlContains!.trim().isNotEmpty) ||
      (match.urlPattern != null && match.urlPattern!.trim().isNotEmpty) ||
      (match.path != null && match.path!.trim().isNotEmpty) ||
      (match.pathContains != null && match.pathContains!.trim().isNotEmpty) ||
      (match.pathPattern != null && match.pathPattern!.trim().isNotEmpty) ||
      match.query.isNotEmpty ||
      match.headers.isNotEmpty;
}

bool _isSystemConnectivityProbe(NetworkRequest request) {
  if (request.method.toUpperCase() != 'HEAD') return false;
  final uri = Uri.tryParse(request.url);
  final host = uri?.host.toLowerCase() ?? '';
  final path = request.path ?? uri?.path ?? '';
  return (host == 'connectivitycheck.gstatic.com' && path == '/generate_204') ||
      (host == 'captive.apple.com' && path == '/hotspot-detect.html') ||
      host == 'one.one.one.one' ||
      host == '35.207.149.36';
}

int? _firebaseMockMatchScore(
  FirebaseMockMatch match,
  FirebaseMockMatch request,
) {
  if (_cleanKey(match.service) != _cleanKey(request.service)) return null;
  if (_cleanKey(match.operation) != _cleanKey(request.operation)) return null;
  if (match.path != null &&
      _cleanPath(match.path!) != _cleanPath(request.path)) {
    return null;
  }
  if (!_stringContains(match.pathContains, request.path, cleanPath: true)) {
    return null;
  }
  if (!_stringPatternMatches(
    match.pathPattern,
    request.path,
    cleanPath: true,
  )) {
    return null;
  }
  if (!_stringEquals(match.name, request.name)) return null;
  if (!_stringContains(match.nameContains, request.name)) return null;
  if (!_stringPatternMatches(match.namePattern, request.name)) return null;
  if (!_stringEquals(match.bucket, request.bucket)) return null;
  if (!_stringContains(match.bucketContains, request.bucket)) return null;
  if (!_stringPatternMatches(match.bucketPattern, request.bucket)) return null;
  for (final entry in match.parameters.entries) {
    if (!_valuesEqual(request.parameters[entry.key], entry.value)) return null;
  }
  return _firebaseMockSpecificity(match);
}

int _firebaseMockSpecificity(FirebaseMockMatch match) {
  var score = 0;
  if (match.service.trim().isNotEmpty) score += 1;
  if (match.operation.trim().isNotEmpty) score += 1;
  if (match.path?.trim().isNotEmpty ?? false) score += 100;
  if (match.name?.trim().isNotEmpty ?? false) score += 90;
  if (match.bucket?.trim().isNotEmpty ?? false) score += 80;
  if (match.pathPattern?.trim().isNotEmpty ?? false) score += 70;
  if (match.namePattern?.trim().isNotEmpty ?? false) score += 60;
  if (match.bucketPattern?.trim().isNotEmpty ?? false) score += 50;
  if (match.pathContains?.trim().isNotEmpty ?? false) score += 40;
  if (match.nameContains?.trim().isNotEmpty ?? false) score += 30;
  if (match.bucketContains?.trim().isNotEmpty ?? false) score += 20;
  score += match.parameters.length * 10;
  return score;
}

bool _stringEquals(String? expected, String? actual) {
  if (expected == null) return true;
  return expected == actual;
}

bool _stringContains(String? needle, String? value, {bool cleanPath = false}) {
  if (needle == null || needle.trim().isEmpty) return true;
  final normalizedNeedle = cleanPath ? _cleanPath(needle) : needle;
  final normalizedValue = cleanPath ? _cleanPath(value) : value ?? '';
  return normalizedValue.contains(normalizedNeedle);
}

bool _stringPatternMatches(
  String? pattern,
  String? value, {
  bool cleanPath = false,
}) {
  if (pattern == null || pattern.trim().isEmpty) return true;
  final normalizedValue = cleanPath ? _cleanPath(value) : value ?? '';
  return _patternMatches(pattern, normalizedValue);
}

bool _patternMatches(String pattern, String value) {
  try {
    return RegExp(pattern).hasMatch(value);
  } catch (_) {
    return false;
  }
}

String _cleanKey(String value) => value.trim().toLowerCase();

String _cleanPath(String? value) =>
    (value ?? '').split('/').where((part) => part.trim().isNotEmpty).join('/');

Object? _mergeObjects(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return <String, Object?>{
      ...left.map((key, value) => MapEntry(key.toString(), value)),
      ...right.map((key, value) => MapEntry(key.toString(), value)),
    };
  }
  return right;
}

bool _sameStateStore(
  StateStoreSnapshot store, {
  required OperatorStateSource source,
  required String name,
}) {
  return store.source == source && store.name == name;
}

String _storageKey(String area, String? namespace, String key) =>
    '$area:${namespace ?? ''}:$key';

bool _isSensitiveStorageKey(String key) {
  final normalized = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
  return const <String>[
    'password',
    'passcode',
    'pin',
    'otp',
    'token',
    'accesstoken',
    'refreshtoken',
    'accesskey',
    'apikey',
    'encryptionkey',
    'signingkey',
    'authorization',
    'auth',
    'cookie',
    'session',
    'webhook',
    'webhookurl',
    'dsn',
    'username',
    'email',
    'phone',
    'telephone',
    'address',
    'birthdate',
    'dateofbirth',
    'dob',
    'secret',
    'privatekey',
    'credential',
  ].any(normalized.contains);
}

UiElement _patchUiElement(UiElement element, Iterable<FormFieldPatch> patches) {
  final patch = patches.cast<FormFieldPatch?>().firstWhere(
    (field) =>
        field != null &&
        ((field.id != null &&
                (element.id == field.id || element.platformId == field.id)) ||
            (field.name != null &&
                (element.data['name'] == field.name ||
                    element.platformId == field.name))),
    orElse: () => null,
  );
  if (patch == null) return element;
  return UiElement(
    id: element.id,
    enabled: element.enabled,
    visible: element.visible,
    actions: element.actions,
    confidence: element.confidence,
    platformId: element.platformId,
    role: element.role,
    label: element.label,
    text: element.text,
    value: patch.value ?? element.value,
    hint: element.hint,
    selected: patch.selected ?? element.selected,
    checked: patch.checked ?? element.checked,
    bounds: element.bounds,
    rendered: element.rendered,
    inViewport: element.inViewport,
    parentId: element.parentId,
    children: element.children,
    observationTargetRef: element.observationTargetRef,
    scrollOwner: element.scrollOwner,
    data:
        patch.errors == null
            ? element.data
            : <String, Object?>{...element.data, 'errors': patch.errors},
  );
}

FormFieldPatch _mergeFormPatch(FormFieldPatch left, FormFieldPatch right) =>
    FormFieldPatch(
      id: right.id ?? left.id,
      name: right.name ?? left.name,
      value: right.value ?? left.value,
      checked: right.checked ?? left.checked,
      selected: right.selected ?? left.selected,
      errors: right.errors ?? left.errors,
    );

bool _valuesEqual(Object? left, Object? right) {
  if (left == right) return true;
  return left.toString() == right.toString();
}

const nullSafeDefaultRedactionFields = <String>[
  'password',
  'pin',
  'token',
  'authorization',
  'accessToken',
  'refreshToken',
  'cardNumber',
  'cvv',
  'bvn',
  'nin',
];

JsonMap _requestToMap(NetworkRequest request) {
  return <String, Object?>{
    'method': request.method,
    'url': request.url,
    'path': request.path,
    'query': request.query,
    'headers': request.headers,
    'body': request.body,
  };
}

NetworkRequest _requestFromMap(Map<String, Object?> value) {
  return NetworkRequest(
    method: value['method'] as String? ?? 'GET',
    url: value['url'] as String? ?? '',
    path: value['path'] as String?,
    query:
        value['query'] is Map
            ? Map<String, Object?>.from(value['query'] as Map)
            : const <String, Object?>{},
    headers:
        value['headers'] is Map
            ? Map<String, String>.from(value['headers'] as Map)
            : const <String, String>{},
    body: value['body'],
  );
}

Map<String, String> _headersFromCleanedResponse(Object? value) {
  if (value is! Map || value['headers'] is! Map)
    return const <String, String>{};
  return Map<String, String>.from(value['headers'] as Map);
}

String? _pathFromUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  if (uri.path.isEmpty) return value.startsWith('/') ? value : null;
  return uri.path;
}
