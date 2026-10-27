import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'adapter.dart';
import 'bridge_handlers.dart';
import 'protocol.dart';
import 'wire_codec.dart';

export 'wire_codec.dart';

/// Methods only this transport adds to the shared bridge contract.
const List<String> _transportMethods = <String>['capture', 'captureVisual'];

/// Loopback HTTP bridge for native builds. It serves the same method set as
/// the Flutter Web page bridge, through [OperatorFlutterBridgeHandlers], so a
/// host reaching the app through `adb forward` or the simulator's localhost
/// gets the same snapshots, one-use targets, point inspection, observed
/// Firestore operations and in-app screenshots the browser host gets.
class OperatorFlutterLiveBridge {
  OperatorFlutterLiveBridge._(this._server, this.adapter, this.token)
    : handlers = OperatorFlutterBridgeHandlers(adapter);

  final HttpServer _server;
  final OperatorFlutterAdapter adapter;
  final String? token;
  final OperatorFlutterBridgeHandlers handlers;

  String get installationId => handlers.installationId;

  Uri get url =>
      Uri(scheme: 'http', host: _server.address.address, port: _server.port);

  static Future<OperatorFlutterLiveBridge> start(
    OperatorFlutterAdapter adapter, {
    String host = '127.0.0.1',
    int port = 0,
    String? token,
  }) async {
    final server = await HttpServer.bind(host, port);
    final bridge = OperatorFlutterLiveBridge._(server, adapter, token);
    unawaited(bridge._serve());
    return bridge;
  }

  Future<void> close() {
    handlers.close();
    return _server.close(force: true);
  }

  /// Requests are served concurrently: the event stream keeps its connection
  /// open for the whole session, and captures and actions must not wait
  /// behind it.
  Future<void> _serve() async {
    await for (final request in _server) {
      unawaited(_serveOne(request));
    }
  }

  Future<void> _serveOne(HttpRequest request) async {
    try {
      await _handle(request);
    } catch (error, stackTrace) {
      adapter.operator.captureLog(
        'error',
        'flutter live bridge failed',
        data: <String, Object?>{
          'error': error.toString(),
          'stack': stackTrace.toString(),
        },
      );
      _writeJson(
        request.response,
        HttpStatus.internalServerError,
        <String, Object?>{'ok': false, 'error': error.toString()},
      );
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (!_authorized(request)) {
      _writeJson(
        request.response,
        HttpStatus.unauthorized,
        const <String, Object?>{'ok': false, 'error': 'unauthorized'},
      );
      return;
    }

    final method = request.method.toUpperCase();
    final path = request.uri.path;

    if (method == 'GET' && path == '/healthz') {
      final snapshot = await adapter.getSnapshot();
      _writeJson(request.response, HttpStatus.ok, <String, Object?>{
        'ok': true,
        'protocolVersion': 'operator-live-bridge/v1',
        'appId': snapshot.app.appId,
        'platform': operatorPlatformName(snapshot.app.platform),
        'installationId': installationId,
      });
      return;
    }
    // Page-bridge parity. Each route answers exactly what the browser host
    // gets from the corresponding page method, as JSON bodies instead of
    // JSON strings.
    if (method == 'GET' && path == '/health') {
      _writeJson(
        request.response,
        HttpStatus.ok,
        handlers.health(transportMethods: _transportMethods),
      );
      return;
    }
    if (method == 'POST' && path == '/capture') {
      _writeJson(
        request.response,
        HttpStatus.ok,
        await handlers.capture(
          await _readJson(request),
          transportMethods: _transportMethods,
        ),
      );
      return;
    }
    if (method == 'POST' && path == '/observedOperations') {
      final body = _asMap(await _readJson(request));
      final expected = body['installationId'];
      if (expected is String && expected != installationId) {
        _writeJson(request.response, HttpStatus.conflict, <String, Object?>{
          'ok': false,
          'error': 'observed_operations_installation_changed',
        });
        return;
      }
      _writeJson(request.response, HttpStatus.ok, <String, Object?>{
        'installationId': installationId,
        'data': handlers.observedOperations(body['request'] ?? body),
      });
      return;
    }
    if (method == 'POST' && path == '/inspectPoint') {
      await _answer(
        request,
        () async => handlers.inspectPoint(await _readJson(request)),
      );
      return;
    }
    if (method == 'POST' && path == '/prepareKeyTarget') {
      await _answer(
        request,
        () async =>
            handlers.prepareKeyTarget(_actionPayload(await _readJson(request))),
      );
      return;
    }
    if (method == 'POST' && path == '/captureVisual') {
      await _answer(
        request,
        () async => handlers.captureVisual(await _readJson(request)),
      );
      return;
    }

    if (method == 'GET' && path == '/snapshot') {
      _writeJson(
        request.response,
        HttpStatus.ok,
        operatorSnapshotToJson(await adapter.getSnapshot()),
      );
      return;
    }

    if (method == 'GET' && path == '/events') {
      await _writeEventStream(
        request,
        includeSnapshot: request.uri.queryParameters['snapshot'] != 'false',
      );
      return;
    }

    if (method == 'GET' && path == '/capabilities') {
      _writeJson(
        request.response,
        HttpStatus.ok,
        operatorCapabilitiesToJson((await adapter.getSnapshot()).capabilities),
      );
      return;
    }

    if (method == 'POST' && path == '/execute') {
      final action = operatorActionCommandFromEnvelopeJson(
        await _readJson(request),
      );
      final result = await adapter.execute(action);
      _writeJson(
        request.response,
        HttpStatus.ok,
        operatorActionResultToJson(result),
      );
      return;
    }

    if (method == 'POST' && path == '/verify') {
      final payload = await _readJson(request);
      final after = operatorSnapshotToJson(await adapter.getSnapshot());
      _writeJson(
        request.response,
        HttpStatus.ok,
        operatorVerifyPayload(payload, after),
      );
      return;
    }

    if (method == 'POST' && path == '/redact') {
      final payload = _asMap(await _readJson(request));
      final cleaned = adapter.operator.redactor.cleanWithReport(
        payload['value'],
      );
      _writeJson(request.response, HttpStatus.ok, <String, Object?>{
        'value': cleaned.value,
        'redactions': operatorRedactionToJson(cleaned.report),
      });
      return;
    }

    _writeJson(request.response, HttpStatus.notFound, <String, Object?>{
      'ok': false,
      'error': 'not_found:$method:$path',
    });
  }

  /// Explicit contract rejections keep their meaning across the wire: a
  /// malformed request is 400, an unavailable capability is 409. Anything
  /// else is the server failure handled by [_serve].
  Future<void> _answer(
    HttpRequest request,
    Future<Object?> Function() produce,
  ) async {
    try {
      _writeJson(request.response, HttpStatus.ok, await produce());
    } on FormatException catch (error) {
      _writeJson(request.response, HttpStatus.badRequest, <String, Object?>{
        'ok': false,
        'error': error.message,
      });
    } on StateError catch (error) {
      _writeJson(request.response, HttpStatus.conflict, <String, Object?>{
        'ok': false,
        'error': error.message,
      });
    }
  }

  /// Accepts either the bare action or the `{action: ...}` envelope.
  static Object? _actionPayload(Object? body) => body;

  bool _authorized(HttpRequest request) {
    if (token == null) return true;
    return request.headers.value(HttpHeaders.authorizationHeader) ==
        'Bearer $token';
  }

  Future<Object?> _readJson(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.trim().isEmpty) return const <String, Object?>{};
    return jsonDecode(text);
  }

  Future<void> _writeEventStream(
    HttpRequest request, {
    required bool includeSnapshot,
  }) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.bufferOutput = false;
    response.headers
      ..set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..set(HttpHeaders.connectionHeader, 'keep-alive')
      ..set('x-accel-buffering', 'no');

    var closed = false;
    unawaited(response.done.whenComplete(() => closed = true));

    Future<void> send(OperatorRuntimeEvent event) async {
      if (closed) return;
      try {
        response
          ..write('id: ${event.sequence}\n')
          ..write('event: ${operatorRuntimeEventTypeName(event.type)}\n')
          ..write(
            'data: ${operatorEncodeJson(operatorRuntimeEventToJson(event))}\n\n',
          );
        await response.flush();
      } catch (_) {
        closed = true;
      }
    }

    response.write(': operator_flutter_live_bridge connected\n\n');
    await response.flush();

    if (includeSnapshot) {
      final snapshot = await adapter.getSnapshot();
      await send(
        OperatorRuntimeEvent(
          type: OperatorRuntimeEventType.snapshot,
          sequence: 0,
          timestamp: DateTime.now().toUtc(),
          snapshotId: snapshot.snapshotId,
          payload: snapshot,
        ),
      );
    }

    var writes = Future<void>.value();
    void queue(OperatorRuntimeEvent event) {
      writes = writes.then((_) => send(event));
      unawaited(writes);
    }

    final subscription = adapter.events.listen(queue);
    try {
      await response.done;
    } finally {
      closed = true;
      await subscription.cancel();
      await writes;
    }
  }
}

JsonMap _asMap(Object? value) {
  if (value is Map) {
    return value.map((key, child) => MapEntry(key.toString(), child));
  }
  return <String, Object?>{};
}

void _writeJson(HttpResponse response, int status, Object? value) {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(operatorEncodeJson(value));
  unawaited(response.close());
}
