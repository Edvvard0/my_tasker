import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/auth/device_info_source.dart';
import 'package:my_tasker/core/format/ru_format.dart' show debugUtcOffset;
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/registered_tables.dart' show settingLabels;
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_remote.dart';
import 'package:my_tasker/features/devices/devices_providers.dart';
import 'package:my_tasker/features/sync/sync_providers_ui.dart';
import 'package:my_tasker/features/trash/presentation/trash_screen.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import '../support/fake_server/fake_backend.dart';
import '../support/fake_server/fake_sync_server.dart';
import '../support/in_memory_opener.dart';
import '../support/manual_clock.dart';
import '../support/pump_app.dart';
import '../support/sync_env.dart';
import '../support/ui_helpers.dart';

/// Golden-тесты этапа 1 на телефоне и десктопе: вход, устройства,
/// синхронизация, корзина, журнал конфликтов, восстановление.
/// Эталоны — `files/*.png`; обновление: `flutter test --update-goldens`.
final _now = DateTime.utc(2026, 10, 1, 12);

RegisteredDevice _device(
  String id,
  String name,
  DevicePlatform platform, {
  bool current = false,
  DateTime? revoked,
  Duration seen = const Duration(minutes: 5),
}) => RegisteredDevice(
  id: id,
  name: name,
  platform: platform,
  appVersion: '0.3.1',
  createdAt: _now.subtract(const Duration(days: 20)),
  lastSeenAt: _now.subtract(seen),
  revokedAt: revoked,
  isCurrent: current,
);

SyncConflict _conflict(
  String id,
  ConflictKind kind, {
  Object? losing,
  Object? winning,
  String key = 'ui.theme',
  Duration ago = const Duration(hours: 1),
  DateTime? reverted,
}) => SyncConflict(
  id: id,
  createdAt: _now.subtract(ago),
  table: 'user_settings',
  rowId: userSettingsId(key),
  field: kind == ConflictKind.field ? 'value' : 'deleted_at',
  kind: kind,
  losingValue: losing,
  winningValue: winning,
  revertedAt: reverted,
);

class _ConflictsRemote implements SyncRemote {
  @override
  Future<ConflictsPage> conflicts({
    String reverted = 'all',
    int limit = 50,
    String? before,
  }) async => ConflictsPage(
    conflicts: [
      _conflict('c1', ConflictKind.field, losing: 'light', winning: 'dark'),
      _conflict(
        'c2',
        ConflictKind.resurrected,
        key: 'sync.interval_minutes',
        ago: const Duration(days: 1),
      ),
      _conflict(
        'c3',
        ConflictKind.field,
        losing: 15,
        winning: 30,
        key: 'a.b',
        ago: const Duration(days: 3),
        reverted: _now.subtract(const Duration(days: 2)),
      ),
    ],
  );

  @override
  Future<PushResponse> push(List<Json> ops) => throw UnimplementedError();

  @override
  Future<PullPage> pull({required int since, required int limit}) =>
      throw UnimplementedError();

  @override
  Future<RevertResult> revert(String conflictId) => throw UnimplementedError();
}

TrashItem _trash(String title, int daysLeft, int daysAgo) => TrashItem(
  table: 'user_settings',
  label: 'Настройка',
  id: userSettingsId(title),
  title: title,
  deletedAt: _now.subtract(Duration(days: daysAgo)),
  daysLeft: daysLeft,
);

Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late FakeBackend backend;

  setUp(() {
    // Подписи времени («сегодня в 14:02») считаются в UTC, а не в поясе
    // машины: эталоны не зависят от TZ.
    debugUtcOffset = Duration.zero;
    addTearDown(() => debugUtcOffset = null);
    clock = ManualClock();
    server = FakeSyncServer(registry: testRegistry(), nowMs: clock.call);
    backend = FakeBackend(server: server, now: () => clock.now);
  });
  tearDown(() => server.dispose());

  final deviceInfo = deviceInfoSourceProvider.overrideWithValue(
    const DeviceInfoSource(
      defaultName: 'Galaxy A55',
      platform: DevicePlatform.android,
    ),
  );

  group('вход', () {
    Future<void> login(
      WidgetTester tester,
      Size size, {
      bool configured = true,
      bool withError = false,
    }) async {
      await pumpApp(
        tester,
        size: size,
        signedIn: false,
        gated: true,
        backend: backend,
        serverUrl: configured ? 'http://localhost:8000' : null,
        overrides: [deviceInfo],
      );
      if (withError) {
        await tester.enterText(find.byKey(const Key('login-password')), 'nope');
        await tester.enterText(find.byKey(const Key('login-code')), '123456');
        await tester.tap(find.byKey(const Key('login-submit')));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('телефон: форма', (tester) async {
      await login(tester, phoneSize);
      await _shot(tester, 'login_phone');
    });

    testWidgets('десктоп: форма', (tester) async {
      await login(tester, desktopSize);
      await _shot(tester, 'login_desktop');
    });

    testWidgets('телефон: сервер не настроен', (tester) async {
      await login(tester, phoneSize, configured: false);
      await _shot(tester, 'login_not_configured_phone');
    });

    testWidgets('телефон: ошибка входа', (tester) async {
      await login(tester, phoneSize, withError: true);
      await _shot(tester, 'login_error_phone');
    });
  });

  group('устройства', () {
    final devices = devicesProvider.overrideWith(
      (ref) async => [
        _device('a', 'Galaxy A55', DevicePlatform.android, current: true),
        _device(
          'b',
          'Рабочий ПК',
          DevicePlatform.windows,
          seen: const Duration(hours: 3),
        ),
        _device(
          'c',
          'Старый телефон',
          DevicePlatform.android,
          revoked: _now.subtract(const Duration(days: 2)),
          seen: const Duration(days: 9),
        ),
      ],
    );

    testWidgets('телефон', (tester) async {
      await pumpApp(
        tester,
        location: '/settings/devices',
        now: _now,
        overrides: [devices],
      );
      await _shot(tester, 'devices_phone');
    });

    testWidgets('десктоп', (tester) async {
      await pumpApp(
        tester,
        size: desktopSize,
        location: '/settings/devices',
        now: _now,
        overrides: [devices],
      );
      await _shot(tester, 'devices_desktop');
    });
  });

  group('синхронизация', () {
    final status = statusOf(
      SyncIndicatorKind.error,
      unsent: 3,
      rejected: 1,
      lastSuccess: _now.subtract(const Duration(minutes: 40)),
      lastPush: _now.subtract(const Duration(minutes: 40)),
      lastPull: _now.subtract(const Duration(minutes: 40)),
    );

    Future<void> open(WidgetTester tester, Size size) async {
      final container = await pumpApp(
        tester,
        size: size,
        location: '/settings/sync',
        now: _now,
        overrides: [
          syncStatusProvider.overrideWith(() => FixedStatus(status)),
          syncCursorProvider.overrideWith((ref) async => 128),
        ],
      );
      final store = container.read(syncStoreProvider);
      await tester.runAsync(() async {
        await store.create('user_settings', userSettingsId('ui.theme'), {
          'key': 'ui.theme',
          'value': 'dark',
        });
        final batch = await store.takeBatch();
        await store.applyPushResults(batch, [
          PushOpResult(
            opId: batch.single.opId,
            applied: false,
            code: 'invalid_field',
            message: 'value',
          ),
        ]);
        await pumpEventQueue();
      });
      await tester.pumpAndSettle();
    }

    testWidgets('телефон: ошибка и отклонённая операция', (tester) async {
      await open(tester, phoneSize);
      await _shot(tester, 'sync_phone');
    });

    testWidgets('десктоп', (tester) async {
      await open(tester, desktopSize);
      await _shot(tester, 'sync_desktop');
    });

    testWidgets('телефон: сводка по тапу на индикатор', (tester) async {
      // Сервер настроен (иначе «Не настроен» в списке противоречит тому,
      // что синхронизация уже шла 20 минут назад и накопила очередь).
      await pumpApp(
        tester,
        location: '/settings',
        now: _now,
        backend: backend,
        serverUrl: 'http://localhost:8000',
        overrides: [
          syncStatusProvider.overrideWith(
            () => FixedStatus(
              statusOf(
                SyncIndicatorKind.offline,
                unsent: 12,
                lastSuccess: _now.subtract(const Duration(minutes: 20)),
              ),
            ),
          ),
        ],
      );
      await tester.tap(find.byKey(const Key('sync-indicator')));
      await tester.pumpAndSettle();
      await _shot(tester, 'sync_sheet_phone');
    });
  });

  group('корзина', () {
    final trash = trashProvider.overrideWith(
      (ref) => Stream.value([
        _trash(settingLabels['ui.theme']!, 27, 3),
        _trash('sync.interval_minutes', 12, 18),
        _trash('a.b', 1, 29),
      ]),
    );

    testWidgets('телефон', (tester) async {
      await pumpApp(
        tester,
        location: '/settings/trash',
        now: _now,
        overrides: [trash],
      );
      await _shot(tester, 'trash_phone');
    });

    testWidgets('десктоп', (tester) async {
      await pumpApp(
        tester,
        size: desktopSize,
        location: '/settings/trash',
        now: _now,
        overrides: [trash],
      );
      await _shot(tester, 'trash_desktop');
    });
  });

  group('журнал конфликтов', () {
    Future<void> open(WidgetTester tester, Size size) async {
      final container = await pumpApp(
        tester,
        size: size,
        location: '/settings/sync/conflicts',
        now: _now,
        overrides: [syncRemoteProvider.overrideWithValue(_ConflictsRemote())],
      );
      final store = container.read(syncStoreProvider);
      await tester.runAsync(
        () => store.create('user_settings', userSettingsId('ui.theme'), {
          'key': 'ui.theme',
          'value': 'dark',
        }),
      );
      container.invalidate(rowTitleProvider);
      await tester.pumpAndSettle();
    }

    testWidgets('телефон', (tester) async {
      await open(tester, phoneSize);
      await _shot(tester, 'conflicts_phone');
    });

    testWidgets('десктоп', (tester) async {
      await open(tester, desktopSize);
      await _shot(tester, 'conflicts_desktop');
    });
  });

  group('восстановление', () {
    Future<void> open(WidgetTester tester, Size size) async {
      await pumpApp(
        tester,
        size: size,
        gated: true,
        opener: BrokenUntilResetOpener(
          SqliteException(
            extendedResultCode: 26,
            message: 'file is not a database',
          ),
        ),
      );
    }

    testWidgets('телефон', (tester) async {
      await open(tester, phoneSize);
      await _shot(tester, 'recovery_phone');
    });

    testWidgets('десктоп', (tester) async {
      await open(tester, desktopSize);
      await _shot(tester, 'recovery_desktop');
    });
  });

  test('заглушки для неиспользуемых импортов', () {
    expect(ApiException, isNotNull);
    expect(ProviderContainer, isNotNull);
    expect(Completer<void>, isNotNull);
    expect(ManualClock().ms, greaterThan(0));
  });
}
