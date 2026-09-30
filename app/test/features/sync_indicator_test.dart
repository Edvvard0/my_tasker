import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/sync/presentation/sync_indicator.dart';
import 'package:my_tasker/features/sync/sync_texts.dart';

import '../support/pump_app.dart';
import '../support/ui_helpers.dart';

final _now = DateTime.utc(2026, 10, 1, 12);

void main() {
  Future<List<CountingCoordinator>> open(
    WidgetTester tester,
    SyncStatus status, {
    Size size = phoneSize,
    bool settle = true,
  }) async {
    final created = <CountingCoordinator>[];
    await pumpApp(
      tester,
      size: size,
      location: '/settings',
      now: _now,
      settle: settle,
      overrides: [
        syncStatusProvider.overrideWith(() => FixedStatus(status)),
        syncCoordinatorProvider.overrideWith((ref) {
          final coordinator = CountingCoordinator(ref);
          created.add(coordinator);
          return coordinator;
        }),
      ],
    );
    if (!settle) {
      // Бесконечная анимация: pumpAndSettle не вернётся, ждём вручную.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
    return created;
  }

  group('индикатор в верхней панели', () {
    testWidgets('синхронизировано: тишина', (tester) async {
      await open(tester, statusOf(SyncIndicatorKind.synced));
      expect(find.byKey(const Key('sync-indicator')), findsNothing);
    });

    testWidgets('идёт синхронизация: вращающийся значок', (tester) async {
      await open(tester, statusOf(SyncIndicatorKind.syncing), settle: false);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('sync-spinner')), findsOneWidget);
      expect(find.byKey(const Key('sync-indicator-label')), findsNothing);
      // не блокирует работу: экран на месте
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Настройки'), findsWidgets);
    });

    testWidgets('десктоп, офлайн: пилюля со счётчиком неотправленного', (
      tester,
    ) async {
      await open(
        tester,
        statusOf(SyncIndicatorKind.offline, unsent: 12),
        size: desktopSize,
      );
      expect(find.text('Офлайн · 12'), findsOneWidget);
    });

    testWidgets('десктоп, офлайн без очереди', (tester) async {
      await open(
        tester,
        statusOf(SyncIndicatorKind.offline),
        size: desktopSize,
      );
      expect(find.text('Офлайн'), findsWidgets);
    });

    testWidgets('десктоп, ошибка: красная пилюля «Не синхронизировано»', (
      tester,
    ) async {
      await open(tester, statusOf(SyncIndicatorKind.error), size: desktopSize);
      expect(find.text('Не синхронизировано'), findsOneWidget);
    });

    testWidgets('телефон: пилюля сжимается до значка и счётчика', (
      tester,
    ) async {
      await open(tester, statusOf(SyncIndicatorKind.offline, unsent: 12));
      expect(find.byKey(const Key('sync-indicator')), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('Офлайн · 12'), findsNothing);
      // заголовок экрана при этом не вытесняется
      expect(find.text('Настройки'), findsWidgets);
    });

    testWidgets('телефон: ошибка — только значок', (tester) async {
      await open(tester, statusOf(SyncIndicatorKind.error));
      expect(find.byKey(const Key('sync-indicator')), findsOneWidget);
      expect(find.byKey(const Key('sync-indicator-label')), findsNothing);
    });

    testWidgets('нужно обновить: пилюля и баннер', (tester) async {
      await open(
        tester,
        statusOf(SyncIndicatorKind.blocked),
        size: desktopSize,
      );
      expect(find.text('Нужно обновить'), findsOneWidget);
      expect(find.byKey(const Key('banner-update')), findsOneWidget);
      expect(
        find.textContaining('Оно продолжает работать офлайн'),
        findsOneWidget,
      );
    });

    testWidgets('часы спешат: баннер «проверьте время»', (tester) async {
      await open(tester, statusOf(SyncIndicatorKind.synced, clockSkew: true));
      expect(find.byKey(const Key('banner-clock')), findsOneWidget);
      expect(
        find.textContaining('Проверьте время на устройстве'),
        findsOneWidget,
      );
    });

    testWidgets('баннеров нет, когда всё хорошо', (tester) async {
      await open(tester, statusOf(SyncIndicatorKind.synced));
      expect(find.byKey(const Key('banner-update')), findsNothing);
      expect(find.byKey(const Key('banner-clock')), findsNothing);
    });
  });

  group('сводка по тапу', () {
    testWidgets('телефон: bottom sheet с состоянием и действиями', (
      tester,
    ) async {
      final created = await open(
        tester,
        statusOf(
          SyncIndicatorKind.offline,
          unsent: 12,
          lastSuccess: _now.subtract(const Duration(minutes: 20)),
        ),
      );
      await tester.tap(find.byKey(const Key('sync-indicator')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync-summary')), findsOneWidget);
      expect(find.text('Синхронизация'), findsWidgets);
      expect(
        find.textContaining('На устройстве сохранено 12 изменений'),
        findsWidgets,
      );
      expect(find.text('20 мин назад'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-now')));
      await tester.pump();
      expect(created.single.syncNowCalls, 1);
    });

    testWidgets('десктоп: окно, «Подробнее» ведёт на экран синхронизации', (
      tester,
    ) async {
      await open(tester, statusOf(SyncIndicatorKind.error), size: desktopSize);
      await tester.tap(find.byKey(const Key('sync-indicator')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.textContaining('Сервер ответил ошибкой'), findsWidgets);
      expect(find.text('ещё не было'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-details')));
      await tester.pumpAndSettle();
      expect(find.text('Журнал конфликтов'), findsOneWidget);
    });

    testWidgets('идёт обмен: «Синхронизировать сейчас» недоступна', (
      tester,
    ) async {
      await open(tester, statusOf(SyncIndicatorKind.syncing), settle: false);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('sync-indicator')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Идёт синхронизация…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('sync-now')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('нужно обновить и отклонённые операции в сводке', (
      tester,
    ) async {
      await open(tester, statusOf(SyncIndicatorKind.blocked, rejected: 2));
      await tester.tap(find.byKey(const Key('sync-indicator')));
      await tester.pumpAndSettle();
      expect(find.text('Нужно обновить приложение'), findsOneWidget);
      expect(find.text('Сервер не принял: 2.'), findsOneWidget);
    });

    testWidgets('всё синхронизировано: заголовок «Всё синхронизировано»', (
      tester,
    ) async {
      await open(tester, statusOf(SyncIndicatorKind.synced));
      unawaited(showSyncSheet(tester.element(find.byType(Scaffold).first)));
      await tester.pumpAndSettle();
      expect(find.text('Всё синхронизировано'), findsOneWidget);
    });
  });

  test('тексты: множественное число и подписи', () {
    expect(changesCount(1), '1 изменение');
    expect(changesCount(3), '3 изменения');
    expect(changesCount(12), '12 изменений');
    expect(changesCount(21), '21 изменение');
    expect(opTypeLabel('delete'), 'Удаление');
    expect(opTypeLabel('upsert'), 'Правка');
    for (final code in [
      'unknown_table',
      'invalid_field',
      'immutable_field',
      'missing_fields',
      'parent_not_found',
      'validation_failed',
      'hlc_device_mismatch',
      'invalid_op',
      'zzz',
      null,
    ]) {
      expect(rejectCodeText(code), isNotEmpty);
    }
  });
}
