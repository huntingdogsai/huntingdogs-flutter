import 'package:flutter/foundation.dart';

import 'adapter.dart';

export 'page_bridge_contract.dart';

/// Native builds keep using the loopback HTTP bridge. The page-local bridge is
/// installed only when compiled for Flutter Web.
class OperatorFlutterPageBridge {
  OperatorFlutterPageBridge._();

  static VoidCallback install(OperatorFlutterAdapter adapter) => () {};
}
