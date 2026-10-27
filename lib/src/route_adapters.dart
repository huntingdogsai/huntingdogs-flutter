import 'protocol.dart';
import 'runtime.dart';

class OperatorRouterAdapter {
  OperatorRouterAdapter(this.operator);

  final OperatorFlutter operator;

  void captureNavigatorRoute({
    required String name,
    String? path,
    String? screenClass,
    JsonMap arguments = const <String, Object?>{},
  }) {
    operator.captureRoute(
      name: name,
      path: path ?? name,
      screenClass: screenClass ?? 'Navigator',
      params: arguments,
    );
  }

  void captureNavigatorStack(List<RouteEntry> stack) {
    operator.captureRouteStack(stack);
  }

  void captureRouterDelegate({
    required String location,
    String? name,
    JsonMap params = const <String, Object?>{},
  }) {
    operator.captureRoute(
      name: name,
      path: location,
      screenClass: 'RouterDelegate',
      params: params,
    );
  }

  void captureGoRouterLocation({
    required String location,
    String? name,
    JsonMap params = const <String, Object?>{},
  }) {
    operator.captureRoute(
      name: name,
      path: location,
      screenClass: 'go_router',
      params: params,
    );
  }

  void captureAutoRoute({
    required String routeName,
    String? path,
    String? pageClass,
    JsonMap params = const <String, Object?>{},
  }) {
    operator.captureRoute(
      name: routeName,
      path: path ?? routeName,
      screenClass: pageClass ?? 'auto_route',
      params: params,
    );
  }

  void captureBeamer({
    required String location,
    String? beamLocation,
    JsonMap params = const <String, Object?>{},
  }) {
    operator.captureRoute(
      name: beamLocation,
      path: location,
      screenClass: 'beamer',
      params: params,
    );
  }

  void captureGetXRoute({
    required String route,
    String? name,
    JsonMap params = const <String, Object?>{},
  }) {
    operator.captureRoute(
      name: name,
      path: route,
      screenClass: 'getx',
      params: params,
    );
  }

  void captureNamedRoute({
    required String name,
    String? path,
    JsonMap params = const <String, Object?>{},
  }) {
    operator.captureRoute(name: name, path: path ?? name, params: params);
  }
}
