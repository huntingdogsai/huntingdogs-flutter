import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('post-frame endOfFrame can wait without scheduling its completion frame', (tester) async {
    // Isolate the scheduler primitive used by _waitForFreshFrame, not screenshot encoding.
    // This controlled mechanism test is not proof of the historical Chrome incident.
    final binding = tester.binding;
    var completed = false;
    SchedulerPhase? phase;
    binding.addPostFrameCallback((_) {
      phase = binding.schedulerPhase;
      binding.endOfFrame.then((_) { completed = true; });
    });
    binding.scheduleFrame();
    await tester.pump();
    expect(phase, SchedulerPhase.postFrameCallbacks);
    expect(completed, isFalse);
    expect(binding.hasScheduledFrame, isFalse);
    // Advancing only time does not supply the missing frame.
    await tester.idle();
    expect(completed, isFalse);
    // Explicitly deliver the next frame; the very same pending Future completes.
    binding.scheduleFrame();
    await tester.pump();
    expect(completed, isTrue);
  });
}
