import 'dart:async';

import 'adapter.dart';
import 'protocol.dart';

export 'action_registry.dart';
export 'wire_codec.dart';

typedef OperatorBundledAppMapLoader = FutureOr<Object?> Function();
typedef OperatorHttpClientFactory = Object Function();

class OperatorProductionSessionConfig {
  const OperatorProductionSessionConfig({
    required this.endpoint,
    required this.sessionId,
    required this.appId,
    this.userId,
    this.platform = 'flutter',
    this.appVersion,
    this.token,
    this.sessionSecret,
    this.deviceId,
    this.operatorControlConsent = false,
    this.approvedPurposes = const <String>[],
    this.consentExpiresAt,
    this.pollWait = const Duration(seconds: 1),
    this.contextStreamInterval = const Duration(seconds: 1),
    this.contextPublishTimeout = const Duration(seconds: 2),
    this.runtimeEventDebounce = const Duration(milliseconds: 250),
    this.requestTimeout = const Duration(seconds: 10),
    this.commandExecutionTimeout = const Duration(seconds: 8),
    this.commandResultUploadTimeout = const Duration(seconds: 3),
    this.appMapManifest,
    this.bundledAppMap,
    this.bundledAppMapLoader,
    this.appMapManifestAssetPath = 'assets/operator/appmap-manifest.json',
    this.appMapAssetPath = 'assets/operator/appmap.json',
    this.uploadBundledAppMapWhenMissing = true,
    this.controlClientFactory,
  });

  final Uri endpoint;
  final String sessionId;
  final String appId;
  final String? userId;
  final String platform;
  final String? appVersion;
  final String? token;
  final String? sessionSecret;
  final String? deviceId;
  final bool operatorControlConsent;
  final List<String> approvedPurposes;
  final DateTime? consentExpiresAt;
  final Duration pollWait;
  final Duration contextStreamInterval;
  final Duration contextPublishTimeout;
  final Duration runtimeEventDebounce;
  final Duration requestTimeout;
  final Duration commandExecutionTimeout;
  final Duration commandResultUploadTimeout;
  final OperatorAppMapManifest? appMapManifest;
  final Object? bundledAppMap;
  final OperatorBundledAppMapLoader? bundledAppMapLoader;
  final String? appMapManifestAssetPath;
  final String? appMapAssetPath;
  final bool uploadBundledAppMapWhenMissing;
  final OperatorHttpClientFactory? controlClientFactory;
}

/// The browser build communicates through `OperatorFlutterPageBridge`.
/// Remote polling sessions remain native-only until a web transport is added.
class OperatorFlutterProductionSession {
  OperatorFlutterProductionSession({
    required this.adapter,
    required this.config,
  });

  final OperatorFlutterAdapter adapter;
  final OperatorProductionSessionConfig config;

  Future<void> connect() => Future<void>.error(_unsupported());

  Future<int> pumpOnce({Duration? wait}) => Future<int>.error(_unsupported());

  Future<void> start() => Future<void>.error(_unsupported());

  Future<void> publishSnapshot({String reason = 'manual'}) =>
      Future<void>.error(_unsupported());

  Future<void> close() async {}

  UnsupportedError _unsupported() => UnsupportedError(
    'Operator remote polling sessions are unavailable on Flutter Web; use the page-local bridge.',
  );
}
