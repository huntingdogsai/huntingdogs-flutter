import 'dart:async';

import 'capture_diagnostics_stub.dart'
    if (dart.library.js_interop) 'capture_diagnostics_web.dart'
    as platform;

// Opt-in diagnostic channel only. Never enters runtime logs, snapshots or model payloads.
const _traceKey = #operatorCaptureTrace;
final _clock = Stopwatch()..start();
int _sequence = 0;

String get operatorCaptureTrace =>
    Zone.current[_traceKey] as String? ?? 'automatic';

T operatorCaptureTraceScope<T>(String id, T Function() operation) =>
    runZoned(operation, zoneValues: {_traceKey: id});

void operatorCaptureMark(
  String stage,
  String phase, [
  Map<String, Object?> details = const {},
]) {
  try {
    if (!platform.captureDiagnosticsEnabled) return;
    platform.emitCaptureDiagnostic({
      'traceId': operatorCaptureTrace,
      'sequence': ++_sequence,
      'clock': 'dart_stopwatch_us',
      'time': _clock.elapsedMicroseconds,
      'stage': stage,
      'phase': phase,
      ...details,
    });
  } catch (_) {
    // Diagnostic transport must never change capture behavior.
  }
}

T operatorCaptureStage<T>(String stage, T Function() operation) {
  operatorCaptureMark(stage, 'enter');
  try {
    return operation();
  } finally {
    operatorCaptureMark(stage, 'exit');
  }
}

Future<T> operatorCaptureAsyncStage<T>(
  String stage,
  Future<T> Function() operation,
) =>
    platform.captureDiagnosticsEnabled
        ? _captureAsyncStage(stage, operation)
        : operation();

Future<T> _captureAsyncStage<T>(
  String stage,
  Future<T> Function() operation,
) async {
  operatorCaptureMark(stage, 'enter');
  try {
    return await operation();
  } finally {
    operatorCaptureMark(stage, 'exit');
  }
}
