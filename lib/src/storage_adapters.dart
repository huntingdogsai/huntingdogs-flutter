import 'package:flutter/widgets.dart';

import 'protocol.dart';
import 'runtime.dart';

class OperatorStorageAdapters {
  OperatorStorageAdapters(this.operator);

  final OperatorFlutter operator;

  void captureSharedPreferences({
    required String key,
    Object? value,
    bool metadataOnly = false,
  }) {
    operator.captureStorageEntry(
      StorageEntrySnapshot(
        area: 'sharedPreferences',
        key: key,
        value: value,
        valueType: value?.runtimeType.toString(),
        metadataOnly: metadataOnly,
        redacted: metadataOnly,
        source: 'shared_preferences',
        confidence: 0.9,
      ),
    );
  }

  void captureSecureStorage({
    required String key,
    Object? value,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final canCaptureValue =
        operator.config.environment != OperatorEnvironment.production &&
        value != null;
    operator.captureStorageEntry(
      StorageEntrySnapshot(
        area: 'secureStore',
        key: key,
        value: canCaptureValue ? value : metadata,
        valueType:
            canCaptureValue ? value.runtimeType.toString() : 'secure_metadata',
        metadataOnly: !canCaptureValue,
        redacted: !canCaptureValue,
        source: 'flutter_secure_storage',
        confidence: 0.86,
      ),
    );
  }

  void captureHiveBox({
    required String box,
    required String key,
    Object? value,
    bool metadataOnly = false,
  }) {
    operator.captureStorageEntry(
      StorageEntrySnapshot(
        area: 'hive',
        key: key,
        value: value,
        valueType: value?.runtimeType.toString(),
        namespace: box,
        metadataOnly: metadataOnly,
        redacted: metadataOnly,
        source: 'hive',
        confidence: 0.86,
      ),
    );
  }

  VoidCallback attachProvider(OperatorStorageProvider provider) =>
      operator.addStorageProvider(provider);
}
