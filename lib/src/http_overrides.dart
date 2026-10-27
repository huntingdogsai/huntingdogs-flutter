import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'protocol.dart';
import 'runtime.dart';

class OperatorHttpCapture {
  OperatorHttpCapture._();

  static final _OperatorHttpCaptureController _controller =
      _OperatorHttpCaptureController();
  static OperatorFlutter? _activeOperator;
  static HttpOverrides? _restoreOverride;
  static Timer? _rechainTimer;
  static ReceivePort? _isolatePort;
  static VoidCallback? _mockAvailabilityDispose;
  static bool _mockLookupRegistered = false;
  static int _installCount = 0;

  static VoidCallback installEarly({
    Duration rechainInterval = const Duration(milliseconds: 250),
  }) {
    return _retainGlobalCapture(rechainInterval: rechainInterval);
  }

  static VoidCallback install(
    OperatorFlutter operator, {
    Duration rechainInterval = const Duration(milliseconds: 250),
  }) {
    final previousActive = _activeOperator;
    _activeOperator = operator;
    _controller.operator = operator;
    _registerIsolateBridge(operator);
    final disposeGlobal = _retainGlobalCapture(
      rechainInterval: rechainInterval,
    );
    operator
      ..setVirtualizationCapability('httpOverrides', true)
      ..setVirtualizationCapability('dartIoHttp', true)
      ..setVirtualizationCapability('dartIoIsolateHttp', true)
      ..setVirtualizationCapability('networkConditions', true);
    operator.captureLog('debug', 'flutter http capture installed');
    var disposed = false;
    return () {
      if (disposed) return;
      disposed = true;
      if (_activeOperator == operator) {
        _activeOperator = previousActive;
        _controller.operator = previousActive;
        operator
          ..setVirtualizationCapability('httpOverrides', false)
          ..setVirtualizationCapability('dartIoHttp', false)
          ..setVirtualizationCapability('dartIoIsolateHttp', false)
          ..setVirtualizationCapability('networkConditions', false);
        if (previousActive == null) {
          _unregisterIsolateBridge();
        } else {
          _registerIsolateBridge(previousActive);
        }
      }
      disposeGlobal();
    };
  }

  static HttpClient wrapActive(HttpClient client) {
    if (_activeOperator == null && _installCount == 0) return client;
    if (client is _OperatorHttpClient) return client;
    return _OperatorHttpClient(_controller, client);
  }

  static VoidCallback _retainGlobalCapture({
    required Duration rechainInterval,
  }) {
    if (_installCount == 0) {
      _restoreOverride = HttpOverrides.current;
    }
    _installCount++;
    _rechainGlobalCapture();
    if (rechainInterval > Duration.zero) {
      _rechainTimer ??= Timer.periodic(
        rechainInterval,
        (_) => _rechainGlobalCapture(),
      );
    }

    var disposed = false;
    return () {
      if (disposed) return;
      disposed = true;
      _installCount--;
      if (_installCount > 0) return;
      _rechainTimer?.cancel();
      _rechainTimer = null;
      final current = HttpOverrides.current;
      if (current is _OperatorHttpOverrides &&
          identical(current.controller, _controller)) {
        HttpOverrides.global = current.previous ?? _restoreOverride;
      }
      _restoreOverride = null;
    };
  }

  static void _rechainGlobalCapture() {
    if (_installCount <= 0) return;
    final current = HttpOverrides.current;
    if (current is _OperatorHttpOverrides &&
        identical(current.controller, _controller)) {
      return;
    }
    final next = _OperatorHttpOverrides(_controller, current);
    HttpOverrides.global = next;
    _controller.operator?.captureLog(
      'debug',
      'flutter http capture chained',
      data: <String, Object?>{
        'previousOverride': current.runtimeType.toString(),
      },
    );
  }

  static void _registerIsolateBridge(OperatorFlutter operator) {
    _unregisterIsolateBridge();
    final port = ReceivePort('huntingdogs_http_capture');
    _isolatePort = port;
    IsolateNameServer.registerPortWithName(
      port.sendPort,
      _operatorHttpIsolatePortName,
    );
    _mockAvailabilityDispose = operator.addMockAvailabilityListener(
      _syncMockLookupRegistration,
    );
    port.listen((message) => _handleIsolateMessage(operator, message));
  }

  static void _unregisterIsolateBridge() {
    _mockAvailabilityDispose?.call();
    _mockAvailabilityDispose = null;
    IsolateNameServer.removePortNameMapping(_operatorHttpMockLookupPortName);
    _mockLookupRegistered = false;
    _isolatePort?.close();
    _isolatePort = null;
    IsolateNameServer.removePortNameMapping(_operatorHttpIsolatePortName);
  }

  static void _syncMockLookupRegistration() {
    final port = _isolatePort;
    final operator = _activeOperator;
    final shouldRegister =
        port != null &&
        operator != null &&
        (operator.hasActiveNetworkMocks || operator.networkConditions != null);
    if (!shouldRegister) {
      if (_mockLookupRegistered) {
        IsolateNameServer.removePortNameMapping(
          _operatorHttpMockLookupPortName,
        );
        _mockLookupRegistered = false;
      }
      return;
    }
    if (_mockLookupRegistered) return;
    IsolateNameServer.removePortNameMapping(_operatorHttpMockLookupPortName);
    _mockLookupRegistered = IsolateNameServer.registerPortWithName(
      port.sendPort,
      _operatorHttpMockLookupPortName,
    );
  }

  static void _handleIsolateMessage(OperatorFlutter operator, Object? message) {
    if (message is! Map) return;
    final type = message['type'];
    final id = message['id']?.toString();
    final request = _networkRequestFromMessage(message['request']);
    if (id == null || request == null) return;
    switch (type) {
      case 'request':
        operator.captureNetworkRequest(
          id: id,
          request: request,
          tags: _stringList(
            message['tags'],
            fallback: const <String>['request'],
          ),
        );
      case 'response':
        operator.captureNetworkResponse(
          id: id,
          request: request,
          status: _intValue(message['status']) ?? 0,
          ok: message['ok'] == true,
          headers: _stringMap(message['headers']),
          body: message['body'],
          tags: _stringList(
            message['tags'],
            fallback: const <String>['response'],
          ),
        );
      case 'error':
        operator.captureNetworkError(
          id: id,
          request: request,
          type: message['errorType']?.toString() ?? 'NetworkError',
          message: message['message']?.toString() ?? 'Unknown network error',
          retryable: message['retryable'] != false,
          tags: _stringList(message['tags'], fallback: const <String>['error']),
        );
      case 'mock_lookup':
        final replyTo = message['replyTo'];
        if (replyTo is SendPort) {
          final resolution = operator.resolveNetworkMock(request);
          replyTo.send(<String, Object?>{
            ..._networkMockResolutionToMessage(resolution),
            // Real requests take their share of the conditions from the main isolate's sequence.
            if (resolution.response == null)
              'networkDecision': operator.decideNetworkConditions()?.toMessage(),
          });
        }
      case 'mock_lookup_timeout':
        operator.captureLog(
          'debug',
          'operator isolate network mock lookup timed out',
          source: OperatorLogSource.operatorRuntime,
          data: <String, Object?>{
            'method': request.method,
            'path': request.path,
            'timeoutMs': _operatorIsolateMockLookupTimeout.inMilliseconds,
          },
        );
    }
  }
}

const bool _operatorHttpDebug = bool.fromEnvironment('OPERATOR_HTTP_DEBUG');
const String _operatorHttpIsolatePortName = 'huntingdogs.http_capture';
const String _operatorHttpMockLookupPortName =
    'huntingdogs.http_mock_lookup';
const Duration _operatorIsolateMockLookupTimeout = Duration(seconds: 2);

class _OperatorHttpCaptureController {
  OperatorFlutter? operator;
}

class _OperatorHttpOverrides extends HttpOverrides {
  _OperatorHttpOverrides(this.controller, this.previous);

  final _OperatorHttpCaptureController controller;
  final HttpOverrides? previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client =
        previous?.createHttpClient(context) ?? super.createHttpClient(context);
    if (client is _OperatorHttpClient) return client;
    return _OperatorHttpClient(controller, client);
  }
}

class _OperatorHttpClient implements HttpClient {
  _OperatorHttpClient(this.controller, this.delegate);

  final _OperatorHttpCaptureController controller;
  final HttpClient delegate;
  int _counter = 0;

  @override
  bool get autoUncompress => delegate.autoUncompress;

  @override
  set autoUncompress(bool value) {
    delegate.autoUncompress = value;
  }

  @override
  Duration? get connectionTimeout => delegate.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) {
    delegate.connectionTimeout = value;
  }

  @override
  Duration get idleTimeout => delegate.idleTimeout;

  @override
  set idleTimeout(Duration value) {
    delegate.idleTimeout = value;
  }

  @override
  int? get maxConnectionsPerHost => delegate.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) {
    delegate.maxConnectionsPerHost = value;
  }

  @override
  String? get userAgent => delegate.userAgent;

  @override
  set userAgent(String? value) {
    delegate.userAgent = value;
  }

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) {
    delegate.authenticate = f;
  }

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
    f,
  ) {
    delegate.authenticateProxy = f;
  }

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) {
    delegate.badCertificateCallback = callback;
  }

  @override
  set findProxy(String Function(Uri url)? f) {
    delegate.findProxy = f;
  }

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) {
    delegate.addCredentials(url, realm, credentials);
  }

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) {
    delegate.addProxyCredentials(host, port, realm, credentials);
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final operator = controller.operator;
    final ignored = _ignored(url);
    if (_operatorHttpDebug && !_ignored(url)) {
      operator?.captureLog(
        'debug',
        'http openUrl begin',
        data: <String, Object?>{'method': method, 'path': url.path},
      );
    }
    final captureInIsolate = operator == null && _isolateBridgeAvailable();
    if (!ignored && (operator != null || captureInIsolate)) {
      if (_operatorHttpDebug) {
        operator?.captureLog(
          'debug',
          'http openUrl deferred',
          data: <String, Object?>{'method': method, 'path': url.path},
        );
      }
      return _LazyOperatorHttpClientRequest(
        controller: controller,
        delegate: delegate,
        method: method,
        uri: url,
        id: 'http_${DateTime.now().microsecondsSinceEpoch}_${++_counter}',
      );
    }
    final request = await delegate.openUrl(method, url);
    if (_operatorHttpDebug && !_ignored(url)) {
      operator?.captureLog(
        'debug',
        'http openUrl ready',
        data: <String, Object?>{'method': method, 'path': url.path},
      );
    }
    return _OperatorHttpClientRequest(
      controller: controller,
      delegate: request,
      method: method,
      uri: url,
      id: 'http_${DateTime.now().microsecondsSinceEpoch}_${++_counter}',
    );
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) {
    return openUrl(
      method,
      Uri(scheme: 'http', host: host, port: port, path: path),
    );
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  void close({bool force = false}) => delegate.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LazyOperatorHttpClientRequest implements HttpClientRequest {
  _LazyOperatorHttpClientRequest({
    required this.controller,
    required this.delegate,
    required this.method,
    required this.uri,
    required this.id,
  });

  final _OperatorHttpCaptureController controller;
  final HttpClient delegate;
  @override
  final String method;
  @override
  final Uri uri;
  final String id;
  final List<int> _bodyBytes = <int>[];
  final _BufferedHttpHeaders _headers = _BufferedHttpHeaders();
  final List<Cookie> _cookies = <Cookie>[];
  Future<HttpClientResponse>? _closeFuture;
  var _aborted = false;

  @override
  Encoding encoding = utf8;

  @override
  HttpHeaders get headers => _headers;

  @override
  bool bufferOutput = true;

  @override
  int contentLength = -1;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  bool persistentConnection = true;

  @override
  List<Cookie> get cookies => _cookies;

  @override
  Future<HttpClientResponse> get done => close();

  @override
  void add(List<int> data) {
    _bodyBytes.addAll(data);
  }

  @override
  void write(Object? object) {
    _bodyBytes.addAll(encoding.encode(object.toString()));
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    var first = true;
    for (final object in objects) {
      if (!first) write(separator);
      write(object);
      first = false;
    }
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  @override
  void writeCharCode(int charCode) {
    _bodyBytes.addAll(encoding.encode(String.fromCharCode(charCode)));
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _bodyBytes.addAll(chunk);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> flush() async {}

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _aborted = true;
  }

  @override
  Future<HttpClientResponse> close() {
    return _closeFuture ??= _close();
  }

  Future<HttpClientResponse> _close() async {
    final request = _requestSnapshot();
    if (_aborted) {
      final error = HttpException('Request aborted', uri: uri);
      _captureNetworkError(
        operator: controller.operator,
        id: id,
        request: request,
        type: error.runtimeType.toString(),
        message: error.toString(),
      );
      throw error;
    }
    final operator = controller.operator;
    final (resolution, isolateDecision) =
        operator == null
            ? await _resolveIsolateNetwork(request)
            : (operator.resolveNetworkMock(request), null);
    final mock = resolution.response;
    if (mock == null) {
      return _closeRealRequest(
        request,
        resolution,
        operator?.decideNetworkConditions() ?? isolateDecision,
      );
    }
    final mockTags = _networkMockTags(resolution, base: 'request');

    _captureNetworkRequest(
      operator: operator,
      id: id,
      request: request,
      tags: mockTags,
    );
    if (mock.delay != null) await Future<void>.delayed(mock.delay!);
    final mockError = mock.error;
    if (mockError != null) {
      _captureNetworkError(
        operator: controller.operator,
        id: id,
        request: request,
        type: mockError.type,
        message: mockError.message,
        retryable: mockError.retryable ?? true,
        tags: _networkMockTags(resolution, base: 'error'),
      );
      throw HttpException(mockError.message, uri: uri);
    }
    final body = _encodeMockBody(mock.body);
    final headers = _mockHeaders(mock);
    _captureNetworkResponse(
      operator: controller.operator,
      id: id,
      request: request,
      status: mock.status,
      ok: mock.status >= 200 && mock.status < 300,
      headers: headers,
      body: mock.body,
      tags: _networkMockTags(resolution, base: 'response'),
    );
    return _CapturedHttpClientResponse(
      statusCode: mock.status,
      headers: _CapturedHttpHeaders(headers),
      bodyBytes: body,
      reasonPhrase: 'Operator network mock',
    );
  }

  Future<HttpClientResponse> _closeRealRequest(
    NetworkRequest request,
    OperatorNetworkMockResolution resolution,
    OperatorNetworkDecision? decision,
  ) async {
    final missTags = _networkMockMissTags(resolution, base: 'request');
    _captureNetworkRequest(
      operator: controller.operator,
      id: id,
      request: request,
      tags: missTags,
    );
    final conditioned = await _applyNetworkDecision(
      controller: controller,
      id: id,
      request: request,
      uri: uri,
      decision: decision,
      requestBytes: _bodyBytes.length,
      tags: missTags,
    );
    if (conditioned != null) return conditioned;
    try {
      final realRequest = await delegate.openUrl(method, uri);
      realRequest
        ..bufferOutput = bufferOutput
        ..followRedirects = followRedirects
        ..maxRedirects = maxRedirects
        ..persistentConnection = persistentConnection;
      if (contentLength >= 0) realRequest.contentLength = contentLength;
      _headers.forEach((name, values) {
        for (final value in values) {
          realRequest.headers.add(name, value);
        }
      });
      realRequest.cookies.addAll(_cookies);
      if (_bodyBytes.isNotEmpty) realRequest.add(_bodyBytes);
      final response = await realRequest.close();
      return _OperatorHttpClientResponse(
        controller: controller,
        delegate: response,
        request: request,
        id: id,
        tags: _networkMockMissTags(resolution, base: 'response'),
        downloadKbps: decision?.downloadKbps,
      );
    } catch (error) {
      _captureNetworkError(
        operator: controller.operator,
        id: id,
        request: request,
        type: error.runtimeType.toString(),
        message: error.toString(),
        tags: _networkMockMissTags(resolution, base: 'error'),
      );
      rethrow;
    }
  }

  NetworkRequest _requestSnapshot() {
    return networkRequest(
      method: method,
      url: uri.toString(),
      path: uri.path.isEmpty ? '/' : uri.path,
      query: <String, Object?>{
        for (final entry in uri.queryParameters.entries) entry.key: entry.value,
      },
      headers: _headers.toMap(),
      body: _decodeRequestBody(_bodyBytes, _headers),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OperatorHttpClientRequest implements HttpClientRequest {
  _OperatorHttpClientRequest({
    required this.controller,
    required this.delegate,
    required this.method,
    required this.uri,
    required this.id,
  });

  final _OperatorHttpCaptureController controller;
  final HttpClientRequest delegate;
  @override
  final String method;
  @override
  final Uri uri;
  final String id;
  final List<int> _bodyBytes = <int>[];
  Future<HttpClientResponse>? _closeFuture;

  @override
  Encoding encoding = utf8;

  @override
  HttpHeaders get headers => delegate.headers;

  @override
  bool get bufferOutput => delegate.bufferOutput;

  @override
  set bufferOutput(bool value) {
    delegate.bufferOutput = value;
  }

  @override
  int get contentLength => delegate.contentLength;

  @override
  set contentLength(int value) {
    delegate.contentLength = value;
  }

  @override
  bool get followRedirects => delegate.followRedirects;

  @override
  set followRedirects(bool value) {
    delegate.followRedirects = value;
  }

  @override
  int get maxRedirects => delegate.maxRedirects;

  @override
  set maxRedirects(int value) {
    delegate.maxRedirects = value;
  }

  @override
  bool get persistentConnection => delegate.persistentConnection;

  @override
  set persistentConnection(bool value) {
    delegate.persistentConnection = value;
  }

  @override
  List<Cookie> get cookies => delegate.cookies;

  @override
  Future<HttpClientResponse> get done => close();

  @override
  void add(List<int> data) {
    _bodyBytes.addAll(data);
    delegate.add(data);
  }

  @override
  void write(Object? object) {
    final text = object.toString();
    _bodyBytes.addAll(encoding.encode(text));
    final operator = controller.operator;
    if (_operatorHttpDebug && !_ignored(uri)) {
      operator?.captureLog(
        'debug',
        'http request write',
        data: <String, Object?>{
          'method': method,
          'path': uri.path,
          'bytes': _bodyBytes.length,
        },
      );
    }
    delegate.write(object);
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    var first = true;
    for (final object in objects) {
      if (!first) write(separator);
      write(object);
      first = false;
    }
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  @override
  void writeCharCode(int charCode) {
    _bodyBytes.addAll(encoding.encode(String.fromCharCode(charCode)));
    delegate.writeCharCode(charCode);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    return delegate.addStream(
      stream.map((chunk) {
        _bodyBytes.addAll(chunk);
        return chunk;
      }),
    );
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    delegate.addError(error, stackTrace);
  }

  @override
  Future<void> flush() => delegate.flush();

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    delegate.abort(exception, stackTrace);
  }

  @override
  Future<HttpClientResponse> close() {
    return _closeFuture ??= _close();
  }

  Future<HttpClientResponse> _close() async {
    final operator = controller.operator;
    if (_ignored(uri)) {
      return delegate.close();
    }
    final networkRequest = _requestSnapshot();
    final captureInIsolate = operator == null && _isolateBridgeAvailable();
    if (operator == null && !captureInIsolate) {
      return delegate.close();
    }
    if (_operatorHttpDebug) {
      operator?.captureLog(
        'debug',
        'http request close',
        data: <String, Object?>{
          'method': method,
          'path': uri.path,
          'bodyBytes': _bodyBytes.length,
        },
      );
    }

    final (resolution, isolateDecision) =
        operator == null
            ? await _resolveIsolateNetwork(networkRequest)
            : (operator.resolveNetworkMock(networkRequest), null);
    final mock = resolution.response;
    if (mock != null) {
      _captureNetworkRequest(
        operator: operator,
        id: id,
        request: networkRequest,
        tags: _networkMockTags(resolution, base: 'request'),
      );
      if (mock.delay != null) await Future<void>.delayed(mock.delay!);
      final error = mock.error;
      if (error != null) {
        _captureNetworkError(
          operator: operator,
          id: id,
          request: networkRequest,
          type: error.type,
          message: error.message,
          retryable: error.retryable ?? true,
          tags: _networkMockTags(resolution, base: 'error'),
        );
        throw HttpException(error.message, uri: uri);
      }
      final body = _encodeMockBody(mock.body);
      final headers = _mockHeaders(mock);
      _captureNetworkResponse(
        operator: operator,
        id: id,
        request: networkRequest,
        status: mock.status,
        ok: mock.status >= 200 && mock.status < 300,
        headers: headers,
        body: mock.body,
        tags: _networkMockTags(resolution, base: 'response'),
      );
      return _CapturedHttpClientResponse(
        statusCode: mock.status,
        headers: _CapturedHttpHeaders(headers),
        bodyBytes: body,
        reasonPhrase: 'Operator network mock',
      );
    }

    final missTags = _networkMockMissTags(resolution, base: 'request');
    _captureNetworkRequest(
      operator: operator,
      id: id,
      request: networkRequest,
      tags: missTags,
    );
    final decision = operator?.decideNetworkConditions() ?? isolateDecision;
    final conditioned = await _applyNetworkDecision(
      controller: controller,
      id: id,
      request: networkRequest,
      uri: uri,
      decision: decision,
      requestBytes: _bodyBytes.length,
      tags: missTags,
      // This request is already open; a condition that stops it must not leak the connection.
      abortDelegate: (error) => delegate.abort(error),
    );
    if (conditioned != null) return conditioned;
    try {
      final response = await delegate.close();
      return _OperatorHttpClientResponse(
        controller: controller,
        delegate: response,
        request: networkRequest,
        id: id,
        tags: _networkMockMissTags(resolution, base: 'response'),
        downloadKbps: decision?.downloadKbps,
      );
    } catch (error) {
      _captureNetworkError(
        operator: operator,
        id: id,
        request: networkRequest,
        type: error.runtimeType.toString(),
        message: error.toString(),
        tags: _networkMockMissTags(resolution, base: 'error'),
      );
      rethrow;
    }
  }

  NetworkRequest _requestSnapshot() {
    return networkRequest(
      method: method,
      url: uri.toString(),
      path: uri.path.isEmpty ? '/' : uri.path,
      query: <String, Object?>{
        for (final entry in uri.queryParameters.entries) entry.key: entry.value,
      },
      headers: _headersToMap(headers),
      body: _decodeRequestBody(_bodyBytes, headers),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OperatorHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _OperatorHttpClientResponse({
    required this.controller,
    required this.delegate,
    required this.request,
    required this.id,
    required this.tags,
    this.downloadKbps,
  });

  final _OperatorHttpCaptureController controller;
  final HttpClientResponse delegate;
  final NetworkRequest request;
  final String id;
  final List<String> tags;

  /// When set, each body chunk is held for the time it takes at this speed.
  final double? downloadKbps;

  @override
  int get statusCode => delegate.statusCode;

  @override
  HttpHeaders get headers => delegate.headers;

  @override
  String get reasonPhrase => delegate.reasonPhrase;

  @override
  int get contentLength => delegate.contentLength;

  @override
  bool get isRedirect => delegate.isRedirect;

  @override
  bool get persistentConnection => delegate.persistentConnection;

  @override
  List<RedirectInfo> get redirects => delegate.redirects;

  @override
  List<Cookie> get cookies => delegate.cookies;

  @override
  X509Certificate? get certificate => delegate.certificate;

  @override
  HttpClientResponseCompressionState get compressionState =>
      delegate.compressionState;

  @override
  Future<Socket> detachSocket() => delegate.detachSocket();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _capturedStream().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Stream<R> cast<R>() => _capturedStream().cast<R>();

  Stream<List<int>> _capturedStream() {
    final streamController = StreamController<List<int>>(sync: true);
    final bodyBytes = BytesBuilder(copy: false);
    StreamSubscription<List<int>>? subscription;

    streamController.onListen = () {
      subscription = delegate.listen(
        (chunk) {
          bodyBytes.add(chunk);
          final pace = downloadKbps;
          if (pace == null) {
            streamController.add(_asUint8List(chunk));
            return;
          }
          subscription?.pause();
          Future<void>.delayed(_transferTime(chunk.length, pace), () {
            streamController.add(_asUint8List(chunk));
            subscription?.resume();
          });
        },
        onError: (Object error, StackTrace stackTrace) {
          _captureNetworkError(
            operator: controller.operator,
            id: id,
            request: request,
            type: error.runtimeType.toString(),
            message: error.toString(),
            tags: tags.map((tag) => tag == 'response' ? 'error' : tag).toList(),
          );
          streamController.addError(error, stackTrace);
        },
        onDone: () {
          _captureNetworkResponse(
            operator: controller.operator,
            id: id,
            request: request,
            status: statusCode,
            ok: statusCode >= 200 && statusCode < 300,
            headers: _headersToMap(headers),
            body: _decodeBody(bodyBytes.takeBytes(), headers),
            tags: tags,
          );
          streamController.close();
        },
        cancelOnError: false,
      );
    };
    streamController.onPause = () => subscription?.pause();
    streamController.onResume = () => subscription?.resume();
    streamController.onCancel = () => subscription?.cancel();

    return streamController.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CapturedHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _CapturedHttpClientResponse({
    required this.statusCode,
    required this.headers,
    required List<int> bodyBytes,
    this.reasonPhrase = '',
  }) : _bodyBytes = Uint8List.fromList(bodyBytes);

  final Uint8List _bodyBytes;

  @override
  final int statusCode;

  @override
  final HttpHeaders headers;

  @override
  final String reasonPhrase;

  @override
  int get contentLength => _bodyBytes.length;

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  List<RedirectInfo> get redirects => const <RedirectInfo>[];

  @override
  List<Cookie> get cookies => const <Cookie>[];

  @override
  X509Certificate? get certificate => null;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  Future<Socket> detachSocket() {
    throw UnsupportedError('Captured Operator response cannot detach socket.');
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<Uint8List>.fromIterable(<Uint8List>[_bodyBytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CapturedHttpHeaders implements HttpHeaders {
  _CapturedHttpHeaders(Map<String, String> values)
    : _values = Map<String, String>.unmodifiable(values);

  final Map<String, String> _values;

  @override
  String? value(String name) => _values[name.toLowerCase()] ?? _values[name];

  @override
  List<String>? operator [](String name) {
    final value = this.value(name);
    return value == null ? null : <String>[value];
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    for (final entry in _values.entries) {
      action(entry.key, <String>[entry.value]);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BufferedHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = <String, List<String>>{};

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values
        .putIfAbsent(name.toLowerCase(), () => <String>[])
        .add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = <String>[value.toString()];
  }

  @override
  void remove(String name, Object value) {
    _values[name.toLowerCase()]?.remove(value.toString());
  }

  @override
  void removeAll(String name) {
    _values.remove(name.toLowerCase());
  }

  @override
  String? value(String name) => _values[name.toLowerCase()]?.join(', ');

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  void forEach(void Function(String name, List<String> values) action) {
    for (final entry in _values.entries) {
      action(entry.key, List<String>.unmodifiable(entry.value));
    }
  }

  @override
  ContentType? get contentType {
    final raw = value(HttpHeaders.contentTypeHeader);
    if (raw == null) return null;
    return ContentType.parse(raw);
  }

  @override
  set contentType(ContentType? value) {
    if (value == null) {
      removeAll(HttpHeaders.contentTypeHeader);
    } else {
      set(HttpHeaders.contentTypeHeader, value.toString());
    }
  }

  Map<String, String> toMap() {
    final values = <String, String>{};
    forEach((name, headerValues) {
      values[name.toLowerCase()] = headerValues.join(', ');
    });
    return values;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, String> _headersToMap(HttpHeaders headers) {
  final values = <String, String>{};
  headers.forEach((name, headerValues) {
    values[name.toLowerCase()] = headerValues.join(', ');
  });
  return values;
}

Object? _decodeRequestBody(List<int> bytes, HttpHeaders headers) {
  if (bytes.isEmpty) return null;
  return _decodeBody(bytes, headers);
}

Object? _decodeBody(List<int> bytes, HttpHeaders headers) {
  if (bytes.isEmpty) return null;
  final text = utf8.decode(bytes, allowMalformed: true);
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  final contentType = headers.contentType?.mimeType.toLowerCase();
  if (contentType == 'application/json' ||
      trimmed.startsWith('{') ||
      trimmed.startsWith('[')) {
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      return text;
    }
  }
  return text;
}

List<int> _encodeMockBody(Object? body) {
  if (body == null) return const <int>[];
  if (body is String) return utf8.encode(body);
  return utf8.encode(jsonEncode(body));
}

Map<String, String> _mockHeaders(NetworkMockResponse mock) {
  final headers = <String, String>{'x-operator-mock': 'true', ...mock.headers};
  final hasContentType = headers.keys.any(
    (key) => key.toLowerCase() == HttpHeaders.contentTypeHeader,
  );
  if (!hasContentType && mock.body != null && mock.body is! String) {
    headers[HttpHeaders.contentTypeHeader] = ContentType.json.mimeType;
  }
  return headers;
}

Uint8List _asUint8List(List<int> bytes) {
  if (bytes is Uint8List) return bytes;
  return Uint8List.fromList(bytes);
}

bool _isolateBridgeAvailable() =>
    IsolateNameServer.lookupPortByName(_operatorHttpIsolatePortName) != null;

void _captureNetworkRequest({
  required OperatorFlutter? operator,
  required String id,
  required NetworkRequest request,
  List<String> tags = const <String>['request'],
}) {
  if (operator != null) {
    operator.captureNetworkRequest(id: id, request: request, tags: tags);
    return;
  }
  _sendIsolateMessage(<String, Object?>{
    'type': 'request',
    'id': id,
    'request': _networkRequestToMessage(request),
    'tags': tags,
  });
}

void _captureNetworkResponse({
  required OperatorFlutter? operator,
  required String id,
  required NetworkRequest request,
  required int status,
  required bool ok,
  Map<String, String> headers = const <String, String>{},
  Object? body,
  List<String> tags = const <String>['response'],
}) {
  if (operator != null) {
    operator.captureNetworkResponse(
      id: id,
      request: request,
      status: status,
      ok: ok,
      headers: headers,
      body: body,
      tags: tags,
    );
    return;
  }
  _sendIsolateMessage(<String, Object?>{
    'type': 'response',
    'id': id,
    'request': _networkRequestToMessage(request),
    'status': status,
    'ok': ok,
    'headers': headers,
    'body': body,
    'tags': tags,
  });
}

void _captureNetworkError({
  required OperatorFlutter? operator,
  required String id,
  required NetworkRequest request,
  required String type,
  required String message,
  bool retryable = true,
  List<String> tags = const <String>['error'],
}) {
  if (operator != null) {
    operator.captureNetworkError(
      id: id,
      request: request,
      type: type,
      message: message,
      retryable: retryable,
      tags: tags,
    );
    return;
  }
  _sendIsolateMessage(<String, Object?>{
    'type': 'error',
    'id': id,
    'request': _networkRequestToMessage(request),
    'errorType': type,
    'message': message,
    'retryable': retryable,
    'tags': tags,
  });
}

/// A background isolate's mock resolution and, for a real request, its share of the conditions.
Future<(OperatorNetworkMockResolution, OperatorNetworkDecision?)>
_resolveIsolateNetwork(NetworkRequest request) async {
  final sendPort = IsolateNameServer.lookupPortByName(
    _operatorHttpMockLookupPortName,
  );
  if (sendPort == null) return (_unmatchedNetworkMockResolution(request), null);
  final reply = ReceivePort('huntingdogs_http_mock_lookup');
  try {
    sendPort.send(<String, Object?>{
      'type': 'mock_lookup',
      'id': 'mock_lookup_${DateTime.now().microsecondsSinceEpoch}',
      'request': _networkRequestToMessage(request),
      'replyTo': reply.sendPort,
    });
    final response = await reply.first.timeout(
      _operatorIsolateMockLookupTimeout,
      onTimeout: () {
        _sendIsolateMessage(<String, Object?>{
          'type': 'mock_lookup_timeout',
          'id': 'mock_lookup_timeout_${DateTime.now().microsecondsSinceEpoch}',
          'request': _networkRequestToMessage(request),
        });
        return null;
      },
    );
    return (
      _networkMockResolutionFromMessage(response, request),
      OperatorNetworkDecision.fromMessage(
        response is Map ? response['networkDecision'] : null,
      ),
    );
  } finally {
    reply.close();
  }
}

/// Applies one request's share of the network conditions before it is sent. Offline and a chosen
/// transport failure throw the socket error a real phone raises; a chosen failure status answers
/// with that status without sending; delay and upload pacing wait first. Returns that synthetic
/// response when there is one.
Future<HttpClientResponse?> _applyNetworkDecision({
  required _OperatorHttpCaptureController controller,
  required String id,
  required NetworkRequest request,
  required Uri uri,
  required OperatorNetworkDecision? decision,
  required int requestBytes,
  required List<String> tags,
  void Function(Object error)? abortDelegate,
}) async {
  if (decision == null) return null;
  List<String> conditionTags(String base, String outcome) => <String>[
    ...tags.map((tag) => tag == 'request' ? base : tag),
    'network_conditions',
    'network_conditions:${decision.generation}',
    outcome,
  ];
  if (decision.offline) {
    final error = SocketException(
      'Network is unreachable (Operator network conditions: offline)',
      osError: const OSError('Network is unreachable', 101),
      port: uri.port,
    );
    _captureNetworkError(
      operator: controller.operator,
      id: id,
      request: request,
      type: 'SocketException',
      message: error.message,
      tags: conditionTags('error', 'offline'),
    );
    abortDelegate?.call(error);
    throw error;
  }
  if (decision.delay > Duration.zero) await Future<void>.delayed(decision.delay);
  final upload = decision.uploadKbps;
  if (upload != null && requestBytes > 0) {
    await Future<void>.delayed(_transferTime(requestBytes, upload));
  }
  if (!decision.fail) return null;
  final status = decision.failureStatus;
  if (status != null) {
    abortDelegate?.call(const SocketException('Operator network conditions answered instead'));
    _captureNetworkResponse(
      operator: controller.operator,
      id: id,
      request: request,
      status: status,
      ok: status >= 200 && status < 300,
      tags: conditionTags('response', 'failure_status'),
    );
    return _CapturedHttpClientResponse(
      statusCode: status,
      headers: _CapturedHttpHeaders(const <String, String>{}),
      bodyBytes: Uint8List(0),
      reasonPhrase: 'Operator network conditions',
    );
  }
  final error = SocketException(
    'Connection reset by peer (Operator network conditions: simulated failure)',
    osError: const OSError('Connection reset by peer', 54),
    port: uri.port,
  );
  _captureNetworkError(
    operator: controller.operator,
    id: id,
    request: request,
    type: 'SocketException',
    message: error.message,
    tags: conditionTags('error', 'failure'),
  );
  abortDelegate?.call(error);
  throw error;
}

/// How long [bytes] take at [kbps] kilobits per second.
Duration _transferTime(int bytes, double kbps) =>
    Duration(microseconds: (bytes * 8000 / kbps).round());

void _sendIsolateMessage(Map<String, Object?> message) {
  final sendPort = IsolateNameServer.lookupPortByName(
    _operatorHttpIsolatePortName,
  );
  sendPort?.send(message);
}

Map<String, Object?> _networkRequestToMessage(NetworkRequest request) {
  return <String, Object?>{
    'method': request.method,
    'url': request.url,
    'path': request.path,
    'query': request.query,
    'headers': request.headers,
    'body': request.body,
  };
}

NetworkRequest? _networkRequestFromMessage(Object? value) {
  if (value is! Map) return null;
  final method = value['method']?.toString();
  final url = value['url']?.toString();
  if (method == null || url == null) return null;
  return NetworkRequest(
    method: method,
    url: url,
    path: value['path']?.toString(),
    query: _jsonMap(value['query']),
    headers: _stringMap(value['headers']),
    body: value['body'],
  );
}

Map<String, Object?>? _networkMockResponseToMessage(
  NetworkMockResponse? response,
) {
  if (response == null) return null;
  return <String, Object?>{
    'status': response.status,
    'headers': response.headers,
    'body': response.body,
    'delayMs': response.delay?.inMilliseconds,
    if (response.error != null)
      'error': <String, Object?>{
        'type': response.error!.type,
        'message': response.error!.message,
        'retryable': response.error!.retryable,
      },
  };
}

Map<String, Object?> _networkMockResolutionToMessage(
  OperatorNetworkMockResolution resolution,
) {
  return <String, Object?>{
    'matched': resolution.matched,
    'candidateCount': resolution.candidateCount,
    if (resolution.mockId != null) 'mockId': resolution.mockId,
    if (resolution.score != null) 'score': resolution.score,
    if (resolution.match != null)
      'match': <String, Object?>{
        if (resolution.match!.method != null)
          'method': resolution.match!.method,
        if (resolution.match!.url != null) 'url': resolution.match!.url,
        if (resolution.match!.urlContains != null)
          'urlContains': resolution.match!.urlContains,
        if (resolution.match!.urlPattern != null)
          'urlPattern': resolution.match!.urlPattern,
        if (resolution.match!.path != null) 'path': resolution.match!.path,
        if (resolution.match!.pathContains != null)
          'pathContains': resolution.match!.pathContains,
        if (resolution.match!.pathPattern != null)
          'pathPattern': resolution.match!.pathPattern,
        'query': resolution.match!.query,
        'headers': resolution.match!.headers,
      },
    if (resolution.response != null)
      'response': _networkMockResponseToMessage(resolution.response),
  };
}

OperatorNetworkMockResolution _networkMockResolutionFromMessage(
  Object? value,
  NetworkRequest request,
) {
  if (value is Map && value.containsKey('matched')) {
    return OperatorNetworkMockResolution(
      request: request,
      matched: value['matched'] == true,
      mockId: value['mockId']?.toString(),
      match: _networkMockMatchFromMessage(value['match']),
      response: _networkMockResponseFromMessage(value['response']),
      score: _intValue(value['score']),
      candidateCount: _intValue(value['candidateCount']) ?? 0,
    );
  }
  return OperatorNetworkMockResolution(
    request: request,
    matched: value != null,
    response: _networkMockResponseFromMessage(value),
    candidateCount: value == null ? 0 : 1,
  );
}

OperatorNetworkMockResolution _unmatchedNetworkMockResolution(
  NetworkRequest request,
) {
  return OperatorNetworkMockResolution(request: request, matched: false);
}

NetworkMockMatch? _networkMockMatchFromMessage(Object? value) {
  if (value is! Map) return null;
  return NetworkMockMatch(
    method: value['method']?.toString(),
    url: value['url']?.toString(),
    urlContains: value['urlContains']?.toString(),
    urlPattern: value['urlPattern']?.toString(),
    path: value['path']?.toString(),
    pathContains: value['pathContains']?.toString(),
    pathPattern: value['pathPattern']?.toString(),
    query: _jsonMap(value['query']),
    headers: _stringMap(value['headers']),
  );
}

NetworkMockResponse? _networkMockResponseFromMessage(Object? value) {
  if (value is! Map) return null;
  final status = _intValue(value['status']);
  if (status == null) return null;
  final errorValue = value['error'];
  return NetworkMockResponse(
    status: status,
    headers: _stringMap(value['headers']),
    body: value['body'],
    delay:
        _intValue(value['delayMs']) == null
            ? null
            : Duration(milliseconds: _intValue(value['delayMs'])!),
    error:
        errorValue is Map
            ? NetworkError(
              type: errorValue['type']?.toString() ?? 'NetworkError',
              message: errorValue['message']?.toString() ?? '',
              retryable:
                  errorValue['retryable'] is bool
                      ? errorValue['retryable'] as bool
                      : null,
            )
            : null,
  );
}

List<String> _networkMockTags(
  OperatorNetworkMockResolution resolution, {
  required String base,
}) {
  return <String>[
    base,
    'mock',
    if (resolution.mockId != null) 'mockId:${resolution.mockId}',
    if (resolution.score != null) 'mockScore:${resolution.score}',
  ];
}

List<String> _networkMockMissTags(
  OperatorNetworkMockResolution resolution, {
  required String base,
}) {
  if (resolution.matched || resolution.candidateCount <= 0) {
    return <String>[base];
  }
  return <String>[
    base,
    'mockMiss',
    'activeMockCount:${resolution.candidateCount}',
  ];
}

Map<String, Object?> _jsonMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return value.map((key, entryValue) => MapEntry(key.toString(), entryValue));
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const <String, String>{};
  return value.map(
    (key, entryValue) => MapEntry(key.toString(), entryValue.toString()),
  );
}

List<String> _stringList(
  Object? value, {
  List<String> fallback = const <String>[],
}) {
  if (value is! Iterable) return fallback;
  return value.map((entry) => entry.toString()).toList(growable: false);
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool _ignored(Uri uri) {
  return uri.path.startsWith('/v1/operator/') ||
      uri.path == '/v1/operator/dev/pairing' ||
      uri.path.startsWith('/v1/operator/dev/');
}
