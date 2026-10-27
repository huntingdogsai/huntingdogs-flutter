import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';

import 'adapter.dart';
import 'bridge_handlers.dart';
import 'page_bridge_contract.dart';
import 'wire_codec.dart';

export 'page_bridge_contract.dart';

/// Versioned, page-local Flutter Web bridge consumed by the Watchdog browser
/// host. Payloads are JSON strings so the Dart and TypeScript wire contract is
/// explicit and does not depend on implicit JS object conversion. The method
/// bodies live in [OperatorFlutterBridgeHandlers], shared with the native
/// loopback HTTP bridge; this class only owns the JS surface.
class OperatorFlutterPageBridge {
  OperatorFlutterPageBridge._(this.adapter)
    : _handlers = OperatorFlutterBridgeHandlers(adapter);

  final OperatorFlutterAdapter adapter;
  final OperatorFlutterBridgeHandlers _handlers;
  bool _closed = false;
  late final JSFunction _pageHideListener =
      ((JSAny? _) {
        adapter.operator.observedOperations.clearAll();
      }).toJS;

  static VoidCallback install(OperatorFlutterAdapter adapter) {
    final bridge = OperatorFlutterPageBridge._(adapter).._install();
    return bridge.close;
  }

  String get _installationId => _handlers.installationId;

  void _install() {
    final bridge = JSObject();
    bridge
      ..setProperty(
        'protocolVersion'.toJS,
        operatorFlutterPageBridgeProtocolVersion.toJS,
      )
      ..setProperty('uiAuthority'.toJS, 'flutter_runtime'.toJS)
      ..setProperty('installationId'.toJS, _installationId.toJS)
      ..setProperty('getHealth'.toJS, _getHealth.toJS)
      ..setProperty('getSnapshot'.toJS, _getSnapshot.toJS)
      ..setProperty('getCapabilities'.toJS, _getCapabilities.toJS)
      ..setProperty('getEvents'.toJS, _getEvents.toJS)
      ..setProperty('execute'.toJS, _execute.toJS)
      ..setProperty('observedOperations'.toJS, _observedOperations.toJS)
      ..setProperty('inspectPoint'.toJS, _inspectPoint.toJS)
      ..setProperty('prepareKeyTarget'.toJS, _prepareKeyTarget.toJS);
    globalContext.setProperty(operatorFlutterPageBridgeGlobal.toJS, bridge);
    globalContext.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'pagehide'.toJS,
      _pageHideListener,
    );
  }

  JSString _getHealth() => operatorEncodeJson(_handlers.health()).toJS;

  JSPromise<JSString> _getSnapshot(JSString requestJson) =>
      _handlers.snapshot(requestJson.toDart).then(_encode).toJS;

  JSPromise<JSString> _getCapabilities() =>
      _handlers.capabilities().then(_encode).toJS;

  JSString _getEvents(JSString requestJson) =>
      operatorEncodeJson(_handlers.events(requestJson.toDart)).toJS;

  JSPromise<JSString> _execute(JSString actionJson) =>
      _handlers.execute(actionJson.toDart).then(_encode).toJS;

  JSString _observedOperations(JSString requestJson) =>
      operatorEncodeJson(_handlers.observedOperations(requestJson.toDart)).toJS;

  JSString _inspectPoint(JSString requestJson) =>
      operatorEncodeJson(_handlers.inspectPoint(requestJson.toDart)).toJS;

  JSPromise<JSString> _prepareKeyTarget(JSString actionJson) =>
      _handlers.prepareKeyTarget(actionJson.toDart).then(_encode).toJS;

  static JSString _encode(Object? value) => operatorEncodeJson(value).toJS;

  void close() {
    if (_closed) return;
    _closed = true;
    _handlers.close();
    globalContext.callMethod<JSAny?>(
      'removeEventListener'.toJS,
      'pagehide'.toJS,
      _pageHideListener,
    );
    final current = globalContext.getProperty<JSAny?>(
      operatorFlutterPageBridgeGlobal.toJS,
    );
    if (current != null && current.typeofEquals('object')) {
      final currentInstallation = (current as JSObject).getProperty<JSAny?>(
        'installationId'.toJS,
      );
      if (currentInstallation != null &&
          currentInstallation.typeofEquals('string') &&
          (currentInstallation as JSString).toDart == _installationId) {
        globalContext.delete(operatorFlutterPageBridgeGlobal.toJS);
      }
    }
  }
}
