import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as rp;
import 'package:get/get.dart' as gx;

import 'protocol.dart';
import 'runtime.dart';
import 'state_adapters.dart';

class OperatorObservers {
  const OperatorObservers({
    this.bloc = true,
    this.riverpod = true,
    this.wrapRiverpodScope = true,
    this.navigator = true,
    this.getx = true,
  });

  const OperatorObservers.none()
    : bloc = false,
      riverpod = false,
      wrapRiverpodScope = false,
      navigator = false,
      getx = false;

  const OperatorObservers.popular({
    this.bloc = true,
    this.riverpod = true,
    this.wrapRiverpodScope = true,
    this.navigator = true,
    this.getx = true,
  });

  final bool bloc;
  final bool riverpod;
  final bool wrapRiverpodScope;
  final bool navigator;
  final bool getx;

  Widget wrap({
    required OperatorFlutter operator,
    required Widget child,
    OperatorStateSerializer? serializer,
  }) {
    if (!riverpod || !wrapRiverpodScope) return child;
    return rp.ProviderScope(
      observers: <rp.ProviderObserver>[
        OperatorRiverpodObserver(operator: operator, serializer: serializer),
      ],
      child: child,
    );
  }

  List<NavigatorObserver> navigatorObservers(
    OperatorFlutter operator, {
    List<NavigatorObserver> existing = const <NavigatorObserver>[],
  }) {
    return <NavigatorObserver>[
      ...existing,
      if (navigator) OperatorNavigatorObserver(operator: operator),
      if (getx) getxObserver(operator),
    ];
  }

  ValueChanged<gx.Routing?> getxRoutingCallback(
    OperatorFlutter operator, {
    ValueChanged<gx.Routing?>? delegate,
  }) {
    return (routing) {
      captureGetXRouting(operator, routing);
      delegate?.call(routing);
    };
  }

  gx.GetObserver getxObserver(OperatorFlutter operator) {
    return gx.GetObserver(getxRoutingCallback(operator), gx.Get.routing);
  }
}

final class OperatorRiverpodObserver extends rp.ProviderObserver {
  OperatorRiverpodObserver({
    required this.operator,
    OperatorStateSerializer? serializer,
  }) : serializer = serializer ?? const OperatorFallbackStateSerializer();

  final OperatorFlutter operator;
  final OperatorStateSerializer serializer;

  @override
  void didAddProvider(rp.ProviderObserverContext context, Object? value) {
    _capture(context, value, event: 'add');
  }

  @override
  void didUpdateProvider(
    rp.ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    final serialized = serializer.serialize(newValue);
    operator.captureStateChange(
      source: OperatorStateSource.riverpod,
      name: _providerName(context),
      value: <String, Object?>{
        'provider': context.provider.toString(),
        'providerType': context.provider.runtimeType.toString(),
        'event': 'update',
        'previous': serializer.serialize(previousValue),
        'value': serialized,
        if (context.mutation != null)
          'mutation': context.mutation.runtimeType.toString(),
      },
      confidence: _confidence(serialized),
    );
  }

  @override
  void didDisposeProvider(rp.ProviderObserverContext context) {
    operator.captureLog(
      'debug',
      'riverpod provider disposed',
      data: <String, Object?>{
        'provider': _providerName(context),
        'providerType': context.provider.runtimeType.toString(),
      },
    );
  }

  @override
  void providerDidFail(
    rp.ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    operator.captureLog(
      'error',
      'riverpod provider failed',
      data: <String, Object?>{
        'provider': _providerName(context),
        'error': error.toString(),
        'stack': stackTrace.toString(),
      },
    );
  }

  void _capture(
    rp.ProviderObserverContext context,
    Object? value, {
    required String event,
  }) {
    final serialized = serializer.serialize(value);
    operator.captureStateChange(
      source: OperatorStateSource.riverpod,
      name: _providerName(context),
      value: <String, Object?>{
        'provider': context.provider.toString(),
        'providerType': context.provider.runtimeType.toString(),
        'event': event,
        'value': serialized,
        if (context.mutation != null)
          'mutation': context.mutation.runtimeType.toString(),
      },
      confidence: _confidence(serialized),
    );
  }

  String _providerName(rp.ProviderObserverContext context) {
    return context.provider.name ?? context.provider.toString();
  }

  double _confidence(Object? serialized) {
    if (serialized is Map) return 0.94;
    if (serialized is List) return 0.9;
    if (serialized == null ||
        serialized is num ||
        serialized is bool ||
        serialized is String) {
      return 0.86;
    }
    return 0.58;
  }
}

class OperatorNavigatorObserver extends NavigatorObserver {
  OperatorNavigatorObserver({required this.operator});

  final OperatorFlutter operator;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _capture(route, previousRoute, event: 'push');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _capture(previousRoute, route, event: 'pop');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _capture(newRoute, oldRoute, event: 'replace');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _capture(previousRoute, route, event: 'remove');
  }

  void _capture(
    Route<dynamic>? current,
    Route<dynamic>? previous, {
    required String event,
  }) {
    if (current == null) return;
    final name = current.settings.name;
    operator.captureRoute(
      name: name,
      path: name == null || name.isEmpty ? null : name,
      screenClass: current.runtimeType.toString(),
      params: <String, Object?>{
        'event': event,
        if (current.settings.arguments != null)
          'arguments': current.settings.arguments.toString(),
        if (previous?.settings.name != null)
          'previous': previous!.settings.name,
      },
    );
  }
}

void captureGetXRouting(OperatorFlutter operator, gx.Routing? routing) {
  if (routing == null) return;
  final current = routing.current.trim();
  operator.captureRoute(
    name: current.isEmpty ? null : current,
    path: current.isEmpty ? null : current,
    screenClass: 'getx',
    params: <String, Object?>{
      if (routing.previous.trim().isNotEmpty) 'previous': routing.previous,
      if (routing.removed.trim().isNotEmpty) 'removed': routing.removed,
      if (routing.args != null) 'arguments': routing.args.toString(),
      if (routing.isBack != null) 'isBack': routing.isBack,
      if (routing.isBottomSheet != null) 'isBottomSheet': routing.isBottomSheet,
      if (routing.isDialog != null) 'isDialog': routing.isDialog,
    },
  );
}
