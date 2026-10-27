import 'protocol.dart';

const _defaultRedactedFields = <String>[
  'password',
  'passcode',
  'pin',
  'otp',
  'token',
  'accessToken',
  'refreshToken',
  'accessKey',
  'apiKey',
  'encryptionKey',
  'signingKey',
  'authorization',
  'auth',
  'cookie',
  'session',
  'webhook',
  'webhookUrl',
  'dsn',
  'username',
  'email',
  'phone',
  'telephone',
  'address',
  'birthdate',
  'dateOfBirth',
  'dob',
  'cardNumber',
  'cvv',
  'cvc',
  'bvn',
  'nin',
  'ssn',
  'secret',
  'privateKey',
  'credential',
];

const _redactedValue = '[REDACTED]';

final RegExp _emailPattern = RegExp(
  r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
  caseSensitive: false,
);
final RegExp _jwtPattern = RegExp(
  r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b',
);
final RegExp _inlineCredentialPattern = RegExp(
  r'\b(?:bearer|basic)\s+[A-Za-z0-9._~+/\-=]{8,}',
  caseSensitive: false,
);
final RegExp _webhookUrlPattern = RegExp(
  r'''https?://[^\s"'<>]*(?:hooks\.slack\.com/services|webhook)[^\s"'<>]*''',
  caseSensitive: false,
);
final RegExp _highEntropySecretPattern = RegExp(
  r'\b(?=[A-Za-z0-9_+=]{32,}\b)(?=[A-Za-z0-9_+=]*[A-Za-z])(?=[A-Za-z0-9_+=]*[0-9])[A-Za-z0-9_+=]{32,}\b',
);

class OperatorRedactor {
  OperatorRedactor({
    Iterable<String> fields = _defaultRedactedFields,
    this.maxStringLength = 8000,
    this.maxArrayLength = 250,
  }) : _fieldNeedles = <String>{
         ..._defaultRedactedFields,
         ...fields,
       }.map(_normalizeField).toList(growable: false);

  final List<String> _fieldNeedles;
  final int maxStringLength;
  final int maxArrayLength;

  Object? clean(Object? value) => cleanWithReport(value).value;

  RedactionResult cleanWithReport(Object? value) {
    final fields = <String>{};
    final paths = <String>{};
    final cleaned = _visit(value, r'$', fields, paths, <Object>{});
    return RedactionResult(
      value: cleaned,
      report: RedactionReport(
        redacted: fields.isNotEmpty || paths.isNotEmpty,
        fields: fields.toList()..sort(),
        paths: paths.toList()..sort(),
      ),
    );
  }

  bool shouldRedactKey(String key) {
    final normalized = _normalizeField(key);
    return _fieldNeedles.any(normalized.contains);
  }

  Object? _visit(
    Object? value,
    String path,
    Set<String> fields,
    Set<String> paths,
    Set<Object> seen,
  ) {
    if (value == null) return null;
    if (value is num || value is bool) return value;
    if (value is String) {
      final redacted = _redactSensitiveString(value, path, fields, paths);
      if (redacted != null) return redacted;
      if (value.length <= maxStringLength) return value;
      paths.add(path);
      return '${value.substring(0, maxStringLength)}...[TRUNCATED]';
    }

    if (value is List) {
      if (seen.contains(value)) return '[Circular]';
      seen.add(value);
      return value
          .take(maxArrayLength)
          .toList()
          .asMap()
          .entries
          .map(
            (entry) =>
                _visit(entry.value, '$path[${entry.key}]', fields, paths, seen),
          )
          .toList();
    }

    if (value is Map) {
      if (seen.contains(value)) return '[Circular]';
      seen.add(value);
      final out = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final childPath = '$path.$key';
        if (shouldRedactKey(key)) {
          fields.add(key);
          paths.add(childPath);
          out[key] = _redactedValue;
          continue;
        }
        out[key] = _visit(entry.value, childPath, fields, paths, seen);
      }
      return out;
    }

    return value.toString();
  }

  String? _redactSensitiveString(
    String value,
    String path,
    Set<String> fields,
    Set<String> paths,
  ) {
    final url = _absoluteHttpUrl(value);
    if (url == null) {
      final normalized = _normalizeField(value);
      final hasSensitiveName = _fieldNeedles.any(normalized.contains);
      final looksLikeAssignment =
          RegExp(r'[:=]').hasMatch(value) ||
          value.toLowerCase().contains('bearer ');
      if (hasSensitiveName && looksLikeAssignment) {
        fields.add('string');
        paths.add(path);
        return _redactedValue;
      }
    }

    var cleaned = url == null ? value : _redactUrlParts(url, fields);
    var redacted = cleaned != value;
    if (_emailPattern.hasMatch(cleaned)) {
      cleaned = cleaned.replaceAll(_emailPattern, _redactedValue);
      fields.add('email');
      redacted = true;
    }
    if (_jwtPattern.hasMatch(cleaned)) {
      cleaned = cleaned.replaceAll(_jwtPattern, _redactedValue);
      fields.add('token');
      redacted = true;
    }
    if (_inlineCredentialPattern.hasMatch(cleaned)) {
      cleaned = cleaned.replaceAll(_inlineCredentialPattern, _redactedValue);
      fields.add('authorization');
      redacted = true;
    }
    if (_webhookUrlPattern.hasMatch(cleaned)) {
      cleaned = cleaned.replaceAll(_webhookUrlPattern, _redactedValue);
      fields.add('webhook');
      redacted = true;
    }
    if (_highEntropySecretPattern.hasMatch(cleaned)) {
      cleaned = cleaned.replaceAll(_highEntropySecretPattern, _redactedValue);
      fields.add('secret');
      redacted = true;
    }
    if (!redacted) return null;
    paths.add(path);
    return cleaned;
  }

  /// An absolute http(s) URL keeps its host and path: an evidence reader identifies a request by
  /// them, and the wholesale rule above would wipe every `/auth/...` or `/session/...` address
  /// because a URL always carries a colon. Credentials in a URL travel in its user info and its
  /// query values, which are redacted by name; the pattern rules still run on what remains.
  static Uri? _absoluteHttpUrl(String value) {
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      return null;
    }
    if (RegExp(r'\s').hasMatch(value)) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
    return uri;
  }

  String _redactUrlParts(Uri url, Set<String> fields) {
    final buffer = StringBuffer('${url.scheme}://');
    if (url.userInfo.isNotEmpty) {
      fields.add('credential');
      buffer.write('$_redactedValue@');
    }
    buffer.write(url.host.contains(':') ? '[${url.host}]' : url.host);
    if (url.hasPort) buffer.write(':${url.port}');
    buffer.write(url.path);
    if (url.hasQuery) {
      final pairs = url.query.split('&').map((pair) {
        final separator = pair.indexOf('=');
        final rawKey = separator < 0 ? pair : pair.substring(0, separator);
        final key = Uri.decodeQueryComponent(rawKey);
        if (rawKey.isEmpty || !shouldRedactKey(key)) return pair;
        fields.add(key);
        return '$rawKey=$_redactedValue';
      });
      buffer.write('?${pairs.join('&')}');
    }
    if (url.hasFragment) buffer.write('#${url.fragment}');
    return buffer.toString();
  }
}

class RedactionResult {
  const RedactionResult({required this.value, required this.report});

  final Object? value;
  final RedactionReport report;
}

RedactionReport mergeRedactionReports(Iterable<RedactionReport> reports) {
  final fields = <String>{};
  final paths = <String>{};
  for (final report in reports) {
    fields.addAll(report.fields);
    paths.addAll(report.paths);
  }
  return RedactionReport(
    redacted: fields.isNotEmpty || paths.isNotEmpty,
    fields: fields.toList()..sort(),
    paths: paths.toList()..sort(),
  );
}

String _normalizeField(String value) =>
    value.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
