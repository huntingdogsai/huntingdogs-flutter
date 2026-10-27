import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:huntingdogs/huntingdogs.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() {
    HttpOverrides.global = null;
  });

  test('HTTP capture preserves dart:io POST response streaming', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method == 'POST' && request.uri.path == '/auth/sign-in') {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, Object?>;
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, Object?>{
              'email': body['email'],
              'authenticated': true,
            }),
          );
        await request.response.close();
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });

    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-http-capture-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final disposeCapture = OperatorHttpCapture.install(operator);
    final client = HttpClient();

    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/auth/sign-in'),
      );
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(
        jsonEncode(<String, Object?>{
          'email': 'ada@example.com',
          'password': 'demo1234',
        }),
      );

      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 2));

      expect(response.statusCode, 200);
      expect(jsonDecode(text), containsPair('authenticated', true));

      final snapshot = await operator.getSnapshot();
      final events = snapshot.network.events
          .where((event) => event.request.path == '/auth/sign-in')
          .toList(growable: false);
      expect(events, hasLength(2));
      expect(events.first.request.body, containsPair('password', '[REDACTED]'));
      expect(events.last.response?.status, 200);
      expect(events.last.response?.ok, isTrue);
    } finally {
      client.close(force: true);
      disposeCapture();
      operator.dispose();
      await server.close(force: true);
    }
  });

  test('early HTTP capture observes clients after operator attaches', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object?>{'ok': true}));
      await request.response.close();
    });

    final disposeEarly = OperatorHttpCapture.installEarly(
      rechainInterval: Duration.zero,
    );
    final client = HttpClient();
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-http-early-capture-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final disposeCapture = OperatorHttpCapture.install(
      operator,
      rechainInterval: Duration.zero,
    );

    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/bootstrap/config'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await utf8.decoder.bind(response).join();

      final snapshot = await operator.getSnapshot();
      final events = snapshot.network.events
          .where((event) => event.request.path == '/bootstrap/config')
          .toList(growable: false);
      expect(events, hasLength(2));
      expect(events.last.response?.status, 200);
    } finally {
      client.close(force: true);
      disposeCapture();
      disposeEarly();
      operator.dispose();
      await server.close(force: true);
    }
  });

  test('HTTP capture re-chains after an app replaces HttpOverrides', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object?>{'rechain': true}));
      await request.response.close();
    });

    final disposeEarly = OperatorHttpCapture.installEarly(
      rechainInterval: const Duration(milliseconds: 10),
    );
    HttpOverrides.global = _PassthroughOverrides();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-http-rechain-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final disposeCapture = OperatorHttpCapture.install(
      operator,
      rechainInterval: Duration.zero,
    );
    final client = HttpClient();

    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/after/override'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await utf8.decoder.bind(response).join();

      final snapshot = await operator.getSnapshot();
      final events = snapshot.network.events
          .where((event) => event.request.path == '/after/override')
          .toList(growable: false);
      expect(events, hasLength(2));
      expect(events.last.response?.status, 200);
    } finally {
      client.close(force: true);
      disposeCapture();
      disposeEarly();
      operator.dispose();
      await server.close(force: true);
    }
  });

  test(
    'HTTP capture can mock dart:io requests without hitting server',
    () async {
      var serverHit = false;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        serverHit = true;
        request.response.statusCode = 500;
        await request.response.close();
      });

      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-http-mock-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final disposeCapture = OperatorHttpCapture.install(
        operator,
        rechainInterval: Duration.zero,
      );
      final client = HttpClient();
      final mockId = operator.installNetworkMock(
        const NetworkMockMatch(method: 'GET', path: '/feature-flags'),
        const NetworkMockResponse(
          status: 200,
          body: <String, Object?>{'newCheckout': true},
        ),
      );

      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/feature-flags'),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 2),
        );
        final text = await utf8.decoder.bind(response).join();

        expect(response.statusCode, 200);
        expect(jsonDecode(text), containsPair('newCheckout', true));
        expect(serverHit, isFalse);

        final snapshot = await operator.getSnapshot();
        final events = snapshot.network.events
            .where((event) => event.request.path == '/feature-flags')
            .toList(growable: false);
        expect(events, hasLength(2));
        expect(events.first.tags, contains('mock'));
        expect(events.first.tags, contains('mockId:$mockId'));
        expect(events.last.tags, contains('mockId:$mockId'));
        expect(events.last.response?.body, containsPair('newCheckout', true));
      } finally {
        client.close(force: true);
        disposeCapture();
        operator.dispose();
        await server.close(force: true);
      }
    },
  );

  test('HTTP capture tags real fallthrough when active mocks miss', () async {
    var serverHit = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      serverHit = true;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object?>{'real': true}));
      await request.response.close();
    });

    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-http-mock-miss-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final disposeCapture = OperatorHttpCapture.install(
      operator,
      rechainInterval: Duration.zero,
    );
    final client = HttpClient();
    operator.installNetworkMock(
      const NetworkMockMatch(method: 'GET', path: '/mocked-only'),
      const NetworkMockResponse(status: 200),
    );

    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/real-data'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await utf8.decoder.bind(response).join();

      expect(response.statusCode, 200);
      expect(serverHit, isTrue);

      final snapshot = await operator.getSnapshot();
      final events = snapshot.network.events
          .where((event) => event.request.path == '/real-data')
          .toList(growable: false);
      expect(events, hasLength(2));
      expect(events.first.tags, contains('mockMiss'));
      expect(events.first.tags, contains('activeMockCount:1'));
      expect(events.last.tags, contains('mockMiss'));
      expect(events.last.tags, contains('activeMockCount:1'));
      expect(events.last.response?.body, containsPair('real', true));
    } finally {
      client.close(force: true);
      disposeCapture();
      operator.dispose();
      await server.close(force: true);
    }
  });

  test(
    'HTTP capture observes Dio requests through dart:io overrides',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/inventory') {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode(<String, Object?>{
                'items': <Object?>[
                  <String, Object?>{'sku': 'coke', 'stock': 12},
                ],
              }),
            );
          await request.response.close();
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });

      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-http-dio-capture-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final disposeCapture = OperatorHttpCapture.install(
        operator,
        rechainInterval: Duration.zero,
      );
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));

      try {
        final response = await dio.get<Map<String, Object?>>('/inventory');

        expect(response.statusCode, 200);
        expect(response.data?['items'], isA<List<Object?>>());

        final snapshot = await operator.getSnapshot();
        final events = snapshot.network.events
            .where((event) => event.request.path == '/inventory')
            .toList(growable: false);
        expect(events, hasLength(2));
        expect(events.last.response?.status, 200);
        expect(events.last.response?.body, contains('items'));
      } finally {
        dio.close(force: true);
        disposeCapture();
        operator.dispose();
        await server.close(force: true);
      }
    },
  );

  test('HTTP capture can mock Dio requests before the server is hit', () async {
    var serverHit = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      serverHit = true;
      request.response.statusCode = 503;
      await request.response.close();
    });

    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-http-dio-mock-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final disposeCapture = OperatorHttpCapture.install(
      operator,
      rechainInterval: Duration.zero,
    );
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
    final mockId = operator.installNetworkMock(
      const NetworkMockMatch(method: 'GET', path: '/checkout/config'),
      const NetworkMockResponse(
        status: 200,
        body: <String, Object?>{
          'paymentEnabled': false,
          'maintenanceBanner': 'Operator mock',
        },
      ),
    );

    try {
      final response = await dio.get<Map<String, Object?>>('/checkout/config');

      expect(response.statusCode, 200);
      expect(response.data, containsPair('paymentEnabled', false));
      expect(serverHit, isFalse);

      final snapshot = await operator.getSnapshot();
      final events = snapshot.network.events
          .where((event) => event.request.path == '/checkout/config')
          .toList(growable: false);
      expect(events, hasLength(2));
      expect(events.first.tags, contains('mock'));
      expect(events.first.tags, contains('mockId:$mockId'));
      expect(events.last.tags, contains('mockId:$mockId'));
      expect(
        events.last.response?.body,
        containsPair('maintenanceBanner', 'Operator mock'),
      );
    } finally {
      dio.close(force: true);
      disposeCapture();
      operator.dispose();
      await server.close(force: true);
    }
  });

  test(
    'network virtualization probe proves active HttpOverrides interception',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-http-probe-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final disposeCapture = OperatorHttpCapture.install(
        operator,
        rechainInterval: Duration.zero,
      );
      final adapter = OperatorFlutterAdapter(operator);

      try {
        final result = await adapter.execute(
          const ActionCommand(
            type: OperatorActionType.probeNetworkVirtualization,
            timeout: Duration(seconds: 1),
          ),
        );

        expect(
          result.ok,
          isTrue,
          reason:
              'message=${result.message}; error=${result.error?.type}:'
              '${result.error?.message}; evidence=${result.evidence.map((item) => '${item.condition}:${item.ok}:${item.detail}').join('|')}',
        );
        expect(result.message, contains('Network virtualization probe'));
        expect(
          result.evidence
              .where(
                (item) => item.source == OperatorVerificationSource.network,
              )
              .every((item) => item.ok),
          isTrue,
        );

        final snapshot = await operator.getSnapshot();
        final probeEvents = snapshot.network.events
            .where(
              (event) =>
                  event.request.path?.startsWith('/__operator_probe__/') ??
                  false,
            )
            .toList(growable: false);
        expect(probeEvents.length, greaterThanOrEqualTo(2));
        expect(probeEvents.first.tags, contains('mock'));
        expect(
          probeEvents.last.response?.headers['x-operator-mock'],
          equals('true'),
        );
        expect(
          operator.hasActiveNetworkMocks,
          isFalse,
          reason: 'probe-installed network mock should be removed after proof',
        );
      } finally {
        disposeCapture();
        operator.dispose();
      }
    },
  );

  test(
    'network virtualization probe preserves custom headers for HEAD mocks',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-http-head-probe-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final disposeCapture = OperatorHttpCapture.install(
        operator,
        rechainInterval: Duration.zero,
      );
      final adapter = OperatorFlutterAdapter(operator);

      try {
        final result = await adapter.execute(
          const ActionCommand(
            type: OperatorActionType.probeNetworkVirtualization,
            method: 'HEAD',
            url: 'https://connectivitycheck.gstatic.com/generate_204',
            match: NetworkMockMatch(method: 'HEAD', path: '/generate_204'),
            response: NetworkMockResponse(
              status: 204,
              headers: <String, String>{'x-operator-probe': 'head-probe'},
              body: '',
            ),
            timeout: Duration(seconds: 1),
          ),
        );

        expect(
          result.ok,
          isTrue,
          reason:
              'message=${result.message}; error=${result.error?.type}:'
              '${result.error?.message}; evidence=${result.evidence.map((item) => '${item.condition}:${item.ok}:${item.detail}').join('|')}',
        );
        expect(
          result.evidence
              .where(
                (item) => item.source == OperatorVerificationSource.network,
              )
              .every((item) => item.ok),
          isTrue,
        );
        expect(
          operator.hasActiveNetworkMocks,
          isFalse,
          reason: 'custom HEAD probe mock should not remain active after proof',
        );
      } finally {
        disposeCapture();
        operator.dispose();
      }
    },
  );

  test(
    'network virtualization probe preserves custom headers through JSON commands',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-http-json-head-probe-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final disposeCapture = OperatorHttpCapture.install(
        operator,
        rechainInterval: Duration.zero,
      );
      final adapter = OperatorFlutterAdapter(operator);

      try {
        final command = operatorActionCommandFromJson(<String, Object?>{
          'type': 'probe_network_virtualization',
          'method': 'HEAD',
          'url': 'https://connectivitycheck.gstatic.com/generate_204',
          'match': <String, Object?>{'method': 'HEAD', 'path': '/generate_204'},
          'response': <String, Object?>{
            'status': 204,
            'headers': <String, Object?>{'x-operator-probe': 'json-head-probe'},
            'body': '',
          },
          'timeoutMs': 1000,
        });
        final result = await adapter.execute(command);

        expect(
          result.ok,
          isTrue,
          reason:
              'message=${result.message}; error=${result.error?.type}:'
              '${result.error?.message}; evidence=${result.evidence.map((item) => '${item.condition}:${item.ok}:${item.detail}').join('|')}',
        );
        expect(
          result.evidence
              .where(
                (item) => item.source == OperatorVerificationSource.network,
              )
              .every((item) => item.ok),
          isTrue,
        );
        expect(
          operator.hasActiveNetworkMocks,
          isFalse,
          reason:
              'JSON-installed probe mock should not remain active after proof',
        );
      } finally {
        disposeCapture();
        operator.dispose();
      }
    },
  );

  test(
    'HTTP capture matches header-scoped mocks before opening the socket',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-http-header-preopen-mock-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final disposeCapture = OperatorHttpCapture.install(
        operator,
        rechainInterval: Duration.zero,
      );
      operator.installNetworkMock(
        const NetworkMockMatch(
          method: 'GET',
          url: 'https://operator.invalid/secure-flags',
          headers: <String, String>{'x-test-scenario': 'header-match'},
        ),
        const NetworkMockResponse(
          status: 209,
          headers: <String, String>{'x-header-mock': 'matched'},
          body: <String, Object?>{'fromHeaderScopedMock': true},
        ),
      );

      try {
        final client = HttpClient();
        final request = await client.getUrl(
          Uri.parse('https://operator.invalid/secure-flags'),
        );
        request.headers.set('x-test-scenario', 'header-match');
        final response = await request.close();
        final body = jsonDecode(await utf8.decoder.bind(response).join());

        expect(response.statusCode, 209);
        expect(response.headers.value('x-operator-mock'), 'true');
        expect(response.headers.value('x-header-mock'), 'matched');
        expect(body, containsPair('fromHeaderScopedMock', true));

        final snapshot = await operator.getSnapshot();
        final events = snapshot.network.events
            .where((event) => event.request.path == '/secure-flags')
            .toList(growable: false);
        expect(events, hasLength(2));
        expect(events.first.tags, contains('mock'));
        expect(
          events.first.request.headers,
          containsPair('x-test-scenario', 'header-match'),
        );
        expect(events.last.response?.status, 209);
      } finally {
        disposeCapture();
        operator.dispose();
      }
    },
  );

  test('HTTP capture forwards worker-isolate requests', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object?>{'worker': true}));
      await request.response.close();
    });

    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-http-isolate-capture-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final disposeCapture = OperatorHttpCapture.install(
      operator,
      rechainInterval: Duration.zero,
    );
    final url = 'http://127.0.0.1:${server.port}/worker/bootstrap';

    try {
      await Isolate.run(() => _workerGet(url));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final snapshot = await operator.getSnapshot();
      final events = snapshot.network.events
          .where((event) => event.request.path == '/worker/bootstrap')
          .toList(growable: false);
      expect(events, hasLength(2));
      expect(events.first.tags, contains('request'));
      expect(events.last.response?.status, 200);
      expect(events.last.response?.body, containsPair('worker', true));
    } finally {
      disposeCapture();
      operator.dispose();
      await server.close(force: true);
    }
  });

  test('HTTP capture can mock worker-isolate requests', () async {
    var serverHit = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      serverHit = true;
      request.response.statusCode = 500;
      await request.response.close();
    });

    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-http-isolate-mock-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final disposeCapture = OperatorHttpCapture.install(
      operator,
      rechainInterval: Duration.zero,
    );
    operator.installNetworkMock(
      const NetworkMockMatch(method: 'GET', path: '/worker/flags'),
      const NetworkMockResponse(
        status: 200,
        body: <String, Object?>{'fromWorkerMock': true},
      ),
    );
    final url = 'http://127.0.0.1:${server.port}/worker/flags';

    try {
      final body = await Isolate.run(() => _workerGet(url));

      expect(jsonDecode(body), containsPair('fromWorkerMock', true));
      expect(serverHit, isFalse);

      final snapshot = await operator.getSnapshot();
      final events = snapshot.network.events
          .where((event) => event.request.path == '/worker/flags')
          .toList(growable: false);
      expect(events, hasLength(2));
      expect(events.first.tags, contains('mock'));
      expect(events.last.response?.body, containsPair('fromWorkerMock', true));
    } finally {
      disposeCapture();
      operator.dispose();
      await server.close(force: true);
    }
  });

  test('live bridge streams runtime events over server sent events', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-live-bridge-stream-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final bridge = await OperatorFlutterLiveBridge.start(
      OperatorFlutterAdapter(operator),
    );
    final client = HttpClient();
    final buffer = StringBuffer();
    StreamSubscription<String>? subscription;

    try {
      final request = await client.getUrl(
        bridge.url.resolve('/events?snapshot=false'),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'text/event-stream');
      subscription = utf8.decoder.bind(response).listen(buffer.write);

      operator.captureRoute(path: '/sse', name: 'sse');
      operator.captureStateChange(
        source: OperatorStateSource.provider,
        name: 'SseState',
        value: <String, Object?>{'ready': true},
      );

      await _waitUntil(
        () =>
            buffer.toString().contains('event: route') &&
            buffer.toString().contains('"path":"/sse"') &&
            buffer.toString().contains('event: state') &&
            buffer.toString().contains('"name":"SseState"'),
        debug: buffer.toString,
      );
    } finally {
      await subscription?.cancel();
      client.close(force: true);
      await bridge.close();
      operator.dispose();
    }
  });
}

class _PassthroughOverrides extends HttpOverrides {}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
  String Function()? debug,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException(
    'condition was not met within $timeout${debug == null ? '' : ': ${debug()}'}',
  );
}

Future<String> _workerGet(String url) async {
  final disposeCapture = OperatorHttpCapture.installEarly(
    rechainInterval: Duration.zero,
  );
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 2));
    return utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 2));
  } finally {
    disposeCapture();
  }
}
