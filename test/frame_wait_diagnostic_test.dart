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

  testWidgets('ensureVisualUpdate in post-frame callbacks asks for the frame endOfFrame waits for', (tester) async {
    // The primitive _waitForFreshFrame now calls before it waits (measured
    // 2026-11-11 on an Android emulator: without it a capture stayed stuck
    // until a frame was forced).
    final binding = tester.binding;
    var completed = false;
    binding.addPostFrameCallback((_) {
      binding.ensureVisualUpdate();
      binding.endOfFrame.then((_) { completed = true; });
    });
    binding.scheduleFrame();
    await tester.pump();
    expect(completed, isFalse);
    expect(binding.hasScheduledFrame, isTrue);
    // The next frame is already asked for: delivering it completes the wait.
    await tester.pump();
    expect(completed, isTrue);
  });
}
