import 'dart:async';

import 'package:flutter/foundation.dart';

import 'adapter.dart';
import 'automatic_runtime.dart';
import 'bloc_indexer.dart';
import 'production_session.dart'
    if (dart.library.js_interop) 'production_session_web.dart';
import 'protocol.dart';
import 'runtime.dart';
import 'state_adapters.dart';

typedef OperatorStateReader<T> = T Function();
typedef OperatorStateMapper<T> = Object? Function(T state);
typedef OperatorRouteReader = Uri Function();
typedef OperatorRouteNameMapper = String? Function(Uri uri);

class OperatorProductionBinding {
  factory OperatorProductionBinding({
    required OperatorFlutter operator,
    OperatorActionRegistry? actions,
    OperatorFlutterAdapter? adapter,
  }) {
    final registry = actions ?? OperatorActionRegistry();
    final automaticRuntime = OperatorAutomaticFlutterRuntime(
      operator: operator,
      registry: registry,
    );
    final binding = OperatorProductionBinding._(
      operator: operator,
      actions: registry,
      automaticRuntime: automaticRuntime,
      adapter:
          adapter ??
          OperatorFlutterAdapter(operator, actuator: automaticRuntime),
    );
    binding._disposers.add(
      operator.addRouteRefresher(automaticRuntime.captureRouteFromElementTree),
    );
    return binding;
  }

  OperatorProductionBinding._({
    required this.operator,
    required this.actions,
    required this.automaticRuntime,
    required this.adapter,
  });

  final OperatorFlutter operator;
  final OperatorActionRegistry actions;
  final OperatorAutomaticFlutterRuntime automaticRuntime;
  final OperatorFlutterAdapter adapter;
  final List<VoidCallback> _disposers = <VoidCallback>[];

  OperatorFlutterProductionSession? _session;
  OperatorBlocIndexer? _blocIndexer;

  OperatorFlutterProductionSession connect(
    OperatorProductionSessionConfig config,
  ) {
    final session = _createSession(config);
    _startSession(session);
    return session;
  }

  Future<OperatorFlutterProductionSession> connectBeforeAppBuild(
    OperatorProductionSessionConfig config,
  ) async {
    final session = _createSession(config);
    try {
      await session.connect().timeout(config.requestTimeout);
    } catch (error, stack) {
      debugPrint(
        'operator production startup connect failed; app will continue: '
        '$error\n$stack',
      );
      operator.captureLog(
        'warn',
        'operator production startup connect failed; app will continue',
        source: OperatorLogSource.operatorRuntime,
        data: <String, Object?>{
          'error': error.toString(),
          'stack': stack.toString(),
          'retryable': true,
        },
      );
    }
    _startSession(session);
    return session;
  }

  OperatorFlutterProductionSession _createSession(
    OperatorProductionSessionConfig config,
  ) {
    final session = OperatorFlutterProductionSession(
      adapter: adapter,
      config: config,
    );
    _session = session;
    return session;
  }

  void _startSession(OperatorFlutterProductionSession session) {
    unawaited(
      session.start().catchError((Object error, StackTrace stack) {
        debugPrint('operator production session failed: $error\n$stack');
        operator.captureLog(
          'error',
          'operator production session failed',
          data: <String, Object?>{
            'error': error.toString(),
            'stack': stack.toString(),
          },
        );
      }),
    );
  }

  OperatorBlocIndexer indexBlocs({OperatorStateSerializer? serializer}) {
    return _blocIndexer ??= OperatorBlocIndexer.install(
      operator: operator,
      serializer: serializer,
    );
  }

  VoidCallback observeRoute({
    required Listenable listenable,
    required OperatorRouteReader read,
    OperatorRouteNameMapper? nameForUri,
    String screenClass = 'router',
  }) {
    void capture() {
      final uri = read();
      operator.captureRoute(
        name: nameForUri?.call(uri),
        path: uri.path.isEmpty ? '/' : uri.path,
        screenClass: screenClass,
        params: <String, Object?>{
          for (final entry in uri.queryParameters.entries)
            entry.key: entry.value,
        },
      );
    }

    listenable.addListener(capture);
    capture();
    final dispose = () => listenable.removeListener(capture);
    _disposers.add(dispose);
    return dispose;
  }

  VoidCallback observeState<T>({
    required String name,
    required OperatorStateSource source,
    required Stream<T> stream,
    required OperatorStateReader<T> read,
    required OperatorStateMapper<T> map,
    double confidence = 0.95,
  }) {
    void capture(T state) {
      operator.captureStateChange(
        source: source,
        name: name,
        value: map(state),
        confidence: confidence,
      );
    }

    capture(read());
    final subscription = stream.listen(capture);
    final dispose = () => unawaited(subscription.cancel());
    _disposers.add(dispose);
    return dispose;
  }

  Future<void> publishSnapshot() async {
    await _session?.publishSnapshot();
  }

  Future<void> close() async {
    for (final dispose in List<VoidCallback>.from(_disposers.reversed)) {
      dispose();
    }
    _disposers.clear();
    await _session?.close();
    _blocIndexer?.restoreIfCurrent();
    automaticRuntime.dispose();
  }
}
