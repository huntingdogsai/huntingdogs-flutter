import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:huntingdogs/huntingdogs.dart';
import 'package:test/test.dart';

/// set_network_conditions inside the app: offline, slow and flaky apply to every real dart:io
/// request, including requests from background isolates, and the server never sees a request the
/// conditions stopped.
void main() {
  tearDown(() {
    HttpOverrides.global = null;
  });

  test(
    'offline stops every request before it leaves the app; clearing restores it',
    () async {
      final harness = await _Harness.start();
      try {
        final set = await harness.execute(
          const ActionCommand(
            type: OperatorActionType.setNetworkConditions,
            networkConditions: OperatorNetworkConditions(offline: true),
          ),
        );
        expect(set.ok, isTrue, reason: set.error?.message);
        expect(set.data['appliesTo'], contains('dart_io_http_isolates'));

        await expectLater(
          harness.get('/profile'),
          throwsA(isA<SocketException>()),
        );
        expect(harness.serverHits, 0, reason: 'nothing reached the server');
        final blocked = (await harness.events('/profile')).last;
        expect(
          blocked.tags,
          containsAll(<String>['network_conditions', 'offline']),
        );

        final cleared = await harness.execute(
          const ActionCommand(type: OperatorActionType.clearNetworkConditions),
        );
        expect(cleared.ok, isTrue);
        expect(await harness.get('/profile'), 'ok');
        expect(harness.serverHits, 1);
      } finally {
        await harness.close();
      }
    },
  );

  test('latency and jitter delay each request by the chosen amount', () async {
    final harness = await _Harness.start();
    try {
      await harness.execute(
        const ActionCommand(
          type: OperatorActionType.setNetworkConditions,
          networkConditions: OperatorNetworkConditions(
            latencyMs: 300,
            jitterMs: 50,
            seed: 'slow',
          ),
        ),
      );
      final clock = Stopwatch()..start();
      expect(await harness.get('/slow'), 'ok');
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(250));
    } finally {
      await harness.close();
    }
  });

  test('a failure status answers without reaching the server', () async {
    final harness = await _Harness.start();
    try {
      await harness.execute(
        const ActionCommand(
          type: OperatorActionType.setNetworkConditions,
          networkConditions: OperatorNetworkConditions(
            failureRate: 1,
            failureStatus: 503,
          ),
        ),
      );
      final response = await harness.request('/flaky');
      expect(response.statusCode, 503);
      expect(harness.serverHits, 0);
      final answered = (await harness.events('/flaky')).last;
      expect(answered.response?.status, 503);
      expect(
        answered.tags,
        containsAll(<String>['network_conditions', 'failure_status']),
      );
    } finally {
      await harness.close();
    }
  });

  test(
    'a failure without a status drops the connection like a real network',
    () async {
      final harness = await _Harness.start();
      try {
        await harness.execute(
          const ActionCommand(
            type: OperatorActionType.setNetworkConditions,
            networkConditions: OperatorNetworkConditions(failureRate: 1),
          ),
        );
        await expectLater(
          harness.get('/flaky'),
          throwsA(isA<SocketException>()),
        );
        expect(harness.serverHits, 0);
      } finally {
        await harness.close();
      }
    },
  );

  test('the same seed repeats the same failures in the same order', () async {
    Future<List<bool>> run() async {
      final harness = await _Harness.start();
      try {
        await harness.execute(
          const ActionCommand(
            type: OperatorActionType.setNetworkConditions,
            networkConditions: OperatorNetworkConditions(
              failureRate: 0.5,
              seed: 'repeat-me',
            ),
          ),
        );
        final outcomes = <bool>[];
        for (var i = 0; i < 12; i += 1) {
          try {
            await harness.get('/coin');
            outcomes.add(true);
          } on SocketException {
            outcomes.add(false);
          }
        }
        return outcomes;
      } finally {
        await harness.close();
      }
    }

    final first = await run();
    final second = await run();
    expect(second, first);
    expect(first, contains(true));
    expect(first, contains(false));
  });

  test('a download speed paces the response body', () async {
    final harness = await _Harness.start(bodyBytes: 4096);
    try {
      await harness.execute(
        const ActionCommand(
          type: OperatorActionType.setNetworkConditions,
          networkConditions: OperatorNetworkConditions(downloadKbps: 64),
        ),
      );
      final clock = Stopwatch()..start();
      final body = await harness.get('/large');
      expect(body.length, 4096);
      // 4096 bytes at 64 kbit/s take half a second.
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(400));
    } finally {
      await harness.close();
    }
  });

  test('offline also stops requests from a background isolate', () async {
    final harness = await _Harness.start();
    try {
      await harness.execute(
        const ActionCommand(
          type: OperatorActionType.setNetworkConditions,
          networkConditions: OperatorNetworkConditions(offline: true),
        ),
      );
      final url = 'http://127.0.0.1:${harness.port}/worker';
      final outcome = await Isolate.run(() => _workerGet(url));
      expect(outcome, startsWith('SocketException'));
      expect(harness.serverHits, 0);
    } finally {
      await harness.close();
    }
  });

  test('clear_simulation all also clears network conditions', () async {
    final harness = await _Harness.start();
    try {
      await harness.execute(
        const ActionCommand(
          type: OperatorActionType.setNetworkConditions,
          networkConditions: OperatorNetworkConditions(offline: true),
        ),
      );
      await harness.execute(
        const ActionCommand(
          type: OperatorActionType.clearSimulation,
          scope: 'all',
        ),
      );
      expect(harness.operator.networkConditions, isNull);
      expect(await harness.get('/after'), 'ok');
    } finally {
      await harness.close();
    }
  });

  test('a listener added while conditions hold hears them at once', () async {
    final harness = await _Harness.start();
    try {
      await harness.execute(
        const ActionCommand(
          type: OperatorActionType.setNetworkConditions,
          networkConditions: OperatorNetworkConditions(offline: true),
        ),
      );
      OperatorNetworkConditions? heard;
      final dispose = harness.operator.addNetworkConditionsListener((
        conditions,
      ) {
        heard = conditions;
        return null;
      });
      await Future<void>.delayed(Duration.zero);
      expect(heard?.offline, isTrue);
      dispose();
    } finally {
      await harness.close();
    }
  });

  test('network conditions are refused in production', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-network-conditions-production',
        environment: OperatorEnvironment.production,
      ),
    );
    try {
      final result = await OperatorFlutterAdapter(operator).execute(
        const ActionCommand(
          type: OperatorActionType.setNetworkConditions,
          networkConditions: OperatorNetworkConditions(offline: true),
        ),
      );
      expect(result.ok, isFalse);
      expect(operator.networkConditions, isNull);
    } finally {
      operator.dispose();
    }
  });

  test(
    'the wire form is the shared browser shape and rejects malformed values',
    () {
      final command = operatorActionCommandFromJson(<String, Object?>{
        'type': 'set_network_conditions',
        'conditions': <String, Object?>{
          'offline': false,
          'latencyMs': 400,
          'downloadKbps': 256,
          'seed': 7,
        },
      });
      expect(command.type, OperatorActionType.setNetworkConditions);
      expect(command.networkConditions?.latencyMs, 400);
      expect(command.networkConditions?.downloadKbps, 256);
      expect(command.networkConditions?.seed, '7');
      final echoed =
          operatorActionResultToJson(
                ActionResult(ok: true, action: command),
              )['action']
              as Map;
      expect(echoed['type'], 'set_network_conditions');
      expect(echoed['conditions'], containsPair('latencyMs', 400));

      for (final bad in <Map<String, Object?>>[
        <String, Object?>{'failureRate': 2},
        <String, Object?>{'latencyMs': -1},
        <String, Object?>{'downloadKbps': 0},
        <String, Object?>{'failureStatus': 42},
        <String, Object?>{'offline': 'yes'},
      ]) {
        expect(
          () => operatorActionCommandFromJson(<String, Object?>{
            'type': 'set_network_conditions',
            'conditions': bad,
          }),
          throwsFormatException,
          reason: jsonEncode(bad),
        );
      }
    },
  );
}

class _Harness {
  _Harness(this.server, this.operator, this._disposeCapture);

  final HttpServer server;
  final OperatorFlutter operator;
  final void Function() _disposeCapture;
  final HttpClient _client = HttpClient();
  int serverHits = 0;

  int get port => server.port;

  static Future<_Harness> start({int bodyBytes = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-network-conditions-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final disposeCapture = OperatorHttpCapture.install(
      operator,
      rechainInterval: Duration.zero,
    );
    final harness = _Harness(server, operator, disposeCapture);
    server.listen((request) async {
      harness.serverHits += 1;
      request.response.statusCode = 200;
      request.response.write(bodyBytes > 0 ? 'x' * bodyBytes : 'ok');
      await request.response.close();
    });
    return harness;
  }

  Future<ActionResult> execute(ActionCommand command) =>
      OperatorFlutterAdapter(operator).execute(command);

  Future<HttpClientResponse> request(String path) async {
    final request = await _client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    return request.close().timeout(const Duration(seconds: 5));
  }

  Future<String> get(String path) async {
    final response = await request(path);
    return utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 5));
  }

  Future<List<NetworkEvent>> events(String path) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final snapshot = await operator.getSnapshot();
    return snapshot.network.events
        .where((event) => event.request.path == path)
        .toList(growable: false);
  }

  Future<void> close() async {
    _client.close(force: true);
    _disposeCapture();
    operator.dispose();
    await server.close(force: true);
  }
}

Future<String> _workerGet(String url) async {
  final disposeCapture = OperatorHttpCapture.installEarly(
    rechainInterval: Duration.zero,
  );
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 2));
    return await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 2));
  } on SocketException catch (error) {
    return 'SocketException: ${error.message}';
  } finally {
    client.close(force: true);
    disposeCapture();
  }
}
