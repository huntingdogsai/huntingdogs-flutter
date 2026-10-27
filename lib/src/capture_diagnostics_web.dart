import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

bool get captureDiagnosticsEnabled =>
    globalContext
        .getProperty<JSAny?>('__watchdogCaptureDiagnostic'.toJS)
        ?.typeofEquals('function') ==
    true;

void emitCaptureDiagnostic(Map<String, Object?> record) {
  final sink = globalContext.getProperty<JSAny?>(
    '__watchdogCaptureDiagnostic'.toJS,
  );
  if (sink == null || !sink.typeofEquals('function')) return;
  (sink as JSFunction).callAsFunction(null, jsonEncode(record).toJS);
}
