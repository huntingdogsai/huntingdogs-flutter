import 'dart:async';
import 'dart:convert';
import 'dart:io' as io show HttpOverrides;
import 'dart:io' show ContentType, HttpClient, HttpHeaders, HttpStatus;

import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

/// The native loopback bridge must answer the same contract the Flutter Web
/// page bridge answers, so one host implementation can drive both. Real
/// sockets need a plain test; the runtime behaviour behind the shared handlers
/// is proved separately with a pumped widget tree (bridge_handlers_test).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the loopback bridge serves the page-bridge contract over HTTP', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-live-bridge-contract',
        environment: OperatorEnvironment.dev,
      ),
    );
    addTearDown(operator.dispose);
    final binding = OperatorProductionBinding(operator: operator);
    final bridge = await OperatorFlutterLiveBridge.start(
      binding.adapter,
      port: 0,
      token: 'secret',
    );
    addTearDown(bridge.close);
    // flutter_test installs a mock HttpClient that answers 400 to everything;
    // this test needs the real loopback socket.
    io.HttpOverrides.global = null;
    final client = HttpClient();
    addTearDown(client.close);

    Future<(int, Map<String, Object?>)> call(
      String method,
      String path, {
      Object? body,
      String? token = 'secret',
    }) async {
      final request = await client.openUrl(
        method,
        bridge.url.replace(path: path),
      );
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      expect(
        text,
        isNotEmpty,
        reason:
            '$method $path returned ${response.statusCode} '
            '${response.reasonPhrase} with no body; headers=${response.headers}',
      );
      return (
        response.statusCode,
        Map<String, Object?>.from(jsonDecode(text) as Map),
      );
    }

    // The token guards every route.
    final (unauthorized, _) = await call('GET', '/health', token: null);
    expect(unauthorized, HttpStatus.unauthorized);

    // Health carries the shared method list plus this transport's extras,
    // and the same installation id the legacy route reports.
    final (healthStatus, health) = await call('GET', '/health');
    expect(healthStatus, HttpStatus.ok);
    expect(health['ok'], isTrue);
    expect(health['protocolVersion'], operatorFlutterPageBridgeProtocolVersion);
    expect(health['uiAuthority'], 'flutter_runtime');
    expect(health['appId'], 'flutter-live-bridge-contract');
    expect(health['framework'], 'flutter');
    expect(health['platform'], 'flutter');
    expect(
      health['methods'],
      containsAll(<String>[
        'getHealth',
        'getSnapshot',
        'getCapabilities',
        'getEvents',
        'execute',
        'observedOperations',
        'inspectPoint',
        'capture',
        'captureVisual',
      ]),
    );
    expect(health['installationId'], bridge.installationId);
    final (_, legacy) = await call('GET', '/healthz');
    expect(legacy['installationId'], bridge.installationId);

    // One capture round trip: health, snapshot and the event batch, the
    // shape the browser host assembles from three page calls.
    final (captureStatus, capture) = await call(
      'POST',
      '/capture',
      body: <String, Object?>{'issueActionTargets': true, 'afterSequence': 0},
    );
    expect(captureStatus, HttpStatus.ok);
    expect((capture['health'] as Map)['installationId'], bridge.installationId);
    final snapshot = Map<String, Object?>.from(capture['snapshot'] as Map);
    expect(snapshot['snapshotId'], isA<String>());
    expect((snapshot['app'] as Map)['platform'], 'flutter');
    expect((snapshot['app'] as Map)['framework'], 'flutter');
    expect((snapshot['ui'] as Map)['elements'], isA<List>());
    final eventBatch = capture['eventBatch'] as Map;
    expect(eventBatch['events'], isA<List>());
    expect(eventBatch['lastSequence'], isA<int>());
    expect(eventBatch['overflow'], isFalse);

    // Point inspection is wired: with no widget tree mounted nothing is under
    // the point, and a malformed request is a bad request.
    final (inspectStatus, inspected) = await call(
      'POST',
      '/inspectPoint',
      body: <String, Object?>{'x': 10, 'y': 10},
    );
    expect(inspectStatus, HttpStatus.ok);
    expect(inspected['status'], 'not_found');
    final (badInspect, badInspectBody) = await call(
      'POST',
      '/inspectPoint',
      body: <String, Object?>{'x': 'no'},
    );
    expect(badInspect, HttpStatus.badRequest);
    expect(badInspectBody['error'], contains('numeric x and y'));

    // Observed-operation control validates synchronously and reports an
    // explicit rejection; a stale installation id is refused outright.
    final (opsStatus, ops) = await call(
      'POST',
      '/observedOperations',
      body: <String, Object?>{
        'installationId': bridge.installationId,
        'request': <String, Object?>{'kind': 'status', 'faultId': 'missing'},
      },
    );
    expect(opsStatus, HttpStatus.ok);
    expect(ops['installationId'], bridge.installationId);
    expect((ops['data'] as Map)['rejected'], isTrue);
    final (staleStatus, stale) = await call(
      'POST',
      '/observedOperations',
      body: <String, Object?>{
        'installationId': 'someone-else',
        'request': <String, Object?>{'kind': 'status', 'faultId': 'missing'},
      },
    );
    expect(staleStatus, HttpStatus.conflict);
    expect(stale['error'], 'observed_operations_installation_changed');

    // Host key preparation answers through the runtime's own actuator; with
    // an unknown target it asks for a fresh observation instead of dispatching.
    final (keyStatus, key) = await call(
      'POST',
      '/prepareKeyTarget',
      body: <String, Object?>{
        'action': <String, Object?>{
          'type': 'key',
          'target': <String, Object?>{'id': 'anything'},
          'key': 'Enter',
          'purpose': 'probe_key_support',
          'risk': 1,
        },
      },
    );
    expect(keyStatus, HttpStatus.ok);
    expect(key['ok'], isFalse);
    expect(
      (key['error'] as Map)['type'],
      anyOf('flutter_host_key_unavailable', 'semantic_reobservation_required'),
    );

    // The in-app camera route answers with the frame list and the capture
    // targets; with no widget tree mounted it reports why no frame exists.
    final (visualStatus, visual) = await call(
      'POST',
      '/captureVisual',
      body: <String, Object?>{'reason': 'contract_test'},
    );
    expect(visualStatus, HttpStatus.ok);
    expect(visual['frames'], isA<List>());
    expect(visual['captureTargets'], isA<List>());

    // The event stream holds its connection open; other routes must not queue
    // behind it.
    final streamRequest = await client.openUrl(
      'GET',
      bridge.url.replace(path: '/events', queryParameters: {'snapshot': 'false'}),
    );
    streamRequest.headers.set(HttpHeaders.authorizationHeader, 'Bearer secret');
    final streamResponse = await streamRequest.close();
    final firstChunk = streamResponse.first;
    final (whileStreaming, streamingHealth) = await call('GET', '/health')
        .timeout(const Duration(seconds: 5));
    expect(whileStreaming, HttpStatus.ok);
    expect(streamingHealth['ok'], isTrue);
    await firstChunk;
    await streamResponse.detachSocket().then((socket) => socket.destroy());

    // The legacy routes keep working next to the new ones.
    final (execStatus, exec) = await call(
      'POST',
      '/execute',
      body: <String, Object?>{
        'action': <String, Object?>{
          'type': 'wait',
          'until': <String, Object?>{'type': 'elapsed', 'durationMs': 1},
          'timeoutMs': 50,
          'purpose': 'legacy_route',
          'risk': 0,
        },
      },
    );
    expect(execStatus, HttpStatus.ok);
    expect(exec['ok'], isTrue, reason: exec.toString());
    final (capabilitiesStatus, capabilities) = await call(
      'GET',
      '/capabilities',
    );
    expect(capabilitiesStatus, HttpStatus.ok);
    expect((capabilities['actions'] as Map)['scrollTo'], isTrue);
    final (unknownStatus, unknown) = await call('GET', '/nope');
    expect(unknownStatus, HttpStatus.notFound);
    expect(unknown['error'], 'not_found:GET:/nope');

    // Closing retires the handlers: the health they report says so.
    await bridge.close();
    expect(bridge.handlers.closed, isTrue);
    expect(bridge.handlers.health()['ok'], isFalse);
  });

  test(
    'a number JSON cannot carry fails neither a reply nor the event stream',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-live-bridge-unreadable',
          environment: OperatorEnvironment.dev,
        ),
      );
      addTearDown(operator.dispose);
      final binding = OperatorProductionBinding(operator: operator);
      final bridge = await OperatorFlutterLiveBridge.start(
        binding.adapter,
        port: 0,
        token: 'secret',
      );
      addTearDown(bridge.close);
      io.HttpOverrides.global = null;
      final client = HttpClient();
      addTearDown(client.close);

      // The event stream goes on after an event holding such a number.
      final streamRequest = await client.openUrl(
        'GET',
        bridge.url.replace(
          path: '/events',
          queryParameters: {'snapshot': 'false'},
        ),
      );
      streamRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer secret',
      );
      final lines = StreamIterator(
        (await streamRequest.close())
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
      addTearDown(lines.cancel);
      Future<String> nextLine() async {
        if (!await lines.moveNext().timeout(const Duration(seconds: 5))) {
          throw StateError('the event stream ended');
        }
        return lines.current;
      }

      Future<Map<String, Object?>> nextLog() async {
        for (;;) {
          final line = await nextLine();
          if (!line.startsWith('data: ')) continue;
          final event = Map<String, Object?>.from(
            jsonDecode(line.substring('data: '.length)) as Map,
          );
          if (event['type'] == 'log') return event;
        }
      }

      expect(
        await nextLine(),
        startsWith(': operator_flutter_live_bridge connected'),
      );
      // The stream starts listening right after that line: repeat a marker
      // until one arrives, so the events below cannot come before it listens.
      final marked = nextLog();
      final marker = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => operator.captureLog('debug', 'marker'),
      );
      addTearDown(marker.cancel);
      await marked;
      marker.cancel();
      operator.captureLog(
        'debug',
        'unreadable',
        data: <String, Object?>{'ratio': double.nan},
      );
      operator.captureLog('debug', 'after');
      Map<String, Object?> unreadable;
      do {
        unreadable = await nextLog();
      } while ((unreadable['payload'] as Map)['message'] == 'marker');
      final payload = unreadable['payload'] as Map;
      expect(payload['message'], 'unreadable');
      expect((payload['data'] as Map)['ratio'], isNull);
      expect(
        (payload['unreadableValues'] as Map)['values'],
        contains(
          allOf(
            containsPair('path', r'$.data.ratio'),
            containsPair('value', 'NaN'),
          ),
        ),
      );
      final after = await nextLog();
      expect((after['payload'] as Map)['message'], 'after');

      // The capture answers in full: the snapshot lists its own such values,
      // and so does each event's payload.
      final request = await client.openUrl(
        'POST',
        bridge.url.replace(path: '/capture'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer secret');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'afterSequence': 0,
          'issueActionTargets': false,
        }),
      );
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      expect(response.statusCode, HttpStatus.ok, reason: text);
      final capture = jsonDecode(text) as Map;
      final snapshotValues =
          ((capture['snapshot'] as Map)['unreadableValues'] as Map)['values'];
      expect(
        snapshotValues,
        contains(
          allOf(
            containsPair(
              'path',
              allOf(startsWith(r'$.logs['), endsWith('.data.ratio')),
            ),
            containsPair('value', 'NaN'),
          ),
        ),
      );
      final logged = ((capture['eventBatch'] as Map)['events'] as List)
          .cast<Map>()
          .map((event) => event['payload'])
          .whereType<Map>()
          .firstWhere((payload) => payload['message'] == 'unreadable');
      expect(
        (logged['unreadableValues'] as Map)['values'],
        contains(containsPair('path', r'$.data.ratio')),
      );
    },
  );

  test(
    'an action result holding a number JSON cannot carry is answered in full',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-live-bridge-unreadable-result',
          environment: OperatorEnvironment.dev,
        ),
      );
      addTearDown(operator.dispose);
      final bridge = await OperatorFlutterLiveBridge.start(
        OperatorFlutterAdapter(
          operator,
          actuator: _EndlessListScrollActuator(),
        ),
        port: 0,
        token: 'secret',
      );
      addTearDown(bridge.close);
      io.HttpOverrides.global = null;
      final client = HttpClient();
      addTearDown(client.close);

      final request = await client.openUrl(
        'POST',
        bridge.url.replace(path: '/execute'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer secret');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'action': <String, Object?>{
            'type': 'scroll',
            'direction': 'down',
            'amount': '100',
            'container': <String, Object?>{'id': 'endless-list'},
            'purpose': 'prove_an_infinite_scroll_end_reaches_the_host',
            'risk': 0,
          },
        }),
      );
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      expect(response.statusCode, HttpStatus.ok, reason: text);
      final result = jsonDecode(text) as Map;
      expect(result['ok'], isTrue);
      expect(((result['data'] as Map)['scroll'] as Map)['max'], isNull);
      expect(
        (result['unreadableValues'] as Map)['values'],
        contains(
          allOf(
            containsPair('path', r'$.data.scroll.max'),
            containsPair('value', 'Infinity'),
          ),
        ),
      );
    },
  );
}

/// Answers every action as scrolling an endless list does: such a list has no
/// end, so the furthest it can scroll (`maxScrollExtent`) is infinite.
class _EndlessListScrollActuator implements OperatorFlutterActuator {
  @override
  Future<ActionResult?> execute(
    ActionCommand command,
    OperatorFlutter operator,
  ) async => ActionResult(
    ok: true,
    action: command,
    data: const <String, Object?>{
      'operationPhase': 'settled',
      'scroll': <String, Object?>{
        'before': 0.0,
        'after': 100.0,
        'min': 0.0,
        'max': double.infinity,
        'outcome': 'moved',
      },
    },
  );
}
