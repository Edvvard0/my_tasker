import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/banks/data/notification_store.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/platform/bank_platform.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

import '../../support/banks_env.dart';

class _BrokenPlatform extends FakeBankPlatform {
  @override
  Future<List<RawNotification>> drain() async {
    drains++;
    throw StateError('очередь недоступна');
  }
}

/// Хранилище, у которого обработка пачки падает сразу (до разбора).
class _ThrowingStore extends NotificationStore {
  _ThrowingStore(super._db);

  @override
  Future<int> purgeExpired() async => throw StateError('база недоступна');
}

Future<List<FinTransaction>> _txs(
  WidgetTester tester,
  ProviderContainer c,
) async {
  final rows = await tester.runAsync(
    () async => [
      for (final r
          in await c.read(syncStoreProvider).visibleRows('transactions'))
        FinTransaction.fromRow(r),
    ],
  );
  await tester.pumpAndSettle();
  return rows!;
}

/// Даём настоящим асинхронным операциям (БД, очередь) завершиться.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
}

const _purchase = 'Покупка на 100 ₽, Магнит. Карта *1234. Доступно 500 ₽';

/// Слушатель уведомлений ↔ конвейер: при старте, по сигналу платформы и при
/// возврате в приложение накопленные уведомления превращаются в черновики.
void main() {
  group('жизненный цикл уведомлений банков', () {
    testWidgets('старт: белый список пакетов передан платформе, накопленные '
        'уведомления обработаны', (tester) async {
      final platform = FakeBankPlatform()
        ..queue.add(
          raw(
            tbankPackage,
            'Покупка',
            _purchase,
            DateTime.utc(2026, 9, 30, 8, 30),
          ),
        );
      final c = await pumpBanks(
        tester,
        location: '/finance',
        platform: platform,
        seedWith: (c) async {
          await seedFinanceDemo(c);
        },
      );
      await _settle(tester);
      expect(platform.packages, [tbankPackage, vtbPackage]);
      expect(platform.drains, greaterThanOrEqualTo(1));
      // Очередь на устройстве удаляется только после подтверждения пачки.
      expect(platform.acks, greaterThanOrEqualTo(1));
      expect(platform.queue, isEmpty);
      final created = (await _txs(
        tester,
        c,
      )).where((t) => t.source == TxSource.notification);
      expect(created.single.merchant, 'Магнит');
      expect(created.single.status, TxStatus.draft);
    });

    testWidgets('сигнал платформы и возврат в приложение забирают очередь', (
      tester,
    ) async {
      final platform = FakeBankPlatform();
      final c = await pumpBanks(
        tester,
        location: '/finance',
        platform: platform,
        seedWith: (c) async {
          await seedFinanceDemo(c);
        },
      );
      await _settle(tester);
      final base = platform.drains;

      platform.queue.add(
        raw(
          tbankPackage,
          'Покупка',
          _purchase,
          DateTime.utc(2026, 9, 30, 8, 31),
        ),
      );
      platform.wake();
      await _settle(tester);
      expect(platform.drains, base + 1);
      expect(
        (await _txs(tester, c)).where((t) => t.source == TxSource.notification),
        hasLength(1),
      );

      platform.queue.add(
        raw(
          tbankPackage,
          'Покупка',
          'Покупка на 200 ₽, Лента. Карта *1234. Доступно 300 ₽',
          DateTime.utc(2026, 9, 30, 8, 40),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(platform.drains, base + 2);
      expect(
        (await _txs(tester, c)).where((t) => t.source == TxSource.notification),
        hasLength(2),
      );
    });

    testWidgets('сбой выборки очереди не роняет приложение', (tester) async {
      final platform = _BrokenPlatform();
      await pumpBanks(
        tester,
        location: '/finance',
        platform: platform,
        seedWith: (c) async {
          await seedFinanceDemo(c);
        },
      );
      await _settle(tester);
      expect(platform.drains, greaterThanOrEqualTo(1));
      expect(platform.acks, 0);
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('сбой обработки пачки: подтверждения нет, уведомления остаются '
        'в очереди на устройстве', (tester) async {
      final platform = FakeBankPlatform()
        ..queue.add(
          raw(
            tbankPackage,
            'Покупка',
            _purchase,
            DateTime.utc(2026, 9, 30, 8, 30),
          ),
        );
      await pumpBanks(
        tester,
        location: '/finance',
        platform: platform,
        overrides: [
          notificationStoreProvider.overrideWith(
            (ref) => _ThrowingStore(ref.watch(appDatabaseProvider)),
          ),
        ],
        seedWith: (c) async {
          await seedFinanceDemo(c);
        },
      );
      await _settle(tester);
      expect(platform.drains, greaterThanOrEqualTo(1));
      expect(platform.acks, 0);
      expect(platform.queue, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Windows: слушатель не запускается', (tester) async {
      final platform = FakeBankPlatform(supported: false);
      await pumpBanks(tester, location: '/finance', platform: platform);
      await _settle(tester);
      expect(platform.drains, 0);
      expect(platform.packages, isEmpty);
    });
  });

  test('NoBankPlatform: пустая платформа Windows и тестов', () async {
    const platform = NoBankPlatform();
    expect(platform.isSupported, isFalse);
    await platform.setWatchedPackages(const ['x']);
    expect(await platform.isListenerEnabled(), isFalse);
    await platform.openListenerSettings();
    expect(await platform.isIgnoringBatteryOptimizations(), isFalse);
    await platform.openBatterySettings();
    expect(await platform.drain(), isEmpty);
    expect(await platform.wakeups.isEmpty, isTrue);
  });
}
