import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/src/frame_wait.dart';

void main() {
  testWidgets(
    'a screenshot wait started in a post-frame callback draws its own frame on a still screen',
    (tester) async {
      // The automatic screenshot starts in a post-frame callback. On a still screen nothing else
      // draws, so the wait must not depend on a frame somebody else happens to request.
      await tester.pumpWidget(const SizedBox());
      final binding = tester.binding;
      var completed = false;
      Object? failure;
      SchedulerPhase? phase;
      binding.addPostFrameCallback((_) {
        phase = binding.schedulerPhase;
        operatorWaitForFreshFrame(binding).then<void>(
          (_) => completed = true,
          onError: (Object error) => failure = error,
        );
      });
      binding.scheduleFrame();
      await tester.pump();
      expect(phase, SchedulerPhase.postFrameCallbacks);
      expect(
        completed,
        isFalse,
        reason: 'the frame that started the wait is not a fresh frame',
      );

      // From here the test delivers no frame; only timers run.
      await tester.idle();
      expect(failure, isNull);
      expect(completed, isTrue);
    },
  );

  testWidgets(
    'a screenshot wait from a still, idle screen draws its own frame',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      final binding = tester.binding;
      expect(binding.schedulerPhase, SchedulerPhase.idle);
      expect(binding.hasScheduledFrame, isFalse);
      var completed = false;
      unawaited(
        operatorWaitForFreshFrame(binding).then((_) => completed = true),
      );
      await tester.idle();
      expect(completed, isTrue);
    },
  );

  testWidgets(
    'a frame that never comes ends the wait at its limit instead of holding the snapshot',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      final binding = tester.binding;
      Object? failure;
      var completed = false;
      // The frame is asked for but never drawn, as when the device stops producing frames.
      unawaited(
        operatorWaitForFreshFrame(
          binding,
          limit: const Duration(seconds: 5),
          drawFrame: () {},
        ).then<void>(
          (_) => completed = true,
          onError: (Object error) => failure = error,
        ),
      );
      await tester.binding.delayed(const Duration(milliseconds: 4900));
      expect(failure, isNull);
      expect(completed, isFalse);
      await tester.binding.delayed(const Duration(milliseconds: 200));
      expect(failure, isA<TimeoutException>());
      expect(completed, isFalse);
      // The frame endOfFrame scheduled is still pending in the test binding; deliver it so the test ends clean.
      await tester.pump();
    },
  );
}
