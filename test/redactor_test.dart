import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final redactor = OperatorRedactor();

  test('an absolute URL keeps its host and path', () {
    const url = 'http://127.0.0.1:8787/auth/sign-in';
    final result = redactor.cleanWithReport(url);
    expect(result.value, url);
    expect(result.report.redacted, isFalse);
    expect(redactor.clean('https://api.example.com/session/refresh'), 'https://api.example.com/session/refresh');
  });

  test('sensitive query values and user info in a URL are redacted by name', () {
    final result = redactor.cleanWithReport(
      'https://api.example.com/session/refresh?token=abc123&page=2#top',
    );
    expect(
      result.value,
      'https://api.example.com/session/refresh?token=[REDACTED]&page=2#top',
    );
    expect(result.report.redacted, isTrue);
    expect(result.report.fields, contains('token'));
    expect(
      redactor.clean('https://user:pw@host.example/auth/callback'),
      'https://[REDACTED]@host.example/auth/callback',
    );
  });

  test('pattern rules still run on URLs', () {
    expect(
      redactor.clean('https://host.example/verify/someone@example.com'),
      'https://host.example/verify/[REDACTED]',
    );
  });

  test('assignment-shaped strings keep the wholesale rule', () {
    expect(redactor.clean('password=hunter2'), '[REDACTED]');
    expect(redactor.clean('Authorization: Bearer abcdefghijklmnop'), '[REDACTED]');
    expect(redactor.clean('/auth/sign-in'), '/auth/sign-in');
  });

  test('a captured network exchange keeps the request URL and redacts its secrets', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'redactor-network-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    operator.captureNetworkResponse(
      id: 'req-1',
      request: const NetworkRequest(
        method: 'POST',
        url: 'http://127.0.0.1:8787/auth/sign-in',
        body: <String, Object?>{'email': 'shopper@example.com', 'password': 'hunter2'},
      ),
      status: 200,
      ok: true,
      body: <String, Object?>{'accessToken': 'abc', 'user': 'usr_1'},
    );
    final snapshot = await operator.getSnapshot();
    final event = snapshot.network.events.last;
    expect(event.request.url, 'http://127.0.0.1:8787/auth/sign-in');
    expect(event.request.body, <String, Object?>{'email': '[REDACTED]', 'password': '[REDACTED]'});
    expect((event.response?.body as Map?)?['accessToken'], '[REDACTED]');
    expect(event.redacted, isTrue);
    operator.dispose();
  });
}
