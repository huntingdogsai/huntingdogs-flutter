import 'package:flutter/foundation.dart';

import 'runtime.dart';

/// Web requests are observed by the browser host rather than `dart:io` overrides.
class OperatorHttpCapture {
  OperatorHttpCapture._();

  static VoidCallback installEarly({
    Duration rechainInterval = const Duration(milliseconds: 250),
  }) => () {};

  static VoidCallback install(
    OperatorFlutter operator, {
    Duration rechainInterval = const Duration(milliseconds: 250),
  }) {
    operator
      ..setVirtualizationCapability('httpOverrides', false)
      ..setVirtualizationCapability('dartIoHttp', false)
      ..setVirtualizationCapability('dartIoIsolateHttp', false)
      ..captureLog(
        'debug',
        'flutter web uses host browser network observation',
      );
    return () {};
  }

  static T wrapActive<T>(T client) => client;
}
