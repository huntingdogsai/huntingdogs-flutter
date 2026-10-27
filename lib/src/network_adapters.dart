import 'protocol.dart';
import 'runtime.dart';

class OperatorNetworkAdapter {
  OperatorNetworkAdapter(this.operator);

  final OperatorFlutter operator;

  void captureDioRequest({
    required String id,
    required String method,
    required String url,
    String? path,
    JsonMap query = const <String, Object?>{},
    Map<String, String> headers = const <String, String>{},
    Object? data,
  }) {
    captureRequest(
      id: id,
      method: method,
      url: url,
      path: path,
      query: query,
      headers: headers,
      body: data,
    );
  }

  void captureDioResponse({
    required String id,
    required String method,
    required String url,
    required int status,
    required bool ok,
    String? path,
    JsonMap query = const <String, Object?>{},
    Map<String, String> requestHeaders = const <String, String>{},
    Object? requestData,
    Map<String, String> responseHeaders = const <String, String>{},
    Object? responseData,
  }) {
    captureResponse(
      id: id,
      method: method,
      url: url,
      path: path,
      query: query,
      requestHeaders: requestHeaders,
      requestBody: requestData,
      responseHeaders: responseHeaders,
      status: status,
      ok: ok,
      responseBody: responseData,
    );
  }

  void captureDioError({
    required String id,
    required String method,
    required String url,
    required String type,
    required String message,
    String? path,
    JsonMap query = const <String, Object?>{},
    Map<String, String> requestHeaders = const <String, String>{},
    Object? requestData,
    bool retryable = true,
  }) {
    captureError(
      id: id,
      method: method,
      url: url,
      path: path,
      query: query,
      requestHeaders: requestHeaders,
      requestBody: requestData,
      type: type,
      message: message,
      retryable: retryable,
    );
  }

  void captureHttpRequest({
    required String id,
    required String method,
    required String url,
    String? path,
    JsonMap query = const <String, Object?>{},
    Map<String, String> headers = const <String, String>{},
    Object? body,
  }) {
    captureRequest(
      id: id,
      method: method,
      url: url,
      path: path,
      query: query,
      headers: headers,
      body: body,
    );
  }

  void captureHttpResponse({
    required String id,
    required String method,
    required String url,
    required int status,
    required bool ok,
    String? path,
    JsonMap query = const <String, Object?>{},
    Map<String, String> requestHeaders = const <String, String>{},
    Object? requestBody,
    Map<String, String> responseHeaders = const <String, String>{},
    Object? responseBody,
  }) {
    captureResponse(
      id: id,
      method: method,
      url: url,
      path: path,
      query: query,
      requestHeaders: requestHeaders,
      requestBody: requestBody,
      responseHeaders: responseHeaders,
      status: status,
      ok: ok,
      responseBody: responseBody,
    );
  }

  void captureHttpError({
    required String id,
    required String method,
    required String url,
    required String type,
    required String message,
    String? path,
    JsonMap query = const <String, Object?>{},
    Map<String, String> requestHeaders = const <String, String>{},
    Object? requestBody,
    bool retryable = true,
  }) {
    captureError(
      id: id,
      method: method,
      url: url,
      path: path,
      query: query,
      requestHeaders: requestHeaders,
      requestBody: requestBody,
      type: type,
      message: message,
      retryable: retryable,
    );
  }

  void captureGraphQLRequest({
    required String id,
    required String endpoint,
    required String query,
    String? operationName,
    JsonMap variables = const <String, Object?>{},
    Map<String, String> headers = const <String, String>{},
  }) {
    captureRequest(
      id: id,
      method: 'POST',
      url: endpoint,
      path: endpoint,
      headers: headers,
      body: <String, Object?>{
        'operationName': operationName,
        'query': query,
        'variables': variables,
      },
    );
  }

  void captureGraphQLResponse({
    required String id,
    required String endpoint,
    required String query,
    required int status,
    String? operationName,
    JsonMap variables = const <String, Object?>{},
    Object? data,
    Object? errors,
    Map<String, String> requestHeaders = const <String, String>{},
    Map<String, String> responseHeaders = const <String, String>{},
  }) {
    captureResponse(
      id: id,
      method: 'POST',
      url: endpoint,
      path: endpoint,
      requestHeaders: requestHeaders,
      requestBody: <String, Object?>{
        'operationName': operationName,
        'query': query,
        'variables': variables,
      },
      responseHeaders: responseHeaders,
      status: status,
      ok: status >= 200 && status < 300 && errors == null,
      responseBody: <String, Object?>{'data': data, 'errors': errors},
    );
  }

  void captureGraphQLError({
    required String id,
    required String endpoint,
    required String query,
    required String message,
    String? operationName,
    JsonMap variables = const <String, Object?>{},
    Map<String, String> requestHeaders = const <String, String>{},
    bool retryable = true,
  }) {
    captureError(
      id: id,
      method: 'POST',
      url: endpoint,
      path: endpoint,
      requestHeaders: requestHeaders,
      requestBody: <String, Object?>{
        'operationName': operationName,
        'query': query,
        'variables': variables,
      },
      type: 'GraphQLError',
      message: message,
      retryable: retryable,
    );
  }

  void captureRetrofitResponse({
    required String id,
    required String method,
    required String url,
    required int status,
    required bool ok,
    String? serviceMethod,
    String? path,
    JsonMap query = const <String, Object?>{},
    Object? requestBody,
    Object? responseBody,
  }) {
    captureResponse(
      id: id,
      method: method,
      url: url,
      path: path,
      query: query,
      requestBody: <String, Object?>{
        if (serviceMethod != null) 'serviceMethod': serviceMethod,
        if (requestBody != null) 'body': requestBody,
      },
      status: status,
      ok: ok,
      responseBody: responseBody,
    );
  }

  void captureChopperResponse({
    required String id,
    required String method,
    required String url,
    required int status,
    required bool ok,
    String? path,
    JsonMap query = const <String, Object?>{},
    Object? requestBody,
    Object? responseBody,
  }) {
    captureResponse(
      id: id,
      method: method,
      url: url,
      path: path,
      query: query,
      requestBody: requestBody,
      status: status,
      ok: ok,
      responseBody: responseBody,
    );
  }

  void captureWebSocketMessage({
    required String id,
    required String url,
    required String direction,
    Object? message,
    String? path,
  }) {
    captureRequest(
      id: id,
      method: 'WS',
      url: url,
      path: path,
      body: <String, Object?>{'direction': direction, 'message': message},
    );
  }

  void captureRequest({
    required String id,
    required String method,
    required String url,
    String? path,
    JsonMap query = const <String, Object?>{},
    Map<String, String> headers = const <String, String>{},
    Object? body,
  }) {
    operator.captureNetworkRequest(
      id: id,
      request: networkRequest(
        method: method,
        url: url,
        path: path,
        query: query,
        headers: headers,
        body: operator.redactor.clean(body),
      ),
      tags: const <String>['request'],
    );
  }

  NetworkMockResponse? findMockResponse({
    required String method,
    required String url,
    String? path,
    JsonMap query = const <String, Object?>{},
    Map<String, String> headers = const <String, String>{},
    Object? body,
  }) {
    return operator.findNetworkMock(
      networkRequest(
        method: method,
        url: url,
        path: path,
        query: query,
        headers: headers,
        body: body,
      ),
    );
  }

  void captureResponse({
    required String id,
    required String method,
    required String url,
    required int status,
    required bool ok,
    String? path,
    JsonMap query = const <String, Object?>{},
    Map<String, String> requestHeaders = const <String, String>{},
    Object? requestBody,
    Map<String, String> responseHeaders = const <String, String>{},
    Object? responseBody,
  }) {
    operator.captureNetworkResponse(
      id: id,
      request: networkRequest(
        method: method,
        url: url,
        path: path,
        query: query,
        headers: requestHeaders,
        body: requestBody,
      ),
      status: status,
      ok: ok,
      headers: responseHeaders,
      body: responseBody,
    );
  }

  void captureError({
    required String id,
    required String method,
    required String url,
    required String type,
    required String message,
    String? path,
    JsonMap query = const <String, Object?>{},
    Map<String, String> requestHeaders = const <String, String>{},
    Object? requestBody,
    bool retryable = true,
  }) {
    operator.captureNetworkError(
      id: id,
      request: networkRequest(
        method: method,
        url: url,
        path: path,
        query: query,
        headers: requestHeaders,
        body: requestBody,
      ),
      type: type,
      message: message,
      retryable: retryable,
    );
  }
}
