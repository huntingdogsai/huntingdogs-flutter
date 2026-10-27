import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/src/capture_diagnostics.dart';

void main() {
  test('disabled diagnostics preserve the original future and synchronous error', () async {
    final completer = Completer<int>();
    final original = completer.future;
    final result = operatorCaptureAsyncStage('fixture', () => original);
    expect(identical(result, original), isTrue);
    completer.complete(7);
    expect(await result, 7);
    final error = StateError('fixture');
    expect(() => operatorCaptureAsyncStage<int>('fixture', () => throw error), throwsA(same(error)));
    expect(operatorCaptureStage('fixture', () => 9), 9);
  });
}
