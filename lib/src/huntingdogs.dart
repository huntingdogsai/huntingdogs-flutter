// The names an app owner writes: the package's public face, over the runtime that does the work.
import 'app.dart';
import 'protocol.dart';
import 'runtime.dart';

/// Wraps your app's root widget so huntingdogs can test it: the screen as the app knows it, its
/// network calls and its state. It serves only in a QA build (one made with
/// `--dart-define=HUNTINGDOGS_PORT=8799`, or the older `OPERATOR_LIVE_BRIDGE_PORT`) whose
/// [HuntingdogsConfig.environment] is not [HuntingdogsEnvironment.production].
typedef HuntingdogsApp = OperatorAppHost;

/// What your app is called and which environment this build is: dev, staging or production.
typedef HuntingdogsConfig = OperatorFlutterConfig;

/// The environment a build runs in. In production the package stays silent.
typedef HuntingdogsEnvironment = OperatorEnvironment;

/// What is never sent to a test: fields to redact, body size, screenshots.
typedef HuntingdogsPrivacy = OperatorPrivacyConfig;
