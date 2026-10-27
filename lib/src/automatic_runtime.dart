import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show CheckedState;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Diagnosticable, ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart'
    show
        ButtonStyleButton,
        Checkbox,
        DropdownButton,
        FloatingActionButton,
        IconButton,
        InkWell,
        InputDecoration,
        Radio,
        Slider,
        Switch,
        TextField;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart' as gx;

import 'action_registry.dart';
import 'adapter.dart';
import 'network_virtualization_probe.dart'
    if (dart.library.js_interop) 'network_virtualization_probe_web.dart';
import 'page_bridge_contract.dart';
import 'protocol.dart';
import 'runtime.dart';
import 'verifier.dart';

const _userActionSettleDelay = Duration(milliseconds: 120);

/// The wait between presses in a row when none is given: the shortest at which an iPhone, Android
/// and Flutter all take two presses as a double tap, so a second press lands while the work the
/// first one started is still running.
const _defaultPressInterval = Duration(milliseconds: 40);
const _interactionPollDelay = Duration(milliseconds: 80);
const _deferredInteractionVerificationTimeout = Duration(milliseconds: 1800);

class OperatorAutomaticFlutterRuntime
    implements
        OperatorFlutterActuator,
        OperatorFlutterHostKeyActuator,
        OperatorFlutterPointInspector {
  OperatorAutomaticFlutterRuntime({
    required this.operator,
    required this.registry,
  }) {
    _uiProviderDisposer = operator.addUiProvider(_readUiElements);
  }

  final OperatorFlutter operator;
  final OperatorActionRegistry registry;
  VoidCallback? _uiProviderDisposer;
  VoidCallback? _stateProviderDisposer;
  SemanticsHandle? _semanticsHandle;
  PipelineOwner? _pipelineOwner;
  _AutomaticStateIndexers _stateIndexers = const _AutomaticStateIndexers();
  final DefaultOperatorFlutterActuator _simulationActuator =
      DefaultOperatorFlutterActuator();
  final Expando<String> _runtimeControlIds = Expando<String>(
    'operatorFlutterRuntimeControlId',
  );
  final Map<Type, bool> _modalScopeWidgetTypes = <Type, bool>{};
  Map<String, _FlutterRuntimeControlBinding> _runtimeControlsById =
      <String, _FlutterRuntimeControlBinding>{};
  final _FlutterObservationTargetRegistry _observationTargets =
      _FlutterObservationTargetRegistry();
  int _runtimeControlCounter = 0;
  static const int _syntheticMousePointer = 8675309;
  int _syntheticPointerCounter = _syntheticMousePointer + 1;
  bool _syntheticMousePointerAdded = false;
  Offset _syntheticMousePosition = Offset.zero;

  @override
  JsonMap inspectPoint(double x, double y, {String? scrollDirection}) {
    if (scrollDirection != null &&
        !['up', 'down', 'left', 'right'].contains(scrollDirection)) {
      throw ArgumentError.value(scrollDirection, 'scrollDirection');
    }
    final viewport = _viewportSize();
    if (!x.isFinite ||
        !y.isFinite ||
        viewport == null ||
        x < 0 ||
        y < 0 ||
        x >= viewport.width ||
        y >= viewport.height) {
      throw StateError('point_inspection_outside_viewport');
    }
    final base = <String, Object?>{
      'viewport': {'width': viewport.width, 'height': viewport.height},
      'status': 'not_found',
    };
    final control = _controlAt(Offset(x, y), scrollDirection: scrollDirection);
    if (control == null || !control.enabled) return base;
    final reference = _observationTargets.referenceForLiveControl(control);
    if (reference == null) throw StateError('point_inspection_target_changed');
    final bounds = control.bounds!;
    return <String, Object?>{
      ...base,
      'status': 'found',
      'control': <String, Object?>{
        'id': control.id,
        'observationTargetRef': {
          'version': reference.version,
          'ticketId': reference.ticketId,
          'snapshotId': reference.snapshotId,
        },
        'role': control.role.name,
        'label': control.label,
        'value':
            control.secure
                ? '[SECURE_FIELD]'
                : control.textController?.text ?? control.value,
        'secure': control.secure,
        'actions': control.actions,
        'bounds': {
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        },
      },
    };
  }

  /// The one control the frontmost hit branch at [point] belongs to, disabled or not; null when
  /// no recognised control owns the point or two controls could.
  _FlutterRuntimeControlBinding? _controlAt(
    Offset point, {
    String? scrollDirection,
  }) {
    final hit = _hitTestAt(point);
    if (hit.error != null) throw StateError('point_inspection_hit_test_failed');
    // Only the frontmost hit branch can own this point. Searching every hit or
    // just rectangles could resolve a covered button behind an opaque overlay.
    final front = hit.targets.whereType<RenderObject>().firstOrNull;
    if (front == null) return null;
    final ancestry = <RenderObject, int>{};
    RenderObject? current = front;
    var distance = 0;
    while (current != null) {
      ancestry[current] = distance++;
      current = current.parent;
    }
    _FlutterRuntimeControlBinding? selected;
    int? selectedDistance;
    var ambiguous = false;
    void consider(Element element) {
      // Only an element whose render object lies on the hit branch can own the
      // point, so no control binding is built for the rest of the app.
      final owner = element.findRenderObject();
      final depth = ancestry[owner];
      final bestDistance = selectedDistance;
      if (depth == null || (bestDistance != null && depth > bestDistance))
        return;
      final live = _runtimeControlForElement(element);
      if (live == null) return;
      if (scrollDirection != null) {
        final position = live.scrollOwner;
        final vertical = scrollDirection == 'up' || scrollDirection == 'down';
        if (position == null ||
            position.axis != (vertical ? Axis.vertical : Axis.horizontal))
          return;
      }
      if (live.scrollOwner != null) {
        var editorImplementation = false;
        element.visitAncestorElements((ancestor) {
          editorImplementation = ancestor.widget is EditableText;
          return !editorImplementation;
        });
        // EditableText's internal scrolling is part of the text field, not a
        // separate user control. A real suffix button/list remains independent.
        if (editorImplementation) return;
      }
      if (!live.rendered ||
          !live.inViewport ||
          live.bounds?.contains(point) != true ||
          (live.enabled &&
              !live.actions.any(
                (a) => a != 'key' && a != 'hover' && a != 'scrollIntoView',
              )))
        return;
      if (selectedDistance == depth) {
        final previous = selected!;
        var sameBranch = false;
        element.visitAncestorElements((ancestor) {
          if (identical(ancestor, previous.element)) sameBranch = true;
          return !sameBranch;
        });
        if (!sameBranch || previous.role != live.role) {
          ambiguous = true;
        } else {
          // Framework button wrappers may share the exact RenderObject. They
          // are aliases on one branch, not competing controls. Prefer a named
          // wrapper (e.g. IconButton.tooltip), otherwise the inner control.
          final namedPrevious = previous.label?.trim().isNotEmpty == true;
          if (!namedPrevious) selected = live;
        }
      } else {
        selected = live;
        selectedDistance = depth;
        ambiguous = false;
      }
    }

    // Every element is visited, but only one whose render object lies on the
    // hit branch can be chosen (consider checks the ancestry), so a covered
    // control behind the point never wins. The element tree is walked whole
    // because it does not always nest like the render tree: an OverlayPortal's
    // child (an autocomplete or menu list) is the portal's element child but
    // paints in the Overlay, outside the portal's render branch.
    void walk(Element element) {
      if (!element.mounted) return;
      consider(element);
      element.visitChildren(walk);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) walk(root);
    return ambiguous ? null : selected;
  }

  void configureStateIndexers({
    required bool provider,
    required bool riverpod,
    required bool getx,
    required bool setState,
    required bool changeNotifier,
    required bool valueNotifier,
  }) {
    _stateIndexers = _AutomaticStateIndexers(
      provider: provider,
      riverpod: riverpod,
      getx: getx,
      setState: setState,
      changeNotifier: changeNotifier,
      valueNotifier: valueNotifier,
      custom:
          provider ||
          riverpod ||
          getx ||
          setState ||
          changeNotifier ||
          valueNotifier,
    );

    if (_stateIndexers.any && _stateProviderDisposer == null) {
      _stateProviderDisposer = operator.addStateProvider(_readStateStores);
    } else if (!_stateIndexers.any && _stateProviderDisposer != null) {
      _stateProviderDisposer?.call();
      _stateProviderDisposer = null;
    }
  }

  void ensureInstalled() {
    _semanticsHandle ??= SemanticsBinding.instance.ensureSemantics();
  }

  void attachPipelineOwner(PipelineOwner owner) {
    if (_pipelineOwner == owner) return;
    _pipelineOwner = owner;
    ensureInstalled();
  }

  void captureRouteFromElementTree({bool emit = true}) {
    final route = _findCurrentRoute(WidgetsBinding.instance.rootElement);
    if (route == null) return;
    operator.captureRoute(
      name: route.name,
      path: route.path,
      screenClass: route.screenClass,
      params: route.params,
      emit: emit,
    );
  }

  void dispose() {
    _uiProviderDisposer?.call();
    _uiProviderDisposer = null;
    _stateProviderDisposer?.call();
    _stateProviderDisposer = null;
    _semanticsHandle?.dispose();
    _semanticsHandle = null;
    _removeSyntheticMousePointer();
    _runtimeControlsById = <String, _FlutterRuntimeControlBinding>{};
    _observationTargets.clear();
  }

  @override
  Future<ActionResult?> execute(
    ActionCommand command,
    OperatorFlutter operator,
  ) async {
    ensureInstalled();

    final observationTarget = _observationTargetForCommand(command);
    final observationRef = observationTarget?.observationTargetRef;
    final requiredAction = _requiredRuntimeAction(command.type);
    if (observationRef == null || requiredAction == null) {
      captureRouteFromElementTree();
      return _executeCommand(command, operator);
    }
    final deliveryId = _deliveryIdFor(command, observationRef);

    final begun = _observationTargets.begin(
      observationRef,
      targetId: observationTarget?.id,
      deliveryId: deliveryId,
    );
    final additionalObservationRefs = <FlutterObservationTargetRef>[];
    if (begun.status == _FlutterObservationTargetBeginStatus.execute &&
        command.type == OperatorActionType.drag) {
      final destination = command.destination;
      final destinationRef = destination?.observationTargetRef;
      if (destination == null || destinationRef == null) {
        final result = _reobservationRequired(command);
        _observationTargets.invalidate(observationRef, deliveryId, result);
        return result;
      }
      if (destinationRef.ticketId != observationRef.ticketId) {
        final destinationBegun = _observationTargets.begin(
          destinationRef,
          targetId: destination.id,
          deliveryId: deliveryId,
        );
        if (destinationBegun.status !=
            _FlutterObservationTargetBeginStatus.execute) {
          final result = _reobservationRequired(command);
          _observationTargets.invalidate(observationRef, deliveryId, result);
          return result;
        }
        additionalObservationRefs.add(destinationRef);
      }
    }
    // Claim the exact target before route refresh emits a newer observation.
    // Multi-target gestures claim every endpoint before the refresh. A newer
    // snapshot revokes future use of old tickets, while an already in-flight
    // action keeps the private mounted-object bindings it began with.
    captureRouteFromElementTree();
    switch (begun.status) {
      case _FlutterObservationTargetBeginStatus.unavailable:
        return _reobservationRequired(command);
      case _FlutterObservationTargetBeginStatus.delivered:
        return begun.result!;
      case _FlutterObservationTargetBeginStatus.join:
        return await begun.sharedResult!;
      case _FlutterObservationTargetBeginStatus.execute:
        break;
    }

    if (_runtimeControlForTarget(
          observationTarget,
          requiredAction: requiredAction,
        ) ==
        null) {
      final result = _reobservationRequired(command);
      _observationTargets.invalidate(observationRef, deliveryId, result);
      for (final reference in additionalObservationRefs) {
        _observationTargets.invalidate(reference, deliveryId, result);
      }
      return result;
    }

    try {
      final result = await _executeCommand(command, operator);
      final completed = result ?? _reobservationRequired(command);
      _observationTargets.complete(observationRef, deliveryId, completed);
      for (final reference in additionalObservationRefs) {
        _observationTargets.complete(reference, deliveryId, completed);
      }
      return completed;
    } catch (error) {
      _observationTargets.fail(observationRef, deliveryId, error);
      for (final reference in additionalObservationRefs) {
        _observationTargets.fail(reference, deliveryId, error);
      }
      rethrow;
    }
  }

  @override
  Future<ActionResult> prepareHostKey(
    ActionCommand command,
    OperatorFlutter operator,
  ) async {
    ensureInstalled();
    if (command.type != OperatorActionType.key) {
      return ActionResult(
        ok: false,
        action: command,
        error: const ActionError(
          type: 'unsupported_action',
          message: 'Host key preparation requires a key action',
        ),
      );
    }
    final target = command.target;
    final reference = target?.observationTargetRef;
    if (target == null) {
      return _reobservationRequired(command);
    }
    if (reference == null) {
      final control = _runtimeControlForTarget(target, requiredAction: 'key');
      if (control == null) return _reobservationRequired(command);
      return _prepareHostKeyControl(command, control);
    }
    final deliveryId = _deliveryIdFor(command, reference);
    final begun = _observationTargets.begin(
      reference,
      targetId: target.id,
      deliveryId: deliveryId,
    );
    switch (begun.status) {
      case _FlutterObservationTargetBeginStatus.unavailable:
        return _reobservationRequired(command);
      case _FlutterObservationTargetBeginStatus.delivered:
        return begun.result!;
      case _FlutterObservationTargetBeginStatus.join:
        return await begun.sharedResult!;
      case _FlutterObservationTargetBeginStatus.execute:
        break;
    }

    final control = _runtimeControlForTarget(target, requiredAction: 'key');
    if (control == null) {
      final result = _reobservationRequired(command);
      _observationTargets.invalidate(reference, deliveryId, result);
      return result;
    }
    final result = await _prepareHostKeyControl(command, control);
    if (result.ok) {
      _observationTargets.complete(reference, deliveryId, result);
    } else {
      _observationTargets.invalidate(reference, deliveryId, result);
    }
    return result;
  }

  String _deliveryIdFor(
    ActionCommand command,
    FlutterObservationTargetRef reference,
  ) {
    final explicit = command.deliveryId?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return 'legacy:${reference.ticketId}:${reference.snapshotId}';
  }

  Future<ActionResult> _prepareHostKeyControl(
    ActionCommand command,
    _FlutterRuntimeControlBinding control,
  ) async {
    if (command.focusTarget != false) {
      final focusNode = control.focusNode;
      if (focusNode == null || !focusNode.canRequestFocus) {
        return ActionResult(
          ok: false,
          action: command,
          data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
          error: const ActionError(
            type: 'target_not_focusable',
            message: 'The exact Flutter target cannot receive keyboard focus',
            retryable: true,
          ),
        );
      }
      focusNode.requestFocus();
      await _settleAfterUserAction(refreshRoute: false);
      if (!focusNode.hasFocus) {
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'target_focus_unverified',
            message: 'Flutter did not confirm focus on the exact key target',
            retryable: true,
          ),
        );
      }
    }
    return ActionResult(
      ok: true,
      action: command,
      message:
          'Prepared exact Flutter target ${control.id} for browser key input',
      data: <String, Object?>{
        'targetId': control.id,
        'focusTarget': command.focusTarget != false,
      },
    );
  }

  Future<ActionResult?> _executeCommand(
    ActionCommand command,
    OperatorFlutter operator,
  ) async {
    switch (command.type) {
      case OperatorActionType.tap:
      case OperatorActionType.click:
        final result = await _tap(command);
        if (result != null) return result;
        return registry.execute(command, operator);
      case OperatorActionType.tapPoint:
        return _tapPoint(command);
      case OperatorActionType.type:
        final result = await _setText(command);
        if (result != null) return result;
        return registry.execute(command, operator);
      case OperatorActionType.clear:
        final result = await _setText(command, clear: true);
        if (result != null) return result;
        return registry.execute(command, operator);
      case OperatorActionType.hover:
        return _hover(command);
      case OperatorActionType.key:
        return null;
      case OperatorActionType.drag:
        return _drag(command);
      case OperatorActionType.touch:
        return _touch(command);
      case OperatorActionType.scroll:
        final result = await _scroll(command);
        if (result != null) return result;
        return null;
      case OperatorActionType.scrollIntoView:
        final result = await _scrollIntoView(command);
        if (result != null) return result;
        return null;
      case OperatorActionType.scrollTo:
        return _scrollTo(command);
      case OperatorActionType.navigate:
        final result = await _navigate(command);
        if (result != null) return result;
        return registry.execute(command, operator);
      case OperatorActionType.wait:
        return _wait(command);
      case OperatorActionType.captureVisual:
        return _simulationActuator.execute(command, operator);
      case OperatorActionType.askUser:
      case OperatorActionType.confirm:
        return registry.execute(command, operator);
      case OperatorActionType.installNetworkMock:
        final blocked = _simulationBlocked(
          operator,
          command,
          'Network mocking',
        );
        if (blocked != null) return blocked;
        final match = command.match;
        final response = command.response;
        if (match == null || response == null) {
          return ActionResult(
            ok: false,
            action: command,
            error: const ActionError(
              type: 'invalid_network_mock',
              message: 'Network mock requires match and response',
            ),
          );
        }
        final id = operator.installNetworkMock(
          match,
          response,
          ttl: command.ttl,
        );
        return ActionResult(
          ok: true,
          action: command,
          message: 'Installed network mock $id',
        );
      case OperatorActionType.probeNetworkVirtualization:
        return probeOperatorNetworkVirtualization(operator, command);
      case OperatorActionType.installFirebaseMock:
        final blocked = _simulationBlocked(
          operator,
          command,
          'Firebase mocking',
        );
        if (blocked != null) return blocked;
        final match = command.firebase;
        final response = command.firebaseResponse;
        if (match == null || response == null) {
          return ActionResult(
            ok: false,
            action: command,
            error: const ActionError(
              type: 'invalid_firebase_mock',
              message: 'Firebase mock requires firebase and firebaseResponse',
            ),
          );
        }
        final id = operator.installFirebaseMock(
          match,
          response,
          ttl: command.ttl,
        );
        return ActionResult(
          ok: true,
          action: command,
          message: 'Installed Firebase mock $id',
        );
      case OperatorActionType.probeFirebaseVirtualization:
        final blocked = _simulationBlocked(
          operator,
          command,
          'Firebase virtualization probing',
        );
        if (blocked != null) return blocked;
        final result = await operator.runVirtualizationProbe(
          'firebase',
          command,
        );
        if (result != null) return result;
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'firebase_virtualization_probe_unavailable',
            message:
                'No Firebase virtualization probe is registered. Install huntingdogs_firebase and enable OperatorFirebaseVirtualization.integration().',
            retryable: false,
          ),
        );
      case OperatorActionType.supplyMedia:
        final blocked = _simulationBlocked(operator, command, 'Media supply');
        if (blocked != null) return blocked;
        final result = await operator.runVirtualizationProbe('media', command);
        if (result != null) return result;
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'media_stand_in_unavailable',
            message:
                'No media stand-in is registered. Install huntingdogs_media and enable OperatorMediaVirtualization.integration().',
            retryable: false,
          ),
        );
      case OperatorActionType.injectState:
        final blocked = _simulationBlocked(
          operator,
          command,
          'State injection',
        );
        if (blocked != null) return blocked;
        final store = command.store;
        if (store == null) {
          return ActionResult(
            ok: false,
            action: command,
            error: const ActionError(
              type: 'invalid_state_injection',
              message: 'State injection requires a store name',
            ),
          );
        }
        operator.injectState(store, command.value, mode: command.stateMode);
        return ActionResult(
          ok: true,
          action: command,
          message: 'Injected state $store',
        );
      case OperatorActionType.injectStorage:
      case OperatorActionType.clearStorage:
      case OperatorActionType.setNetworkConditions:
      case OperatorActionType.clearNetworkConditions:
        return _simulationActuator.execute(command, operator);
      case OperatorActionType.injectForm:
        return _injectForm(command);
      case OperatorActionType.clearSimulation:
        final blocked = _simulationBlocked(
          operator,
          command,
          'Simulation clearing',
        );
        if (blocked != null) return blocked;
        final scope = command.scope ?? 'all';
        // Supplied media goes back first, while its records still belong to the test that ends. A
        // stand-in that fails reports it, and the rest of the cleanup still runs.
        ActionResult? media;
        if (scope == 'all' || scope == 'media') {
          try {
            media = await operator.runVirtualizationProbe('media', command);
          } catch (error) {
            media = ActionResult(
              ok: false,
              action: command,
              error: ActionError(
                type: 'simulation_cleanup_failed',
                message: '$error',
              ),
            );
          }
        }
        operator.clearSimulation(scope);
        if (media != null && !media.ok) {
          return ActionResult(
            ok: false,
            action: command,
            error: ActionError(
              type: 'simulation_cleanup_failed',
              message:
                  'The media stand-in did not take its files back: ${media.error?.message ?? 'no reason given'}',
              retryable: false,
            ),
            data: <String, Object?>{'media': media.data},
          );
        }
        return ActionResult(
          ok: true,
          action: command,
          message: 'Cleared simulation ${command.scope ?? 'all'}',
          data: <String, Object?>{if (media != null) 'media': media.data},
        );
    }
  }

  ElementTarget? _observationTargetForCommand(ActionCommand command) {
    return switch (command.type) {
      OperatorActionType.tap ||
      OperatorActionType.click ||
      OperatorActionType.type ||
      OperatorActionType.clear ||
      OperatorActionType.hover ||
      OperatorActionType.scrollIntoView => command.target,
      OperatorActionType.drag => command.source,
      OperatorActionType.touch =>
        command.gesture == 'tap' ? command.target : command.start,
      OperatorActionType.scroll => command.container ?? command.target,
      OperatorActionType.scrollTo => command.container,
      _ => null,
    };
  }

  String? _requiredRuntimeAction(OperatorActionType type) {
    return switch (type) {
      OperatorActionType.tap || OperatorActionType.click => 'tap',
      OperatorActionType.type => 'type',
      OperatorActionType.clear => 'clear',
      OperatorActionType.hover => 'hover',
      OperatorActionType.drag => 'drag',
      OperatorActionType.touch => 'touch',
      OperatorActionType.scroll => 'scroll',
      OperatorActionType.scrollIntoView => 'scrollIntoView',
      OperatorActionType.scrollTo => 'scroll',
      _ => null,
    };
  }

  ActionResult _reobservationRequired(
    ActionCommand command, {
    String operationPhase = 'zero_dispatch',
  }) {
    return ActionResult(
      ok: false,
      action: command,
      data: <String, Object?>{'operationPhase': operationPhase},
      error: const ActionError(
        type: 'semantic_reobservation_required',
        message:
            'The exact Flutter observation target is no longer current. Capture a fresh snapshot and use its new target reference.',
        retryable: true,
      ),
    );
  }

  Future<ActionResult?> _injectForm(ActionCommand command) async {
    if (operator.config.environment == OperatorEnvironment.production) {
      return ActionResult(
        ok: false,
        action: command,
        error: const ActionError(
          type: 'simulation_blocked',
          message: 'Form injection is only available in dev or staging',
        ),
      );
    }
    if (command.fields.isEmpty) {
      return ActionResult(
        ok: true,
        action: command,
        message: 'No form fields requested',
      );
    }

    final applied = <String>[];
    final missing = <String>[];

    for (final field in command.fields) {
      final key = field.id ?? field.name;
      if (key == null) {
        missing.add('<unnamed>');
        continue;
      }

      final target = _targetForFormField(field);
      var handled = false;
      if (field.value != null) {
        final match =
            _resolve(target, preferredAction: SemanticsAction.setText) ??
            _resolve(target);
        final trustedMatch =
            _stronglyMatchesFormField(match, field) ? match : null;
        handled = _setTextViaFlutterWidgetTree(
          target,
          trustedMatch,
          field.value.toString(),
        );
        if (!handled &&
            trustedMatch != null &&
            _semanticsOwner != null &&
            trustedMatch.data.hasAction(SemanticsAction.setText)) {
          _semanticsOwner!.performAction(
            trustedMatch.node.id,
            SemanticsAction.setText,
            field.value.toString(),
          );
          handled = true;
        }
      } else if (field.checked != null || field.selected != null) {
        final match = _resolve(target, preferredAction: SemanticsAction.tap);
        if (match != null) {
          final owner = _semanticsOwner;
          if (owner != null && match.data.hasAction(SemanticsAction.tap)) {
            owner.performAction(match.node.id, SemanticsAction.tap);
            handled = true;
          } else if (!match.bounds.isEmpty && match.bounds.isFinite) {
            _dispatchPointerTap(match.bounds.center);
            handled = true;
          }
        }
      }

      if (handled) {
        applied.add(key);
      } else {
        missing.add(key);
      }
    }

    if (applied.isNotEmpty) await _settleAfterUserAction();
    if (missing.isEmpty) {
      return ActionResult(
        ok: true,
        action: command,
        message: 'Injected ${applied.length} real form field(s)',
      );
    }

    return ActionResult(
      ok: false,
      action: command,
      error: ActionError(
        type: 'form_field_not_found',
        message:
            'Injected ${applied.length}/${command.fields.length} real form field(s); missing ${missing.join(', ')}',
        retryable: true,
      ),
    );
  }

  Future<ActionResult?> _tap(ActionCommand command) async {
    final timing = _TapPhaseTiming();
    ActionResult finish(ActionResult result) =>
        _withTapPhaseTiming(result, timing);
    final runtimeControl = _runtimeControlForTarget(command.target);
    if (runtimeControl != null &&
        (!runtimeControl.enabled ||
            !runtimeControl.visible ||
            !runtimeControl.actions.contains('tap') ||
            runtimeControl.bounds == null)) {
      final reasons = <String>[
        if (!runtimeControl.enabled) 'disabled',
        if (!runtimeControl.visible) 'not visible',
        if (!runtimeControl.actions.contains('tap')) 'no tap action',
        if (runtimeControl.bounds == null) 'no rendered bounds',
      ];
      return finish(
        ActionResult(
          ok: false,
          action: command,
          data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
          error: ActionError(
            type: 'target_not_actionable',
            message:
                'Flutter element matched ${_targetLabel(command.target)}, but it cannot be tapped: ${reasons.join(', ')}',
            retryable: true,
          ),
        ),
      );
    }
    if (runtimeControl != null &&
        command.target?.observationTargetRef != null) {
      return finish(await _mechanicalRuntimeTap(command));
    }
    // The taps below find their target by its words or place and press once.
    if ((command.count ?? 1) > 1) {
      return finish(operatorPressesOnceOnlyResult(command));
    }
    final directFallbackPoint =
        runtimeControl?.bounds?.center ?? _fallbackPoint(command.target);
    final coordinateOnly =
        runtimeControl != null || _coordinateOnlyTarget(command.target);
    final evidence = <VerificationEvidence>[];

    if (directFallbackPoint != null && coordinateOnly) {
      var dispatchPoint = directFallbackPoint;
      final before = await timing.time(
        'fingerprint.before',
        () => _interactionFingerprint(
          includeAmbientSignals: false,
          includeStateSignals: false,
        ),
      );
      final beforeSnapshot = await timing.time(
        'snapshot.before',
        _interactionSnapshot,
      );
      if (runtimeControl != null) {
        final currentControl = _runtimeControlForTarget(command.target);
        final currentBounds = currentControl?.bounds;
        if (currentControl == null ||
            !currentControl.enabled ||
            !currentControl.visible ||
            !currentControl.actions.contains('tap') ||
            currentBounds == null) {
          return finish(
            ActionResult(
              ok: false,
              action: command,
              data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
              error: ActionError(
                type: 'target_not_actionable',
                message:
                    'Flutter element ${_targetLabel(command.target)} was replaced or became non-actionable before tap dispatch',
                retryable: true,
              ),
            ),
          );
        }
        dispatchPoint = currentBounds.center;
      }
      final candidate = _tapCandidate(
        dispatchPoint,
        reason: 'target.fallbackPoint',
        priority: 100,
      );
      evidence.add(
        _tapAttemptEvidence(
          actuator: 'pointer',
          candidate: candidate,
          ok: false,
          detail: 'dispatching coordinate-only tap',
        ),
      );
      timing.timeSync('pointer.dispatch', () {
        _dispatchPointerTap(dispatchPoint);
        return true;
      });
      if (await timing.time(
        'pointer.wait_change',
        () => _waitForInteractionChange(
          before,
          includeAmbientSignals: false,
          includeStateSignals: false,
          refreshRoute: false,
        ),
      )) {
        final afterSnapshot = await timing.time(
          'snapshot.after',
          _postInteractionSnapshot,
        );
        final interruption = await timing.time(
          'dialog_check',
          () => _tapInterruptionFromSettledSnapshot(
            command: command,
            match: null,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot,
            evidence: evidence,
            candidate: candidate,
            actuator: 'pointer',
          ),
        );
        if (interruption != null) return finish(interruption);
        return finish(
          ActionResult(
            ok: true,
            action: command,
            message: 'Tapped at ${_formatOffset(dispatchPoint)}',
            evidence: <VerificationEvidence>[
              _tapAttemptEvidence(
                actuator: 'pointer',
                candidate: candidate,
                ok: true,
                detail: 'verified app change after coordinate-only tap',
              ),
            ],
          ),
        );
      }
      final deferred = await timing.time(
        'deferred.wait',
        () => _deferredTapEffectResult(
          command: command,
          before: before,
          beforeSnapshot: beforeSnapshot,
          evidence: evidence,
          match: null,
          successMessage: 'Tapped at ${_formatOffset(dispatchPoint)}',
        ),
      );
      if (deferred != null) return finish(deferred);
      return finish(
        ActionResult(
          ok: false,
          action: command,
          error: ActionError(
            type: 'tap_effect_unverified',
            message:
                'Tap was dispatched at ${_formatOffset(dispatchPoint)}, but Operator could not verify the app effect',
            retryable: true,
          ),
          evidence: evidence,
        ),
      );
    }

    final match = timing.timeSync(
      'resolve',
      () => _resolve(command.target, preferredAction: SemanticsAction.tap),
    );
    if (match == null) {
      if (command.target != null) {
        final notActionable = _tapTargetNotActionableResult(command);
        if (notActionable != null) return finish(notActionable);
        return finish(
          ActionResult(
            ok: false,
            action: command,
            data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
            error: ActionError(
              type: 'target_not_found',
              message:
                  'No tappable Flutter element matched ${_targetLabel(command.target)}',
              retryable: true,
            ),
          ),
        );
      }
      return null;
    }

    if (_unlabelledSpecificTextMatch(match, command.target) &&
        command.target?.fallbackBounds == null &&
        _widgetTapCandidates(match, command.target).isEmpty &&
        !_trustedLabelledSemanticControl(match, command.target)) {
      return finish(
        ActionResult(
          ok: false,
          action: command,
          data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
          error: ActionError(
            type: 'target_bounds_untrusted',
            message:
                'Matched ${_targetLabel(command.target)} only through an unlabeled Flutter semantics node. Operator refused to tap its bounds because they may be local or unrelated; provide a stable id, label, or fallbackBounds.',
            retryable: true,
          ),
          evidence: <VerificationEvidence>[
            VerificationEvidence(
              source: OperatorVerificationSource.action,
              condition: 'tap.target_bounds_untrusted',
              ok: false,
              detail:
                  'matched=${match.description}; id=${_uiElementId(match)}; bounds=${_formatRect(match.bounds)}',
            ),
          ],
        ),
      );
    }

    final hasSemanticsTap = match.data.hasAction(SemanticsAction.tap);
    final fallbackPoint = _fallbackPoint(command.target);
    final candidates = timing.timeSync(
      'candidates',
      () => _tapCandidates(match, command.target),
    );
    if (command.target != null &&
        !hasSemanticsTap &&
        fallbackPoint == null &&
        !_hasActionableTapCandidate(candidates)) {
      final notActionable = _tapTargetNotActionableResult(command);
      return notActionable == null ? null : finish(notActionable);
    }
    final before = await timing.time(
      'fingerprint.before',
      () => _interactionFingerprint(
        includeAmbientSignals: false,
        includeStateSignals: false,
      ),
    );
    final beforeSnapshot = await timing.time(
      'snapshot.before',
      _interactionSnapshot,
    );
    var attempted = false;
    const pointerVerificationTimeout = Duration(milliseconds: 350);

    Future<ActionResult?> tryPointerCandidate(_TapCandidate candidate) async {
      attempted = true;
      evidence.add(
        _tapAttemptEvidence(
          actuator: 'pointer',
          candidate: candidate,
          ok: false,
          detail: 'dispatching pointer tap',
        ),
      );
      timing.timeSync('pointer.dispatch', () {
        _dispatchPointerTap(candidate.position);
        return true;
      });
      final expectedDelegated = _expectedConditionTapDispatchedResult(
        command: command,
        match: candidate.match ?? match,
        candidate: candidate,
        actuator: 'pointer',
        successMessage:
            'Tapped ${match.description} at ${_formatOffset(candidate.position)}',
        evidence: evidence,
      );
      if (expectedDelegated != null) return finish(expectedDelegated);
      if (await timing.time(
        'pointer.wait_change',
        () => _waitForInteractionChange(
          before,
          timeout: pointerVerificationTimeout,
          includeAmbientSignals: false,
          includeStateSignals: false,
          refreshRoute: false,
        ),
      )) {
        final afterSnapshot = await timing.time(
          'snapshot.after',
          _postInteractionSnapshot,
        );
        if (_isNonInputTapTarget(match, command.target) &&
            _snapshotShowsTextEditMenu(afterSnapshot)) {
          evidence.add(
            _tapAttemptEvidence(
              actuator: 'pointer',
              candidate: candidate,
              ok: false,
              detail:
                  'rejected pointer tap because a text-edit menu appeared for a non-input target',
            ),
          );
          return null;
        }
        final interruption = await timing.time(
          'dialog_check',
          () => _tapInterruptionFromSettledSnapshot(
            command: command,
            match: match,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot,
            evidence: evidence,
            candidate: candidate,
            actuator: 'pointer',
          ),
        );
        if (interruption != null) return finish(interruption);
        final targetEffect = _semanticTapTargetEffect(
          command: command,
          match: match,
          beforeSnapshot: beforeSnapshot,
          afterSnapshot: afterSnapshot,
          candidate: candidate,
          actuator: 'pointer',
        );
        evidence.add(targetEffect.evidence);
        if (!targetEffect.ok) {
          final deferredTargetEffect = await _deferredTargetEffectSettlementResult(
            command: command,
            beforeSnapshot: beforeSnapshot,
            evidence: evidence,
            match: match,
            candidate: candidate,
            actuator: 'pointer',
            successMessage:
                'Tapped ${match.description} at ${_formatOffset(candidate.position)}',
          );
          if (deferredTargetEffect != null) return finish(deferredTargetEffect);
          return finish(_targetAmbiguousTapResult(command, evidence));
        }
        final successEvidence = _tapAttemptEvidence(
          actuator: 'pointer',
          candidate: candidate,
          ok: true,
          detail: 'verified app change after pointer tap',
        );
        return finish(
          ActionResult(
            ok: true,
            action: command,
            message:
                'Tapped ${match.description} at ${_formatOffset(candidate.position)}',
            evidence: <VerificationEvidence>[...evidence, successEvidence],
          ),
        );
      }
      if (_singleDispatchTapTarget(candidate.match ?? match, command.target)) {
        final deferred = await timing.time(
          'deferred.wait.single_candidate',
          () => _deferredTapEffectResult(
            command: command,
            before: before,
            beforeSnapshot: beforeSnapshot,
            evidence: evidence,
            match: candidate.match ?? match,
            candidate: candidate,
            actuator: 'pointer',
            successMessage: 'Tapped ${match.description}',
          ),
        );
        if (deferred != null) return finish(deferred);
        return finish(
          ActionResult(
            ok: false,
            action: command,
            error: ActionError(
              type: 'tap_effect_unverified',
              message:
                  'Tap was dispatched to ${match.description}, but Operator could not verify the app effect',
              retryable: true,
            ),
            evidence: evidence,
          ),
        );
      }
      return null;
    }

    for (final candidate in candidates.take(1)) {
      final result = await tryPointerCandidate(candidate);
      if (result != null) return result;
    }

    if (!attempted) return null;
    final deferred = await timing.time(
      'deferred.wait',
      () => _deferredTapEffectResult(
        command: command,
        before: before,
        beforeSnapshot: beforeSnapshot,
        evidence: evidence,
        match: match,
        successMessage: 'Tapped ${match.description}',
      ),
    );
    if (deferred != null) return finish(deferred);
    return finish(
      ActionResult(
        ok: false,
        action: command,
        error: ActionError(
          type: 'tap_effect_unverified',
          message:
              'Tap was dispatched to ${match.description}, but Operator could not verify the app effect',
          retryable: true,
        ),
        evidence: evidence,
      ),
    );
  }

  /// Presses the exact control; presses in a row after the first land at the same point, as a
  /// finger's do, on whatever is there by then.
  Future<ActionResult> _mechanicalRuntimeTap(ActionCommand command) async {
    final control = _runtimeControlForTarget(
      command.target,
      requiredAction: 'tap',
    );
    final bounds = control?.bounds;
    final renderObject = control?.element.findRenderObject();
    if (control == null ||
        !control.enabled ||
        !control.visible ||
        bounds == null ||
        !bounds.isFinite ||
        bounds.isEmpty ||
        renderObject == null ||
        !renderObject.attached) {
      return _reobservationRequired(command);
    }

    final dispatchPoint = bounds.center;
    final hit = _hitTestAt(dispatchPoint);
    if (!_hitTestBelongsTo(renderObject, hit)) {
      final hitPath = hit.path.isEmpty ? '<empty>' : hit.path.join(' > ');
      return ActionResult(
        ok: false,
        action: command,
        data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
        error: ActionError(
          type: 'target_hit_test_mismatch',
          message:
              'No click was sent. At the control dispatch point ${_formatOffset(dispatchPoint)}, '
              'the hit test did not include the intended control ${control.id}. '
              'Consider re-examining the screenshot to see if the control is blocked.',
          retryable: true,
        ),
        evidence: <VerificationEvidence>[
          VerificationEvidence(
            source: OperatorVerificationSource.action,
            condition: 'tap.mechanical_delivery.refused',
            ok: false,
            detail:
                'target=${control.id}; point=${_formatOffset(dispatchPoint)}; hit=$hitPath${hit.error == null ? '' : '; hitError=${hit.error}'}; dispatchedEvents=0',
          ),
        ],
      );
    }

    final presses = command.count ?? 1;
    final interval = command.interval ?? _defaultPressInterval;
    var dispatchedEvents = 0;
    try {
      final binding = GestureBinding.instance;
      for (var press = 0; press < presses; press += 1) {
        if (press > 0) await Future<void>.delayed(interval);
        final pointer = _syntheticPointerCounter++;
        binding.handlePointerEvent(
          PointerAddedEvent(
            pointer: pointer,
            position: dispatchPoint,
            kind: ui.PointerDeviceKind.touch,
          ),
        );
        dispatchedEvents += 1;
        binding.handlePointerEvent(
          PointerDownEvent(
            pointer: pointer,
            position: dispatchPoint,
            kind: ui.PointerDeviceKind.touch,
            buttons: kPrimaryButton,
          ),
        );
        dispatchedEvents += 1;
        binding.handlePointerEvent(
          PointerUpEvent(
            pointer: pointer,
            position: dispatchPoint,
            kind: ui.PointerDeviceKind.touch,
          ),
        );
        dispatchedEvents += 1;
        binding.handlePointerEvent(
          PointerRemovedEvent(
            pointer: pointer,
            position: dispatchPoint,
            kind: ui.PointerDeviceKind.touch,
          ),
        );
        dispatchedEvents += 1;
      }
    } catch (error) {
      final wasDispatched = dispatchedEvents > 0;
      return ActionResult(
        ok: false,
        action: command,
        error: ActionError(
          type: wasDispatched ? 'tap_dispatch_unknown' : 'tap_dispatch_failed',
          message:
              wasDispatched
                  ? 'Flutter accepted part of the pointer sequence before dispatch failed; the action will not be retried'
                  : 'Flutter rejected the pointer sequence before accepting an event: $error',
          retryable: !wasDispatched,
        ),
        evidence: <VerificationEvidence>[
          VerificationEvidence(
            source: OperatorVerificationSource.action,
            condition: 'tap.mechanical_delivery.failed',
            ok: false,
            detail:
                'target=${control.id}; point=${_formatOffset(dispatchPoint)}; dispatchedEvents=$dispatchedEvents; error=$error',
          ),
        ],
      );
    }

    return ActionResult(
      ok: true,
      action: command,
      message:
          presses == 1
              ? 'Delivered one pointer tap to exact Flutter target ${control.id}'
              : 'Delivered pointer taps to exact Flutter target ${control.id} '
                  '$presses times in a row, with a ${interval.inMilliseconds} ms wait between presses',
      data: <String, Object?>{
        if (presses > 1)
          'presses': <String, Object?>{
            'count': presses,
            'intervalMs': interval.inMilliseconds,
          },
      },
      evidence: <VerificationEvidence>[
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'tap.mechanical_delivery.acknowledged',
          ok: true,
          detail:
              'target=${control.id}; point=${_formatOffset(dispatchPoint)}; dispatchedEvents=$dispatchedEvents',
        ),
      ],
    );
  }

  Future<ActionResult?> _deferredTapEffectResult({
    required ActionCommand command,
    required String before,
    required AppSnapshot beforeSnapshot,
    required List<VerificationEvidence> evidence,
    required _SemanticsMatch? match,
    _TapCandidate? candidate,
    String actuator = 'deferred',
    required String successMessage,
  }) async {
    if (!await _waitForInteractionChange(
      before,
      timeout: _deferredInteractionVerificationTimeout,
      includeAmbientSignals: false,
      includeStateSignals: false,
    )) {
      return null;
    }
    final afterSnapshot = await _postInteractionSnapshot();
    final interruption = await _tapInterruptionFromSettledSnapshot(
      command: command,
      match: match,
      beforeSnapshot: beforeSnapshot,
      afterSnapshot: afterSnapshot,
      evidence: evidence,
      candidate: null,
      actuator: 'deferred',
    );
    if (interruption != null) return interruption;
    if (match != null) {
      final effectCandidate =
          candidate ??
          _tapCandidate(
            match.bounds.isFinite && !match.bounds.isEmpty
                ? match.bounds.center
                : Offset.zero,
            match: match,
            dispatchBounds: match.bounds,
            reason: 'deferred.target_effect',
            priority: 0,
          );
      final targetEffect = _semanticTapTargetEffect(
        command: command,
        match: match,
        beforeSnapshot: beforeSnapshot,
        afterSnapshot: afterSnapshot,
        candidate: effectCandidate,
        actuator: actuator,
      );
      evidence.add(targetEffect.evidence);
      if (!targetEffect.ok) {
        return _targetAmbiguousTapResult(command, evidence);
      }
    }
    return ActionResult(
      ok: true,
      action: command,
      message: successMessage,
      evidence: <VerificationEvidence>[
        ...evidence,
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'tap.deferred_effect.verified',
          ok: true,
          detail:
              'verified app change after dispatched tap settled; route=${afterSnapshot.route.current.path}; target=${match?.description ?? '<coordinate>'}',
        ),
      ],
    );
  }

  ActionResult _targetAmbiguousTapResult(
    ActionCommand command,
    List<VerificationEvidence> evidence,
  ) {
    return ActionResult(
      ok: false,
      action: command,
      error: const ActionError(
        type: 'tap_effect_target_ambiguous',
        message:
            'Tap changed the app, but Operator could not prove the change belonged to the requested target',
        retryable: true,
      ),
      evidence: evidence,
    );
  }

  Future<ActionResult?> _deferredTargetEffectSettlementResult({
    required ActionCommand command,
    required AppSnapshot beforeSnapshot,
    required List<VerificationEvidence> evidence,
    required _SemanticsMatch match,
    required _TapCandidate candidate,
    required String actuator,
    required String successMessage,
  }) async {
    final sampleInterval = const Duration(milliseconds: 80);
    final maxSamples = (_deferredInteractionVerificationTimeout.inMilliseconds /
            sampleInterval.inMilliseconds)
        .ceil()
        .clamp(1, 20);
    for (var sample = 0; sample < maxSamples; sample += 1) {
      await Future<void>.delayed(sampleInterval);
      final afterSnapshot = await _postInteractionSnapshot();
      final interruption = await _tapInterruptionFromSettledSnapshot(
        command: command,
        match: match,
        beforeSnapshot: beforeSnapshot,
        afterSnapshot: afterSnapshot,
        evidence: evidence,
        candidate: candidate,
        actuator: actuator,
      );
      if (interruption != null) return interruption;
      final targetEffect = _semanticTapTargetEffect(
        command: command,
        match: match,
        beforeSnapshot: beforeSnapshot,
        afterSnapshot: afterSnapshot,
        candidate: candidate,
        actuator: actuator,
      );
      if (!targetEffect.ok) continue;
      return ActionResult(
        ok: true,
        action: command,
        message: successMessage,
        evidence: <VerificationEvidence>[
          ...evidence,
          targetEffect.evidence,
          VerificationEvidence(
            source: OperatorVerificationSource.action,
            condition: 'tap.deferred_target_effect.verified',
            ok: true,
            detail:
                'verified delayed target-specific effect after dispatched $actuator tap settled; target=${_targetLabel(command.target)}; match=${match.description}',
          ),
        ],
      );
    }
    return null;
  }

  _TapTargetEffect _semanticTapTargetEffect({
    required ActionCommand command,
    required _SemanticsMatch match,
    required AppSnapshot beforeSnapshot,
    required AppSnapshot afterSnapshot,
    required _TapCandidate candidate,
    required String actuator,
  }) {
    if (command.expected.isNotEmpty) {
      return _TapTargetEffect.ok(
        'caller supplied explicit expected conditions; post-action verifier owns final outcome',
      );
    }
    if (command.target == null || _coordinateOnlyTarget(command.target)) {
      return _TapTargetEffect.ok('coordinate or any-target semantic action');
    }
    if (_routeChanged(beforeSnapshot, afterSnapshot)) {
      return _TapTargetEffect.ok(
        'route changed ${beforeSnapshot.route.current.path ?? beforeSnapshot.route.current.name ?? '<unknown>'} -> ${afterSnapshot.route.current.path ?? afterSnapshot.route.current.name ?? '<unknown>'}',
      );
    }
    final beforeElements = _snapshotElementsMatchingTarget(
      beforeSnapshot,
      command.target,
      match,
    );
    final afterElements = _snapshotElementsMatchingTarget(
      afterSnapshot,
      command.target,
      match,
    );
    final closeControlEffect = _closeControlTapEffect(
      command: command,
      match: match,
      beforeSnapshot: beforeSnapshot,
      afterSnapshot: afterSnapshot,
      beforeElements: beforeElements,
      afterElements: afterElements,
    );
    if (closeControlEffect != null) return closeControlEffect;
    if (_dialogVisibleTexts(afterSnapshot).isNotEmpty &&
        !_sameTextSet(
          _dialogVisibleTexts(beforeSnapshot),
          _dialogVisibleTexts(afterSnapshot),
        )) {
      return _TapTargetEffect.ok('target produced a new dialog/popup surface');
    }
    if (_targetElementsChanged(beforeElements, afterElements, match: match)) {
      return _TapTargetEffect.ok('target element state/text changed');
    }
    final generatedIdLeafEffect = _generatedIdLeafTargetEffect(
      command: command,
      match: match,
      beforeSnapshot: beforeSnapshot,
      afterSnapshot: afterSnapshot,
    );
    if (generatedIdLeafEffect != null) return generatedIdLeafEffect;
    final scopedVisibleTextEffect = _targetScopedVisibleTextEffect(
      command: command,
      match: match,
      beforeSnapshot: beforeSnapshot,
      afterSnapshot: afterSnapshot,
      candidate: candidate,
      actuator: actuator,
    );
    if (scopedVisibleTextEffect != null) return scopedVisibleTextEffect;
    if (actuator == 'pointer' && _hitTestQuality(candidate.hit) >= 5) {
      return _TapTargetEffect.ok(
        'render-pointer target hit changed app context; live stream owns final readiness',
      );
    }
    if (beforeElements.isNotEmpty && afterElements.isEmpty) {
      return _TapTargetEffect.ambiguous(
        'target disappeared without durable route/dialog/target state evidence; target=${_targetLabel(command.target)}',
      );
    }

    return _TapTargetEffect.ambiguous(
      'semantic action changed non-target app state; target=${_targetLabel(command.target)}; '
      'match=${match.description}; point=${_formatOffset(candidate.position)}; '
      'beforeTargetCount=${beforeElements.length}; afterTargetCount=${afterElements.length}',
    );
  }

  ActionResult? _expectedConditionTapDispatchedResult({
    required ActionCommand command,
    required _SemanticsMatch match,
    required _TapCandidate candidate,
    required String actuator,
    required String successMessage,
    required List<VerificationEvidence> evidence,
  }) {
    if (command.expected.isEmpty) return null;
    return ActionResult(
      ok: true,
      action: command,
      message: successMessage,
      evidence: <VerificationEvidence>[
        ...evidence,
        _tapAttemptEvidence(
          actuator: actuator,
          candidate: candidate,
          ok: true,
          detail:
              'dispatched tap once; caller supplied explicit expected conditions so bridge/live-stream verification owns final outcome; target=${match.description}',
        ),
        const VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'tap.expected_verification_delegated',
          ok: true,
          detail:
              'The tap command has explicit expected conditions. The SDK does not run expensive local target-effect proof after dispatch; the bridge verifies the expected route, UI, state, form, network, or storage condition from the live stream.',
        ),
      ],
    );
  }

  _TapTargetEffect? _closeControlTapEffect({
    required ActionCommand command,
    required _SemanticsMatch match,
    required AppSnapshot beforeSnapshot,
    required AppSnapshot afterSnapshot,
    required List<UiElement> beforeElements,
    required List<UiElement> afterElements,
  }) {
    final closeTexts = _closeControlTexts(command.target, match);
    if (closeTexts.isEmpty) return null;

    final beforeDialogTexts = _dialogVisibleTexts(beforeSnapshot);
    final afterDialogTexts = _dialogVisibleTexts(afterSnapshot);
    if (beforeSnapshot.dialogs.length > afterSnapshot.dialogs.length) {
      return _TapTargetEffect.ok(
        'close control reduced dialog stack ${beforeSnapshot.dialogs.length} -> ${afterSnapshot.dialogs.length}',
      );
    }
    if (beforeDialogTexts.isNotEmpty && afterDialogTexts.isEmpty) {
      return _TapTargetEffect.ok('close control dismissed visible dialog text');
    }
    if (beforeElements.isNotEmpty && afterElements.isEmpty) {
      return _TapTargetEffect.ok('close target disappeared');
    }

    final afterStillShowsClose =
        afterElements.isNotEmpty ||
        _visibleTextSet(
          afterSnapshot,
        ).any((text) => closeTexts.any((closeText) => text == closeText));
    if (afterStillShowsClose) {
      return _TapTargetEffect.ambiguous(
        'close control remained visible after tap; target=${_targetLabel(command.target)}; match=${match.description}',
      );
    }
    if (_closeControlTextsDisappeared(
      beforeSnapshot: beforeSnapshot,
      afterSnapshot: afterSnapshot,
      closeTexts: closeTexts,
    )) {
      return _TapTargetEffect.ok('close control text disappeared');
    }

    return _TapTargetEffect.ambiguous(
      'close control changed the app without durable close proof; target=${_targetLabel(command.target)}; match=${match.description}',
    );
  }

  Set<String> _closeControlTexts(ElementTarget? target, _SemanticsMatch match) {
    final texts =
        <String?>[
          target?.id,
          target?.label,
          target?.text,
          target?.selector,
          target?.listContext?.itemText,
          match.data.identifier,
          match.data.label,
          match.data.value,
          match.data.hint,
          match.description,
        ].map(_normalizedMatchText).where((value) => value.isNotEmpty).toSet();
    return texts.where(_isCloseControlText).toSet();
  }

  bool _isCloseControlText(String value) {
    final normalized = _normalizedMatchText(value);
    if (normalized.isEmpty) return false;
    const exact = <String>{
      'back',
      'cancel',
      'close',
      'dismiss',
      'done',
      'finish',
      'ok',
      'schließen',
      'schliessen',
      'abbrechen',
      'fertig',
    };
    if (exact.contains(normalized)) return true;
    return normalized.startsWith('close ') ||
        normalized.startsWith('dismiss ') ||
        normalized.startsWith('cancel ') ||
        normalized.startsWith('schließen ') ||
        normalized.startsWith('schliessen ');
  }

  bool _closeControlTextsDisappeared({
    required AppSnapshot beforeSnapshot,
    required AppSnapshot afterSnapshot,
    required Set<String> closeTexts,
  }) {
    if (closeTexts.isEmpty) return false;
    final beforeTexts = _visibleTextSet(beforeSnapshot);
    if (!beforeTexts.any(closeTexts.contains)) return false;
    final afterTexts = _visibleTextSet(afterSnapshot);
    return !afterTexts.any(closeTexts.contains);
  }

  bool _routeChanged(AppSnapshot before, AppSnapshot after) {
    return before.route.current.path != after.route.current.path ||
        before.route.current.name != after.route.current.name ||
        before.route.current.screenClass != after.route.current.screenClass;
  }

  List<UiElement> _snapshotElementsMatchingTarget(
    AppSnapshot snapshot,
    ElementTarget? target,
    _SemanticsMatch? match,
  ) {
    final targetId =
        _generatedFlutterSemanticsId(target?.id) ? null : target?.id;
    final matchIdentifier = match?.data.identifier.trim();
    final targetTexts =
        <String?>[
          targetId,
          target?.label,
          target?.text,
          target?.selector,
          target?.listContext?.itemText,
          matchIdentifier == null || matchIdentifier.isEmpty
              ? null
              : matchIdentifier,
          match?.data.label,
          match?.data.value,
        ].map(_normalizedMatchText).where((value) => value.isNotEmpty).toSet();
    if (targetTexts.isEmpty) return const <UiElement>[];
    return snapshot.ui.elements
        .where((element) {
          if (element.visible == false) return false;
          final fields = <Object?>[
                element.id,
                element.platformId,
                element.label,
                element.text,
                element.value,
                element.hint,
              ]
              .whereType<String>()
              .map(_normalizedMatchText)
              .where((value) => value.isNotEmpty)
              .toList(growable: false);
          return targetTexts.any(
            (needle) =>
                fields.any((field) => _targetTextMatchesField(needle, field)),
          );
        })
        .toList(growable: false);
  }

  bool _generatedFlutterSemanticsId(String? value) =>
      _normalizedMatchText(value).startsWith('flutter-semantics-');

  bool _targetElementsChanged(
    List<UiElement> beforeElements,
    List<UiElement> afterElements, {
    required _SemanticsMatch match,
  }) {
    if (beforeElements.isEmpty || afterElements.isEmpty) return false;
    final afterById = <String, UiElement>{
      for (final element in afterElements) element.id: element,
    };
    for (final before in beforeElements) {
      final after = afterById[before.id];
      if (after == null) continue;
      if (_uiElementDurableTargetSignature(before) !=
              _uiElementDurableTargetSignature(after) &&
          _uiElementChangeIsDurableTargetEffect(before, after, match)) {
        return true;
      }
    }
    return _targetPresentationMigrated(beforeElements, afterElements);
  }

  bool _uiElementChangeIsDurableTargetEffect(
    UiElement before,
    UiElement after,
    _SemanticsMatch match,
  ) {
    if (before.selected != after.selected || before.checked != after.checked) {
      return true;
    }
    if (_normalizedMatchText(before.value?.toString()) !=
        _normalizedMatchText(after.value?.toString())) {
      return true;
    }
    if (before.role == OperatorUiRole.input ||
        after.role == OperatorUiRole.input) {
      return true;
    }
    final beforeText = <String>[
      _normalizedMatchText(before.label),
      _normalizedMatchText(before.text),
      _normalizedMatchText(before.hint),
    ].join('|');
    final afterText = <String>[
      _normalizedMatchText(after.label),
      _normalizedMatchText(after.text),
      _normalizedMatchText(after.hint),
    ].join('|');
    if (beforeText != afterText) {
      return _smallControlBounds(match.bounds);
    }
    return false;
  }

  bool _targetPresentationMigrated(
    List<UiElement> beforeElements,
    List<UiElement> afterElements,
  ) {
    final beforeFields = <String, Set<String>>{};
    for (final before in beforeElements) {
      for (final text in _elementTargetTextFields(before)) {
        beforeFields
            .putIfAbsent(text, () => <String>{})
            .add(before.role?.name ?? '<unknown>');
      }
    }
    if (beforeFields.isEmpty) return false;
    for (final after in afterElements) {
      final afterRole = after.role?.name ?? '<unknown>';
      final afterLooksSelected =
          after.role == OperatorUiRole.input ||
          after.value != null ||
          after.selected == true ||
          after.checked == true;
      if (!afterLooksSelected) continue;
      for (final text in _elementTargetTextFields(after)) {
        final beforeRoles = beforeFields[text];
        if (beforeRoles != null && !beforeRoles.contains(afterRole)) {
          return true;
        }
      }
    }
    return false;
  }

  Set<String> _elementTargetTextFields(UiElement element) {
    return <Object?>[element.label, element.text, element.value, element.hint]
        .whereType<String>()
        .map(_normalizedMatchText)
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  _TapTargetEffect? _targetScopedVisibleTextEffect({
    required ActionCommand command,
    required _SemanticsMatch match,
    required AppSnapshot beforeSnapshot,
    required AppSnapshot afterSnapshot,
    required _TapCandidate candidate,
    required String actuator,
  }) {
    final beforeTexts = _visibleTextSet(beforeSnapshot);
    final afterTexts = _visibleTextSet(afterSnapshot);
    if (beforeTexts.length == afterTexts.length &&
        beforeTexts.containsAll(afterTexts)) {
      return null;
    }

    final role = _roleFor(match.data);
    final targetTexts =
        <String?>[
          command.target?.id,
          command.target?.label,
          command.target?.text,
          command.target?.selector,
          command.target?.listContext?.itemText,
          match.data.identifier,
          match.data.label,
          match.data.value,
          match.description,
        ].map(_normalizedMatchText).where((value) => value.isNotEmpty).toSet();
    if (role == OperatorUiRole.input) {
      return _TapTargetEffect.ok('target input changed surrounding visible UI');
    }

    if (_trustedSameControlSemanticTransfer(match, command.target)) {
      return _TapTargetEffect.ok(
        'same-control transferred action changed surrounding visible UI',
      );
    }

    if (_largeExactSemanticActionProxy(match, command.target)) {
      return _TapTargetEffect.ok(
        'large exact semantic proxy changed surrounding visible UI',
      );
    }

    if (_trustedLeafWidgetDispatch(candidate) &&
        afterTexts.difference(beforeTexts).isNotEmpty) {
      return _TapTargetEffect.ok(
        'trusted leaf widget dispatch changed surrounding visible UI',
      );
    }

    final leafActionControl =
        _smallControlBounds(match.bounds) &&
        (role == OperatorUiRole.button ||
            role == OperatorUiRole.link ||
            role == OperatorUiRole.checkbox ||
            role == OperatorUiRole.radio ||
            role == OperatorUiRole.switchRole);
    if (leafActionControl) {
      if (targetTexts.isNotEmpty) {
        final newlyVisibleTexts = afterTexts.difference(beforeTexts);
        final mentionsTarget = targetTexts.any(
          (needle) => newlyVisibleTexts.any(
            (text) =>
                text == needle ||
                text.contains(needle) ||
                _looksLikeUpdatedTargetText(needle, text),
          ),
        );
        if (mentionsTarget) {
          return _TapTargetEffect.ok(
            'small target control produced target-scoped visible UI text',
          );
        }
      }
    }

    if (actuator == 'pointer' && _hitTestQuality(candidate.hit) >= 5) {
      return _TapTargetEffect.ok(
        'render-pointer target hit changed visible UI; live stream owns final readiness',
      );
    }

    return null;
  }

  _TapTargetEffect? _generatedIdLeafTargetEffect({
    required ActionCommand command,
    required _SemanticsMatch match,
    required AppSnapshot beforeSnapshot,
    required AppSnapshot afterSnapshot,
  }) {
    final targetId = _normalizedMatchText(command.target?.id);
    if (!_generatedFlutterSemanticsId(targetId)) return null;
    if (!_leafActionControl(match)) return null;
    final before = _visibleElementById(beforeSnapshot, targetId);
    if (before == null) return null;
    final after =
        _visibleElementById(afterSnapshot, targetId) ??
        _visibleLeafElementWithStableTextAndGeometry(
          afterSnapshot,
          before,
          match,
        );
    if (after == null) return null;
    final beforeText = _normalizedMatchText(_elementDisplayText(before));
    final afterText = _normalizedMatchText(_elementDisplayText(after));
    if (beforeText.isEmpty || afterText.isEmpty || beforeText == afterText) {
      return null;
    }
    if (!_sharesStableNonNumericTokens(beforeText, afterText)) return null;
    return _TapTargetEffect.ok(
      'generated-id leaf control updated visible label with stable target tokens',
    );
  }

  UiElement? _visibleElementById(AppSnapshot snapshot, String id) {
    return snapshot.ui.elements
        .where(
          (element) =>
              element.visible != false &&
              _normalizedMatchText(element.id) == id,
        )
        .firstOrNull;
  }

  UiElement? _visibleLeafElementWithStableTextAndGeometry(
    AppSnapshot snapshot,
    UiElement before,
    _SemanticsMatch match,
  ) {
    final beforeText = _normalizedMatchText(_elementDisplayText(before));
    if (beforeText.isEmpty) return null;
    final beforeBounds = _rectFromElementBounds(before.bounds) ?? match.bounds;
    return snapshot.ui.elements.where((element) {
      if (element.visible == false) return false;
      if (element.role != before.role) return false;
      final afterBounds = _rectFromElementBounds(element.bounds);
      if (afterBounds == null || !_leafControlBounds(afterBounds)) {
        return false;
      }
      if (!_sameControlGeometry(beforeBounds, afterBounds)) return false;
      final afterText = _normalizedMatchText(_elementDisplayText(element));
      return afterText.isNotEmpty &&
          beforeText != afterText &&
          _sharesStableNonNumericTokens(beforeText, afterText);
    }).firstOrNull;
  }

  Rect? _rectFromElementBounds(ElementBounds? bounds) {
    if (bounds == null) return null;
    return Rect.fromLTWH(bounds.x, bounds.y, bounds.width, bounds.height);
  }

  bool _leafActionControl(_SemanticsMatch match) {
    final role = _roleFor(match.data);
    final leafRole =
        role == OperatorUiRole.button ||
        role == OperatorUiRole.link ||
        role == OperatorUiRole.checkbox ||
        role == OperatorUiRole.radio ||
        role == OperatorUiRole.switchRole;
    return leafRole && _leafControlBounds(match.bounds);
  }

  bool _trustedLeafWidgetDispatch(_TapCandidate candidate) {
    final bounds = candidate.dispatchBounds;
    if (bounds == null || !_leafControlBounds(bounds)) return false;
    if (!_widgetDispatchReasonLooksInteractive(candidate.reason)) return false;
    return _hitTestQuality(candidate.hit) >= 5;
  }

  bool _widgetDispatchReasonLooksInteractive(String reason) {
    if (!reason.startsWith('widget.')) return false;
    return reason.contains('Button') ||
        reason.contains('InkWell') ||
        reason.contains('GestureDetector') ||
        reason.contains('CupertinoButton') ||
        reason.contains('ListTile');
  }

  bool _sharesStableNonNumericTokens(String before, String after) {
    final beforeTokens = _stableTextTokens(before);
    if (beforeTokens.isEmpty) return false;
    final afterTokens = _stableTextTokens(after);
    return beforeTokens.any(afterTokens.contains);
  }

  bool _looksLikeUpdatedTargetText(String before, String after) {
    final beforeTokens = _stableTextTokens(before);
    if (beforeTokens.length < 2) return false;
    final afterTokens = _stableTextTokens(after);
    return afterTokens.containsAll(beforeTokens);
  }

  Set<String> _stableTextTokens(String value) {
    return value
        .split(RegExp(r'[^a-z0-9]+'))
        .where((token) => token.length >= 2 && int.tryParse(token) == null)
        .toSet();
  }

  Set<String> _visibleTextSet(AppSnapshot snapshot) {
    return snapshot.ui.elements
        .where((element) => element.visible != false)
        .map(_elementDisplayText)
        .whereType<String>()
        .map(_normalizedMatchText)
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  String _uiElementDurableTargetSignature(UiElement element) {
    return jsonEncode(<String, Object?>{
      'role': element.role?.name,
      'label': _normalizedMatchText(element.label),
      'text': _normalizedMatchText(element.text),
      'value': _normalizedMatchText(element.value?.toString()),
      'hint': _normalizedMatchText(element.hint),
      'selected': element.selected,
      'checked': element.checked,
    });
  }

  ActionResult? _tapTargetNotActionableResult(ActionCommand command) {
    final target = command.target;
    if (target == null) return null;
    final match = _resolve(target);
    if (match == null) return null;
    final enabled = match.data.flagsCollection.isEnabled.toBoolOrNull() ?? true;
    final hidden = match.data.flagsCollection.isHidden;
    final hasTap = match.data.hasAction(SemanticsAction.tap);
    final inViewport =
        match.bounds.isFinite &&
        !match.bounds.isEmpty &&
        _pointInViewport(match.bounds.center);
    final reasons = <String>[
      if (!enabled) 'disabled',
      if (hidden) 'hidden',
      if (!hasTap) 'no tap action',
      if (!inViewport) 'outside viewport',
    ];
    if (reasons.isEmpty) return null;
    final detail =
        'matched=${match.description}; id=${_uiElementId(match)}; '
        'role=${_roleFor(match.data).name}; '
        'bounds=${_formatRect(match.bounds)}; '
        'reasons=${reasons.join(', ')}';
    return ActionResult(
      ok: false,
      action: command,
      data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
      error: ActionError(
        type: 'target_not_actionable',
        message:
            'Flutter element matched ${_targetLabel(target)}, but it cannot be tapped: ${reasons.join(', ')}',
        retryable: true,
      ),
      evidence: <VerificationEvidence>[
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'tap.target_not_actionable',
          ok: false,
          detail: detail,
        ),
      ],
    );
  }

  Future<ActionResult?> _setText(
    ActionCommand command, {
    bool clear = false,
  }) async {
    final text = clear ? '' : command.text ?? '';
    final clearFirst = clear || command.clearFirst != false;
    final requiredAction = clear ? 'clear' : 'type';
    final runtimeControl = _runtimeControlForTarget(
      command.target,
      requiredAction: requiredAction,
    );
    if (runtimeControl != null) {
      final controller = runtimeControl.textController;
      if (controller == null ||
          !runtimeControl.enabled ||
          runtimeControl.readOnly ||
          !runtimeControl.actions.contains(requiredAction)) {
        return ActionResult(
          ok: false,
          action: command,
          data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
          error: ActionError(
            type: 'target_not_actionable',
            message:
                'Flutter element matched ${_targetLabel(command.target)}, but it is not an editable input',
            retryable: true,
          ),
        );
      }
      final before = controller.value;
      final nextValue = _typedEditingValue(
        before,
        text,
        clearFirst: clearFirst,
      );
      controller.value = nextValue;
      runtimeControl.focusNode?.requestFocus();
      runtimeControl.onTextChanged?.call(nextValue.text);
      await _settleAfterUserAction();
      final live =
          runtimeControl.element.mounted
              ? _runtimeControlForElement(runtimeControl.element)
              : null;
      if (live == null || !identical(live.textController, controller)) {
        return ActionResult(
          ok: false,
          action: command,
          data: const {'operationPhase': 'dispatched_unknown_effect'},
          error: const ActionError(
            type: 'text_control_replaced',
            message:
                'Text was dispatched, but the input was replaced before its resulting value could be read',
          ),
        );
      }
      final after = controller.value;
      final changed = before.text != after.text;
      return ActionResult(
        ok: true,
        action: command,
        message:
            'Text input delivered to ${runtimeControl.id}; ${changed ? 'the value changed' : 'the value did not change'}${after.text == nextValue.text ? ' and matches the requested edit' : ' and differs from the requested edit'}.',
        data: {
          'operationPhase': 'settled',
          'typing': {
            'ownerId': runtimeControl.id,
            'clearFirst': clearFirst,
            'changed': changed,
            'matchesRequested': after.text == nextValue.text,
            'secure': runtimeControl.secure,
            if (!runtimeControl.secure) 'before': before.text,
            if (!runtimeControl.secure) 'after': after.text,
          },
        },
      );
    }
    final match =
        _resolve(command.target, preferredAction: SemanticsAction.setText) ??
        _resolve(command.target);

    final owner = _semanticsOwner;
    if (_setTextViaFlutterWidgetTree(
      command.target,
      match,
      text,
      clearFirst: clearFirst,
    )) {
      // The widget-tree path drives the same TextEditingController/onChanged
      // callback a user-written TextField uses, and avoids semantics setText
      // stalls seen in widget-test and embedded runtime environments.
    } else if (owner != null &&
        match != null &&
        match.data.hasAction(SemanticsAction.setText)) {
      if (!clearFirst && match.data.flagsCollection.isObscured) {
        return ActionResult(
          ok: false,
          action: command,
          data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
          error: const ActionError(
            type: 'text_editing_value_unavailable',
            message:
                'Insertion requires the live text value; masked Flutter semantics cannot supply it. Use the exact controller-backed input.',
            retryable: true,
          ),
        );
      }
      final nextValue = _typedEditingValue(
        TextEditingValue(
          text: match.data.value,
          selection:
              match.data.textSelection ??
              const TextSelection.collapsed(offset: -1),
        ),
        text,
        clearFirst: clearFirst,
      );
      owner.performAction(
        match.node.id,
        SemanticsAction.setText,
        nextValue.text,
      );
      if (!clearFirst && match.data.hasAction(SemanticsAction.setSelection)) {
        owner.performAction(match.node.id, SemanticsAction.setSelection, {
          'base': nextValue.selection.baseOffset,
          'extent': nextValue.selection.extentOffset,
        });
      }
    } else if (command.target != null) {
      return ActionResult(
        ok: false,
        action: command,
        data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
        error: ActionError(
          type: 'target_not_found',
          message:
              'No editable Flutter element matched ${_targetLabel(command.target)}',
          retryable: true,
        ),
      );
    } else {
      return null;
    }
    await _settleAfterUserAction();
    return ActionResult(
      ok: true,
      action: command,
      message:
          clear
              ? 'Cleared ${match?.description ?? command.target?.label ?? 'input'}'
              : 'Typed into ${match?.description ?? command.target?.label ?? 'input'}',
    );
  }

  Future<ActionResult?> _hover(ActionCommand command) async {
    final control = _runtimeControlForTarget(
      command.target,
      requiredAction: 'hover',
    );
    final bounds = control?.bounds;
    if (control == null || bounds == null || !control.visible) {
      return command.target?.observationTargetRef == null
          ? null
          : _reobservationRequired(command);
    }
    _dispatchPointerHover(bounds.center);
    await _settleAfterUserAction();
    return ActionResult(
      ok: true,
      action: command,
      message: 'Hovered exact Flutter target ${control.id}',
      evidence: <VerificationEvidence>[
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'flutter_input.exact_hover_dispatched',
          ok: true,
          detail: 'target=${control.id}; point=${_formatOffset(bounds.center)}',
        ),
      ],
    );
  }

  Future<ActionResult?> _drag(ActionCommand command) async {
    if (command.mode == 'html5') {
      return ActionResult(
        ok: false,
        action: command,
        data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
        error: const ActionError(
          type: 'unsupported_action',
          message:
              'Flutter controls use pointer drag; HTML5 drag data is a DOM-only mechanism',
        ),
      );
    }
    final source = _runtimeControlForTarget(
      command.source,
      requiredAction: 'drag',
    );
    final destination = _runtimeControlForTarget(command.destination);
    final sourceBounds = source?.bounds;
    final destinationBounds = destination?.bounds;
    if (source == null ||
        destination == null ||
        sourceBounds == null ||
        destinationBounds == null ||
        !source.visible ||
        !destination.visible) {
      return _reobservationRequired(command);
    }
    _dispatchPointerGesture(
      start: sourceBounds.center,
      end: destinationBounds.center,
      kind: ui.PointerDeviceKind.mouse,
      duration: command.duration ?? const Duration(milliseconds: 360),
    );
    await _settleAfterUserAction();
    return ActionResult(
      ok: true,
      action: command,
      message: 'Dragged exact Flutter target ${source.id} to ${destination.id}',
      evidence: <VerificationEvidence>[
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'flutter_input.exact_pointer_drag_dispatched',
          ok: true,
          detail:
              'source=${source.id}; destination=${destination.id}; mode=${command.mode ?? 'auto'}',
        ),
      ],
    );
  }

  /// Presses exactly at one logical view point, like a finger, whatever is there. Nothing is
  /// resolved or claimed first, so a control the runtime cannot classify is still pressable; the
  /// receipt names what was under the point at the moment of the press: the labelled element, or
  /// else the control the runtime recognises there.
  Future<ActionResult> _tapPoint(ActionCommand command) async {
    final point = command.target?.point;
    final viewport = _viewportSize();
    if (point == null ||
        viewport == null ||
        !point.x.isFinite ||
        !point.y.isFinite ||
        point.x < 0 ||
        point.y < 0 ||
        point.x >= viewport.width ||
        point.y >= viewport.height) {
      return ActionResult(
        ok: false,
        action: command,
        data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
        error: const ActionError(
          type: 'point_outside_view',
          message:
              'No tap was sent: the point is outside the current Flutter view.',
          retryable: false,
        ),
      );
    }
    final position = Offset(point.x, point.y);
    final pressed =
        _labelledSemanticsAt(position) ?? _controlUnderPointer(position);
    final presses = command.count ?? 1;
    final interval = command.interval ?? _defaultPressInterval;
    for (var press = 0; press < presses; press += 1) {
      if (press > 0) await Future<void>.delayed(interval);
      _dispatchPointerTap(position, kind: ui.PointerDeviceKind.touch);
    }
    await _settleAfterUserAction();
    final on = _pressedOn(pressed);
    final times =
        presses == 1
            ? ''
            : ' $presses times in a row, with a ${interval.inMilliseconds} ms wait between presses';
    return ActionResult(
      ok: true,
      action: command,
      // "; no labelled element was under it" closes the sentence, after the presses.
      message:
          pressed == null
              ? 'Pressed the exact point (${point.x}, ${point.y})$times$on.'
              : 'Pressed the exact point (${point.x}, ${point.y})$on$times.',
      data: <String, Object?>{
        'operationPhase': 'settled',
        'dispatch': 'in_app_pointer',
        'point': <String, Object?>{'x': point.x, 'y': point.y},
        'underPointer': pressed,
        if (presses > 1)
          'presses': <String, Object?>{
            'count': presses,
            'intervalMs': interval.inMilliseconds,
          },
      },
    );
  }

  /// The control the finder sees under [position] when no accessibility label names one, such as
  /// an unlabelled icon button. Read before the press; issues no target.
  JsonMap? _controlUnderPointer(Offset position) {
    final _FlutterRuntimeControlBinding? control;
    try {
      control = _controlAt(position);
    } catch (_) {
      return null;
    }
    final bounds = control?.bounds;
    if (control == null || bounds == null) return null;
    // An icon font draws a private-use character, which names nothing a reader can see.
    final label =
        (control.label ?? '').replaceAll(RegExp(r'[\uE000-\uF8FF]'), '').trim();
    return <String, Object?>{
      if (label.isNotEmpty)
        'label': label.length > 120 ? '${label.substring(0, 120)}…' : label,
      'role': _scrollToRoleName(control.role),
      if (!control.enabled) 'enabled': false,
      'bounds': <String, Object?>{
        'x': bounds.left,
        'y': bounds.top,
        'width': bounds.width,
        'height': bounds.height,
      },
    };
  }

  static String _pressedOn(JsonMap? pressed) {
    if (pressed == null) return '; no labelled element was under it';
    final role = pressed['role'];
    final label = pressed['label'];
    if (role is! String) return ' on "$label"';
    final state = pressed['enabled'] == false ? 'disabled ' : '';
    final noun = role == OperatorUiRole.unknown.name ? 'control' : role;
    return label is String
        ? ' on the $state$noun "$label"'
        : ' on an unlabelled $state$noun';
  }

  /// The labelled accessibility node a finger at [position] lands on, just before the press.
  ///
  /// Semantics children are kept in paint order, so the last child is on top. The walk descends
  /// through the frontmost visible child containing the point, the way a finger is hit-tested,
  /// and keeps the deepest labelled node on that path: a dropdown row wins over the label under it.
  JsonMap? _labelledSemanticsAt(Offset position) {
    final nodes = _nodes();
    if (nodes.isEmpty) return null;
    _SemanticsMatch? best;
    _SemanticsMatch? current = nodes.first;
    while (current != null) {
      if (current.data.label.trim().isNotEmpty) best = current;
      _SemanticsMatch? next;
      for (final child in current.children.reversed) {
        if (child.data.flagsCollection.isHidden) continue;
        if (child.bounds.contains(position)) {
          next = child;
          break;
        }
      }
      current = next;
    }
    if (best == null) return null;
    final label = best.data.label.trim();
    final bounds = best.bounds;
    return <String, Object?>{
      'label': label.length > 120 ? '${label.substring(0, 120)}…' : label,
      'button': best.data.flagsCollection.isButton,
      'bounds': <String, Object?>{
        'x': bounds.left,
        'y': bounds.top,
        'width': bounds.width,
        'height': bounds.height,
      },
    };
  }

  Future<ActionResult?> _touch(ActionCommand command) async {
    final gesture = command.gesture;
    if (gesture == 'tap') {
      final control = _runtimeControlForTarget(
        command.target,
        requiredAction: 'touch',
      );
      final bounds = control?.bounds;
      if (control == null || bounds == null || !control.visible) {
        return _reobservationRequired(command);
      }
      _dispatchPointerTap(bounds.center, kind: ui.PointerDeviceKind.touch);
      await _settleAfterUserAction();
      return ActionResult(
        ok: true,
        action: command,
        message: 'Touch-tapped exact Flutter target ${control.id}',
      );
    }
    if (gesture != 'swipe') return null;

    final control = _runtimeControlForTarget(
      command.start,
      requiredAction: 'touch',
    );
    final start = control?.bounds?.center ?? _primaryViewportCenter();
    if (command.start != null && (control == null || !control.visible)) {
      return _reobservationRequired(command);
    }
    final direction = command.direction?.toLowerCase();
    final distance = math.max(1.0, command.distancePx ?? 240.0);
    final delta = switch (direction) {
      'up' => Offset(0, -distance),
      'down' => Offset(0, distance),
      'left' => Offset(-distance, 0),
      'right' => Offset(distance, 0),
      _ => null,
    };
    if (delta == null) {
      return ActionResult(
        ok: false,
        action: command,
        data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
        error: const ActionError(
          type: 'unsupported_action',
          message: 'Touch swipe direction must be up, down, left, or right',
        ),
      );
    }
    _dispatchPointerGesture(
      start: start,
      end: start + delta,
      kind: ui.PointerDeviceKind.touch,
      duration: command.duration ?? const Duration(milliseconds: 320),
    );
    await _settleAfterUserAction();
    return ActionResult(
      ok: true,
      action: command,
      message:
          'Swiped ${direction ?? 'content'} from ${control?.id ?? 'the Flutter viewport'}',
      evidence: <VerificationEvidence>[
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'flutter_input.touch_swipe_dispatched',
          ok: true,
          detail:
              'start=${_formatOffset(start)}; end=${_formatOffset(start + delta)}',
        ),
      ],
    );
  }

  Future<ActionResult?> _scroll(ActionCommand command) async {
    final target = command.container ?? command.target;
    final direction = command.direction?.toLowerCase();
    final runtimeControl = _runtimeControlForTarget(
      target,
      requiredAction: 'scroll',
    );
    final runtimePosition = runtimeControl?.scrollOwner;
    if (runtimePosition == null &&
        (target?.point != null ||
            target?.observationTargetRef != null ||
            target?.id?.startsWith('flutter-runtime-') == true)) {
      return ActionResult(
        ok: false,
        action: command,
        data: const {'operationPhase': 'zero_dispatch'},
        error: const ActionError(
          type: 'scroll_owner_unavailable',
          message:
              'No scroll sent: the exact selected scroll owner is unavailable; no other container was used',
        ),
      );
    }
    if (runtimeControl != null && runtimePosition != null) {
      final vertical = direction == 'up' || direction == 'down';
      if (!['up', 'down', 'left', 'right'].contains(direction) ||
          runtimePosition.axis !=
              (vertical ? Axis.vertical : Axis.horizontal)) {
        return ActionResult(
          ok: false,
          action: command,
          data: const {'operationPhase': 'zero_dispatch'},
          error: const ActionError(
            type: 'scroll_axis_mismatch',
            message: 'The selected container cannot scroll in that axis',
          ),
        );
      }
      final point = target?.point;
      if (point != null) {
        final live = inspectPoint(point.x, point.y, scrollDirection: direction);
        final hitControl = live['control'];
        if (live['status'] != 'found' ||
            hitControl is! Map ||
            hitControl['id'] != runtimeControl.id) {
          return ActionResult(
            ok: false,
            action: command,
            data: const {'operationPhase': 'zero_dispatch'},
            error: const ActionError(
              type: 'scroll_owner_changed',
              message:
                  'No scroll sent: the frontmost container at the requested point changed',
            ),
          );
        }
      }
      if (!runtimePosition.hasContentDimensions || !runtimePosition.hasPixels) {
        return ActionResult(
          ok: false,
          action: command,
          data: const {'operationPhase': 'zero_dispatch'},
          error: const ActionError(
            type: 'scroll_owner_unavailable',
            message:
                'The selected Flutter scroll owner has no current dimensions',
            retryable: true,
          ),
        );
      }
      final delta = _scrollAmount(command, runtimePosition);
      if (!delta.isFinite || delta < 0) {
        return ActionResult(
          ok: false,
          action: command,
          data: const {'operationPhase': 'zero_dispatch'},
          error: const ActionError(
            type: 'invalid_scroll_amount',
            message: 'Scroll amount must be finite and non-negative',
          ),
        );
      }
      final current = runtimePosition.pixels;
      final reversed =
          runtimePosition.axisDirection == AxisDirection.up ||
          runtimePosition.axisDirection == AxisDirection.left;
      final sign =
          ((direction == 'down' || direction == 'right') ? 1 : -1) *
          (reversed ? -1 : 1);
      final requested = current + sign * delta;
      final minimum = runtimePosition.minScrollExtent;
      final maximum = runtimePosition.maxScrollExtent;
      final next = math.min(
        runtimePosition.maxScrollExtent,
        math.max(runtimePosition.minScrollExtent, requested),
      );
      if (next != current) runtimePosition.jumpTo(next);
      await _settleAfterUserAction();
      final live =
          runtimeControl.element.mounted
              ? _runtimeControlForElement(runtimeControl.element)
              : null;
      if (live == null ||
          !identical(live.scrollOwner, runtimePosition) ||
          !runtimePosition.hasPixels) {
        return ActionResult(
          ok: false,
          action: command,
          data: {
            'operationPhase': 'dispatched_unknown_effect',
            'scroll': {'ownerId': runtimeControl.id, 'before': current},
          },
          error: const ActionError(
            type: 'scroll_owner_changed',
            message:
                'The selected container was replaced before its final offset could be read',
          ),
        );
      }
      final after = runtimePosition.pixels;
      final moved = after - current;
      final boundaryBefore = sign > 0 ? current >= maximum : current <= minimum;
      final outcome =
          moved == 0
              ? (boundaryBefore ? 'boundary' : 'no_progress')
              : moved * sign > 0
              ? 'moved'
              : 'wrong_direction';
      return ActionResult(
        ok: outcome != 'wrong_direction',
        action: command,
        message:
            outcome == 'moved'
                ? 'Scrolled the selected list $direction ${moved.abs()} pixels (offset $current -> $after).'
                : outcome == 'boundary'
                ? 'The selected list was already at the $direction boundary; nothing moved (offset $after).'
                : outcome == 'no_progress'
                ? 'The selected list did not move (offset $after); it was not at the requested boundary.'
                : 'The selected list moved opposite to the requested direction (offset $current -> $after).',
        data: {
          'operationPhase': 'settled',
          'scroll': {
            'ownerId': runtimeControl.id,
            'label': runtimeControl.label,
            'axis': runtimePosition.axis.name,
            'direction': direction,
            'before': current,
            'after': after,
            'delta': moved,
            'requestedDelta': sign * delta,
            'min': runtimePosition.minScrollExtent,
            'max': runtimePosition.maxScrollExtent,
            'outcome': outcome,
          },
        },
        error:
            outcome == 'wrong_direction'
                ? const ActionError(
                  type: 'scroll_wrong_direction',
                  message:
                      'Observed movement contradicted the requested direction',
                )
                : null,
      );
    }
    final action = switch (direction) {
      'up' => SemanticsAction.scrollUp,
      'down' => SemanticsAction.scrollDown,
      'left' => SemanticsAction.scrollLeft,
      'right' => SemanticsAction.scrollRight,
      _ => null,
    };
    if (action == null) return null;

    final match =
        _resolve(target, preferredAction: action) ??
        (target == null
            ? _nodes().where((node) => node.data.hasAction(action)).firstOrNull
            : null);
    if (match == null) {
      if (target != null)
        return ActionResult(
          ok: false,
          action: command,
          data: const {'operationPhase': 'zero_dispatch'},
          error: const ActionError(
            type: 'scroll_owner_not_found',
            message:
                'The requested scroll owner was not found; no other container was used',
          ),
        );
      return _scrollViaFlutterWidgetTree(command, direction);
    }

    final before = match.data.scrollPosition;
    _semanticsOwner?.performAction(match.node.id, action);
    await _settleAfterUserAction();
    final after =
        _nodes()
            .where((node) => node.node.id == match.node.id)
            .firstOrNull
            ?.data
            .scrollPosition;
    return ActionResult(
      ok: true,
      action: command,
      message:
          before != null && after != null
              ? 'Scroll input delivered to ${_uiElementId(match)}; observed offset $before -> $after.'
              : 'Scroll input delivered to ${_uiElementId(match)}; this semantics control does not expose measurable movement.',
      data: {
        'operationPhase': 'settled',
        'scroll': {
          'ownerId': _uiElementId(match),
          'direction': direction,
          'before': before,
          'after': after,
          'outcome':
              before == null || after == null
                  ? 'unmeasured'
                  : before == after
                  ? 'no_progress'
                  : 'moved',
          if (before != null && after != null) 'delta': after - before,
        },
      },
    );
  }

  Future<ActionResult?> _scrollIntoView(ActionCommand command) async {
    final control = _runtimeControlForTarget(
      command.target,
      requiredAction: 'scrollIntoView',
    );
    if (control == null) {
      if (command.target?.observationTargetRef != null) {
        return _reobservationRequired(command);
      }
      return null;
    }
    final renderObject = control.element.findRenderObject();
    if (!control.rendered || renderObject == null || !renderObject.attached) {
      return _reobservationRequired(command);
    }

    final alignment = command.alignment ?? 'nearest';
    switch (alignment) {
      case 'nearest':
        await _ensureVisible(
          control.element,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
        await _ensureVisible(
          control.element,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      case 'start':
        await _ensureVisible(control.element, alignment: 0);
      case 'center':
        await _ensureVisible(control.element, alignment: 0.5);
      case 'end':
        await _ensureVisible(control.element, alignment: 1);
      default:
        return ActionResult(
          ok: false,
          action: command,
          data: const <String, Object?>{'operationPhase': 'zero_dispatch'},
          error: ActionError(
            type: 'unsupported_action',
            message: 'Unsupported scroll_into_view alignment: $alignment',
          ),
        );
    }

    await _settleAfterUserAction();
    final current = _runtimeControlForTarget(
      command.target,
      requiredAction: 'scrollIntoView',
    );
    // The view has already scrolled: a target gone after that is no refusal.
    if (current == null) {
      return _reobservationRequired(
        command,
        operationPhase: 'dispatched_unknown_effect',
      );
    }
    if (!current.inViewport) {
      return ActionResult(
        ok: false,
        action: command,
        error: const ActionError(
          type: 'action_effect_unverified',
          message:
              'Flutter completed scroll_into_view, but the exact target is still outside the viewport',
          retryable: true,
        ),
      );
    }
    return ActionResult(
      ok: true,
      action: command,
      message: 'Revealed exact Flutter target ${current.id}',
    );
  }

  /// Finds a control by visible text inside one scroll container, stepping the
  /// container one viewport at a time until the control is built, then reveals
  /// it with the same checks as scroll_into_view. Lazily built rows do not exist
  /// until scrolled near, so a search of the current tree alone cannot find
  /// them. Two matches are returned and neither is revealed.
  Future<ActionResult?> _scrollTo(ActionCommand command) async {
    final needle = _clean(command.text ?? '').toLowerCase();
    final direction = (command.direction ?? 'down').trim().toLowerCase();
    final maxSteps = command.maxSteps ?? 20;
    final role = command.role?.trim().toLowerCase();
    ActionResult refuse(String type, String message, {bool? retryable}) =>
        ActionResult(
          ok: false,
          action: command,
          data: const {'operationPhase': 'zero_dispatch'},
          error: ActionError(
            type: type,
            message: message,
            retryable: retryable,
          ),
        );
    if (needle.isEmpty) {
      return refuse(
        'invalid_scroll_to_text',
        'scroll_to requires non-empty text to find',
      );
    }
    if (!const ['up', 'down', 'left', 'right'].contains(direction)) {
      return refuse(
        'invalid_scroll_direction',
        'scroll_to direction must be up, down, left or right',
      );
    }
    if (maxSteps < 1 || maxSteps > 50) {
      return refuse(
        'invalid_scroll_to_steps',
        'scroll_to maxSteps must be between 1 and 50',
      );
    }
    if (role != null &&
        role.isNotEmpty &&
        !OperatorUiRole.values.any(
          (value) => _scrollToRoleName(value) == role,
        )) {
      return refuse('invalid_scroll_to_role', 'Unknown scroll_to role: $role');
    }

    final vertical = direction == 'up' || direction == 'down';
    final axis = vertical ? Axis.vertical : Axis.horizontal;
    final Element ownerElement;
    final ScrollPosition position;
    final String ownerId;
    final String? ownerLabel;
    final String ownerName;
    final container = command.container;
    if (container != null) {
      final control = _runtimeControlForTarget(
        container,
        requiredAction: 'scroll',
      );
      final owner = control?.scrollOwner;
      if (control == null || owner == null) {
        if (container.observationTargetRef != null) {
          return _reobservationRequired(command);
        }
        return refuse(
          'scroll_owner_unavailable',
          'No scroll sent: the selected container is unavailable; no other container was used',
        );
      }
      final point = container.point;
      if (point != null) {
        final live = inspectPoint(point.x, point.y, scrollDirection: direction);
        final hitControl = live['control'];
        if (live['status'] != 'found' ||
            hitControl is! Map ||
            hitControl['id'] != control.id) {
          return refuse(
            'scroll_owner_changed',
            'No scroll sent: the frontmost container at the requested point changed',
          );
        }
      }
      if (owner.axis != axis) {
        return refuse(
          'scroll_axis_mismatch',
          'The selected container cannot scroll in that axis',
        );
      }
      ownerElement = control.element;
      position = owner;
      ownerId = control.id;
      ownerLabel = control.label;
      ownerName = _scrollContainerName(control);
    } else {
      // Without a named container only an unambiguous one is searched: with more than one on
      // screen (a pop-up list over a page, a list inside a page) a "not found" could come from the
      // wrong one, so nothing is scrolled and the candidates are named instead.
      final onScreen = _onScreenScrollOwners(axis);
      if (onScreen.isEmpty) {
        return refuse(
          'scroll_owner_unavailable',
          'No scrollable container is on screen on that axis; select a container from the rendered-control list',
        );
      }
      if (onScreen.length > 1) {
        return ActionResult(
          ok: false,
          action: command,
          data: <String, Object?>{
            'operationPhase': 'zero_dispatch',
            'scrollTo': <String, Object?>{
              'found': false,
              'containers': <JsonMap>[
                for (final control in onScreen) _scrollContainerFacts(control),
              ],
            },
          },
          error: ActionError(
            type: 'scroll_container_required',
            message:
                'No scroll sent: ${onScreen.length} scrollable containers are on screen '
                '(${onScreen.map(_scrollContainerName).join('; ')}); name the one to search '
                'in container: the target listed for it in data.scrollTo.containers, or a '
                'point inside it',
            retryable: false,
          ),
        );
      }
      final only = onScreen.single;
      ownerElement = only.element;
      position = only.scrollOwner!;
      ownerId = only.id;
      ownerLabel = only.label;
      ownerName = _scrollContainerName(only);
    }
    if (!position.hasContentDimensions || !position.hasPixels) {
      return refuse(
        'scroll_owner_unavailable',
        'The selected Flutter scroll owner has no current dimensions',
        retryable: true,
      );
    }

    final reversed =
        position.axisDirection == AxisDirection.up ||
        position.axisDirection == AxisDirection.left;
    final sign =
        ((direction == 'down' || direction == 'right') ? 1 : -1) *
        (reversed ? -1 : 1);
    var steps = 0;
    var reachedEnd = false;
    JsonMap facts() => <String, Object?>{
      'ownerId': ownerId,
      if (ownerLabel != null) 'label': ownerLabel,
      'owner': ownerName,
      'axis': position.axis.name,
      'direction': direction,
      'text': command.text,
      if (role != null && role.isNotEmpty) 'role': role,
      'steps': steps,
      'reachedEnd': reachedEnd,
      'offset': position.hasPixels ? position.pixels : null,
    };
    bool ownerIsLive() =>
        ownerElement.mounted &&
        ownerElement is StatefulElement &&
        ownerElement.state is ScrollableState &&
        identical((ownerElement.state as ScrollableState).position, position) &&
        position.hasPixels;

    while (true) {
      final matches = _scrollToMatches(ownerElement, needle, role);
      if (matches.length > 1) {
        return ActionResult(
          ok: false,
          action: command,
          data: {
            'operationPhase': 'settled',
            'scrollTo': {
              ...facts(),
              'found': false,
              'ambiguous': true,
              'matches': [for (final match in matches.take(5)) match.toJson()],
            },
          },
          error: ActionError(
            type: 'scroll_to_ambiguous',
            message:
                '${matches.length} controls match "${command.text}"; nothing was revealed. Narrow the text or role, or select one from the next observation.',
            retryable: false,
          ),
        );
      }
      if (matches.length == 1) {
        final match = matches.single;
        await _ensureVisible(
          match.element,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
        await _ensureVisible(
          match.element,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
        await _settleAfterUserAction();
        final live =
            match.element.mounted ? _scrollToCandidate(match.element) : null;
        if (live == null) {
          return ActionResult(
            ok: false,
            action: command,
            data: {
              'operationPhase': 'dispatched_unknown_effect',
              'scrollTo': {...facts(), 'found': true, 'revealed': false},
            },
            error: ActionError(
              type: 'scroll_to_target_changed',
              message:
                  'Found "${command.text}" but it was rebuilt or removed before it could be revealed',
              retryable: true,
            ),
          );
        }
        if (!live.inViewport) {
          return ActionResult(
            ok: false,
            action: command,
            data: {
              'operationPhase': 'settled',
              'scrollTo': {
                ...facts(),
                'found': true,
                'revealed': false,
                'control': live.toJson(),
              },
            },
            error: ActionError(
              type: 'action_effect_unverified',
              message:
                  'Found "${command.text}" after $steps step(s), but it is still outside the viewport',
              retryable: true,
            ),
          );
        }
        return ActionResult(
          ok: true,
          action: command,
          message:
              'Found "${command.text}" after $steps step(s) in $ownerName; it is now in the viewport.',
          data: {
            'operationPhase': 'settled',
            'scrollTo': {
              ...facts(),
              'found': true,
              'revealed': true,
              'control': live.toJson(),
            },
          },
        );
      }
      if (reachedEnd || steps >= maxSteps) break;
      final before = position.pixels;
      final viewport =
          position.viewportDimension.isFinite && position.viewportDimension > 0
              ? position.viewportDimension
              : 360.0;
      final next = math.min(
        position.maxScrollExtent,
        math.max(position.minScrollExtent, before + sign * viewport),
      );
      if (next == before) {
        reachedEnd = true;
        break;
      }
      position.jumpTo(next);
      steps += 1;
      await _settleAfterUserAction();
      if (!ownerIsLive()) {
        return ActionResult(
          ok: false,
          action: command,
          data: {
            'operationPhase': 'dispatched_unknown_effect',
            'scrollTo': {...facts(), 'found': false},
          },
          error: const ActionError(
            type: 'scroll_owner_changed',
            message:
                'The container was replaced while stepping; select it again from a fresh observation',
            retryable: true,
          ),
        );
      }
      final after = position.pixels;
      if (after == before ||
          (sign > 0
              ? after >= position.maxScrollExtent
              : after <= position.minScrollExtent)) {
        // The end is judged after layout, so a lazily built list that grew
        // during this step is not mistaken for finished.
        reachedEnd = true;
      }
    }
    return ActionResult(
      ok: false,
      action: command,
      data: {
        'operationPhase': 'settled',
        'scrollTo': {...facts(), 'found': false},
      },
      error: ActionError(
        type: 'scroll_to_not_found',
        message:
            reachedEnd
                ? 'Reached the $direction end of $ownerName after $steps step(s) without finding "${command.text}"'
                : 'Stopped after the maximum $maxSteps step(s) without finding "${command.text}"; the $direction end was not reached',
        retryable: !reachedEnd,
      ),
    );
  }

  /// Scroll containers a person can see on that axis now: rendered, in the viewport, and the
  /// scroll owner of their own control. Each is registered, so it can be named by its id. A text
  /// field scrolls its own text, not a list, so it is not one.
  List<_FlutterRuntimeControlBinding> _onScreenScrollOwners(Axis axis) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const <_FlutterRuntimeControlBinding>[];
    final owners = <_FlutterRuntimeControlBinding>[];
    void walk(Element element) {
      if (element.widget is EditableText) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final control = _runtimeControlForElement(element);
        final owner = control?.scrollOwner;
        if (control != null &&
            owner != null &&
            owner.axis == axis &&
            control.rendered &&
            control.inViewport) {
          _runtimeControlsById[control.id] = control;
          owners.add(control);
        }
      }
      element.visitChildren(walk);
    }

    walk(root);
    return owners;
  }

  /// A container as an answer names it: its label, or its id and place on screen.
  String _scrollContainerName(_FlutterRuntimeControlBinding control) {
    final label = control.label?.trim();
    if (label != null && label.isNotEmpty) return '"$label" (${control.id})';
    final bounds = _boundsForElement(control.element);
    if (bounds == null) return 'unlabelled scrollable ${control.id}';
    return 'unlabelled scrollable ${control.id} at '
        '${bounds.left.round()},${bounds.top.round()} '
        '(${bounds.width.round()}x${bounds.height.round()})';
  }

  /// A container as a refusal lists it: its id, label and place on screen, and
  /// the ticket issued for it by the latest observation, if any, which the host
  /// keeps to itself: the Tester names a container only by a spot inside it.
  JsonMap _scrollContainerFacts(_FlutterRuntimeControlBinding control) {
    final bounds = _boundsForElement(control.element);
    final reference = _observationTargets.referenceForLiveControl(control);
    return <String, Object?>{
      'id': control.id,
      if (reference != null)
        'observationTargetRef': <String, Object?>{
          'version': reference.version,
          'ticketId': reference.ticketId,
          'snapshotId': reference.snapshotId,
        },
      if (control.label != null) 'label': control.label,
      if (bounds != null)
        'bounds': <String, Object?>{
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        },
    };
  }

  /// Rendered controls and plain text inside [root] whose label, text or value
  /// contains [needle]. A matching control is not descended into, so its own
  /// text is not counted a second time. Containers are never matches.
  List<_ScrollToMatch> _scrollToMatches(
    Element root,
    String needle,
    String? role,
  ) {
    final matches = <_ScrollToMatch>[];
    var visited = 0;
    void walk(Element element) {
      if (++visited > 20000) return;
      final candidate = _scrollToCandidate(element);
      if (candidate != null && candidate.matches(needle, role)) {
        matches.add(candidate);
        return;
      }
      element.visitChildren(walk);
    }

    walk(root);
    return matches;
  }

  _ScrollToMatch? _scrollToCandidate(Element element) {
    final control = _runtimeControlForElement(element);
    if (control != null) {
      if (control.scrollOwner != null || !control.rendered) return null;
      return _ScrollToMatch(
        element: element,
        id: control.id,
        role: _scrollToRoleName(control.role),
        label: control.label,
        text:
            control.text ??
            (control.secure
                ? null
                : control.textController?.text ?? control.value?.toString()),
        bounds: control.bounds,
        inViewport: control.inViewport,
      );
    }
    final text = _clean(_directWidgetText(element.widget));
    if (text.isEmpty || _looksLikeIconOnlyWidgetText(text)) return null;
    final bounds = _boundsForElement(element);
    if (bounds == null ||
        !bounds.isFinite ||
        bounds.isEmpty ||
        !_runtimeElementCanPaint(element)) {
      return null;
    }
    return _ScrollToMatch(
      element: element,
      id: null,
      role: 'text',
      label: text,
      text: text,
      bounds: bounds,
      inViewport: _boundsIntersectViewport(bounds),
    );
  }

  static String _scrollToRoleName(OperatorUiRole role) =>
      role == OperatorUiRole.switchRole ? 'switch' : role.name;

  _FlutterRuntimeControlBinding? _runtimeControlForTarget(
    ElementTarget? target, {
    String? requiredAction,
  }) {
    final id = target?.id?.trim();
    final reference = target?.observationTargetRef;
    final control =
        reference == null
            ? id == null || id.isEmpty
                ? null
                : _runtimeControlsById[id]
            : _observationTargets.bindingFor(reference);
    if (control == null) return null;
    if (id != null && id.isNotEmpty && control.id != id) return null;
    if (!control.element.mounted) return null;
    final renderObject = control.element.findRenderObject();
    if (renderObject != null && !renderObject.attached) return null;
    final current = _runtimeControlForElement(control.element);
    if (current == null || current.id != control.id) return null;
    if (requiredAction != null && !current.actions.contains(requiredAction)) {
      return null;
    }
    _runtimeControlsById[current.id] = current;
    return current;
  }

  Future<ActionResult?> _wait(ActionCommand command) async {
    final until = command.until;
    if (until == null) {
      return ActionResult(ok: true, action: command, message: 'Wait complete');
    }

    final timeout = command.timeout ?? const Duration(seconds: 2);
    if (until.type == 'elapsed') {
      final duration = until.duration;
      if (duration == null || duration.isNegative || timeout.isNegative) {
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'invalid_wait_condition',
            message:
                'elapsed durationMs and wait timeoutMs must be finite non-negative numbers',
            retryable: false,
          ),
        );
      }
      final stopwatch = Stopwatch()..start();
      await Future<void>.delayed(duration <= timeout ? duration : timeout);
      final elapsed = stopwatch.elapsed;
      if (elapsed < duration) {
        return ActionResult(
          ok: false,
          action: command,
          error: ActionError(
            type: 'wait_timeout',
            message:
                'Timed out after ${timeout.inMilliseconds}ms while waiting for ${duration.inMilliseconds}ms to elapse',
            retryable: true,
          ),
          data: <String, Object?>{
            'condition': 'elapsed',
            'requestedDurationMs': duration.inMilliseconds,
            'elapsedMs': elapsed.inMicroseconds / 1000,
            'clock': 'flutter_monotonic',
          },
        );
      }
      return ActionResult(
        ok: true,
        action: command,
        message:
            'Waited ${duration.inMilliseconds}ms using Flutter monotonic time',
        data: <String, Object?>{
          'condition': 'elapsed',
          'requestedDurationMs': duration.inMilliseconds,
          'elapsedMs': elapsed.inMicroseconds / 1000,
          'clock': 'flutter_monotonic',
        },
      );
    }
    if (until.type == 'network_event') {
      final path = until.path?.trim();
      if (path == null || path.isEmpty) {
        return ActionResult(
          ok: false,
          action: command,
          error: const ActionError(
            type: 'invalid_wait_condition',
            message: 'network_event requires one exact non-empty path',
            retryable: false,
          ),
        );
      }
      try {
        final event = await operator.events
            .where((event) => event.type == OperatorRuntimeEventType.network)
            .map((event) => event.payload)
            .where((payload) => payload is NetworkEvent)
            .cast<NetworkEvent>()
            .firstWhere((event) => _networkEventMatchesWait(event, until))
            .timeout(timeout);
        return ActionResult(
          ok: true,
          action: command,
          message: 'Observed future network event for $path',
          data: <String, Object?>{
            'condition': 'network_event',
            'observation': 'future_event',
            'eventId': event.id,
            'method': event.request.method,
            'path': event.request.path,
            if (event.response != null) 'ok': event.response!.ok,
          },
        );
      } on TimeoutException {
        return ActionResult(
          ok: false,
          action: command,
          error: ActionError(
            type: 'wait_timeout',
            message: 'Timed out waiting for network_event at $path',
            retryable: true,
          ),
        );
      }
    }
    final started = DateTime.now();
    while (DateTime.now().difference(started) <= timeout) {
      final snapshot = await operator.getSnapshot(
        refreshVisual: false,
        issueActionTargets: false,
      );
      if (_waitConditionMet(until, snapshot)) {
        return ActionResult(
          ok: true,
          action: command,
          message: 'Wait condition satisfied',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return ActionResult(
      ok: false,
      action: command,
      error: ActionError(
        type: 'wait_timeout',
        message: 'Timed out waiting for ${until.type}',
        retryable: true,
      ),
    );
  }

  bool _waitConditionMet(WaitCondition condition, AppSnapshot snapshot) {
    if (condition.type == 'route') {
      return condition.path == null ||
          snapshot.route.current.path == condition.path;
    }
    if (condition.type == 'state') {
      return snapshot.state.any(
        (store) =>
            store.name == condition.store &&
            valueAtPath(store.value, condition.statePath ?? r'$') != null,
      );
    }
    return true;
  }

  Future<ActionResult?> _navigate(ActionCommand command) async {
    final location = _navigationLocation(command);
    if (location == null) {
      return ActionResult(
        ok: false,
        action: command,
        error: const ActionError(
          type: 'missing_route',
          message: 'Navigation path is required',
        ),
      );
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;

    final attempts = <String>[];
    final method =
        await _tryRouterWidgetNavigation(root, location, command, attempts) ??
        await _tryInheritedRouterNavigation(
          root,
          location,
          command,
          attempts,
        ) ??
        await _tryGetXNavigation(location, command, attempts) ??
        await _tryNavigatorNavigation(root, location, command, attempts);

    if (method == null) {
      operator.captureLog(
        'debug',
        'automatic flutter navigation was not handled',
        data: <String, Object?>{
          'path': location,
          if (attempts.isNotEmpty) 'attempts': attempts,
        },
      );
      return null;
    }

    await _settleAfterUserAction();
    captureRouteFromElementTree();
    return ActionResult(
      ok: true,
      action: command,
      message: 'Navigated to $location via $method',
    );
  }

  Future<String?> _tryRouterWidgetNavigation(
    Element root,
    String location,
    ActionCommand command,
    List<String> attempts,
  ) async {
    for (final element in _elementsDeepestFirst(root)) {
      final widget = element.widget;
      if (widget is! Router<Object>) continue;
      final provider = widget.routeInformationProvider;
      if (provider != null &&
          await _tryDynamicNavigation(
            provider,
            location,
            command,
            attempts,
            owner: provider.runtimeType.toString(),
          )) {
        return '${provider.runtimeType}.go';
      }

      final delegate = widget.routerDelegate;
      if (await _tryDynamicNavigation(
        delegate,
        location,
        command,
        attempts,
        owner: delegate.runtimeType.toString(),
      )) {
        return delegate.runtimeType.toString();
      }

      final parser = widget.routeInformationParser;
      if (parser != null &&
          await _trySetNewRoutePath(
            parser,
            delegate,
            element,
            location,
            attempts,
          )) {
        return '${delegate.runtimeType}.setNewRoutePath';
      }
    }
    return null;
  }

  Future<String?> _tryInheritedRouterNavigation(
    Element root,
    String location,
    ActionCommand command,
    List<String> attempts,
  ) async {
    for (final element in _elementsDeepestFirst(root)) {
      final widget = element.widget;
      final type = widget.runtimeType.toString();
      if (!type.contains('InheritedGoRouter')) continue;
      Object? router;
      try {
        router = (widget as dynamic).goRouter;
      } catch (error) {
        attempts.add('$type.goRouter:$error');
      }
      if (router != null &&
          await _tryDynamicNavigation(
            router,
            location,
            command,
            attempts,
            owner: router.runtimeType.toString(),
          )) {
        return '${router.runtimeType}.go';
      }
    }
    return null;
  }

  Future<String?> _tryNavigatorNavigation(
    Element root,
    String location,
    ActionCommand command,
    List<String> attempts,
  ) async {
    final navigators = <NavigatorState>{};
    for (final element in _elementsDeepestFirst(root)) {
      final navigator = Navigator.maybeOf(element);
      if (navigator != null) navigators.add(navigator);
      final rootNavigator = Navigator.maybeOf(element, rootNavigator: true);
      if (rootNavigator != null) navigators.add(rootNavigator);
    }

    for (final navigator in navigators) {
      try {
        unawaited(
          navigator.pushNamed<Object?>(
            location,
            arguments: command.payload ?? command.params,
          ),
        );
        return '${navigator.runtimeType}.pushNamed';
      } catch (error) {
        attempts.add('${navigator.runtimeType}.pushNamed:$error');
      }
    }
    return null;
  }

  Future<String?> _tryGetXNavigation(
    String location,
    ActionCommand command,
    List<String> attempts,
  ) async {
    if (gx.Get.key.currentState == null) return null;
    try {
      final result = gx.Get.toNamed<Object?>(
        location,
        arguments: command.payload,
        parameters: _stringParams(command.params),
      );
      if (result == null && gx.Get.currentRoute != location) return null;
      return 'Get.toNamed';
    } catch (error) {
      attempts.add('Get.toNamed:$error');
      return null;
    }
  }

  Future<bool> _trySetNewRoutePath(
    RouteInformationParser<Object> parser,
    RouterDelegate<Object> delegate,
    BuildContext context,
    String location,
    List<String> attempts,
  ) async {
    final information = RouteInformation(uri: Uri.parse(location));
    Object configuration;
    try {
      configuration = await parser.parseRouteInformationWithDependencies(
        information,
        context,
      );
    } catch (firstError) {
      try {
        configuration = await parser.parseRouteInformation(information);
      } catch (secondError) {
        attempts.add('${parser.runtimeType}.parse:$firstError/$secondError');
        return false;
      }
    }

    try {
      await delegate.setNewRoutePath(configuration);
      return true;
    } catch (error) {
      attempts.add('${delegate.runtimeType}.setNewRoutePath:$error');
      return false;
    }
  }

  Future<bool> _tryDynamicNavigation(
    Object target,
    String location,
    ActionCommand command,
    List<String> attempts, {
    required String owner,
  }) async {
    final params = _stringParams(command.params);
    final dynamic dynamicTarget = target;

    try {
      await _awaitMaybe(dynamicTarget.go(location, extra: command.payload));
      return true;
    } catch (error) {
      attempts.add('$owner.go(extra):$error');
    }

    try {
      await _awaitMaybe(dynamicTarget.go(location));
      return true;
    } catch (error) {
      attempts.add('$owner.go:$error');
    }

    try {
      await _awaitMaybe(
        dynamicTarget.navigatePath(location, includePrefixMatches: true),
      );
      return true;
    } catch (error) {
      attempts.add('$owner.navigatePath:$error');
    }

    try {
      dynamicTarget.pushPath(location, includePrefixMatches: true);
      return true;
    } catch (error) {
      attempts.add('$owner.pushPath:$error');
    }

    try {
      dynamicTarget.beamToNamed(location, data: command.payload);
      return true;
    } catch (error) {
      attempts.add('$owner.beamToNamed(data):$error');
    }

    try {
      dynamicTarget.beamToNamed(location);
      return true;
    } catch (error) {
      attempts.add('$owner.beamToNamed:$error');
    }

    try {
      dynamicTarget.toNamed(
        location,
        arguments: command.payload,
        parameters: params,
      );
      return true;
    } catch (error) {
      attempts.add('$owner.toNamed(parameters):$error');
    }

    try {
      dynamicTarget.toNamed(location);
      return true;
    } catch (error) {
      attempts.add('$owner.toNamed:$error');
    }

    return false;
  }

  Future<void> _awaitMaybe(Object? value) async {
    if (value is Future) await value;
  }

  String? _navigationLocation(ActionCommand command) {
    final raw = (command.path ?? command.routeName)?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (command.params.isEmpty) return raw;

    final uri = Uri.parse(raw);
    final params = <String, String>{
      ...uri.queryParameters,
      ..._stringParams(command.params),
    };
    return uri
        .replace(queryParameters: params.isEmpty ? null : params)
        .toString();
  }

  Map<String, String> _stringParams(JsonMap params) {
    return <String, String>{
      for (final entry in params.entries)
        if (entry.value != null) entry.key: entry.value.toString(),
    };
  }

  List<Element> _elementsDeepestFirst(Element root, {int maxElements = 20000}) {
    final elements = <Element>[];
    final visited = <Element>{};

    void walk(Element element) {
      if (!visited.add(element) || visited.length > maxElements) return;
      elements.add(element);
      element.visitChildren(walk);
    }

    walk(root);
    elements.sort((a, b) => b.depth.compareTo(a.depth));
    return elements;
  }

  Iterable<UiElement> _readUiElements() {
    ensureInstalled();
    captureRouteFromElementTree(emit: false);
    final nodes = _nodes().where((node) => !_isEmpty(node.data)).toList();
    final claimedSemanticsIds = <int>{};
    final elements = _readFlutterRuntimeControls(nodes, claimedSemanticsIds);
    for (final node in nodes) {
      if (claimedSemanticsIds.contains(node.node.id)) continue;
      elements.add(
        _semanticUiElement(node, omittedNodeIds: claimedSemanticsIds),
      );
    }
    elements.addAll(_readWidgetTextElements(elements));
    return elements;
  }

  List<UiElement> _readFlutterRuntimeControls(
    List<_SemanticsMatch> semantics,
    Set<int> claimedSemanticsIds,
  ) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) {
      _runtimeControlsById = <String, _FlutterRuntimeControlBinding>{};
      return <UiElement>[];
    }

    final candidates = <Element, _FlutterRuntimeControlBinding>{};
    final visited = <Element>{};

    void walk(Element element) {
      if (!visited.add(element) || visited.length > 20000) return;
      final control = _runtimeControlForElement(element);
      if (control != null) candidates[element] = control;
      element.visitChildren(walk);
    }

    walk(root);

    String? parentControlId(Element element) {
      String? parentId;
      element.visitAncestorElements((ancestor) {
        final parent = candidates[ancestor];
        if (parent == null) return true;
        parentId = parent.id;
        return false;
      });
      return parentId;
    }

    final childrenById = <String, List<String>>{};
    for (final entry in candidates.entries) {
      final parentId = parentControlId(entry.key);
      if (parentId != null) {
        childrenById
            .putIfAbsent(parentId, () => <String>[])
            .add(entry.value.id);
      }
    }

    final observationId = operator.activeSnapshotId;
    final issueActionTargets =
        observationId != null && operator.activeSnapshotIssuesActionTargets;
    if (issueActionTargets) {
      _observationTargets.beginSnapshot(observationId);
    }
    final currentBindings = <String, _FlutterRuntimeControlBinding>{};
    final elements = <UiElement>[];
    for (final entry in candidates.entries) {
      final element = entry.key;
      final control = entry.value;
      if (!element.mounted) continue;
      currentBindings[control.id] = control;

      final semantic = _matchingSemanticsForRuntimeControl(
        control,
        semantics,
        claimedSemanticsIds,
      );
      if (semantic != null) claimedSemanticsIds.add(semantic.node.id);
      final semanticData = semantic?.data;
      final semanticLabel = _clean(semanticData?.label ?? '');
      final semanticHint = _clean(semanticData?.hint ?? '');
      final semanticsValue = _clean(semanticData?.value ?? '');
      final runtimeLabel = _clean(control.label ?? '');
      final runtimeHint = _clean(control.hint ?? '');
      final bounds = control.bounds;
      final parentId = parentControlId(element);
      final runtimeValue =
          control.valueIsAuthoritative
              ? control.value
              : control.value ??
                  (semanticsValue.isEmpty ? null : semanticsValue);
      final value =
          control.secure && runtimeValue != null
              ? '[SECURE_FIELD]'
              : runtimeValue;
      final observationTargetRef =
          issueActionTargets &&
                  control.rendered &&
                  _canIssueObservationTarget(control) &&
                  control.actions.isNotEmpty
              ? _observationTargets.issue(observationId, control)
              : null;

      elements.add(
        UiElement(
          id: control.id,
          platformId: control.platformId,
          role: control.role,
          label:
              runtimeLabel.isNotEmpty
                  ? runtimeLabel
                  : semanticLabel.isEmpty
                  ? null
                  : semanticLabel,
          text: control.text,
          value: value,
          hint:
              runtimeHint.isNotEmpty
                  ? runtimeHint
                  : semanticHint.isEmpty
                  ? null
                  : semanticHint,
          enabled: control.enabled,
          visible: control.visible,
          rendered: control.rendered,
          inViewport: control.inViewport,
          selected: control.selected,
          checked: control.checked,
          bounds:
              bounds == null
                  ? null
                  : ElementBounds(
                    x: bounds.left,
                    y: bounds.top,
                    width: bounds.width,
                    height: bounds.height,
                  ),
          parentId: parentId,
          children: childrenById[control.id] ?? const <String>[],
          actions: control.actions,
          observationTargetRef: observationTargetRef,
          scrollOwner:
              control.scrollOwner == null
                  ? null
                  : _scrollOwnerFacts(control.scrollOwner!),
          data: <String, Object?>{
            'source': 'flutter_runtime',
            'widgetType': element.widget.runtimeType.toString(),
            if (control.debugKey != null) 'debugKey': control.debugKey,
            if (control.valueSource != null) 'valueSource': control.valueSource,
            if (control.secure) 'secure': true,
            if (control.readOnly) 'readOnly': true,
            if (control.focusNode != null)
              'focused': control.focusNode!.hasPrimaryFocus,
            if (semantic != null) 'semanticsId': semantic.node.id,
            if (semanticData != null)
              'semanticsRole': semanticData.role.toString(),
            if (semanticsValue.isNotEmpty && semanticsValue != value)
              'semanticsValueContradicted': true,
          },
          confidence: control.confidence,
        ),
      );
    }
    if (issueActionTargets) {
      _observationTargets.endSnapshot(observationId);
    }
    _runtimeControlsById = currentBindings;
    return elements;
  }

  bool _canIssueObservationTarget(_FlutterRuntimeControlBinding control) {
    if (control.enabled) return true;
    return control.actions.every((action) => action == 'scrollIntoView');
  }

  _FlutterRuntimeControlBinding? _runtimeControlForElement(Element element) {
    final widget = element.widget;
    final isScrollable =
        element is StatefulElement && element.state is ScrollableState;
    final isEditableText =
        widget is EditableText && !_hasTextFieldAncestor(element);
    final hasGestureTap = widget is GestureDetector && widget.onTap != null;
    final hasGestureDrag =
        widget is GestureDetector &&
        (widget.onPanStart != null ||
            widget.onPanUpdate != null ||
            widget.onPanEnd != null ||
            widget.onHorizontalDragStart != null ||
            widget.onHorizontalDragUpdate != null ||
            widget.onHorizontalDragEnd != null ||
            widget.onVerticalDragStart != null ||
            widget.onVerticalDragUpdate != null ||
            widget.onVerticalDragEnd != null);
    final isGestureControl =
        widget is GestureDetector &&
        (hasGestureTap || hasGestureDrag) &&
        !_hasInteractiveControlAncestor(element);
    final isInkControl =
        widget is InkWell &&
        widget.onTap != null &&
        !_hasInteractiveControlAncestor(element);
    final isMouseControl =
        widget is MouseRegion &&
        (widget.onEnter != null ||
            widget.onHover != null ||
            widget.onExit != null) &&
        !_hasInteractiveControlAncestor(element);
    final isDragControl =
        widget is Draggable<Object> && !_hasInteractiveControlAncestor(element);
    final isKeyboardControl =
        (widget is KeyboardListener ||
            (widget is Focus &&
                widget.onKeyEvent != null &&
                !_isKeyboardListenerFocus(element))) &&
        !_hasInteractiveControlAncestor(element);
    if (!isScrollable &&
        widget is! TextField &&
        !isEditableText &&
        widget is! ButtonStyleButton &&
        widget is! IconButton &&
        widget is! FloatingActionButton &&
        widget is! Checkbox &&
        widget is! Switch &&
        widget is! Radio<Object?> &&
        widget is! Slider &&
        widget is! DropdownButton<Object?> &&
        !isGestureControl &&
        !isInkControl &&
        !isMouseControl &&
        !isDragControl &&
        !isKeyboardControl) {
      return null;
    }
    final bounds = _boundsForElement(element);
    final rendered =
        bounds != null &&
        bounds.isFinite &&
        !bounds.isEmpty &&
        _runtimeElementCanPaint(element);
    final inViewport = rendered && _boundsIntersectViewport(bounds);
    final visible = inViewport;
    final id = _runtimeControlId(element);
    final platformId = _runtimePlatformId(element);
    final debugKey = _nearestRuntimeDebugKey(element);
    // A generic gesture, hover, or drag wrapper does not own focus merely
    // because a nested control does. Standard focusable controls and explicit
    // KeyboardListener/Focus controls may use their internal FocusNode.
    final runtimeFocusNode =
        isScrollable || isGestureControl || isMouseControl || isDragControl
            ? null
            : _runtimeFocusNodeForElement(element);
    List<String> actions(Iterable<String> base) => <String>{
      ...base,
      if (base.contains('tap')) 'touch',
      if (runtimeFocusNode?.canRequestFocus == true) 'key',
      if (_hasScrollableAncestor(element)) 'scrollIntoView',
    }.toList(growable: false);

    if (isScrollable) {
      final state = element.state as ScrollableState;
      ScrollPosition position;
      try {
        position = state.position;
      } catch (_) {
        return null;
      }
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.list,
        enabled: true,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions:
            position.hasContentDimensions
                ? actions(const <String>['scroll', 'touch'])
                : actions(const <String>[]),
        platformId: platformId,
        debugKey: debugKey,
        scrollOwner: position,
        confidence: 0.96,
      );
    }

    if (widget is TextField) {
      final editable = _findEditableText(element);
      final controller = widget.controller ?? editable?.controller;
      final enabled = widget.enabled ?? widget.decoration?.enabled ?? true;
      final readOnly = widget.readOnly;
      final label = _firstNonEmpty(<String?>[
        widget.decoration?.labelText,
        widget.decoration?.hintText,
      ]);
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.input,
        label: label,
        value: controller?.text,
        valueIsAuthoritative: controller != null,
        valueSource: controller == null ? null : 'text_editing_controller',
        hint: _cleanNullable(widget.decoration?.hintText),
        enabled: enabled,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions:
            enabled
                ? actions(<String>[
                  'tap',
                  if (!readOnly) ...const <String>['type', 'clear'],
                ])
                : actions(const <String>[]),
        platformId: widget.restorationId ?? platformId,
        debugKey: debugKey,
        textController: controller,
        onTextChanged: widget.onChanged ?? editable?.onChanged,
        focusNode: editable?.focusNode ?? runtimeFocusNode,
        secure: widget.obscureText,
        readOnly: readOnly,
        confidence: 0.99,
      );
    }

    if (isEditableText) {
      final editableText = widget;
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.input,
        value: editableText.controller.text,
        valueIsAuthoritative: true,
        valueSource: 'text_editing_controller',
        enabled: true,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions: actions(<String>[
          'tap',
          if (!editableText.readOnly) ...const <String>['type', 'clear'],
        ]),
        platformId: editableText.restorationId ?? platformId,
        debugKey: debugKey,
        textController: editableText.controller,
        onTextChanged: editableText.onChanged,
        focusNode: editableText.focusNode,
        secure: editableText.obscureText,
        readOnly: editableText.readOnly,
        confidence: 0.99,
      );
    }

    if (widget is ButtonStyleButton) {
      final enabled = widget.onPressed != null || widget.onLongPress != null;
      final tappable = widget.onPressed != null;
      final text = _descendantRuntimeText(element);
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.button,
        label: text,
        text: text,
        enabled: enabled,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions:
            tappable
                ? actions(const <String>['tap'])
                : actions(const <String>[]),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.98,
      );
    }

    if (widget is IconButton) {
      final enabled = widget.onPressed != null;
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.button,
        label: _cleanNullable(widget.tooltip),
        enabled: enabled,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions:
            enabled
                ? actions(const <String>['tap'])
                : actions(const <String>[]),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.98,
      );
    }

    if (widget is FloatingActionButton) {
      final enabled = widget.onPressed != null;
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.button,
        label:
            _cleanNullable(widget.tooltip) ?? _descendantRuntimeText(element),
        enabled: enabled,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions:
            enabled
                ? actions(const <String>['tap'])
                : actions(const <String>[]),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.98,
      );
    }

    if (widget is Checkbox) {
      final enabled = widget.onChanged != null;
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.checkbox,
        checked: widget.value,
        value: widget.value,
        valueIsAuthoritative: true,
        valueSource: 'widget.value',
        enabled: enabled,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions:
            enabled
                ? actions(const <String>['tap'])
                : actions(const <String>[]),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.98,
      );
    }

    if (widget is Switch) {
      final enabled = widget.onChanged != null;
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.switchRole,
        checked: widget.value,
        value: widget.value,
        valueIsAuthoritative: true,
        valueSource: 'widget.value',
        enabled: enabled,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions:
            enabled
                ? actions(const <String>['tap'])
                : actions(const <String>[]),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.98,
      );
    }

    if (widget is Radio<Object?>) {
      // These fields remain the only backwards-compatible value source for
      // Flutter versions supported before RadioGroup was introduced.
      // ignore: deprecated_member_use
      final enabled = widget.onChanged != null;
      // ignore: deprecated_member_use
      final selected = widget.value == widget.groupValue;
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.radio,
        selected: selected,
        checked: selected,
        value: widget.value,
        valueIsAuthoritative: true,
        valueSource: 'widget.value',
        enabled: enabled,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions:
            enabled
                ? actions(const <String>['tap'])
                : actions(const <String>[]),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.98,
      );
    }

    if (widget is Slider) {
      final enabled = widget.onChanged != null;
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.input,
        value: widget.value,
        valueIsAuthoritative: true,
        valueSource: 'widget.value',
        enabled: enabled,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions:
            enabled
                ? actions(const <String>['tap'])
                : actions(const <String>[]),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.96,
      );
    }

    if (widget is DropdownButton<Object?>) {
      final enabled = widget.onChanged != null;
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.input,
        label: _cleanNullable(
          widget.hint is Text ? (widget.hint as Text).data : null,
        ),
        value: widget.value,
        valueIsAuthoritative: true,
        valueSource: 'widget.value',
        enabled: enabled,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions:
            enabled
                ? actions(const <String>['tap'])
                : actions(const <String>[]),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.96,
      );
    }

    if (isGestureControl) {
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.button,
        label: _descendantRuntimeText(element),
        enabled: true,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions: actions(<String>[
          if (hasGestureTap) 'tap',
          if (hasGestureDrag) ...const <String>['drag', 'touch'],
        ]),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.9,
      );
    }

    if (isInkControl) {
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.button,
        label: _descendantRuntimeText(element),
        enabled: true,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions: actions(const <String>['tap']),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.9,
      );
    }

    if (isMouseControl || isDragControl || isKeyboardControl) {
      return _FlutterRuntimeControlBinding(
        id: id,
        element: element,
        role: OperatorUiRole.unknown,
        label: _descendantRuntimeText(element),
        text: _descendantRuntimeText(element),
        enabled: true,
        visible: visible,
        rendered: rendered,
        inViewport: inViewport,
        bounds: bounds,
        actions: actions(<String>[
          if (isMouseControl) 'hover',
          if (isDragControl) ...const <String>['drag', 'touch'],
        ]),
        platformId: platformId,
        debugKey: debugKey,
        focusNode: runtimeFocusNode,
        confidence: 0.9,
      );
    }

    return null;
  }

  String _runtimeControlId(Element element) {
    final current = _runtimeControlIds[element];
    if (current != null) return current;
    final created = 'flutter-runtime-${++_runtimeControlCounter}';
    _runtimeControlIds[element] = created;
    return created;
  }

  String? _runtimePlatformId(Element element) {
    final key = element.widget.key;
    if (key == null) return null;
    final value = key.toString().trim();
    return value.isEmpty ? null : value;
  }

  String? _nearestRuntimeDebugKey(Element element) {
    final own = _runtimePlatformId(element);
    if (own != null) return own;
    String? result;
    element.visitAncestorElements((ancestor) {
      result = _runtimePlatformId(ancestor);
      return result == null;
    });
    return result;
  }

  bool _hasTextFieldAncestor(Element element) {
    var found = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is TextField) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  /// The Focus a KeyboardListener builds for itself belongs to that listener.
  bool _isKeyboardListenerFocus(Element element) {
    var listener = false;
    element.visitAncestorElements((ancestor) {
      listener = ancestor.widget is KeyboardListener;
      return false;
    });
    return listener;
  }

  bool _hasInteractiveControlAncestor(Element element) {
    var found = false;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is ButtonStyleButton ||
          widget is IconButton ||
          widget is FloatingActionButton ||
          widget is TextField ||
          widget is EditableText ||
          widget is Checkbox ||
          widget is Switch ||
          widget is Radio<Object?> ||
          widget is Slider ||
          widget is DropdownButton<Object?> ||
          widget is Draggable<Object>) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  FocusNode? _runtimeFocusNodeForElement(Element root) {
    final widget = root.widget;
    if (widget is EditableText) return widget.focusNode;
    if (widget is TextField && widget.focusNode != null) {
      return widget.focusNode;
    }
    if (widget is KeyboardListener) return widget.focusNode;
    if (widget is Focus && widget.focusNode != null) return widget.focusNode;

    var visited = 0;
    FocusNode? result;

    bool isInsideRoot(BuildContext? context) {
      if (context is! Element) return false;
      if (identical(context, root)) return true;
      var inside = false;
      context.visitAncestorElements((ancestor) {
        if (identical(ancestor, root)) {
          inside = true;
          return false;
        }
        return true;
      });
      return inside;
    }

    void walk(Element element) {
      if (result != null || visited++ >= 300) return;
      final node = Focus.maybeOf(element, createDependency: false);
      if (node != null && node.canRequestFocus && isInsideRoot(node.context)) {
        result = node;
        return;
      }
      element.visitChildren(walk);
    }

    root.visitChildren(walk);
    return result;
  }

  String? _descendantRuntimeText(Element root) {
    final values = <String>[];
    final visited = <Element>{};

    void walk(Element element) {
      if (!visited.add(element) || visited.length > 200) return;
      if (element != root && _runtimeControlForTextBoundary(element.widget)) {
        return;
      }
      final text = _clean(_directWidgetText(element.widget));
      if (text.isNotEmpty && !values.contains(text)) values.add(text);
      if (values.length >= 8) return;
      element.visitChildren(walk);
    }

    walk(root);
    if (values.isEmpty) return null;
    return values.join(' ');
  }

  bool _runtimeControlForTextBoundary(Widget widget) {
    return widget is ButtonStyleButton ||
        widget is IconButton ||
        widget is FloatingActionButton ||
        widget is TextField ||
        widget is EditableText ||
        widget is Checkbox ||
        widget is Switch ||
        widget is Radio<Object?> ||
        widget is Slider ||
        widget is DropdownButton<Object?>;
  }

  String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final cleaned = _cleanNullable(value);
      if (cleaned != null) return cleaned;
    }
    return null;
  }

  String? _cleanNullable(String? value) {
    if (value == null) return null;
    final cleaned = _clean(value);
    return cleaned.isEmpty ? null : cleaned;
  }

  _SemanticsMatch? _matchingSemanticsForRuntimeControl(
    _FlutterRuntimeControlBinding control,
    List<_SemanticsMatch> semantics,
    Set<int> claimedSemanticsIds,
  ) {
    final bounds = control.bounds;
    if (bounds == null || bounds.isEmpty || !bounds.isFinite) return null;
    _SemanticsMatch? best;
    var bestScore = 0.0;
    for (final semantic in semantics) {
      if (claimedSemanticsIds.contains(semantic.node.id)) continue;
      final overlap = _rectOverlapRatio(bounds, semantic.bounds);
      final centerDistance = (bounds.center - semantic.bounds.center).distance;
      if (overlap < 0.5 && centerDistance > 4) continue;
      final semanticRole = _roleFor(semantic.data);
      final roleMatches = semanticRole == control.role;
      final scrollMatches =
          control.scrollOwner != null &&
          _actionsFor(semantic.data).contains('scroll');
      if (!roleMatches && !scrollMatches) continue;
      var score = overlap * 100;
      if (roleMatches) score += 30;
      if (scrollMatches) score += 30;
      final controlLabel = _normalizedMatchText(control.label);
      final semanticLabel = _normalizedMatchText(semantic.data.label);
      if (controlLabel.isNotEmpty && semanticLabel == controlLabel) {
        score += 40;
      } else if (controlLabel.isNotEmpty &&
          semanticLabel.contains(controlLabel)) {
        score += 20;
      }
      if (score > bestScore) {
        bestScore = score;
        best = semantic;
      }
    }
    return best;
  }

  UiElement _semanticUiElement(
    _SemanticsMatch node, {
    Set<int> omittedNodeIds = const <int>{},
  }) {
    final data = node.data;
    final role = _roleFor(data);
    final id =
        data.identifier.trim().isEmpty
            ? 'flutter-semantics-${node.node.id}'
            : data.identifier.trim();
    final label = _clean(data.label);
    final value = _clean(data.value);
    final hint = _clean(data.hint);
    return UiElement(
      id: id,
      platformId: '${node.node.id}',
      role: role,
      label: label.isEmpty ? null : label,
      text: label.isNotEmpty ? label : null,
      value: value.isEmpty ? null : value,
      hint: hint.isEmpty ? null : hint,
      enabled: data.flagsCollection.isEnabled.toBoolOrNull() ?? true,
      visible: !data.flagsCollection.isHidden && !node.bounds.isEmpty,
      selected: data.flagsCollection.isSelected.toBoolOrNull(),
      checked: data.flagsCollection.isChecked.toBoolOrNull(),
      bounds: ElementBounds(
        x: node.bounds.left,
        y: node.bounds.top,
        width: node.bounds.width,
        height: node.bounds.height,
      ),
      parentId:
          node.parentId == null || omittedNodeIds.contains(node.parentId)
              ? null
              : 'flutter-semantics-${node.parentId}',
      children: node.children
          .where((child) => !omittedNodeIds.contains(child.node.id))
          .map((child) => 'flutter-semantics-${child.node.id}')
          .toList(growable: false),
      actions: _actionsFor(data),
      data: <String, Object?>{
        'source': 'flutter_semantics',
        'semanticsId': node.node.id,
        'role': data.role.toString(),
        if (data.identifier.isNotEmpty) 'identifier': data.identifier,
      },
      confidence: data.identifier.isNotEmpty ? 0.98 : 0.86,
    );
  }

  UiScrollOwnerFacts _scrollOwnerFacts(ScrollPosition position) {
    final horizontal = switch (position.axisDirection) {
      AxisDirection.left || AxisDirection.right => true,
      AxisDirection.up || AxisDirection.down => false,
    };
    final min = position.hasContentDimensions ? position.minScrollExtent : 0.0;
    final max = position.hasContentDimensions ? position.maxScrollExtent : 0.0;
    final pixels = position.hasPixels ? position.pixels : min;
    final viewport =
        position.hasContentDimensions ? position.viewportDimension : 0.0;
    final normalizedOffset = math.max(0.0, pixels - min);
    final normalizedMax = math.max(0.0, max - min);
    return UiScrollOwnerFacts(
      axes: <String>[horizontal ? 'x' : 'y'],
      offsetX: horizontal ? normalizedOffset : 0,
      offsetY: horizontal ? 0 : normalizedOffset,
      maxOffsetX: horizontal ? normalizedMax : 0,
      maxOffsetY: horizontal ? 0 : normalizedMax,
      canScrollUp: !horizontal && pixels > min + 0.5,
      canScrollDown: !horizontal && pixels < max - 0.5,
      canScrollLeft: horizontal && pixels > min + 0.5,
      canScrollRight: horizontal && pixels < max - 0.5,
      viewportWidth: horizontal ? viewport : 0,
      viewportHeight: horizontal ? 0 : viewport,
    );
  }

  Iterable<UiElement> _readWidgetTextElements(
    List<UiElement> semanticElements,
  ) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const <UiElement>[];

    final elements = <UiElement>[];
    final seen = <String>{};
    var index = 0;
    for (final element in _elementsDeepestFirst(root, maxElements: 6000)) {
      final text = _clean(_directWidgetText(element.widget));
      if (text.isEmpty) continue;
      if (_looksLikeIconOnlyWidgetText(text)) continue;
      final bounds = _boundsForElement(element);
      if (bounds == null ||
          bounds.isEmpty ||
          !bounds.isFinite ||
          !_widgetTextElementCanPaint(element, bounds)) {
        continue;
      }
      if (_semanticAlreadyCoversWidgetText(semanticElements, text, bounds)) {
        continue;
      }
      if (!seen.add(_widgetTextDedupeKey(text, bounds))) continue;
      final widgetType = element.widget.runtimeType.toString();
      elements.add(
        UiElement(
          id: _widgetTextElementId(text, bounds, index++),
          platformId: widgetType,
          role: OperatorUiRole.text,
          label: text,
          text: text,
          enabled: true,
          visible: true,
          bounds: ElementBounds(
            x: bounds.left,
            y: bounds.top,
            width: bounds.width,
            height: bounds.height,
          ),
          actions: const <String>[],
          data: <String, Object?>{
            'source': 'flutter_widget_text',
            'widgetType': widgetType,
          },
          confidence: 0.72,
        ),
      );
      if (elements.length >= 200) break;
    }
    return elements;
  }

  bool _widgetTextElementCanPaint(Element element, Rect bounds) {
    if (!_pointInViewport(bounds.center)) return false;
    return _runtimeElementCanPaint(element);
  }

  bool _runtimeElementCanPaint(Element element) {
    if (_hasHiddenWidgetAncestor(element)) return false;
    final route = _modalRouteForElement(element);
    if (route == null) return true;
    return route.isCurrent || (route.isActive && !route.opaque);
  }

  bool _boundsIntersectViewport(Rect bounds) {
    final viewport = _viewportSize();
    if (viewport == null) return true;
    return bounds.overlaps(Offset.zero & viewport);
  }

  bool _hasScrollableAncestor(Element element) {
    var found = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor is StatefulElement && ancestor.state is ScrollableState) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  /// Scrollable.ensureVisible without its lookups: Scrollable.maybeOf makes the
  /// target and every enclosing Scrollable depend on their scroll scope, so a
  /// later change to that scope would rebuild them (a Scrollable replaces its
  /// ScrollPosition). The same walk, each Scrollable found as an ancestor.
  Future<void> _ensureVisible(
    Element target, {
    double alignment = 0,
    ScrollPositionAlignmentPolicy alignmentPolicy =
        ScrollPositionAlignmentPolicy.explicit,
  }) async {
    final reveals = <Future<void>>[];
    RenderObject? targetRenderObject;
    BuildContext context = target;
    var scrollable = context.findAncestorStateOfType<ScrollableState>();
    while (scrollable != null) {
      final object = context.findRenderObject();
      if (object == null || !object.attached) break;
      reveals.add(
        scrollable.position.ensureVisible(
          object,
          alignment: alignment,
          alignmentPolicy: alignmentPolicy,
          targetRenderObject: targetRenderObject,
        ),
      );
      targetRenderObject ??= target.findRenderObject();
      context = scrollable.context;
      scrollable = context.findAncestorStateOfType<ScrollableState>();
    }
    await Future.wait(reveals);
  }

  // Never ModalRoute.of(element): it makes the app's element depend on the
  // route's status, so every later push or pop rebuilds it and a Scrollable
  // replaces its ScrollPosition. Reading must not change the app, so the route
  // is read from the nearest scope widget, as _findCurrentRoute does.
  ModalRoute<dynamic>? _modalRouteForElement(Element element) {
    ModalRoute<dynamic>? route;
    try {
      element.visitAncestorElements((ancestor) {
        if (!_isModalScopeWidget(ancestor.widget)) return true;
        Object? value;
        try {
          final dynamic scope = ancestor.widget;
          value = scope.route;
        } catch (_) {
          return true;
        }
        if (value is! ModalRoute<dynamic>) return true;
        route = value;
        return false;
      });
    } catch (_) {
      return null;
    }
    return route;
  }

  /// Flutter's route scope (`_ModalScopeStatus`) is private: it is known by
  /// what it holds, an inherited widget carrying its ModalRoute, never by its
  /// class name, which release web builds minify. Cached per type because the
  /// check runs for every ancestor of every control read.
  bool _isModalScopeWidget(Widget widget) => _modalScopeWidgetTypes.putIfAbsent(
    widget.runtimeType,
    () {
      if (widget is! InheritedWidget) return false;
      try {
        final dynamic scope = widget;
        return scope.route is ModalRoute<dynamic>;
      } catch (_) {
        return false;
      }
    },
  );

  bool _hasHiddenWidgetAncestor(Element element) {
    var hidden = _widgetSuppressesPaint(element.widget);
    if (hidden) return true;
    element.visitAncestorElements((ancestor) {
      if (_widgetSuppressesPaint(ancestor.widget)) {
        hidden = true;
        return false;
      }
      return true;
    });
    return hidden;
  }

  bool _widgetSuppressesPaint(Widget widget) {
    if (widget is Offstage && widget.offstage) return true;
    if (widget is Visibility && !widget.visible) return true;
    if (widget is Opacity && widget.opacity <= 0) return true;
    if (widget is AnimatedOpacity && widget.opacity <= 0) return true;
    return false;
  }

  bool _looksLikeIconOnlyWidgetText(String text) {
    final runes = text.trim().runes.where((rune) => !_isWhitespaceRune(rune));
    if (runes.isEmpty) return true;
    return runes.every(_isPrivateUseRune);
  }

  bool _isWhitespaceRune(int rune) =>
      rune == 0x09 || rune == 0x0a || rune == 0x0d || rune == 0x20;

  bool _isPrivateUseRune(int rune) =>
      (rune >= 0xe000 && rune <= 0xf8ff) ||
      (rune >= 0xf0000 && rune <= 0xffffd) ||
      (rune >= 0x100000 && rune <= 0x10fffd);

  String _directWidgetText(Widget widget) {
    if (widget is Text) {
      return widget.data ?? widget.textSpan?.toPlainText() ?? '';
    }
    if (widget is RichText) {
      return widget.text.toPlainText();
    }
    return '';
  }

  bool _semanticAlreadyCoversWidgetText(
    List<UiElement> semanticElements,
    String text,
    Rect bounds,
  ) {
    final normalized = _normalizedMatchText(text);
    if (normalized.isEmpty) return true;
    for (final semantic in semanticElements) {
      final semanticText = _normalizedElementText(semantic);
      if (semanticText.isEmpty) continue;
      final sameText =
          semanticText == normalized ||
          semanticText.contains(normalized) ||
          normalized.contains(semanticText);
      if (!sameText) continue;
      final semanticBounds = semantic.bounds;
      if (semanticBounds == null) return true;
      final semanticRect = Rect.fromLTWH(
        semanticBounds.x,
        semanticBounds.y,
        semanticBounds.width,
        semanticBounds.height,
      );
      if (_rectOverlapRatio(bounds, semanticRect) >= 0.5 ||
          (bounds.center - semanticRect.center).distance <= 4) {
        return true;
      }
    }
    return false;
  }

  double _rectOverlapRatio(Rect a, Rect b) {
    final overlap = a.intersect(b);
    if (overlap.isEmpty) return 0;
    final smallerArea = math.min(_area(a), _area(b));
    if (smallerArea <= 0 || !smallerArea.isFinite) return 0;
    return _area(overlap) / smallerArea;
  }

  String _widgetTextDedupeKey(String text, Rect bounds) =>
      '${_normalizedMatchText(text)}@${bounds.left.round()},${bounds.top.round()},${bounds.width.round()},${bounds.height.round()}';

  String _widgetTextElementId(String text, Rect bounds, int index) {
    final key = _widgetTextDedupeKey(text, bounds);
    var hash = 0;
    for (final codeUnit in key.codeUnits) {
      hash = 0x1fffffff & (hash + codeUnit);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= hash >> 6;
    }
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash ^= hash >> 11;
    hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
    return 'flutter-widget-text-${hash.toRadixString(16)}-$index';
  }

  List<StateStoreSnapshot> _readStateStores() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const <StateStoreSnapshot>[];

    final summary = _FlutterTreeSummary();
    final visited = <Element>{};

    void walk(Element element) {
      if (!visited.add(element) || visited.length > 20000) return;
      final widget = element.widget;
      final widgetType = widget.runtimeType.toString();
      summary.addWidget(widgetType);
      summary.detect(widgetType);
      summary.capturePublicWidgetState(widgetType, widget);

      if (element is StatefulElement) {
        final state = element.state;
        final stateType = state.runtimeType.toString();
        final internalState =
            _isFlutterInternal(stateType) || _isFlutterInternal(widgetType);
        final publicState =
            internalState ? const <String, Object?>{} : _publicStateFor(state);
        summary.addState(<String, Object?>{
          'widget': widgetType,
          'state': stateType,
          'mounted': state.mounted,
          'diagnostics':
              internalState
                  ? <String, Object?>{'type': stateType}
                  : _diagnosticsFor(state),
          if (publicState.isNotEmpty) 'public': publicState,
        });
        if (!internalState) {
          summary.capturePublicControllerState(stateType, state);
        }
        summary.detect(stateType);
      }

      if (element is InheritedElement) {
        summary.addInherited(widgetType);
      }

      if (widget is ValueListenableBuilder<dynamic>) {
        summary.addValueListenable(<String, Object?>{
          'widget': widgetType,
          'listenable': widget.valueListenable.runtimeType.toString(),
          'value': _safeValue(widget.valueListenable.value),
        });
      } else if (widget is TextField && widget.controller != null) {
        final controller = widget.controller!;
        summary.addChangeNotifier(<String, Object?>{
          'widget': widgetType,
          'listenable': controller.runtimeType.toString(),
          'kind': 'textEditingController',
          'value': _safeValue(controller.value),
        });
      } else if (widget is AnimatedWidget) {
        final listenable = widget.listenable;
        summary.addChangeNotifier(<String, Object?>{
          'widget': widgetType,
          'listenable': listenable.runtimeType.toString(),
          if (listenable is ValueListenable<dynamic>)
            'value': _safeValue(listenable.value),
        });
      }

      element.visitChildren(walk);
    }

    walk(root);
    final stores = <StateStoreSnapshot>[
      StateStoreSnapshot(
        source: OperatorStateSource.inferred,
        name: 'FlutterWidgetTree',
        value: summary.widgetTreeValue,
        confidence: 0.76,
        redacted: false,
      ),
    ];

    if (_stateIndexers.setState && summary.states.isNotEmpty) {
      stores.add(
        StateStoreSnapshot(
          source: OperatorStateSource.setState,
          name: 'FlutterStatefulWidgets',
          value: <String, Object?>{'states': summary.states},
          confidence: 0.7,
          redacted: false,
        ),
      );
    }
    if (_stateIndexers.valueNotifier && summary.valueListenables.isNotEmpty) {
      stores.add(
        StateStoreSnapshot(
          source: OperatorStateSource.valueNotifier,
          name: 'FlutterValueListenables',
          value: <String, Object?>{'listenables': summary.valueListenables},
          confidence: 0.86,
          redacted: false,
        ),
      );
    }
    if (_stateIndexers.changeNotifier && summary.changeNotifiers.isNotEmpty) {
      stores.add(
        StateStoreSnapshot(
          source: OperatorStateSource.changeNotifier,
          name: 'FlutterChangeNotifiers',
          value: <String, Object?>{'listenables': summary.changeNotifiers},
          confidence: 0.64,
          redacted: false,
        ),
      );
    }
    if (_stateIndexers.provider && summary.providerWidgets.isNotEmpty) {
      stores.add(
        StateStoreSnapshot(
          source: OperatorStateSource.provider,
          name: 'FlutterProviderTree',
          value: <String, Object?>{
            'widgets': summary.providerWidgets,
            if (summary.providerValues.isNotEmpty)
              'values': summary.providerValues,
          },
          confidence: summary.providerValues.isEmpty ? 0.62 : 0.84,
          redacted: false,
        ),
      );
    }
    if (_stateIndexers.riverpod && summary.riverpodWidgets.isNotEmpty) {
      stores.add(
        StateStoreSnapshot(
          source: OperatorStateSource.riverpod,
          name: 'FlutterRiverpodTree',
          value: <String, Object?>{
            'widgets': summary.riverpodWidgets,
            if (summary.riverpodValues.isNotEmpty)
              'values': summary.riverpodValues,
          },
          confidence: summary.riverpodValues.isEmpty ? 0.6 : 0.82,
          redacted: false,
        ),
      );
    }
    if (_stateIndexers.getx && summary.getxWidgets.isNotEmpty) {
      stores.add(
        StateStoreSnapshot(
          source: OperatorStateSource.getx,
          name: 'FlutterGetXTree',
          value: <String, Object?>{
            'widgets': summary.getxWidgets,
            if (summary.getxControllers.isNotEmpty)
              'controllers': summary.getxControllers,
          },
          confidence: summary.getxControllers.isEmpty ? 0.6 : 0.86,
          redacted: false,
        ),
      );
    }
    if (_stateIndexers.custom && summary.customStates.isNotEmpty) {
      stores.add(
        StateStoreSnapshot(
          source: OperatorStateSource.custom,
          name: 'FlutterCustomState',
          value: <String, Object?>{'states': summary.customStates},
          confidence: 0.58,
          redacted: false,
        ),
      );
    }
    if (summary.inheritedWidgets.isNotEmpty) {
      stores.add(
        StateStoreSnapshot(
          source: OperatorStateSource.inheritedWidget,
          name: 'FlutterInheritedWidgets',
          value: <String, Object?>{'widgets': summary.inheritedWidgets},
          confidence: 0.68,
          redacted: false,
        ),
      );
    }
    return stores;
  }

  _SemanticsMatch? _resolve(
    ElementTarget? target, {
    SemanticsAction? preferredAction,
  }) {
    final allNodes = _nodes().where((node) => !_isEmpty(node.data)).toList();
    final nodes =
        target == null && preferredAction != null
            ? allNodes
                .where((node) => node.data.hasAction(preferredAction))
                .toList()
            : allNodes;
    if (nodes.isEmpty) return null;
    if (target == null) {
      return preferredAction == null
          ? nodes.first
          : nodes
              .where((node) => node.data.hasAction(preferredAction))
              .firstOrNull;
    }

    final scored = <_ScoredSemanticsMatch>[];
    for (final node in nodes) {
      final score = _score(node, target, preferredAction);
      if (score > 0) scored.add(_ScoredSemanticsMatch(node, score));
    }
    final fallbackPoint = target.fallbackBounds;
    if (fallbackPoint != null) {
      final point = Offset(fallbackPoint.x, fallbackPoint.y);
      final containing =
          scored
              .where(
                (candidate) =>
                    candidate.match.bounds.isFinite &&
                    candidate.match.bounds.contains(point),
              )
              .toList();
      if (containing.isNotEmpty) {
        _sortScoredMatches(containing);
        return containing.first.match;
      }
    }
    _sortScoredMatches(scored);
    final best = scored.firstOrNull?.match;
    if (best != null) {
      if (preferredAction != null && !best.data.hasAction(preferredAction)) {
        return _nearestActionableMatch(best, allNodes, preferredAction) ?? best;
      }
      return best;
    }
    return _resolveByFallbackPoint(nodes, target.fallbackBounds);
  }

  _SemanticsMatch? _nearestActionableMatch(
    _SemanticsMatch match,
    List<_SemanticsMatch> nodes,
    SemanticsAction action,
  ) {
    if (match.data.hasAction(action)) return match;
    final descendants = <_SemanticsMatch>[];

    void collect(_SemanticsMatch node) {
      for (final child in node.children) {
        if (child.data.hasAction(action)) descendants.add(child);
        collect(child);
      }
    }

    collect(match);
    if (descendants.isNotEmpty) {
      descendants.sort((a, b) => _area(a.bounds).compareTo(_area(b.bounds)));
      return descendants.first;
    }

    final overlapping =
        nodes
            .where(
              (node) =>
                  node.data.hasAction(action) &&
                  _isSpatialActionMatch(match.bounds, node.bounds) &&
                  _isReasonableActionFallback(match, node),
            )
            .toList();
    if (overlapping.isNotEmpty) {
      overlapping.sort((a, b) {
        final distance = _distance(
          a.bounds.center,
          match.bounds.center,
        ).compareTo(_distance(b.bounds.center, match.bounds.center));
        if (distance != 0) return distance;
        return _area(a.bounds).compareTo(_area(b.bounds));
      });
      return overlapping.first;
    }

    var parentId = match.parentId;
    while (parentId != null) {
      final parent =
          nodes.where((node) => node.node.id == parentId).firstOrNull;
      if (parent == null) break;
      if (parent.data.hasAction(action) &&
          _isReasonableActionFallback(match, parent)) {
        return parent;
      }
      parentId = parent.parentId;
    }
    return null;
  }

  bool _isReasonableActionFallback(
    _SemanticsMatch labelled,
    _SemanticsMatch action,
  ) {
    if (labelled.node.id == action.node.id) return true;
    if (labelled.bounds.isEmpty ||
        action.bounds.isEmpty ||
        !labelled.bounds.isFinite ||
        !action.bounds.isFinite) {
      return false;
    }
    if (!_isSpatialActionMatch(labelled.bounds, action.bounds)) return false;

    final labelledArea = _area(labelled.bounds);
    final actionArea = _area(action.bounds);
    if (!labelledArea.isFinite || !actionArea.isFinite || labelledArea <= 0) {
      return false;
    }
    final ratio = actionArea / labelledArea;
    if (ratio <= 12) return true;

    final labelledText = _normalizedMatchText(labelled.description);
    final actionText = _normalizedMatchText(
      <String>[
        action.data.identifier,
        action.data.label,
        action.data.value,
        action.data.hint,
        action.data.tooltip,
      ].where((value) => value.trim().isNotEmpty).join(' '),
    );
    if (labelledText.isNotEmpty &&
        actionText.isNotEmpty &&
        actionText.contains(labelledText) &&
        ratio <= 24) {
      return true;
    }

    return false;
  }

  void _sortScoredMatches(List<_ScoredSemanticsMatch> scored) {
    scored.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      final childCount = a.match.children.length.compareTo(
        b.match.children.length,
      );
      if (childCount != 0) return childCount;
      final areaA = _area(a.match.bounds);
      final areaB = _area(b.match.bounds);
      return areaA.compareTo(areaB);
    });
  }

  _SemanticsMatch? _resolveByFallbackPoint(
    List<_SemanticsMatch> nodes,
    FallbackPoint? fallbackBounds,
  ) {
    if (fallbackBounds == null) return null;
    final point = Offset(fallbackBounds.x, fallbackBounds.y);
    final matches =
        nodes
            .where(
              (node) =>
                  !node.bounds.isEmpty &&
                  node.bounds.isFinite &&
                  node.bounds.contains(point),
            )
            .toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) {
      final areaA = a.bounds.width * a.bounds.height;
      final areaB = b.bounds.width * b.bounds.height;
      return areaA.compareTo(areaB);
    });
    return matches.first;
  }

  int _score(
    _SemanticsMatch match,
    ElementTarget target,
    SemanticsAction? preferredAction,
  ) {
    final data = match.data;
    if (data.flagsCollection.isHidden) return 0;
    final haystack = <String>[
      _uiElementId(match),
      match.node.id.toString(),
      data.identifier,
      data.label,
      data.value,
    ].map(_normalizedMatchText).where((value) => value.isNotEmpty).join(' ');
    var score = 0;
    var matchedSpecificTarget = false;

    void scoreText(String? needle, int exact, int contains) {
      final value = _normalizedMatchText(needle);
      if (value.isEmpty) return;
      final fields = <String>[
        _uiElementId(match),
        match.node.id.toString(),
        data.identifier,
        data.label,
        data.value,
      ].map(_normalizedMatchText);
      final shortNeedle = value.length <= 2;
      if (fields.contains(value)) {
        score += exact;
        matchedSpecificTarget = true;
      } else if (!shortNeedle &&
          (fields.any((field) => _targetTextMatchesField(value, field)) ||
              haystack.contains(value))) {
        score += contains;
        matchedSpecificTarget = true;
      }
    }

    scoreText(target.id, 120, 60);
    scoreText(target.label, 90, 45);
    scoreText(target.text, 80, 40);
    scoreText(target.selector, 70, 35);
    scoreText(target.listContext?.itemText, 55, 25);
    final fallbackPoint = target.fallbackBounds;
    if (fallbackPoint != null &&
        match.bounds.isFinite &&
        match.bounds.contains(Offset(fallbackPoint.x, fallbackPoint.y))) {
      score += 20;
      matchedSpecificTarget = true;
    }

    final requestedRole = _targetRole(target.role);
    final actualRole = _roleFor(data);
    final hasTextTarget = <String?>[
      target.id,
      target.label,
      target.text,
      target.selector,
      target.listContext?.itemText,
    ].any((value) => value != null && value.trim().isNotEmpty);
    if (hasTextTarget && !matchedSpecificTarget) return 0;
    if (requestedRole != null && requestedRole == actualRole) {
      score += 25;
      if (!hasTextTarget) matchedSpecificTarget = true;
    }
    if (!hasTextTarget && requestedRole != null && !matchedSpecificTarget) {
      return 0;
    }
    if (preferredAction != null && data.hasAction(preferredAction)) score += 30;
    final exactDirectTextTarget = _targetMatchesDirectSemanticText(
      match,
      target,
    );
    if (preferredAction == SemanticsAction.tap &&
        actualRole == OperatorUiRole.input &&
        requestedRole != OperatorUiRole.input &&
        !exactDirectTextTarget) {
      score -= 120;
    }
    if (preferredAction == SemanticsAction.tap && match.children.isNotEmpty) {
      score -= math.min(30, match.children.length * 3);
    }
    final area =
        match.bounds.isEmpty ? 0.0 : match.bounds.width * match.bounds.height;
    if (area > 0 && area < 50000) score += 6;
    if ((data.flagsCollection.isEnabled.toBoolOrNull() ?? true) == false) {
      score -= 20;
    }
    return score;
  }

  String _uiElementId(_SemanticsMatch match) {
    final identifier = match.data.identifier.trim();
    return identifier.isEmpty
        ? 'flutter-semantics-${match.node.id}'
        : identifier;
  }

  String _normalizedMatchText(String? value) =>
      value?.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase() ?? '';

  bool _targetTextMatchesField(
    String needle,
    String field, {
    bool allowContains = true,
  }) {
    if (needle.isEmpty || field.isEmpty) return false;
    if (needle == field) return true;
    if (allowContains && needle.length > 2 && field.contains(needle)) {
      return true;
    }
    return _targetTextHasDecorativeLeadingBadge(needle, field);
  }

  bool _targetTextHasDecorativeLeadingBadge(String needle, String field) {
    final needleTokens = _matchTokens(needle);
    final fieldTokens = _matchTokens(field);
    if (fieldTokens.isEmpty || needleTokens.length < 3) return false;
    for (var prefixLength = 1; prefixLength <= 2; prefixLength += 1) {
      if (needleTokens.length <= prefixLength) continue;
      final prefixTokens = needleTokens
          .take(prefixLength)
          .toList(growable: false);
      final compact = prefixTokens.join();
      if (compact.isEmpty || compact.length > 3) continue;
      if (!prefixTokens.every(
        (token) => token.isNotEmpty && RegExp(r'^[a-z0-9]+$').hasMatch(token),
      )) {
        continue;
      }
      final remaining = needleTokens.skip(prefixLength).toList(growable: false);
      if (remaining.length < 2) continue;
      if (_containsTokenSequence(fieldTokens, remaining)) return true;
    }
    return false;
  }

  bool _containsTokenSequence(List<String> haystack, List<String> needle) {
    if (needle.isEmpty || haystack.length < needle.length) return false;
    for (var start = 0; start <= haystack.length - needle.length; start += 1) {
      var matched = true;
      for (var index = 0; index < needle.length; index += 1) {
        if (haystack[start + index] != needle[index]) {
          matched = false;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }

  List<String> _matchTokens(String value) => value
      .split(RegExp(r'\s+'))
      .map(
        (token) =>
            token.replaceAll(RegExp(r'^[.,:;()\[\]-]+|[.,:;()\[\]-]+$'), ''),
      )
      .where((token) => token.isNotEmpty)
      .toList(growable: false);

  String _targetLabel(ElementTarget? target) {
    if (target == null) return '<any>';
    for (final value in <String?>[
      target.id,
      target.label,
      target.text,
      target.selector,
      target.listContext?.itemText,
      target.role,
    ]) {
      if (value != null && value.trim().isNotEmpty) {
        return '"${value.trim()}"';
      }
    }
    return '<unspecified>';
  }

  String _primaryTargetText(ElementTarget? target) {
    if (target == null) return '';
    for (final value in <String?>[
      target.id,
      target.label,
      target.text,
      target.selector,
      target.listContext?.itemText,
    ]) {
      final normalized = _normalizedMatchText(value);
      if (normalized.isNotEmpty) return normalized;
    }
    return '';
  }

  List<_SemanticsMatch> _nodes() {
    final root = _semanticsOwner?.rootSemanticsNode;
    if (root == null) return const <_SemanticsMatch>[];
    final matches = <_SemanticsMatch>[];
    final visited = <int>{};

    _SemanticsMatch? walk(
      SemanticsNode node,
      int? parentId,
      Matrix4 parentTransform,
    ) {
      if (!visited.add(node.id) || matches.length > 5000) return null;
      final data = node.getSemanticsData();
      final transform = _globalTransform(data, parentTransform);
      final bounds = _logicalSemanticsBounds(
        MatrixUtils.transformRect(transform, data.rect),
      );
      final match = _SemanticsMatch(
        node: node,
        data: data,
        bounds: bounds,
        parentId: parentId,
      );
      matches.add(match);
      final children = <_SemanticsMatch>[];
      node.visitChildren((child) {
        final childMatch = walk(child, node.id, transform);
        if (childMatch != null) children.add(childMatch);
        return true;
      });
      match.children = children;
      return match;
    }

    walk(root, null, Matrix4.identity());
    return matches;
  }

  Matrix4 _globalTransform(SemanticsData data, Matrix4 parentTransform) {
    final transform = data.transform;
    if (transform == null) return parentTransform;
    return parentTransform.clone()..multiply(transform);
  }

  Rect _logicalSemanticsBounds(Rect bounds) {
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    final devicePixelRatio = view?.devicePixelRatio ?? 1;
    if (devicePixelRatio <= 0 || devicePixelRatio == 1) return bounds;
    return Rect.fromLTRB(
      bounds.left / devicePixelRatio,
      bounds.top / devicePixelRatio,
      bounds.right / devicePixelRatio,
      bounds.bottom / devicePixelRatio,
    );
  }

  Offset? _fallbackPoint(ElementTarget? target) {
    final point = target?.fallbackBounds;
    if (point == null) return null;
    return Offset(point.x, point.y);
  }

  List<_TapCandidate> _tapCandidates(
    _SemanticsMatch match,
    ElementTarget? target,
  ) {
    final nodes = _nodes().where((node) => !_isEmpty(node.data)).toList();
    final candidates = <_TapCandidate>[];
    final seen = <String>{};
    final untrustedSemanticBounds =
        _unlabelledSpecificTextMatch(match, target) &&
        target?.fallbackBounds == null &&
        !_trustedLabelledSemanticControl(match, target);
    final normalizedTargetText = _primaryTargetText(target);
    final shortOrAmbiguousTarget =
        normalizedTargetText.isNotEmpty && normalizedTargetText.length <= 8;
    final semanticBoundsUsable =
        !untrustedSemanticBounds &&
        match.bounds.isFinite &&
        !match.bounds.isEmpty &&
        _pointInViewport(match.bounds.center);
    final directTextMatch = _targetMatchesDirectSemanticText(match, target);
    final shouldSearchWidgetTree =
        target?.fallbackBounds != null ||
        !semanticBoundsUsable ||
        shortOrAmbiguousTarget;

    void add(
      Offset? position, {
      required String reason,
      required int priority,
      _SemanticsMatch? candidateMatch,
      Rect? dispatchBounds,
    }) {
      if (position == null || !_pointInViewport(position)) return;
      final key =
          '${position.dx.toStringAsFixed(1)}:${position.dy.toStringAsFixed(1)}';
      if (!seen.add(key)) return;
      candidates.add(
        _tapCandidate(
          position,
          reason: reason,
          priority: priority,
          match: candidateMatch,
          dispatchBounds: dispatchBounds,
        ),
      );
    }

    void addBounds(
      Rect bounds, {
      required String reason,
      required int priority,
      required _SemanticsMatch candidateMatch,
      bool centerOnly = false,
    }) {
      if (bounds.isEmpty || !bounds.isFinite) return;
      add(
        bounds.center,
        reason: '$reason.center',
        priority: priority,
        candidateMatch: candidateMatch,
        dispatchBounds: bounds,
      );
      if (centerOnly || bounds.width < 16 || bounds.height < 16) return;

      final x25 = _lerp(bounds.left, bounds.right, 0.25);
      final x50 = bounds.center.dx;
      final x75 = _lerp(bounds.left, bounds.right, 0.75);
      final y25 = _lerp(bounds.top, bounds.bottom, 0.25);
      final y50 = bounds.center.dy;
      final y75 = _lerp(bounds.top, bounds.bottom, 0.75);
      final role = _roleFor(candidateMatch.data);
      final allowTrailingInset =
          role == OperatorUiRole.input ||
          role == OperatorUiRole.checkbox ||
          role == OperatorUiRole.radio ||
          role == OperatorUiRole.switchRole ||
          (!candidateMatch.data.hasAction(SemanticsAction.tap) &&
              candidateMatch.children.isNotEmpty) ||
          bounds.width <= 180;
      add(
        Offset(x25, y50),
        reason: '$reason.left-inset',
        priority: priority - 1,
        candidateMatch: candidateMatch,
        dispatchBounds: bounds,
      );
      if (allowTrailingInset) {
        add(
          Offset(x75, y50),
          reason: '$reason.right-inset',
          priority: priority - 1,
          candidateMatch: candidateMatch,
          dispatchBounds: bounds,
        );
      }
      add(
        Offset(x50, y25),
        reason: '$reason.top-inset',
        priority: priority - 2,
        candidateMatch: candidateMatch,
        dispatchBounds: bounds,
      );
      add(
        Offset(x50, y75),
        reason: '$reason.bottom-inset',
        priority: priority - 2,
        candidateMatch: candidateMatch,
        dispatchBounds: bounds,
      );
    }

    add(
      _fallbackPoint(target),
      reason: 'target.fallbackPoint',
      priority: 100,
      candidateMatch: match,
    );

    if (!untrustedSemanticBounds) {
      addBounds(
        match.bounds,
        reason: 'match.${match.node.id}',
        priority:
            directTextMatch && !match.data.hasAction(SemanticsAction.tap)
                ? 112
                : 70,
        candidateMatch: match,
      );
    }

    if (shouldSearchWidgetTree) {
      for (final widgetCandidate in _widgetTapCandidates(
        match,
        target,
      ).take(3)) {
        addBounds(
          widgetCandidate.bounds,
          reason: widgetCandidate.reason,
          priority: widgetCandidate.priority,
          candidateMatch: match,
          centerOnly: widgetCandidate.centerOnly,
        );
      }
    }

    if (!untrustedSemanticBounds) {
      var priority = 64;
      for (final alternative in _tapAlternatives(match, nodes).take(4)) {
        addBounds(
          alternative.bounds,
          reason: 'related.${alternative.node.id}',
          priority: priority,
          candidateMatch: alternative,
          centerOnly: alternative.children.isEmpty,
        );
        priority -= 2;
      }
    }

    candidates.sort((a, b) {
      final score = _tapCandidateScore(b).compareTo(_tapCandidateScore(a));
      if (score != 0) return score;
      final priority = b.priority.compareTo(a.priority);
      if (priority != 0) return priority;
      final hit = _hitTestQuality(b.hit).compareTo(_hitTestQuality(a.hit));
      if (hit != 0) return hit;
      final area = _area(
        a.match?.bounds ?? Rect.zero,
      ).compareTo(_area(b.match?.bounds ?? Rect.zero));
      if (area != 0) return area;
      return a.reason.compareTo(b.reason);
    });
    return candidates.take(6).toList(growable: false);
  }

  int _tapCandidateScore(_TapCandidate candidate) {
    final hitQuality = _hitTestQuality(candidate.hit).clamp(-10, 12);
    return candidate.priority + hitQuality * 8;
  }

  List<_SemanticsMatch> _tapAlternatives(
    _SemanticsMatch match,
    List<_SemanticsMatch> nodes,
  ) {
    final alternatives = <_SemanticsMatch>[];
    final seen = <int>{match.node.id};

    void add(_SemanticsMatch candidate) {
      if (!seen.add(candidate.node.id)) return;
      if (candidate.bounds.isEmpty || !candidate.bounds.isFinite) return;
      if (candidate.data.flagsCollection.isHidden) return;
      alternatives.add(candidate);
    }

    void collectDescendants(_SemanticsMatch node) {
      for (final child in node.children) {
        if (_isSpatialActionMatch(match.bounds, child.bounds)) add(child);
        collectDescendants(child);
      }
    }

    collectDescendants(match);

    for (final node in nodes) {
      if (node.node.id == match.node.id) continue;
      if (!node.data.hasAction(SemanticsAction.tap)) continue;
      if (_isReasonableActionFallback(match, node)) add(node);
    }

    var parentId = match.parentId;
    while (parentId != null) {
      final parent =
          nodes.where((node) => node.node.id == parentId).firstOrNull;
      if (parent == null) break;
      if (!parent.data.hasAction(SemanticsAction.tap) ||
          _isReasonableActionFallback(match, parent)) {
        add(parent);
      }
      parentId = parent.parentId;
    }

    alternatives.sort((a, b) {
      final action = _tapActionRank(b).compareTo(_tapActionRank(a));
      if (action != 0) return action;
      final distance = _distance(
        a.bounds.center,
        match.bounds.center,
      ).compareTo(_distance(b.bounds.center, match.bounds.center));
      if (distance != 0) return distance;
      return _area(a.bounds).compareTo(_area(b.bounds));
    });
    return alternatives;
  }

  int _tapActionRank(_SemanticsMatch match) {
    if (match.data.hasAction(SemanticsAction.tap)) return 3;
    if (match.children.any(
      (child) => child.data.hasAction(SemanticsAction.tap),
    )) {
      return 2;
    }
    return 1;
  }

  List<_WidgetTapCandidate> _widgetTapCandidates(
    _SemanticsMatch match,
    ElementTarget? target,
  ) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const <_WidgetTapCandidate>[];
    final needles = <String>{
      for (final value in <String?>[
        target?.label,
        target?.text,
        target?.selector,
        match.description,
      ])
        if (_normalizedMatchText(value).isNotEmpty) _normalizedMatchText(value),
    };
    if (needles.isEmpty) return const <_WidgetTapCandidate>[];

    final candidates = <_WidgetTapCandidate>[];
    for (final element in _elementsDeepestFirst(root, maxElements: 3500)) {
      final bounds = _boundsForElement(element);
      if (bounds == null ||
          bounds.isEmpty ||
          !bounds.isFinite ||
          !_pointInViewport(bounds.center)) {
        continue;
      }
      final text = _normalizedMatchText(_widgetText(element, maxDepth: 4));
      if (text.isEmpty) continue;
      final exact = needles.any((needle) => text == needle);
      final fuzzy =
          !exact &&
          needles.any((needle) => _targetTextMatchesField(needle, text));
      if (!exact && !fuzzy) continue;
      final type = element.widget.runtimeType.toString();
      if (type.startsWith('DropdownMenuItem')) continue;
      final area = _area(bounds);
      if (!area.isFinite || area > 140000) continue;
      final textLikeWrapper =
          type == 'Text' ||
          type == 'RichText' ||
          type == 'ExcludeSemantics' ||
          type == 'Semantics';
      var priority = exact ? 96 : 86;
      if (_looksInteractiveWidgetType(type)) priority += 6;
      if (textLikeWrapper) priority += 2;
      if (area < 2600) priority -= 4;
      candidates.add(
        _WidgetTapCandidate(
          bounds: bounds,
          reason: 'widget.${type}.${exact ? 'exact' : 'fuzzy'}',
          priority: priority,
          centerOnly: textLikeWrapper,
        ),
      );
      if (candidates.length >= 12 &&
          candidates.any((candidate) => candidate.priority >= 100)) {
        break;
      }
    }

    candidates.sort((a, b) {
      final priority = b.priority.compareTo(a.priority);
      if (priority != 0) return priority;
      return _area(a.bounds).compareTo(_area(b.bounds));
    });
    return candidates;
  }

  String _widgetText(Element element, {required int maxDepth}) {
    final parts = <String>[];

    void collect(Element current, int depth) {
      if (depth > maxDepth || parts.length > 20) return;
      final widget = current.widget;
      if (widget is Text) {
        final data = widget.data ?? widget.textSpan?.toPlainText();
        if (data != null && data.trim().isNotEmpty) parts.add(data);
      } else if (widget is RichText) {
        final data = widget.text.toPlainText();
        if (data.trim().isNotEmpty) parts.add(data);
      }
      current.visitChildren((child) => collect(child, depth + 1));
    }

    collect(element, 0);
    return parts.join(' ');
  }

  bool _looksInteractiveWidgetType(String type) {
    return type.contains('Button') ||
        type.contains('InkWell') ||
        type.contains('GestureDetector') ||
        type.contains('CupertinoButton') ||
        type.contains('ListTile');
  }

  bool _isNonInputTapTarget(_SemanticsMatch match, ElementTarget? target) {
    if (target?.role == OperatorUiRole.input.name) return false;
    return _roleFor(match.data) != OperatorUiRole.input;
  }

  bool _unlabelledSpecificTextMatch(
    _SemanticsMatch match,
    ElementTarget? target,
  ) {
    final requestedText = <String?>[
      target?.label,
      target?.text,
      target?.selector,
      target?.listContext?.itemText,
    ].any((value) => _normalizedMatchText(value).isNotEmpty);
    if (!requestedText) return false;
    return match.data.identifier.trim().isEmpty &&
        match.data.label.trim().isEmpty &&
        match.data.value.trim().isEmpty;
  }

  bool _trustedSmallSemanticControl(
    _SemanticsMatch match,
    ElementTarget? target,
  ) {
    if (!match.data.hasAction(SemanticsAction.tap)) return false;
    final role = _roleFor(match.data);
    if (role != OperatorUiRole.button && role != OperatorUiRole.link) {
      return false;
    }
    final bounds = match.bounds;
    if (!_smallControlBounds(bounds)) return false;
    final targetTexts =
        <String?>[
          target?.label,
          target?.text,
          target?.selector,
          target?.listContext?.itemText,
        ].map(_normalizedMatchText).where((value) => value.isNotEmpty).toSet();
    if (targetTexts.isEmpty) return false;
    final parentTexts = _parentSemanticTexts(match);
    if (parentTexts.isEmpty) return false;
    return targetTexts.any(parentTexts.contains);
  }

  bool _trustedLabelledSemanticControl(
    _SemanticsMatch match,
    ElementTarget? target,
  ) {
    return _trustedSmallSemanticControl(match, target) ||
        _trustedSameControlSemanticTransfer(match, target);
  }

  bool _trustedSameControlSemanticTransfer(
    _SemanticsMatch match,
    ElementTarget? target,
  ) {
    if (!_unlabelledSpecificTextMatch(match, target)) return false;
    if (!match.data.hasAction(SemanticsAction.tap)) return false;
    if (_roleFor(match.data) == OperatorUiRole.input) return false;
    if (!_safeTransferredActionBounds(match.bounds)) return false;

    final nodes = _nodes().where((node) => !_isEmpty(node.data)).toList();
    final labelledMatches =
        nodes
            .where(
              (node) =>
                  node.node.id != match.node.id &&
                  _targetMatchesDirectSemanticText(node, target),
            )
            .toList();
    if (labelledMatches.isEmpty) return false;

    return labelledMatches.any((labelled) {
      final related = _semanticFamilyRelated(labelled, match, nodes);
      if (related) {
        return _sameControlGeometry(labelled.bounds, match.bounds);
      }
      return _nearExactControlGeometry(labelled.bounds, match.bounds);
    });
  }

  bool _safeTransferredActionBounds(Rect bounds) {
    if (bounds.isEmpty || !bounds.isFinite) return false;
    if (!_pointInViewport(bounds.center)) return false;
    final area = _area(bounds);
    if (!area.isFinite || area <= 0) return false;
    final viewport = _viewportSize();
    if (viewport == null) return area <= 48000;
    final viewportArea = viewport.width * viewport.height;
    if (viewportArea <= 0) return area <= 48000;
    if (area / viewportArea > 0.25) return false;
    if (bounds.width / viewport.width > 0.96 &&
        bounds.height / viewport.height > 0.25) {
      return false;
    }
    return true;
  }

  bool _semanticFamilyRelated(
    _SemanticsMatch a,
    _SemanticsMatch b,
    List<_SemanticsMatch> nodes,
  ) {
    if (a.node.id == b.node.id) return true;
    if (a.parentId != null && a.parentId == b.parentId) return true;
    if (a.parentId == b.node.id || b.parentId == a.node.id) return true;

    final byId = <int, _SemanticsMatch>{
      for (final node in nodes) node.node.id: node,
    };
    bool isAncestor(_SemanticsMatch ancestor, _SemanticsMatch child) {
      var parentId = child.parentId;
      while (parentId != null) {
        if (parentId == ancestor.node.id) return true;
        parentId = byId[parentId]?.parentId;
      }
      return false;
    }

    return isAncestor(a, b) || isAncestor(b, a);
  }

  bool _sameControlGeometry(Rect labelledBounds, Rect actionBounds) {
    return _controlGeometryMatches(
      labelledBounds,
      actionBounds,
      overlapThreshold: 0.72,
      dimensionRatioThreshold: 0.68,
    );
  }

  bool _nearExactControlGeometry(Rect labelledBounds, Rect actionBounds) {
    return _controlGeometryMatches(
      labelledBounds,
      actionBounds,
      overlapThreshold: 0.9,
      dimensionRatioThreshold: 0.85,
    );
  }

  bool _controlGeometryMatches(
    Rect labelledBounds,
    Rect actionBounds, {
    required double overlapThreshold,
    required double dimensionRatioThreshold,
  }) {
    if (labelledBounds.isEmpty ||
        actionBounds.isEmpty ||
        !labelledBounds.isFinite ||
        !actionBounds.isFinite) {
      return false;
    }
    final labelledArea = _area(labelledBounds);
    final actionArea = _area(actionBounds);
    if (!labelledArea.isFinite ||
        !actionArea.isFinite ||
        labelledArea <= 0 ||
        actionArea <= 0) {
      return false;
    }

    final overlap = labelledBounds.intersect(actionBounds);
    if (!overlap.isEmpty && overlap.isFinite) {
      final overlapArea = overlap.width * overlap.height;
      final coverage = overlapArea / math.max(labelledArea, actionArea);
      if (coverage >= overlapThreshold) return true;
    }

    final widthRatio =
        math.min(labelledBounds.width, actionBounds.width) /
        math.max(labelledBounds.width, actionBounds.width);
    final heightRatio =
        math.min(labelledBounds.height, actionBounds.height) /
        math.max(labelledBounds.height, actionBounds.height);
    final centerTolerance = math.max(
      10.0,
      math.sqrt(math.max(labelledArea, actionArea)) * 0.08,
    );
    return widthRatio >= dimensionRatioThreshold &&
        heightRatio >= dimensionRatioThreshold &&
        _distance(labelledBounds.center, actionBounds.center) <=
            centerTolerance;
  }

  bool _smallControlBounds(Rect bounds) =>
      bounds.isFinite &&
      !bounds.isEmpty &&
      bounds.width <= 96 &&
      bounds.height <= 96 &&
      _area(bounds) <= 9216;

  bool _leafControlBounds(Rect bounds) =>
      bounds.isFinite &&
      !bounds.isEmpty &&
      bounds.width <= 480 &&
      bounds.height <= 64 &&
      _area(bounds) <= 26000;

  bool _singleDispatchTapTarget(_SemanticsMatch match, ElementTarget? target) {
    if (!_smallControlBounds(match.bounds)) return false;
    final role = _roleFor(match.data);
    final leafRole =
        role == OperatorUiRole.button ||
        role == OperatorUiRole.link ||
        role == OperatorUiRole.checkbox ||
        role == OperatorUiRole.radio ||
        role == OperatorUiRole.switchRole;
    if (!leafRole) return false;
    if (_targetMatchesDirectSemanticText(match, target)) return true;
    final primary = _primaryTargetText(target);
    return primary.isNotEmpty && primary.length <= 2;
  }

  Set<String> _parentSemanticTexts(_SemanticsMatch match) {
    final parentId = match.parentId;
    if (parentId == null) return const <String>{};
    final parent =
        _nodes().where((node) => node.node.id == parentId).firstOrNull;
    if (parent == null || !_isReasonableActionFallback(parent, match)) {
      return const <String>{};
    }
    return <String>{
      parent.data.identifier,
      parent.data.label,
      parent.data.value,
      parent.data.hint,
      parent.data.tooltip,
    }.map(_normalizedMatchText).where((value) => value.isNotEmpty).toSet();
  }

  bool _snapshotShowsTextEditMenu(AppSnapshot snapshot) {
    const editMenuTexts = <String>{
      'paste',
      'select all',
      'copy',
      'cut',
      'look up',
      'replace',
    };
    return snapshot.ui.elements.any((element) {
      if (element.visible == false) return false;
      final value = element.label ?? element.text ?? element.value;
      final text = _normalizedMatchText(value is String ? value : null);
      return editMenuTexts.contains(text);
    });
  }

  Future<ActionResult?> _tapInterruptionFromSettledSnapshot({
    required ActionCommand command,
    required _SemanticsMatch? match,
    required AppSnapshot beforeSnapshot,
    required AppSnapshot afterSnapshot,
    required List<VerificationEvidence> evidence,
    required _TapCandidate? candidate,
    required String actuator,
  }) async {
    final immediate = _tapInterruptionFromUnexpectedDialog(
      command: command,
      match: match,
      beforeSnapshot: beforeSnapshot,
      afterSnapshot: afterSnapshot,
      evidence: evidence,
      candidate: candidate,
      actuator: actuator,
    );
    if (immediate != null) return immediate;

    if (_routeChanged(beforeSnapshot, afterSnapshot)) {
      evidence.add(
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'tap.dialog_check.delegated_to_route_settlement',
          ok: true,
          detail:
              'route changed ${beforeSnapshot.route.current.path ?? beforeSnapshot.route.current.name ?? '<unknown>'} -> '
              '${afterSnapshot.route.current.path ?? afterSnapshot.route.current.name ?? '<unknown>'}; '
              'skipped delayed duplicate dialog snapshot because bridge route/UI settling owns destination readiness',
        ),
      );
      return null;
    }

    await Future<void>.delayed(const Duration(milliseconds: 180));
    final settledSnapshot = await _dialogCheckSnapshot();
    if (settledSnapshot.snapshotId == afterSnapshot.snapshotId) return null;
    return _tapInterruptionFromUnexpectedDialog(
      command: command,
      match: match,
      beforeSnapshot: beforeSnapshot,
      afterSnapshot: settledSnapshot,
      evidence: evidence,
      candidate: candidate,
      actuator: actuator,
    );
  }

  ActionResult? _tapInterruptionFromUnexpectedDialog({
    required ActionCommand command,
    required _SemanticsMatch? match,
    required AppSnapshot beforeSnapshot,
    required AppSnapshot afterSnapshot,
    required List<VerificationEvidence> evidence,
    required _TapCandidate? candidate,
    required String actuator,
  }) {
    if (match != null && !_isNonInputTapTarget(match, command.target)) {
      return null;
    }
    if (!_routeAllowsDialogInterruption(beforeSnapshot, afterSnapshot)) {
      return null;
    }

    final beforeTexts = _dialogVisibleTexts(beforeSnapshot);
    final afterTexts = _dialogVisibleTexts(afterSnapshot);
    if (afterTexts.isEmpty || _sameTextSet(beforeTexts, afterTexts)) {
      return null;
    }
    final isPermissionPrompt = afterTexts.any(_looksLikePermissionPromptText);
    if (isPermissionPrompt) {
      if (_targetLooksPermissionDialogAction(command.target) ||
          _purposeLooksDialogRelated(command.purpose, afterTexts)) {
        return null;
      }
    } else if (_targetMatchesAnyText(command.target, afterTexts) ||
        _purposeLooksDialogRelated(command.purpose, afterTexts)) {
      return null;
    }

    final type =
        isPermissionPrompt
            ? 'tap_blocked_by_permission_prompt'
            : 'tap_interrupted_by_dialog';
    final message =
        isPermissionPrompt
            ? 'Tap changed the app, but a permission dialog appeared before Operator could verify the intended target effect'
            : 'Tap changed the app, but an unrelated dialog appeared before Operator could verify the intended target effect';
    final detail =
        'route=${afterSnapshot.route.current.path}; '
        'dialogTexts=${afterTexts.take(6).join(' | ')}';
    return ActionResult(
      ok: false,
      action: command,
      error: ActionError(type: type, message: message, retryable: true),
      evidence: <VerificationEvidence>[
        ...evidence,
        VerificationEvidence(
          source: OperatorVerificationSource.action,
          condition: 'tap.$type',
          ok: false,
          detail: [
            if (candidate != null)
              _tapAttemptEvidence(
                actuator: actuator,
                candidate: candidate,
                ok: false,
                detail: 'rejected tap verification because a dialog appeared',
              ).detail,
            detail,
          ].whereType<String>().where((value) => value.isNotEmpty).join('; '),
        ),
      ],
    );
  }

  bool _routeAllowsDialogInterruption(AppSnapshot before, AppSnapshot after) {
    if (before.route.current.path == after.route.current.path &&
        before.route.current.name == after.route.current.name) {
      return true;
    }
    final afterPath = after.route.current.path?.trim();
    final afterName = after.route.current.name?.trim();
    final afterClass = after.route.current.screenClass?.toLowerCase() ?? '';
    return afterPath == null ||
        afterPath.isEmpty ||
        afterName == null ||
        afterName.isEmpty ||
        afterClass.contains('dialog') ||
        afterClass.contains('popup') ||
        afterClass.contains('modal');
  }

  List<String> _dialogVisibleTexts(AppSnapshot snapshot) {
    final elements = snapshot.ui.elements;
    final hasDialogSignal =
        snapshot.dialogs.isNotEmpty ||
        elements.any(
          (element) =>
              element.role == OperatorUiRole.dialog ||
              _normalizedElementText(element) == 'general_dialog' ||
              _looksLikePermissionPromptText(
                _elementDisplayText(element) ?? '',
              ),
        );
    if (!hasDialogSignal) return const <String>[];
    final texts = elements
        .where((element) => element.visible != false)
        .map(_elementDisplayText)
        .whereType<String>()
        .map(_clean)
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    return texts;
  }

  String? _elementDisplayText(UiElement element) {
    for (final value in <Object?>[element.label, element.text, element.value]) {
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  String _normalizedElementText(UiElement element) =>
      _normalizedMatchText(_elementDisplayText(element));

  bool _sameTextSet(List<String> before, List<String> after) {
    if (before.length != after.length) return false;
    final beforeSet = before.map(_normalizedMatchText).toSet();
    final afterSet = after.map(_normalizedMatchText).toSet();
    return beforeSet.length == afterSet.length &&
        beforeSet.containsAll(afterSet);
  }

  bool _targetMatchesAnyText(ElementTarget? target, List<String> texts) {
    final targetTexts = <String?>[
          target?.id,
          target?.label,
          target?.text,
          target?.selector,
          target?.listContext?.itemText,
        ]
        .map(_normalizedMatchText)
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (targetTexts.isEmpty) return false;
    final haystack = texts.map(_normalizedMatchText).join(' ');
    return targetTexts.any(
      (needle) =>
          texts.any((text) => _normalizedMatchText(text) == needle) ||
          haystack.contains(needle),
    );
  }

  bool _targetLooksPermissionDialogAction(ElementTarget? target) {
    final targetText = <String?>[
      target?.id,
      target?.label,
      target?.text,
      target?.selector,
      target?.listContext?.itemText,
    ].map(_normalizedMatchText).join(' ');
    return targetText.contains('abbrechen') ||
        targetText.contains('cancel') ||
        targetText.contains('einstellungen') ||
        targetText.contains('settings') ||
        targetText.contains('permission') ||
        targetText.contains('berechtigung') ||
        targetText.contains('allow') ||
        targetText.contains('deny');
  }

  bool _purposeLooksDialogRelated(String? purpose, List<String> texts) {
    final normalizedPurpose = _normalizedMatchText(purpose);
    if (normalizedPurpose.isEmpty) return false;
    if (normalizedPurpose.contains('dialog') ||
        normalizedPurpose.contains('modal') ||
        normalizedPurpose.contains('confirm') ||
        normalizedPurpose.contains('permission')) {
      return true;
    }
    final haystack = texts.map(_normalizedMatchText).join(' ');
    return normalizedPurpose
        .split(RegExp(r'\s+|_+|-+'))
        .where((part) => part.length >= 4)
        .any(haystack.contains);
  }

  bool _looksLikePermissionPromptText(String value) {
    final text = value.toLowerCase();
    return text.contains('berechtigung') ||
        text.contains('permission') ||
        text.contains('einstellungen öffnen') ||
        text.contains('settings öffnen') ||
        text.contains('open settings');
  }

  _TapCandidate _tapCandidate(
    Offset position, {
    required String reason,
    required int priority,
    _SemanticsMatch? match,
    Rect? dispatchBounds,
  }) {
    return _TapCandidate(
      position: position,
      reason: reason,
      priority: priority,
      match: match,
      dispatchBounds: dispatchBounds,
      hit: _hitTestAt(position),
    );
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  bool _targetMatchesDirectSemanticText(
    _SemanticsMatch match,
    ElementTarget? target,
  ) {
    final targets =
        <String?>[
          target?.label,
          target?.text,
          target?.selector,
          target?.listContext?.itemText,
        ].map(_normalizedMatchText).where((value) => value.isNotEmpty).toSet();
    if (targets.isEmpty) return false;
    final directTexts =
        <String>[
          _uiElementId(match),
          match.data.identifier,
          match.data.label,
          match.data.value,
        ].map(_normalizedMatchText).where((value) => value.isNotEmpty).toSet();
    return targets.any(
      (target) => directTexts.any(
        (field) => _targetTextMatchesField(target, field, allowContains: false),
      ),
    );
  }

  bool _largeExactSemanticActionProxy(
    _SemanticsMatch match,
    ElementTarget? target,
  ) {
    if (!_targetMatchesDirectSemanticText(match, target)) return false;
    final viewport = _viewportSize();
    if (viewport == null || viewport.width <= 0 || viewport.height <= 0) {
      return false;
    }
    final bounds = match.bounds;
    if (!bounds.isFinite || bounds.isEmpty) return false;
    final viewportArea = viewport.width * viewport.height;
    if (viewportArea <= 0) return false;
    final widthRatio = bounds.width / viewport.width;
    final heightRatio = bounds.height / viewport.height;
    final areaRatio = _area(bounds) / viewportArea;
    return widthRatio >= 0.75 && heightRatio >= 0.45 && areaRatio >= 0.35;
  }

  Size? _viewportSize() {
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null || view.devicePixelRatio <= 0) return null;
    final viewport = view.physicalSize / view.devicePixelRatio;
    if (viewport.width <= 0 || viewport.height <= 0) return null;
    return viewport;
  }

  bool _pointInViewport(Offset position) {
    if (position.dx.isNaN || position.dy.isNaN) return false;
    if (position.dx < 0 || position.dy < 0) return false;
    final viewport = _viewportSize();
    if (viewport == null) return true;
    return position.dx <= viewport.width && position.dy <= viewport.height;
  }

  _HitTestSnapshot _hitTestAt(Offset position) {
    final result = HitTestResult();
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
      if (view == null) {
        return _HitTestSnapshot(
          position: position,
          path: const <String>[],
          targets: const <HitTestTarget>[],
          error: 'no FlutterView available for hit test',
        );
      }
      RendererBinding.instance.hitTestInView(result, position, view.viewId);
      final path = result.path
          .map((entry) => entry.target.runtimeType.toString())
          .where((name) => name.trim().isNotEmpty)
          .take(12)
          .toList(growable: false);
      final targets = result.path
          .map((entry) => entry.target)
          .toList(growable: false);
      return _HitTestSnapshot(position: position, path: path, targets: targets);
    } catch (error) {
      return _HitTestSnapshot(
        position: position,
        path: const <String>[],
        targets: const <HitTestTarget>[],
        error: error.toString(),
      );
    }
  }

  bool _hitTestBelongsTo(RenderObject owner, _HitTestSnapshot hit) {
    for (final target in hit.targets.whereType<RenderObject>()) {
      RenderObject? current = target;
      while (current != null) {
        if (identical(current, owner)) return true;
        final parent = current.parent;
        current = parent is RenderObject ? parent : null;
      }
    }
    return false;
  }

  int _hitTestQuality(_HitTestSnapshot hit) {
    if (hit.error != null) return -10;
    if (hit.path.isEmpty) return 0;
    var score = 1;
    for (final entry in hit.path) {
      if (entry.contains('RenderSemanticsGestureHandler') ||
          entry.contains('RenderPointerListener') ||
          entry.contains('RenderMouseRegion') ||
          entry.contains('RenderInkFeatures') ||
          entry.contains('RenderEditable')) {
        score += 4;
      } else if (entry.contains('RenderAbsorbPointer') ||
          entry.contains('RenderIgnorePointer')) {
        score -= 6;
      }
    }
    return score;
  }

  bool _hasActionableTapCandidate(List<_TapCandidate> candidates) {
    return candidates.any((candidate) {
      if (candidate.match?.data.hasAction(SemanticsAction.tap) ?? false) {
        return true;
      }
      return _hitTestQuality(candidate.hit) >= 5;
    });
  }

  VerificationEvidence _tapAttemptEvidence({
    required String actuator,
    required _TapCandidate candidate,
    required bool ok,
    required String detail,
  }) {
    final target = candidate.match?.description ?? '<coordinate>';
    final hitPath =
        candidate.hit.path.isEmpty ? '<empty>' : candidate.hit.path.join(' > ');
    final error = candidate.hit.error;
    final parts = <String>[
      detail,
      'target=$target',
      'point=${_formatOffset(candidate.position)}',
      'reason=${candidate.reason}',
      'hit=$hitPath',
      if (error != null) 'hitError=$error',
    ];
    final phase = ok ? 'verified' : 'attempt';
    return VerificationEvidence(
      source: OperatorVerificationSource.action,
      condition: 'tap.$actuator.$phase.${candidate.reason}',
      ok: ok,
      detail: parts.join('; '),
    );
  }

  bool _coordinateOnlyTarget(ElementTarget? target) {
    if (target?.fallbackBounds == null) return false;
    return <String?>[
          target?.id,
          target?.role,
          target?.label,
          target?.text,
          target?.selector,
          target?.listContext?.listId,
          target?.listContext?.itemText,
        ].every((value) => value == null || value.trim().isEmpty) &&
        target?.listContext?.itemIndex == null;
  }

  double _area(Rect bounds) {
    if (bounds.isEmpty || !bounds.isFinite) return double.infinity;
    return bounds.width * bounds.height;
  }

  bool _isSpatialActionMatch(Rect labelledBounds, Rect actionBounds) {
    if (labelledBounds.isEmpty ||
        actionBounds.isEmpty ||
        !labelledBounds.isFinite ||
        !actionBounds.isFinite) {
      return false;
    }
    if (labelledBounds.contains(actionBounds.center) ||
        actionBounds.contains(labelledBounds.center)) {
      return true;
    }
    final overlap = labelledBounds.intersect(actionBounds);
    if (overlap.isEmpty || !overlap.isFinite) return false;
    final overlapArea = overlap.width * overlap.height;
    final actionArea = actionBounds.width * actionBounds.height;
    final labelledArea = labelledBounds.width * labelledBounds.height;
    if (actionArea <= 0 || labelledArea <= 0) return false;
    return overlapArea / math.min(actionArea, labelledArea) >= 0.5;
  }

  double _distance(Offset a, Offset b) => (a - b).distance;

  String _formatOffset(Offset offset) =>
      '(${offset.dx.toStringAsFixed(1)}, ${offset.dy.toStringAsFixed(1)})';

  String _formatRect(Rect rect) =>
      '(${rect.left.toStringAsFixed(1)}, ${rect.top.toStringAsFixed(1)}, '
      '${rect.width.toStringAsFixed(1)}x${rect.height.toStringAsFixed(1)})';

  void _dispatchPointerTap(
    Offset position, {
    ui.PointerDeviceKind kind = ui.PointerDeviceKind.touch,
  }) {
    final binding = GestureBinding.instance;
    final pointer = _syntheticPointerCounter++;
    binding.handlePointerEvent(
      PointerAddedEvent(pointer: pointer, position: position, kind: kind),
    );
    binding.handlePointerEvent(
      PointerDownEvent(
        pointer: pointer,
        position: position,
        kind: kind,
        buttons: kPrimaryButton,
      ),
    );
    binding.handlePointerEvent(
      PointerUpEvent(pointer: pointer, position: position, kind: kind),
    );
    binding.handlePointerEvent(
      PointerRemovedEvent(pointer: pointer, position: position, kind: kind),
    );
  }

  void _dispatchPointerHover(Offset position) {
    _positionSyntheticMouse(position);
  }

  void _positionSyntheticMouse(Offset position) {
    final binding = GestureBinding.instance;
    if (!_syntheticMousePointerAdded) {
      binding.handlePointerEvent(
        PointerAddedEvent(
          pointer: _syntheticMousePointer,
          position: position,
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
      _syntheticMousePointerAdded = true;
      _syntheticMousePosition = position;
    }
    binding.handlePointerEvent(
      PointerHoverEvent(
        pointer: _syntheticMousePointer,
        position: position,
        delta: position - _syntheticMousePosition,
        kind: ui.PointerDeviceKind.mouse,
      ),
    );
    _syntheticMousePosition = position;
  }

  void _removeSyntheticMousePointer() {
    if (!_syntheticMousePointerAdded) return;
    try {
      GestureBinding.instance.handlePointerEvent(
        PointerRemovedEvent(
          pointer: _syntheticMousePointer,
          position: _syntheticMousePosition,
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
    } catch (_) {
      // Runtime teardown can occur after Flutter has detached its binding.
    }
    _syntheticMousePointerAdded = false;
  }

  void _dispatchPointerGesture({
    required Offset start,
    required Offset end,
    required ui.PointerDeviceKind kind,
    required Duration duration,
  }) {
    final binding = GestureBinding.instance;
    final isMouse = kind == ui.PointerDeviceKind.mouse;
    final pointer =
        isMouse ? _syntheticMousePointer : _syntheticPointerCounter++;
    const steps = 8;
    if (isMouse) {
      _positionSyntheticMouse(start);
    } else {
      binding.handlePointerEvent(
        PointerAddedEvent(
          pointer: pointer,
          position: start,
          kind: kind,
          timeStamp: Duration.zero,
        ),
      );
    }
    binding.handlePointerEvent(
      PointerDownEvent(
        pointer: pointer,
        position: start,
        kind: kind,
        buttons: kPrimaryButton,
        timeStamp: Duration.zero,
      ),
    );
    var previous = start;
    for (var step = 1; step <= steps; step += 1) {
      final fraction = step / steps;
      final position = Offset.lerp(start, end, fraction)!;
      binding.handlePointerEvent(
        PointerMoveEvent(
          pointer: pointer,
          position: position,
          delta: position - previous,
          kind: kind,
          buttons: kPrimaryButton,
          timeStamp: duration * fraction,
        ),
      );
      previous = position;
      if (isMouse) _syntheticMousePosition = position;
    }
    binding.handlePointerEvent(
      PointerUpEvent(
        pointer: pointer,
        position: end,
        kind: kind,
        timeStamp: duration,
      ),
    );
    if (!isMouse) {
      binding.handlePointerEvent(
        PointerRemovedEvent(
          pointer: pointer,
          position: end,
          kind: kind,
          timeStamp: duration,
        ),
      );
    }
  }

  Offset _primaryViewportCenter() {
    final viewport = _viewportSize();
    if (viewport == null) return Offset.zero;
    return Offset(viewport.width / 2, viewport.height / 2);
  }

  Future<void> _settleAfterUserAction({bool refreshRoute = true}) async {
    try {
      WidgetsBinding.instance.scheduleFrame();
    } catch (_) {
      // Some non-widget test/runtime contexts have no binding yet.
    }
    await Future<void>.delayed(_userActionSettleDelay);
    if (refreshRoute) captureRouteFromElementTree();
  }

  Future<bool> _waitForInteractionChange(
    String before, {
    Duration timeout = const Duration(milliseconds: 900),
    bool includeAmbientSignals = true,
    bool includeStateSignals = true,
    bool refreshRoute = true,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final pollCycleMs =
        _userActionSettleDelay.inMilliseconds +
        _interactionPollDelay.inMilliseconds;
    final maxChecks = math.max(
      1,
      (timeout.inMilliseconds / pollCycleMs).ceil() + 1,
    );
    var refreshedRoute = false;
    var checked = false;
    var checks = 0;
    while ((!checked || DateTime.now().isBefore(deadline)) &&
        checks < maxChecks) {
      checks += 1;
      final shouldRefreshRoute = refreshRoute && !refreshedRoute;
      await _settleAfterUserAction(refreshRoute: shouldRefreshRoute);
      refreshedRoute = refreshedRoute || shouldRefreshRoute;
      checked = true;
      if (await _interactionFingerprint(
            includeAmbientSignals: includeAmbientSignals,
            includeStateSignals: includeStateSignals,
          ) !=
          before) {
        return true;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      final delay =
          remaining < _interactionPollDelay ? remaining : _interactionPollDelay;
      await Future<void>.delayed(delay);
    }
    return false;
  }

  Future<String> _interactionFingerprint({
    bool includeAmbientSignals = true,
    bool includeStateSignals = true,
  }) async {
    final snapshot = await _interactionSnapshot();
    final route = snapshot.route.current;
    return jsonEncode(<String, Object?>{
      'route': <String, Object?>{'name': route.name, 'path': route.path},
      'focusedElementId': snapshot.ui.focusedElementId,
      'ui': snapshot.ui.elements
          .map(
            (element) => <String, Object?>{
              'id': element.id,
              'role': element.role?.name,
              'label': element.label,
              'text': element.text,
              'value': element.value,
              'selected': element.selected,
              'checked': element.checked,
              'enabled': element.enabled,
              'visible': element.visible,
              'actions': element.actions,
              'bounds':
                  element.bounds == null
                      ? null
                      : <num>[
                        element.bounds!.x.round(),
                        element.bounds!.y.round(),
                        element.bounds!.width.round(),
                        element.bounds!.height.round(),
                      ],
            },
          )
          .toList(growable: false),
    });
  }

  Future<AppSnapshot> _interactionSnapshot() => operator.getSnapshot(
    refreshVisual: false,
    refreshProviders: false,
    refreshUiProviders: true,
    issueActionTargets: false,
  );

  Future<AppSnapshot> _postInteractionSnapshot() => operator.getSnapshot(
    refreshVisual: false,
    refreshProviders: false,
    refreshUiProviders: true,
    issueActionTargets: false,
  );

  Future<AppSnapshot> _dialogCheckSnapshot() => operator.getSnapshot(
    refreshVisual: false,
    refreshProviders: false,
    refreshUiProviders: false,
    issueActionTargets: false,
  );

  Future<ActionResult?> _scrollViaFlutterWidgetTree(
    ActionCommand command,
    String? direction,
  ) async {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;

    final candidates = <_ScrollCandidate>[];
    void walk(Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        final position = state.position;
        final vertical = direction == 'up' || direction == 'down';
        if (position.axis != (vertical ? Axis.vertical : Axis.horizontal)) {
          element.visitChildren(walk);
          return;
        }
        final bounds = _boundsForElement(element);
        var score = 1;
        if (bounds != null && bounds.isFinite && !bounds.isEmpty) {
          score += bounds.width.round() + bounds.height.round();
        }
        candidates.add(
          _ScrollCandidate(position: position, score: score, element: element),
        );
      }
      element.visitChildren(walk);
    }

    walk(root);
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.score.compareTo(a.score));

    final position = candidates.first.position;
    if (!position.hasContentDimensions || !position.hasPixels) {
      return null;
    }

    final delta = _scrollAmount(command, position);
    if (!delta.isFinite || delta < 0)
      return ActionResult(
        ok: false,
        action: command,
        data: const {'operationPhase': 'zero_dispatch'},
        error: const ActionError(
          type: 'invalid_scroll_amount',
          message: 'Scroll amount must be finite and non-negative',
        ),
      );
    final current = position.pixels;
    final reversed =
        position.axisDirection == AxisDirection.up ||
        position.axisDirection == AxisDirection.left;
    final sign =
        ((direction == 'down' || direction == 'right') ? 1 : -1) *
        (reversed ? -1 : 1);
    final requested = current + sign * delta;
    final next = math.min(
      position.maxScrollExtent,
      math.max(position.minScrollExtent, requested),
    );

    final boundary =
        sign > 0
            ? current >= position.maxScrollExtent
            : current <= position.minScrollExtent;
    if (next != current) position.jumpTo(next);
    await _settleAfterUserAction();
    final owner = candidates.first.element;
    if (!owner.mounted ||
        owner is! StatefulElement ||
        owner.state is! ScrollableState ||
        !identical((owner.state as ScrollableState).position, position)) {
      return ActionResult(
        ok: false,
        action: command,
        data: const {'operationPhase': 'dispatched_unknown_effect'},
        error: const ActionError(
          type: 'scroll_owner_changed',
          message:
              'The default list was replaced before its final offset could be read',
        ),
      );
    }
    final after = position.pixels;
    final moved = after - current;
    final outcome =
        moved == 0
            ? (boundary ? 'boundary' : 'no_progress')
            : moved * sign > 0
            ? 'moved'
            : 'wrong_direction';
    return ActionResult(
      ok: outcome != 'wrong_direction',
      action: command,
      message:
          outcome == 'boundary'
              ? 'The default list was already at the $direction boundary; nothing moved.'
              : 'Default list offset $current -> $after ($outcome).',
      data: {
        'operationPhase': 'settled',
        'scroll': {
          'ownerId': 'scroll-position-${position.hashCode}',
          'direction': direction,
          'before': current,
          'after': after,
          'delta': moved,
          'outcome': outcome,
        },
      },
      error:
          outcome == 'wrong_direction'
              ? const ActionError(
                type: 'scroll_wrong_direction',
                message:
                    'Observed movement contradicted the requested direction',
              )
              : null,
    );
  }

  double _scrollAmount(ActionCommand command, ScrollPosition position) {
    final amount = command.amount?.trim().toLowerCase();
    final viewport =
        position.viewportDimension.isFinite && position.viewportDimension > 0
            ? position.viewportDimension
            : 360.0;
    if (amount == 'small') return viewport * 0.35;
    if (amount == 'large') return viewport * 0.9;
    if (amount == 'page') return viewport * 0.75;
    return double.tryParse(amount ?? '') ?? viewport * 0.75;
  }

  ElementTarget _targetForFormField(FormFieldPatch field) => ElementTarget(
    id: field.id,
    label: field.name,
    text: field.name ?? field.id,
    role: OperatorUiRole.input.name,
  );

  bool _stronglyMatchesFormField(_SemanticsMatch? match, FormFieldPatch field) {
    if (match == null) return false;
    final needles =
        <String?>[field.id, field.name]
            .whereType<String>()
            .map((value) => _clean(value).toLowerCase())
            .where((value) => value.isNotEmpty)
            .toList();
    if (needles.isEmpty) return false;
    final fields =
        <String>[
          match.data.identifier,
          match.data.label,
          match.data.value,
          match.data.hint,
          match.data.tooltip,
        ].map((value) => _clean(value).toLowerCase()).toList();
    final haystack = fields.join(' ');
    return needles.any(
      (needle) =>
          fields.any((field) => field == needle) || haystack.contains(needle),
    );
  }

  bool _setTextViaFlutterWidgetTree(
    ElementTarget? target,
    _SemanticsMatch? match,
    String text, {
    bool clearFirst = true,
  }) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return false;
    final candidates = <_TextInputCandidate>[];

    void walk(Element element) {
      final widget = element.widget;
      if (widget is TextField) {
        final editable = _findEditableText(element);
        final controller = widget.controller ?? editable?.controller;
        final onChanged = widget.onChanged ?? editable?.onChanged;
        final bounds = _boundsForElement(element);
        final score = _scoreTextField(
          decoration: widget.decoration,
          target: target,
          semantics: match,
          bounds: bounds,
        );
        if (controller != null && score > 0) {
          candidates.add(
            _TextInputCandidate(
              controller: controller,
              onChanged: onChanged,
              score: score,
            ),
          );
        }
      }
      element.visitChildren(walk);
    }

    walk(root);
    if (candidates.isEmpty) return false;
    candidates.sort((a, b) => b.score.compareTo(a.score));
    final selected = candidates.first;
    final nextValue = _typedEditingValue(
      selected.controller.value,
      text,
      clearFirst: clearFirst,
    );
    selected.controller.value = nextValue;
    selected.onChanged?.call(nextValue.text);
    return true;
  }

  TextEditingValue _typedEditingValue(
    TextEditingValue current,
    String text, {
    required bool clearFirst,
  }) {
    if (clearFirst) {
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }

    // Match Flutter's end-of-text fallback when no valid caret is established.
    // A valid selection (in either direction) replaces only the selected range.
    final selection =
        current.selection.isValid &&
                current.selection.end <= current.text.length
            ? current.selection
            : TextSelection.collapsed(offset: current.text.length);
    return TextEditingValue(
      text: current.text.replaceRange(selection.start, selection.end, text),
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
  }

  _EditableTextCandidate? _findEditableText(Element root) {
    _EditableTextCandidate? found;
    void walk(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is EditableText) {
        found = _EditableTextCandidate(
          controller: widget.controller,
          onChanged: widget.onChanged,
          focusNode: widget.focusNode,
        );
        return;
      }
      element.visitChildren(walk);
    }

    root.visitChildren(walk);
    return found;
  }

  int _scoreTextField({
    required InputDecoration? decoration,
    required ElementTarget? target,
    required _SemanticsMatch? semantics,
    required Rect? bounds,
  }) {
    final labels = <String?>[
      decoration?.labelText,
      decoration?.hintText,
      decoration?.helperText,
      decoration?.semanticCounterText,
    ].whereType<String>().map(_clean).where((value) => value.isNotEmpty);
    final labelText = labels.join(' ').toLowerCase();
    var score = 0;

    void scoreNeedle(String? needle, int exact, int contains) {
      final value = _clean(needle ?? '').toLowerCase();
      if (value.isEmpty) return;
      if (labelText == value ||
          labels.any((label) => label.toLowerCase() == value)) {
        score += exact;
      } else if (labelText.contains(value)) {
        score += contains;
      }
    }

    scoreNeedle(target?.id, 60, 25);
    scoreNeedle(target?.label, 100, 50);
    scoreNeedle(target?.text, 80, 40);
    scoreNeedle(semantics?.data.label, 75, 35);
    if (bounds != null &&
        semantics != null &&
        _rectsOverlap(bounds, semantics.bounds)) {
      score += 80;
    }
    return score;
  }

  Rect? _boundsForElement(Element element) {
    final renderObject = element.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    return topLeft & renderObject.size;
  }

  SemanticsOwner? get _semanticsOwner =>
      _pipelineOwner?.semanticsOwner ??
      RendererBinding.instance.rootPipelineOwner.semanticsOwner;

  RouteEntry? _findCurrentRoute(Element? root) {
    if (root == null) return null;
    RouteEntry? paintedRoute;
    RouteEntry? routerRoute;
    var bestPaintedScore = -1;
    var bestRouterScore = -1;
    final visited = <Element>{};

    void walk(Element element) {
      if (!visited.add(element) || visited.length > 20000) return;
      final router = _routeFromRouterWidget(element.widget);
      if (router != null) {
        final score = _routeCandidateScore(router, element.depth);
        if (score >= bestRouterScore) {
          bestRouterScore = score;
          routerRoute = router;
        }
      }
      final painted = _routeFromModalScopeWidget(element.widget);
      if (painted != null) {
        final score = _routeCandidateScore(painted, element.depth);
        if (score >= bestPaintedScore) {
          bestPaintedScore = score;
          paintedRoute = painted;
        }
      }
      element.visitChildren(walk);
    }

    walk(root);
    final painted = paintedRoute;
    if (painted != null && _hasUsefulPaintedRoute(painted)) return painted;
    return routerRoute ?? painted;
  }

  int _routeCandidateScore(RouteEntry route, int depth) {
    var score = depth;
    final path = route.path;
    if (path != null && path.isNotEmpty) score += 1000;
    if (_isRouterScreenClass(route.screenClass)) score += 2000;
    return score;
  }

  RouteEntry? _routeFromRouterWidget(Widget widget) {
    if (widget is! Router<Object>) return null;
    final configuration = widget.routerDelegate.currentConfiguration;
    final route = _routeFromConfiguration(configuration);
    if (route == null) return null;
    return RouteEntry(
      name: route.name,
      path: route.path,
      screenClass: _screenClassForRouter(widget.routerDelegate, configuration),
      params: route.params,
    );
  }

  RouteEntry? _routeFromModalScopeWidget(Widget widget) {
    if (!_isModalScopeWidget(widget)) return null;
    try {
      final dynamic scope = widget;
      final route = scope.route;
      if (route is! Route<dynamic>) return null;
      var isCurrent = route.isCurrent;
      try {
        final dynamic current = scope.isCurrent;
        if (current is bool) isCurrent = current;
      } catch (_) {
        // _ModalScope exposes route; _ModalScopeStatus exposes isCurrent.
      }
      if (!isCurrent) return null;
      return _routeFromRoute(route);
    } catch (_) {
      return null;
    }
  }

  RouteEntry _routeFromRoute(Route<dynamic> route) {
    final name = route.settings.name;
    return RouteEntry(
      name: name,
      path: _routePathFromRouteName(name),
      screenClass: route.runtimeType.toString(),
      params: <String, Object?>{
        if (route.settings.arguments != null)
          'arguments': route.settings.arguments.toString(),
      },
    );
  }

  RouteEntry? _routeFromConfiguration(
    Object? configuration, [
    Set<Object>? seen,
    int depth = 0,
  ]) {
    if (configuration == null) return null;
    if (depth > 8) return null;
    if (configuration is Uri) return _routeFromUri(configuration);
    seen ??= <Object>{};
    if (seen.contains(configuration)) return null;
    seen.add(configuration);

    final uri = _tryUri(configuration, const <String>[
      'uri',
      'location',
      'path',
      'url',
      'matchedLocation',
      'fullPath',
      'route',
    ]);
    if (uri != null) return _routeFromUri(uri);

    for (final field in const <String>[
      'state',
      'urlState',
      'routeInformation',
      'routeData',
    ]) {
      final nested = _tryRead(configuration, field);
      final route = _routeFromConfiguration(nested, seen, depth + 1);
      if (route != null) return route;
    }

    final textPath = _pathFromText(configuration.toString());
    if (textPath == null) return null;
    return _routeFromUri(Uri.parse(textPath));
  }

  RouteEntry _routeFromUri(Uri uri) {
    return RouteEntry(
      name: _routeName(uri),
      path: uri.path.isEmpty ? '/' : uri.path,
      params: <String, Object?>{
        for (final entry in uri.queryParameters.entries) entry.key: entry.value,
      },
    );
  }

  Uri? _tryUri(Object source, List<String> fields) {
    for (final field in fields) {
      final value = _tryRead(source, field);
      if (value is Uri) return value;
      if (value is String && value.trim().isNotEmpty) {
        final text = value.trim();
        if (text.startsWith('/') || text.startsWith('http')) {
          return Uri.parse(text);
        }
      }
    }
    return null;
  }

  Object? _tryRead(Object source, String field) {
    try {
      return switch (field) {
        'fullPath' => (source as dynamic).fullPath,
        'location' => (source as dynamic).location,
        'matchedLocation' => (source as dynamic).matchedLocation,
        'path' => (source as dynamic).path,
        'route' => (source as dynamic).route,
        'routeData' => (source as dynamic).routeData,
        'routeInformation' => (source as dynamic).routeInformation,
        'state' => (source as dynamic).state,
        'uri' => (source as dynamic).uri,
        'url' => (source as dynamic).url,
        'urlState' => (source as dynamic).urlState,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  String? _pathFromText(String text) {
    final match = RegExp(r'(/[A-Za-z0-9_\-./?=&%]+)').firstMatch(text);
    return match?.group(1);
  }

  bool _hasUsefulPaintedRoute(RouteEntry route) {
    final path = route.path?.trim();
    if (path == null || path.isEmpty) return false;
    if (path == '/') return true;
    return path.startsWith('/') || path.contains('-') || path.contains('_');
  }

  String? _routePathFromRouteName(String? name) {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.startsWith('/')) return trimmed;
    final path = _pathFromText(trimmed);
    if (path != null) return path;
    if (!trimmed.endsWith('Route')) return trimmed;
    final kebab =
        trimmed
            .replaceAllMapped(
              RegExp(r'(?<=[a-z0-9])([A-Z])'),
              (match) => '-${match.group(1)!.toLowerCase()}',
            )
            .replaceAll('_', '-')
            .toLowerCase();
    return '/$kebab';
  }

  String _screenClassForRouter(
    RouterDelegate<Object> delegate,
    Object? configuration,
  ) {
    final haystack =
        '${delegate.runtimeType} ${configuration.runtimeType}'.toLowerCase();
    if (haystack.contains('go')) return 'go_router';
    if (haystack.contains('auto')) return 'auto_route';
    if (haystack.contains('beam')) return 'beamer';
    if (haystack.contains('get')) return 'getx';
    return 'flutter_router';
  }

  bool _isRouterScreenClass(String? screenClass) {
    return switch (screenClass) {
      'flutter_router' ||
      'go_router' ||
      'auto_route' ||
      'beamer' ||
      'getx' => true,
      _ => false,
    };
  }

  String _routeName(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    if (path == '/') return 'home';
    return path.split('/').where((part) => part.isNotEmpty).last;
  }
}

class _AutomaticStateIndexers {
  const _AutomaticStateIndexers({
    this.provider = true,
    this.riverpod = true,
    this.getx = true,
    this.setState = true,
    this.changeNotifier = true,
    this.valueNotifier = true,
    this.custom = true,
  });

  final bool provider;
  final bool riverpod;
  final bool getx;
  final bool setState;
  final bool changeNotifier;
  final bool valueNotifier;
  final bool custom;

  bool get any =>
      provider ||
      riverpod ||
      getx ||
      setState ||
      changeNotifier ||
      valueNotifier ||
      custom;
}

class _FlutterTreeSummary {
  static const int _maxStateRecords = 60;
  static const int _maxFrameworkValues = 40;

  final Map<String, int> _widgets = <String, int>{};
  final List<Map<String, Object?>> states = <Map<String, Object?>>[];
  final List<Map<String, Object?>> customStates = <Map<String, Object?>>[];
  final List<String> inheritedWidgets = <String>[];
  final List<Map<String, Object?>> valueListenables = <Map<String, Object?>>[];
  final List<Map<String, Object?>> changeNotifiers = <Map<String, Object?>>[];
  final List<Map<String, Object?>> providerWidgets = <Map<String, Object?>>[];
  final List<Map<String, Object?>> riverpodWidgets = <Map<String, Object?>>[];
  final List<Map<String, Object?>> getxWidgets = <Map<String, Object?>>[];
  final List<Map<String, Object?>> providerValues = <Map<String, Object?>>[];
  final List<Map<String, Object?>> riverpodValues = <Map<String, Object?>>[];
  final List<Map<String, Object?>> getxControllers = <Map<String, Object?>>[];
  final Set<String> detectedFrameworks = <String>{};

  void addWidget(String type) {
    _widgets[type] = (_widgets[type] ?? 0) + 1;
  }

  void addState(Map<String, Object?> state) {
    if (states.length < _maxStateRecords) states.add(state);
    final stateType = state['state']?.toString() ?? '';
    if (!_isFlutterInternal(stateType) &&
        customStates.length < _maxStateRecords) {
      customStates.add(state);
    }
  }

  void addInherited(String type) {
    if (!inheritedWidgets.contains(type)) inheritedWidgets.add(type);
    detect(type);
  }

  void addValueListenable(Map<String, Object?> listenable) {
    if (valueListenables.length < _maxFrameworkValues) {
      valueListenables.add(listenable);
    }
  }

  void addChangeNotifier(Map<String, Object?> listenable) {
    if (changeNotifiers.length < _maxFrameworkValues) {
      changeNotifiers.add(listenable);
    }
  }

  void capturePublicWidgetState(String type, Widget widget) {
    final source = _sourceForType(type);
    if (source == null) return;
    final values = _publicStateFor(widget);
    if (values.isEmpty) return;
    final item = <String, Object?>{'widget': type, 'value': values};
    switch (source) {
      case OperatorStateSource.provider:
        if (providerValues.length < _maxFrameworkValues) {
          providerValues.add(item);
        }
      case OperatorStateSource.riverpod:
        if (riverpodValues.length < _maxFrameworkValues) {
          riverpodValues.add(item);
        }
      case OperatorStateSource.getx:
        if (getxControllers.length < _maxFrameworkValues) {
          getxControllers.add(item);
        }
      case OperatorStateSource.bloc:
      case OperatorStateSource.setState:
      case OperatorStateSource.changeNotifier:
      case OperatorStateSource.valueNotifier:
      case OperatorStateSource.redux:
      case OperatorStateSource.mobx:
      case OperatorStateSource.inheritedWidget:
      case OperatorStateSource.custom:
      case OperatorStateSource.inferred:
        break;
    }
  }

  void capturePublicControllerState(String type, State<dynamic> state) {
    final source = _sourceForType(type);
    final values = _publicStateFor(state);
    if (values.isEmpty) return;
    final item = <String, Object?>{'state': type, 'value': values};
    if (source == OperatorStateSource.getx ||
        values.containsKey('controller')) {
      if (getxControllers.length < _maxFrameworkValues) {
        getxControllers.add(item);
      }
    } else if (source == OperatorStateSource.provider) {
      if (providerValues.length < _maxFrameworkValues) {
        providerValues.add(item);
      }
    } else if (source == OperatorStateSource.riverpod) {
      if (riverpodValues.length < _maxFrameworkValues) {
        riverpodValues.add(item);
      }
    }
  }

  void detect(String rawType) {
    final type = rawType.toLowerCase();
    if (type.contains('bloc') || type.contains('cubit')) {
      detectedFrameworks.add('bloc');
    }
    if (type.contains('riverpod') ||
        type.contains('providerscope') ||
        type.contains('consumerwidget') ||
        type.contains('consumerstate')) {
      detectedFrameworks.add('riverpod');
      _addUnique(riverpodWidgets, rawType);
    }
    if (type.contains('provider') ||
        type.contains('consumer') ||
        type.contains('selector')) {
      detectedFrameworks.add('provider');
      _addUnique(providerWidgets, rawType);
    }
    if (type.contains('getx') ||
        type == 'get' ||
        type.contains('getbuilder') ||
        type.contains('getmaterialapp') ||
        type.contains('obx')) {
      detectedFrameworks.add('getx');
      _addUnique(getxWidgets, rawType);
    }
    if (type.contains('gorouter') || type.contains('go_router')) {
      detectedFrameworks.add('go_router');
    }
    if (type.contains('autoroute') || type.contains('autorouter')) {
      detectedFrameworks.add('auto_route');
    }
    if (type.contains('beamer')) detectedFrameworks.add('beamer');
    if (type.contains('navigator')) detectedFrameworks.add('navigator');
  }

  Map<String, Object?> get widgetTreeValue {
    final topWidgets =
        _widgets.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return <String, Object?>{
      'frameworks': detectedFrameworks.toList()..sort(),
      'widgetCount': _widgets.values.fold<int>(0, (sum, count) => sum + count),
      'topWidgets': topWidgets
          .take(30)
          .map(
            (entry) => <String, Object?>{
              'type': entry.key,
              'count': entry.value,
            },
          )
          .toList(growable: false),
      'stateCount': states.length,
      'inheritedWidgetCount': inheritedWidgets.length,
    };
  }

  void _addUnique(List<Map<String, Object?>> target, String widget) {
    if (target.any((entry) => entry['widget'] == widget)) return;
    target.add(<String, Object?>{'widget': widget});
  }
}

Map<String, Object?> _diagnosticsFor(Object state) {
  final value = <String, Object?>{'type': state.runtimeType.toString()};
  final stringValue = state.toString();
  if (stringValue.isNotEmpty && stringValue != state.runtimeType.toString()) {
    value['stringValue'] = _truncate(stringValue, 160);
  }
  return value;
}

Map<String, Object?> _publicStateFor(Object object) {
  final out = <String, Object?>{};
  final json = _tryCallToJson(object);
  if (json != null) out['json'] = _safeValue(json);
  for (final field in const <String>[
    'value',
    'state',
    'controller',
    'notifier',
    'model',
    'viewModel',
    'store',
    'data',
    'items',
    'count',
    'length',
    'selected',
    'status',
  ]) {
    final value = _tryReadPublic(object, field);
    if (value == null) continue;
    out[field] = _safeValue(value);
  }
  return out;
}

Object? _safeValue(Object? value, [Set<Object>? seen]) {
  if (value == null || value is num || value is bool) {
    return value;
  }
  if (value is String) return _truncate(value, 500);
  if (value is TextEditingValue) {
    return <String, Object?>{
      'type': 'TextEditingValue',
      'text': '[REDACTED]',
      'textLength': value.text.length,
      'selectionBase': value.selection.baseOffset,
      'selectionExtent': value.selection.extentOffset,
    };
  }
  seen ??= <Object>{};
  if (seen.contains(value)) return '[Circular]';
  seen.add(value);
  if (value is List) {
    return value
        .take(20)
        .map((item) => _safeValue(item, seen))
        .toList(growable: false);
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries.take(20))
        entry.key.toString(): _safeValue(entry.value, seen),
    };
  }
  final json = _tryCallToJson(value);
  if (json != null) return _safeValue(json, seen);
  if (value is Diagnosticable) {
    return <String, Object?>{'type': value.runtimeType.toString()};
  }
  return <String, Object?>{
    'type': value.runtimeType.toString(),
    'stringValue': _truncate(value.toString(), 160),
  };
}

String _truncate(String value, int maxLength) =>
    value.length <= maxLength ? value : '${value.substring(0, maxLength)}...';

Object? _tryCallToJson(Object object) {
  try {
    final value = (object as dynamic).toJson();
    if (value == null ||
        value is num ||
        value is bool ||
        value is String ||
        value is List ||
        value is Map) {
      return value;
    }
  } catch (_) {
    return null;
  }
  return null;
}

Object? _tryReadPublic(Object object, String field) {
  try {
    return switch (field) {
      'controller' => (object as dynamic).controller,
      'count' => (object as dynamic).count,
      'data' => (object as dynamic).data,
      'items' => (object as dynamic).items,
      'length' => (object as dynamic).length,
      'model' => (object as dynamic).model,
      'notifier' => (object as dynamic).notifier,
      'selected' => (object as dynamic).selected,
      'state' => (object as dynamic).state,
      'status' => (object as dynamic).status,
      'store' => (object as dynamic).store,
      'value' => (object as dynamic).value,
      'viewModel' => (object as dynamic).viewModel,
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

OperatorStateSource? _sourceForType(String rawType) {
  final type = rawType.toLowerCase();
  if (type.contains('riverpod') ||
      type.contains('providerscope') ||
      type.contains('consumerwidget') ||
      type.contains('consumerstate')) {
    return OperatorStateSource.riverpod;
  }
  if (type.contains('provider') ||
      type.contains('consumer') ||
      type.contains('selector')) {
    return OperatorStateSource.provider;
  }
  if (type.contains('getx') ||
      type == 'get' ||
      type.contains('getbuilder') ||
      type.contains('getmaterialapp') ||
      type.contains('obx')) {
    return OperatorStateSource.getx;
  }
  return null;
}

bool _isFlutterInternal(String type) {
  final lower = type.toLowerCase();
  return lower.contains('navigator') ||
      lower.contains('overlay') ||
      lower.contains('scrollable') ||
      lower.contains('focus') ||
      lower.contains('shortcut') ||
      lower.contains('action') ||
      lower.contains('hero') ||
      lower.contains('ticker') ||
      lower.contains('semantics') ||
      lower.contains('gesture') ||
      lower.contains('mediaquery') ||
      lower.contains('materialapp') ||
      lower.contains('widgetsapp') ||
      lower.contains('router') ||
      lower.contains('modal') ||
      lower.contains('theme') ||
      lower.contains('animated') ||
      lower.contains('transition');
}

class _TextInputCandidate {
  const _TextInputCandidate({
    required this.controller,
    required this.onChanged,
    required this.score,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final int score;
}

class _ScrollCandidate {
  const _ScrollCandidate({
    required this.position,
    required this.score,
    required this.element,
  });

  final ScrollPosition position;
  final int score;
  final Element element;
}

class _EditableTextCandidate {
  const _EditableTextCandidate({
    required this.controller,
    required this.onChanged,
    required this.focusNode,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final FocusNode focusNode;
}

class OperatorAutomaticLayer extends StatefulWidget {
  const OperatorAutomaticLayer({
    super.key,
    required this.runtime,
    required this.child,
  });

  final OperatorAutomaticFlutterRuntime runtime;
  final Widget child;

  @override
  State<OperatorAutomaticLayer> createState() => _OperatorAutomaticLayerState();
}

class _OperatorAutomaticLayerState extends State<OperatorAutomaticLayer> {
  @override
  void initState() {
    super.initState();
    widget.runtime.ensureInstalled();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.runtime.attachPipelineOwner(View.pipelineOwnerOf(context));
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class _TapPhaseTiming {
  _TapPhaseTiming() : _total = Stopwatch()..start();

  final Stopwatch _total;
  final Map<String, int> _durations = <String, int>{};

  T timeSync<T>(String phase, T Function() body) {
    final watch = Stopwatch()..start();
    try {
      return body();
    } finally {
      _add(phase, watch.elapsedMilliseconds);
    }
  }

  Future<T> time<T>(String phase, Future<T> Function() body) async {
    final watch = Stopwatch()..start();
    try {
      return await body();
    } finally {
      _add(phase, watch.elapsedMilliseconds);
    }
  }

  VerificationEvidence evidence() {
    return VerificationEvidence(
      source: OperatorVerificationSource.action,
      condition: 'tap.phase_timing',
      ok: true,
      detail: <String>[
        'totalMs=${_total.elapsedMilliseconds}',
        for (final entry in _durations.entries) '${entry.key}Ms=${entry.value}',
      ].join('; '),
    );
  }

  void _add(String phase, int elapsedMs) {
    _durations[phase] = (_durations[phase] ?? 0) + elapsedMs;
  }
}

ActionResult _withTapPhaseTiming(ActionResult result, _TapPhaseTiming timing) {
  if (result.evidence.any((entry) => entry.condition == 'tap.phase_timing')) {
    return result;
  }
  return ActionResult(
    ok: result.ok,
    action: result.action,
    message: result.message,
    error: result.error,
    evidence: <VerificationEvidence>[...result.evidence, timing.evidence()],
    data: result.data,
  );
}

enum _FlutterObservationTargetBeginStatus {
  execute,
  delivered,
  join,
  unavailable,
}

class _FlutterObservationTargetBegin {
  const _FlutterObservationTargetBegin({
    required this.status,
    this.result,
    this.sharedResult,
  });

  final _FlutterObservationTargetBeginStatus status;
  final ActionResult? result;
  final Future<ActionResult>? sharedResult;
}

enum _FlutterObservationDeliveryStatus { inFlight, delivered }

class _FlutterObservationTargetRecord {
  _FlutterObservationTargetRecord({
    required this.reference,
    required this.binding,
    required this.identityFingerprint,
  });

  final FlutterObservationTargetRef reference;
  _FlutterRuntimeControlBinding binding;
  final String identityFingerprint;
  bool revoked = false;
  int inFlightDeliveryCount = 0;
}

class _FlutterObservationDeliveryRecord {
  _FlutterObservationDeliveryRecord({
    required this.reference,
    required this.deliveryId,
    required this.inFlight,
  });

  final FlutterObservationTargetRef reference;
  final String deliveryId;
  _FlutterObservationDeliveryStatus status =
      _FlutterObservationDeliveryStatus.inFlight;
  ActionResult? deliveredResult;
  final Completer<ActionResult> inFlight;
}

class _FlutterObservationTargetRegistry {
  final Map<String, _FlutterObservationTargetRecord> _records =
      <String, _FlutterObservationTargetRecord>{};
  final Map<String, String> _ticketByControlId = <String, String>{};
  final Map<String, _FlutterObservationDeliveryRecord> _deliveries =
      <String, _FlutterObservationDeliveryRecord>{};
  final math.Random _random = math.Random.secure();
  String? _activeSnapshotId;
  final Set<String> _seenControlIds = <String>{};

  void clear() {
    for (final delivery in _deliveries.values) {
      if (!delivery.inFlight.isCompleted) {
        delivery.inFlight.completeError(
          StateError('Flutter observation target registry was disposed'),
        );
      }
    }
    _records.clear();
    _ticketByControlId.clear();
    _deliveries.clear();
    _seenControlIds.clear();
    _activeSnapshotId = null;
  }

  void beginSnapshot(String snapshotId) {
    _activeSnapshotId = snapshotId;
    _seenControlIds.clear();
  }

  FlutterObservationTargetRef issue(
    String snapshotId,
    _FlutterRuntimeControlBinding binding,
  ) {
    if (_activeSnapshotId != snapshotId) {
      throw StateError(
        'Flutter observation target issuance is not bound to $snapshotId',
      );
    }
    _seenControlIds.add(binding.id);
    final fingerprint = _targetIdentityFingerprint(binding);
    final existingTicketId = _ticketByControlId[binding.id];
    final existing =
        existingTicketId == null ? null : _records[existingTicketId];
    if (existing != null &&
        !existing.revoked &&
        identical(existing.binding.element, binding.element) &&
        existing.identityFingerprint == fingerprint) {
      existing.binding = binding;
      return existing.reference;
    }
    if (existing != null) _retire(existing);

    final reference = FlutterObservationTargetRef(
      ticketId: _newTicketId(),
      snapshotId: snapshotId,
    );
    _records[reference.ticketId] = _FlutterObservationTargetRecord(
      reference: reference,
      binding: binding,
      identityFingerprint: fingerprint,
    );
    _ticketByControlId[binding.id] = reference.ticketId;
    return reference;
  }

  void endSnapshot(String snapshotId) {
    if (_activeSnapshotId != snapshotId) return;
    for (final entry in _ticketByControlId.entries.toList(growable: false)) {
      if (_seenControlIds.contains(entry.key)) continue;
      final record = _records[entry.value];
      if (record != null) _retire(record);
    }
    _seenControlIds.clear();
    _activeSnapshotId = null;
  }

  _FlutterObservationTargetBegin begin(
    FlutterObservationTargetRef reference, {
    String? targetId,
    required String deliveryId,
  }) {
    if (!_referenceShapeIsValid(reference)) {
      return const _FlutterObservationTargetBegin(
        status: _FlutterObservationTargetBeginStatus.unavailable,
      );
    }
    final key = _deliveryKey(reference, deliveryId);
    final existingDelivery = _deliveries[key];
    if (existingDelivery != null &&
        _sameReference(existingDelivery.reference, reference)) {
      if (existingDelivery.status ==
          _FlutterObservationDeliveryStatus.delivered) {
        return _FlutterObservationTargetBegin(
          status: _FlutterObservationTargetBeginStatus.delivered,
          result: existingDelivery.deliveredResult,
        );
      }
      return _FlutterObservationTargetBegin(
        status: _FlutterObservationTargetBeginStatus.join,
        sharedResult: existingDelivery.inFlight.future,
      );
    }
    final record = _recordFor(reference);
    if (record == null ||
        record.revoked ||
        (targetId != null &&
            targetId.trim().isNotEmpty &&
            targetId.trim() != record.binding.id)) {
      return const _FlutterObservationTargetBegin(
        status: _FlutterObservationTargetBeginStatus.unavailable,
      );
    }
    final completer = Completer<ActionResult>();
    unawaited(
      completer.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
    _deliveries[key] = _FlutterObservationDeliveryRecord(
      reference: reference,
      deliveryId: deliveryId,
      inFlight: completer,
    );
    record.inFlightDeliveryCount += 1;
    return const _FlutterObservationTargetBegin(
      status: _FlutterObservationTargetBeginStatus.execute,
    );
  }

  _FlutterRuntimeControlBinding? bindingFor(
    FlutterObservationTargetRef reference,
  ) => _recordFor(reference)?.binding;

  // A read cannot mint or consume input authority. It may only reuse a ticket
  // issued for this same live widget and identity by a model observation.
  FlutterObservationTargetRef? referenceForLiveControl(
    _FlutterRuntimeControlBinding binding,
  ) {
    final record = _records[_ticketByControlId[binding.id]];
    if (record == null ||
        record.revoked ||
        !identical(record.binding.element, binding.element) ||
        record.identityFingerprint != _targetIdentityFingerprint(binding))
      return null;
    return record.reference;
  }

  void complete(
    FlutterObservationTargetRef reference,
    String deliveryId,
    ActionResult result,
  ) {
    final delivery = _deliveryFor(reference, deliveryId);
    if (delivery == null ||
        delivery.status == _FlutterObservationDeliveryStatus.delivered) {
      return;
    }
    delivery.status = _FlutterObservationDeliveryStatus.delivered;
    delivery.deliveredResult = result;
    if (!delivery.inFlight.isCompleted) delivery.inFlight.complete(result);
    _finishInFlight(reference);
  }

  void invalidate(
    FlutterObservationTargetRef reference,
    String deliveryId,
    ActionResult result,
  ) {
    complete(reference, deliveryId, result);
    final record = _recordFor(reference);
    if (record != null) _retire(record);
  }

  void fail(
    FlutterObservationTargetRef reference,
    String deliveryId,
    Object error,
  ) {
    final key = _deliveryKey(reference, deliveryId);
    final delivery = _deliveries.remove(key);
    if (delivery == null) return;
    if (!delivery.inFlight.isCompleted) {
      delivery.inFlight.completeError(error);
    }
    _finishInFlight(reference);
  }

  void _finishInFlight(FlutterObservationTargetRef reference) {
    final record = _recordFor(reference);
    if (record == null || record.inFlightDeliveryCount == 0) return;
    record.inFlightDeliveryCount -= 1;
    if (record.revoked && record.inFlightDeliveryCount == 0) {
      _records.remove(reference.ticketId);
    }
  }

  _FlutterObservationTargetRecord? _recordFor(
    FlutterObservationTargetRef reference,
  ) {
    if (!_referenceShapeIsValid(reference)) return null;
    final record = _records[reference.ticketId];
    if (record == null || !_sameReference(record.reference, reference)) {
      return null;
    }
    return record;
  }

  _FlutterObservationDeliveryRecord? _deliveryFor(
    FlutterObservationTargetRef reference,
    String deliveryId,
  ) {
    final delivery = _deliveries[_deliveryKey(reference, deliveryId)];
    if (delivery == null || !_sameReference(delivery.reference, reference)) {
      return null;
    }
    return delivery;
  }

  void _retire(_FlutterObservationTargetRecord record) {
    record.revoked = true;
    if (_ticketByControlId[record.binding.id] == record.reference.ticketId) {
      _ticketByControlId.remove(record.binding.id);
    }
    if (record.inFlightDeliveryCount == 0) {
      _records.remove(record.reference.ticketId);
    }
  }

  String _targetIdentityFingerprint(_FlutterRuntimeControlBinding binding) {
    final actions = [...binding.actions]..sort();
    return <Object?>[
      binding.element.widget.runtimeType,
      binding.platformId,
      binding.debugKey,
      binding.role,
      binding.label,
      actions.join(','),
    ].join('\u0000');
  }

  String _deliveryKey(
    FlutterObservationTargetRef reference,
    String deliveryId,
  ) => '${reference.ticketId}\u0000$deliveryId';

  bool _referenceShapeIsValid(FlutterObservationTargetRef reference) {
    return reference.version == operatorFlutterObservationTargetVersion &&
        reference.ticketId.isNotEmpty &&
        reference.snapshotId.isNotEmpty;
  }

  bool _sameReference(
    FlutterObservationTargetRef left,
    FlutterObservationTargetRef right,
  ) {
    return left.version == right.version &&
        left.ticketId == right.ticketId &&
        left.snapshotId == right.snapshotId;
  }

  String _newTicketId() {
    final bytes = List<int>.generate(18, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

class _FlutterRuntimeControlBinding {
  const _FlutterRuntimeControlBinding({
    required this.id,
    required this.element,
    required this.role,
    required this.enabled,
    required this.visible,
    required this.rendered,
    required this.inViewport,
    required this.actions,
    required this.confidence,
    this.platformId,
    this.debugKey,
    this.label,
    this.text,
    this.value,
    this.valueIsAuthoritative = false,
    this.valueSource,
    this.hint,
    this.selected,
    this.checked,
    this.bounds,
    this.textController,
    this.onTextChanged,
    this.focusNode,
    this.scrollOwner,
    this.secure = false,
    this.readOnly = false,
  });

  final String id;
  final Element element;
  final String? platformId;
  final String? debugKey;
  final OperatorUiRole role;
  final String? label;
  final String? text;
  final Object? value;
  final bool valueIsAuthoritative;
  final String? valueSource;
  final String? hint;
  final bool enabled;
  final bool visible;
  final bool rendered;
  final bool inViewport;
  final bool? selected;
  final bool? checked;
  final Rect? bounds;
  final List<String> actions;
  final TextEditingController? textController;
  final ValueChanged<String>? onTextChanged;
  final FocusNode? focusNode;
  final ScrollPosition? scrollOwner;
  final bool secure;
  final bool readOnly;
  final double confidence;
}

class _SemanticsMatch {
  _SemanticsMatch({
    required this.node,
    required this.data,
    required this.bounds,
    required this.parentId,
  });

  final SemanticsNode node;
  final SemanticsData data;
  final Rect bounds;
  final int? parentId;
  List<_SemanticsMatch> children = const <_SemanticsMatch>[];

  String get description {
    final identifier = data.identifier.trim();
    if (identifier.isNotEmpty) return identifier;
    final label = data.label.trim();
    if (label.isNotEmpty) return label;
    final value = data.value.trim();
    if (value.isNotEmpty) return value;
    return 'semantics node ${node.id}';
  }
}

class _ScoredSemanticsMatch {
  const _ScoredSemanticsMatch(this.match, this.score);

  final _SemanticsMatch match;
  final int score;
}

class _TapCandidate {
  const _TapCandidate({
    required this.position,
    required this.reason,
    required this.priority,
    required this.hit,
    this.match,
    this.dispatchBounds,
  });

  final Offset position;
  final String reason;
  final int priority;
  final _SemanticsMatch? match;
  final Rect? dispatchBounds;
  final _HitTestSnapshot hit;
}

class _WidgetTapCandidate {
  const _WidgetTapCandidate({
    required this.bounds,
    required this.reason,
    required this.priority,
    required this.centerOnly,
  });

  final Rect bounds;
  final String reason;
  final int priority;
  final bool centerOnly;
}

class _HitTestSnapshot {
  const _HitTestSnapshot({
    required this.position,
    required this.path,
    required this.targets,
    this.error,
  });

  final Offset position;
  final List<String> path;
  final List<HitTestTarget> targets;
  final String? error;
}

class _TapTargetEffect {
  const _TapTargetEffect({required this.ok, required this.evidence});

  factory _TapTargetEffect.ok(String detail) => _TapTargetEffect(
    ok: true,
    evidence: VerificationEvidence(
      source: OperatorVerificationSource.action,
      condition: 'tap.target_effect.verified',
      ok: true,
      detail: detail,
    ),
  );

  factory _TapTargetEffect.ambiguous(String detail) => _TapTargetEffect(
    ok: false,
    evidence: VerificationEvidence(
      source: OperatorVerificationSource.action,
      condition: 'tap.target_effect.ambiguous',
      ok: false,
      detail: detail,
    ),
  );

  final bool ok;
  final VerificationEvidence evidence;
}

bool _isEmpty(SemanticsData data) {
  return data.label.trim().isEmpty &&
      data.value.trim().isEmpty &&
      data.hint.trim().isEmpty &&
      data.tooltip.trim().isEmpty &&
      data.identifier.trim().isEmpty &&
      data.actions == 0;
}

bool _networkEventMatchesWait(NetworkEvent event, WaitCondition condition) {
  if (event.request.path != condition.path) return false;
  final method = condition.method;
  if (method != null &&
      event.request.method.toUpperCase() != method.toUpperCase()) {
    return false;
  }
  final ok = condition.ok;
  if (ok != null && event.response?.ok != ok) return false;
  return true;
}

String _clean(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

bool _rectsOverlap(Rect a, Rect b) {
  if (a.isEmpty || b.isEmpty) return false;
  return a.overlaps(b) || (a.center - b.center).distance < 24;
}

OperatorUiRole _roleFor(SemanticsData data) {
  final flags = data.flagsCollection;
  if (flags.isTextField) return OperatorUiRole.input;
  if (flags.isButton) return OperatorUiRole.button;
  if (flags.isLink) return OperatorUiRole.link;
  if (flags.isChecked.toBoolOrNull() != null) return OperatorUiRole.checkbox;
  if (flags.isToggled.toBoolOrNull() != null) return OperatorUiRole.switchRole;
  if (flags.isSelected.toBoolOrNull() != null &&
      data.hasAction(SemanticsAction.tap)) {
    return OperatorUiRole.tab;
  }
  if (flags.isImage) return OperatorUiRole.image;
  if (data.hasAction(SemanticsAction.tap)) return OperatorUiRole.button;
  if (data.hasAction(SemanticsAction.setText)) return OperatorUiRole.input;
  return OperatorUiRole.text;
}

OperatorUiRole? _targetRole(String? role) {
  return switch (role) {
    'button' => OperatorUiRole.button,
    'link' => OperatorUiRole.link,
    'input' => OperatorUiRole.input,
    'text' => OperatorUiRole.text,
    'image' => OperatorUiRole.image,
    'list' => OperatorUiRole.list,
    'listitem' => OperatorUiRole.listitem,
    'checkbox' => OperatorUiRole.checkbox,
    'radio' => OperatorUiRole.radio,
    'switch' => OperatorUiRole.switchRole,
    'tab' => OperatorUiRole.tab,
    _ => null,
  };
}

List<String> _actionsFor(SemanticsData data) {
  final actions = <String>[];
  if (data.hasAction(SemanticsAction.tap)) actions.add('tap');
  if (data.hasAction(SemanticsAction.longPress)) actions.add('longPress');
  if (data.hasAction(SemanticsAction.setText)) actions.add('type');
  if (data.hasAction(SemanticsAction.scrollUp) ||
      data.hasAction(SemanticsAction.scrollDown) ||
      data.hasAction(SemanticsAction.scrollLeft) ||
      data.hasAction(SemanticsAction.scrollRight)) {
    actions.add('scroll');
  }
  if (data.hasAction(SemanticsAction.increase)) actions.add('increase');
  if (data.hasAction(SemanticsAction.decrease)) actions.add('decrease');
  return actions;
}

ActionResult? _simulationBlocked(
  OperatorFlutter operator,
  ActionCommand command,
  String feature,
) {
  if (operator.config.environment != OperatorEnvironment.production)
    return null;
  return ActionResult(
    ok: false,
    action: command,
    error: ActionError(
      type: 'simulation_blocked',
      message: '$feature is only available in dev or staging',
    ),
  );
}

extension on CheckedState {
  bool? toBoolOrNull() {
    return switch (this) {
      CheckedState.isTrue => true,
      CheckedState.isFalse => false,
      CheckedState.mixed => null,
      CheckedState.none => null,
    };
  }
}

/// One scroll_to candidate: a rendered control or a plain text widget.
class _ScrollToMatch {
  const _ScrollToMatch({
    required this.element,
    required this.id,
    required this.role,
    required this.label,
    required this.text,
    required this.bounds,
    required this.inViewport,
  });

  final Element element;
  final String? id;
  final String role;
  final String? label;
  final String? text;
  final Rect? bounds;
  final bool inViewport;

  bool matches(String needle, String? role) {
    if (role != null && role.isNotEmpty && this.role != role) return false;
    return <String?>[label, text].any(
      (value) => value != null && _clean(value).toLowerCase().contains(needle),
    );
  }

  JsonMap toJson() => <String, Object?>{
    if (id != null) 'id': id,
    'role': role,
    'label': label,
    'text': text,
    'inViewport': inViewport,
    if (bounds != null)
      'bounds': {
        'x': bounds!.left,
        'y': bounds!.top,
        'width': bounds!.width,
        'height': bounds!.height,
      },
  };
}
