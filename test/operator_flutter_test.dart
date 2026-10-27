import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' as getx;
import 'package:huntingdogs/huntingdogs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

final _operatorRiverpodInventoryProvider =
    riverpod.Provider<Map<String, Object?>>(
      (ref) => <String, Object?>{'sku': 'COKE', 'count': 13},
      name: 'OperatorRiverpodInventory',
    );

void main() {
  late SharedPreferencesStorePlatform previousStoragePlatform;
  setUp(() {
    previousStoragePlatform = SharedPreferencesStorePlatform.instance;
    // Snapshots now read storage on request; widget tests have no native plugin.
    SharedPreferencesStorePlatform.instance =
        _FakeSharedPreferencesStorePlatform();
  });
  tearDown(() {
    SharedPreferencesStorePlatform.instance = previousStoragePlatform;
  });

  test('snapshot JSON derives visibleTexts from visible UI elements', () {
    final snapshot = AppSnapshot(
      snapshotId: 'snap_visible_texts',
      timestamp: DateTime.utc(2026),
      app: const AppInfo(
        appId: 'flutter-test',
        name: 'Flutter Test',
        platform: OperatorPlatform.flutter,
        environment: OperatorEnvironment.dev,
      ),
      userSession: const UserSession(),
      route: const RouteState(current: RouteEntry(path: '/')),
      ui: const UiTree(
        rootId: 'root',
        viewport: ViewportSnapshot(width: 390, height: 844),
        elements: <UiElement>[
          UiElement(
            id: 'primary',
            role: OperatorUiRole.button,
            label: '  Add   Coke  ',
            text: 'Add Coke',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'hidden',
            role: OperatorUiRole.text,
            text: 'Hidden text',
            enabled: true,
            visible: false,
            actions: <String>[],
            confidence: 1,
          ),
          UiElement(
            id: 'value',
            role: OperatorUiRole.input,
            value: 'Jewel',
            hint: 'Profile',
            enabled: true,
            visible: true,
            actions: <String>['type'],
            confidence: 1,
          ),
        ],
      ),
      state: const <StateStoreSnapshot>[],
      network: const NetworkTimeline(events: <NetworkEvent>[]),
      logs: const <LogEvent>[],
      dialogs: const <DialogState>[],
      capabilities: flutterCapabilities(
        hasStateProviders: false,
        hasStorageProviders: false,
        capturesScreenshots: false,
      ),
      redactions: const RedactionReport(
        redacted: false,
        fields: <String>[],
        paths: <String>[],
      ),
    );

    final ui = operatorSnapshotToJson(snapshot)['ui'] as Map<String, Object?>;

    expect(ui['visibleTexts'], <String>['Add Coke', 'Jewel']);
  });

  test(
    'redacts sensitive state and verifies route/state/network evidence',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-test',
          environment: OperatorEnvironment.dev,
          privacy: OperatorPrivacyConfig(redactFields: <String>['token']),
        ),
      );
      final adapter = OperatorFlutterAdapter(operator);

      operator.captureRoute(path: '/search', name: 'search');
      operator.captureUiTree(
        const UiTree(
          rootId: 'root',
          viewport: ViewportSnapshot(width: 390, height: 844),
          elements: <UiElement>[
            UiElement(
              id: 'product-search-input',
              role: OperatorUiRole.input,
              label: 'Search products',
              enabled: true,
              visible: true,
              actions: <String>['type'],
              confidence: 1,
            ),
          ],
        ),
      );
      operator.storageAdapters.captureSharedPreferences(
        key: 'cart:draft',
        value: <String, Object?>{
          'token': 'secret-token',
          'customerEmail': 'ada@example.com',
          'items': 1,
        },
      );
      operator.storageAdapters.captureSharedPreferences(
        key: 'dexter_prefs_last-entered-login-email',
        value: 'dexter-internal@dexter-health.com',
      );
      operator.storageAdapters.captureSharedPreferences(
        key: 'dexter_prefs_dexter_envs',
        value: <String, Object?>{
          'ENCRYPTION_KEY': 'h2j3k4l5m6n7b8v9c0x1z2a3s4d5f6g7h8j9k0l',
          'SLACK_ERROR_WEBHOOK_URL':
              'https://hooks.slack.com/services/T000/B000/secret',
          'SIS_GATEWAY_BASE_URL':
              'https://api-gateway-staging-319464104816.europe-west4.run.app',
        },
      );
      operator.storageAdapters.captureSecureStorage(
        key: 'staging-access-key',
        value: 'flutter-stage-value',
        metadata: <String, Object?>{'present': true},
      );
      operator.captureError(
        type: 'FlutterTestError',
        message: 'Handled Flutter warning',
        source: 'test',
        data: <String, Object?>{'token': 'secret-token'},
      );
      operator.captureStateChange(
        source: OperatorStateSource.bloc,
        name: 'ProductSearchState',
        value: <String, Object?>{
          'query': 'Coke',
          'token': 'secret-token',
          'lastContact': 'Customer ada@example.com requested support',
          'diagnostic': 'sessionToken=secret-token',
        },
      );
      operator.captureNetworkResponse(
        id: 'net_1',
        request: networkRequest(
          method: 'GET',
          url: '/products/search?q=Coke',
          path: '/products/search',
        ),
        status: 200,
        ok: true,
        body: <String, Object?>{'products': <Object>[]},
      );

      final before = await adapter.getSnapshot();
      final action = const ActionCommand(
        type: OperatorActionType.navigate,
        path: '/checkout',
        purpose: 'open_checkout',
        risk: 1,
        expected: <VerificationCondition>[
          VerificationCondition(
            source: OperatorVerificationSource.route,
            path: '/checkout',
          ),
          VerificationCondition(
            source: OperatorVerificationSource.state,
            store: 'ProductSearchState',
            path: 'query',
            equals: 'Coke',
          ),
          VerificationCondition(
            source: OperatorVerificationSource.network,
            method: 'GET',
            path: '/products/search',
            ok: true,
          ),
        ],
      );
      final result = await adapter.execute(action);
      final after = await adapter.getSnapshot();
      final verification = adapter.verify(
        VerificationRequest(
          action: action,
          before: before,
          after: after,
          result: result,
        ),
      );

      expect(
        result.ok,
        isTrue,
        reason: '${result.error?.type}: ${result.error?.message}',
      );
      expect(verification.ok, isTrue);
      expect(after.route.current.path, '/checkout');
      expect(
        after.visual?.regions.any(
          (region) => region.elementId == 'product-search-input',
        ),
        isTrue,
      );
      expect(
        after.visual?.ocr.any((region) => region.text == 'Search products'),
        isTrue,
      );
      expect(after.visual?.metadata['pixelBacked'], isFalse);
      expect(
        (after.visual?.analysis['assertions'] as JsonMap?)?['hasVisibleText'],
        isTrue,
      );
      operator.captureVisualFrame(
        const VisualFrame(
          id: 'flutter-test-frame',
          format: 'png',
          encoding: 'base64',
          data: 'iVBORw0KGgoAAAANSUhEUgAAAYYAAANM',
          width: 390,
          height: 844,
          source: 'manual',
          redacted: false,
        ),
      );
      final visualFrameSnapshot = await adapter.getSnapshot();
      expect(
        visualFrameSnapshot.visual?.frames.any(
          (frame) => frame.id == 'flutter-test-frame',
        ),
        isTrue,
      );
      expect(after.forms.single.fields.single.id, 'product-search-input');
      expect(
        (after.storage!.entries
                .singleWhere((entry) => entry.key == 'cart:draft')
                .value
            as Map<String, Object?>),
        containsPair('token', '[REDACTED]'),
      );
      expect(
        (after.storage!.entries
                .singleWhere((entry) => entry.key == 'cart:draft')
                .value
            as Map<String, Object?>),
        containsPair('customerEmail', '[REDACTED]'),
      );
      final loginEmailEntry = after.storage!.entries.singleWhere(
        (entry) => entry.key == 'dexter_prefs_last-entered-login-email',
      );
      expect(loginEmailEntry.metadataOnly, isTrue);
      expect(loginEmailEntry.redacted, isTrue);
      expect(loginEmailEntry.value, isNull);
      final envEntry =
          after.storage!.entries
                  .singleWhere(
                    (entry) => entry.key == 'dexter_prefs_dexter_envs',
                  )
                  .value
              as Map<String, Object?>;
      expect(envEntry['ENCRYPTION_KEY'], '[REDACTED]');
      expect(envEntry['SLACK_ERROR_WEBHOOK_URL'], '[REDACTED]');
      expect(
        envEntry['SIS_GATEWAY_BASE_URL'],
        'https://api-gateway-staging-319464104816.europe-west4.run.app',
      );
      final productSearchState = after.state.singleWhere(
        (store) => store.name == 'ProductSearchState',
      );
      expect(
        productSearchState.value as Map<String, Object?>,
        containsPair('lastContact', 'Customer [REDACTED] requested support'),
      );
      final accessKeyEntry = after.storage!.entries.singleWhere(
        (entry) => entry.key == 'staging-access-key',
      );
      expect(accessKeyEntry.metadataOnly, isTrue);
      expect(accessKeyEntry.redacted, isTrue);
      expect(accessKeyEntry.value, isNull);
      expect(
        after.errors.any((error) => error.message == 'Handled Flutter warning'),
        isTrue,
      );

      final injectStorage = await adapter.execute(
        const ActionCommand(
          type: OperatorActionType.injectStorage,
          area: 'sharedPreferences',
          key: 'feature:checkout',
          value: <String, Object?>{'enabled': true},
          expected: <VerificationCondition>[
            VerificationCondition(
              source: OperatorVerificationSource.storage,
              area: 'sharedPreferences',
              key: 'feature:checkout',
            ),
          ],
        ),
      );
      expect(injectStorage.ok, isTrue);

      final injectForm = await adapter.execute(
        const ActionCommand(
          type: OperatorActionType.injectForm,
          fields: <FormFieldPatch>[
            FormFieldPatch(id: 'product-search-input', value: 'Seeded Coke'),
          ],
          expected: <VerificationCondition>[
            VerificationCondition(
              source: OperatorVerificationSource.form,
              fieldId: 'product-search-input',
              value: 'Seeded Coke',
            ),
          ],
        ),
      );
      expect(injectForm.ok, isTrue);
      final injected = await adapter.getSnapshot();
      expect(
        injected.storage!.entries.any(
          (entry) =>
              entry.area == 'sharedPreferences' &&
              entry.key == 'feature:checkout',
        ),
        isTrue,
      );
      expect(
        injected.forms.single.fields
            .singleWhere((field) => field.id == 'product-search-input')
            .value,
        'Seeded Coke',
      );
      expect(
        adapter
            .verify(
              VerificationRequest(
                action: injectForm.action,
                before: after,
                after: injected,
                result: injectForm,
              ),
            )
            .ok,
        isTrue,
      );
      expect(after.redactions.redacted, isTrue);
      expect(after.redactions.fields, contains('token'));
      expect(
        after.state
            .singleWhere((store) => store.name == 'ProductSearchState')
            .value,
        containsPair('token', '[REDACTED]'),
      );
      expect(
        after.state
            .singleWhere((store) => store.name == 'ProductSearchState')
            .value,
        containsPair('diagnostic', '[REDACTED]'),
      );

      operator.dispose();
    },
  );

  test(
    'snapshot associates unlabeled checkbox fields with adjacent labels',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-checkbox-label-association-test',
          environment: OperatorEnvironment.dev,
        ),
      );

      operator.captureUiTree(
        const UiTree(
          rootId: 'filter-sheet-root',
          viewport: ViewportSnapshot(width: 393, height: 852),
          elements: <UiElement>[
            UiElement(
              id: 'filter-sheet',
              role: OperatorUiRole.button,
              label:
                  'Filter Wähle die Dokumentationskategorien aus, die du sehen möchtest.',
              enabled: true,
              visible: true,
              actions: <String>['tap'],
              bounds: ElementBounds(x: 0, y: 138, width: 393, height: 714),
              children: <String>[
                'planned-checkbox',
                'planned-label',
                'extra-checkbox',
                'extra-label',
              ],
              confidence: 1,
            ),
            UiElement(
              id: 'planned-checkbox',
              role: OperatorUiRole.checkbox,
              enabled: true,
              visible: true,
              checked: true,
              selected: true,
              actions: <String>['tap'],
              bounds: ElementBounds(x: 10, y: 269, width: 40, height: 40),
              parentId: 'filter-sheet',
              confidence: 1,
            ),
            UiElement(
              id: 'planned-label',
              role: OperatorUiRole.button,
              label: 'geplante Maßnahmen',
              text: 'geplante Maßnahmen',
              enabled: true,
              visible: true,
              actions: <String>['tap'],
              bounds: ElementBounds(x: 50, y: 274.5, width: 184, height: 29),
              parentId: 'filter-sheet',
              confidence: 1,
            ),
            UiElement(
              id: 'extra-checkbox',
              role: OperatorUiRole.checkbox,
              enabled: true,
              visible: true,
              checked: false,
              selected: false,
              actions: <String>['tap'],
              bounds: ElementBounds(x: 10, y: 309, width: 40, height: 40),
              parentId: 'filter-sheet',
              confidence: 1,
            ),
            UiElement(
              id: 'extra-label',
              role: OperatorUiRole.button,
              label: 'zusätzliche Maßnahmen',
              text: 'zusätzliche Maßnahmen',
              enabled: true,
              visible: true,
              actions: <String>['tap'],
              bounds: ElementBounds(x: 50, y: 314.5, width: 184, height: 29),
              parentId: 'filter-sheet',
              confidence: 1,
            ),
          ],
        ),
      );

      final snapshot = await operator.getSnapshot();
      final fields = snapshot.forms.single.fields;
      expect(
        fields.map((field) => field.label),
        containsAll(<String>['geplante Maßnahmen', 'zusätzliche Maßnahmen']),
      );
      expect(
        fields.singleWhere((field) => field.id == 'planned-checkbox').checked,
        isTrue,
      );
      expect(
        fields.singleWhere((field) => field.id == 'extra-checkbox').checked,
        isFalse,
      );

      operator.dispose();
    },
  );

  test(
    'snapshot treats masked password inputs as secure form fields',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-masked-password-form-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final maskedPassword = String.fromCharCodes(List<int>.filled(9, 0x25cf));

      operator.captureUiTree(
        UiTree(
          rootId: 'login-root',
          viewport: const ViewportSnapshot(width: 393, height: 852),
          elements: <UiElement>[
            UiElement(
              id: 'password-input',
              role: OperatorUiRole.input,
              label: 'Enter your password',
              value: maskedPassword,
              enabled: true,
              visible: true,
              actions: const <String>['tap'],
              confidence: 1,
            ),
          ],
        ),
      );

      final field = (await operator.getSnapshot()).forms.single.fields.single;
      expect(field.secure, isTrue);
      expect(field.value, '[SECURE_FIELD]');

      operator.dispose();
    },
  );

  test(
    'getSnapshot can skip UI providers for interaction verification',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-lightweight-interaction-snapshot-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      operator.captureUiTree(
        const UiTree(
          rootId: 'root',
          viewport: ViewportSnapshot(width: 390, height: 844),
          elements: <UiElement>[
            UiElement(
              id: 'cached-button',
              role: OperatorUiRole.button,
              label: 'Cached',
              visible: true,
              enabled: true,
              actions: <String>['tap'],
              confidence: 1,
            ),
          ],
        ),
      );

      var providerReads = 0;
      operator.addUiProvider(() {
        providerReads += 1;
        return const <UiElement>[
          UiElement(
            id: 'provider-button',
            role: OperatorUiRole.button,
            label: 'Provider',
            visible: true,
            enabled: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
        ];
      });
      final readsAfterRegistration = providerReads;

      final lightweight = await operator.getSnapshot(
        refreshVisual: false,
        refreshProviders: false,
        refreshUiProviders: false,
        issueActionTargets: false,
      );
      expect(providerReads, readsAfterRegistration);
      expect(
        lightweight.ui.elements.map((element) => element.id),
        isNot(contains('provider-button')),
      );

      final full = await operator.getSnapshot(
        refreshVisual: false,
        refreshProviders: false,
      );
      expect(providerReads, readsAfterRegistration + 1);
      expect(
        full.ui.elements.map((element) => element.id),
        contains('provider-button'),
      );

      operator.dispose();
    },
  );

  test('clearSimulation keeps visual evidence intact', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-clear-simulation-visual-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    operator.captureVisualFrame(
      const VisualFrame(
        id: 'persisted-visual-frame',
        format: 'png',
        encoding: 'base64',
        data: 'iVBORw0KGgoAAAANSUhEUgAAAYYAAANM',
        width: 390,
        height: 844,
        source: 'manual',
        redacted: false,
      ),
    );
    operator.installNetworkMock(
      const NetworkMockMatch(method: 'GET', path: '/test'),
      const NetworkMockResponse(status: 200),
    );

    operator.clearSimulation('all');
    final snapshot = await operator.getSnapshot(refreshVisual: false);

    expect(
      snapshot.visual?.frames.any(
        (frame) => frame.id == 'persisted-visual-frame',
      ),
      isTrue,
    );
    expect(snapshot.visual?.metadata['pixelBacked'], isTrue);

    operator.dispose();
  });

  test('installs and resolves Firebase mocks in dev', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-firebase-mock-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final adapter = OperatorFlutterAdapter(operator);

    final result = await adapter.execute(
      const ActionCommand(
        type: OperatorActionType.installFirebaseMock,
        firebase: FirebaseMockMatch(
          service: 'firestore',
          operation: 'getDocument',
          path: 'users/u1',
        ),
        firebaseResponse: FirebaseMockResponse(
          value: <String, Object?>{'name': 'Ada'},
        ),
      ),
    );

    expect(
      result.ok,
      isTrue,
      reason:
          '${result.error?.type}: ${result.error?.message}; evidence=${result.evidence.map((entry) => '${entry.condition}:${entry.detail}').join(' | ')}',
    );
    expect(
      operator
          .findFirebaseMock(
            const FirebaseMockMatch(
              service: 'firestore',
              operation: 'getDocument',
              path: '/users/u1/',
            ),
          )
          ?.value,
      containsPair('name', 'Ada'),
    );

    operator.dispose();
  });

  test('Firebase virtualization probe fails clearly without adapter', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-firebase-probe-missing-adapter-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final adapter = OperatorFlutterAdapter(operator);

    final result = await adapter.execute(
      const ActionCommand(type: OperatorActionType.probeFirebaseVirtualization),
    );

    expect(result.ok, isFalse);
    expect(result.error?.type, 'firebase_virtualization_probe_unavailable');

    operator.dispose();
  });

  test(
    'media supply fails clearly without the media stand-in, and a production app refuses it, on both action routes',
    () async {
      final command = ActionCommand(
        type: OperatorActionType.supplyMedia,
        to: 'camera',
        media: OperatorSuppliedMedia(
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          mediaId: 'photo-1',
          mediaType: 'image/jpeg',
        ),
      );
      for (final environment in <OperatorEnvironment>[
        OperatorEnvironment.dev,
        OperatorEnvironment.production,
      ]) {
        final operator = await OperatorFlutter.init(
          OperatorFlutterConfig(
            appId: 'flutter-media-supply-${environment.name}',
            environment: environment,
          ),
        );
        addTearDown(operator.dispose);
        for (final adapter in <OperatorFlutterAdapter>[
          OperatorFlutterAdapter(operator),
          OperatorProductionBinding(operator: operator).adapter,
        ]) {
          final result = await adapter.execute(command);
          expect(result.ok, isFalse);
          expect(
            result.error?.type,
            environment == OperatorEnvironment.production
                ? 'simulation_blocked'
                : 'media_stand_in_unavailable',
          );
        }
      }
    },
  );

  test(
    'a clear takes supplied media back first, on both action routes, and fails when the stand-in cannot confirm',
    () async {
      for (final route in <String>['default', 'automatic']) {
        final operator = await OperatorFlutter.init(
          OperatorFlutterConfig(
            appId: 'flutter-media-clear-$route',
            environment: OperatorEnvironment.dev,
          ),
        );
        addTearDown(operator.dispose);
        final asked = <String?>[];
        var confirm = true;
        var broken = false;
        operator.registerVirtualizationProbe('media', (command, operator) {
          if (broken) throw StateError('the stand-in broke');
          asked.add(
            command.type == OperatorActionType.clearSimulation
                ? command.scope
                : command.type.name,
          );
          // The stand-in's own record of the take-back belongs to the test that ends.
          operator.captureNetworkEvent(
            NetworkEvent(
              id: 'take-back-${asked.length}',
              timestamp: DateTime.now().toUtc(),
              request: networkRequest(
                method: 'MEDIA',
                url: 'media://camera/takeBack',
              ),
              redacted: false,
            ),
          );
          return ActionResult(
            ok: confirm,
            action: command,
            data: const <String, Object?>{
              'camera': <String, Object?>{'cleared': true},
            },
            error:
                confirm
                    ? null
                    : const ActionError(
                      type: 'stuck',
                      message: 'the stand-in is stuck',
                    ),
          );
        });
        final adapter =
            route == 'default'
                ? OperatorFlutterAdapter(operator)
                : OperatorProductionBinding(operator: operator).adapter;
        Future<ActionResult> clear(String scope) => adapter.execute(
          ActionCommand(type: OperatorActionType.clearSimulation, scope: scope),
        );

        final all = await clear('all');
        expect(all.ok, isTrue, reason: route);
        expect(all.data['media'], <String, Object?>{
          'camera': <String, Object?>{'cleared': true},
        });
        expect(
          (await operator.getSnapshot(
            refreshVisual: false,
          )).network.events.where((event) => event.id == 'take-back-1'),
          isEmpty,
          reason:
              'the take-back ran before the clear, so its record went with the ending test',
        );
        expect((await clear('media')).ok, isTrue);
        final state = await clear('state');
        expect(state.ok, isTrue);
        expect(state.data.containsKey('media'), isFalse);
        expect(asked, <String?>['all', 'media'], reason: route);

        confirm = false;
        final failed = await clear('all');
        expect(failed.ok, isFalse, reason: route);
        expect(failed.error?.type, 'simulation_cleanup_failed');
        expect(failed.error?.message, contains('the stand-in is stuck'));

        // A stand-in that throws still lets the rest of the cleanup run.
        broken = true;
        operator.installNetworkMock(
          const NetworkMockMatch(method: 'GET', path: '/left-over'),
          const NetworkMockResponse(status: 200),
        );
        final thrown = await clear('all');
        expect(thrown.ok, isFalse, reason: route);
        expect(thrown.error?.type, 'simulation_cleanup_failed');
        expect(thrown.error?.message, contains('the stand-in broke'));
        expect(
          operator.hasActiveNetworkMocks,
          isFalse,
          reason: '$route: the rest of the cleanup ran',
        );
      }
    },
  );

  test(
    'a clear that fails twice names both failures',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-media-clear-twice',
          environment: OperatorEnvironment.dev,
        ),
      );
      addTearDown(operator.dispose);
      operator.registerVirtualizationProbe(
        'media',
        (command, operator) => throw StateError('the stand-in broke'),
      );
      operator.addNetworkConditionsListener(
        (conditions) => <String, Object?>{'error': 'the network stayed off'},
      );
      final result = await OperatorFlutterAdapter(operator).execute(
        const ActionCommand(
          type: OperatorActionType.clearSimulation,
          scope: 'all',
        ),
      );
      expect(result.ok, isFalse);
      expect(result.error?.type, 'simulation_cleanup_failed');
      expect(
        result.error?.message,
        allOf(contains('network conditions'), contains('the stand-in broke')),
      );
    },
  );

  test(
    'supply_media is read as the host sends it, and its result never carries the bytes',
    () {
      final bytes = Uint8List.fromList(
        List<int>.generate(300, (index) => index % 256),
      );
      final command = operatorActionCommandFromEnvelopeJson(<String, Object?>{
        'action': <String, Object?>{
          'type': 'supply_media',
          'to': 'microphone',
          'media': <String, Object?>{
            'algorithm': 'sha256',
            'digest': 'abc',
            'relativePath': 'blobs/sha256/abc',
            'mediaType': 'audio/wav',
            'bytes': 300,
          },
          'dataBase64': base64Encode(bytes),
          'startInMs': 1500,
          'deliveryId': 'delivery-1',
        },
      });
      expect(command.type, OperatorActionType.supplyMedia);
      expect(command.to, 'microphone');
      expect(command.media!.bytes, bytes);
      expect(command.media!.mediaId, 'abc');
      expect(command.media!.mediaType, 'audio/wav');
      expect(command.startIn, const Duration(milliseconds: 1500));

      final echoed = jsonEncode(
        operatorActionResultToJson(ActionResult(ok: true, action: command)),
      );
      expect(echoed, isNot(contains(base64Encode(bytes))));
      expect(echoed, isNot(contains('dataBase64')));
      final action = (jsonDecode(echoed) as Map)['action'] as Map;
      expect(action['type'], 'supply_media');
      expect(action['to'], 'microphone');
      expect(action['media'], <String, Object?>{
        'mediaId': 'abc',
        'mediaType': 'audio/wav',
        'bytes': 300,
      });
      expect(action['startInMs'], 1500);

      final back = operatorActionCommandFromJson(<String, Object?>{
        'type': 'supply_media',
        'to': 'camera',
        'media': null,
      });
      expect(back.media, isNull);
      expect(back.startIn, isNull);
    },
  );

  test('a malformed supply_media is refused before it reaches the app', () {
    final file = <String, Object?>{
      'algorithm': 'sha256',
      'digest': 'abc',
      'relativePath': 'blobs/sha256/abc',
      'mediaType': 'audio/wav',
      'bytes': 3,
    };
    final cases = <String, Map<String, Object?>>{
      'another device': <String, Object?>{'to': 'speaker', 'media': null},
      'a delay for the camera': <String, Object?>{
        'to': 'camera',
        'media': null,
        'startInMs': 10,
      },
      'a delay over an hour': <String, Object?>{
        'to': 'microphone',
        'media': null,
        'startInMs': 3600001,
      },
      'a negative delay': <String, Object?>{
        'to': 'microphone',
        'media': null,
        'startInMs': -1,
      },
      'part of a millisecond': <String, Object?>{
        'to': 'microphone',
        'media': null,
        'startInMs': 1.5,
      },
      'a file without its bytes': <String, Object?>{
        'to': 'microphone',
        'media': file,
      },
      'bytes that are not base64': <String, Object?>{
        'to': 'microphone',
        'media': file,
        'dataBase64': '***',
      },
      'a file without its name': <String, Object?>{
        'to': 'microphone',
        'media': <String, Object?>{'mediaType': 'audio/wav'},
        'dataBase64': 'AQID',
      },
    };
    for (final entry in cases.entries) {
      expect(
        () => operatorActionCommandFromJson(<String, Object?>{
          'type': 'supply_media',
          ...entry.value,
        }),
        throwsFormatException,
        reason: entry.key,
      );
    }
    expect(
      operatorActionCommandFromJson(<String, Object?>{
        'type': 'supply_media',
        'to': 'microphone',
        'media': null,
        'startInMs': 3600000,
      }).startIn,
      const Duration(hours: 1),
      reason: 'an hour is the longest delay',
    );
  });

  test('Firebase mocks match generated collection paths flexibly', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-firebase-flexible-mock-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final adapter = OperatorFlutterAdapter(operator);

    final result = await adapter.execute(
      const ActionCommand(
        type: OperatorActionType.installFirebaseMock,
        firebase: FirebaseMockMatch(
          service: 'firestore',
          operation: 'queryGet',
          pathContains: 'mappings',
          pathPattern: r'organizations/.+/facilities/.+/mappings$',
          parameters: <String, Object?>{'whereUid': 'operator-mock-user'},
        ),
        firebaseResponse: FirebaseMockResponse(
          value: <String, Object?>{
            'docs': <Object?>[
              <String, Object?>{
                'id': 'operator-mock-user',
                'organizationId': 'internalTestDB',
                'facilityId': 'facility1',
              },
            ],
          },
        ),
      ),
    );

    expect(result.ok, isTrue);
    final mock = operator.findFirebaseMock(
      const FirebaseMockMatch(
        service: 'firestore',
        operation: 'queryGet',
        path: 'organizations/internalTestDB/facilities/facility1/mappings',
        parameters: <String, Object?>{'whereUid': 'operator-mock-user'},
      ),
    );
    expect(mock?.value, isA<Map<String, Object?>>());
    expect(mock?.value, containsPair('docs', isA<List<Object?>>()));
    expect(
      operator
          .findFirebaseMock(
            const FirebaseMockMatch(
              service: 'firestore',
              operation: 'queryGet',
              path: 'organizations/internalTestDB/facilities/facility1/users',
              parameters: <String, Object?>{'whereUid': 'operator-mock-user'},
            ),
          )
          ?.value,
      isNull,
    );

    operator.dispose();
  });

  test('blocks Firebase and network mocks in production adapter', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-production-simulation-block-test',
        environment: OperatorEnvironment.production,
      ),
    );
    final adapter = OperatorFlutterAdapter(operator);

    final firebase = await adapter.execute(
      const ActionCommand(
        type: OperatorActionType.installFirebaseMock,
        firebase: FirebaseMockMatch(
          service: 'functions',
          operation: 'call',
          name: 'checkout',
        ),
        firebaseResponse: FirebaseMockResponse(value: <String, Object?>{}),
      ),
    );
    final network = await adapter.execute(
      const ActionCommand(
        type: OperatorActionType.installNetworkMock,
        match: NetworkMockMatch(method: 'GET', path: '/flags'),
        response: NetworkMockResponse(status: 200),
      ),
    );
    final firebaseProbe = await adapter.execute(
      const ActionCommand(type: OperatorActionType.probeFirebaseVirtualization),
    );

    expect(firebase.ok, isFalse);
    expect(firebase.error?.type, 'simulation_blocked');
    expect(network.ok, isFalse);
    expect(network.error?.type, 'simulation_blocked');
    expect(firebaseProbe.ok, isFalse);
    expect(firebaseProbe.error?.type, 'simulation_blocked');

    operator.dispose();
  });

  test(
    'method-only HEAD network mocks do not intercept connectivity probes',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-network-mock-safety-test',
          environment: OperatorEnvironment.dev,
        ),
      );

      operator.installNetworkMock(
        const NetworkMockMatch(method: 'HEAD'),
        const NetworkMockResponse(status: 204),
      );

      expect(
        operator.findNetworkMock(
          networkRequest(
            method: 'HEAD',
            url: 'https://connectivitycheck.gstatic.com/generate_204',
            path: '/generate_204',
          ),
        ),
        isNull,
      );
      expect(
        operator.findNetworkMock(
          networkRequest(
            method: 'HEAD',
            url: 'https://api.example.test/health',
            path: '/health',
          ),
        ),
        isNull,
      );

      operator.installNetworkMock(
        const NetworkMockMatch(method: 'HEAD', path: '/health'),
        const NetworkMockResponse(status: 204),
      );
      expect(
        operator
            .findNetworkMock(
              networkRequest(
                method: 'HEAD',
                url: 'https://api.example.test/health',
                path: '/health',
              ),
            )
            ?.status,
        204,
      );

      operator.dispose();
    },
  );

  test('network mocks support explicit dynamic URL matching', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-network-mock-dynamic-match-test',
        environment: OperatorEnvironment.dev,
      ),
    );

    operator.installNetworkMock(
      const NetworkMockMatch(
        method: 'GET',
        pathContains: 'documentation_summary.json.br',
        query: <String, Object?>{'alt': 'media'},
      ),
      const NetworkMockResponse(
        status: 200,
        body: <String, Object?>{'ok': true},
      ),
    );
    operator.installNetworkMock(
      const NetworkMockMatch(
        method: 'GET',
        urlPattern:
            r'firebasestorage\.googleapis\.com/.+documentation_records\.json\.br',
      ),
      const NetworkMockResponse(status: 202),
    );

    expect(
      operator
          .findNetworkMock(
            networkRequest(
              method: 'GET',
              url:
                  'https://firebasestorage.googleapis.com/v0/b/app/o/brotli_files%2Fdocumentation_summary.json.br?alt=media&token=dynamic',
              path: '/v0/b/app/o/brotli_files%2Fdocumentation_summary.json.br',
              query: const <String, Object?>{
                'alt': 'media',
                'token': 'dynamic',
              },
            ),
          )
          ?.status,
      200,
    );
    expect(
      operator
          .findNetworkMock(
            networkRequest(
              method: 'GET',
              url:
                  'https://firebasestorage.googleapis.com/v0/b/app/o/brotli_files%2Fdocumentation_records.json.br?alt=media&token=dynamic',
              path: '/v0/b/app/o/brotli_files%2Fdocumentation_records.json.br',
              query: const <String, Object?>{
                'alt': 'media',
                'token': 'dynamic',
              },
            ),
          )
          ?.status,
      202,
    );
    expect(
      operator.findNetworkMock(
        networkRequest(
          method: 'GET',
          url: 'https://api.example.test/products',
          path: '/products',
        ),
      ),
      isNull,
    );

    operator.dispose();
  });

  test('network mocks prefer specificity then newest matching setup', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-network-mock-precedence-test',
        environment: OperatorEnvironment.dev,
      ),
    );

    const request = NetworkRequest(
      method: 'HEAD',
      url: 'https://connectivitycheck.gstatic.com/generate_204',
      path: '/generate_204',
    );
    operator.installNetworkMock(
      const NetworkMockMatch(method: 'HEAD', path: '/generate_204'),
      const NetworkMockResponse(status: 204),
    );
    operator.installNetworkMock(
      const NetworkMockMatch(method: 'HEAD', path: '/generate_204'),
      const NetworkMockResponse(
        status: 209,
        headers: <String, String>{'x-operator-probe': 'latest'},
      ),
    );
    expect(operator.findNetworkMock(request)?.status, 209);
    expect(
      operator.findNetworkMock(request)?.headers['x-operator-probe'],
      'latest',
    );

    operator.installNetworkMock(
      const NetworkMockMatch(method: 'HEAD', pathContains: 'generate'),
      const NetworkMockResponse(status: 210),
    );
    expect(
      operator.findNetworkMock(request)?.status,
      209,
      reason: 'a newer broad mock must not shadow an older exact-path mock',
    );

    operator.dispose();
  });

  test(
    'mock resolution exposes selected network and Firebase mock metadata',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-mock-resolution-test',
          environment: OperatorEnvironment.dev,
        ),
      );

      final broadNetworkId = operator.installNetworkMock(
        const NetworkMockMatch(method: 'GET', pathContains: '/api'),
        const NetworkMockResponse(status: 299),
      );
      final exactNetworkId = operator.installNetworkMock(
        const NetworkMockMatch(method: 'GET', path: '/api/users/1'),
        const NetworkMockResponse(status: 200),
      );
      final networkResolution = operator.resolveNetworkMock(
        networkRequest(
          method: 'GET',
          url: 'https://example.test/api/users/1',
          path: '/api/users/1',
        ),
      );
      expect(networkResolution.matched, isTrue);
      expect(networkResolution.mockId, exactNetworkId);
      expect(networkResolution.mockId, isNot(broadNetworkId));
      expect(networkResolution.response?.status, 200);
      expect(networkResolution.score, greaterThan(0));
      expect(networkResolution.candidateCount, 2);
      final networkMiss = operator.resolveNetworkMock(
        networkRequest(
          method: 'GET',
          url: 'https://example.test/public',
          path: '/public',
        ),
      );
      expect(networkMiss.matched, isFalse);
      expect(networkMiss.candidateCount, 2);

      final broadFirebaseId = operator.installFirebaseMock(
        const FirebaseMockMatch(
          service: 'firestore',
          operation: 'queryGet',
          pathContains: 'mappings',
        ),
        const FirebaseMockResponse(
          value: <String, Object?>{'docs': <Object>[]},
        ),
      );
      final exactFirebaseId = operator.installFirebaseMock(
        const FirebaseMockMatch(
          service: 'firestore',
          operation: 'queryGet',
          path: 'facilities/facility1/mappings/operator-mock-user',
        ),
        const FirebaseMockResponse(
          value: <String, Object?>{
            'docs': <Object>[
              <String, Object?>{'id': 'operator-mock-user'},
            ],
          },
        ),
      );
      final firebaseResolution = operator.resolveFirebaseMock(
        const FirebaseMockMatch(
          service: 'firestore',
          operation: 'queryGet',
          path: 'facilities/facility1/mappings/operator-mock-user',
        ),
      );
      expect(firebaseResolution.matched, isTrue);
      expect(firebaseResolution.mockId, exactFirebaseId);
      expect(firebaseResolution.mockId, isNot(broadFirebaseId));
      expect(
        (firebaseResolution.response?.value as Map<String, Object?>)['docs'],
        isNotEmpty,
      );
      expect(firebaseResolution.score, greaterThan(0));
      expect(firebaseResolution.candidateCount, 2);

      final newerTieFirebaseId = operator.installFirebaseMock(
        const FirebaseMockMatch(
          service: 'firestore',
          operation: 'queryGet',
          path: 'facilities/facility1/mappings/operator-mock-user',
        ),
        const FirebaseMockResponse(
          value: <String, Object?>{
            'docs': <Object>[
              <String, Object?>{'id': 'newest'},
            ],
          },
        ),
      );
      final tieResolution = operator.resolveFirebaseMock(
        const FirebaseMockMatch(
          service: 'firestore',
          operation: 'queryGet',
          path: 'facilities/facility1/mappings/operator-mock-user',
        ),
      );
      expect(tieResolution.mockId, newerTieFirebaseId);
      expect(tieResolution.candidateCount, 3);
      final firebaseMiss = operator.resolveFirebaseMock(
        const FirebaseMockMatch(
          service: 'firestore',
          operation: 'queryGet',
          path: 'facilities/facility1/residents',
        ),
      );
      expect(firebaseMiss.matched, isFalse);
      expect(firebaseMiss.candidateCount, 3);

      operator.dispose();
    },
  );

  test(
    'mock availability listeners track active network and Firebase mocks',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-mock-availability-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final states = <String>[];
      final dispose = operator.addMockAvailabilityListener(() {
        states.add(
          'network=${operator.hasActiveNetworkMocks};firebase=${operator.hasActiveFirebaseMocks}',
        );
      });

      expect(states, <String>['network=false;firebase=false']);
      operator.installNetworkMock(
        const NetworkMockMatch(method: 'GET', path: '/items'),
        const NetworkMockResponse(status: 200, body: <String, Object?>{}),
      );
      var snapshot = await operator.getSnapshot();
      expect(snapshot.capabilities.virtualization['networkMocks'], isTrue);
      expect(
        snapshot.capabilities.virtualization['networkMocks.active'],
        isTrue,
      );
      expect(
        snapshot.capabilities.virtualization['network.activeMocks'],
        isTrue,
      );
      expect(
        snapshot.capabilities.virtualization['firebaseMocks.active'],
        isFalse,
      );
      operator.installFirebaseMock(
        const FirebaseMockMatch(service: 'firestore', operation: 'queryGet'),
        const FirebaseMockResponse(
          value: <String, Object?>{'docs': <Object>[]},
        ),
      );
      snapshot = await operator.getSnapshot();
      expect(
        snapshot.capabilities.virtualization['firebaseMocks.active'],
        isTrue,
      );
      expect(
        snapshot.capabilities.virtualization['firebase.activeMocks'],
        isTrue,
      );
      operator.clearSimulation('network_mocks');
      snapshot = await operator.getSnapshot();
      expect(
        snapshot.capabilities.virtualization['networkMocks.active'],
        isFalse,
      );
      expect(
        snapshot.capabilities.virtualization['firebaseMocks.active'],
        isTrue,
      );
      operator.clearSimulation('firebase_mocks');
      snapshot = await operator.getSnapshot();
      expect(
        snapshot.capabilities.virtualization['networkMocks.active'],
        isFalse,
      );
      expect(
        snapshot.capabilities.virtualization['firebaseMocks.active'],
        isFalse,
      );
      dispose();
      operator.installNetworkMock(
        const NetworkMockMatch(method: 'GET', path: '/after-dispose'),
        const NetworkMockResponse(status: 200, body: <String, Object?>{}),
      );

      expect(states, <String>[
        'network=false;firebase=false',
        'network=true;firebase=false',
        'network=true;firebase=true',
        'network=false;firebase=true',
        'network=false;firebase=false',
      ]);

      operator.dispose();
    },
  );

  test(
    'runtime events stream route/ui/forms/state/network/storage/log/error/dialog/visual/snapshot',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-event-stream-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final events = <OperatorRuntimeEvent>[];
      final subscription = operator.events.listen(events.add);

      operator.captureRoute(path: '/stream', name: 'stream');
      operator.captureUiTree(
        const UiTree(
          rootId: 'stream-root',
          viewport: ViewportSnapshot(width: 390, height: 844),
          elements: <UiElement>[
            UiElement(
              id: 'email',
              role: OperatorUiRole.input,
              label: 'Email',
              value: 'qa@example.test',
              enabled: true,
              visible: true,
              actions: <String>['type'],
              confidence: 1,
            ),
          ],
        ),
      );
      operator.captureStateChange(
        source: OperatorStateSource.bloc,
        name: 'AuthState',
        value: <String, Object?>{'status': 'editing'},
      );
      operator.captureNetworkResponse(
        id: 'net_stream',
        request: networkRequest(
          method: 'GET',
          url: '/profile',
          path: '/profile',
        ),
        status: 200,
        ok: true,
        body: <String, Object?>{'ok': true},
      );
      operator.storageAdapters.captureSharedPreferences(
        key: 'lastRoute',
        value: '/stream',
      );
      operator.captureDialog(
        const DialogState(
          id: 'toast',
          role: 'toast',
          message: 'Saved',
          buttons: <String>[],
          visible: true,
          confidence: 1,
        ),
      );
      operator.captureVisualFrame(
        const VisualFrame(
          id: 'frame',
          format: 'metadata',
          width: 390,
          height: 844,
          source: 'manual',
          redacted: false,
          metadataOnly: true,
        ),
      );
      operator.captureError(
        type: 'StreamTestError',
        message: 'Handled stream test error',
        source: 'test',
      );

      await pumpEventQueue(times: 20);
      await subscription.cancel();
      operator.dispose();

      final types = events.map((event) => event.type).toList();
      expect(types, contains(OperatorRuntimeEventType.route));
      expect(types, contains(OperatorRuntimeEventType.ui));
      expect(types, contains(OperatorRuntimeEventType.forms));
      expect(types, contains(OperatorRuntimeEventType.state));
      expect(types, contains(OperatorRuntimeEventType.network));
      expect(types, contains(OperatorRuntimeEventType.storage));
      expect(types, contains(OperatorRuntimeEventType.dialog));
      expect(types, contains(OperatorRuntimeEventType.visual));
      expect(types, contains(OperatorRuntimeEventType.error));
      expect(types, contains(OperatorRuntimeEventType.log));
      expect(types, contains(OperatorRuntimeEventType.snapshot));
      expect(
        events
            .where((event) => event.type == OperatorRuntimeEventType.snapshot)
            .every((event) => event.snapshotId != null),
        isTrue,
      );
      expect(
        events.map((event) => event.sequence).toList(),
        orderedEquals(events.map((event) => event.sequence).toList()..sort()),
      );
    },
  );

  test('snapshot infers modal sheets from visible filter-style UI', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-inferred-modal-test',
        environment: OperatorEnvironment.dev,
      ),
    );

    operator.captureUiTree(
      const UiTree(
        rootId: 'filter-sheet-root',
        viewport: ViewportSnapshot(width: 393, height: 852),
        elements: <UiElement>[
          UiElement(
            id: 'close-filter',
            role: OperatorUiRole.button,
            label: 'Schließen',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'filter-title',
            role: OperatorUiRole.text,
            label:
                'Filter Wähle die Dokumentationskategorien aus, die du sehen möchtest.',
            enabled: true,
            visible: true,
            actions: <String>[],
            confidence: 1,
          ),
          UiElement(
            id: 'option-planned',
            role: OperatorUiRole.button,
            label: 'geplante Maßnahmen',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'option-selected-state',
            role: OperatorUiRole.button,
            label: 'Not selected',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'option-extra',
            role: OperatorUiRole.button,
            label: 'zusätzliche Maßnahmen',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'option-all',
            role: OperatorUiRole.button,
            label: 'zeige alle Maßnahmen',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'option-medication',
            role: OperatorUiRole.button,
            label: 'Medikation',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'option-pain',
            role: OperatorUiRole.button,
            label: 'Schmerzbeurteilung',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'option-urine',
            role: OperatorUiRole.button,
            label: 'Urin',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'option-drink',
            role: OperatorUiRole.button,
            label: 'Trinkprotokoll',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'clear-filter',
            role: OperatorUiRole.button,
            label: 'Filter löschen',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'apply-filter',
            role: OperatorUiRole.button,
            label: 'Anwenden',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
        ],
      ),
    );

    final snapshot = await operator.getSnapshot();

    expect(snapshot.dialogs, hasLength(1));
    expect(snapshot.dialogs.single.role, 'modal');
    expect(snapshot.dialogs.single.title, startsWith('Filter'));
    expect(snapshot.dialogs.single.buttons, contains('Schließen'));
    expect(snapshot.dialogs.single.buttons, contains('Filter löschen'));
    expect(snapshot.dialogs.single.buttons, contains('Anwenden'));
    expect(snapshot.dialogs.single.buttons, isNot(contains('Not selected')));
    operator.dispose();
  });

  test('snapshot does not infer a modal from page filter chrome', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-filter-page-not-modal-test',
        environment: OperatorEnvironment.dev,
      ),
    );

    operator.captureUiTree(
      const UiTree(
        rootId: 'resident-record-root',
        viewport: ViewportSnapshot(width: 393, height: 852),
        elements: <UiElement>[
          UiElement(
            id: 'filter-button',
            role: OperatorUiRole.button,
            label: 'Filter',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'close-page',
            role: OperatorUiRole.button,
            label: 'Close',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'task-card',
            role: OperatorUiRole.button,
            label: 'Hr. Adolph, Günter Kontrollgang 23:00',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'complete-task',
            role: OperatorUiRole.checkbox,
            label: 'Mark as complete',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 1,
          ),
          UiElement(
            id: 'resident-title',
            role: OperatorUiRole.text,
            label: 'Hr. Adolph, Günter',
            enabled: true,
            visible: true,
            actions: <String>[],
            confidence: 1,
          ),
        ],
      ),
    );

    final snapshot = await operator.getSnapshot();

    expect(snapshot.dialogs, isEmpty);
    operator.dispose();
  });

  test('production secure storage remains metadata only', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-prod-storage-test',
        environment: OperatorEnvironment.production,
      ),
    );

    operator.storageAdapters.captureSecureStorage(
      key: 'staging-access-key',
      value: 'prod-secret-value',
    );

    final snapshot = await operator.getSnapshot();
    final entry = snapshot.storage!.entries.single;
    expect(entry.metadataOnly, isTrue);
    expect(entry.value, isNull);

    final blocked = await OperatorFlutterAdapter(operator).execute(
      const ActionCommand(
        type: OperatorActionType.injectStorage,
        area: 'sharedPreferences',
        key: 'feature:checkout',
        value: <String, Object?>{'enabled': true},
      ),
    );
    expect(blocked.ok, isFalse);
    expect(blocked.error?.type, 'simulation_blocked');
    operator.dispose();
  });

  test(
    'storage installation never replaces the application storage APIs',
    () async {
      final previousAsync = SharedPreferencesAsyncPlatform.instance;
      final previousLegacy = SharedPreferencesStorePlatform.instance;
      final asyncStore = _FakeSharedPreferencesAsyncPlatform();
      final legacyStore = _FakeSharedPreferencesStorePlatform();
      SharedPreferencesAsyncPlatform.instance = asyncStore;
      SharedPreferencesStorePlatform.instance = legacyStore;
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'storage-no-watcher',
          environment: OperatorEnvironment.dev,
        ),
      );
      final dispose = OperatorSharedPreferencesReader.install(operator);
      try {
        expect(SharedPreferencesAsyncPlatform.instance, same(asyncStore));
        expect(SharedPreferencesStorePlatform.instance, same(legacyStore));
        await Future<void>.delayed(Duration.zero);
        expect(asyncStore.readCount, 0);
        expect(legacyStore.readCount, 0);
      } finally {
        dispose();
        operator.dispose();
        SharedPreferencesAsyncPlatform.instance = previousAsync;
        SharedPreferencesStorePlatform.instance = previousLegacy;
      }
    },
  );

  test(
    'storage snapshot reads direct backend changes and deletions on request',
    () async {
      final previousAsync = SharedPreferencesAsyncPlatform.instance;
      final previousLegacy = SharedPreferencesStorePlatform.instance;
      final asyncStore = _FakeSharedPreferencesAsyncPlatform();
      final legacyStore = _FakeSharedPreferencesStorePlatform.withData(
        <String, Object>{'flutter.GetStorage': '{"isDarkMode":false}'},
      );
      SharedPreferencesAsyncPlatform.instance = asyncStore;
      SharedPreferencesStorePlatform.instance = legacyStore;
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'storage-fresh-reads',
          environment: OperatorEnvironment.dev,
        ),
      );
      final dispose = OperatorSharedPreferencesReader.install(operator);
      try {
        await Future<void>.delayed(Duration.zero);
        var snapshot = await operator.getSnapshot(refreshVisual: false);
        expect(
          snapshot.storage!.entries
              .singleWhere((e) => e.key == 'flutter.GetStorage')
              .value,
          <String, Object?>{'isDarkMode': false},
        );

        // Simulate GetStorage/another isolate writing without the intercepted API.
        legacyStore._values['flutter.GetStorage'] = '{"isDarkMode":true}';
        asyncStore._values['counter'] = 7;
        snapshot = await operator.getSnapshot(refreshVisual: false);
        expect(
          snapshot.storage!.entries
              .singleWhere((e) => e.key == 'flutter.GetStorage')
              .value,
          <String, Object?>{'isDarkMode': true},
        );
        expect(
          snapshot.storage!.entries
              .singleWhere((e) => e.key == 'counter')
              .value,
          7,
        );

        legacyStore._values.clear();
        asyncStore._values.clear();
        snapshot = await operator.getSnapshot(refreshVisual: false);
        expect(snapshot.storage?.entries ?? <StorageEntrySnapshot>[], isEmpty);
        legacyStore._values['flutter.GetStorage'] = '{"isDarkMode":true}';
        await operator.getSnapshot(refreshVisual: false);
        legacyStore.failRead = true;
        snapshot = await operator.getSnapshot(refreshVisual: false);
        expect(snapshot.storage?.entries ?? <StorageEntrySnapshot>[], isEmpty,
            reason: 'a failed backend read must not resurrect the previous value');
        expect(snapshot.logs.any((log) => log.message == 'storage provider failed'), isTrue);
        final reads = legacyStore.readCount;
        dispose();
        await operator.getSnapshot(refreshVisual: false);
        expect(legacyStore.readCount, reads, reason: 'disposing removes the on-request reader');
      } finally {
        dispose();
        operator.dispose();
        SharedPreferencesAsyncPlatform.instance = previousAsync;
        SharedPreferencesStorePlatform.instance = previousLegacy;
      }
    },
  );

  test('OperatorAppHost reads shared_preferences on request', () async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    final store = _FakeSharedPreferencesAsyncPlatform();
    SharedPreferencesAsyncPlatform.instance = store;
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-shared-preferences-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final dispose = OperatorSharedPreferencesReader.install(operator);

    try {
      final preferences = SharedPreferencesAsync();
      await preferences.setString(
        'foodly.checkoutDraft',
        '{"address":"14 Market Street"}',
      );
      await preferences.setString(
        'foodly.sessionToken',
        'foodly-access-token-should-not-leak',
      );
      await preferences.setInt('foodly.cartCount', 2);

      var snapshot = await operator.getSnapshot();
      expect(
        snapshot.storage!.entries
            .singleWhere((entry) => entry.key == 'foodly.checkoutDraft')
            .value,
        containsPair('address', '[REDACTED]'),
      );
      expect(
        snapshot.storage!.entries
            .singleWhere((entry) => entry.key == 'foodly.cartCount')
            .value,
        2,
      );
      final tokenEntry = snapshot.storage!.entries.singleWhere(
        (entry) => entry.key == 'foodly.sessionToken',
      );
      expect(tokenEntry.metadataOnly, isTrue);
      expect(tokenEntry.redacted, isTrue);
      expect(tokenEntry.value, isNull);

      await preferences.clear(allowList: <String>{'foodly.cartCount'});
      snapshot = await operator.getSnapshot();
      expect(
        snapshot.storage!.entries.any(
          (entry) => entry.key == 'foodly.cartCount',
        ),
        isFalse,
      );

      final injected = await OperatorFlutterAdapter(operator).execute(
        const ActionCommand(
          type: OperatorActionType.injectStorage,
          area: 'sharedPreferences',
          key: 'foodly.cachedProducts',
          value: <String, Object?>{
            'items': <Object?>[
              <String, Object?>{'id': 'p_mock', 'name': 'SDK Mocked Juice'},
            ],
          },
        ),
      );
      expect(injected.ok, isTrue);
      expect(
        jsonDecode(await preferences.getString('foodly.cachedProducts') ?? '{}')
            as Map<String, Object?>,
        containsPair('items', isA<List<Object?>>()),
      );

      final cleared = await OperatorFlutterAdapter(operator).execute(
        const ActionCommand(
          type: OperatorActionType.clearStorage,
          area: 'sharedPreferences',
          key: 'foodly.cachedProducts',
        ),
      );
      expect(cleared.ok, isTrue);
      expect(await preferences.getString('foodly.cachedProducts'), isNull);
    } finally {
      dispose();
      operator.dispose();
      SharedPreferencesAsyncPlatform.instance = previous;
    }
  });

  test('OperatorAppHost reads legacy shared_preferences on request', () async {
    final previousAsync = SharedPreferencesAsyncPlatform.instance;
    final previousLegacy = SharedPreferencesStorePlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        _FakeSharedPreferencesAsyncPlatform();
    SharedPreferencesStorePlatform
        .instance = _FakeSharedPreferencesStorePlatform.withData(
      <String, Object>{'flutter.foodly.preloadedLocale': 'de_DE'},
    );
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-legacy-shared-preferences-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final dispose = OperatorSharedPreferencesReader.install(operator);

    try {
      await Future<void>.delayed(Duration.zero);
      final preferences = SharedPreferencesStorePlatform.instance;
      var snapshot = await operator.getSnapshot();
      expect(
        snapshot.storage!.entries
            .singleWhere(
              (entry) => entry.key == 'flutter.foodly.preloadedLocale',
            )
            .value,
        'de_DE',
      );

      await preferences.setValue(
        'String',
        'flutter.foodly.legacyDraft',
        '{"address":"55 Legacy Road"}',
      );
      await preferences.setValue(
        'String',
        'flutter.foodly.sessionToken',
        'legacy-access-token-should-not-leak',
      );
      await preferences.setValue('Int', 'flutter.foodly.legacyCount', 4);

      snapshot = await operator.getSnapshot();
      expect(
        snapshot.storage!.entries
            .singleWhere((entry) => entry.key == 'flutter.foodly.legacyDraft')
            .value,
        containsPair('address', '[REDACTED]'),
      );
      expect(
        snapshot.storage!.entries
            .singleWhere((entry) => entry.key == 'flutter.foodly.legacyCount')
            .value,
        4,
      );
      final tokenEntry = snapshot.storage!.entries.singleWhere(
        (entry) => entry.key == 'flutter.foodly.sessionToken',
      );
      expect(tokenEntry.metadataOnly, isTrue);
      expect(tokenEntry.redacted, isTrue);
      expect(tokenEntry.value, isNull);

      await preferences.clearWithParameters(
        ClearParameters(
          filter: PreferencesFilter(
            prefix: 'flutter.',
            allowList: <String>{'flutter.foodly.legacyCount'},
          ),
        ),
      );
      snapshot = await operator.getSnapshot();
      expect(
        snapshot.storage!.entries.any(
          (entry) => entry.key == 'flutter.foodly.legacyCount',
        ),
        isFalse,
      );
      expect(
        snapshot.storage!.entries.any(
          (entry) => entry.key == 'flutter.foodly.legacyDraft',
        ),
        isTrue,
      );
    } finally {
      dispose();
      operator.dispose();
      SharedPreferencesAsyncPlatform.instance = previousAsync;
      SharedPreferencesStorePlatform.instance = previousLegacy;
    }
  });

  test('policy requires confirmation for sensitive actions', () {
    final policy = OperatorPolicyEngine(
      requireConfirmationFor: <String>['Refund Customer'],
    );
    final decision = policy.evaluate(
      const ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(id: 'refund-button'),
        purpose: 'refund customer',
        risk: 1,
      ),
    );

    expect(decision.decision, OperatorPolicyDecisionType.confirm);
  });

  test('popular state adapters capture common Flutter state options', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-state-adapter-test',
        environment: OperatorEnvironment.dev,
      ),
    );

    final state = operator.stateAdapters;
    state.captureBloc(
      bloc: _InventoryBloc(),
      name: 'InventoryBlocState',
      state: <String, Object?>{
        'items': <Object>[
          <String, Object?>{'sku': 'RICE', 'quantity': 2},
        ],
      },
    );
    state.captureCubit(
      cubit: _InventoryCubit(),
      name: 'InventoryCubitState',
      state: <String, Object?>{'selectedSku': 'RICE'},
    );
    state.captureSetState(
      widget: 'InventoryScreen',
      state: <String, Object?>{'filter': 'low-stock'},
    );
    state.captureChangeNotifier(
      notifier: _InventoryNotifier(),
      name: 'InventoryNotifier',
      state: <String, Object?>{'dirty': true},
    );
    state.captureValueNotifier(
      notifier: _InventoryValueNotifier(),
      name: 'SelectedQuantity',
      value: 2,
    );
    state.captureProvider(
      provider: 'inventoryProvider',
      value: <String, Object?>{'count': 1},
    );
    state.captureRiverpod(
      provider: 'inventoryRiverpodProvider',
      previous: <String, Object?>{'count': 0},
      value: <String, Object?>{'count': 1},
    );
    state.captureGetX(
      controller: _InventoryGetXController(),
      name: 'InventoryGetXController',
      state: <String, Object?>{'ready': true},
    );
    state.captureRedux(
      store: 'InventoryReduxStore',
      action: 'RefreshInventory',
      state: <String, Object?>{'loaded': true},
    );
    state.captureMobX(
      store: _InventoryMobXStore(),
      name: 'InventoryMobXStore',
      state: <String, Object?>{'computedCount': 1},
    );
    state.captureInheritedWidget(
      widget: 'InventoryScope',
      value: <String, Object?>{'warehouseId': 'lagos-1'},
    );

    final snapshot = await operator.getSnapshot();
    final storesByName = <String, StateStoreSnapshot>{
      for (final store in snapshot.state) store.name: store,
    };

    expect(
      storesByName['InventoryBlocState']?.source,
      OperatorStateSource.bloc,
    );
    expect(
      storesByName['InventoryCubitState']?.source,
      OperatorStateSource.bloc,
    );
    expect(
      storesByName['InventoryScreen']?.source,
      OperatorStateSource.setState,
    );
    expect(
      storesByName['InventoryNotifier']?.source,
      OperatorStateSource.changeNotifier,
    );
    expect(
      storesByName['SelectedQuantity']?.source,
      OperatorStateSource.valueNotifier,
    );
    expect(
      storesByName['inventoryProvider']?.source,
      OperatorStateSource.provider,
    );
    expect(
      storesByName['inventoryRiverpodProvider']?.source,
      OperatorStateSource.riverpod,
    );
    expect(
      storesByName['InventoryGetXController']?.source,
      OperatorStateSource.getx,
    );
    expect(
      storesByName['InventoryReduxStore']?.source,
      OperatorStateSource.redux,
    );
    expect(
      storesByName['InventoryMobXStore']?.source,
      OperatorStateSource.mobx,
    );
    expect(
      storesByName['InventoryScope']?.source,
      OperatorStateSource.inheritedWidget,
    );
    expect(
      (storesByName['InventoryReduxStore']?.value as Map<String, Object?>),
      containsPair('action', 'RefreshInventory'),
    );

    operator.dispose();
  });

  test('state store identity keeps source collisions separate', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-state-identity-test',
        environment: OperatorEnvironment.dev,
      ),
    );

    operator.captureStateChange(
      source: OperatorStateSource.bloc,
      name: 'InventoryState',
      value: <String, Object?>{'source': 'bloc', 'count': 1},
    );
    operator.captureStateChange(
      source: OperatorStateSource.provider,
      name: 'InventoryState',
      value: <String, Object?>{'source': 'provider', 'count': 2},
    );
    operator.captureStateChange(
      source: OperatorStateSource.bloc,
      name: 'InventoryState',
      value: <String, Object?>{'source': 'bloc', 'count': 3},
    );

    final snapshot = await operator.getSnapshot();
    final inventoryStores =
        snapshot.state
            .where((store) => store.name == 'InventoryState')
            .toList();

    expect(inventoryStores, hasLength(2));
    expect(
      inventoryStores
          .singleWhere((store) => store.source == OperatorStateSource.bloc)
          .value,
      containsPair('count', 3),
    );
    expect(
      inventoryStores
          .singleWhere((store) => store.source == OperatorStateSource.provider)
          .value,
      containsPair('count', 2),
    );

    operator.dispose();
  });

  test('state provider transient failures reuse last good state', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-state-provider-transient-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    var failDuringTabTransition = false;
    operator.addStateProvider(() {
      if (failDuringTabTransition) {
        throw StateError(
          "'package:flutter/src/material/tabs.dart': Failed assertion: "
          "line 823 pos 12: '!controller.indexIsChanging': is not true.",
        );
      }
      return const <StateStoreSnapshot>[
        StateStoreSnapshot(
          source: OperatorStateSource.inferred,
          name: 'TabControllerState',
          value: <String, Object?>{'index': 1, 'length': 2},
          confidence: 0.8,
          redacted: false,
        ),
      ];
    });

    final first = await operator.getSnapshot();
    failDuringTabTransition = true;
    final second = await operator.getSnapshot();
    for (var index = 0; index < 4; index++) {
      await operator.getSnapshot();
    }
    final latest = await operator.getSnapshot();

    final firstStore = first.state.singleWhere(
      (store) => store.name == 'TabControllerState',
    );
    final secondStore = second.state.singleWhere(
      (store) => store.name == 'TabControllerState',
    );
    final logs = latest.logs.where(
      (log) =>
          log.message ==
              'state provider temporarily unavailable; using last observation' ||
          log.message == 'state provider failed',
    );

    expect(firstStore.value, containsPair('index', 1));
    expect(secondStore.value, containsPair('index', 1));
    expect(latest.errors, isEmpty);
    expect(
      logs.where((log) => log.message == 'state provider failed'),
      isEmpty,
    );
    expect(
      logs.every((log) => log.source == OperatorLogSource.operatorRuntime),
      isTrue,
    );
    expect(logs.every((log) => log.level == 'debug'), isTrue);
    expect(logs.length, lessThan(7));

    operator.dispose();
  });

  test(
    'popular routing adapters capture common Flutter routing options',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-router-adapter-test',
          environment: OperatorEnvironment.dev,
        ),
      );

      operator.routerAdapter.captureNavigatorRoute(
        name: 'inventory',
        path: '/inventory',
        screenClass: 'InventoryPage',
      );
      expect(
        (await operator.getSnapshot()).route.current.screenClass,
        'InventoryPage',
      );

      operator.routerAdapter.captureRouterDelegate(
        location: '/inventory/router',
        name: 'inventoryRouter',
      );
      expect(
        (await operator.getSnapshot()).route.current.screenClass,
        'RouterDelegate',
      );

      operator.routerAdapter.captureGoRouterLocation(
        location: '/inventory/go',
        name: 'inventoryGo',
      );
      expect(
        (await operator.getSnapshot()).route.current.screenClass,
        'go_router',
      );

      operator.routerAdapter.captureAutoRoute(
        routeName: 'InventoryAutoRoute',
        path: '/inventory/auto',
        pageClass: 'InventoryAutoPage',
      );
      expect(
        (await operator.getSnapshot()).route.current.screenClass,
        'InventoryAutoPage',
      );

      operator.routerAdapter.captureBeamer(
        location: '/inventory/beamer',
        beamLocation: 'InventoryBeamLocation',
      );
      expect(
        (await operator.getSnapshot()).route.current.screenClass,
        'beamer',
      );

      operator.routerAdapter.captureGetXRoute(
        route: '/inventory/getx',
        name: 'InventoryGetXRoute',
      );
      expect((await operator.getSnapshot()).route.current.screenClass, 'getx');

      operator.routerAdapter.captureNavigatorStack(const <RouteEntry>[
        RouteEntry(name: 'home', path: '/'),
        RouteEntry(name: 'inventory', path: '/inventory'),
        RouteEntry(
          name: 'inventoryDetail',
          path: '/inventory/detail',
          screenClass: 'InventoryDetailPage',
          params: <String, Object?>{'sku': 'RICE'},
        ),
      ]);

      final snapshot = await operator.getSnapshot();
      expect(snapshot.route.current.path, '/inventory/detail');
      expect(snapshot.route.previous?.path, '/inventory/getx');
      expect(
        snapshot.route.stack.map((route) => route.path),
        containsAll(<String>['/', '/inventory', '/inventory/detail']),
      );

      operator.dispose();
    },
  );

  testWidgets(
    'OperatorAppHost automatically indexes common and custom Flutter state',
    (tester) async {
      late OperatorApp operatorApp;
      final listenable = ValueNotifier<int>(7);
      final notifier = _InventoryChangeNotifier();
      final textController = TextEditingController(text: 'demo-password-value');
      final providerModel = _InventoryProviderModel(count: 3);
      final riverpodModel = _InventoryRiverpodModel(filter: 'cold-drinks');
      final getxController = _InventoryGetXControllerState(total: 9);

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-auto-state-test',
            environment: OperatorEnvironment.dev,
          ),
          stateProbes: <OperatorStateProbe>[
            OperatorStateProbe.provider(
              name: 'ProviderInventoryModel',
              read: () => providerModel,
            ),
            OperatorStateProbe.riverpod(
              name: 'RiverpodInventoryProvider',
              read: () => riverpodModel,
            ),
            OperatorStateProbe.getx(
              name: 'GetXInventoryController',
              read: () => getxController,
            ),
          ],
          onReady: (app) => operatorApp = app,
          child: _FakeInheritedProvider(
            value: providerModel,
            child: _FakeRiverpodProviderScope(
              value: riverpodModel,
              child: _FakeGetXControllerWidget(
                controller: getxController,
                child: _AutomaticStateHarness(
                  listenable: listenable,
                  notifier: notifier,
                  textController: textController,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Increment 0'));
      await tester.pump();

      final snapshot = await operatorApp.operator.getSnapshot();
      final storesByName = <String, StateStoreSnapshot>{
        for (final store in snapshot.state) store.name: store,
      };

      expect(
        storesByName['FlutterWidgetTree']?.source,
        OperatorStateSource.inferred,
      );
      expect(
        storesByName['FlutterStatefulWidgets']?.source,
        OperatorStateSource.setState,
      );
      expect(
        storesByName['FlutterValueListenables']?.source,
        OperatorStateSource.valueNotifier,
      );
      expect(
        storesByName['FlutterChangeNotifiers']?.source,
        OperatorStateSource.changeNotifier,
      );
      expect(
        storesByName['FlutterProviderTree']?.source,
        OperatorStateSource.provider,
      );
      expect(
        storesByName['FlutterRiverpodTree']?.source,
        OperatorStateSource.riverpod,
      );
      expect(storesByName['FlutterGetXTree']?.source, OperatorStateSource.getx);
      expect(
        storesByName['FlutterCustomState']?.source,
        OperatorStateSource.custom,
      );
      expect(
        storesByName['FlutterInheritedWidgets']?.source,
        OperatorStateSource.inheritedWidget,
      );
      expect(
        storesByName['ProviderInventoryModel']?.source,
        OperatorStateSource.provider,
      );
      expect(
        storesByName['RiverpodInventoryProvider']?.source,
        OperatorStateSource.riverpod,
      );
      expect(
        storesByName['GetXInventoryController']?.source,
        OperatorStateSource.getx,
      );
      expect(
        storesByName['ProviderInventoryModel']?.value,
        containsPair('count', 3),
      );
      expect(
        storesByName['RiverpodInventoryProvider']?.value,
        containsPair('filter', 'cold-drinks'),
      );
      expect(
        storesByName['GetXInventoryController']?.value,
        containsPair('total', 9),
      );
      expect(snapshot.capabilities.privacy['capturesScreenshots'], isTrue);

      final widgetTree =
          storesByName['FlutterWidgetTree']?.value as Map<String, Object?>;
      expect(
        widgetTree['frameworks'],
        containsAll(<String>['provider', 'riverpod', 'getx']),
      );

      final valueListenables =
          storesByName['FlutterValueListenables']?.value
              as Map<String, Object?>;
      final listenables =
          (valueListenables['listenables'] as List<Object?>).cast<JsonMap>();
      expect(
        listenables,
        contains(predicate<JsonMap>((item) => item['value'] == 7)),
      );

      final changeNotifierJson = jsonEncode(
        storesByName['FlutterChangeNotifiers']?.value,
      );
      expect(changeNotifierJson, isNot(contains('demo-password-value')));
      expect(changeNotifierJson, contains('[REDACTED]'));

      final providerTree =
          storesByName['FlutterProviderTree']?.value as Map<String, Object?>;
      final providerValues =
          (providerTree['values'] as List<Object?>).cast<JsonMap>();
      expect(
        providerValues,
        contains(
          predicate<JsonMap>(
            (item) =>
                ((item['value'] as JsonMap?)?['value'] as JsonMap?)?['count'] ==
                3,
          ),
        ),
      );

      final riverpodTree =
          storesByName['FlutterRiverpodTree']?.value as Map<String, Object?>;
      final riverpodValues =
          (riverpodTree['values'] as List<Object?>).cast<JsonMap>();
      expect(
        riverpodValues,
        contains(
          predicate<JsonMap>(
            (item) =>
                ((item['value'] as JsonMap?)?['value']
                    as JsonMap?)?['filter'] ==
                'cold-drinks',
          ),
        ),
      );

      final getxTree =
          storesByName['FlutterGetXTree']?.value as Map<String, Object?>;
      final controllers =
          (getxTree['controllers'] as List<Object?>).cast<JsonMap>();
      expect(
        controllers,
        contains(
          predicate<JsonMap>(
            (item) =>
                ((item['value'] as JsonMap?)?['controller']
                    as JsonMap?)?['total'] ==
                9,
          ),
        ),
      );

      final customState =
          storesByName['FlutterCustomState']?.value as Map<String, Object?>;
      final states = (customState['states'] as List<Object?>).cast<JsonMap>();
      expect(
        states,
        contains(
          predicate<JsonMap>(
            (item) =>
                item['state'] == '_CounterSetStateScreenState' &&
                ((item['diagnostics'] as JsonMap?)?['stringValue']
                        ?.toString()
                        .contains('count=1') ??
                    false),
          ),
        ),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      textController.dispose();
      listenable.dispose();
      notifier.dispose();
    },
  );

  test('snapshot reports virtualization coverage capabilities', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-virtualization-capabilities',
        environment: OperatorEnvironment.dev,
      ),
    );

    var snapshot = await operator.getSnapshot(refreshVisual: false);
    expect(snapshot.capabilities.virtualization['networkMocks'], isTrue);
    expect(snapshot.capabilities.virtualization['firebaseMocks'], isFalse);
    expect(snapshot.capabilities.virtualization['stateInjection'], isTrue);
    expect(snapshot.capabilities.virtualization['httpOverrides'], isNull);

    operator.setVirtualizationCapability('httpOverrides', true);
    operator.setVirtualizationCapability('firebase.firestore.queries', true);
    snapshot = await operator.getSnapshot(refreshVisual: false);
    expect(snapshot.capabilities.virtualization['httpOverrides'], isTrue);
    expect(
      snapshot.capabilities.virtualization['firebase.firestore.queries'],
      isTrue,
    );

    operator.setVirtualizationCapability('httpOverrides', false);
    snapshot = await operator.getSnapshot(refreshVisual: false);
    expect(snapshot.capabilities.virtualization['httpOverrides'], isNull);
    expect(
      snapshot.capabilities.virtualization['firebase.firestore.queries'],
      isTrue,
    );
  });

  testWidgets('OperatorAppHost installs and disposes managed integrations', (
    tester,
  ) async {
    var installed = 0;
    var disposed = 0;
    late OperatorApp operatorApp;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-host-integration-test',
          environment: OperatorEnvironment.dev,
        ),
        integrations: <OperatorAppIntegration>[
          (app) {
            installed += 1;
            app.operator.captureLog('info', 'managed integration installed');
            return () {
              disposed += 1;
            };
          },
        ],
        onReady: (app) => operatorApp = app,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('integration host'),
        ),
      ),
    );
    await tester.pump();

    expect(installed, 1);
    expect(
      (await operatorApp.operator.getSnapshot()).logs.map((log) => log.message),
      contains('managed integration installed'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(disposed, 1);
  });

  test(
    'OperatorAppHost gates child build until production setup applies',
    () async {
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..connectSetupActions.add(<String, Object?>{
              'type': 'install_network_mock',
              'match': <String, Object?>{'method': 'GET', 'path': '/startup'},
              'response': <String, Object?>{
                'status': 503,
                'body': 'startup mocked',
              },
              'purpose': 'connect_setup_network_mock',
              'risk': 0,
            });
      final app = await OperatorApp.install(
        config: const OperatorFlutterConfig(
          appId: 'host-startup-gate-test',
          environment: OperatorEnvironment.dev,
        ),
        production: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'host-startup-gate-session',
          appId: 'host-startup-gate-test',
          operatorControlConsent: true,
          uploadBundledAppMapWhenMissing: false,
          requestTimeout: const Duration(seconds: 1),
          pollWait: const Duration(seconds: 5),
          contextStreamInterval: const Duration(seconds: 5),
          controlClientFactory: () => client,
        ),
      );
      final mockAtChildBuild = app.operator.findNetworkMock(
        const NetworkRequest(
          method: 'GET',
          url: 'https://api.example.test/startup',
          path: '/startup',
        ),
      );

      expect(mockAtChildBuild?.status, 503);
      expect(mockAtChildBuild?.body, 'startup mocked');
      expect(client.connects, 1);

      await app.close();
    },
  );

  test(
    'production control client bypasses app HttpOverrides by default',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      final subscription = server.listen((request) async {
        requests.add(request.uri.path);
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/connect')) {
          request.response.write(
            jsonEncode(<String, Object?>{
              'session': <String, Object?>{
                'sessionId': 'control-plane-default-session',
              },
            }),
          );
        } else {
          request.response.write(jsonEncode(<String, Object?>{'ok': true}));
        }
        await request.response.close();
      });
      final previousOverrides = HttpOverrides.current;
      final failingOverrides = _FailingHttpOverrides();
      HttpOverrides.global = failingOverrides;
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-control-plane-default-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final session = OperatorFlutterProductionSession(
        adapter: OperatorFlutterAdapter(operator),
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          sessionId: 'control-plane-default-session',
          appId: 'flutter-control-plane-default-test',
          requestTimeout: const Duration(seconds: 2),
          uploadBundledAppMapWhenMissing: false,
        ),
      );

      try {
        await session.connect();
        expect(
          requests,
          contains(
            '/v1/operator/sessions/control-plane-default-session/connect',
          ),
        );
        expect(failingOverrides.createClientCalls, 0);
      } finally {
        await session.close();
        operator.dispose();
        HttpOverrides.global = previousOverrides;
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'production snapshot holding a number JSON cannot carry arrives, listing it',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final snapshotBodies = <Map<String, Object?>>[];
      final subscription = server.listen((request) async {
        final body = await _readRequestJson(request);
        if (request.uri.path.endsWith('/snapshot')) snapshotBodies.add(body);
        _writeJson(request, <String, Object?>{'ok': true});
      });
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-unreadable-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final session = OperatorFlutterProductionSession(
        adapter: OperatorFlutterAdapter(operator),
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          sessionId: 'unreadable-session',
          appId: 'flutter-production-unreadable-test',
          requestTimeout: const Duration(seconds: 2),
          uploadBundledAppMapWhenMissing: false,
        ),
      );

      try {
        operator.captureLog(
          'debug',
          'unreadable',
          data: <String, Object?>{'ratio': double.nan},
        );
        await session.publishSnapshot(reason: 'unreadable_test');
        // The full snapshot arrived: the session did not fall back to a
        // compacted one, which it would log.
        expect(
          (await operator.getSnapshot()).logs.map((log) => log.message),
          isNot(
            contains(
              'operator production full snapshot upload failed; compact snapshot uploaded',
            ),
          ),
        );
        final snapshot = snapshotBodies.single['snapshot'] as Map;
        expect(
          (snapshot['unreadableValues'] as Map)['values'],
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
      } finally {
        await session.close();
        operator.dispose();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('production session close wakes poll and context loops', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-production-close-loop-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final client = _FakeProductionHttpClient()..failFirstCommandPoll = false;
    final session = OperatorFlutterProductionSession(
      adapter: OperatorFlutterAdapter(operator),
      config: OperatorProductionSessionConfig(
        endpoint: Uri.parse('http://operator.test'),
        sessionId: 'close-loop-session',
        appId: 'flutter-production-close-loop-test',
        pollWait: const Duration(seconds: 5),
        contextStreamInterval: const Duration(seconds: 5),
      ),
      client: client,
    );

    unawaited(session.start());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final stopwatch = Stopwatch()..start();
    await session.close().timeout(const Duration(milliseconds: 500));
    stopwatch.stop();
    operator.dispose();

    expect(client.commandPolls, greaterThanOrEqualTo(1));
    expect(stopwatch.elapsedMilliseconds, lessThan(500));
  });

  test('snapshot JSON preserves log source', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-log-source-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    operator.captureLog(
      'warn',
      'operator production snapshot stream upload failed',
    );

    final snapshot = await operator.getSnapshot();
    final json = operatorSnapshotToJson(snapshot);
    final logs = json['logs'] as List<Object?>;
    final lastLog = logs.last as Map<String, Object?>;

    expect(lastLog['source'], 'operator');
  });

  test('operator transport aborts do not become app errors', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-operator-transport-error-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    operator.suppressOperatorRuntimeZoneError('Request has been aborted');
    final handledAbort = operator.captureZoneError(
      const HttpException('Request has been aborted'),
      StackTrace.current,
    );

    final snapshot = await operator.getSnapshot();
    final json = operatorSnapshotToJson(snapshot);
    final logs = json['logs'] as List<Object?>;
    final lastLog = logs.last as Map<String, Object?>;

    expect(snapshot.errors, isEmpty);
    expect(handledAbort, isTrue);
    expect(snapshot.logs.last.source, OperatorLogSource.operatorRuntime);
    expect(lastLog['source'], 'operator');
    expect(lastLog['message'], 'operator runtime transport error suppressed');

    final handledEndpointFailure = operator.captureZoneError(
      HttpException(
        'Connection closed before full header was received, uri = '
        'http://127.0.0.1:8791/v1/operator/sessions/test-session/results',
      ),
      StackTrace.current,
    );
    final endpointSnapshot = await operator.getSnapshot();
    expect(endpointSnapshot.errors, isEmpty);
    expect(endpointSnapshot.logs.last.level, 'debug');
    expect(
      endpointSnapshot.logs.last.source,
      OperatorLogSource.operatorRuntime,
    );

    final handledAppFailure = operator.captureZoneError(
      StateError('real app failure'),
      StackTrace.current,
    );
    final appFailureSnapshot = await operator.getSnapshot();
    expect(handledEndpointFailure, isTrue);
    expect(handledAppFailure, isFalse);
    expect(appFailureSnapshot.errors, isNotEmpty);
    expect(
      appFailureSnapshot.errors.last.message,
      contains('real app failure'),
    );
    operator.dispose();
  });

  testWidgets('OperatorAppHost reports platform runtime errors', (
    tester,
  ) async {
    late OperatorApp operatorApp;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-platform-error-capture-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('error host'),
        ),
      ),
    );
    await tester.pump();

    ui.PlatformDispatcher.instance.onError!(
      StateError('operator async runtime failure'),
      StackTrace.current,
    );

    final snapshot = await operatorApp.operator.getSnapshot();
    expect(
      snapshot.errors.map((error) => error.message),
      contains(contains('operator async runtime failure')),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'getSnapshot refreshes visual frame providers before returning',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-visual-provider-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      operator.addVisualFrameProvider(
        () async => const VisualFrame(
          id: 'provider-frame',
          format: 'png',
          width: 390,
          height: 844,
          source: 'repaint_boundary',
          redacted: false,
          encoding: 'base64',
          data: 'iVBORw0KGgoAAAANSUhEUgAAAYYAAANM',
        ),
      );

      final snapshot = await operator.getSnapshot();

      expect(snapshot.visual?.metadata['pixelBacked'], isTrue);
      expect(
        (snapshot.visual?.analysis['assertions'] as JsonMap?)?['hasPixels'],
        isTrue,
      );
      expect(
        snapshot.visual?.frames.any((frame) => frame.id == 'provider-frame'),
        isTrue,
      );
      operator.dispose();
    },
  );

  test(
    'capture_visual dispatch captures fresh provider occurrences and bounds retention',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-explicit-visual-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      var providerCalls = 0;
      operator.addVisualFrameProvider(() async {
        providerCalls += 1;
        return const VisualFrame(
          id: 'fixed-provider-frame',
          format: 'png',
          width: 390,
          height: 844,
          source: 'test_provider',
          redacted: false,
          encoding: 'base64',
          data: 'iVBORw0KGgoAAAANSUhEUgAAAYYAAANM',
        );
      });
      final adapter = OperatorFlutterAdapter(operator);
      final command = operatorActionCommandFromJson(<String, Object?>{
        'type': 'capture_visual',
        'reason': 'fresh Flutter pixels',
      });
      expect(command.type, OperatorActionType.captureVisual);
      expect(command.reason, 'fresh Flutter pixels');
      expect(operator.canCaptureScreenshots, isTrue);

      final baseline = await operator.getSnapshot();
      final baselineIds =
          baseline.visual?.frames.map((frame) => frame.id).toSet();
      final firstResult = await adapter.execute(command);
      final firstSnapshot = await operator.getSnapshot(refreshVisual: false);
      final firstFresh = firstSnapshot.visual?.frames.where(
        (frame) => !(baselineIds?.contains(frame.id) ?? false),
      );
      expect(firstResult.ok, isTrue);
      expect(firstFresh, isNotNull);
      expect(firstFresh, isNotEmpty);
      final firstId = firstFresh!.first.id;

      final secondResult = await adapter.execute(command);
      final secondSnapshot = await operator.getSnapshot(refreshVisual: false);
      final secondFresh = secondSnapshot.visual?.frames.where(
        (frame) => frame.id != firstId,
      );
      expect(secondResult.ok, isTrue);
      expect(secondFresh, isNotNull);
      expect(secondFresh, isNotEmpty);
      expect(secondSnapshot.visual?.frames.length, lessThanOrEqualTo(2));
      expect(providerCalls, 3);

      final encodedResult = operatorActionResultToJson(secondResult);
      final encodedAction = encodedResult['action'] as JsonMap;
      expect(encodedAction['type'], 'capture_visual');
      expect(encodedAction['reason'], 'fresh Flutter pixels');
      operator.dispose();
    },
  );

  test(
    'passive and explicit visual capture share one FIFO and explicit owns its invocation',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-visual-overlap-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final first = Completer<VisualFrame?>();
      final second = Completer<VisualFrame?>();
      var providerCalls = 0;
      operator.addVisualFrameProvider(() {
        providerCalls += 1;
        return providerCalls == 1 ? first.future : second.future;
      });

      final passive = operator.getSnapshot();
      await Future<void>.delayed(Duration.zero);
      final explicit = operator.captureVisualResult('queued explicit capture');
      await Future<void>.delayed(Duration.zero);
      expect(providerCalls, 1);

      first.complete(
        const VisualFrame(
          id: 'passive-overlap-frame',
          format: 'png',
          width: 1,
          height: 1,
          source: 'manual',
          redacted: false,
          encoding: 'base64',
          data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB',
        ),
      );
      await passive;
      await Future<void>.delayed(Duration.zero);
      expect(providerCalls, 2);

      second.complete(
        const VisualFrame(
          id: 'explicit-overlap-frame',
          format: 'png',
          width: 1,
          height: 1,
          source: 'manual',
          redacted: true,
          encoding: 'base64',
          data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB',
        ),
      );
      final captured = await explicit;
      expect(captured.frames, hasLength(1));
      expect(captured.frames.single.id, contains('explicit-overlap-frame'));
      final observation = await operator.getSnapshot(
        refreshVisual: false,
        refreshProviders: false,
        visualFrames: captured.frames,
        visualCaptureTargets: captured.captureTargets,
      );
      expect(observation.visual?.analysis['hasUsablePixels'], isTrue);
      final frameAnalysis =
          (observation.visual?.analysis['frames'] as List<Object?>)
              .cast<JsonMap>();
      expect(frameAnalysis.single['lowInformation'], isTrue);
      operator.dispose();
    },
  );

  test('visual retention is latest per provider and surface', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-visual-surface-retention-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    var calls = 0;
    operator.addVisualFrameProvider(() async {
      calls += 1;
      return VisualFrame(
        id: 'stable-provider-frame',
        surfaceId: calls == 1 ? 'surface-a' : 'surface-b',
        format: 'png',
        width: 1,
        height: 1,
        source: 'manual',
        redacted: false,
        encoding: 'base64',
        data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB',
      );
    });

    await operator.getSnapshot();
    final snapshot = await operator.getSnapshot();
    expect(
      snapshot.visual?.frames.map((frame) => frame.surfaceId).toSet(),
      <String?>{'surface-a', 'surface-b'},
    );
    operator.dispose();
  });

  test('visual base64 parity rejects whitespace', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-visual-whitespace-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    operator.addVisualFrameProvider(
      () async => const VisualFrame(
        id: 'whitespace-frame',
        format: 'png',
        width: 1,
        height: 1,
        source: 'manual',
        redacted: false,
        encoding: 'base64',
        data: 'iVBORw0KGgoAAAANSUhEUgAA AAEAAAAB',
      ),
    );

    final result = await OperatorFlutterAdapter(operator).execute(
      const ActionCommand(
        type: OperatorActionType.captureVisual,
        reason: 'whitespace parity',
      ),
    );
    expect(result.ok, isFalse);
    expect(result.error?.type, 'visual_capture_unavailable');
    expect((result.data['visualCapture'] as JsonMap)['invalidTargetCount'], 1);
    operator.dispose();
  });

  test('capture_visual is unavailable without an installed provider', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-no-visual-provider-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final adapter = OperatorFlutterAdapter(operator);

    expect(operator.canCaptureScreenshots, isFalse);
    final result = await adapter.execute(
      const ActionCommand(
        type: OperatorActionType.captureVisual,
        reason: 'missing Flutter provider',
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error?.type, 'visual_capture_unavailable');
    expect(result.error?.retryable, isFalse);
    operator.dispose();
  });

  test(
    'capture_visual rejects malformed current bytes without reusing a retained frame',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-malformed-visual-provider-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      operator.captureVisualFrame(
        const VisualFrame(
          id: 'stale-valid-frame',
          format: 'png',
          width: 390,
          height: 844,
          source: 'manual',
          redacted: false,
          encoding: 'base64',
          data: 'iVBORw0KGgoAAAANSUhEUgAAAYYAAANM',
        ),
      );
      operator.addVisualFrameProvider(
        () async => const VisualFrame(
          id: 'malformed-current-frame',
          format: 'png',
          width: 390,
          height: 844,
          source: 'manual',
          redacted: false,
          encoding: 'base64',
          // Valid base64, but not an image header.
          data: 'QUJDRA==',
        ),
      );

      final captured = await operator.captureVisual('malformed current frame');
      final exactObservation = await operator.getSnapshot(
        refreshVisual: false,
        refreshProviders: false,
        visualFrames: captured,
      );
      expect(
        exactObservation.visual?.frames.any(
          (frame) => frame.id == 'stale-valid-frame',
        ),
        isFalse,
      );
      expect(exactObservation.visual?.analysis['hasUsablePixels'], isFalse);
      expect(exactObservation.visual?.analysis['invalidFrameCount'], 1);

      final result = await OperatorFlutterAdapter(operator).execute(
        const ActionCommand(
          type: OperatorActionType.captureVisual,
          reason: 'malformed Flutter provider bytes',
        ),
      );
      expect(result.ok, isFalse);
      expect(result.error?.type, 'visual_capture_unavailable');
      operator.dispose();
    },
  );

  testWidgets('getSnapshot resolves zero viewport before visual analysis', (
    tester,
  ) async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-viewport-fallback-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    operator.captureUiTree(
      const UiTree(
        rootId: 'flutter-root',
        viewport: ViewportSnapshot(width: 0, height: 0),
        elements: <UiElement>[
          UiElement(
            id: 'close',
            role: OperatorUiRole.button,
            label: 'Close',
            text: 'Close',
            enabled: true,
            visible: true,
            actions: <String>['tap'],
            confidence: 0.9,
            bounds: ElementBounds(x: 20, y: 20, width: 80, height: 44),
          ),
        ],
      ),
    );

    final snapshot = await operator.getSnapshot();
    final findings =
        (snapshot.visual?.analysis['findings'] as List<Object?>? ?? const []);

    expect(snapshot.ui.viewport.width, greaterThan(0));
    expect(snapshot.ui.viewport.height, greaterThan(0));
    expect(
      findings.where(
        (finding) => finding is JsonMap && finding['type'] == 'out_of_viewport',
      ),
      isEmpty,
    );
    operator.dispose();
  });

  testWidgets('OperatorAppHost captures painted text omitted from semantics', (
    tester,
  ) async {
    late OperatorApp app;
    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-widget-text-observer-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (ready) => app = ready,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: <Widget>[
              ExcludeSemantics(
                child: ColoredBox(
                  color: Colors.red,
                  child: Stack(
                    children: const <Widget>[
                      SizedBox(
                        width: 390,
                        height: 52,
                        child: Center(child: Text('Keine Netzwerkverbindung')),
                      ),
                      SizedBox(
                        width: 390,
                        height: 52,
                        child: Center(child: Text('Keine Netzwerkverbindung')),
                      ),
                      Positioned(right: 12, top: 12, child: Text('\ue821')),
                    ],
                  ),
                ),
              ),
              Positioned(top: 80, child: Text('Semantic body text')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final snapshot = await app.operator.getSnapshot();
    final paintedBanner = snapshot.ui.elements.where(
      (element) =>
          element.text == 'Keine Netzwerkverbindung' &&
          element.data['source'] == 'flutter_widget_text',
    );

    expect(paintedBanner.length, 1);
    expect(
      snapshot.ui.elements.any(
        (element) =>
            element.text == '\ue821' &&
            element.data['source'] == 'flutter_widget_text',
      ),
      isFalse,
    );
    expect(
      snapshot.visual?.ocr.any(
        (region) => region.text == 'Keine Netzwerkverbindung',
      ),
      isTrue,
    );
    expect(
      snapshot.visual?.metadata['textSource'],
      'semantic_ui+flutter_widget_text',
    );
  });

  testWidgets('OperatorAppHost ignores widget text from inactive routes', (
    tester,
  ) async {
    late OperatorApp app;
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-widget-text-route-visibility-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (ready) => app = ready,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(
            body: ExcludeSemantics(child: Text('Background Route Text')),
          ),
          routes: <String, WidgetBuilder>{
            '/current':
                (_) => const Scaffold(
                  body: Stack(
                    children: <Widget>[
                      ExcludeSemantics(child: Text('Current Route Banner')),
                      Offstage(
                        offstage: true,
                        child: Text('Hidden Offstage Text'),
                      ),
                      Visibility(
                        visible: false,
                        child: Text('Hidden Visibility Text'),
                      ),
                    ],
                  ),
                ),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pushNamed('/current');
    await tester.pumpAndSettle();

    final snapshot = await app.operator.getSnapshot();
    final widgetTexts =
        snapshot.ui.elements
            .where((element) => element.data['source'] == 'flutter_widget_text')
            .map((element) => element.text)
            .toList();

    expect(widgetTexts, contains('Current Route Banner'));
    expect(widgetTexts, isNot(contains('Background Route Text')));
    expect(widgetTexts, isNot(contains('Hidden Offstage Text')));
    expect(widgetTexts, isNot(contains('Hidden Visibility Text')));
  });

  testWidgets('OperatorAppHost installs a root Riverpod observer', (
    tester,
  ) async {
    late OperatorApp operatorApp;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-riverpod-observer-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          home: Scaffold(
            body: riverpod.Consumer(
              builder: (context, ref, _) {
                final item = ref.watch(_operatorRiverpodInventoryProvider);
                return Text('Riverpod ${item['sku']} x${item['count']}');
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Riverpod COKE x13'), findsOneWidget);

    final snapshot = await operatorApp.operator.getSnapshot();
    final store = snapshot.state.lastWhere(
      (store) => store.name == 'OperatorRiverpodInventory',
    );
    final value = store.value as JsonMap;

    expect(store.source, OperatorStateSource.riverpod);
    expect(value['event'], 'add');
    expect(value['value'], containsPair('sku', 'COKE'));
    expect(value['value'], containsPair('count', 13));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('OperatorAppHost installs a root Bloc observer', (tester) async {
    late OperatorApp operatorApp;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-bloc-observer-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('Bloc observer shell'),
        ),
      ),
    );
    await tester.pump();

    final cubit = _OperatorInventoryCubit();
    cubit.setQuantity(3);

    final snapshot = await operatorApp.operator.getSnapshot();
    final store = snapshot.state.lastWhere(
      (store) => store.name == '_OperatorInventoryCubit',
    );
    final value = store.value as JsonMap;
    final state = value['state'] as JsonMap;

    expect(store.source, OperatorStateSource.bloc);
    expect(value['event'], 'change');
    expect(value['bloc'], '_OperatorInventoryCubit');
    expect(value['stateType'], '_OperatorInventoryState');
    expect(state, containsPair('sku', 'COKE'));
    expect(state, containsPair('quantity', 3));
    expect(
      snapshot.state.where((store) => store.name == '_OperatorInventoryState'),
      isEmpty,
    );

    await cubit.close();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('Navigator and GetX observers capture route changes', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-route-observer-test',
        environment: OperatorEnvironment.dev,
      ),
    );

    final observer = OperatorNavigatorObserver(operator: operator);
    observer.didPush(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/inventory'),
        builder: (_) => const SizedBox.shrink(),
      ),
      null,
    );
    expect((await operator.getSnapshot()).route.current.path, '/inventory');

    captureGetXRouting(
      operator,
      getx.Routing(
        current: '/getx/cart',
        previous: '/inventory',
        isBack: false,
      ),
    );
    final snapshot = await operator.getSnapshot();
    expect(snapshot.route.current.path, '/getx/cart');
    expect(snapshot.route.current.screenClass, 'getx');
    expect(snapshot.route.current.params['previous'], '/inventory');

    operator.dispose();
  });

  testWidgets(
    'OperatorAppHost automatically captures normal Navigator routes',
    (tester) async {
      late OperatorApp operatorApp;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-navigator-route-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            routes: <String, WidgetBuilder>{
              '/':
                  (context) => Scaffold(
                    body: TextButton(
                      onPressed:
                          () => Navigator.of(
                            context,
                          ).pushNamed('/inventory/detail'),
                      child: const Text('Open details'),
                    ),
                  ),
              '/inventory/detail':
                  (_) => const Scaffold(body: Text('Inventory detail')),
            },
          ),
        ),
      );
      await tester.pump();
      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(label: 'Open details'),
          purpose: 'open_details',
          risk: 1,
        ),
      );
      final result = await _awaitActionWithPumps(tester, action);
      expect(
        result.ok,
        isTrue,
        reason: '${result.error?.type}: ${result.error?.message}',
      );
      await tester.pump(const Duration(milliseconds: 400));

      final snapshot = await operatorApp.operator.getSnapshot();
      expect(snapshot.route.current.path, '/inventory/detail');
      expect(snapshot.route.current.screenClass, contains('Route'));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost refreshes route from element tree during passive snapshots',
    (tester) async {
      late OperatorApp operatorApp;
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-passive-route-refresh-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            routes: <String, WidgetBuilder>{
              '/': (_) => const Scaffold(body: Text('Dashboard home')),
              '/resident-record-route':
                  (_) => const Scaffold(body: Text('Resident record')),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        (await operatorApp.operator.getSnapshot()).route.current.path,
        '/',
      );

      navigatorKey.currentState!.pushNamed('/resident-record-route');
      await tester.pumpAndSettle();
      expect(
        (await operatorApp.operator.getSnapshot()).route.current.path,
        '/resident-record-route',
      );

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      final snapshot = await operatorApp.operator.getSnapshot();
      expect(snapshot.route.current.path, '/');
      expect(
        snapshot.ui.elements
            .map((element) => element.text ?? element.label)
            .whereType<String>(),
        contains('Dashboard home'),
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost prefers painted current route over stale RouterDelegate config',
    (tester) async {
      late OperatorApp operatorApp;
      final delegate = _StaleConfigPaintedRouteDelegate();

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-painted-route-over-stale-router-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: Router<Object>(routerDelegate: delegate),
        ),
      );
      await tester.pumpAndSettle();

      final snapshot = await operatorApp.operator.getSnapshot();
      expect(snapshot.route.current.path, '/dashboard-route');
      expect(snapshot.route.current.name, 'DashboardRoute');
      expect(
        snapshot.ui.elements
            .map((element) => element.text ?? element.label)
            .whereType<String>(),
        contains('Dashboard route visible'),
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('OperatorAppHost executes direct Navigator route commands', (
    tester,
  ) async {
    late OperatorApp operatorApp;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-navigator-execute-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          routes: <String, WidgetBuilder>{
            '/': (_) => const Scaffold(body: Text('Home')),
            '/inventory/detail':
                (_) => const Scaffold(body: Text('Inventory detail')),
          },
        ),
      ),
    );
    await tester.pump();

    final action = operatorApp.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.navigate,
        path: '/inventory/detail',
        purpose: 'open_details',
        risk: 1,
      ),
    );
    final result = await _awaitActionWithPumps(tester, action);
    await tester.pumpAndSettle();

    expect(result.ok, isTrue);
    expect(find.text('Inventory detail'), findsOneWidget);
    expect(
      (await operatorApp.operator.getSnapshot()).route.current.path,
      '/inventory/detail',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'OperatorAppHost infers AutoRoute Beamer and GetX style RouterDelegate routes',
    (tester) async {
      Future<AppSnapshot> snapshotFor<T extends Object>(
        RouterDelegate<T> delegate,
        String appId,
      ) async {
        late OperatorApp operatorApp;
        await tester.pumpWidget(
          OperatorAppHost(
            config: OperatorFlutterConfig(
              appId: appId,
              environment: OperatorEnvironment.dev,
            ),
            onReady: (app) => operatorApp = app,
            child: Router<T>(routerDelegate: delegate),
          ),
        );
        await tester.pump();
        final snapshot = await operatorApp.operator.getSnapshot();
        await tester.pumpWidget(const SizedBox.shrink());
        return snapshot;
      }

      final autoRouteSnapshot = await snapshotFor(
        _FakeAutoRouteDelegate(),
        'flutter-auto-route-test',
      );
      expect(autoRouteSnapshot.route.current.path, '/auto/cart');
      expect(autoRouteSnapshot.route.current.params['sku'], 'COKE');
      expect(autoRouteSnapshot.route.current.screenClass, 'auto_route');

      final beamerSnapshot = await snapshotFor(
        _FakeBeamerDelegate(),
        'flutter-beamer-route-test',
      );
      expect(beamerSnapshot.route.current.path, '/beam/checkout');
      expect(beamerSnapshot.route.current.screenClass, 'beamer');

      final getxSnapshot = await snapshotFor(
        _FakeGetXDelegate(),
        'flutter-getx-route-test',
      );
      expect(getxSnapshot.route.current.path, '/getx/orders');
      expect(getxSnapshot.route.current.screenClass, 'getx');
    },
  );

  testWidgets('OperatorAppHost executes direct RouterDelegate route commands', (
    tester,
  ) async {
    Future<void> verify(
      _PathRouterDelegate delegate,
      String appId, {
      RouteInformationParser<Object>? parser,
    }) async {
      late OperatorApp operatorApp;
      await tester.pumpWidget(
        OperatorAppHost(
          config: OperatorFlutterConfig(
            appId: appId,
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: Router<Object>(
            routerDelegate: delegate,
            routeInformationParser: parser,
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.navigate,
          path: '/popular/search',
          purpose: 'open_search',
          risk: 1,
        ),
      );
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();
      expect(
        result.ok,
        isTrue,
        reason: [
          result.error?.message ?? result.message,
          for (final entry in result.evidence)
            '${entry.condition}: ${entry.detail}',
        ].whereType<String>().join('\n'),
      );
      expect(delegate.path, '/popular/search');
      expect(
        (await operatorApp.operator.getSnapshot()).route.current.path,
        '/popular/search',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    }

    await verify(
      _ParserBackedRouteDelegate(),
      'flutter-parser-route-execute-test',
      parser: _PathRouteInformationParser(),
    );
    await verify(
      _FakeAutoRouteNavigationDelegate(),
      'flutter-auto-route-execute-test',
    );
    await verify(
      _FakeBeamerNavigationDelegate(),
      'flutter-beamer-route-execute-test',
    );
    await verify(
      _FakeGetXNavigationDelegate(),
      'flutter-getx-route-execute-test',
    );
  });

  testWidgets(
    'OperatorAppHost executes wait commands through automatic runtime',
    (tester) async {
      late OperatorApp operatorApp;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-wait-execute-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: const MaterialApp(home: Scaffold(body: Text('Waiting'))),
        ),
      );
      await tester.pump();

      operatorApp.operator.captureStateChange(
        source: OperatorStateSource.custom,
        name: 'AsyncFlag',
        value: const <String, Object?>{
          'state': <String, Object?>{'ready': true},
        },
      );

      final result = await operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.wait,
          until: WaitCondition(
            type: 'state',
            store: 'AsyncFlag',
            statePath: 'state.ready',
          ),
          timeout: Duration(milliseconds: 500),
          purpose: 'wait_for_state',
          risk: 1,
        ),
      );

      expect(
        result.ok,
        isTrue,
        reason: result.error?.message ?? result.message,
      );
      expect(result.message, 'Wait condition satisfied');

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('network event wait ignores retained and unrelated traffic', (
    tester,
  ) async {
    late OperatorApp operatorApp;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-network-event-wait-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: const MaterialApp(home: Scaffold(body: Text('Waiting'))),
      ),
    );
    await tester.pump();

    const request = NetworkRequest(
      method: 'POST',
      url: 'https://example.test/v1/session',
      path: '/v1/session',
    );
    operatorApp.operator.captureNetworkResponse(
      id: 'retained-before-wait',
      request: request,
      status: 200,
      ok: true,
    );

    var settled = false;
    final wait = operatorApp.binding.adapter
        .execute(
          const ActionCommand(
            type: OperatorActionType.wait,
            until: WaitCondition(
              type: 'network_event',
              path: '/v1/session',
              method: 'POST',
              ok: true,
            ),
            timeout: Duration(milliseconds: 500),
            purpose: 'wait_for_future_session_request',
            risk: 0,
          ),
        )
        .then((result) {
          settled = true;
          return result;
        });

    await tester.pump(const Duration(milliseconds: 10));
    expect(settled, isFalse, reason: 'retained traffic satisfied the wait');

    operatorApp.operator.captureNetworkResponse(
      id: 'future-unrelated',
      request: const NetworkRequest(
        method: 'POST',
        url: 'https://example.test/v1/analytics',
        path: '/v1/analytics',
      ),
      status: 200,
      ok: true,
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(settled, isFalse, reason: 'unrelated traffic satisfied the wait');

    operatorApp.operator.captureNetworkResponse(
      id: 'future-matching',
      request: request,
      status: 200,
      ok: true,
    );
    final result = await wait;
    expect(result.ok, isTrue, reason: result.error?.message ?? result.message);
    expect(result.data['eventId'], 'future-matching');
    expect(result.data['observation'], 'future_event');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'OperatorAppHost taps snapshot ids and rejects missing tap targets',
    (tester) async {
      late OperatorApp operatorApp;
      var taps = 0;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-tap-target-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      children: <Widget>[
                        ElevatedButton(
                          onPressed: () => setState(() => taps++),
                          child: Text('Real target $taps'),
                        ),
                        ElevatedButton(
                          onPressed: () => setState(() => taps += 100),
                          child: const Text('Home'),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final snapshot = await operatorApp.operator.getSnapshot();
      final target = snapshot.ui.elements.singleWhere(
        (element) => element.label?.contains('Real target') ?? false,
      );
      final tapAction = operatorApp.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(id: target.id),
          purpose: 'tap_snapshot_id',
          risk: 1,
        ),
      );
      for (var i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final tapped = await _awaitActionWithPumps(tester, tapAction);
      await tester.pump();

      expect(
        tapped.ok,
        isTrue,
        reason:
            '${tapped.error?.type}: ${tapped.error?.message}; evidence=${tapped.evidence.map((entry) => '${entry.condition}:${entry.detail}').join(' | ')}',
      );
      expect(taps, 1);

      final missing =
          (await tester.runAsync(
            () => operatorApp.binding.adapter.execute(
              const ActionCommand(
                type: OperatorActionType.tap,
                target: ElementTarget(label: 'Place order'),
                purpose: 'tap_missing_target',
                risk: 1,
              ),
            ),
          ))!;
      await tester.pump();

      expect(missing.ok, isFalse);
      expect(missing.error?.type, 'target_not_found');
      expect(missing.data['operationPhase'], 'zero_dispatch');
      expect(taps, 1);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('OperatorAppHost taps exact short text without parent fallback', (
    tester,
  ) async {
    late OperatorApp operatorApp;
    var tapped = '';

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-short-text-target-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder:
                  (context, setState) => Column(
                    children: <Widget>[
                      Text('Tapped $tapped'),
                      Semantics(
                        label: '1234',
                        child: Row(
                          children: <Widget>[
                            ElevatedButton(
                              onPressed: () => setState(() => tapped = '1'),
                              child: const Text('1'),
                            ),
                            ElevatedButton(
                              onPressed: () => setState(() => tapped = '2'),
                              child: const Text('2'),
                            ),
                            ElevatedButton(
                              onPressed: () => setState(() => tapped = '3'),
                              child: const Text('3'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final action = operatorApp.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(text: '3'),
        purpose: 'tap_pin_digit',
        risk: 1,
      ),
    );
    for (var i = 0; i < 12; i += 1) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final result = await _awaitActionWithPumps(tester, action);
    await tester.pump();

    expect(result.ok, isTrue);
    expect(tapped, '3');
    expect(
      result.evidence.any(
        (entry) =>
            entry.condition == 'tap.phase_timing' &&
            (entry.detail?.contains('totalMs=') ?? false) &&
            (entry.detail?.contains('resolveMs=') ?? false),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('OperatorAppHost does not retry delayed small leaf controls', (
    tester,
  ) async {
    late OperatorApp operatorApp;
    var taps = 0;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-single-dispatch-small-control-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder:
                  (context, setState) => Column(
                    children: <Widget>[
                      Text('Tapped $taps'),
                      ElevatedButton(
                        onPressed: () {
                          Future<void>.delayed(
                            const Duration(milliseconds: 650),
                            () => setState(() => taps += 1),
                          );
                        },
                        child: const Text('2'),
                      ),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final action = operatorApp.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(text: '2'),
        purpose: 'tap_delayed_digit',
        risk: 1,
      ),
    );
    for (var i = 0; i < 24; i += 1) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final result = await _awaitActionWithPumps(tester, action);
    await tester.pump();

    expect(
      result.ok,
      isTrue,
      reason:
          '${result.error?.type}: ${result.error?.message}; evidence=${result.evidence.map((entry) => '${entry.condition}:${entry.detail}').join(' | ')}',
    );
    expect(taps, 1);
    expect(
      result.evidence.where(
        (entry) => entry.condition.startsWith('tap.pointer.attempt.'),
      ),
      hasLength(1),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('OperatorAppHost taps exact labelled input controls', (
    tester,
  ) async {
    late OperatorApp operatorApp;
    var opened = false;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-labelled-input-tap-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder:
                  (context, setState) => Column(
                    children: <Widget>[
                      Text('opened=$opened'),
                      Semantics(
                        label: '-- Profil auswählen --',
                        textField: true,
                        onTap: () => setState(() => opened = true),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => opened = true),
                          child: const SizedBox(width: 320, height: 56),
                        ),
                      ),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final action = operatorApp.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(text: '-- Profil auswählen --'),
        purpose: 'open_profile_selector',
        risk: 1,
      ),
    );
    for (var i = 0; i < 12; i += 1) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final result = await _awaitActionWithPumps(tester, action);
    await tester.pump();

    expect(
      result.ok,
      isTrue,
      reason:
          '${result.error?.type}: ${result.error?.message}; evidence=${result.evidence.map((entry) => '${entry.condition}:${entry.detail}').join(' | ')}',
    );
    expect(opened, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('OperatorAppHost selects dropdown menu items by text', (
    tester,
  ) async {
    late OperatorApp operatorApp;
    String? selected;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-dropdown-selection-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder:
                  (context, setState) => Column(
                    children: <Widget>[
                      Text('selected=${selected ?? 'none'}'),
                      DropdownButton<String>(
                        hint: const Text('-- Profil auswählen --'),
                        value: selected,
                        items: const <DropdownMenuItem<String>>[
                          DropdownMenuItem<String>(
                            value: 'Eren',
                            child: Text('Eren'),
                          ),
                          DropdownMenuItem<String>(
                            value: 'Jewel',
                            child: Text('Jewel'),
                          ),
                        ],
                        onChanged: (value) => setState(() => selected = value),
                      ),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    var action = operatorApp.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(text: '-- Profil auswählen --'),
        purpose: 'open_profile_selector',
        risk: 1,
      ),
    );
    for (var i = 0; i < 12; i += 1) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    var result = await _awaitActionWithPumps(tester, action);
    expect(
      result.ok,
      isTrue,
      reason:
          '${result.error?.type}: ${result.error?.message}; evidence=${result.evidence.map((entry) => '${entry.condition}:${entry.detail}').join(' | ')}',
    );

    action = operatorApp.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(text: 'Jewel'),
        purpose: 'select_profile_jewel',
        risk: 1,
      ),
    );
    for (var i = 0; i < 12; i += 1) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    result = await _awaitActionWithPumps(tester, action);
    await tester.pump();

    expect(
      result.ok,
      isTrue,
      reason:
          '${result.error?.type}: ${result.error?.message}; evidence=${result.evidence.map((entry) => '${entry.condition}:${entry.detail}').join(' | ')}',
    );
    expect(
      selected,
      'Jewel',
      reason:
          '${result.error?.type}: ${result.error?.message}; evidence=${result.evidence.map((entry) => '${entry.condition}:${entry.detail}').join(' | ')}',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('OperatorAppHost verifies delayed route changes after tap', (
    tester,
  ) async {
    late OperatorApp operatorApp;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-delayed-route-tap-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          routes: <String, WidgetBuilder>{
            '/':
                (context) => Scaffold(
                  body: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      await Future<void>.delayed(
                        const Duration(milliseconds: 2200),
                      );
                      if (context.mounted) {
                        Navigator.of(context).pushNamed('/detail');
                      }
                    },
                    child: const Center(child: Text('Open delayed detail')),
                  ),
                ),
            '/detail':
                (_) => const Scaffold(body: Text('Delayed detail loaded')),
          },
        ),
      ),
    );
    await tester.pump();

    final action = operatorApp.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(fallbackBounds: FallbackPoint(x: 200, y: 200)),
        purpose: 'tap_delayed_route',
        risk: 1,
      ),
    );
    for (var i = 0; i < 40; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final result = await _awaitActionWithPumps(tester, action);
    await tester.pump();

    expect(result.ok, isTrue, reason: result.error?.message);
    expect(
      result.evidence.map((entry) => entry.condition),
      contains('tap.deferred_effect.verified'),
    );
    expect(
      (await operatorApp.operator.getSnapshot()).route.current.path,
      '/detail',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'OperatorAppHost returns after render-pointer reaction while stream sees delayed route',
    (tester) async {
      late OperatorApp operatorApp;
      var unrelatedCounter = 0;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-immediate-state-delayed-route-tap-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            routes: <String, WidgetBuilder>{
              '/':
                  (context) => Scaffold(
                    body: StatefulBuilder(
                      builder:
                          (context, setState) => Column(
                            children: <Widget>[
                              Text('unrelated=$unrelatedCounter'),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  setState(() => unrelatedCounter += 1);
                                  Future<void>.delayed(
                                    const Duration(milliseconds: 650),
                                    () {
                                      if (context.mounted) {
                                        Navigator.of(
                                          context,
                                        ).pushNamed('/dashboard');
                                      }
                                    },
                                  );
                                },
                                child: Semantics(
                                  label: 'Fortfahren',
                                  button: true,
                                  child: const SizedBox(width: 180, height: 48),
                                ),
                              ),
                            ],
                          ),
                    ),
                  ),
              '/dashboard':
                  (_) => const Scaffold(body: Text('Dashboard loaded')),
            },
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Fortfahren'),
          purpose: 'tap_continue_with_async_navigation',
          risk: 1,
        ),
      );
      for (var i = 0; i < 24; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(result.ok, isTrue, reason: result.error?.message);
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition == 'tap.target_effect.verified' &&
              ((entry.detail ?? '').contains(
                'live stream owns final readiness',
              )),
        ),
        isTrue,
      );
      expect(
        (await operatorApp.operator.getSnapshot()).route.current.path,
        '/dashboard',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost delegates delayed dialog checks after route-changing taps',
    (tester) async {
      late OperatorApp operatorApp;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-route-tap-dialog-delegation-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            routes: <String, WidgetBuilder>{
              '/':
                  (context) => Scaffold(
                    body: Center(
                      child: ElevatedButton(
                        onPressed:
                            () => Navigator.of(context).pushNamed('/detail'),
                        child: const Text('Open detail'),
                      ),
                    ),
                  ),
              '/detail':
                  (_) => const Scaffold(body: Text('Detail route loaded')),
            },
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Open detail'),
          purpose: 'open_detail_route',
          risk: 1,
        ),
      );
      for (var i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(result.ok, isTrue, reason: result.error?.message);
      expect(
        result.evidence.map((entry) => entry.condition),
        contains('tap.dialog_check.delegated_to_route_settlement'),
      );
      expect(
        (await operatorApp.operator.getSnapshot()).route.current.path,
        '/detail',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost taps nearest child when label parent has no tap action',
    (tester) async {
      late OperatorApp operatorApp;
      var markedDone = false;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-parent-label-child-tap-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      children: <Widget>[
                        Text('markedDone=$markedDone'),
                        Semantics(
                          container: true,
                          explicitChildNodes: true,
                          label: 'Mark done',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() => markedDone = true),
                            child: const SizedBox(width: 72, height: 48),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Mark done'),
          purpose: 'mark_done',
          risk: 1,
        ),
      );
      for (var i = 0; i < 8; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(
        result.ok,
        isTrue,
        reason: result.error?.message ?? result.message,
      );
      expect(markedDone, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost rejects close controls that remain visible after content changes',
    (tester) async {
      late OperatorApp operatorApp;
      var closeLabel = 'Schließen';

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-close-control-truth-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      children: <Widget>[
                        const Text('Filter'),
                        const Text('Resident records'),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap:
                              () => setState(
                                () => closeLabel = 'Schließen geladen',
                              ),
                          child: Semantics(
                            label: closeLabel,
                            button: true,
                            child: SizedBox(
                              width: 120,
                              height: 48,
                              child: Center(child: Text(closeLabel)),
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Schließen'),
          purpose: 'close_filter_sheet',
          risk: 1,
        ),
      );
      for (var i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(closeLabel, 'Schließen geladen');
      expect(result.ok, isFalse);
      expect(result.error?.type, 'tap_effect_target_ambiguous');
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition == 'tap.target_effect.ambiguous' &&
              (entry.detail ?? '').contains('close control remained visible'),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost verifies close controls only when the close target disappears',
    (tester) async {
      late OperatorApp operatorApp;
      var sheetOpen = true;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-close-control-disappears-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      children: <Widget>[
                        const Text('Resident records'),
                        if (sheetOpen) ...<Widget>[
                          const Text('Filter'),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() => sheetOpen = false),
                            child: Semantics(
                              label: 'Schließen',
                              button: true,
                              child: SizedBox(
                                width: 120,
                                height: 48,
                                child: Center(child: Text('Schließen')),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Schließen'),
          purpose: 'close_filter_sheet',
          risk: 1,
        ),
      );
      for (var i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(sheetOpen, isFalse);
      expect(result.ok, isTrue, reason: result.error?.message);
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition == 'tap.target_effect.verified' &&
              ((entry.detail ?? '').contains('close target disappeared') ||
                  (entry.detail ?? '').contains(
                    'close control text disappeared',
                  )),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost waits for delayed close target disappearance without retapping',
    (tester) async {
      late OperatorApp operatorApp;
      var sheetOpen = true;
      var closeLabel = 'Schließen';
      var closeCalls = 0;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-delayed-close-settlement-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      children: <Widget>[
                        const Text('Resident records'),
                        if (sheetOpen) ...<Widget>[
                          const Text('Filter'),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              closeCalls += 1;
                              setState(() => closeLabel = 'Schließen läuft');
                              Future<void>.delayed(
                                const Duration(milliseconds: 650),
                                () => setState(() => sheetOpen = false),
                              );
                            },
                            child: Semantics(
                              label: closeLabel,
                              button: true,
                              child: SizedBox(
                                width: 140,
                                height: 48,
                                child: Center(child: Text(closeLabel)),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Schließen'),
          purpose: 'close_filter_sheet',
          risk: 1,
        ),
      );
      for (var i = 0; i < 24; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(sheetOpen, isFalse);
      expect(closeCalls, 1);
      expect(result.ok, isTrue, reason: result.error?.message);
      expect(
        result.evidence.map((entry) => entry.condition),
        contains('tap.deferred_target_effect.verified'),
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost reports matched disabled tap target as not actionable',
    (tester) async {
      late OperatorApp operatorApp;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-disabled-target-diagnostic-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: Semantics(
                identifier: 'profile-selector',
                label: 'Abrufen verfugbarer Profile...',
                enabled: false,
                textField: true,
                child: const SizedBox(width: 320, height: 56),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final result =
          (await tester.runAsync(
            () => operatorApp.binding.adapter.execute(
              const ActionCommand(
                type: OperatorActionType.tap,
                target: ElementTarget(id: 'profile-selector'),
                purpose: 'probe_disabled_profile',
                risk: 0,
              ),
            ),
          ))!;
      await tester.pump();

      expect(result.ok, isFalse);
      expect(result.error?.type, 'target_not_actionable');
      expect(result.data['operationPhase'], 'zero_dispatch');
      expect(result.error?.message, contains('disabled'));
      expect(result.error?.message, contains('no tap action'));
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition == 'tap.target_not_actionable' &&
              (entry.detail?.contains('profile-selector') ?? false),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost does not tap controls matched only by hint text',
    (tester) async {
      late OperatorApp operatorApp;
      var tapped = false;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-hint-only-tap-match-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: Semantics(
                label: 'Back',
                hint: 'Close',
                button: true,
                onTap: () => tapped = true,
                child: const SizedBox(width: 120, height: 48),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final result =
          (await tester.runAsync(
            () => operatorApp.binding.adapter.execute(
              const ActionCommand(
                type: OperatorActionType.tap,
                target: ElementTarget(text: 'Close'),
                purpose: 'qa_close',
                risk: 0,
              ),
            ),
          ))!;
      await tester.pump();

      expect(result.ok, isFalse);
      expect(result.error?.type, 'target_not_found');
      expect(tapped, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost prefers widget global bounds over misleading semantics bounds',
    (tester) async {
      late OperatorApp operatorApp;
      var fakeSemanticsTapped = false;
      var loginTapped = false;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-widget-global-tap-bounds-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      children: <Widget>[
                        Semantics(
                          label: 'Login',
                          button: true,
                          onTap:
                              () => setState(() => fakeSemanticsTapped = true),
                          child: const SizedBox(width: 320, height: 48),
                        ),
                        const TextField(
                          decoration: InputDecoration(labelText: 'Email'),
                        ),
                        const SizedBox(height: 160),
                        ElevatedButton(
                          onPressed: () => setState(() => loginTapped = true),
                          child: const Text('Login'),
                        ),
                        Text('fake=$fakeSemanticsTapped login=$loginTapped'),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Login'),
          purpose: 'qa_login',
          risk: 1,
        ),
      );
      for (var i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(
        result.ok,
        isTrue,
        reason: result.error?.message ?? result.message,
      );
      expect(fakeSemanticsTapped, isFalse);
      expect(loginTapped, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost exports nested semantics bounds in global coordinates',
    (tester) async {
      late OperatorApp operatorApp;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-global-semantics-bounds-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.only(left: 24, top: 220),
                child: Semantics(
                  label:
                      'Dokumentation Dokumentieren, Maßnahmen abzeichnen, Bewohnerdaten lesen',
                  button: true,
                  onTap: () {},
                  child: const SizedBox(width: 320, height: 128),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final snapshot = await operatorApp.operator.getSnapshot();
      final card = snapshot.ui.elements.singleWhere(
        (element) => element.label?.contains('Dokumentation') ?? false,
      );

      expect(card.bounds?.x, greaterThanOrEqualTo(24));
      expect(card.bounds?.y, greaterThanOrEqualTo(220));
      expect(card.bounds?.width, greaterThanOrEqualTo(300));
      expect(card.bounds?.height, greaterThanOrEqualTo(120));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost reports unrelated dialog after tap as interruption',
    (tester) async {
      late OperatorApp operatorApp;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-unexpected-dialog-tap-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder:
                    (context) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        showDialog<void>(
                          context: context,
                          builder:
                              (context) => AlertDialog(
                                title: const Text(
                                  'App-Berechtigungen erforderlich',
                                ),
                                content: const Text(
                                  'Benachrichtigungen Berechtigung aktivieren.',
                                ),
                                actions: <Widget>[
                                  TextButton(
                                    onPressed:
                                        () => Navigator.of(context).pop(),
                                    child: const Text('Abbrechen'),
                                  ),
                                ],
                              ),
                        );
                      },
                      child: const SizedBox(
                        width: 320,
                        height: 180,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Text('Dokumentation'),
                        ),
                      ),
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Dokumentation'),
          purpose: 'qa_open_documentation',
          risk: 1,
        ),
      );
      for (var i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);

      expect(result.ok, isFalse);
      expect(result.error?.type, 'tap_blocked_by_permission_prompt');
      expect(find.text('App-Berechtigungen erforderlich'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('OperatorAppHost refuses text tap on hint-only semantics match', (
    tester,
  ) async {
    late OperatorApp operatorApp;
    var tapped = false;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-unlabeled-semantics-target-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder:
                  (context, setState) => Semantics(
                    hint: 'Dokumentation',
                    button: true,
                    onTap: () => setState(() => tapped = true),
                    child: const SizedBox(width: 80, height: 80),
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final result =
        (await tester.runAsync(
          () => operatorApp.binding.adapter.execute(
            const ActionCommand(
              type: OperatorActionType.tap,
              target: ElementTarget(text: 'Dokumentation'),
              purpose: 'qa_open_documentation',
              risk: 1,
            ),
          ),
        ))!;
    await tester.pump();

    expect(result.ok, isFalse);
    expect(result.error?.type, 'target_not_found');
    expect(tapped, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('OperatorAppHost can tap small parent-labelled controls', (
    tester,
  ) async {
    late OperatorApp operatorApp;
    var openedQuickAction = false;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-small-tooltip-control-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder:
                  (context, setState) => Column(
                    children: <Widget>[
                      Text('openedQuickAction=$openedQuickAction'),
                      Align(
                        alignment: Alignment.topLeft,
                        child: Semantics(
                          label: 'Quick action',
                          container: true,
                          explicitChildNodes: true,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap:
                                () => setState(() => openedQuickAction = true),
                            child: Semantics(
                              button: true,
                              child: SizedBox(width: 50, height: 50),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final action = operatorApp.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(text: 'Quick action'),
        purpose: 'open_quick_action',
        risk: 0,
      ),
    );
    for (var i = 0; i < 12; i += 1) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final result = await _awaitActionWithPumps(tester, action);

    expect(result.ok, isTrue, reason: result.error?.message ?? result.message);
    expect(openedQuickAction, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'OperatorAppHost transfers a label to same-geometry semantic action',
    (tester) async {
      late OperatorApp operatorApp;
      var openedProfile = false;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-same-control-label-transfer-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Stack(
                      children: <Widget>[
                        Text('opened=$openedProfile'),
                        Align(
                          alignment: Alignment.topRight,
                          child: Semantics(
                            label: 'Mein Profil',
                            container: true,
                            explicitChildNodes: true,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => openedProfile = true),
                              child: Semantics(
                                button: true,
                                child: const SizedBox(width: 36, height: 116),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Mein Profil'),
          purpose: 'qa_open_profile_from_label_parent',
          risk: 0,
        ),
      );
      for (var i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(
        result.ok,
        isTrue,
        reason: result.error?.message ?? result.message,
      );
      expect(openedProfile, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('OperatorAppHost can tap fallback coordinates', (tester) async {
    late OperatorApp operatorApp;
    var taps = 0;

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-coordinate-fallback-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder:
                  (context, setState) => Align(
                    alignment: Alignment.topLeft,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        final nextTaps = taps + 1;
                        operatorApp.operator.captureStateChange(
                          source: OperatorStateSource.custom,
                          name: 'CoordinateFallbackState',
                          value: <String, Object?>{
                            'state': <String, Object?>{'taps': nextTaps},
                          },
                        );
                        setState(() => taps = nextTaps);
                      },
                      child: Semantics(
                        label: 'Resident row $taps',
                        child: const SizedBox(width: 120, height: 80),
                      ),
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final action = operatorApp.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.tap,
        target: ElementTarget(fallbackBounds: FallbackPoint(x: 60, y: 40)),
        purpose: 'tap_coordinate_fallback',
        risk: 1,
      ),
    );
    for (var i = 0; i < 12; i += 1) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final result = await _awaitActionWithPumps(tester, action);
    await tester.pump();

    expect(result.ok, isTrue);
    expect(taps, 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'OperatorAppHost uses fallback coordinates before ambiguous semantics tap',
    (tester) async {
      late OperatorApp operatorApp;
      var openedResident = false;
      var pinnedResident = false;
      const residentLabel = 'AG Hr. Adolph, Günter 329';

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-resident-row-target-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('opened=$openedResident pinned=$pinnedResident'),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => openedResident = true),
                          child: Semantics(
                            label: residentLabel,
                            button: true,
                            onTap: () => setState(() => pinnedResident = true),
                            child: SizedBox(
                              width: 360,
                              height: 72,
                              child: Row(
                                children: <Widget>[
                                  const Expanded(child: Text(residentLabel)),
                                  IconButton(
                                    tooltip: 'Pin $residentLabel',
                                    onPressed:
                                        () => setState(
                                          () => pinnedResident = true,
                                        ),
                                    icon: const Icon(Icons.push_pin),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(
            text: residentLabel,
            fallbackBounds: FallbackPoint(x: 80, y: 52),
          ),
          purpose: 'open_resident_row',
          risk: 1,
        ),
      );
      for (var i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(result.ok, isTrue);
      expect(openedResident, isTrue);
      expect(pinnedResident, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost prefers bounded row geometry before exact semantic action',
    (tester) async {
      late OperatorApp operatorApp;
      var openedResident = false;
      var pinnedResident = false;
      const residentLabel = 'AG Hr. Adolph, Günter 329';

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-row-geometry-before-semantics-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('opened=$openedResident pinned=$pinnedResident'),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => openedResident = true),
                          child: Semantics(
                            label: residentLabel,
                            button: true,
                            onTap: () => setState(() => pinnedResident = true),
                            child: const SizedBox(
                              width: 360,
                              height: 72,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(residentLabel),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: residentLabel),
          purpose: 'open_resident_row',
          risk: 1,
        ),
      );
      for (var i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(
        result.ok,
        isTrue,
        reason: result.error?.message ?? result.message,
      );
      expect(openedResident, isTrue);
      expect(pinnedResident, isFalse);
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition.contains('tap.pointer') &&
              (entry.detail?.contains('verified app change') ?? false),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost does not trust generated semantics ids as stable row action ids',
    (tester) async {
      late OperatorApp operatorApp;
      var openedResident = false;
      var pinnedResident = false;
      const residentLabel = 'Hr. Adolph, Günter 329';

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-generated-semantics-id-row-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('opened=$openedResident pinned=$pinnedResident'),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => openedResident = true),
                          child: Semantics(
                            label: residentLabel,
                            button: true,
                            onTap: () => setState(() => pinnedResident = true),
                            child: const SizedBox(
                              width: 360,
                              height: 72,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(residentLabel),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final row = (await operatorApp.operator.getSnapshot()).ui.elements
          .firstWhere(
            (element) => <Object?>[
              element.label,
              element.text,
              element.value,
            ].whereType<String>().any((value) => value.contains(residentLabel)),
          );
      expect(row.id, startsWith('flutter-semantics-'));

      final action = operatorApp.binding.adapter.execute(
        ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(id: row.id, text: residentLabel),
          purpose: 'open_resident_row',
          risk: 1,
        ),
      );
      for (var i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(
        result.ok,
        isTrue,
        reason: result.error?.message ?? result.message,
      );
      expect(openedResident, isTrue);
      expect(pinnedResident, isFalse);
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition.contains('tap.pointer') &&
              (entry.detail?.contains('verified app change') ?? false),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost rejects semantics-only controls as Flutter finger taps',
    (tester) async {
      late OperatorApp operatorApp;
      var opened = false;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-semantics-only-proxy-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Stack(
                      children: <Widget>[
                        Text('opened=$opened'),
                        Semantics(
                          label: 'Open panel',
                          button: true,
                          onTap: () => setState(() => opened = true),
                          child: const SizedBox.expand(),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Open panel'),
          purpose: 'open_panel',
          risk: 1,
        ),
      );
      for (var i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(
        result.ok,
        isFalse,
        reason: result.error?.message ?? result.message,
      );
      expect(opened, isFalse);
      expect(result.error?.type, 'tap_effect_unverified');
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition.contains('tap.pointer') &&
              (entry.detail?.contains('dispatching pointer tap') ?? false),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost blocks broad composite semantics actions without verified geometry',
    (tester) async {
      late OperatorApp operatorApp;
      var pinnedResident = false;
      const residentLabel = 'AG Hr. Adolph, Günter 329';

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-composite-row-semantic-guard-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('pinned=$pinnedResident'),
                        Semantics(
                          label: residentLabel,
                          button: true,
                          onTap: () => setState(() => pinnedResident = true),
                          child: SizedBox(
                            width: 360,
                            height: 72,
                            child: Row(
                              children: <Widget>[
                                const Expanded(child: Text(residentLabel)),
                                Semantics(
                                  button: true,
                                  onTap:
                                      () =>
                                          setState(() => pinnedResident = true),
                                  child: const SizedBox(width: 56, height: 56),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: residentLabel),
          purpose: 'open_resident_row_without_safe_geometry',
          risk: 1,
        ),
      );
      for (var i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(result.ok, isFalse);
      expect(result.error?.type, 'tap_effect_unverified');
      expect(pinnedResident, isFalse);
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition.contains('tap.semantics') &&
              (entry.detail?.contains('SemanticsAction.tap') ?? false),
        ),
        isFalse,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost does not transfer row text to contained sub-actions',
    (tester) async {
      late OperatorApp operatorApp;
      var pinnedResident = false;
      const residentLabel = 'AG Hr. Adolph, Günter 329';

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-contained-subaction-transfer-guard-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('pinned=$pinnedResident'),
                        SizedBox(
                          width: 360,
                          height: 72,
                          child: Stack(
                            children: <Widget>[
                              Positioned.fill(
                                child: Semantics(
                                  label: residentLabel,
                                  container: true,
                                  child: const SizedBox.expand(),
                                ),
                              ),
                              Positioned(
                                right: 8,
                                top: 8,
                                width: 56,
                                height: 56,
                                child: Semantics(
                                  button: true,
                                  onTap:
                                      () =>
                                          setState(() => pinnedResident = true),
                                  child: const SizedBox.expand(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: residentLabel),
          purpose: 'open_resident_row_without_safe_geometry',
          risk: 1,
        ),
      );
      for (var i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(result.ok, isFalse);
      expect(result.error?.type, 'target_bounds_untrusted');
      expect(result.data['operationPhase'], 'zero_dispatch');
      expect(pinnedResident, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost chooses hit-tested point inside labelled controls',
    (tester) async {
      late OperatorApp operatorApp;
      var opened = false;
      const selectorLabel = '-- Profil auswählen --';

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-labelled-control-pointer-retry-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      children: <Widget>[
                        Text('opened=$opened'),
                        Semantics(
                          container: true,
                          explicitChildNodes: true,
                          label: selectorLabel,
                          child: SizedBox(
                            width: 320,
                            height: 56,
                            child: Row(
                              children: <Widget>[
                                const Expanded(child: Text('Choose profile')),
                                ExcludeSemantics(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => setState(() => opened = true),
                                    child: const SizedBox(
                                      width: 96,
                                      height: 56,
                                      child: Icon(Icons.arrow_drop_down),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: selectorLabel),
          purpose: 'open_profile_selector',
          risk: 1,
        ),
      );
      for (var i = 0; i < 50; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(
        result.ok,
        isTrue,
        reason: result.error?.message ?? result.message,
      );
      expect(opened, isTrue);
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition.contains('tap.pointer') &&
              (entry.detail?.contains('hit=') ?? false),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost returns hit-test evidence for unverified coordinate taps',
    (tester) async {
      late OperatorApp operatorApp;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-unverified-coordinate-tap-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: const MaterialApp(
            home: Scaffold(body: Text('No action here')),
          ),
        ),
      );
      await tester.pump();

      final result =
          (await tester.runAsync(
            () => operatorApp.binding.adapter.execute(
              const ActionCommand(
                type: OperatorActionType.tap,
                target: ElementTarget(
                  fallbackBounds: FallbackPoint(x: 24, y: 24),
                ),
                purpose: 'tap_empty_space',
                risk: 1,
              ),
            ),
          ))!;
      await tester.pump();

      expect(result.ok, isFalse);
      expect(result.error?.type, 'tap_effect_unverified');
      expect(result.evidence, isNotEmpty);
      expect(result.evidence.first.detail, contains('hit='));
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition == 'tap.phase_timing' &&
              (entry.detail?.contains('totalMs=') ?? false) &&
              (entry.detail?.contains('pointer.wait_changeMs=') ?? false),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost delegates tap proof when explicit expected conditions exist',
    (tester) async {
      late OperatorApp operatorApp;
      var taps = 0;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-expected-tap-delegation-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    taps += 1;
                  },
                  child: const SizedBox(
                    width: 160,
                    height: 64,
                    child: Center(child: Text('Open resident')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Open resident'),
          purpose: 'open_resident_with_bridge_expected_route',
          risk: 1,
          expected: <VerificationCondition>[
            VerificationCondition(
              source: OperatorVerificationSource.route,
              path: '/resident-record-route',
            ),
          ],
        ),
      );

      final result = await _awaitActionWithPumps(tester, action, maxPumps: 12);
      await tester.pump();

      expect(result.ok, isTrue);
      expect(taps, 1);
      expect(
        result.evidence.any(
          (entry) => entry.condition == 'tap.expected_verification_delegated',
        ),
        isTrue,
      );
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition == 'tap.phase_timing' &&
              (entry.detail?.contains('pointer.wait_changeMs=') ?? false),
        ),
        isFalse,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost does not verify taps from ambient network or errors',
    (tester) async {
      late OperatorApp operatorApp;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-ambient-tap-verification-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(child: Text('1')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: '1'),
          purpose: 'tap_static_digit',
          risk: 1,
        ),
      );

      operatorApp.operator.networkAdapter.captureHttpResponse(
        id: 'ambient_background_request',
        method: 'GET',
        url: 'https://example.test/background',
        path: '/background',
        status: 200,
        ok: true,
      );
      operatorApp.operator.captureError(
        type: 'BackgroundError',
        message: 'background task failed',
        handled: true,
        fatal: false,
      );
      operatorApp.operator.captureStateChange(
        source: OperatorStateSource.inferred,
        name: 'TransientInkState',
        value: const <String, Object?>{
          'state': <String, Object?>{'pressed': true},
        },
      );

      for (var i = 0; i < 60; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(result.ok, isFalse);
      expect(result.error?.type, 'tap_effect_unverified');
      expect(result.evidence, isNotEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost accepts render-pointer target reaction and leaves readiness to stream',
    (tester) async {
      late OperatorApp operatorApp;
      var archived = false;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-semantic-target-effect-guard-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      children: <Widget>[
                        Text('archived=$archived'),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => archived = true),
                          child: Semantics(
                            label: 'Archive resident',
                            button: true,
                            child: SizedBox(
                              width: 180,
                              height: 48,
                              child: Center(child: Text('Archive resident')),
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Archive resident'),
          purpose: 'archive_resident',
          risk: 1,
        ),
      );
      for (var i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(archived, isTrue);
      expect(result.ok, isTrue, reason: result.error?.message);
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition == 'tap.target_effect.verified' &&
              ((entry.detail ?? '').contains(
                'live stream owns final readiness',
              )),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost accepts broad navigation card reaction and leaves readiness to stream',
    (tester) async {
      late OperatorApp operatorApp;
      var cardPressed = false;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-broad-navigation-card-target-effect-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  final label =
                      cardPressed
                          ? 'SIS Assistent wird geladen'
                          : 'SIS Assistent Erstelle automatisch eine SIS aus Gesprächen oder eigenen Aufnahmen';
                  return Center(
                    child: GestureDetector(
                      onTap: () => setState(() => cardPressed = true),
                      child: Semantics(
                        label: label,
                        button: true,
                        onTap: () => setState(() => cardPressed = true),
                        child: SizedBox(
                          width: 340,
                          height: 92,
                          child: Center(child: Text(label)),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'SIS Assistent'),
          purpose: 'open_sis_assistant',
          risk: 1,
        ),
      );
      for (var i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(cardPressed, isTrue);
      expect(result.ok, isTrue, reason: result.error?.message);
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition == 'tap.target_effect.verified' &&
              ((entry.detail ?? '').contains(
                'live stream owns final readiness',
              )),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost matches decorative leading badge target text to suffix labels',
    (tester) async {
      late OperatorApp operatorApp;
      var selected = false;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-decorative-leading-badge-target-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      children: <Widget>[
                        if (selected) const Text('Resident selected'),
                        GestureDetector(
                          onTap: () => setState(() => selected = true),
                          child: Semantics(
                            label: 'Hr. Adolph, Günter',
                            button: true,
                            onTap: () => setState(() => selected = true),
                            child: const SizedBox(
                              width: 220,
                              height: 56,
                              child: Center(child: Text('Hr. Adolph, Günter')),
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'AG Hr. Adolph, Günter'),
          purpose: 'select_resident',
          risk: 1,
        ),
      );
      for (var i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(
        selected,
        isTrue,
        reason:
            'result=${result.ok} error=${result.error?.type}:${result.error?.message}',
      );
      expect(result.ok, isTrue, reason: result.error?.message);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OperatorAppHost rejects delayed target disappearance as verified tap effect',
    (tester) async {
      late OperatorApp operatorApp;
      var menuOpen = true;

      await tester.pumpWidget(
        OperatorAppHost(
          config: const OperatorFlutterConfig(
            appId: 'flutter-target-disappearance-guard-test',
            environment: OperatorEnvironment.dev,
          ),
          onReady: (app) => operatorApp = app,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder:
                    (context, setState) => Column(
                      children: <Widget>[
                        Text(menuOpen ? 'menu=open' : 'menu=closed'),
                        if (menuOpen)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              Future<void>.delayed(
                                const Duration(milliseconds: 650),
                                () => setState(() => menuOpen = false),
                              );
                            },
                            child: Semantics(
                              label: 'Jewel',
                              button: true,
                              child: SizedBox(
                                width: 180,
                                height: 48,
                                child: Center(child: Text('Jewel')),
                              ),
                            ),
                          ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = operatorApp.binding.adapter.execute(
        const ActionCommand(
          type: OperatorActionType.tap,
          target: ElementTarget(text: 'Jewel'),
          purpose: 'select_profile_jewel',
          risk: 1,
        ),
      );
      for (var i = 0; i < 24; i += 1) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final result = await _awaitActionWithPumps(tester, action);
      await tester.pump();

      expect(menuOpen, isFalse);
      expect(result.ok, isFalse);
      expect(result.error?.type, 'tap_effect_target_ambiguous');
      expect(
        result.evidence.any(
          (entry) =>
              entry.condition == 'tap.target_effect.ambiguous' &&
              (entry.detail ?? '').contains('target disappeared'),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('OperatorAppHost scroll falls back to Scrollable widgets', (
    tester,
  ) async {
    late OperatorApp operatorApp;
    final controller = ScrollController();

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-scroll-fallback-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          home: Scaffold(
            body: ExcludeSemantics(
              child: ListView(
                controller: controller,
                children: <Widget>[
                  for (var index = 0; index < 60; index++)
                    SizedBox(height: 48, child: Text('Row $index')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(controller.offset, 0);

    final action = operatorApp.binding.adapter.execute(
      const ActionCommand(
        type: OperatorActionType.scroll,
        direction: 'up',
        purpose: 'scroll_content',
        risk: 1,
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    final result = await _awaitActionWithPumps(tester, action);

    expect(result.ok, isTrue);
    expect(result.message, contains('Scrollable'));
    expect(controller.offset, greaterThan(0));

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('OperatorAppHost injects forms into real TextFields', (
    tester,
  ) async {
    late OperatorApp operatorApp;
    final controller = TextEditingController();
    var changed = '';

    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'flutter-real-form-injection-test',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (app) => operatorApp = app,
        child: MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'Delivery address'),
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final result =
        (await tester.runAsync(
          () => operatorApp.binding.adapter.execute(
            const ActionCommand(
              type: OperatorActionType.injectForm,
              fields: <FormFieldPatch>[
                FormFieldPatch(
                  name: 'Delivery address',
                  value: '42 Test Avenue',
                ),
              ],
              purpose: 'inject_delivery_form',
              risk: 1,
            ),
          ),
        ))!;
    await tester.pump();

    expect(result.ok, isTrue);
    expect(controller.text, '42 Test Avenue');
    expect(changed, '42 Test Avenue');

    final missing =
        (await tester.runAsync(
          () => operatorApp.binding.adapter.execute(
            const ActionCommand(
              type: OperatorActionType.injectForm,
              fields: <FormFieldPatch>[
                FormFieldPatch(name: 'Missing field', value: 'not applied'),
              ],
              purpose: 'inject_missing_form',
              risk: 1,
            ),
          ),
        ))!;
    expect(missing.ok, isFalse);
    expect(missing.error?.type, 'form_field_not_found');
    expect(controller.text, '42 Test Avenue');

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'OperatorAppHost executes storage injection through automatic runtime',
    (tester) async {
      final previous = SharedPreferencesAsyncPlatform.instance;
      final store = _FakeSharedPreferencesAsyncPlatform();
      SharedPreferencesAsyncPlatform.instance = store;
      late OperatorApp operatorApp;

      try {
        await tester.pumpWidget(
          OperatorAppHost(
            config: const OperatorFlutterConfig(
              appId: 'flutter-host-storage-injection-test',
              environment: OperatorEnvironment.dev,
            ),
            onReady: (app) => operatorApp = app,
            child: const MaterialApp(home: Scaffold(body: Text('Storage'))),
          ),
        );
        await tester.pump();

        final result =
            (await tester.runAsync(
              () => operatorApp.binding.adapter.execute(
                const ActionCommand(
                  type: OperatorActionType.injectStorage,
                  area: 'sharedPreferences',
                  key: 'foodly.cachedProducts',
                  value: <String, Object?>{
                    'items': <Object?>[
                      <String, Object?>{
                        'id': 'p_mock',
                        'name': 'SDK Mocked Juice',
                      },
                    ],
                  },
                  purpose: 'inject_cache',
                  risk: 1,
                ),
              ),
            ))!;

        expect(result.ok, isTrue);
        expect(result.message, contains('persisted shared_preferences'));
        final preferences = SharedPreferencesAsync();
        expect(
          jsonDecode(
                await preferences.getString('foodly.cachedProducts') ?? '{}',
              )
              as Map<String, Object?>,
          containsPair('items', isA<List<Object?>>()),
        );

        final snapshot = await operatorApp.operator.getSnapshot();
        expect(
          snapshot.storage!.entries.any(
            (entry) =>
                entry.area == 'sharedPreferences' &&
                entry.key == 'foodly.cachedProducts',
          ),
          isTrue,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        SharedPreferencesAsyncPlatform.instance = previous;
      }
    },
  );

  test(
    'popular network adapters capture common Flutter client options',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-network-adapter-test',
          environment: OperatorEnvironment.dev,
        ),
      );

      operator.networkAdapter.captureDioResponse(
        id: 'net_inventory',
        method: 'GET',
        url: '/inventory/low-stock',
        path: '/inventory/low-stock',
        status: 200,
        ok: true,
        responseData: <String, Object?>{'count': 1},
      );
      operator.networkAdapter.captureHttpResponse(
        id: 'net_http',
        method: 'PATCH',
        url: '/inventory/items/RICE',
        path: '/inventory/items/RICE',
        status: 200,
        ok: true,
        requestBody: <String, Object?>{'quantity': 2},
        responseBody: <String, Object?>{'saved': true},
      );
      operator.networkAdapter.captureGraphQLResponse(
        id: 'net_graphql',
        endpoint: '/graphql',
        query: 'query Inventory { inventory { sku quantity } }',
        operationName: 'Inventory',
        status: 200,
        data: <String, Object?>{'inventory': <Object>[]},
      );
      operator.networkAdapter.captureRetrofitResponse(
        id: 'net_retrofit',
        method: 'GET',
        url: '/inventory/retrofit',
        path: '/inventory/retrofit',
        serviceMethod: 'InventoryApi.lowStock',
        status: 200,
        ok: true,
        responseBody: <String, Object?>{'count': 1},
      );
      operator.networkAdapter.captureChopperResponse(
        id: 'net_chopper',
        method: 'GET',
        url: '/inventory/chopper',
        path: '/inventory/chopper',
        status: 200,
        ok: true,
        responseBody: <String, Object?>{'count': 1},
      );
      operator.networkAdapter.captureWebSocketMessage(
        id: 'net_ws',
        url: 'wss://example.test/inventory',
        path: '/inventory',
        direction: 'inbound',
        message: <String, Object?>{'event': 'inventory.updated'},
      );
      operator.networkAdapter.captureHttpRequest(
        id: 'net_sensitive_request',
        method: 'POST',
        url: '/inventory/token-check',
        path: '/inventory/token-check',
        body: <String, Object?>{'token': 'secret-token'},
      );
      operator.captureUiTree(
        buildFlutterUiTree(
          rootId: 'inventory-root',
          viewport: const Size(390, 844),
          nodes: <OperatorUiNode>[
            operatorTextInputNode(
              id: 'inventory-search-input',
              label: 'Search inventory',
            ),
            operatorButtonNode(
              id: 'add-inventory-item-button',
              label: 'Add item',
            ),
          ],
        ),
      );

      final snapshot = await operator.getSnapshot();
      final eventsById = <String, NetworkEvent>{
        for (final event in snapshot.network.events) event.id: event,
      };

      expect(eventsById['net_inventory']?.request.path, '/inventory/low-stock');
      expect(eventsById['net_http']?.request.method, 'PATCH');
      expect(eventsById['net_graphql']?.response?.ok, isTrue);
      expect(
        (eventsById['net_retrofit']?.request.body as Map<String, Object?>),
        containsPair('serviceMethod', 'InventoryApi.lowStock'),
      );
      expect(eventsById['net_chopper']?.request.path, '/inventory/chopper');
      expect(eventsById['net_ws']?.request.method, 'WS');
      expect(
        eventsById['net_sensitive_request']?.request.body,
        containsPair('token', '[REDACTED]'),
      );
      expect(snapshot.redactions.fields, contains('token'));
      expect(
        snapshot.ui.elements.map((element) => element.id),
        containsAll(<String>[
          'inventory-search-input',
          'add-inventory-item-button',
        ]),
      );

      operator.dispose();
    },
  );

  test('production session recovers after transient polling failure', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-production-retry-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    operator.captureRoute(path: '/retry', name: 'retry');
    final adapter = OperatorFlutterAdapter(operator);
    final client = _FakeProductionHttpClient();

    final session = OperatorFlutterProductionSession(
      adapter: adapter,
      config: OperatorProductionSessionConfig(
        endpoint: Uri.parse('http://operator.test'),
        sessionId: 'retry-session',
        appId: 'flutter-production-retry-test',
        operatorControlConsent: true,
        pollWait: const Duration(milliseconds: 20),
      ),
      client: client,
    );

    await expectLater(
      session.pumpOnce(wait: const Duration(milliseconds: 20)),
      throwsA(isA<SocketException>()),
    );
    final commandCount = await session.pumpOnce(
      wait: const Duration(milliseconds: 20),
    );
    await session.publishSnapshot();

    await session.close();
    operator.dispose();

    expect(client.commandPolls, greaterThanOrEqualTo(2));
    expect(client.snapshots, greaterThanOrEqualTo(2));
    expect(commandCount, 0);
  });

  test(
    'production command polling failure does not force full reconnect',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-poll-no-reconnect-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final adapter = OperatorFlutterAdapter(operator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = true
            ..commandResponseDelay = const Duration(milliseconds: 10);

      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'poll-no-reconnect-session',
          appId: 'flutter-production-poll-no-reconnect-test',
          operatorControlConsent: true,
          pollWait: const Duration(milliseconds: 5),
          contextStreamInterval: const Duration(hours: 1),
        ),
        client: client,
      );

      await session.connect();
      expect(client.connects, 1);
      final loop = session.start();
      await _waitForCondition(() => client.commandPolls >= 2);
      await session.close();
      await loop.timeout(
        const Duration(milliseconds: 200),
        onTimeout: () async {},
      );
      final snapshot = await operator.getSnapshot();
      operator.dispose();

      expect(client.commandPolls, greaterThanOrEqualTo(2));
      expect(client.connects, 1);
      expect(
        snapshot.logs.map((log) => log.message),
        contains('operator production polling will retry after failure'),
      );
    },
  );

  test(
    'production session reconnects when command poll loses server session',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-poll-session-not-found-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final adapter = OperatorFlutterAdapter(operator);

      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'poll-session-not-found-session',
          appId: 'flutter-production-poll-session-not-found-test',
          operatorControlConsent: true,
          pollWait: const Duration(milliseconds: 5),
          contextStreamInterval: const Duration(hours: 1),
        ),
        client: _FakeProductionHttpClient(),
      );

      await session.close();
      operator.dispose();

      expect(
        session.shouldReconnectAfterPollingFailureForTest(
          const HttpException(
            'Operator production session failed: {error: session_not_found:abc}',
          ),
        ),
        isTrue,
      );
      expect(
        session.shouldReconnectAfterPollingFailureForTest(
          const SocketException('Connection closed before full header'),
        ),
        isFalse,
      );
    },
  );

  test(
    'production session continuously publishes live context snapshots',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-context-stream-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      operator.captureRoute(path: '/', name: 'splash');
      final adapter = OperatorFlutterAdapter(operator);
      final client = _FakeProductionHttpClient();

      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'context-stream-session',
          appId: 'flutter-production-context-stream-test',
          operatorControlConsent: true,
          pollWait: const Duration(milliseconds: 50),
          contextStreamInterval: const Duration(milliseconds: 10),
          runtimeEventDebounce: const Duration(milliseconds: 1),
        ),
        client: client,
      );

      final loop = session.start();
      await Future<void>.delayed(const Duration(milliseconds: 35));
      operator.captureRoute(path: '/login', name: 'login');
      await Future<void>.delayed(const Duration(milliseconds: 35));
      await session.close();
      await loop.timeout(
        const Duration(milliseconds: 200),
        onTimeout: () async {},
      );
      operator.dispose();

      final reasons =
          client.snapshotBodies
              .map((body) => body['reason'])
              .whereType<String>()
              .toList();
      expect(client.snapshots, greaterThanOrEqualTo(3));
      expect(reasons, contains('connect'));
      expect(reasons, contains('context_tick'));
      expect(client.snapshotBodies.last['clientPublishedAt'], isA<String>());
    },
  );

  test(
    'production command polling timeout retries instead of freezing loop',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-poll-timeout-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final adapter = OperatorFlutterAdapter(operator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commandResponseDelay = const Duration(milliseconds: 50)
            ..completeCommandCloseWithAbortErrorAfterAbort = true;
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'poll-timeout-session',
          appId: 'flutter-production-poll-timeout-test',
          operatorControlConsent: true,
          pollWait: const Duration(milliseconds: 1),
          requestTimeout: const Duration(milliseconds: 5),
          contextStreamInterval: const Duration(hours: 1),
        ),
        client: client,
      );

      await session.connect();
      final loop = session.start();
      await _waitForCondition(() => client.commandPolls >= 2);
      await session.close();
      await loop.timeout(
        const Duration(milliseconds: 200),
        onTimeout: () async {},
      );
      final snapshot = await operator.getSnapshot();
      operator.dispose();

      expect(client.commandPolls, greaterThanOrEqualTo(2));
      expect(client.abortedRequests, greaterThanOrEqualTo(1));
      expect(
        snapshot.logs.map((log) => log.message),
        contains('operator production polling will retry after failure'),
      );
      expect(snapshot.errors, isEmpty);
    },
  );

  test('production session clamps local dev command polling wait', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-local-dev-poll-clamp-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final adapter = OperatorFlutterAdapter(operator);
    final client = _FakeProductionHttpClient()..failFirstCommandPoll = false;
    final session = OperatorFlutterProductionSession(
      adapter: adapter,
      config: OperatorProductionSessionConfig(
        endpoint: Uri.parse('http://127.0.0.1:8791'),
        sessionId: 'local-dev-poll-clamp-session',
        appId: 'flutter-local-dev-poll-clamp-test',
        operatorControlConsent: true,
        pollWait: const Duration(seconds: 15),
      ),
      client: client,
    );

    session.reportCommandPollingHealthForTest();
    await session.pumpOnce(wait: session.effectiveCommandPollWaitForTest);
    await session.close();
    final snapshot = await operator.getSnapshot();
    operator.dispose();

    expect(client.commandPollWaits.first, 500);
    expect(
      snapshot.logs.map((log) => log.message),
      contains('operator local dev command polling interval reduced'),
    );
    expect(
      snapshot.logs.where(
        (log) => log.message == 'operator command polling interval is high',
      ),
      isEmpty,
    );
  });

  test('production session caps localhost command retry backoff', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-local-dev-retry-cap-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final adapter = OperatorFlutterAdapter(operator);
    final localSession = OperatorFlutterProductionSession(
      adapter: adapter,
      config: OperatorProductionSessionConfig(
        endpoint: Uri.parse('http://127.0.0.1:8791'),
        sessionId: 'local-dev-retry-cap-session',
        appId: 'flutter-local-dev-retry-cap-test',
        operatorControlConsent: true,
      ),
      client: _FakeProductionHttpClient(),
    );
    final remoteSession = OperatorFlutterProductionSession(
      adapter: adapter,
      config: OperatorProductionSessionConfig(
        endpoint: Uri.parse('https://operator.example.test'),
        sessionId: 'remote-retry-cap-session',
        appId: 'flutter-local-dev-retry-cap-test',
        operatorControlConsent: true,
      ),
      client: _FakeProductionHttpClient(),
    );

    expect(
      localSession.retryDelayForFailureCountForTest(20),
      const Duration(seconds: 2),
    );
    expect(
      remoteSession.retryDelayForFailureCountForTest(20),
      const Duration(seconds: 16),
    );

    await localSession.close();
    await remoteSession.close();
    operator.dispose();
  });

  test(
    'production session preserves remote high command polling warning',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-remote-poll-warning-test',
          environment: OperatorEnvironment.production,
        ),
      );
      final adapter = OperatorFlutterAdapter(operator);
      final client = _FakeProductionHttpClient()..failFirstCommandPoll = false;
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('https://operator.example.test'),
          sessionId: 'remote-poll-warning-session',
          appId: 'flutter-remote-poll-warning-test',
          operatorControlConsent: true,
          pollWait: const Duration(seconds: 15),
        ),
        client: client,
      );

      session.reportCommandPollingHealthForTest();
      await session.pumpOnce(wait: session.effectiveCommandPollWaitForTest);
      await session.close();
      final snapshot = await operator.getSnapshot();
      operator.dispose();

      expect(client.commandPollWaits.first, 15000);
      expect(
        snapshot.logs.map((log) => log.message),
        contains('operator command polling interval is high'),
      );
      expect(
        snapshot.logs.where(
          (log) =>
              log.message ==
              'operator local dev command polling interval reduced',
        ),
        isEmpty,
      );
    },
  );

  test(
    'production session applies connect setup actions before first snapshot',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-connect-setup-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final adapter = OperatorFlutterAdapter(operator);
      final client =
          _FakeProductionHttpClient()
            ..connectSetupActions.add(<String, Object?>{
              'type': 'install_network_mock',
              'match': <String, Object?>{'method': 'GET', 'path': '/startup'},
              'response': <String, Object?>{
                'status': 503,
                'body': 'startup mocked',
              },
              'purpose': 'connect_setup_network_mock',
              'risk': 0,
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'connect-setup-session',
          appId: 'flutter-production-connect-setup-test',
          operatorControlConsent: true,
        ),
        client: client,
      );

      await session.connect();
      final mock = operator.findNetworkMock(
        const NetworkRequest(
          method: 'GET',
          url: 'https://api.example.test/startup',
          path: '/startup',
        ),
      );
      final snapshot = await operator.getSnapshot();

      await session.close();
      operator.dispose();

      expect(mock?.status, 503);
      expect(mock?.body, 'startup mocked');
      expect(client.snapshots, 1);
      expect(
        snapshot.logs.map((log) => log.message),
        contains('operator connect setup actions applied'),
      );
    },
  );

  test(
    'production session retries compact snapshot after upload failure',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-compact-snapshot-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      operator.captureRoute(path: '/large-snapshot', name: 'largeSnapshot');
      for (var index = 0; index < 45; index++) {
        operator.captureNetworkResponse(
          id: 'network_$index',
          request: networkRequest(
            method: 'GET',
            url: 'https://api.example.test/items/$index',
            path: '/items/$index',
          ),
          status: 200,
          ok: true,
        );
      }
      operator.captureVisualFrame(
        VisualFrame(
          id: 'small-frame',
          format: 'png',
          width: 390,
          height: 844,
          source: 'test',
          redacted: false,
          encoding: 'base64',
          data: base64Encode(List<int>.filled(128 * 1024, 7)),
        ),
      );
      operator.captureVisualFrame(
        VisualFrame(
          id: 'large-frame',
          format: 'png',
          width: 390,
          height: 844,
          source: 'test',
          redacted: false,
          encoding: 'base64',
          data: base64Encode(List<int>.filled(800 * 1024, 8)),
        ),
      );
      final adapter = OperatorFlutterAdapter(operator);
      final client = _FakeProductionHttpClient()..failNextSnapshotUpload = true;
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'compact-snapshot-session',
          appId: 'flutter-production-compact-snapshot-test',
        ),
        client: client,
      );

      await session.publishSnapshot();

      await session.close();
      operator.dispose();

      expect(client.snapshots, 2);
      final retriedSnapshot =
          client.snapshotBodies.last['snapshot'] as Map<String, Object?>;
      final visual = retriedSnapshot['visual'] as Map<String, Object?>;
      final frames = visual['frames'] as List<Object?>;
      final smallFrame = frames.cast<Map<String, Object?>>().firstWhere(
        (frame) => frame['id'] == 'small-frame',
      );
      expect(smallFrame['metadataOnly'], isFalse);
      expect(smallFrame['data'], isA<String>());
      expect(smallFrame.containsKey('dataOmitted'), isFalse);
      final largeFrame = frames.cast<Map<String, Object?>>().firstWhere(
        (frame) => frame['id'] == 'large-frame',
      );
      expect(largeFrame['metadataOnly'], isTrue);
      expect(largeFrame.containsKey('data'), isFalse);
      expect(largeFrame['dataOmitted'], 'too_large_for_snapshot_upload');
      final network = retriedSnapshot['network'] as Map<String, Object?>;
      final networkEvents = network['events'] as List<Object?>;
      expect(networkEvents, hasLength(40));
      expect(
        ((networkEvents.first as Map<String, Object?>)['request']
            as Map<String, Object?>)['path'],
        '/items/5',
      );
      expect(
        ((networkEvents.last as Map<String, Object?>)['request']
            as Map<String, Object?>)['path'],
        '/items/44',
      );
      expect(
        networkEvents.every(
          (event) =>
              event is Map<String, Object?> &&
              event['request'] is Map<String, Object?> &&
              (event['request'] as Map<String, Object?>)['method'] == 'GET',
        ),
        isTrue,
      );
      expect(
        networkEvents.any(
          (event) => event is Map<String, Object?> && event['omitted'] == true,
        ),
        isFalse,
      );
    },
  );

  test(
    'production compact snapshot lists the numbers JSON cannot carry where they are sent',
    () async {
      final operator = await _operatorHoldingUnreadableNumbers(
        'flutter-production-unreadable-compact-test',
      );
      final client = _FakeProductionHttpClient()..failNextSnapshotUpload = true;
      final session = OperatorFlutterProductionSession(
        adapter: OperatorFlutterAdapter(operator),
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'unreadable-compact-session',
          appId: 'flutter-production-unreadable-compact-test',
        ),
        client: client,
      );

      await session.publishSnapshot();

      await session.close();
      operator.dispose();

      expect(client.snapshots, 2);
      _expectUnreadableValuesWhereSent(
        client.snapshotBodies.last['snapshot'] as JsonMap,
        providers: true,
      );
    },
  );

  test(
    'production snapshot stream transient failures stay debug-level',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-snapshot-stream-noise-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final adapter = OperatorFlutterAdapter(operator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..failNextSnapshotUpload = false;
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'snapshot-stream-noise-session',
          appId: 'flutter-production-snapshot-stream-noise-test',
        ),
        client: client,
      );

      await session.publishRuntimeSnapshotForTest(reason: 'runtime_event');
      client.failNextSnapshotUpload = true;
      await session.publishRuntimeSnapshotForTest(reason: 'runtime_event');
      await session.publishRuntimeSnapshotForTest(reason: 'runtime_event');
      final snapshot = await operator.getSnapshot();

      await session.close();
      operator.dispose();

      final failureLogs =
          snapshot.logs
              .where(
                (log) =>
                    log.message ==
                    'operator production snapshot stream upload failed',
              )
              .toList();
      expect(failureLogs, hasLength(1));
      expect(failureLogs.single.level, 'debug');
      expect(failureLogs.single.source, OperatorLogSource.operatorRuntime);
      expect(failureLogs.single.data, containsPair('retryable', true));
      expect(
        snapshot.logs.where(
          (log) =>
              log.message ==
              'operator production snapshot stream upload recovered',
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'production snapshot upload timeout returns control to context loop',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-snapshot-timeout-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final adapter = OperatorFlutterAdapter(operator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..completeSnapshotCloseWithAbortErrorAfterAbort = true;
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'snapshot-timeout-session',
          appId: 'flutter-production-snapshot-timeout-test',
          contextPublishTimeout: const Duration(milliseconds: 5),
          requestTimeout: const Duration(milliseconds: 250),
        ),
        client: client,
      );

      await session.connect();
      client.snapshotCloseDelay = const Duration(milliseconds: 50);
      await session
          .publishRuntimeSnapshotForTest(reason: 'runtime_event')
          .timeout(const Duration(milliseconds: 200));
      final snapshot = await operator.getSnapshot();

      await session.close();
      operator.dispose();

      expect(client.abortedRequests, greaterThanOrEqualTo(1));
      expect(
        snapshot.logs.map((log) => log.message),
        contains('operator production snapshot stream upload failed'),
      );
      expect(snapshot.errors, isEmpty);
    },
  );

  test(
    'production snapshot stream detaches stalled publish and sends fresh context',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-snapshot-stall-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final adapter = OperatorFlutterAdapter(operator);
      final client = _FakeProductionHttpClient()..failFirstCommandPoll = false;
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'snapshot-stall-session',
          appId: 'flutter-production-snapshot-stall-test',
          contextPublishTimeout: const Duration(milliseconds: 20),
          requestTimeout: const Duration(seconds: 5),
        ),
        client: client,
      );
      final firstBlocker = Completer<void>();
      client.snapshotCloseBlocker = firstBlocker;

      await session.publishRuntimeSnapshotForTest(reason: 'context_tick');
      final afterTimeout = await operator.getSnapshot();
      client.snapshotCloseBlocker = null;
      operator.captureRoute(path: '/fresh-context', name: 'freshContext');
      await session.publishRuntimeSnapshotForTest(reason: 'runtime_event');
      firstBlocker.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final afterFreshPublish = await operator.getSnapshot();

      await session.close();
      operator.dispose();

      expect(client.snapshots, greaterThanOrEqualTo(2));
      expect(
        afterTimeout.logs.map((log) => log.message),
        contains('operator production snapshot stream upload failed'),
      );
      expect(
        afterFreshPublish.logs.map((log) => log.message),
        contains('operator production snapshot stream upload recovered'),
      );
      final uploadedRoutes =
          client.snapshotBodies
              .map((body) => body['snapshot'])
              .whereType<Map<String, Object?>>()
              .map((snapshot) => snapshot['route'])
              .whereType<Map<String, Object?>>()
              .map((route) => route['current'])
              .whereType<Map<String, Object?>>()
              .map((current) => current['path'])
              .toList();
      expect(uploadedRoutes, contains('/fresh-context'));
    },
  );

  test(
    'production session bundles post-command snapshot with command result',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-result-fallback-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      operator.captureRoute(path: '/before', name: 'before');
      final adapter = OperatorFlutterAdapter(operator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_result_fallback',
              'action': <String, Object?>{
                'type': 'navigate',
                'path': '/after',
                'mode': 'router',
                'purpose': 'result_fallback_regression',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'result-fallback-session',
          appId: 'flutter-production-result-fallback-test',
          commandResultUploadTimeout: const Duration(milliseconds: 20),
        ),
        client: client,
      );

      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      expect(client.results, 1);
      expect(client.resultBodies.last['commandId'], 'cmd_result_fallback');
      expect(client.resultBodies.last.containsKey('snapshot'), isTrue);
      final snapshot =
          client.resultBodies.last['snapshot'] as Map<String, Object?>;
      final route = snapshot['route'] as Map<String, Object?>;
      final current = route['current'] as Map<String, Object?>;
      expect(current['path'], '/after');
      final result = client.resultBodies.last['result'] as Map<String, Object?>;
      expect(result['ok'], isTrue);
      final evidence = result['evidence'] as List<Object?>;
      expect(
        evidence.any(
          (entry) =>
              entry is Map<String, Object?> &&
              entry['condition'] == 'command.result_snapshot',
        ),
        isTrue,
      );
      expect(
        client.snapshotBodies.any((body) => body['reason'] == 'command_result'),
        isFalse,
      );
    },
  );

  test(
    'production command result snapshot lists the numbers JSON cannot carry where they are sent',
    () async {
      final operator = await _operatorHoldingUnreadableNumbers(
        'flutter-production-unreadable-result-test',
      );
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_unreadable_result',
              'action': <String, Object?>{
                'type': 'navigate',
                'path': '/after',
                'mode': 'router',
                'purpose': 'unreadable_values_regression',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: OperatorFlutterAdapter(operator),
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'unreadable-result-session',
          appId: 'flutter-production-unreadable-result-test',
          commandResultUploadTimeout: const Duration(milliseconds: 250),
        ),
        client: client,
      );

      await session.connect();
      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await _waitForCondition(() => client.resultBodies.isNotEmpty);

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      _expectUnreadableValuesWhereSent(
        client.resultBodies.single['snapshot'] as JsonMap,
        providers: false,
      );
    },
  );

  test(
    'production command result holding a number JSON cannot carry lists it',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-unreadable-action-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final adapter = OperatorFlutterAdapter(
        operator,
        actuator: _EndlessListScrollActuator(),
      );
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_endless_scroll',
              'action': <String, Object?>{
                'type': 'scroll',
                'direction': 'down',
                'amount': '100',
                'container': <String, Object?>{'id': 'endless-list'},
                'purpose': 'unreadable_values_regression',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'unreadable-action-session',
          appId: 'flutter-production-unreadable-action-test',
        ),
        client: client,
      );

      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await session.drainResultUploadsForTest();

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      final result = client.resultBodies.single['result'] as JsonMap;
      expect(result['ok'], isTrue);
      expect(((result['data'] as JsonMap)['scroll'] as JsonMap)['max'], isNull);
      // The result lists it itself: the host keeps the result, not the upload.
      expect(
        (result['unreadableValues'] as JsonMap)['values'],
        contains(
          allOf(
            containsPair('path', r'$.data.scroll.max'),
            containsPair('value', 'Infinity'),
          ),
        ),
      );
    },
  );

  test(
    'production command result does not use racing follow-up snapshot upload',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-result-priority-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_snapshot_block',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'result_priority_regression',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'result-priority-session',
          appId: 'flutter-production-result-priority-test',
          commandResultUploadTimeout: const Duration(milliseconds: 250),
        ),
        client: client,
      );

      final pump = session.pumpOnce(wait: const Duration(milliseconds: 1));
      final commandCount = await pump.timeout(
        const Duration(milliseconds: 500),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      expect(client.results, 1);
      expect(client.resultBodies.last['commandId'], 'cmd_snapshot_block');
      expect(client.resultBodies.last.containsKey('snapshot'), isTrue);
      expect(
        client.snapshotBodies.where(
          (body) => body['reason'] == 'command_result',
        ),
        isEmpty,
      );
    },
  );

  test(
    'production capture_visual uploads the exact one-shot provider observation',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-capture-visual-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      operator.captureVisualFrame(
        const VisualFrame(
          id: 'stale-production-frame',
          format: 'png',
          width: 390,
          height: 844,
          source: 'manual',
          redacted: false,
          encoding: 'base64',
          data: 'iVBORw0KGgoAAAANSUhEUgAAAYYAAANM',
        ),
      );
      var providerCalls = 0;
      operator.addVisualFrameProvider(() async {
        providerCalls += 1;
        return const VisualFrame(
          id: 'current-production-frame',
          format: 'png',
          width: 390,
          height: 844,
          source: 'manual',
          redacted: false,
          encoding: 'base64',
          data: 'iVBORw0KGgoAAAANSUhEUgAAAYYAAANM',
        );
      });
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_capture_visual_exact',
              'action': <String, Object?>{
                'type': 'capture_visual',
                'reason': 'one-shot Flutter production pixels',
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: OperatorFlutterAdapter(operator),
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'capture-visual-exact-session',
          appId: 'flutter-production-capture-visual-test',
          commandResultUploadTimeout: const Duration(milliseconds: 250),
        ),
        client: client,
      );

      await session.connect();
      final providerCallsBeforeCommand = providerCalls;
      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await _waitForCondition(() => client.resultBodies.isNotEmpty);

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      expect(providerCalls - providerCallsBeforeCommand, 1);
      final result = client.resultBodies.single['result'] as JsonMap;
      expect(result['ok'], isTrue);
      final snapshot = client.resultBodies.single['snapshot'] as JsonMap;
      final visual = snapshot['visual'] as JsonMap;
      final frames = (visual['frames'] as List<Object?>).cast<JsonMap>();
      expect(frames, hasLength(1));
      expect(frames.single['id'], contains('current-production-frame'));
      expect(frames.single['id'], isNot('stale-production-frame'));
      final analysis = visual['analysis'] as JsonMap;
      expect(analysis['hasUsablePixels'], isTrue);
    },
  );

  test(
    'production capture_visual selects two useful providers and reports transport omissions',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-capture-selection-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      String validPngPayload(int byteLength) {
        final bytes = List<int>.filled(byteLength, 0);
        final header = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAYYAAANM');
        bytes.setRange(0, header.length, header);
        return base64Encode(bytes);
      }

      operator.addVisualFrameProvider(
        () async => const VisualFrame(
          id: 'weak-provider-frame',
          format: 'png',
          width: 1,
          height: 1,
          source: 'manual',
          redacted: false,
          encoding: 'base64',
          data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB',
        ),
      );
      operator.addVisualFrameProvider(
        () async => VisualFrame(
          id: 'strong-redacted-provider-frame',
          format: 'png',
          width: 390,
          height: 844,
          source: 'manual',
          redacted: true,
          encoding: 'base64',
          data: validPngPayload(1024 * 1024),
        ),
      );
      operator.addVisualFrameProvider(
        () async => VisualFrame(
          id: 'coverage-provider-frame',
          format: 'png',
          width: 390,
          height: 844,
          source: 'manual',
          redacted: false,
          encoding: 'base64',
          data: validPngPayload(16 * 1024),
        ),
      );
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_capture_visual_selection',
              'action': <String, Object?>{
                'type': 'capture_visual',
                'reason': 'select useful Flutter capture providers',
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: OperatorFlutterAdapter(operator),
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'capture-visual-selection-session',
          appId: 'flutter-production-capture-selection-test',
          commandResultUploadTimeout: const Duration(milliseconds: 250),
        ),
        client: client,
      );

      await session.connect();
      expect(await session.pumpOnce(wait: const Duration(milliseconds: 1)), 1);
      await _waitForCondition(() => client.resultBodies.isNotEmpty);

      final result = client.resultBodies.single['result'] as JsonMap;
      final data = result['data'] as JsonMap;
      final summary = data['visualCapture'] as JsonMap;
      expect(summary['complete'], isFalse);
      expect(summary['transportOmittedFrameCount'], 1);
      final snapshot = client.resultBodies.single['snapshot'] as JsonMap;
      final visual = snapshot['visual'] as JsonMap;
      final frames = (visual['frames'] as List<Object?>).cast<JsonMap>();
      expect(frames, hasLength(2));
      expect(
        frames.any(
          (frame) => (frame['id'] as String).contains(
            'strong-redacted-provider-frame',
          ),
        ),
        isTrue,
      );
      expect(
        frames.any(
          (frame) =>
              (frame['id'] as String).contains('coverage-provider-frame'),
        ),
        isTrue,
      );
      final redacted = frames.firstWhere(
        (frame) =>
            (frame['id'] as String).contains('strong-redacted-provider-frame'),
      );
      expect(redacted['redacted'], isTrue);
      expect(redacted['data'], isA<String>());
      expect(
        frames.any(
          (frame) => (frame['id'] as String).contains('weak-provider-frame'),
        ),
        isFalse,
      );
      final retained = await operator.getSnapshot(
        refreshVisual: false,
        refreshProviders: false,
      );
      expect(
        retained.visual?.frames.every((frame) => frame.data == null),
        isTrue,
      );

      await session.close();
      operator.dispose();
    },
  );

  test(
    'production session does not block explicit expected command results on snapshots',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-expected-result-priority-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_expected_snapshot_deferred',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'expected_result_priority_regression',
                'risk': 0,
                'expected': <Object?>[
                  <String, Object?>{
                    'source': 'route',
                    'path': '/resident-record-route',
                  },
                ],
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'expected-result-priority-session',
          appId: 'flutter-production-expected-result-priority-test',
        ),
        client: client,
      );

      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await _waitForCondition(() => client.results == 1);
      await _waitForCondition(
        () => client.snapshotBodies.any(
          (body) => body['reason'] == 'command_result',
        ),
      );

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      expect(actuator.calls, 1);
      expect(
        client.resultBodies.last['commandId'],
        'cmd_expected_snapshot_deferred',
      );
      expect(client.resultBodies.last.containsKey('snapshot'), isFalse);
      final result = client.resultBodies.last['result'] as Map<String, Object?>;
      final evidence = result['evidence'] as List<Object?>;
      expect(
        evidence.any(
          (entry) =>
              entry is Map<String, Object?> &&
              entry['condition'] == 'command.result_snapshot_deferred',
        ),
        isTrue,
      );
      expect(
        client.snapshotBodies.any((body) => body['reason'] == 'command_result'),
        isTrue,
      );
    },
  );

  test(
    'production session can use a dedicated command result client',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-result-lane-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final controlClient =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_result_lane',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'result_lane_regression',
                'risk': 0,
              },
            });
      final resultClient = _FakeProductionHttpClient();
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'result-lane-session',
          appId: 'flutter-production-result-lane-test',
        ),
        client: controlClient,
        resultClient: resultClient,
      );

      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      expect(actuator.calls, 1);
      expect(controlClient.commandPolls, 1);
      expect(controlClient.results, 0);
      expect(resultClient.results, 1);
      expect(resultClient.resultBodies.last['commandId'], 'cmd_result_lane');
      expect(resultClient.resultBodies.last.containsKey('snapshot'), isTrue);
      final resultClientTiming =
          resultClient.resultBodies.last['clientTiming']
              as Map<String, Object?>;
      expect(resultClientTiming['uploadAttempt'], 1);
      expect(resultClientTiming['uploadAttemptStartedAt'], isA<String>());
      expect(resultClientTiming['clientOpenMs'], isA<int>());
      expect(resultClientTiming['completedToUploadStartMs'], isA<int>());
      expect(resultClientTiming['uploadStartedAt'], isA<String>());
      expect(
        DateTime.tryParse(
          resultClientTiming['uploadAttemptStartedAt']! as String,
        ),
        isNotNull,
      );
      expect(
        DateTime.tryParse(resultClientTiming['uploadStartedAt']! as String),
        isNotNull,
      );
      expect(
        controlClient.snapshotBodies.any(
          (body) => body['reason'] == 'command_result',
        ),
        isFalse,
      );
    },
  );

  test(
    'production session uploads owned command results from a background isolate',
    () async {
      final resultBodies = <Map<String, Object?>>[];
      var commandDelivered = false;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      late final StreamSubscription<HttpRequest> subscription;
      subscription = server.listen((request) async {
        final path = request.uri.path;
        if (path.endsWith('/connect')) {
          await _readRequestJson(request);
          _writeJson(request, <String, Object?>{
            'ok': true,
            'session': <String, Object?>{
              'appMap': <String, Object?>{'status': 'available'},
            },
            'transport': <String, Object?>{
              'resultPost': true,
              'resultPostAck': true,
              'resultStream': false,
              'resultStreamAck': false,
            },
          });
          return;
        }
        if (path.endsWith('/snapshot')) {
          await _readRequestJson(request);
          _writeJson(request, <String, Object?>{'ok': true});
          return;
        }
        if (path.endsWith('/commands')) {
          _writeJson(request, <String, Object?>{
            'commands':
                commandDelivered
                    ? <Object?>[]
                    : <Object?>[
                      <String, Object?>{
                        'commandId': 'cmd_background_result_post',
                        'action': <String, Object?>{
                          'type': 'tap',
                          'target': <String, Object?>{'id': 'counted-target'},
                          'purpose': 'background_result_post_regression',
                          'risk': 0,
                        },
                      },
                    ],
          });
          commandDelivered = true;
          return;
        }
        if (path.endsWith('/results')) {
          resultBodies.add(await _readRequestJson(request));
          _writeJson(request, <String, Object?>{'ok': true});
          return;
        }
        _writeJson(request, <String, Object?>{
          'error': 'not_found',
        }, statusCode: HttpStatus.notFound);
      });
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-background-result-post-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://${server.address.host}:${server.port}'),
          sessionId: 'background-result-post-session',
          appId: 'flutter-production-background-result-post-test',
        ),
      );

      try {
        final commandCount = await session.pumpOnce(
          wait: const Duration(milliseconds: 1),
        );
        await session.drainResultUploadsForTest();
        await _waitForCondition(() => resultBodies.isNotEmpty);

        expect(commandCount, 1);
        expect(actuator.calls, 1);
        expect(resultBodies.single['commandId'], 'cmd_background_result_post');
        final resultClientTiming =
            resultBodies.single['clientTiming'] as Map<String, Object?>;
        expect(resultClientTiming['resultTransport'], 'post_isolate');
        expect(resultClientTiming['resultUploadIsolate'], true);
        expect(resultClientTiming['clientOpenMs'], isA<int>());
        expect(resultClientTiming['completedToUploadStartMs'], isA<int>());
        expect(resultClientTiming['uploadStartedAt'], isA<String>());
      } finally {
        await session.close();
        operator.dispose();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'production session reuses owned command result client after successful uploads',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-result-client-reuse-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final controlClient =
          _FakeProductionHttpClient()..failFirstCommandPoll = false;
      final commandClient =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_result_reuse_1',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'result_reuse_regression_1',
                'risk': 0,
              },
            });
      final resultClients = <_FakeProductionHttpClient>[];
      _FakeProductionHttpClient resultClientFactory() {
        final client =
            _FakeProductionHttpClient()..failFirstCommandPoll = false;
        resultClients.add(client);
        return client;
      }

      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'result-client-reuse-session',
          appId: 'flutter-production-result-client-reuse-test',
        ),
        client: controlClient,
        commandClient: commandClient,
        resultClientFactory: resultClientFactory,
      );

      final firstCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      commandClient.commands.add(<String, Object?>{
        'commandId': 'cmd_result_reuse_2',
        'action': <String, Object?>{
          'type': 'tap',
          'target': <String, Object?>{'id': 'counted-target'},
          'purpose': 'result_reuse_regression_2',
          'risk': 0,
        },
      });
      final secondCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await session.drainResultUploadsForTest();

      expect(firstCount, 1);
      expect(secondCount, 1);
      expect(actuator.calls, 2);
      expect(resultClients, hasLength(1));
      expect(resultClients.single.results, 2);
      expect(resultClients.single.closedForce, isFalse);
      expect(
        resultClients.single.resultBodies.map((body) => body['commandId']),
        containsAll(<String>['cmd_result_reuse_1', 'cmd_result_reuse_2']),
      );

      await session.close();
      operator.dispose();

      expect(resultClients.single.closedForce, isTrue);
    },
  );

  test(
    'production session uses acked POST when unacked result stream is advertised',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-result-stream-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..supportsResultStream = true
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_result_stream_1',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'result_stream_regression_1',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'result-stream-session',
          appId: 'flutter-production-result-stream-test',
        ),
        client: client,
      );

      final firstCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      client.commands.add(<String, Object?>{
        'commandId': 'cmd_result_stream_2',
        'action': <String, Object?>{
          'type': 'tap',
          'target': <String, Object?>{'id': 'counted-target'},
          'purpose': 'result_stream_regression_2',
          'risk': 0,
        },
      });
      final secondCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await session.drainResultUploadsForTest();

      await session.close();
      operator.dispose();

      expect(firstCount, 1);
      expect(secondCount, 1);
      expect(actuator.calls, 2);
      expect(client.resultStreams, 0);
      expect(client.resultStreamFlushes, 0);
      expect(client.resultUploadAttempts, 2);
      expect(client.results, 2);
      expect(
        client.resultBodies.map((body) => body['commandId']),
        containsAll(<String>['cmd_result_stream_1', 'cmd_result_stream_2']),
      );
      final resultClientTiming =
          client.resultBodies.last['clientTiming'] as Map<String, Object?>;
      expect(resultClientTiming['resultTransport'], 'post');
      expect(resultClientTiming['clientOpenMs'], isA<int>());
      expect(resultClientTiming['uploadStartedAt'], isA<String>());
    },
  );

  test(
    'production session keeps local dev command results on acked POST',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-local-dev-result-stream-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..supportsResultStream = true
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_local_dev_result_stream',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'local_dev_result_stream_regression',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://127.0.0.1:8791'),
          sessionId: 'local-dev-result-stream-session',
          appId: 'flutter-local-dev-result-stream-test',
        ),
        client: client,
      );

      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await session.drainResultUploadsForTest();

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      expect(actuator.calls, 1);
      expect(client.resultStreams, 0);
      expect(client.resultStreamFlushes, 0);
      expect(client.resultUploadAttempts, 1);
      expect(client.results, 1);
      final resultClientTiming =
          client.resultBodies.single['clientTiming'] as Map<String, Object?>;
      expect(resultClientTiming['resultTransport'], 'post');
      expect(resultClientTiming['streamFallbackMs'], isNull);
    },
  );

  test(
    'production session ignores unacked result stream instead of hedging blind flush',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-result-stream-fallback-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..supportsResultStream = true
            ..resultStreamFlushDelay = const Duration(seconds: 3)
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_result_stream_fallback',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'result_stream_fallback_regression',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'result-stream-fallback-session',
          appId: 'flutter-production-result-stream-fallback-test',
        ),
        client: client,
      );

      final stopwatch = Stopwatch()..start();
      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await session.drainResultUploadsForTest();
      stopwatch.stop();
      await Future<void>.delayed(const Duration(milliseconds: 900));

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      expect(actuator.calls, 1);
      expect(client.resultStreams, 0);
      expect(client.resultStreamFlushes, 0);
      expect(client.resultUploadAttempts, 1);
      expect(client.results, 1);
      expect(stopwatch.elapsedMilliseconds, lessThan(1500));
      expect(
        client.resultBodies.single['commandId'],
        'cmd_result_stream_fallback',
      );
      final resultClientTiming =
          client.resultBodies.single['clientTiming'] as Map<String, Object?>;
      expect(resultClientTiming['resultTransport'], 'post');
      expect(resultClientTiming['streamHedgeDelayMs'], isNull);
    },
  );

  test(
    'production session can use a dedicated command polling client',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-command-lane-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final controlClient =
          _FakeProductionHttpClient()..failFirstCommandPoll = false;
      final commandClient =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_command_lane',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'command_lane_regression',
                'risk': 0,
              },
            });
      final resultClient = _FakeProductionHttpClient();
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'command-lane-session',
          appId: 'flutter-production-command-lane-test',
        ),
        client: controlClient,
        commandClient: commandClient,
        resultClient: resultClient,
      );

      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      expect(actuator.calls, 1);
      expect(controlClient.commandPolls, 0);
      expect(commandClient.commandPolls, 1);
      expect(resultClient.results, 1);
      expect(resultClient.resultBodies.last['commandId'], 'cmd_command_lane');
      expect(resultClient.resultBodies.last.containsKey('snapshot'), isTrue);
      expect(
        controlClient.snapshotBodies.any(
          (body) => body['reason'] == 'command_result',
        ),
        isFalse,
      );
    },
  );

  test(
    'production session retries transient command result upload failures',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-result-retry-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..resultUploadFailuresRemaining = 1
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_result_retry',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'result_retry_regression',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'result-retry-session',
          appId: 'flutter-production-result-retry-test',
          commandResultUploadTimeout: const Duration(milliseconds: 250),
        ),
        client: client,
      );

      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await session.drainResultUploadsForTest();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final logs =
          (await operator.getSnapshot()).logs
              .where(
                (log) =>
                    log.message == 'operator command result upload will retry',
              )
              .toList();

      expect(commandCount, 1);
      expect(actuator.calls, 1);
      expect(client.resultUploadAttempts, 2);
      expect(client.results, 1);
      expect(client.resultBodies.last['commandId'], 'cmd_result_retry');
      expect(logs, hasLength(1));
      expect(logs.single.level, 'debug');
      expect(logs.single.source, OperatorLogSource.operatorRuntime);
      expect(logs.single.data, containsPair('retryable', true));

      await session.close();
      operator.dispose();
    },
  );

  test(
    'production session keeps polling while command result upload is pending',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-result-background-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..resultCloseDelay = const Duration(milliseconds: 250)
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_background_result_1',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'background_result_regression_1',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'result-background-session',
          appId: 'flutter-production-result-background-test',
          commandResultUploadTimeout: const Duration(seconds: 1),
        ),
        client: client,
      );
      final stopwatch = Stopwatch()..start();

      final firstCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      final firstElapsedMs = stopwatch.elapsedMilliseconds;
      client.commands.add(<String, Object?>{
        'commandId': 'cmd_background_result_2',
        'action': <String, Object?>{
          'type': 'tap',
          'target': <String, Object?>{'id': 'counted-target'},
          'purpose': 'background_result_regression_2',
          'risk': 0,
        },
      });
      final secondCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await session.drainResultUploadsForTest();

      await session.close();
      operator.dispose();

      expect(firstCount, 1);
      expect(secondCount, 1);
      expect(firstElapsedMs, lessThan(200));
      expect(actuator.calls, 2);
      expect(client.commandPolls, 2);
      expect(client.results, 2);
      expect(
        client.resultBodies.map((body) => body['commandId']),
        containsAll(<String>[
          'cmd_background_result_1',
          'cmd_background_result_2',
        ]),
      );
    },
  );

  test(
    'production session recycles owned command result client after failure',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-result-recycle-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final controlClient =
          _FakeProductionHttpClient()..failFirstCommandPoll = false;
      final commandClient =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_result_recycle',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'result_recycle_regression',
                'risk': 0,
              },
            });
      final resultClients = <_FakeProductionHttpClient>[];
      _FakeProductionHttpClient resultClientFactory() {
        final client =
            _FakeProductionHttpClient()..failFirstCommandPoll = false;
        if (resultClients.isEmpty) {
          client.resultUploadFailuresRemaining = 1;
        }
        resultClients.add(client);
        return client;
      }

      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'result-recycle-session',
          appId: 'flutter-production-result-recycle-test',
          commandResultUploadTimeout: const Duration(milliseconds: 250),
        ),
        client: controlClient,
        commandClient: commandClient,
        resultClientFactory: resultClientFactory,
      );

      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await session.drainResultUploadsForTest();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final logs =
          (await operator.getSnapshot()).logs
              .where(
                (log) =>
                    log.message == 'operator command result transport recycled',
              )
              .toList();

      expect(commandCount, 1);
      expect(actuator.calls, 1);
      expect(resultClients, hasLength(2));
      expect(resultClients.first.closedForce, isTrue);
      expect(resultClients.first.results, 0);
      expect(resultClients.last.results, 1);
      expect(
        resultClients.last.resultBodies.last['commandId'],
        'cmd_result_recycle',
      );
      expect(logs, hasLength(1));
      expect(logs.single.source, OperatorLogSource.operatorRuntime);

      await session.close();
      operator.dispose();
    },
  );

  test('production session expands local dev command result timeout', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'flutter-local-dev-result-timeout-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    final actuator = _CountingFlutterActuator();
    final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
    final client =
        _FakeProductionHttpClient()
          ..failFirstCommandPoll = false
          ..resultCloseDelay = const Duration(milliseconds: 100)
          ..completeResultCloseWithAbortErrorAfterAbort = true
          ..commands.add(<String, Object?>{
            'commandId': 'cmd_local_dev_result_timeout',
            'action': <String, Object?>{
              'type': 'tap',
              'target': <String, Object?>{'id': 'counted-target'},
              'purpose': 'local_dev_result_timeout_regression',
              'risk': 0,
            },
          });
    final session = OperatorFlutterProductionSession(
      adapter: adapter,
      config: OperatorProductionSessionConfig(
        endpoint: Uri.parse('http://127.0.0.1:8791'),
        sessionId: 'local-dev-result-timeout-session',
        appId: 'flutter-local-dev-result-timeout-test',
        commandResultUploadTimeout: const Duration(milliseconds: 5),
      ),
      client: client,
    );

    final commandCount = await session.pumpOnce(
      wait: const Duration(milliseconds: 1),
    );
    await session.drainResultUploadsForTest();
    final snapshot = await operator.getSnapshot();

    await session.close();
    operator.dispose();

    expect(commandCount, 1);
    expect(actuator.calls, 1);
    expect(session.effectiveCommandResultUploadTimeoutForTest.inSeconds, 10);
    expect(client.resultUploadAttempts, 1);
    expect(client.abortedRequests, 0);
    expect(client.results, 1);
    expect(
      snapshot.logs.map((log) => log.message),
      contains('operator local dev command result timeout increased'),
    );
    expect(
      snapshot.logs.where(
        (log) => log.message == 'operator command result upload will retry',
      ),
      isEmpty,
    );
  });

  test(
    'production session expands local dev command execution timeout',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-local-dev-execution-timeout-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator(
        delay: const Duration(milliseconds: 20),
      );
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_local_dev_execution_timeout',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'local_dev_execution_timeout_regression',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://127.0.0.1:8791'),
          sessionId: 'local-dev-execution-timeout-session',
          appId: 'flutter-local-dev-execution-timeout-test',
          commandExecutionTimeout: const Duration(milliseconds: 5),
        ),
        client: client,
      );

      session.reportCommandPollingHealthForTest();
      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await session.drainResultUploadsForTest();
      final snapshot = await operator.getSnapshot();

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      expect(actuator.calls, 1);
      expect(session.effectiveCommandExecutionTimeoutForTest.inSeconds, 20);
      expect(client.results, 1);
      expect(
        (client.resultBodies.last['result'] as Map<String, Object?>)['ok'],
        isTrue,
      );
      expect(
        snapshot.logs.map((log) => log.message),
        contains('operator local dev command execution timeout increased'),
      );
    },
  );

  test(
    'production session applies command result upload timeout to whole request',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-result-timeout-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..resultCloseDelay = const Duration(milliseconds: 20)
            ..completeResultCloseWithAbortErrorAfterAbort = true
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_result_total_timeout',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'result_total_timeout_regression',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'result-total-timeout-session',
          appId: 'flutter-production-result-timeout-test',
          commandResultUploadTimeout: const Duration(milliseconds: 5),
        ),
        client: client,
      );
      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await session.drainResultUploadsForTest();

      final snapshot = await operator.getSnapshot();

      await session.close();
      operator.dispose();

      expect(commandCount, 1);
      expect(actuator.calls, 1);
      expect(client.resultUploadAttempts, 3);
      expect(client.abortedRequests, 3);
      expect(snapshot.errors, isEmpty);
      expect(
        snapshot.logs.map((log) => log.message),
        contains('operator late transport abort drained'),
      );
      expect(
        snapshot.logs.map((log) => log.message),
        contains('operator command result upload exhausted'),
      );
    },
  );

  test(
    'production session reuploads cached result for redelivered command id',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-command-idempotency-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final command = <String, Object?>{
        'commandId': 'cmd_duplicate_delivery',
        'action': <String, Object?>{
          'type': 'tap',
          'target': <String, Object?>{'id': 'counted-target'},
          'purpose': 'duplicate_delivery_regression',
          'risk': 0,
        },
      };
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(command);
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'command-idempotency-session',
          appId: 'flutter-production-command-idempotency-test',
        ),
        client: client,
      );

      final firstCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      client.commands.add(command);
      final secondCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await session.close();
      operator.dispose();

      expect(firstCount, 1);
      expect(secondCount, 1);
      expect(actuator.calls, 1);
      expect(client.results, 2);
      expect(
        client.resultBodies
            .map((body) => body['commandId'])
            .where((id) => id == 'cmd_duplicate_delivery'),
        hasLength(2),
      );
      expect(
        client.resultBodies
            .map((body) => body['result'] as Map<String, Object?>)
            .map((result) => result['message'])
            .where((message) => message == 'count=1'),
        hasLength(2),
      );
    },
  );

  test(
    'production session uploads invalid command result and keeps polling loop alive',
    () async {
      final operator = await OperatorFlutter.init(
        const OperatorFlutterConfig(
          appId: 'flutter-production-invalid-command-test',
          environment: OperatorEnvironment.dev,
        ),
      );
      final actuator = _CountingFlutterActuator();
      final adapter = OperatorFlutterAdapter(operator, actuator: actuator);
      final client =
          _FakeProductionHttpClient()
            ..failFirstCommandPoll = false
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_invalid_expected_source',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'invalid_expected_source_regression',
                'risk': 0,
                'expected': <Object?>[
                  <String, Object?>{'source': 'text', 'text': 'Bad source'},
                ],
              },
            })
            ..commands.add(<String, Object?>{
              'commandId': 'cmd_valid_after_invalid',
              'action': <String, Object?>{
                'type': 'tap',
                'target': <String, Object?>{'id': 'counted-target'},
                'purpose': 'valid_after_invalid_regression',
                'risk': 0,
              },
            });
      final session = OperatorFlutterProductionSession(
        adapter: adapter,
        config: OperatorProductionSessionConfig(
          endpoint: Uri.parse('http://operator.test'),
          sessionId: 'invalid-command-session',
          appId: 'flutter-production-invalid-command-test',
        ),
        client: client,
      );

      final commandCount = await session.pumpOnce(
        wait: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await session.close();
      operator.dispose();

      expect(commandCount, 2);
      expect(actuator.calls, 1);
      expect(client.results, 2);
      final invalid =
          client.resultBodies.firstWhere(
                (body) => body['commandId'] == 'cmd_invalid_expected_source',
              )['result']
              as Map<String, Object?>;
      final valid =
          client.resultBodies.firstWhere(
                (body) => body['commandId'] == 'cmd_valid_after_invalid',
              )['result']
              as Map<String, Object?>;
      expect(invalid['ok'], isFalse);
      expect(invalid['error'], containsPair('type', 'invalid_command'));
      expect(valid['ok'], isTrue);
      expect(valid['message'], 'count=1');
    },
  );
}

Future<ActionResult> _awaitActionWithPumps(
  WidgetTester tester,
  Future<ActionResult> action, {
  int maxPumps = 240,
}) async {
  ActionResult? result;
  Object? error;
  StackTrace? stackTrace;
  var completed = false;
  unawaited(
    action.then(
      (value) {
        result = value;
        completed = true;
      },
      onError: (Object caught, StackTrace caughtStack) {
        error = caught;
        stackTrace = caughtStack;
        completed = true;
      },
    ),
  );

  for (var i = 0; i < maxPumps && !completed; i += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!completed) {
    fail('Operator action did not complete after ${maxPumps * 50}ms');
  }
  if (error != null) {
    Error.throwWithStackTrace(error!, stackTrace ?? StackTrace.current);
  }
  return result!;
}

Future<void> _waitForCondition(
  bool Function() read, {
  Duration timeout = const Duration(milliseconds: 500),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!read()) {
    if (stopwatch.elapsed > timeout) {
      throw TimeoutException('condition was not met within $timeout', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// An operator holding numbers JSON cannot carry in app state, in storage, in
/// the oldest log (which an uploaded snapshot's compaction drops) and in the
/// newest log (which it keeps, at a new index).
Future<OperatorFlutter> _operatorHoldingUnreadableNumbers(String appId) async {
  final operator = await OperatorFlutter.init(
    OperatorFlutterConfig(appId: appId, environment: OperatorEnvironment.dev),
  );
  operator.addStateProvider(
    () => const <StateStoreSnapshot>[
      StateStoreSnapshot(
        source: OperatorStateSource.inferred,
        name: 'ProgressState',
        value: <String, Object?>{'ratio': double.nan},
        confidence: 0.8,
        redacted: false,
      ),
    ],
  );
  operator.addStorageProvider(
    () => const <StorageEntrySnapshot>[
      StorageEntrySnapshot(
        area: 'shared_preferences',
        key: 'progress',
        metadataOnly: false,
        redacted: false,
        value: <String, Object?>{'ratio': double.infinity},
      ),
    ],
  );
  operator.captureLog(
    'debug',
    'dropped by compaction',
    data: <String, Object?>{'ratio': double.nan},
  );
  for (var index = 0; index < 60; index++) {
    operator.captureLog('debug', 'filler $index');
  }
  operator.captureLog(
    'debug',
    'kept by compaction',
    data: <String, Object?>{'ratio': double.nan},
  );
  return operator;
}

/// The uploaded [snapshot] lists exactly the numbers JSON cannot carry that it
/// still holds, each at the path where it sits in the snapshot as sent.
/// [providers] is whether the snapshot read the state and storage providers:
/// a command result snapshot does not refresh them.
void _expectUnreadableValuesWhereSent(
  JsonMap snapshot, {
  required bool providers,
}) {
  final logs = (snapshot['logs'] as List<Object?>).cast<JsonMap>();
  expect(
    logs.map((log) => log['message']),
    isNot(contains('dropped by compaction')),
  );
  final kept = logs.indexWhere((log) => log['message'] == 'kept by compaction');
  final paths = <String>['\$.logs[$kept].data.ratio'];
  if (providers) {
    final state = (snapshot['state'] as List<Object?>)
        .cast<JsonMap>()
        .indexWhere((store) => store['name'] == 'ProgressState');
    final entry = ((snapshot['storage'] as JsonMap)['entries'] as List<Object?>)
        .cast<JsonMap>()
        .indexWhere((entry) => entry['key'] == 'progress');
    paths
      ..add('\$.state[$state].value.ratio')
      ..add('\$.storage.entries[$entry].value.ratio');
  }
  expect(
    ((snapshot['unreadableValues'] as JsonMap)['values'] as List<Object?>).map(
      (value) => (value as JsonMap)['path'],
    ),
    unorderedEquals(paths),
  );
}

Future<Map<String, Object?>> _readRequestJson(HttpRequest request) async {
  final text = await utf8.decoder.bind(request).join();
  if (text.trim().isEmpty) return <String, Object?>{};
  return jsonDecode(text) as Map<String, Object?>;
}

void _writeJson(
  HttpRequest request,
  Map<String, Object?> body, {
  int statusCode = HttpStatus.ok,
}) {
  request.response
    ..statusCode = statusCode
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  unawaited(request.response.close());
}

class _FakeProductionHttpClient implements HttpClient {
  var connects = 0;
  var commandPolls = 0;
  var snapshots = 0;
  var results = 0;
  var resultStreams = 0;
  var resultStreamFlushes = 0;
  var resultUploadAttempts = 0;
  var failFirstCommandPoll = true;
  var supportsResultStream = false;
  var failNextSnapshotUpload = false;
  var resultUploadFailuresRemaining = 0;
  var abortedRequests = 0;
  var closedForce = false;
  var completeCommandCloseWithAbortErrorAfterAbort = false;
  var completeSnapshotCloseWithAbortErrorAfterAbort = false;
  var completeResultCloseWithAbortErrorAfterAbort = false;
  Duration openUrlDelay = Duration.zero;
  Duration commandResponseDelay = Duration.zero;
  Duration snapshotCloseDelay = Duration.zero;
  Duration resultCloseDelay = Duration.zero;
  Duration resultResponseDelay = Duration.zero;
  Duration resultStreamFlushDelay = Duration.zero;
  Completer<void>? snapshotCloseBlocker;
  Completer<void>? commandResultSnapshotStarted;
  Completer<void>? commandResultSnapshotBlocker;
  final connectSetupActions = <Map<String, Object?>>[];
  final commands = <Map<String, Object?>>[];
  final commandPollWaits = <int?>[];
  final snapshotBodies = <Map<String, Object?>>[];
  final resultBodies = <Map<String, Object?>>[];

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (openUrlDelay > Duration.zero) {
      await Future<void>.delayed(openUrlDelay);
    }
    if (url.path.endsWith('/results-stream')) {
      resultStreams += 1;
    }
    return _FakeProductionHttpClientRequest(this, method, url);
  }

  @override
  void close({bool force = false}) {
    closedForce = force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingHttpOverrides extends HttpOverrides {
  var createClientCalls = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    createClientCalls += 1;
    throw StateError('app HttpOverrides must not create control-plane clients');
  }
}

class _CountingFlutterActuator implements OperatorFlutterActuator {
  _CountingFlutterActuator({this.delay = Duration.zero});

  final Duration delay;
  var calls = 0;

  @override
  Future<ActionResult?> execute(
    ActionCommand command,
    OperatorFlutter operator,
  ) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    calls += 1;
    operator.captureRoute(path: '/count-$calls', name: 'count-$calls');
    return ActionResult(ok: true, action: command, message: 'count=$calls');
  }
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

class _FakeProductionHttpClientRequest implements HttpClientRequest {
  _FakeProductionHttpClientRequest(this.client, this.method, this.uri);

  final _FakeProductionHttpClient client;
  final _bodyBytes = <int>[];
  var _aborted = false;

  @override
  bool bufferOutput = true;

  @override
  final String method;

  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  void add(List<int> data) {
    _bodyBytes.addAll(data);
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _aborted = true;
    client.abortedRequests += 1;
  }

  @override
  Future<HttpClientResponse> close() async {
    if (uri.path.endsWith('/connect')) {
      client.connects += 1;
      return _FakeProductionHttpClientResponse(
        jsonEncode(<String, Object?>{
          'session': <String, Object?>{
            'appMap': <String, Object?>{'status': 'available'},
            if (client.connectSetupActions.isNotEmpty)
              'setupActions': client.connectSetupActions,
          },
          if (client.supportsResultStream)
            'transport': <String, Object?>{'resultStream': true},
        }),
      );
    }
    if (uri.path.endsWith('/snapshot')) {
      client.snapshots += 1;
      if (client.snapshotCloseDelay > Duration.zero) {
        await Future<void>.delayed(client.snapshotCloseDelay);
      }
      await client.snapshotCloseBlocker?.future;
      if (_aborted && client.completeSnapshotCloseWithAbortErrorAfterAbort) {
        throw const HttpException('Request has been aborted');
      }
      final snapshotBody =
          jsonDecode(utf8.decode(_bodyBytes)) as Map<String, Object?>;
      client.snapshotBodies.add(snapshotBody);
      if (snapshotBody['reason'] == 'command_result') {
        final started = client.commandResultSnapshotStarted;
        if (started != null && !started.isCompleted) started.complete();
        await client.commandResultSnapshotBlocker?.future;
      }
      if (client.failNextSnapshotUpload) {
        client.failNextSnapshotUpload = false;
        return _FakeProductionHttpClientResponse(
          jsonEncode(<String, Object?>{'error': 'payload_too_large'}),
          statusCode: HttpStatus.requestEntityTooLarge,
        );
      }
      return _FakeProductionHttpClientResponse(
        jsonEncode(<String, Object?>{'ok': true}),
      );
    }
    if (uri.path.endsWith('/commands')) {
      client.commandPolls += 1;
      client.commandPollWaits.add(
        int.tryParse(uri.queryParameters['waitMs'] ?? ''),
      );
      if (client.commandResponseDelay > Duration.zero) {
        await Future<void>.delayed(client.commandResponseDelay);
      }
      if (_aborted && client.completeCommandCloseWithAbortErrorAfterAbort) {
        throw const HttpException('Request has been aborted');
      }
      if (client.failFirstCommandPoll && client.commandPolls == 1) {
        throw const SocketException(
          'Connection closed before full header was received',
        );
      }
      final commands = List<Map<String, Object?>>.from(client.commands);
      client.commands.clear();
      return _FakeProductionHttpClientResponse(
        jsonEncode(<String, Object?>{'commands': commands}),
      );
    }
    if (uri.path.endsWith('/results')) {
      client.resultUploadAttempts += 1;
      if (client.resultUploadFailuresRemaining > 0) {
        client.resultUploadFailuresRemaining -= 1;
        throw const SocketException('simulated result upload failure');
      }
      if (client.resultCloseDelay > Duration.zero) {
        await Future<void>.delayed(client.resultCloseDelay);
      }
      if (_aborted && client.completeResultCloseWithAbortErrorAfterAbort) {
        throw const HttpException('Request has been aborted');
      }
      client.results += 1;
      client.resultBodies.add(
        jsonDecode(utf8.decode(_bodyBytes)) as Map<String, Object?>,
      );
      return _FakeProductionHttpClientResponse(
        jsonEncode(<String, Object?>{'ok': true}),
        chunkDelay: client.resultResponseDelay,
      );
    }
    if (uri.path.endsWith('/results-stream')) {
      return _FakeProductionHttpClientResponse(
        jsonEncode(<String, Object?>{'ok': true}),
      );
    }
    return _FakeProductionHttpClientResponse(
      jsonEncode(<String, Object?>{'error': 'not_found'}),
      statusCode: HttpStatus.notFound,
    );
  }

  @override
  Future<void> flush() async {
    if (!uri.path.endsWith('/results-stream')) return;
    client.resultStreamFlushes += 1;
    if (client.resultStreamFlushDelay > Duration.zero) {
      await Future<void>.delayed(client.resultStreamFlushDelay);
    }
    if (_aborted) return;
    final text = utf8.decode(_bodyBytes);
    _bodyBytes.clear();
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      client.results += 1;
      client.resultBodies.add(jsonDecode(trimmed) as Map<String, Object?>);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProductionHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeProductionHttpClientResponse(
    String body, {
    this.statusCode = 200,
    this.chunkDelay = Duration.zero,
  }) : _body = utf8.encode(body);

  final List<int> _body;
  final Duration chunkDelay;

  @override
  final int statusCode;

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final stream = Stream<List<int>>.fromIterable(<List<int>>[_body]);
    return (chunkDelay > Duration.zero
            ? stream.asyncMap((chunk) async {
              await Future<void>.delayed(chunkDelay);
              return chunk;
            })
            : stream)
        .listen(
          onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError,
        );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, Object> _values = <String, Object>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value;
  }

  @override
  String? value(String name) => _values[name.toLowerCase()]?.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _InventoryBloc {}

class _InventoryCubit {}

class _InventoryNotifier {}

class _InventoryValueNotifier {}

class _InventoryGetXController {}

class _InventoryMobXStore {}

class _InventoryChangeNotifier extends ChangeNotifier {}

class _OperatorInventoryCubit extends Cubit<_OperatorInventoryState> {
  _OperatorInventoryCubit()
    : super(const _OperatorInventoryState(sku: 'COKE', quantity: 1));

  void setQuantity(int quantity) {
    emit(_OperatorInventoryState(sku: state.sku, quantity: quantity));
  }
}

class _OperatorInventoryState {
  const _OperatorInventoryState({required this.sku, required this.quantity});

  final String sku;
  final int quantity;

  Map<String, Object?> toJson() => <String, Object?>{
    'sku': sku,
    'quantity': quantity,
  };
}

class _InventoryProviderModel {
  const _InventoryProviderModel({required this.count});

  final int count;

  Map<String, Object?> toJson() => <String, Object?>{'count': count};
}

class _InventoryRiverpodModel {
  const _InventoryRiverpodModel({required this.filter});

  final String filter;

  Map<String, Object?> toJson() => <String, Object?>{'filter': filter};
}

class _InventoryGetXControllerState {
  const _InventoryGetXControllerState({required this.total});

  final int total;

  Map<String, Object?> toJson() => <String, Object?>{'total': total};
}

class _FakeInheritedProvider extends InheritedWidget {
  const _FakeInheritedProvider({required this.value, required super.child});

  final _InventoryProviderModel value;

  @override
  bool updateShouldNotify(_FakeInheritedProvider oldWidget) => false;
}

class _FakeRiverpodProviderScope extends StatelessWidget {
  const _FakeRiverpodProviderScope({required this.value, required this.child});

  final _InventoryRiverpodModel value;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _FakeGetXControllerWidget extends StatelessWidget {
  const _FakeGetXControllerWidget({
    required this.controller,
    required this.child,
  });

  final _InventoryGetXControllerState controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _AutomaticStateHarness extends StatelessWidget {
  const _AutomaticStateHarness({
    required this.listenable,
    required this.notifier,
    required this.textController,
  });

  final ValueNotifier<int> listenable;
  final _InventoryChangeNotifier notifier;
  final TextEditingController textController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            const Text('Automatic state harness'),
            _CounterSetStateScreen(listenable: listenable),
            ValueListenableBuilder<int>(
              valueListenable: listenable,
              builder: (context, value, _) => Text('Selected $value'),
            ),
            TextField(controller: textController),
            _NotifierView(notifier: notifier),
          ],
        ),
      ),
    );
  }
}

class _CounterSetStateScreen extends StatefulWidget {
  const _CounterSetStateScreen({required this.listenable});

  final ValueNotifier<int> listenable;

  @override
  State<_CounterSetStateScreen> createState() => _CounterSetStateScreenState();
}

class _CounterSetStateScreenState extends State<_CounterSetStateScreen> {
  var _count = 0;

  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) {
    return '_CounterSetStateScreenState(count=$_count)';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        setState(() => _count += 1);
        widget.listenable.value = widget.listenable.value;
      },
      child: Text('Increment $_count'),
    );
  }
}

class _NotifierView extends AnimatedWidget {
  const _NotifierView({required _InventoryChangeNotifier notifier})
    : super(listenable: notifier);

  @override
  Widget build(BuildContext context) => const Text('Notifier ready');
}

class _FakeAutoRouteConfiguration {
  const _FakeAutoRouteConfiguration();

  Uri get uri => Uri.parse('/auto/cart?sku=COKE');
}

class _FakeBeamerConfiguration {
  const _FakeBeamerConfiguration();

  String get location => '/beam/checkout';
}

class _FakeGetXConfiguration {
  const _FakeGetXConfiguration();

  String get route => '/getx/orders';
}

abstract class _FakeRouteDelegate<T extends Object> extends RouterDelegate<T>
    with ChangeNotifier {
  @override
  Future<void> setNewRoutePath(T configuration) async {}

  @override
  Future<bool> popRoute() async => false;

  @override
  Widget build(BuildContext context) {
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: Text('Router delegate shell'),
    );
  }
}

class _FakeAutoRouteDelegate
    extends _FakeRouteDelegate<_FakeAutoRouteConfiguration> {
  @override
  _FakeAutoRouteConfiguration get currentConfiguration =>
      const _FakeAutoRouteConfiguration();
}

class _FakeBeamerDelegate extends _FakeRouteDelegate<_FakeBeamerConfiguration> {
  @override
  _FakeBeamerConfiguration get currentConfiguration =>
      const _FakeBeamerConfiguration();
}

class _FakeGetXDelegate extends _FakeRouteDelegate<_FakeGetXConfiguration> {
  @override
  _FakeGetXConfiguration get currentConfiguration =>
      const _FakeGetXConfiguration();
}

class _StaleConfigPaintedRouteDelegate extends RouterDelegate<Object>
    with ChangeNotifier {
  @override
  Object? get currentConfiguration => Uri.parse('/resident-record-route');

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Navigator(
        pages: const <Page<void>>[
          MaterialPage<void>(
            name: 'DashboardRoute',
            child: Scaffold(body: Text('Dashboard route visible')),
          ),
        ],
        onDidRemovePage: (_) {},
      ),
    );
  }

  @override
  Future<bool> popRoute() async => false;

  @override
  Future<void> setNewRoutePath(Object configuration) async {}
}

abstract class _PathRouterDelegate extends RouterDelegate<Object>
    with ChangeNotifier {
  String _path = '/';

  String get path => _path;

  void setPath(String path) {
    _path = path;
    notifyListeners();
  }

  @override
  Object? get currentConfiguration => Uri.parse(_path);

  @override
  Future<void> setNewRoutePath(Object configuration) async {
    setPath(_pathFromConfiguration(configuration));
  }

  @override
  Future<bool> popRoute() async => false;

  @override
  Widget build(BuildContext context) {
    return Directionality(textDirection: TextDirection.ltr, child: Text(_path));
  }

  String _pathFromConfiguration(Object? configuration) {
    if (configuration is Uri) return configuration.path;
    final value = configuration?.toString() ?? '/';
    final match = RegExp(r'(/[A-Za-z0-9_\-./?=&%]+)').firstMatch(value);
    return match?.group(1) ?? '/';
  }
}

class _ParserBackedRouteDelegate extends _PathRouterDelegate {}

class _FakeAutoRouteNavigationDelegate extends _PathRouterDelegate {
  Future<void> navigatePath(
    String path, {
    bool includePrefixMatches = true,
  }) async {
    setPath(path);
  }
}

class _FakeBeamerNavigationDelegate extends _PathRouterDelegate {
  void beamToNamed(String path, {Object? data}) {
    setPath(path);
  }
}

class _FakeGetXNavigationDelegate extends _PathRouterDelegate {
  Future<void> toNamed(
    String path, {
    Object? arguments,
    Map<String, String>? parameters,
  }) async {
    setPath(path);
  }
}

class _PathRouteInformationParser extends RouteInformationParser<Object> {
  @override
  Future<Object> parseRouteInformation(
    RouteInformation routeInformation,
  ) async {
    return routeInformation.uri;
  }

  @override
  Future<Object> parseRouteInformationWithDependencies(
    RouteInformation routeInformation,
    BuildContext context,
  ) async {
    return routeInformation.uri;
  }
}

base class _FakeSharedPreferencesAsyncPlatform
    extends SharedPreferencesAsyncPlatform {
  final Map<String, Object> _values = <String, Object>{};
  int readCount = 0;

  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) async {
    _values[key] = value;
  }

  @override
  Future<void> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) async {
    _values[key] = value;
  }

  @override
  Future<void> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) async {
    _values[key] = value;
  }

  @override
  Future<void> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) async {
    _values[key] = value;
  }

  @override
  Future<void> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) async {
    _values[key] = List<String>.unmodifiable(value);
  }

  @override
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async {
    return _values[key] as String?;
  }

  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) async {
    return _values[key] as bool?;
  }

  @override
  Future<double?> getDouble(
    String key,
    SharedPreferencesOptions options,
  ) async {
    return _values[key] as double?;
  }

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) async {
    return _values[key] as int?;
  }

  @override
  Future<List<String>?> getStringList(
    String key,
    SharedPreferencesOptions options,
  ) async {
    return (_values[key] as List<String>?)?.toList(growable: false);
  }

  @override
  Future<void> clear(
    ClearPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    final allowList = parameters.filter.allowList;
    if (allowList == null) {
      _values.clear();
      return;
    }
    for (final key in allowList) {
      _values.remove(key);
    }
  }

  @override
  Future<Map<String, Object>> getPreferences(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    readCount++;
    final allowList = parameters.filter.allowList;
    return Map<String, Object>.unmodifiable(
      Map<String, Object>.fromEntries(
        _values.entries.where(
          (entry) => allowList == null || allowList.contains(entry.key),
        ),
      ),
    );
  }

  @override
  Future<Set<String>> getKeys(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    final allowList = parameters.filter.allowList;
    return _values.keys
        .where((key) => allowList == null || allowList.contains(key))
        .toSet();
  }
}

base class _FakeSharedPreferencesStorePlatform
    extends SharedPreferencesStorePlatform {
  _FakeSharedPreferencesStorePlatform() : _values = <String, Object>{};

  _FakeSharedPreferencesStorePlatform.withData(Map<String, Object> values)
    : _values = Map<String, Object>.from(values);

  final Map<String, Object> _values;
  int readCount = 0;
  bool failRead = false;

  @override
  bool get isMock => true;

  @override
  Future<bool> remove(String key) async {
    _values.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> clear() async {
    _values.removeWhere((key, _) => key.startsWith('flutter.'));
    return true;
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final filter = parameters.filter;
    _values.removeWhere(
      (key, _) =>
          key.startsWith(filter.prefix) &&
          (filter.allowList == null || filter.allowList!.contains(key)),
    );
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async {
    readCount++;
    if (failRead) throw StateError('fixture backend unavailable');
    return Map<String, Object>.unmodifiable(
      Map<String, Object>.fromEntries(
        _values.entries.where((entry) => entry.key.startsWith('flutter.')),
      ),
    );
  }
}
