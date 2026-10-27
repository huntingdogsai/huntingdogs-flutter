# huntingdogs for Flutter

[huntingdogs](https://github.com/huntingdogsai) tests your app on every pull request: it reads
the change, builds the app, plans the tests, runs each one on a fresh emulator and reports what
works and what broke, in plain words, on the pull request.

This package lets huntingdogs see your Flutter app the way the app sees itself: the screen, the
network calls it makes, its state. It goes into a QA build only. In a production build it does
nothing and serves nothing.

## Add it in three steps

1. Add the dependency to `pubspec.yaml`:

   ```yaml
   dependencies:
     huntingdogs: ^0.1.0
   ```

2. Wrap your root widget:

   ```dart
   import 'package:huntingdogs/huntingdogs.dart';

   void main() {
     runApp(HuntingdogsApp(
       config: const HuntingdogsConfig(
         appId: 'my-app',
         environment: HuntingdogsEnvironment.dev,
       ),
       child: const MyApp(),
     ));
   }
   ```

3. Build the QA app with the port the test machine talks to:

   ```sh
   flutter build apk --debug --dart-define=OPERATOR_LIVE_BRIDGE_PORT=8799
   ```

   A debug build is needed: the tests read the app's own storage, which Android allows only for
   debuggable apps. For your store build, leave the define out or set the environment to
   `HuntingdogsEnvironment.production`; the package then stays silent.

## What it does, and what it never does

- It listens on the phone's own loopback address only, on the port you gave. The test machine
  reaches it through `adb forward`. Nothing is open to the network.
- It records the app's network calls made with `dart:io` so a test can check what was sent and
  what came back, with the fields you list in `HuntingdogsPrivacy.redactFields` removed first.
- It never runs in production: with no port define, or with `environment: production`, nothing
  starts.
- It sends nothing anywhere by itself. The test machine asks; the package answers.

## Firebase

If your app uses Firebase, the optional `huntingdogs_firebase` package lets the tests see
Firestore reads and writes, sign-ins and function calls, and fail one of them on purpose.

## Licence

BSD 3-Clause. See [LICENSE](LICENSE).
