import 'dart:convert';
import 'dart:math';

import 'protocol.dart';

/// Private SDK identities stay in this registry. The host presents its own
/// test-scoped references, never an editable path/operation matcher.
class OperatorObservedOperations {
  OperatorObservedOperations({
    DateTime Function()? clock,
    int Function()? ticks,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()),
       _ticks = ticks ?? (Stopwatch()..start()).elapsedMillisecondsGetter;

  final DateTime Function() _clock;
  final int Function() _ticks;
  final String _epoch = List.generate(
    4,
    (_) => Random.secure().nextInt(0x100000000).toRadixString(16),
  ).join('-');
  final Map<String, ObservedDependencyOperation> _calls = {};
  final Map<String, _ObservedFault> _faults = {};
  int _sequence = 0;
  DateTime? _droppedThrough;
  DateTime? _workerRecordsLostThrough;
  bool _closed = false;

  /// Retention is bounded by count and by recorded JSON size, whichever is
  /// reached first. Calls drop from the oldest end and the gap is reported
  /// through historyComplete=false, never hidden.
  static const int _maxRetainedCalls = 2048;
  static const int _maxRetainedChars = 4 * 1024 * 1024;
  int _retainedChars = 0;

  void noteUnrecordable() {
    // Do not report complete discovery when a query identity could not safely
    // be recorded. A conservative history gap never changes the application read.
    _droppedThrough = _clock();
  }

  /// A background worker isolate could not deliver some of its records. The
  /// history up to now is incomplete, and the listing names why.
  void noteWorkerRecordsLost() {
    _workerRecordsLostThrough = _clock();
  }

  /// Recorded values and results are capped at this many JSON characters.
  static const int _maxValueChars = 65536;

  /// Deep-copies a JSON-safe value. Oversized or unencodable values become a
  /// marker so a recorded operation never carries an unbounded or non-JSON payload.
  static Object? _boundedJson(Object? value) {
    try {
      final encoded = jsonEncode(value);
      if (encoded.length > _maxValueChars) {
        return <String, Object?>{'truncated': true, 'bytes': encoded.length};
      }
      return jsonDecode(encoded);
    } catch (_) {
      return <String, Object?>{'unrecordable': true};
    }
  }

  ObservedDependencyOperation? begin({
    required Object owner,
    required String identity,
    required JsonMap description,
    JsonMap? values,
    bool listener = false,
    bool faultable = true,
    DateTime? at,
  }) {
    if (_closed) return null;
    String? identityRef;
    for (final prior in [
      ..._calls.values,
      ..._faults.values.map((fault) => fault.selected),
    ]) {
      if (identical(prior.owner, owner) && prior.identity == identity) {
        identityRef = prior.identityRef;
        break;
      }
    }
    final call = ObservedDependencyOperation._(
      ref: 'sdk-op-$_epoch-${++_sequence}',
      identityRef: identityRef ?? 'sdk-identity-$_epoch-$_sequence',
      owner: owner,
      identity: identity,
      description: Map<String, Object?>.from(
        jsonDecode(jsonEncode(description)) as Map,
      ),
      // A record made on a worker isolate keeps the time the worker started it.
      at: at ?? _clock(),
      listener: listener,
      faultable: faultable,
    );
    if (values != null) call.values = _boundedJson(values) as JsonMap?;
    _calls[call.ref] = call;
    _account(call);
    _trim();
    return call;
  }

  /// Re-measures one call after its recorded content changed.
  void _account(ObservedDependencyOperation call) {
    int chars;
    try {
      chars = jsonEncode(call.toJson()).length;
    } catch (_) {
      chars = _maxValueChars;
    }
    _retainedChars += chars - call._chars;
    call._chars = chars;
  }

  void _trim() {
    while (_calls.isNotEmpty &&
        (_calls.length > _maxRetainedCalls ||
            _retainedChars > _maxRetainedChars)) {
      final dropped = _calls.remove(_calls.keys.first)!;
      _retainedChars -= dropped._chars;
      if (_droppedThrough == null || dropped.at.isAfter(_droppedThrough!))
        _droppedThrough = dropped.at;
    }
  }

  /// One listener emission. The first emission's data becomes [result]; later
  /// emissions only advance the count, so a chatty stream stays bounded.
  void emitted(ObservedDependencyOperation? call, {Object? result}) {
    if (call == null) return;
    call.emissions += 1;
    if (call.status == 'pending') call.status = 'listening';
    if (call.emissions == 1) {
      if (result != null) call.result = _boundedJson(result);
      _account(call);
      _trim();
    }
  }

  /// The application stopped listening before the stream ended.
  void cancelled(ObservedDependencyOperation? call) {
    if (call == null) return;
    if (call.status == 'pending' || call.status == 'listening') {
      call.status = 'cancelled';
    }
  }

  /// Synchronous claim-before-await makes concurrent identical gets single-use.
  ObservedSdkFailure? claim(ObservedDependencyOperation call) {
    _expire();
    for (final fault in _faults.values) {
      if (fault.status != 'active' ||
          !identical(fault.selected.owner, call.owner) ||
          fault.selected.identity != call.identity)
        continue;
      fault.status = 'claimed';
      fault.matched = call;
      return ObservedSdkFailure._(fault.id, fault.code, fault.message);
    }
    return null;
  }

  /// Called by the SDK wrapper immediately before throwing its FirebaseException.
  void delivered(ObservedDependencyOperation call, ObservedSdkFailure failure) {
    final fault = _faults[failure.ref];
    if (fault == null ||
        fault.status != 'claimed' ||
        !identical(fault.matched, call)) {
      throw StateError('observed_fault_delivery_mismatch');
    }
    fault.status = 'delivered';
    fault.deliveredAt = _clock().toIso8601String();
    call.status = 'injected_error';
  }

  /// Records the outcome. [result] carries returned values (document data),
  /// [values] and [path] refine what a batch or transaction actually wrote.
  void complete(
    ObservedDependencyOperation? call, {
    required bool failed,
    Object? result,
    JsonMap? values,
    String? path,
    String? errorCode,
    String? errorMessage,
  }) {
    if (call == null) return;
    if (values != null) call.values = _boundedJson(values) as JsonMap?;
    if (result != null) call.result = _boundedJson(result);
    if (path != null) call.description['path'] = path;
    if (failed && (errorCode != null || errorMessage != null)) {
      call.error = <String, Object?>{
        if (errorCode != null) 'code': errorCode,
        if (errorMessage != null)
          'message':
              errorMessage.length > 256
                  ? errorMessage.substring(0, 256)
                  : errorMessage,
      };
    }
    if (call.status == 'pending' || call.status == 'listening') {
      call.status = failed ? 'error' : 'succeeded';
    }
    _account(call);
    _trim();
  }

  void invalidateOwner(Object owner) {
    _calls.removeWhere((_, call) {
      if (!identical(call.owner, owner)) return false;
      _retainedChars -= call._chars;
      return true;
    });
    for (final fault in _faults.values) {
      if (identical(fault.selected.owner, owner) && fault.pending)
        fault.status = 'invalidated';
    }
  }

  bool get hasPending {
    _expire();
    return _faults.values.any((fault) => fault.pending);
  }

  void clearAll() {
    _expire();
    for (final fault in _faults.values) {
      if (fault.pending) fault.status = 'cleared';
    }
  }

  void close() {
    clearAll();
    _closed = true;
    _calls.clear();
    _retainedChars = 0;
  }

  /// Only the host bridge uses this wire API. It revalidates installation and
  /// current-test ownership before invoking it. Arm is idempotent by faultId.
  JsonMap control(JsonMap request) {
    if (_closed) throw StateError('observed_operations_closed');
    _expire();
    switch (request['kind']) {
      case 'list':
        final from = DateTime.parse(_string(request, 'from'));
        final to = DateTime.parse(_string(request, 'to'));
        final limit = request['limit'];
        if (from.isAfter(to) || limit is! int || limit < 1 || limit > 50) {
          throw const FormatException(
            'observed_operations_invalid_window_or_limit',
          );
        }
        final path = request['pathContains'];
        if (path != null && (path is! String || path.isEmpty)) {
          throw const FormatException(
            'observed_operations_invalid_path_filter',
          );
        }
        final matches = _calls.values.where(
          (call) =>
              !call.at.isBefore(from) &&
              !call.at.isAfter(to) &&
              (path == null ||
                  (call.description['path'] as String? ?? '').contains(
                    path as String,
                  )),
        );
        // One choice per exact identity: repeated polling must not hide other calls.
        final byOwner =
            Map<Object, Map<String, ObservedDependencyOperation>>.identity();
        for (final call in matches) {
          byOwner.putIfAbsent(call.owner, () => {})[call.identity] = call;
        }
        final calls =
            byOwner.values.expand((items) => items.values).toList()
              ..sort((left, right) => right.at.compareTo(left.at));
        final workerRecordsLost =
            _workerRecordsLostThrough != null &&
            !_workerRecordsLostThrough!.isBefore(from);
        return {
          'items': calls.take(limit).map((call) => call.toJson()).toList(),
          'hasMore': calls.length > limit,
          'historyComplete':
              (_droppedThrough == null || _droppedThrough!.isBefore(from)) &&
              !workerRecordsLost,
          if (workerRecordsLost) 'gapCodes': const ['worker_records_lost'],
        };
      case 'arm':
        final id = _string(request, 'faultId');
        final ref = _string(request, 'operationRef');
        final code = _string(request, 'code');
        final ttl = request['ttlMs'];
        final message = request['message'];
        if (!const {
              'permission-denied',
              'unavailable',
              'deadline-exceeded',
              'unauthenticated',
              'resource-exhausted',
              'internal',
              'aborted',
              'not-found',
            }.contains(code) ||
            ttl is! int ||
            ttl < 1 ||
            ttl > 300000 ||
            (message != null && (message is! String || message.length > 256))) {
          throw const FormatException('observed_fault_invalid_error_or_ttl');
        }
        final previous = _faults[id];
        if (previous != null) {
          if (previous.selected.ref != ref ||
              previous.code != code ||
              previous.ttl != ttl ||
              previous.message != (message ?? 'Watchdog injected SDK error')) {
            throw StateError('observed_fault_id_conflict');
          }
          return previous.toJson();
        }
        final selected = _calls[ref];
        if (selected == null)
          throw StateError('observed_operation_expired_or_unknown');
        // Only gets are armed. A listener is recorded, never failed.
        if (selected.listener)
          throw StateError('observed_fault_listener_unsupported');
        // Rows recorded for observation only (Functions, Auth, Storage, Remote Config and
        // Firestore administration) have no wrapper that could deliver an SDK error.
        if (!selected.faultable)
          throw StateError('observed_fault_unsupported_operation');
        if (hasPending) throw StateError('observed_fault_already_pending');
        if (_faults.length >= 64)
          throw StateError('observed_fault_retention_full');
        final fault = _ObservedFault(
          id,
          selected,
          code,
          message as String? ?? 'Watchdog injected SDK error',
          ttl,
          _ticks() + ttl,
        );
        _faults[id] = fault;
        return fault.toJson();
      case 'activate':
        final actionId = _string(request, 'actionId');
        for (final fault in _faults.values) {
          if (fault.status == 'waiting_for_action') {
            fault.status = 'active';
            fault.actionId = actionId;
          } else if (fault.status == 'active' && fault.actionId != actionId) {
            fault.status = 'unexercised';
          }
        }
        return {'pending': hasPending};
      case 'status':
      case 'clear':
        final id = _string(request, 'faultId');
        final fault = _faults[id];
        if (fault == null) {
          if (request['kind'] == 'clear') {
            return {
              'ref': id,
              'status': 'absent',
              'hitCount': 0,
              'fidelity': 'sdk_error',
            };
          }
          throw StateError('observed_fault_unknown');
        }
        if (request['kind'] == 'clear' && fault.pending)
          fault.status = 'cleared';
        final result = fault.toJson();
        if (request['kind'] == 'clear' && request['forget'] == true)
          _faults.remove(id);
        return result;
      default:
        throw const FormatException('observed_operations_unknown_command');
    }
  }

  void _expire() {
    for (final fault in _faults.values) {
      if (fault.pending && fault.deadline <= _ticks()) fault.status = 'expired';
    }
  }

  static String _string(JsonMap value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty || field.length > 1024) {
      throw FormatException('observed_operations_invalid_$key');
    }
    return field;
  }
}

extension on Stopwatch {
  int elapsedMillisecondsGetter() => elapsedMilliseconds;
}

class ObservedDependencyOperation {
  ObservedDependencyOperation._({
    required this.ref,
    required this.identityRef,
    required this.owner,
    required this.identity,
    required this.description,
    required this.at,
    this.listener = false,
    this.faultable = true,
  });
  final String ref;
  final String identityRef;
  final Object owner;
  final String identity;
  final JsonMap description;
  final DateTime at;

  /// A snapshot listener: [result] is its first emission and [emissions]
  /// counts every emission; status moves pending -> listening -> succeeded,
  /// error or cancelled.
  final bool listener;

  /// Whether an SDK error can be armed against this call. Observation-only rows say so.
  final bool faultable;
  int emissions = 0;
  String status = 'pending';
  JsonMap? values;
  Object? result;
  JsonMap? error;
  int _chars = 0;

  JsonMap toJson() => {
    ...description,
    'ref': ref,
    'identityRef': identityRef,
    'at': at.toIso8601String(),
    'status': status,
    if (listener) 'emissions': emissions,
    if (!faultable) 'faultable': false,
    if (values != null) 'values': values,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
  };
}

class ObservedSdkFailure {
  ObservedSdkFailure._(this.ref, this.code, this.message);
  final String ref;
  final String code;
  final String message;
}

class _ObservedFault {
  _ObservedFault(
    this.id,
    this.selected,
    this.code,
    this.message,
    this.ttl,
    this.deadline,
  );
  final String id;
  final ObservedDependencyOperation selected;
  final String code;
  final String message;
  final int ttl;
  final int deadline;
  String status = 'waiting_for_action';
  String? actionId;
  ObservedDependencyOperation? matched;
  String? deliveredAt;
  bool get pending => status == 'waiting_for_action' || status == 'active';
  JsonMap toJson() => {
    'ref': id,
    'status': status,
    'fidelity': 'sdk_error',
    'code': code,
    'hitCount': status == 'delivered' ? 1 : 0,
    if (actionId != null) 'actionId': actionId,
    if (matched != null) 'matchedOperationRef': matched!.ref,
    if (deliveredAt != null) 'deliveredAt': deliveredAt,
  };
}
