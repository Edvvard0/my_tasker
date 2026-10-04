import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/pump_app.dart';
import '../../support/work_env.dart';

String _t(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  /// Открывает проект «Бот разборов ИИ» из демо-данных.
  Future<(ProviderContainer, String)> open(
    WidgetTester tester, {
    Size size = phoneSize,
    String title = 'Бот разборов ИИ',
  }) async {
    final container = await pumpWork(tester, size: size, seed: true);
    final id = projectIdOf(container, title);
    await goTo(tester, container, '/work/projects/$id');
    return (container, id);
  }

  group('карточка проекта', () {
    testWidgets('плитки: сумма, остаток, доход в час', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('project-screen')), findsOneWidget);
      expect(find.text('Работа ›'), findsOneWidget);
      expect(_t(tester, 'project-meta'), 'Рома');
      expect(find.text(nb('26к ₽')), findsOneWidget);
      expect(find.text('80,7 % оплач.'), findsOneWidget);
      expect(find.text(nb('5 000 ₽')), findsWidgets);
      expect(find.text('срок 15 окт.'), findsOneWidget);
      // 21 000 ₽ за 14 ч = 1 500 ₽/ч.
      expect(find.text(nb('1 500 ₽')), findsOneWidget);
      expect(find.text('14 ч всего'), findsOneWidget);
      expect(find.text('В РАБОТЕ'), findsWidgets);
    });

    testWidgets('таблица «Excel»: база, доработки, итог', (tester) async {
      final (container, _) = await open(tester);
      final data = container.read(workDataProvider).requireValue;
      expect(find.byKey(const Key('money-row-base')), findsOneWidget);
      expect(find.text('Основная сумма'), findsOneWidget);
      expect(find.text(nb('20 000 ₽')), findsOneWidget);
      for (final title in [
        'Доработка входа в бот',
        'Выгрузка роликов в канал',
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      // Вход оплачен наполовину (1 000 из 2 000), выгрузка — на 0 %.
      expect(find.text('ост. ${nb('1 000 ₽')}'), findsOneWidget);
      expect(find.text('ост. ${nb('4 000 ₽')}'), findsOneWidget);
      expect(find.text('ост. ${nb('0 ₽')}'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      final cr = data.changeRequests.first;
      expect(find.byKey(Key('money-row-${cr.id}')), findsOneWidget);
      final total = find.descendant(
        of: find.byKey(const Key('money-total')),
        matching: find.byType(Text),
      );
      expect(
        tester.widgetList<Text>(total).map((t) => t.data).join('|'),
        'ИТОГО|${nb('26 000 ₽')} · 80,7 % · ост. ${nb('5 000 ₽')}',
      );
    });

    testWidgets('оплаты: распределения и помесячные пилюли', (tester) async {
      final (container, id) = await open(tester);
      final data = container.read(workDataProvider).requireValue;
      expect(data.allocationsOfProject(id), hasLength(3));
      for (final a in data.allocationsOfProject(id)) {
        expect(find.byKey(Key('allocation-${a.id}')), findsOneWidget);
      }
      final months = find.descendant(
        of: find.byKey(const Key('project-monthly')),
        matching: find.byType(Text),
      );
      expect(tester.widgetList<Text>(months).map((t) => t.data).toList(), [
        'авг. ${nb('12к ₽')}',
        'сент. ${nb('9 000 ₽')}',
      ]);
      expect(find.textContaining('Рома'), findsWidgets);
    });

    testWidgets('время: часы и доход по факту и по начисленному', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Оплачиваемых часов: 14 ч'), findsOneWidget);
      expect(
        find.textContaining(
          'По факту: ${nb('1 500 ₽')}/ч, по начисленному: ${nb('0 ₽')}/ч',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('project-time')), findsOneWidget);
    });

    testWidgets('десктоп: строки таблицы раскладываются по колонкам', (
      tester,
    ) async {
      await open(tester, size: desktopSize);
      expect(find.byKey(const Key('money-row-base')), findsOneWidget);
      expect(find.text('ЗАКРЫТА'), findsNothing);
      expect(find.text(nb('2 000 ₽')), findsOneWidget);
      expect(find.text(nb('4 000 ₽')), findsWidgets);
    });

    testWidgets('неизвестный проект — сообщение и «назад» в Работу', (
      tester,
    ) async {
      final container = await pumpWork(tester, seed: true);
      await goTo(tester, container, '/work/projects/no-such');
      expect(find.byKey(const Key('project-missing')), findsOneWidget);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/work');
    });

    testWidgets('«назад» из карточки возвращает в список', (tester) async {
      final container = await pumpWork(tester, seed: true);
      final id = projectIdOf(container, 'SaaS Лены');
      await tapKey(tester, 'project-$id');
      expect(locationOf(tester), '/work/projects/$id');
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/work');
    });

    testWidgets('переплата проекта: плитка «Переплата» и «+» в таблице', (
      tester,
    ) async {
      final container = await pumpWork(tester, seed: true);
      final id = projectIdOf(container, 'SaaS Лены');
      final repo = container.read(workRepositoryProvider);
      await tester.runAsync(
        () => repo.createPayment(
          Payment(id: repo.newId(), paidAt: msk(2026, 9, 29), amount: 2500000),
          [AllocationDraft(projectId: id, amount: 2500000)],
        ),
      );
      await goTo(tester, container, '/work/projects/$id');
      expect(find.text('ПЕРЕПЛАТА'), findsOneWidget);
      expect(find.text(nb('5 000 ₽')), findsWidgets);
      expect(find.text('ост. +${nb('5 000 ₽')}'), findsOneWidget);
      expect(find.text('125 % оплач.'), findsOneWidget);
    });

    testWidgets('нарушение «распределено больше платежа» — предупреждение', (
      tester,
    ) async {
      final container = await pumpWork(tester, seed: true);
      final id = projectIdOf(container, 'SaaS Лены');
      final repo = container.read(workRepositoryProvider);
      final payId = repo.newId();
      await tester.runAsync(() async {
        await repo.createPayment(
          Payment(id: payId, paidAt: msk(2026, 9, 29), amount: 1000000),
          [AllocationDraft(projectId: id, amount: 1000000)],
        );
        // Две правки с разных устройств слились в сумму больше платежа:
        // сервер такое не отклоняет (spec 3.3).
        await container.read(syncStoreProvider).create(
          'payment_allocations',
          repo.newId(),
          {
            'payment_id': payId,
            'project_id': id,
            'change_request_id': null,
            'amount': 800000,
          },
        );
      });
      await goTo(tester, container, '/work/projects/$id');
      expect(find.byKey(Key('project-overallocated-$payId')), findsOneWidget);
      expect(
        find.textContaining('больше, чем пришло, на ${nb('8 000 ₽')}'),
        findsOneWidget,
      );
      await tester.tap(find.text('Открыть платёж'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-amount')), findsOneWidget);
    });
  });
}
