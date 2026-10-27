import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';
import 'runtime.dart';

Future<ActionResult> probeOperatorNetworkVirtualization(
  OperatorFlutter operator,
  ActionCommand command,
) async {
  if (operator.config.environment == OperatorEnvironment.production) {
    return ActionResult(
      ok: false,
      action: command,
      error: const ActionError(
        type: 'simulation_blocked',
        message:
            'Network virtualization probing is only available in dev or staging',
      ),
    );
  }

  final probeId = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
  final method =
      (command.method ?? command.match?.method ?? 'GET').toUpperCase();
  final url =
      command.url ??
      command.match?.url ??
      'https://operator.invalid/__operator_probe__/$probeId';
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return ActionResult(
      ok: false,
      action: command,
      error: const ActionError(
        type: 'invalid_network_probe',
        message: 'Network virtualization probe requires an absolute URL',
      ),
    );
  }

  final match =
      command.match ?? NetworkMockMatch(method: method, url: uri.toString());
  final response =
      command.response ??
      NetworkMockResponse(
        status: 299,
        headers: <String, String>{'x-operator-probe': probeId},
        body: <String, Object?>{'operatorProbe': probeId, 'virtualized': true},
      );
  final mockId = operator.installNetworkMock(
    match,
    response,
    ttl: command.ttl ?? const Duration(seconds: 30),
  );
  final timeout = command.timeout ?? const Duration(seconds: 3);
  final client = HttpClient()..connectionTimeout = timeout;

  try {
    final request = await client.openUrl(method, uri).timeout(timeout);
    for (final entry in command.headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final httpResponse = await request.close().timeout(timeout);
    final body = await utf8.decodeStream(httpResponse).timeout(timeout);
    final operatorMocked =
        httpResponse.headers.value('x-operator-mock')?.toLowerCase() == 'true';
    final statusMatches = httpResponse.statusCode == response.status;
    final expectedProbeHeader = response.headers['x-operator-probe'];
    final probeHeaderMatches =
        expectedProbeHeader == null ||
        httpResponse.headers.value('x-operator-probe') == expectedProbeHeader;
    final ok = operatorMocked && statusMatches && probeHeaderMatches;

    return ActionResult(
      ok: ok,
      action: command,
      message:
          ok
              ? 'Network virtualization probe intercepted by $mockId'
              : 'Network virtualization probe did not prove interception',
      error:
          ok
              ? null
              : const ActionError(
                type: 'network_virtualization_unverified',
                message:
                    'Probe response did not match the installed Operator mock',
                retryable: true,
              ),
      evidence: <VerificationEvidence>[
        VerificationEvidence(
          source: OperatorVerificationSource.network,
          condition: 'response has x-operator-mock header',
          ok: operatorMocked,
          detail: 'mockId=$mockId url=$url',
        ),
        VerificationEvidence(
          source: OperatorVerificationSource.network,
          condition: 'response status matches mock',
          ok: statusMatches,
          detail:
              'actual=${httpResponse.statusCode} expected=${response.status}',
        ),
        VerificationEvidence(
          source: OperatorVerificationSource.network,
          condition: 'probe header matches mock',
          ok: probeHeaderMatches,
          detail: 'bodyBytes=${body.length}',
        ),
      ],
    );
  } catch (error) {
    return ActionResult(
      ok: false,
      action: command,
      error: ActionError(
        type: 'network_virtualization_probe_failed',
        message: error.toString(),
        retryable: true,
      ),
      evidence: <VerificationEvidence>[
        VerificationEvidence(
          source: OperatorVerificationSource.network,
          condition: 'synthetic probe request is intercepted',
          ok: false,
          detail: 'mockId=$mockId url=$url',
        ),
      ],
    );
  } finally {
    client.close(force: true);
    operator.removeNetworkMock(mockId);
  }
}
