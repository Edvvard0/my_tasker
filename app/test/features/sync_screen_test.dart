import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/shell/app_router.dart';
import 'package:my_tasker/features/sync/sync_providers_ui.dart';

import '../support/fake_server/fake_backend.dart';
import '../support/fake_server/fake_sync_server.dart';
import '../support/manual_clock.dart';
import '../support/pump_app.dart';
import '../support/sync_env.dart';
import '../support/ui_helpers.dart';

final _now = DateTime.utc(2026, 10, 1, 12);
const route = '/settings/sync';

Future<ProviderContainer> _open(
  WidgetTester tester,
  SyncStatus status, {
  Size size = phoneSize,
  bool settle = true,
  List<Override> overrides = const [],
}) async {
  final container = await pumpApp(
    tester,
    size: size,
    location: route,
    now: _now,
    settle: settle,
    overrides: [
      syncStatusProvider.overrideWith(() => FixedStatus(status)),
      syncCursorProvider.overrideWith((ref) async => 128),
      ...overrides,
    ],
  );
  if (!settle) {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  return container;
}

String _metric(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  group('состояния статуса', () {
    testWidgets('синхронизировано: счётчики и времена', (tester) async {
      await _open(
        tester,
        statusOf(
          SyncIndicatorKind.synced,
          lastSuccess: _now.subtract(const Duration(minutes: 2)),
          lastPush: _now.subtract(const Duration(minutes: 2)),
          lastPull: _now.subtract(const Duration(minutes: 2)),
        ),
      );
      expect(find.text('СИНХРОНИЗИРОВАНО'), findsOneWidget);
      expect(find.text('Все изменения отправлены и получены.'), findsOneWidget);
      expect(_metric(tester, 'metric-unsent'), '0');
      expect(_metric(tester, 'metric-rejected'), '0');
      expect(_metric(tester, 'metric-push'), '2 мин назад');
      expect(_metric(tester, 'metric-pull'), '2 мин назад');
      expect(_metric(tester, 'metric-cursor'), '128');
      expect(find.byKey(const Key('sync-retry')), findsNothing);
    });

    testWidgets('первая загрузка: прогресс «Загружено записей»', (
      tester,
    ) async {
      await _open(
        tester,
        statusOf(SyncIndicatorKind.syncing, pulledRows: 420),
        settle: false,
      );
      expect(find.text('ИДЁТ СИНХРОНИЗАЦИЯ'), findsOneWidget);
      expect(find.text('Загружено записей: 420.'), findsOneWidget);
      // кнопки недоступны, пока идёт обмен
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('sync-now-button')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('full-resync-button')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('офлайн с очередью', (tester) async {
      await _open(tester, statusOf(SyncIndicatorKind.offline, unsent: 5));
      expect(find.text('ОФЛАЙН'), findsOneWidget);
      expect(_metric(tester, 'metric-unsent'), '5');
      expect(find.byKey(const Key('sync-retry')), findsOneWidget);
    });

    testWidgets('ошибка: причина и «Повторить»', (tester) async {
      await _open(tester, statusOf(SyncIndicatorKind.error, rejected: 1));
      expect(find.text('НЕ СИНХРОНИЗИРОВАНО'), findsOneWidget);
      expect(find.textContaining('Сервер ответил ошибкой'), findsOneWidget);
      expect(find.text('http 503 unavailable'), findsOneWidget);
    });

    testWidgets('нужно обновить приложение: кнопки выключены', (tester) async {
      await _open(tester, statusOf(SyncIndicatorKind.blocked));
      expect(find.text('НУЖНО ОБНОВИТЬ'), findsOneWidget);
      expect(
        find.textContaining('Нужно обновить приложение. Пока'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sync-retry')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('sync-now-button')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('десктоп: те же блоки', (tester) async {
      await _open(
        tester,
        statusOf(SyncIndicatorKind.synced),
        size: desktopSize,
      );
      expect(find.byKey(const Key('sync-metrics')), findsOneWidget);
      expect(find.byKey(const Key('open-conflicts')), findsOneWidget);
    });
  });

  group('действия', () {
    testWidgets('«Синхронизировать сейчас» и «Повторить»', (tester) async {
      final created = <CountingCoordinator>[];
      await _open(
        tester,
        statusOf(SyncIndicatorKind.error),
        overrides: [
          syncCoordinatorProvider.overrideWith((ref) {
            final c = CountingCoordinator(ref);
            created.add(c);
            return c;
          }),
        ],
      );
      await tester.ensureVisible(find.byKey(const Key('sync-now-button')));
      await tester.tap(find.byKey(const Key('sync-now-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync-retry')));
      await tester.pump();
      expect(created.single.syncNowCalls, 2);
    });

    testWidgets('«Журнал конфликтов» открывает журнал', (tester) async {
      await _open(tester, statusOf(SyncIndicatorKind.synced));
      await tester.ensureVisible(find.byKey(const Key('open-conflicts')));
      await tester.tap(find.byKey(const Key('open-conflicts')));
      await tester.pumpAndSettle();
      expect(find.text('Журнал конфликтов'), findsWidgets);
    });
  });

  group('отклонённые операции', () {
    testWidgets('список, «Повторить» и «Отбросить»', (tester) async {
      final container = await _open(
        tester,
        statusOf(SyncIndicatorKind.error, rejected: 2),
        overrides: [],
      );
      final store = container.read(syncStoreProvider);
      await tester.runAsync(() async {
        await store.create('user_settings', userSettingsId('a'), {
          'key': 'a',
          'value': 1,
        });
        await store.create('user_settings', userSettingsId('b'), {
          'key': 'b',
          'value': 2,
        });
        final batch = await store.takeBatch();
        await store.applyPushResults(batch, [
          PushOpResult(
            opId: batch[0].opId,
            applied: false,
            code: 'invalid_field',
            message: 'value',
          ),
          PushOpResult(
            opId: batch[1].opId,
            applied: false,
            code: 'unknown_table',
          ),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Не принято сервером'), findsWidgets);
      expect(find.text('Правка · Настройка'), findsNWidgets(2));
      expect(find.text('Сервер не принял значение поля.'), findsOneWidget);
      expect(find.text('invalid_field · value'), findsOneWidget);
      final ops = await tester.runAsync(store.outbox);
      final first = ops!.first;

      await tester.ensureVisible(find.byKey(Key('retry-${first.opId}')));
      await tester.tap(find.byKey(Key('retry-${first.opId}')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      final afterRetry = await tester.runAsync(store.outbox);
      expect(afterRetry!.where((o) => o.state == 'rejected'), hasLength(1));
      expect(afterRetry.where((o) => o.state != 'rejected'), hasLength(1));

      final second = afterRetry.firstWhere((o) => o.state == 'rejected');
      await tester.ensureVisible(find.byKey(Key('discard-${second.opId}')));
      await tester.tap(find.byKey(Key('discard-${second.opId}')));
      await tester.pumpAndSettle();
      expect(find.text('Отбросить изменение?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      final afterDiscard = await tester.runAsync(store.outbox);
      expect(afterDiscard!.where((o) => o.state == 'rejected'), isEmpty);
    });
  });

  group('полная пересинхронизация', () {
    late ManualClock clock;
    late FakeSyncServer server;
    late FakeBackend backend;

    setUp(() {
      clock = ManualClock();
      server = FakeSyncServer(registry: testRegistry(), nowMs: clock.call);
      backend = FakeBackend(server: server, now: () => clock.now);
    });
    tearDown(() => server.dispose());

    testWidgets('подтверждение, загрузка с сервера, сообщение', (tester) async {
      final container = await pumpApp(
        tester,
        gated: true,
        signedIn: false,
        backend: backend,
        serverUrl: 'http://localhost:8000',
      );
      await tester.runAsync(
        () => container
            .read(authControllerProvider.notifier)
            .login(
              password: backend.password,
              totpCode: backend.totpCode,
              device: const DeviceInfo(
                name: 'phone',
                platform: DevicePlatform.android,
              ),
            ),
      );
      container.read(routerProvider).go(route);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('full-resync-button')));
      await tester.tap(find.byKey(const Key('full-resync-button')));
      await tester.pumpAndSettle();
      expect(find.text('Пересинхронизировать всё?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(backend.requests.where((r) => r.contains('/sync/')), isEmpty);

      await tester.tap(find.byKey(const Key('full-resync-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Данные загружены заново'), findsOneWidget);
      expect(backend.requests, contains('GET /sync/pull'));
    });

    testWidgets('без сети — сообщение об ошибке', (tester) async {
      final container = await pumpApp(
        tester,
        gated: true,
        signedIn: false,
        backend: backend,
        serverUrl: 'http://localhost:8000',
      );
      await tester.runAsync(
        () => container
            .read(authControllerProvider.notifier)
            .login(
              password: backend.password,
              totpCode: backend.totpCode,
              device: const DeviceInfo(
                name: 'phone',
                platform: DevicePlatform.android,
              ),
            ),
      );
      container.read(routerProvider).go(route);
      await tester.pumpAndSettle();
      backend.failNext('/sync/pull');
      await tester.ensureVisible(find.byKey(const Key('full-resync-button')));
      await tester.tap(find.byKey(const Key('full-resync-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Не удалось пересинхронизировать'),
        findsOneWidget,
      );
    });
  });
}
