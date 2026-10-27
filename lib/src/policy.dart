import 'protocol.dart';

const _defaultConfirmPurposes = <String>{
  'place_order',
  'make_payment',
  'transfer_funds',
  'delete_account',
  'submit_legal_form',
  'submit_medical_form',
  'submit_financial_form',
  'send_message',
  'send_email',
  'refund_customer',
  'change_password',
  'change_default_address',
  'change_payment_method',
  'checkout_confirmation',
};

const _defaultBlockedPurposes = <String>{
  'read_password',
  'read_pin',
  'read_cvv',
  'exfiltrate_token',
  'bypass_auth',
  'disable_security',
  'outside_host_scope',
};

class OperatorPolicyEngine {
  OperatorPolicyEngine({
    Iterable<String> requireConfirmationFor = const <String>[],
    Iterable<String> blockedPurposes = const <String>[],
    this.allowHighRiskWithoutConfirmation = false,
    this.allowSimulationActions = false,
  }) : _confirmPurposes = {
         ..._defaultConfirmPurposes,
         ...requireConfirmationFor.map(_normalizePurpose),
       },
       _blockedPurposes = {
         ..._defaultBlockedPurposes,
         ...blockedPurposes.map(_normalizePurpose),
       };

  final Set<String> _confirmPurposes;
  final Set<String> _blockedPurposes;
  final bool allowHighRiskWithoutConfirmation;
  final bool allowSimulationActions;

  PolicyDecision evaluate(
    ActionCommand command, {
    AppSnapshot? context,
    String? description,
  }) {
    final purpose = _normalizePurpose(
      command.purpose ?? description ?? command.type.name,
    );
    final risk = command.risk ?? inferRisk(command, purpose);

    if (_isSimulationCommand(command) && !allowSimulationActions) {
      return PolicyDecision(
        decision: OperatorPolicyDecisionType.blocked,
        risk: 4,
        reason: 'Blocked outside simulation mode: $purpose',
      );
    }

    if (risk >= 4 || _blockedPurposes.contains(purpose)) {
      return PolicyDecision(
        decision: OperatorPolicyDecisionType.blocked,
        risk: risk,
        reason: 'Blocked by policy: $purpose',
      );
    }

    if (command.type == OperatorActionType.confirm ||
        _confirmPurposes.contains(purpose) ||
        (risk >= 2 && !allowHighRiskWithoutConfirmation)) {
      return PolicyDecision(
        decision: OperatorPolicyDecisionType.confirm,
        risk: risk,
        message: _confirmationMessage(command, purpose, context),
        reason: 'Requires user confirmation: $purpose',
      );
    }

    return PolicyDecision(
      decision: OperatorPolicyDecisionType.allow,
      risk: risk,
      reason: 'Allowed autonomous action: $purpose',
    );
  }
}

int inferRisk(ActionCommand command, String purpose) {
  if (_defaultBlockedPurposes.contains(purpose)) return 4;
  if (_isSimulationCommand(command)) return 2;
  if (purpose.contains('pay') ||
      purpose.contains('transfer') ||
      purpose.contains('delete'))
    return 3;
  if (_defaultConfirmPurposes.contains(purpose) ||
      command.type == OperatorActionType.confirm)
    return 2;
  if (command.type == OperatorActionType.tap ||
      command.type == OperatorActionType.tapPoint ||
      command.type == OperatorActionType.click ||
      command.type == OperatorActionType.type ||
      command.type == OperatorActionType.key ||
      command.type == OperatorActionType.drag ||
      command.type == OperatorActionType.touch) {
    return 1;
  }
  return 0;
}

bool _isSimulationCommand(ActionCommand command) {
  return command.type == OperatorActionType.installNetworkMock ||
      command.type == OperatorActionType.installFirebaseMock ||
      command.type == OperatorActionType.supplyMedia ||
      command.type == OperatorActionType.injectState ||
      command.type == OperatorActionType.injectStorage ||
      command.type == OperatorActionType.clearStorage ||
      command.type == OperatorActionType.injectForm ||
      command.type == OperatorActionType.clearSimulation ||
      command.type == OperatorActionType.setNetworkConditions ||
      command.type == OperatorActionType.clearNetworkConditions;
}

String _confirmationMessage(
  ActionCommand command,
  String purpose,
  AppSnapshot? context,
) {
  if (command.type == OperatorActionType.confirm && command.message != null)
    return command.message!;
  final screen =
      context?.route.current.title ??
      context?.route.current.name ??
      context?.route.current.path;
  final location = screen == null ? '' : ' on $screen';
  return 'Confirm ${purpose.replaceAll('_', ' ')}$location?';
}

String _normalizePurpose(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}
