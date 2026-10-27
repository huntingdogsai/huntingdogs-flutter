import 'adapter.dart';
import 'bridge_handlers.dart';

export 'wire_codec.dart';

/// The loopback HTTP bridge is native-only. Flutter Web uses
/// [OperatorFlutterPageBridge], installed automatically by [OperatorAppHost].
class OperatorFlutterLiveBridge {
  OperatorFlutterLiveBridge._();

  Uri get url =>
      throw UnsupportedError(
        'OperatorFlutterLiveBridge is unavailable on Flutter Web; use the page-local bridge.',
      );

  String get installationId =>
      throw UnsupportedError(
        'OperatorFlutterLiveBridge is unavailable on Flutter Web; use the page-local bridge.',
      );

  OperatorFlutterBridgeHandlers get handlers =>
      throw UnsupportedError(
        'OperatorFlutterLiveBridge is unavailable on Flutter Web; use the page-local bridge.',
      );

  static Future<OperatorFlutterLiveBridge> start(
    OperatorFlutterAdapter adapter, {
    String host = '127.0.0.1',
    int port = 0,
    String? token,
  }) {
    return Future<OperatorFlutterLiveBridge>.error(
      UnsupportedError(
        'OperatorFlutterLiveBridge is unavailable on Flutter Web; OperatorAppHost installs the page-local bridge automatically.',
      ),
    );
  }

  Future<void> close() async {}
}
