import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/widgets.dart';

import 'automatic_runtime.dart';
import 'bloc_indexer.dart';
import 'live_bridge.dart';
import 'http_overrides.dart'
    if (dart.library.js_interop) 'http_overrides_web.dart';
import 'observers.dart';
import 'page_bridge.dart';
import 'production_binding.dart';
import 'production_session.dart'
    if (dart.library.js_interop) 'production_session_web.dart';
import 'protocol.dart';
import 'runtime.dart';
import 'shared_preferences_reader.dart';
import 'state_adapters.dart';
import 'widgets.dart';

typedef OperatorAppIntegration = VoidCallback Function(OperatorApp app);

class OperatorAutoIndexers {
  const OperatorAutoIndexers({
    this.bloc = true,
    this.provider = true,
    this.riverpod = true,
    this.getx = true,
    this.setState = true,
    this.changeNotifier = true,
    this.valueNotifier = true,
  });

  const OperatorAutoIndexers.none()
    : bloc = false,
      provider = false,
      riverpod = false,
      getx = false,
      setState = false,
      changeNotifier = false,
      valueNotifier = false;

  final bool bloc;
  final bool provider;
  final bool riverpod;
  final bool getx;
  final bool setState;
  final bool changeNotifier;
  final bool valueNotifier;
}

class OperatorStateProbe {
  const OperatorStateProbe({
    required this.name,
    required this.source,
    required this.read,
    this.confidence = 0.95,
    this.schema,
    this.serializer = const OperatorFallbackStateSerializer(),
  });

  factory OperatorStateProbe.provider({
    required String name,
    required Object? Function() read,
    double confidence = 0.95,
    String? schema,
    OperatorStateSerializer serializer =
        const OperatorFallbackStateSerializer(),
  }) {
    return OperatorStateProbe(
      name: name,
      source: OperatorStateSource.provider,
      read: read,
      confidence: confidence,
      schema: schema,
      serializer: serializer,
    );
  }

  factory OperatorStateProbe.riverpod({
    required String name,
    required Object? Function() read,
    double confidence = 0.95,
    String? schema,
    OperatorStateSerializer serializer =
        const OperatorFallbackStateSerializer(),
  }) {
    return OperatorStateProbe(
      name: name,
      source: OperatorStateSource.riverpod,
      read: read,
      confidence: confidence,
      schema: schema,
      serializer: serializer,
    );
  }

  factory OperatorStateProbe.getx({
    required String name,
    required Object? Function() read,
    double confidence = 0.95,
    String? schema,
    OperatorStateSerializer serializer =
        const OperatorFallbackStateSerializer(),
  }) {
    return OperatorStateProbe(
      name: name,
      source: OperatorStateSource.getx,
      read: read,
      confidence: confidence,
      schema: schema,
      serializer: serializer,
    );
  }

  factory OperatorStateProbe.custom({
    required String name,
    required Object? Function() read,
    double confidence = 0.9,
    String? schema,
    OperatorStateSerializer serializer =
        const OperatorFallbackStateSerializer(),
  }) {
    return OperatorStateProbe(
      name: name,
      source: OperatorStateSource.custom,
      read: read,
      confidence: confidence,
      schema: schema,
      serializer: serializer,
    );
  }

  final String name;
  final OperatorStateSource source;
  final Object? Function() read;
  final double confidence;
  final String? schema;
  final OperatorStateSerializer serializer;

  StateStoreSnapshot snapshot() {
    Object? value;
    var snapshotConfidence = confidence;
    try {
      value = serializer.serialize(read());
    } catch (error) {
      snapshotConfidence = 0.1;
      value = <String, Object?>{'readable': false, 'error': error.toString()};
    }
    return StateStoreSnapshot(
      source: source,
      name: name,
      value: value,
      schema: schema,
      confidence: snapshotConfidence,
      redacted: false,
    );
  }
}

const int _operatorLiveBridgePort = int.fromEnvironment(
  'OPERATOR_LIVE_BRIDGE_PORT',
  defaultValue: 0,
);
const String _operatorLiveBridgeToken = String.fromEnvironment(
  'OPERATOR_LIVE_BRIDGE_TOKEN',
);

/// False leaves the app's dart:io networking untouched; its requests are then read from outside
/// the app, through Dart's own network profile on the debug connection.
const bool _operatorInAppHttpCapture = bool.fromEnvironment(
  'OPERATOR_IN_APP_HTTP_CAPTURE',
  defaultValue: true,
);

class OperatorApp {
  OperatorApp._({
    required this.operator,
    required this.binding,
    required this.observers,
    required this.stateSerializer,
  });

  final OperatorFlutter operator;
  final OperatorProductionBinding binding;
  final OperatorObservers observers;
  final OperatorStateSerializer? stateSerializer;
  final List<VoidCallback> _disposers = <VoidCallback>[];
  bool _closed = false;

  OperatorActionRegistry get actions => binding.actions;

  static Future<OperatorApp> install({
    required OperatorFlutterConfig config,
    OperatorProductionSessionConfig? production,
    OperatorAutoIndexers indexers = const OperatorAutoIndexers(),
    OperatorObservers observers = const OperatorObservers.popular(),
    OperatorStateSerializer? stateSerializer,
    Iterable<OperatorStateProbe> stateProbes = const <OperatorStateProbe>[],
  }) async {
    // Trust the network checkpoint's certificate before anything else, so the app (whose first requests can
    // fire as soon as it builds) trusts the host-side proxy its traffic is routed through. Unconditional and
    // a no-op without the OPERATOR_CHECKPOINT_CA_B64 dart-define; not tied to in-app HTTP capture.
    OperatorHttpCapture.trustCheckpointCa();
    final operator = await OperatorFlutter.init(config);
    final app = OperatorApp._(
      operator: operator,
      binding: OperatorProductionBinding(operator: operator),
      observers: observers,
      stateSerializer: stateSerializer,
    );
    app.index(
      indexers,
      stateSerializer: stateSerializer,
      observeBloc: observers.bloc,
    );
    app._track(_installErrorCapture(operator));
    if (_operatorInAppHttpCapture) {
      app._track(OperatorHttpCapture.install(operator));
    }
    app._track(OperatorSharedPreferencesReader.install(operator));
    app._track(OperatorFlutterPageBridge.install(app.binding.adapter));
    await app._startLiveBridgeFromEnvironment();
    app.addStateProbes(stateProbes);
    if (production != null) {
      await app.binding.connectBeforeAppBuild(production);
    }
    return app;
  }

  static OperatorApp of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_OperatorAppScope>();
    if (scope == null) {
      throw FlutterError('OperatorAppHost was not found in the widget tree.');
    }
    return scope.app;
  }

  static OperatorApp? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_OperatorAppScope>()?.app;
  }

  void index(
    OperatorAutoIndexers indexers, {
    OperatorStateSerializer? stateSerializer,
    bool observeBloc = true,
  }) {
    binding.automaticRuntime.configureStateIndexers(
      provider: indexers.provider,
      riverpod: indexers.riverpod,
      getx: indexers.getx,
      setState: indexers.setState,
      changeNotifier: indexers.changeNotifier,
      valueNotifier: indexers.valueNotifier,
    );
    if (indexers.bloc && observeBloc) {
      binding.indexBlocs(serializer: stateSerializer);
    }
    operator.captureLog(
      'debug',
      'flutter operator indexers installed',
      data: {
        'bloc': indexers.bloc,
        'blocObserver': indexers.bloc && observeBloc,
        'provider': indexers.provider,
        'riverpod': indexers.riverpod,
        'getx': indexers.getx,
        'setState': indexers.setState,
        'changeNotifier': indexers.changeNotifier,
        'valueNotifier': indexers.valueNotifier,
      },
    );
  }

  VoidCallback addStateProbes(Iterable<OperatorStateProbe> probes) {
    final stateProbes = List<OperatorStateProbe>.unmodifiable(probes);
    if (stateProbes.isEmpty) return () {};
    return _track(
      operator.addStateProvider(() {
        return stateProbes.map((probe) => probe.snapshot()).toList();
      }),
    );
  }

  VoidCallback use(OperatorAppIntegration integration) {
    return _track(integration(this));
  }

  VoidCallback useAll(Iterable<OperatorAppIntegration> integrations) {
    final disposers = integrations.map(use).toList(growable: false);
    if (disposers.isEmpty) return () {};
    var active = true;
    return () {
      if (!active) return;
      active = false;
      for (final dispose in disposers.reversed) {
        dispose();
      }
    };
  }

  Widget _buildLayer({required Widget child}) {
    return OperatorVisualCaptureLayer(
      operator: operator,
      enabled: operator.config.privacy.captureScreenshots,
      child: OperatorAutomaticLayer(
        runtime: binding.automaticRuntime,
        child: OperatorScope(
          operator: operator,
          actions: actions,
          child: observers.wrap(
            operator: operator,
            child: child,
            serializer: stateSerializer,
          ),
        ),
      ),
    );
  }

  List<NavigatorObserver> navigatorObservers({
    List<NavigatorObserver> existing = const <NavigatorObserver>[],
  }) {
    return observers.navigatorObservers(operator, existing: existing);
  }

  VoidCallback route({
    required Listenable listenable,
    required OperatorRouteReader read,
    OperatorRouteNameMapper? nameForUri,
    String screenClass = 'router',
  }) {
    return _track(
      binding.observeRoute(
        listenable: listenable,
        read: read,
        nameForUri: nameForUri,
        screenClass: screenClass,
      ),
    );
  }

  void navigation(OperatorNavigateHandler handler) {
    actions.registerNavigator(handler);
  }

  OperatorRegistrationDisposer action({
    required String id,
    required OperatorTapHandler handler,
    String? label,
  }) {
    return actions.registerAction(id: id, label: label, handler: handler);
  }

  OperatorRegistrationDisposer textInput({
    required String id,
    required OperatorTextHandler onChanged,
    String? label,
  }) {
    return actions.registerTextInput(
      id: id,
      label: label,
      onChanged: onChanged,
    );
  }

  OperatorFlutterProductionSession connect(
    OperatorProductionSessionConfig config,
  ) {
    return binding.connect(config);
  }

  OperatorBlocIndexer indexBlocs({OperatorStateSerializer? serializer}) {
    return binding.indexBlocs(serializer: serializer);
  }

  VoidCallback states({
    required Map<String, Object? Function()> readers,
    OperatorStateSource source = OperatorStateSource.provider,
    OperatorStateSerializer serializer =
        const OperatorFallbackStateSerializer(),
  }) {
    return _track(
      operator.addStateProvider(() {
        return readers.entries
            .map((entry) {
              final value = serializer.serialize(entry.value());
              return StateStoreSnapshot(
                source: source,
                name: entry.key,
                value: value,
                confidence: value is Map ? 0.92 : 0.64,
                redacted: false,
              );
            })
            .toList(growable: false);
      }),
    );
  }

  VoidCallback changeNotifier({
    required ChangeNotifier notifier,
    required String name,
    required Object? Function() read,
    OperatorStateSerializer serializer =
        const OperatorFallbackStateSerializer(),
  }) {
    void capture() {
      final value = serializer.serialize(read());
      operator.captureStateChange(
        source: OperatorStateSource.changeNotifier,
        name: name,
        value: value,
        confidence: value is Map ? 0.92 : 0.64,
      );
    }

    notifier.addListener(capture);
    capture();
    return _track(() => notifier.removeListener(capture));
  }

  VoidCallback valueNotifier<T>({
    required ValueListenable<T> notifier,
    required String name,
    OperatorStateSerializer serializer =
        const OperatorFallbackStateSerializer(),
  }) {
    void capture() {
      final value = serializer.serialize(notifier.value);
      operator.captureStateChange(
        source: OperatorStateSource.valueNotifier,
        name: name,
        value: value,
        confidence: value is Map ? 0.92 : 0.82,
      );
    }

    notifier.addListener(capture);
    capture();
    return _track(() => notifier.removeListener(capture));
  }

  void provider(String name, Object? value) {
    operator.stateAdapters.captureProvider(provider: name, value: value);
  }

  void riverpod(String name, Object? value, {Object? previous}) {
    operator.stateAdapters.captureRiverpod(
      provider: name,
      value: value,
      previous: previous,
    );
  }

  void getx(Object controller, Object? state, {String? name}) {
    operator.stateAdapters.captureGetX(
      controller: controller,
      state: state,
      name: name,
    );
  }

  Future<void> publishSnapshot() => binding.publishSnapshot();

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final dispose in List<VoidCallback>.from(_disposers.reversed)) {
      dispose();
    }
    _disposers.clear();
    await binding.close();
    operator.dispose();
  }

  /// Native builds serve the loopback HTTP bridge when the build sets
  /// `OPERATOR_LIVE_BRIDGE_PORT`; the host reaches it through `adb forward`
  /// or the simulator's localhost. Production builds never serve it. Flutter
  /// Web keeps the page-local bridge installed above.
  Future<void> _startLiveBridgeFromEnvironment() async {
    if (kIsWeb ||
        _operatorLiveBridgePort <= 0 ||
        operator.config.environment == OperatorEnvironment.production) {
      return;
    }
    try {
      final bridge = await OperatorFlutterLiveBridge.start(
        binding.adapter,
        port: _operatorLiveBridgePort,
        token:
            _operatorLiveBridgeToken.isEmpty ? null : _operatorLiveBridgeToken,
      );
      _track(() => unawaited(bridge.close()));
      operator.captureLog(
        'info',
        'flutter live bridge listening',
        data: <String, Object?>{
          'url': bridge.url.toString(),
          'tokenRequired': _operatorLiveBridgeToken.isNotEmpty,
        },
      );
    } catch (error) {
      operator.captureLog(
        'error',
        'flutter live bridge failed to start',
        data: <String, Object?>{
          'port': _operatorLiveBridgePort,
          'error': error.toString(),
        },
      );
    }
  }

  VoidCallback _track(VoidCallback dispose) {
    var active = true;
    void tracked() {
      if (!active) return;
      active = false;
      _disposers.remove(tracked);
      dispose();
    }

    _disposers.add(tracked);
    return tracked;
  }
}

VoidCallback _installErrorCapture(OperatorFlutter operator) {
  final previousFlutterError = FlutterError.onError;
  final dispatcher = ui.PlatformDispatcher.instance;
  final previousPlatformError = dispatcher.onError;

  void flutterErrorHandler(FlutterErrorDetails details) {
    operator.captureFlutterError(details);
    previousFlutterError?.call(details);
  }

  bool platformErrorHandler(Object error, StackTrace stack) {
    final handledByOperator = operator.captureZoneError(error, stack);
    if (handledByOperator) return true;
    return previousPlatformError?.call(error, stack) ?? false;
  }

  FlutterError.onError = flutterErrorHandler;
  dispatcher.onError = platformErrorHandler;

  return () {
    if (FlutterError.onError == flutterErrorHandler) {
      FlutterError.onError = previousFlutterError;
    }
    if (dispatcher.onError == platformErrorHandler) {
      dispatcher.onError = previousPlatformError;
    }
  };
}

class OperatorAppHost extends StatefulWidget {
  const OperatorAppHost({
    super.key,
    required this.config,
    required this.child,
    this.production,
    this.indexers = const OperatorAutoIndexers(),
    this.observers = const OperatorObservers.popular(),
    this.stateProbes = const <OperatorStateProbe>[],
    this.integrations = const <OperatorAppIntegration>[],
    this.stateSerializer,
    this.loading,
    this.errorBuilder,
    this.onReady,
  });

  final OperatorFlutterConfig config;
  final OperatorProductionSessionConfig? production;
  final OperatorAutoIndexers indexers;
  final OperatorObservers observers;
  final Iterable<OperatorStateProbe> stateProbes;
  final Iterable<OperatorAppIntegration> integrations;
  final OperatorStateSerializer? stateSerializer;
  final Widget child;
  final Widget? loading;
  final Widget Function(BuildContext context, Object error, StackTrace? stack)?
  errorBuilder;
  final ValueChanged<OperatorApp>? onReady;

  @override
  State<OperatorAppHost> createState() => _OperatorAppHostState();
}

class _OperatorAppHostState extends State<OperatorAppHost> {
  late final Future<OperatorApp> _installFuture = _install();
  OperatorApp? _app;
  bool _readyNotified = false;
  bool _disposed = false;

  Future<OperatorApp> _install() async {
    final app = await OperatorApp.install(
      config: widget.config,
      production: widget.production,
      indexers: widget.indexers,
      observers: widget.observers,
      stateSerializer: widget.stateSerializer,
      stateProbes: widget.stateProbes,
    );
    try {
      app.useAll(widget.integrations);
    } catch (_) {
      await app.close();
      rethrow;
    }
    if (_disposed) {
      await app.close();
      return app;
    }
    _app = app;
    return app;
  }

  @override
  void dispose() {
    _disposed = true;
    final app = _app;
    if (app != null) {
      _closeApp(app);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OperatorApp>(
      future: _installFuture,
      builder: (context, snapshot) {
        final app = snapshot.data;
        if (app != null) {
          _notifyReady(app);
          return _OperatorAppScope(
            app: app,
            child: app._buildLayer(child: widget.child),
          );
        }

        final error = snapshot.error;
        if (error != null) {
          final builder = widget.errorBuilder;
          if (builder != null) {
            return builder(context, error, snapshot.stackTrace);
          }
          return ErrorWidget(error);
        }

        return widget.loading ?? const SizedBox.shrink();
      },
    );
  }

  void _notifyReady(OperatorApp app) {
    if (_readyNotified) return;
    _readyNotified = true;
    final onReady = widget.onReady;
    if (onReady == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      onReady(app);
    });
  }

  void _closeApp(OperatorApp app) {
    app.close().catchError((Object error, StackTrace stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'huntingdogs',
          context: ErrorDescription('while closing OperatorAppHost'),
        ),
      );
    });
  }
}

class _OperatorAppScope extends InheritedWidget {
  const _OperatorAppScope({required this.app, required super.child});

  final OperatorApp app;

  @override
  bool updateShouldNotify(_OperatorAppScope oldWidget) => oldWidget.app != app;
}
