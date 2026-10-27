import 'dart:typed_data';

import 'page_bridge_contract.dart';

typedef JsonMap = Map<String, Object?>;

enum OperatorPlatform {
  web,
  flutter,
  reactNative,
  android,
  ios,
  desktop,
  unknown,
}

enum OperatorEnvironment { dev, staging, production }

enum OperatorActionType {
  tap,
  tapPoint,
  click,
  type,
  clear,
  hover,
  key,
  drag,
  touch,
  scroll,
  scrollIntoView,
  scrollTo,
  navigate,
  wait,
  captureVisual,
  askUser,
  confirm,
  installNetworkMock,
  probeNetworkVirtualization,
  installFirebaseMock,
  probeFirebaseVirtualization,
  supplyMedia,
  injectState,
  injectStorage,
  clearStorage,
  injectForm,
  clearSimulation,
  setNetworkConditions,
  clearNetworkConditions,
}

enum OperatorUiRole {
  button,
  link,
  input,
  text,
  image,
  list,
  listitem,
  checkbox,
  radio,
  switchRole,
  dialog,
  menu,
  tab,
  unknown,
}

enum OperatorStateSource {
  bloc,
  riverpod,
  provider,
  getx,
  setState,
  changeNotifier,
  valueNotifier,
  redux,
  mobx,
  inheritedWidget,
  custom,
  inferred,
}

enum OperatorVerificationSource {
  action,
  ui,
  state,
  network,
  route,
  storage,
  form,
  log,
}

enum OperatorLogSource { app, operatorRuntime, network, system, unknown }

enum OperatorRuntimeEventType {
  snapshot,
  route,
  ui,
  state,
  forms,
  network,
  storage,
  log,
  error,
  dialog,
  visual,
  capabilities,
}

enum OperatorPolicyDecisionType { allow, confirm, blocked }

class OperatorCapabilities {
  const OperatorCapabilities({
    required this.observes,
    required this.actions,
    required this.selectors,
    required this.verification,
    required this.privacy,
    this.virtualization = const <String, bool>{},
  });

  final Map<String, bool> observes;
  final Map<String, bool> actions;
  final Map<String, bool> selectors;
  final Map<String, bool> verification;
  final Map<String, bool> privacy;
  final Map<String, bool> virtualization;
}

class AppSnapshot {
  const AppSnapshot({
    required this.snapshotId,
    required this.timestamp,
    required this.app,
    required this.userSession,
    required this.route,
    required this.ui,
    required this.state,
    this.forms = const <FormSnapshot>[],
    required this.network,
    required this.logs,
    this.errors = const <ErrorSnapshot>[],
    required this.dialogs,
    this.storage,
    this.visual,
    required this.capabilities,
    required this.redactions,
  });

  final String snapshotId;
  final DateTime timestamp;
  final AppInfo app;
  final UserSession userSession;
  final RouteState route;
  final UiTree ui;
  final List<StateStoreSnapshot> state;
  final List<FormSnapshot> forms;
  final NetworkTimeline network;
  final List<LogEvent> logs;
  final List<ErrorSnapshot> errors;
  final List<DialogState> dialogs;
  final StorageSnapshot? storage;
  final VisualSnapshot? visual;
  final OperatorCapabilities capabilities;
  final RedactionReport redactions;
}

class OperatorRuntimeEvent {
  const OperatorRuntimeEvent({
    required this.type,
    required this.sequence,
    required this.timestamp,
    this.snapshotId,
    this.payload,
  });

  final OperatorRuntimeEventType type;
  final int sequence;
  final DateTime timestamp;
  final String? snapshotId;
  final Object? payload;
}

class OperatorAppMapManifest {
  const OperatorAppMapManifest({
    required this.appId,
    required this.appMapHash,
    this.appVersion,
    this.buildNumber,
    this.gitSha,
    this.generatedAt,
    this.formatVersion,
    this.platform,
    this.expiresAt,
    this.keyId,
    this.signatureAlgorithm,
    this.signature,
  });

  final String appId;
  final String appMapHash;
  final String? appVersion;
  final String? buildNumber;
  final String? gitSha;
  final String? generatedAt;
  final String? formatVersion;
  final String? platform;
  final String? expiresAt;
  final String? keyId;
  final String? signatureAlgorithm;
  final String? signature;

  factory OperatorAppMapManifest.fromJson(Map<String, Object?> json) {
    final appId = json['appId'];
    final appMapHash = json['appMapHash'];
    if (appId is! String || appId.isEmpty) {
      throw const FormatException('Operator AppMap manifest requires appId');
    }
    if (appMapHash is! String || appMapHash.isEmpty) {
      throw const FormatException(
        'Operator AppMap manifest requires appMapHash',
      );
    }
    return OperatorAppMapManifest(
      appId: appId,
      appMapHash: appMapHash,
      appVersion: _stringOrNull(json['appVersion']),
      buildNumber: _stringOrNull(json['buildNumber']),
      gitSha: _stringOrNull(json['gitSha']),
      generatedAt: _stringOrNull(json['generatedAt']),
      formatVersion: _stringOrNull(json['formatVersion']),
      platform: _stringOrNull(json['platform']),
      expiresAt: _stringOrNull(json['expiresAt']),
      keyId: _stringOrNull(json['keyId']),
      signatureAlgorithm: _stringOrNull(json['signatureAlgorithm']),
      signature: _stringOrNull(json['signature']),
    );
  }

  JsonMap toJson() => <String, Object?>{
    'appId': appId,
    'appMapHash': appMapHash,
    if (appVersion != null) 'appVersion': appVersion,
    if (buildNumber != null) 'buildNumber': buildNumber,
    if (gitSha != null) 'gitSha': gitSha,
    if (generatedAt != null) 'generatedAt': generatedAt,
    if (formatVersion != null) 'formatVersion': formatVersion,
    if (platform != null) 'platform': platform,
    if (expiresAt != null) 'expiresAt': expiresAt,
    if (keyId != null) 'keyId': keyId,
    if (signatureAlgorithm != null) 'signatureAlgorithm': signatureAlgorithm,
    if (signature != null) 'signature': signature,
  };
}

String? _stringOrNull(Object? value) => value is String ? value : null;

class AppInfo {
  const AppInfo({
    required this.appId,
    required this.name,
    required this.platform,
    required this.environment,
    this.framework,
    this.version,
  });

  final String appId;
  final String name;
  final OperatorPlatform platform;
  final OperatorEnvironment environment;
  final String? framework;
  final String? version;
}

class UserSession {
  const UserSession({
    this.authenticated,
    this.role,
    this.locale,
    this.permissions = const <String>[],
  });

  final bool? authenticated;
  final String? role;
  final String? locale;
  final List<String> permissions;
}

class RouteState {
  const RouteState({
    required this.current,
    this.stack = const <RouteEntry>[],
    this.previous,
  });

  final RouteEntry current;
  final List<RouteEntry> stack;
  final RouteEntry? previous;
}

class RouteEntry {
  const RouteEntry({
    this.name,
    this.path,
    this.screenClass,
    this.title,
    this.params = const <String, Object?>{},
  });

  final String? name;
  final String? path;
  final String? screenClass;
  final String? title;
  final JsonMap params;
}

class UiTree {
  const UiTree({
    required this.rootId,
    required this.elements,
    required this.viewport,
    this.focusedElementId,
  });

  final String rootId;
  final List<UiElement> elements;
  final ViewportSnapshot viewport;
  final String? focusedElementId;
}

class ViewportSnapshot {
  const ViewportSnapshot({
    required this.width,
    required this.height,
    this.scrollX,
    this.scrollY,
  });

  final double width;
  final double height;
  final double? scrollX;
  final double? scrollY;
}

class UiElement {
  const UiElement({
    required this.id,
    required this.enabled,
    required this.visible,
    required this.actions,
    required this.confidence,
    this.platformId,
    this.role,
    this.label,
    this.text,
    this.value,
    this.hint,
    this.selected,
    this.checked,
    this.bounds,
    this.rendered,
    this.inViewport,
    this.parentId,
    this.children = const <String>[],
    this.observationTargetRef,
    this.scrollOwner,
    this.data = const <String, Object?>{},
  });

  final String id;
  final String? platformId;
  final OperatorUiRole? role;
  final String? label;
  final String? text;
  final Object? value;
  final String? hint;
  final bool enabled;
  final bool visible;
  final bool? selected;
  final bool? checked;
  final ElementBounds? bounds;
  final bool? rendered;
  final bool? inViewport;
  final String? parentId;
  final List<String> children;
  final List<String> actions;
  final FlutterObservationTargetRef? observationTargetRef;
  final UiScrollOwnerFacts? scrollOwner;
  final JsonMap data;
  final double confidence;
}

/// Opaque live-control reference. [snapshotId] is the issuance epoch and remains unchanged while
/// the same mounted control retains this target across later model-facing snapshots.
class FlutterObservationTargetRef {
  const FlutterObservationTargetRef({
    required this.ticketId,
    required this.snapshotId,
    this.version = operatorFlutterObservationTargetVersion,
  });

  final String version;
  final String ticketId;
  final String snapshotId;
}

class UiScrollOwnerFacts {
  const UiScrollOwnerFacts({
    required this.axes,
    required this.offsetX,
    required this.offsetY,
    required this.maxOffsetX,
    required this.maxOffsetY,
    required this.canScrollUp,
    required this.canScrollDown,
    required this.canScrollLeft,
    required this.canScrollRight,
    required this.viewportWidth,
    required this.viewportHeight,
    this.kind = 'element',
  });

  final String kind;
  final List<String> axes;
  final double offsetX;
  final double offsetY;
  final double maxOffsetX;
  final double maxOffsetY;
  final bool canScrollUp;
  final bool canScrollDown;
  final bool canScrollLeft;
  final bool canScrollRight;
  final double viewportWidth;
  final double viewportHeight;
}

class ElementBounds {
  const ElementBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;
}

class NetworkTimeline {
  const NetworkTimeline({required this.events});

  final List<NetworkEvent> events;
}

class NetworkEvent {
  const NetworkEvent({
    required this.id,
    required this.timestamp,
    required this.request,
    required this.redacted,
    this.response,
    this.error,
    this.tags = const <String>[],
  });

  final String id;
  final DateTime timestamp;
  final NetworkRequest request;
  final NetworkResponse? response;
  final NetworkError? error;
  final List<String> tags;
  final bool redacted;
}

class NetworkRequest {
  const NetworkRequest({
    required this.method,
    required this.url,
    this.path,
    this.query = const <String, Object?>{},
    this.headers = const <String, String>{},
    this.body,
  });

  final String method;
  final String url;
  final String? path;
  final JsonMap query;
  final Map<String, String> headers;
  final Object? body;
}

class NetworkResponse {
  const NetworkResponse({
    required this.status,
    required this.ok,
    this.headers = const <String, String>{},
    this.body,
  });

  final int status;
  final bool ok;
  final Map<String, String> headers;
  final Object? body;
}

class NetworkError {
  const NetworkError({
    required this.type,
    required this.message,
    this.retryable,
  });

  final String type;
  final String message;
  final bool? retryable;
}

class NetworkMockMatch {
  const NetworkMockMatch({
    this.method,
    this.url,
    this.urlContains,
    this.urlPattern,
    this.path,
    this.pathContains,
    this.pathPattern,
    this.query = const <String, Object?>{},
    this.headers = const <String, String>{},
  });

  final String? method;
  final String? url;
  final String? urlContains;
  final String? urlPattern;
  final String? path;
  final String? pathContains;
  final String? pathPattern;
  final JsonMap query;
  final Map<String, String> headers;
}

class NetworkMockResponse {
  const NetworkMockResponse({
    required this.status,
    this.headers = const <String, String>{},
    this.body,
    this.delay,
    this.error,
  });

  final int status;
  final Map<String, String> headers;
  final Object? body;
  final Duration? delay;
  final NetworkError? error;
}

class OperatorNetworkMockResolution {
  const OperatorNetworkMockResolution({
    required this.request,
    required this.matched,
    this.mockId,
    this.match,
    this.response,
    this.score,
    this.candidateCount = 0,
  });

  final NetworkRequest request;
  final bool matched;
  final String? mockId;
  final NetworkMockMatch? match;
  final NetworkMockResponse? response;
  final int? score;
  final int candidateCount;
}

class FirebaseMockMatch {
  const FirebaseMockMatch({
    required this.service,
    required this.operation,
    this.path,
    this.pathContains,
    this.pathPattern,
    this.name,
    this.nameContains,
    this.namePattern,
    this.bucket,
    this.bucketContains,
    this.bucketPattern,
    this.parameters = const <String, Object?>{},
  });

  final String service;
  final String operation;
  final String? path;
  final String? pathContains;
  final String? pathPattern;
  final String? name;
  final String? nameContains;
  final String? namePattern;
  final String? bucket;
  final String? bucketContains;
  final String? bucketPattern;
  final JsonMap parameters;
}

class FirebaseMockResponse {
  const FirebaseMockResponse({this.value, this.delay, this.error});

  final Object? value;
  final Duration? delay;
  final NetworkError? error;
}

/// A file a test hands to the app: its bytes, the run's name for it and its media type.
class OperatorSuppliedMedia {
  const OperatorSuppliedMedia({
    required this.bytes,
    required this.mediaId,
    required this.mediaType,
  });

  final Uint8List bytes;
  final String mediaId;
  final String mediaType;
}

class OperatorFirebaseMockResolution {
  const OperatorFirebaseMockResolution({
    required this.request,
    required this.matched,
    this.mockId,
    this.match,
    this.response,
    this.score,
    this.candidateCount = 0,
  });

  final FirebaseMockMatch request;
  final bool matched;
  final String? mockId;
  final FirebaseMockMatch? match;
  final FirebaseMockResponse? response;
  final int? score;
  final int candidateCount;
}

class StateStoreSnapshot {
  const StateStoreSnapshot({
    required this.source,
    required this.name,
    required this.value,
    required this.confidence,
    required this.redacted,
    this.schema,
  });

  final OperatorStateSource source;
  final String name;
  final Object? value;
  final String? schema;
  final double confidence;
  final bool redacted;
}

class FormSnapshot {
  const FormSnapshot({
    required this.id,
    required this.visible,
    required this.enabled,
    required this.fields,
    required this.confidence,
    this.name,
    this.route,
    this.submitted,
  });

  final String id;
  final String? name;
  final String? route;
  final bool visible;
  final bool enabled;
  final bool? submitted;
  final List<FormFieldSnapshot> fields;
  final double confidence;
}

class FormFieldSnapshot {
  const FormFieldSnapshot({
    required this.id,
    required this.enabled,
    required this.visible,
    required this.secure,
    required this.confidence,
    this.name,
    this.role,
    this.label,
    this.value,
    this.placeholder,
    this.checked,
    this.selected,
    this.required,
    this.errors = const <String>[],
  });

  final String id;
  final String? name;
  final String? role;
  final String? label;
  final Object? value;
  final String? placeholder;
  final bool? checked;
  final bool? selected;
  final bool enabled;
  final bool visible;
  final bool secure;
  final bool? required;
  final List<String> errors;
  final double confidence;
}

class FormFieldPatch {
  const FormFieldPatch({
    this.id,
    this.name,
    this.value,
    this.checked,
    this.selected,
    this.errors,
  });

  final String? id;
  final String? name;
  final Object? value;
  final bool? checked;
  final bool? selected;
  final List<String>? errors;
}

class VisualSnapshot {
  const VisualSnapshot({
    required this.capturedAt,
    required this.source,
    required this.frames,
    required this.regions,
    required this.redacted,
    this.captureTargets = const <VisualCaptureTarget>[],
    this.ocr = const <VisualTextRegion>[],
    this.metadata = const <String, Object?>{},
    this.analysis = const <String, Object?>{},
  });

  final DateTime capturedAt;
  final String source;
  final List<VisualFrame> frames;
  final List<VisualCaptureTarget> captureTargets;
  final List<VisualElementRegion> regions;
  final List<VisualTextRegion> ocr;
  final bool redacted;
  final JsonMap metadata;
  final JsonMap analysis;
}

class VisualFrame {
  const VisualFrame({
    required this.id,
    required this.format,
    required this.width,
    required this.height,
    required this.source,
    required this.redacted,
    this.surfaceId,
    this.documentGeneration,
    this.surfaceClip,
    this.surfaceScale,
    this.encoding,
    this.data,
    this.pixelRatio,
    this.hash,
    this.metadataOnly,
  });

  final String id;
  final String? surfaceId;
  final int? documentGeneration;
  final ElementBounds? surfaceClip;
  final VisualFrameScale? surfaceScale;
  final String format;
  final String? encoding;
  final String? data;
  final double width;
  final double height;
  final double? pixelRatio;
  final String? hash;
  final bool? metadataOnly;
  final String source;
  final bool redacted;
}

class VisualFrameScale {
  const VisualFrameScale({required this.x, required this.y});

  final double x;
  final double y;
}

class VisualCaptureTarget {
  const VisualCaptureTarget({
    required this.targetId,
    required this.kind,
    required this.frameIds,
    this.documentGeneration,
    this.unavailableReason,
    this.transportOmittedFrameCount,
  });

  final String targetId;
  final String kind;
  final int? documentGeneration;
  final List<String> frameIds;
  final String? unavailableReason;
  final int? transportOmittedFrameCount;
}

class VisualElementRegion {
  const VisualElementRegion({
    required this.elementId,
    required this.visible,
    required this.confidence,
    this.role,
    this.label,
    this.text,
    this.bounds,
    this.parentId,
  });

  final String elementId;
  final String? role;
  final String? label;
  final String? text;
  final ElementBounds? bounds;
  final String? parentId;
  final bool visible;
  final double confidence;
}

class VisualTextRegion {
  const VisualTextRegion({
    required this.text,
    required this.confidence,
    this.bounds,
  });

  final String text;
  final ElementBounds? bounds;
  final double confidence;
}

class StorageSnapshot {
  const StorageSnapshot({required this.entries});

  final List<StorageEntrySnapshot> entries;
}

class StorageEntrySnapshot {
  const StorageEntrySnapshot({
    required this.area,
    required this.key,
    required this.metadataOnly,
    required this.redacted,
    this.value,
    this.valueType,
    this.sizeBytes,
    this.namespace,
    this.source,
    this.updatedAt,
    this.confidence,
  });

  final String area;
  final String key;
  final Object? value;
  final String? valueType;
  final int? sizeBytes;
  final String? namespace;
  final String? source;
  final DateTime? updatedAt;
  final double? confidence;
  final bool metadataOnly;
  final bool redacted;
}

class LogEvent {
  const LogEvent({
    required this.id,
    required this.timestamp,
    required this.level,
    required this.message,
    required this.source,
    required this.redacted,
    this.data = const <String, Object?>{},
  });

  final String id;
  final DateTime timestamp;
  final String level;
  final String message;
  final OperatorLogSource source;
  final JsonMap data;
  final bool redacted;
}

class ErrorSnapshot {
  const ErrorSnapshot({
    required this.id,
    required this.timestamp,
    required this.type,
    required this.message,
    required this.handled,
    required this.fatal,
    required this.redacted,
    this.stack,
    this.source,
    this.data = const <String, Object?>{},
  });

  final String id;
  final DateTime timestamp;
  final String type;
  final String message;
  final String? stack;
  final String? source;
  final bool handled;
  final bool fatal;
  final JsonMap data;
  final bool redacted;
}

class DialogState {
  const DialogState({
    required this.id,
    required this.role,
    required this.buttons,
    required this.visible,
    required this.confidence,
    this.title,
    this.message,
  });

  final String id;
  final String role;
  final String? title;
  final String? message;
  final List<String> buttons;
  final bool visible;
  final double confidence;
}

class RedactionReport {
  const RedactionReport({
    required this.redacted,
    required this.fields,
    required this.paths,
  });

  final bool redacted;
  final List<String> fields;
  final List<String> paths;
}

class ElementTarget {
  const ElementTarget({
    this.id,
    this.role,
    this.label,
    this.text,
    this.selector,
    this.listContext,
    this.fallbackBounds,
    this.point,
    this.confidence,
    this.observationTargetRef,
  });

  final String? id;
  final String? role;
  final String? label;
  final String? text;
  final String? selector;
  final ListContextTarget? listContext;
  final FallbackPoint? fallbackBounds;

  /// Original page/logical point, retained for a final live scroll-owner hit test.
  final FallbackPoint? point;
  final double? confidence;
  final FlutterObservationTargetRef? observationTargetRef;
}

class ListContextTarget {
  const ListContextTarget({this.listId, this.itemText, this.itemIndex});

  final String? listId;
  final String? itemText;
  final int? itemIndex;
}

class FallbackPoint {
  const FallbackPoint({required this.x, required this.y});

  final double x;
  final double y;
}

class ActionCommand {
  const ActionCommand({
    required this.type,
    this.target,
    this.text,
    this.clearFirst,
    this.focusTarget,
    this.modifiers = const <String>[],
    this.source,
    this.destination,
    this.start,
    this.gesture,
    this.distancePx,
    this.duration,
    this.direction,
    this.amount,
    this.container,
    this.alignment,
    this.role,
    this.maxSteps,
    this.routeName,
    this.path,
    this.params = const <String, Object?>{},
    this.mode,
    this.until,
    this.timeout,
    this.reason,
    this.message,
    this.options = const <String>[],
    this.payload,
    this.url,
    this.method,
    this.headers = const <String, String>{},
    this.match,
    this.response,
    this.firebase,
    this.firebaseResponse,
    this.ttl,
    this.to,
    this.media,
    this.startIn,
    this.count,
    this.interval,
    this.store,
    this.value,
    this.area,
    this.key,
    this.namespace,
    this.metadataOnly,
    this.storageSource,
    this.valueType,
    this.formId,
    this.fields = const <FormFieldPatch>[],
    this.stateMode,
    this.scope,
    this.actionId,
    this.deliveryId,
    this.purpose,
    this.risk,
    this.expected = const <VerificationCondition>[],
    this.networkConditions,
  });

  final OperatorActionType type;
  final ElementTarget? target;
  final String? text;
  final bool? clearFirst;
  final bool? focusTarget;
  final List<String> modifiers;
  final ElementTarget? source;
  final ElementTarget? destination;
  final ElementTarget? start;
  final String? gesture;
  final double? distancePx;
  final Duration? duration;
  final String? direction;
  final String? amount;
  final ElementTarget? container;
  final String? alignment;

  /// scroll_to: optional role restriction and step limit for the text search.
  final String? role;
  final int? maxSteps;
  final String? routeName;
  final String? path;
  final JsonMap params;
  final String? mode;
  final WaitCondition? until;
  final Duration? timeout;
  final String? reason;
  final String? message;
  final List<String> options;
  final Object? payload;
  final String? url;
  final String? method;
  final Map<String, String> headers;
  final NetworkMockMatch? match;
  final NetworkMockResponse? response;
  final FirebaseMockMatch? firebase;
  final FirebaseMockResponse? firebaseResponse;
  final Duration? ttl;

  /// supply_media: the stand-in that gets the file, `camera` or `microphone`.
  final String? to;

  /// supply_media: the file, or null to take it back.
  final OperatorSuppliedMedia? media;

  /// supply_media to the microphone: when the words are due after the clip arrives.
  final Duration? startIn;

  /// tap, click and tap_point: presses in a row, as fast fingers press; one when null.
  final int? count;

  /// tap, click and tap_point: the wait from one press's release to the next press.
  final Duration? interval;
  final String? store;
  final Object? value;
  final String? area;
  final String? key;
  final String? namespace;
  final bool? metadataOnly;
  final String? storageSource;
  final String? valueType;
  final String? formId;
  final List<FormFieldPatch> fields;
  final String? stateMode;
  final String? scope;
  final String? actionId;
  final String? deliveryId;
  final String? purpose;
  final int? risk;
  final List<VerificationCondition> expected;

  /// Link conditions for `set_network_conditions`.
  final OperatorNetworkConditions? networkConditions;
}

class WaitCondition {
  const WaitCondition({
    required this.type,
    this.path,
    this.routeName,
    this.target,
    this.visible,
    this.duration,
    this.method,
    this.ok,
    this.store,
    this.statePath,
    this.equals,
  });

  final String type;
  final String? path;
  final String? routeName;
  final ElementTarget? target;
  final bool? visible;
  final Duration? duration;
  final String? method;
  final bool? ok;
  final String? store;
  final String? statePath;
  final Object? equals;
}

class ActionResult {
  const ActionResult({
    required this.ok,
    required this.action,
    this.message,
    this.error,
    this.evidence = const <VerificationEvidence>[],
    this.data = const <String, Object?>{},
  });

  final bool ok;
  final ActionCommand action;
  final String? message;
  final ActionError? error;
  final List<VerificationEvidence> evidence;
  final JsonMap data;
}

class ActionError {
  const ActionError({
    required this.type,
    required this.message,
    this.retryable,
  });

  final String type;
  final String message;
  final bool? retryable;
}

class VerificationCondition {
  const VerificationCondition({
    required this.source,
    this.target,
    this.textIncludes,
    this.labelIncludes,
    this.visible,
    this.store,
    this.path,
    this.equals,
    this.includes,
    this.method,
    this.status,
    this.ok,
    this.name,
    this.area,
    this.key,
    this.namespace,
    this.metadataOnly,
    this.formId,
    this.fieldId,
    this.checked,
    this.selected,
    this.value,
    this.errorsInclude,
    this.absentLevel,
  });

  final OperatorVerificationSource source;
  final ElementTarget? target;
  final String? textIncludes;
  final String? labelIncludes;
  final bool? visible;
  final String? store;
  final String? path;
  final Object? equals;
  final Object? includes;
  final String? method;
  final int? status;
  final bool? ok;
  final String? name;
  final String? area;
  final String? key;
  final String? namespace;
  final bool? metadataOnly;
  final String? formId;
  final String? fieldId;
  final bool? checked;
  final bool? selected;
  final Object? value;
  final String? errorsInclude;
  final String? absentLevel;
}

class VerificationEvidence {
  const VerificationEvidence({
    required this.source,
    required this.condition,
    required this.ok,
    this.detail,
  });

  final OperatorVerificationSource source;
  final String condition;
  final bool ok;
  final String? detail;
}

class VerificationResult {
  const VerificationResult({
    required this.ok,
    required this.evidence,
    this.reason,
  });

  final bool ok;
  final List<VerificationEvidence> evidence;
  final String? reason;
}

class VerificationRequest {
  const VerificationRequest({
    required this.action,
    required this.before,
    required this.after,
    required this.result,
  });

  final ActionCommand action;
  final AppSnapshot before;
  final AppSnapshot after;
  final ActionResult result;
}

class PolicyDecision {
  const PolicyDecision({
    required this.decision,
    required this.risk,
    required this.reason,
    this.message,
  });

  final OperatorPolicyDecisionType decision;
  final int risk;
  final String reason;
  final String? message;
}

/// Link conditions applied inside the app to every real HTTP request it sends: the same fields
/// the browser applies through its own network emulation.
class OperatorNetworkConditions {
  const OperatorNetworkConditions({
    this.offline,
    this.latencyMs,
    this.jitterMs,
    this.downloadKbps,
    this.uploadKbps,
    this.failureRate,
    this.failureStatus,
    this.seed,
  });

  final bool? offline;
  final int? latencyMs;
  final int? jitterMs;
  final double? downloadKbps;
  final double? uploadKbps;

  /// 0..1 probability that one request fails.
  final double? failureRate;

  /// When set, a failed request answers with this HTTP status instead of a connection error.
  final int? failureStatus;

  /// Makes jitter and failures repeat exactly from run to run.
  final String? seed;

  bool get isEmpty =>
      offline != true &&
      (latencyMs ?? 0) <= 0 &&
      (jitterMs ?? 0) <= 0 &&
      downloadKbps == null &&
      uploadKbps == null &&
      (failureRate ?? 0) <= 0;

  JsonMap toJson() => <String, Object?>{
    if (offline != null) 'offline': offline,
    if (latencyMs != null) 'latencyMs': latencyMs,
    if (jitterMs != null) 'jitterMs': jitterMs,
    if (downloadKbps != null) 'downloadKbps': downloadKbps,
    if (uploadKbps != null) 'uploadKbps': uploadKbps,
    if (failureRate != null) 'failureRate': failureRate,
    if (failureStatus != null) 'failureStatus': failureStatus,
    if (seed != null) 'seed': seed,
  };
}

/// One request's share of the active network conditions, decided once from the app's single
/// seeded sequence so requests from every isolate follow the same repeatable order.
class OperatorNetworkDecision {
  const OperatorNetworkDecision({
    required this.generation,
    this.offline = false,
    this.delay = Duration.zero,
    this.fail = false,
    this.failureStatus,
    this.downloadKbps,
    this.uploadKbps,
  });

  final int generation;
  final bool offline;
  final Duration delay;
  final bool fail;
  final int? failureStatus;
  final double? downloadKbps;
  final double? uploadKbps;

  JsonMap toMessage() => <String, Object?>{
    'generation': generation,
    'offline': offline,
    'delayMs': delay.inMilliseconds,
    'fail': fail,
    if (failureStatus != null) 'failureStatus': failureStatus,
    if (downloadKbps != null) 'downloadKbps': downloadKbps,
    if (uploadKbps != null) 'uploadKbps': uploadKbps,
  };

  static OperatorNetworkDecision? fromMessage(Object? value) {
    if (value is! Map) return null;
    final generation = value['generation'];
    if (generation is! int) return null;
    final delayMs = value['delayMs'];
    final failureStatus = value['failureStatus'];
    final downloadKbps = value['downloadKbps'];
    final uploadKbps = value['uploadKbps'];
    return OperatorNetworkDecision(
      generation: generation,
      offline: value['offline'] == true,
      delay: Duration(milliseconds: delayMs is int ? delayMs : 0),
      fail: value['fail'] == true,
      failureStatus: failureStatus is int ? failureStatus : null,
      downloadKbps: downloadKbps is num ? downloadKbps.toDouble() : null,
      uploadKbps: uploadKbps is num ? uploadKbps.toDouble() : null,
    );
  }
}
