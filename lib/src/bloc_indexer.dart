import 'package:bloc/bloc.dart';

import 'protocol.dart';
import 'runtime.dart';
import 'state_adapters.dart';

class OperatorBlocIndexer extends BlocObserver {
  OperatorBlocIndexer({
    required this.operator,
    BlocObserver? delegate,
    OperatorStateSerializer? serializer,
  }) : delegate = delegate ?? Bloc.observer,
       serializer = serializer ?? const OperatorFallbackStateSerializer();

  final OperatorFlutter operator;
  final BlocObserver delegate;
  final OperatorStateSerializer serializer;

  static OperatorBlocIndexer install({
    required OperatorFlutter operator,
    OperatorStateSerializer? serializer,
    BlocObserver? delegate,
  }) {
    final previous = delegate ?? Bloc.observer;
    final indexer = OperatorBlocIndexer(
      operator: operator,
      delegate: previous,
      serializer: serializer,
    );
    Bloc.observer = indexer;
    return indexer;
  }

  bool restoreIfCurrent() {
    if (Bloc.observer != this) return false;
    Bloc.observer = delegate;
    return true;
  }

  @override
  void onCreate(BlocBase<dynamic> bloc) {
    super.onCreate(bloc);
    delegate.onCreate(bloc);
    _capture(bloc, bloc.state, event: 'create');
  }

  @override
  void onEvent(Bloc<dynamic, dynamic> bloc, Object? event) {
    super.onEvent(bloc, event);
    delegate.onEvent(bloc, event);
    operator.captureLog(
      'debug',
      'bloc event',
      data: <String, Object?>{
        'bloc': bloc.runtimeType.toString(),
        'event': event?.runtimeType.toString(),
      },
    );
  }

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    delegate.onChange(bloc, change);
    _capture(bloc, change.nextState, event: 'change');
  }

  @override
  void onTransition(
    Bloc<dynamic, dynamic> bloc,
    Transition<dynamic, dynamic> transition,
  ) {
    super.onTransition(bloc, transition);
    delegate.onTransition(bloc, transition);
    _capture(
      bloc,
      transition.nextState,
      event: 'transition',
      metadata: <String, Object?>{
        'eventType': transition.event.runtimeType.toString(),
      },
    );
  }

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    super.onError(bloc, error, stackTrace);
    delegate.onError(bloc, error, stackTrace);
    operator.captureLog(
      'error',
      'bloc error',
      data: <String, Object?>{
        'bloc': bloc.runtimeType.toString(),
        'error': error.toString(),
        'stack': stackTrace.toString(),
      },
    );
  }

  @override
  void onDone(
    Bloc<dynamic, dynamic> bloc,
    Object? event, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    super.onDone(bloc, event, error, stackTrace);
    delegate.onDone(bloc, event, error, stackTrace);
  }

  @override
  void onClose(BlocBase<dynamic> bloc) {
    super.onClose(bloc);
    delegate.onClose(bloc);
    operator.captureLog(
      'debug',
      'bloc closed',
      data: <String, Object?>{'bloc': bloc.runtimeType.toString()},
    );
  }

  void _capture(
    BlocBase<dynamic> bloc,
    Object? state, {
    required String event,
    JsonMap metadata = const <String, Object?>{},
  }) {
    final serialized = serializer.serialize(state);
    operator.captureStateChange(
      source: OperatorStateSource.bloc,
      name: bloc.runtimeType.toString(),
      value: <String, Object?>{
        'state': serialized,
        'bloc': bloc.runtimeType.toString(),
        'stateType': state.runtimeType.toString(),
        'event': event,
        ...metadata,
      },
      confidence: _confidence(serialized),
    );
  }

  double _confidence(Object? serialized) {
    if (serialized is Map) return 0.94;
    if (serialized is List) return 0.9;
    if (serialized == null ||
        serialized is num ||
        serialized is bool ||
        serialized is String) {
      return 0.85;
    }
    return 0.55;
  }
}
