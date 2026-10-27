import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'protocol.dart';
import 'runtime.dart';

/// Reads the actual storage backends only when a snapshot requests storage.
/// No platform replacement, write interception, initial copy or retained cache.
class OperatorSharedPreferencesReader {
  OperatorSharedPreferencesReader._();

  static VoidCallback install(OperatorFlutter operator) {
    // On web the host reads localStorage/sessionStorage directly, including
    // writes made by GetStorage rather than through shared_preferences.
    if (kIsWeb) return () {};
    final disposers = <VoidCallback>[
      operator.addStorageProvider(() async {
        final platform = SharedPreferencesAsyncPlatform.instance;
        if (platform == null) return const <StorageEntrySnapshot>[];
        final values = await platform.getPreferences(
          const GetPreferencesParameters(filter: PreferencesFilters()),
          const SharedPreferencesOptions(),
        );
        return _entries(values, 'async');
      }, replacesCapturedAreas: const <String>{'sharedPreferences'}),
      operator.addStorageProvider(() async {
        final values = await SharedPreferencesStorePlatform.instance.getAll();
        return _entries(values, 'legacy');
      }, replacesCapturedAreas: const <String>{'sharedPreferences'}),
    ];
    return () {
      for (final dispose in disposers.reversed) {
        dispose();
      }
    };
  }

  static Iterable<StorageEntrySnapshot> _entries(
    Map<String, Object> values,
    String backend,
  ) sync* {
    for (final entry in values.entries) {
      final value = _normalize(entry.value);
      yield StorageEntrySnapshot(
        area: 'sharedPreferences',
        key: entry.key,
        value: value,
        valueType: value.runtimeType.toString(),
        // Async and legacy preferences can use different native backends.
        namespace: backend,
        source: 'shared_preferences',
        confidence: 1,
        metadataOnly: false,
        redacted: false,
      );
    }
  }
}

Object? _normalize(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return jsonDecode(trimmed);
      } on FormatException {
        return value;
      }
    }
  }
  return value;
}
