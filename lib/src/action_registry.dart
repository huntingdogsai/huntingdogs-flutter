import 'dart:async';

import 'adapter.dart';
import 'protocol.dart';
import 'runtime.dart';

typedef OperatorTapHandler = FutureOr<void> Function();
typedef OperatorTextHandler = FutureOr<void> Function(String value);
typedef OperatorNavigateHandler = FutureOr<void> Function(String path);
typedef OperatorRegistrationDisposer = void Function();
typedef OperatorTapResolver =
    OperatorTapHandler? Function(ActionCommand command);

/// The answer of a tap that presses once per action to more presses, before anything is pressed.
ActionResult operatorPressesOnceOnlyResult(ActionCommand command) =>
    ActionResult(
      ok: false,
      action: command,
      data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
      error: const ActionError(
        type: 'repeated_press_unsupported',
        message:
            'Nothing was pressed: this target presses once per action, so count above 1 cannot be pressed here.',
        retryable: false,
      ),
    );

class OperatorActionRegistry {
  final Map<String, OperatorTapHandler> _tapHandlers =
      <String, OperatorTapHandler>{};
  final Map<String, OperatorTextHandler> _textHandlers =
      <String, OperatorTextHandler>{};
  final List<OperatorTapResolver> _tapResolvers = <OperatorTapResolver>[];
  OperatorNavigateHandler? _navigateHandler;

  OperatorRegistrationDisposer registerAction({
    required String id,
    required OperatorTapHandler handler,
    String? label,
  }) {
    final keys = <String>{id, if (label != null) label};
    for (final key in keys) {
      _tapHandlers[key] = handler;
    }
    return () {
      for (final key in keys) {
        if (_tapHandlers[key] == handler) _tapHandlers.remove(key);
      }
    };
  }

  OperatorRegistrationDisposer registerTextInput({
    required String id,
    required OperatorTextHandler onChanged,
    String? label,
  }) {
    final keys = <String>{id, if (label != null) label};
    for (final key in keys) {
      _textHandlers[key] = onChanged;
    }
    return () {
      for (final key in keys) {
        if (_textHandlers[key] == onChanged) _textHandlers.remove(key);
      }
    };
  }

  OperatorRegistrationDisposer registerTapResolver(
    OperatorTapResolver resolver,
  ) {
    _tapResolvers.add(resolver);
    return () => _tapResolvers.remove(resolver);
  }

  void registerNavigator(OperatorNavigateHandler handler) {
    _navigateHandler = handler;
  }

  Future<ActionResult?> execute(
    ActionCommand command,
    OperatorFlutter operator,
  ) async {
    switch (command.type) {
      case OperatorActionType.navigate:
        final path = command.path;
        final handler = _navigateHandler;
        if (path == null || handler == null) return null;
        await handler(path);
        return ActionResult(
          ok: true,
          action: command,
          message: 'Navigated to $path',
        );
      case OperatorActionType.tap:
      case OperatorActionType.click:
        final key =
            command.target?.id ?? command.target?.label ?? command.target?.text;
        final handler = key == null ? null : _tapHandlers[key];
        final resolved = handler ?? _resolveTap(command);
        if (resolved == null) return null;
        // A registered handler is the app's own callback, not a press, so it runs once per action.
        if ((command.count ?? 1) > 1) return operatorPressesOnceOnlyResult(command);
        await resolved();
        return ActionResult(ok: true, action: command, message: 'Invoked $key');
      case OperatorActionType.type:
      case OperatorActionType.clear:
        final key = command.target?.id ?? command.target?.label;
        final handler = key == null ? null : _textHandlers[key];
        if (handler == null) return null;
        await handler(
          command.type == OperatorActionType.clear ? '' : command.text ?? '',
        );
        return ActionResult(ok: true, action: command, message: 'Updated $key');
      case OperatorActionType.hover:
      case OperatorActionType.tapPoint:
      case OperatorActionType.key:
      case OperatorActionType.drag:
      case OperatorActionType.touch:
      case OperatorActionType.confirm:
      case OperatorActionType.captureVisual:
      case OperatorActionType.installNetworkMock:
      case OperatorActionType.probeNetworkVirtualization:
      case OperatorActionType.installFirebaseMock:
      case OperatorActionType.probeFirebaseVirtualization:
      case OperatorActionType.supplyMedia:
      case OperatorActionType.injectState:
      case OperatorActionType.injectStorage:
      case OperatorActionType.clearStorage:
      case OperatorActionType.injectForm:
      case OperatorActionType.clearSimulation:
      case OperatorActionType.setNetworkConditions:
      case OperatorActionType.clearNetworkConditions:
      case OperatorActionType.wait:
      case OperatorActionType.askUser:
      case OperatorActionType.scroll:
      case OperatorActionType.scrollIntoView:
      case OperatorActionType.scrollTo:
        return null;
    }
  }

  OperatorTapHandler? _resolveTap(ActionCommand command) {
    for (final resolver in List<OperatorTapResolver>.from(_tapResolvers)) {
      final handler = resolver(command);
      if (handler != null) return handler;
    }
    return null;
  }
}

class OperatorRegisteredActionActuator implements OperatorFlutterActuator {
  OperatorRegisteredActionActuator(this.registry);

  final OperatorActionRegistry registry;

  @override
  Future<ActionResult?> execute(
    ActionCommand command,
    OperatorFlutter operator,
  ) => registry.execute(command, operator);
}
