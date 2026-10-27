import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

void main() {
  late OperatorObservedOperations registry;
  late Object owner;
  late int ticks;
  final clock = DateTime.utc(2026, 9, 13);

  setUp(() {
    ticks = 0;
    owner = Object();
    registry = OperatorObservedOperations(
      clock: () => clock.add(Duration(milliseconds: ticks)),
      ticks: () => ticks,
    );
  });

  ObservedDependencyOperation call([
    String identity = 'exact-document',
    Object? instance,
  ]) =>
      registry.begin(
        owner: instance ?? owner,
        identity: identity,
        description: {
          'service': 'firestore',
          'operation': 'getDocument',
          'path': 'settings/company',
        },
      )!;
  JsonMap arm(String ref, {int ttl = 100}) => registry.control({
    'kind': 'arm',
    'operationRef': ref,
    'faultId': 'fault-1',
    'code': 'permission-denied',
    'ttlMs': ttl,
  });
  JsonMap status() =>
      registry.control({'kind': 'status', 'faultId': 'fault-1'});

  test('an observation-only call is listed as such and cannot be armed', () {
    final recorded =
        registry.begin(
          owner: owner,
          identity: 'callable',
          description: const {'service': 'functions', 'operation': 'call'},
          faultable: false,
        )!;
    registry.complete(recorded, failed: false, result: const {'ok': true});
    final listed = registry.control({
      'kind': 'list',
      'from': clock.toIso8601String(),
      'to': clock.add(const Duration(minutes: 1)).toIso8601String(),
      'limit': 5,
    });
    final row = (listed['items'] as List).single as Map;
    expect(row['faultable'], isFalse);
    expect(row['status'], 'succeeded');
    expect(
      () => arm(recorded.ref),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'observed_fault_unsupported_operation',
        ),
      ),
    );
    expect(call().toJson().containsKey('faultable'), isFalse);
  });

  test(
    'an observed call is selected, armed, action-bound, and delivered only once',
    () {
      final selected = call();
      expect(arm(selected.ref)['status'], 'waiting_for_action');
      expect(
        registry.claim(call()),
        isNull,
        reason: 'Arming must not affect pre-action polling',
      );
      registry.control({'kind': 'activate', 'actionId': 'action-1'});
      expect(registry.claim(call('different-document')), isNull);
      expect(registry.claim(call('exact-document', Object())), isNull);
      final matching = call();
      final failure = registry.claim(matching)!;
      expect(
        registry.claim(call()),
        isNull,
        reason: 'Claim is consumed before any await',
      );
      expect(status()['status'], 'claimed');
      expect(
        status()['hitCount'],
        0,
        reason: 'Claiming alone is not a thrown SDK error',
      );
      registry.delivered(matching, failure);
      expect(status(), containsPair('status', 'delivered'));
      expect(status()['hitCount'], 1);
      expect(status()['actionId'], 'action-1');
      registry.clearAll();
      expect(
        status()['status'],
        'delivered',
        reason: 'Cleanup preserves delivery evidence',
      );
    },
  );

  test(
    'replayed activation is idempotent; a second action retires an unused fault',
    () {
      arm(call().ref);
      registry.control({'kind': 'activate', 'actionId': 'action-1'});
      registry.control({'kind': 'activate', 'actionId': 'action-1'});
      expect(status()['status'], 'active');
      registry.control({'kind': 'activate', 'actionId': 'action-2'});
      expect(status()['status'], 'unexercised');
      expect(registry.claim(call()), isNull);
    },
  );

  test('expiry, cleanup and detach never become delivery', () {
    arm(call().ref);
    ticks = 100;
    registry.control({'kind': 'activate', 'actionId': 'action-1'});
    expect(registry.claim(call()), isNull);
    expect(status()['status'], 'expired');
    registry.clearAll();
    expect(status()['status'], 'expired');
    final selected = call();
    registry.invalidateOwner(owner);
    expect(
      () => registry.control({
        'kind': 'arm',
        'operationRef': selected.ref,
        'faultId': 'new-fault',
        'code': 'unavailable',
        'ttlMs': 100,
      }),
      throwsStateError,
    );
  });

  test(
    'arm retries use the same id, not a second fault or a renewed expiry',
    () {
      final selected = call();
      arm(selected.ref);
      ticks = 50;
      arm(selected.ref);
      ticks = 100;
      expect(status()['status'], 'expired');
      expect(() => arm(call().ref), throwsStateError);
    },
  );

  test('retention is bounded by recorded size, not only by count', () {
    // Eighty calls carrying 60 k characters each pass the 4 MB budget long
    // before the count cap: the oldest drop and the gap is reported, while the
    // budget still keeps far more than the old 256-call retention did.
    for (var i = 0; i < 80; i++) {
      ticks = i;
      registry.begin(
        owner: owner,
        identity: 'large-$i',
        description: {
          'service': 'firestore',
          'operation': 'getDocument',
          'path': 'large/$i',
        },
        values: {'blob': 'x' * 60000},
      );
    }
    final result = registry.control({
      'kind': 'list',
      'from': clock.toIso8601String(),
      'to': clock.add(const Duration(seconds: 1)).toIso8601String(),
      'limit': 50,
      'pathContains': 'large/',
    });
    expect(result['historyComplete'], isFalse);
    expect(result['hasMore'], isTrue);
    final newest = (result['items'] as List).cast<Map>().first;
    expect(newest['path'], 'large/79', reason: 'the newest calls are kept');
    expect(
      registry.control({
        'kind': 'list',
        'from': clock.toIso8601String(),
        'to': clock.add(const Duration(seconds: 1)).toIso8601String(),
        'limit': 50,
        'pathContains': 'large/0',
      })['items'],
      isEmpty,
      reason: 'the oldest call was dropped to stay within the size budget',
    );
  });

  test(
    'listeners record emissions, the first result and how they ended; they cannot be armed',
    () {
      final listen =
          registry.begin(
            owner: owner,
            identity: 'listen-1',
            description: {
              'service': 'firestore',
              'operation': 'documentListen',
              'path': 'settings/company',
            },
            listener: true,
          )!;
      expect(listen.toJson()['emissions'], 0);
      expect(listen.toJson()['status'], 'pending');
      registry.emitted(
        listen,
        result: {
          'exists': true,
          'data': {'enabled': false},
        },
      );
      registry.emitted(
        listen,
        result: {
          'exists': true,
          'data': {'enabled': true},
        },
      );
      var json = listen.toJson();
      expect(json['status'], 'listening');
      expect(json['emissions'], 2);
      expect(
        json['result'],
        {
          'exists': true,
          'data': {'enabled': false},
        },
        reason: 'the first emission is kept; later ones only count',
      );
      expect(
        () => arm(listen.ref),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'observed_fault_listener_unsupported',
          ),
        ),
      );
      registry.cancelled(listen);
      json = listen.toJson();
      expect(json['status'], 'cancelled');
      expect(json['emissions'], 2);

      final failed =
          registry.begin(
            owner: owner,
            identity: 'listen-2',
            description: {
              'service': 'firestore',
              'operation': 'queryListen',
              'path': 'items',
            },
            listener: true,
          )!;
      registry.complete(
        failed,
        failed: true,
        errorCode: 'permission-denied',
        errorMessage: 'denied',
      );
      expect(failed.toJson()['status'], 'error');
      expect((failed.toJson()['error'] as Map)['code'], 'permission-denied');
      registry.cancelled(failed);
      expect(
        failed.toJson()['status'],
        'error',
        reason: 'an ended listener is not rewritten as cancelled',
      );
      expect(
        call().toJson().containsKey('emissions'),
        isFalse,
        reason: 'gets carry no emission count',
      );
    },
  );

  test(
    'a worker record keeps its own start time, and lost worker records mark the history',
    () {
      final startedOnWorker = clock.add(const Duration(milliseconds: 3));
      ticks = 10;
      final recorded =
          registry.begin(
            owner: owner,
            identity: 'worker-document',
            description: {
              'service': 'firestore',
              'operation': 'getDocument',
              'path': 'settings/company',
            },
            at: startedOnWorker,
          )!;
      expect(recorded.at, startedOnWorker);
      JsonMap list(DateTime from) => registry.control({
        'kind': 'list',
        'from': from.toIso8601String(),
        'to': clock.add(const Duration(seconds: 1)).toIso8601String(),
        'limit': 5,
      });
      final before = list(clock);
      expect(before['historyComplete'], isTrue);
      expect(before.containsKey('gapCodes'), isFalse);
      ticks = 20;
      registry.noteWorkerRecordsLost();
      final after = list(clock);
      expect(after['historyComplete'], isFalse);
      expect(after['gapCodes'], <String>['worker_records_lost']);
      final later = list(clock.add(const Duration(milliseconds: 30)));
      expect(
        later['historyComplete'],
        isTrue,
        reason: 'a window after the loss is whole',
      );
      expect(later.containsKey('gapCodes'), isFalse);
    },
  );

  test('listing is bounded, windowed, distinct and reports history loss', () {
    // The count cap is 2048 calls; the oldest drop and the gap is reported.
    for (var i = 0; i < 2100; i++) {
      ticks = i;
      call('document-$i');
    }
    final result = registry.control({
      'kind': 'list',
      'from': clock.toIso8601String(),
      'to': clock.add(const Duration(seconds: 3)).toIso8601String(),
      'limit': 5,
    });
    expect(result['items'], hasLength(5));
    expect(result['hasMore'], isTrue);
    expect(result['historyComplete'], isFalse);
    expect(
      () => registry.control({
        'kind': 'list',
        'from': clock.toIso8601String(),
        'to': clock.toIso8601String(),
        'limit': 200,
      }),
      throwsFormatException,
    );
    registry.close();
    expect(
      registry.begin(owner: owner, identity: 'closed', description: {}),
      isNull,
    );
  });
}
