import 'protocol.dart';
import 'runtime.dart';

abstract class OperatorStateSerializer {
  Object? serialize(Object? state);
}

class OperatorFallbackStateSerializer implements OperatorStateSerializer {
  const OperatorFallbackStateSerializer();

  @override
  Object? serialize(Object? state) {
    if (state == null || state is num || state is bool || state is String) {
      return state;
    }
    if (state is List) return state;
    if (state is Map) return state;
    try {
      final value = (state as dynamic).toJson();
      if (value == null ||
          value is num ||
          value is bool ||
          value is String ||
          value is List ||
          value is Map) {
        return value;
      }
    } catch (_) {
      // Fall back to a type/string snapshot when a state has no JSON surface.
    }
    return <String, Object?>{
      'type': state.runtimeType.toString(),
      'stringValue': state.toString(),
    };
  }
}

class OperatorBlocStateObserver {
  OperatorBlocStateObserver({
    required this.operator,
    OperatorStateSerializer? serializer,
  }) : serializer = serializer ?? const OperatorFallbackStateSerializer();

  final OperatorFlutter operator;
  final OperatorStateSerializer serializer;

  void onChange({
    required Object bloc,
    required Object? nextState,
    String? name,
  }) {
    final serialized = serializer.serialize(nextState);
    operator.captureStateChange(
      source: OperatorStateSource.bloc,
      name: name ?? bloc.runtimeType.toString(),
      value: serialized,
      confidence: serialized is Map ? 0.95 : 0.55,
    );
  }
}

class OperatorProviderStateObserver {
  OperatorProviderStateObserver({
    required this.operator,
    OperatorStateSerializer? serializer,
  }) : serializer = serializer ?? const OperatorFallbackStateSerializer();

  final OperatorFlutter operator;
  final OperatorStateSerializer serializer;

  void capture({
    required String name,
    required Object? state,
    OperatorStateSource source = OperatorStateSource.provider,
  }) {
    final serialized = serializer.serialize(state);
    operator.captureStateChange(
      source: source,
      name: name,
      value: serialized,
      confidence: serialized is Map ? 0.9 : 0.55,
    );
  }
}

class OperatorPopularStateAdapters {
  OperatorPopularStateAdapters({
    required this.operator,
    OperatorStateSerializer? serializer,
  }) : serializer = serializer ?? const OperatorFallbackStateSerializer();

  final OperatorFlutter operator;
  final OperatorStateSerializer serializer;

  void captureBloc({
    required Object bloc,
    required Object? state,
    String? name,
  }) {
    _capture(
      source: OperatorStateSource.bloc,
      name: name ?? bloc.runtimeType.toString(),
      state: state,
      highConfidence: state is Map,
    );
  }

  void captureCubit({
    required Object cubit,
    required Object? state,
    String? name,
  }) {
    _capture(
      source: OperatorStateSource.bloc,
      name: name ?? cubit.runtimeType.toString(),
      state: state,
      highConfidence: state is Map,
    );
  }

  void captureSetState({required String widget, required Object? state}) {
    _capture(
      source: OperatorStateSource.setState,
      name: widget,
      state: state,
      highConfidence: state is Map,
    );
  }

  void captureChangeNotifier({
    required Object notifier,
    required Object? state,
    String? name,
  }) {
    _capture(
      source: OperatorStateSource.changeNotifier,
      name: name ?? notifier.runtimeType.toString(),
      state: state,
      highConfidence: state is Map,
    );
  }

  void captureValueNotifier({
    required Object notifier,
    required Object? value,
    String? name,
  }) {
    _capture(
      source: OperatorStateSource.valueNotifier,
      name: name ?? notifier.runtimeType.toString(),
      state: value,
      highConfidence:
          value is Map ||
          value is List ||
          value is num ||
          value is bool ||
          value is String,
    );
  }

  void captureProvider({required String provider, required Object? value}) {
    _capture(
      source: OperatorStateSource.provider,
      name: provider,
      state: value,
      highConfidence: value is Map,
    );
  }

  void captureRiverpod({
    required String provider,
    required Object? value,
    Object? previous,
  }) {
    final serialized = serializer.serialize(value);
    operator.captureStateChange(
      source: OperatorStateSource.riverpod,
      name: provider,
      value: <String, Object?>{
        'previous': serializer.serialize(previous),
        'value': serialized,
      },
      confidence: serialized is Map ? 0.92 : 0.62,
    );
  }

  void captureGetX({
    required Object controller,
    required Object? state,
    String? name,
  }) {
    _capture(
      source: OperatorStateSource.getx,
      name: name ?? controller.runtimeType.toString(),
      state: state,
      highConfidence: state is Map,
    );
  }

  void captureRedux({
    required String store,
    required Object? state,
    Object? action,
  }) {
    final serialized = serializer.serialize(state);
    operator.captureStateChange(
      source: OperatorStateSource.redux,
      name: store,
      value: <String, Object?>{
        'action': action?.toString(),
        'state': serialized,
      },
      confidence: serialized is Map ? 0.92 : 0.6,
    );
  }

  void captureMobX({
    required Object store,
    required Object? state,
    String? name,
  }) {
    _capture(
      source: OperatorStateSource.mobx,
      name: name ?? store.runtimeType.toString(),
      state: state,
      highConfidence: state is Map,
    );
  }

  void captureInheritedWidget({
    required String widget,
    required Object? value,
  }) {
    _capture(
      source: OperatorStateSource.inheritedWidget,
      name: widget,
      state: value,
      highConfidence: value is Map,
    );
  }

  void _capture({
    required OperatorStateSource source,
    required String name,
    required Object? state,
    required bool highConfidence,
  }) {
    operator.captureStateChange(
      source: source,
      name: name,
      value: serializer.serialize(state),
      confidence: highConfidence ? 0.9 : 0.58,
    );
  }
}
