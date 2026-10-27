import 'protocol.dart';
import 'runtime.dart';

Future<ActionResult> probeOperatorNetworkVirtualization(
  OperatorFlutter operator,
  ActionCommand command,
) async {
  return ActionResult(
    ok: false,
    action: command,
    error: const ActionError(
      type: 'network_virtualization_probe_unavailable',
      message:
          'Flutter Web network virtualization is owned by the Watchdog browser host.',
    ),
  );
}
