import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Longest a screenshot waits for the frame it asked for. Pixels are evidence beside a snapshot,
/// never a gate on it: past this the screenshot fails (and says so) and the snapshot goes on
/// without fresh pixels, well inside the host's own deadline for the request.
const Duration operatorFrameWaitLimit = Duration(seconds: 5);

/// Waits until a frame drawn after this call has finished, and makes sure that frame is drawn.
///
/// Called from inside a frame (the automatic screenshot starts in a post-frame callback),
/// [SchedulerBinding.endOfFrame] only books a callback on the *next* frame and asks for none,
/// so on a still screen it waits until something else happens to draw. Every snapshot joins
/// that screenshot, so one still screen held the whole observation, and the host's request
/// with it. So the wait first leaves the current frame (a timer runs only once the frame's
/// task is over), then books the end of the next frame and draws it with a warm-up frame,
/// which runs even while frames are disabled (app in the background, screen off).
///
/// Throws a [TimeoutException] if that frame has not finished within [limit]. [drawFrame] is how
/// the frame is asked for: the binding's warm-up frame, unless a test needs one that never comes.
Future<void> operatorWaitForFreshFrame(
  SchedulerBinding binding, {
  Duration limit = operatorFrameWaitLimit,
  void Function()? drawFrame,
}) {
  var abandoned = false;
  Future<void> leaveFrameAndDraw() async {
    while (binding.schedulerPhase != SchedulerPhase.idle) {
      if (abandoned) return;
      await Future<void>.delayed(Duration.zero);
    }
    if (abandoned) return;
    final completed = binding.endOfFrame;
    (drawFrame ?? binding.scheduleWarmUpFrame)();
    await completed;
  }

  return leaveFrameAndDraw().timeout(
    limit,
    onTimeout: () {
      abandoned = true;
      throw TimeoutException(
        'no frame was drawn for the screenshot within ${limit.inMilliseconds} ms',
        limit,
      );
    },
  );
}
