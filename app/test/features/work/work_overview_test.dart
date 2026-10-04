import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/pump_app.dart';
import '../../support/work_env.dart';

Text _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key)));

void main() {
  group('«Работа»: обзор', () {
    testWidgets('пусто: подсказка и создание проекта через форму', (
      tester,
    ) async {
      await pumpWork(tester);
      expect(find.byKey(const Key('work-empty')), findsOneWidget);
      expect(find.text('Проектов пока нет'), findsOneWidget);
      // Плитки показывают нули, а не пропадают.
      expect(find.byKey(const Key('kpi-owed')), findsOneWidget);
      expect(find.text('долгов нет'), findsOneWidget);

      await tapKey(tester, 'work-empty-add');
      await tester.enterText(find.byKey(const Key('project-title')), 'Бот');
      await tester.enterText(find.byKey(const Key('project-base')), '25 000');
      await tapKey(tester, 'project-save');

      expect(find.byKey(const Key('project-title')), findsNothing);
      expect(find.byKey(const Key('work-empty')), findsNothing);
      expect(find.text('Бот'), findsOneWidget);
      expect(find.text(nb('25к ₽')), findsNWidgets(3));
      expect(find.text('ост. ${nb('25 000 ₽')}'), findsOneWidget);
    });

    testWidgets('кнопка «Новый проект» в верхней панели открывает форму', (
      tester,
    ) async {
      await pumpWork(tester);
      await tapKey(tester, 'work-add-project');
      expect(find.byKey(const Key('project-title')), findsOneWidget);
    });

    testWidgets('телефон: плитки, ссылки и карточки проектов', (tester) async {
      final container = await pumpWork(tester, seed: true);
      // Сентябрь: получено 19 000 ₽; должны 80 500 ₽ по 3 проектам.
      expect(find.text(nb('19к ₽')), findsOneWidget);
      expect(find.text('за сентябрь'), findsOneWidget);
      expect(find.text(nb('80,5к ₽')), findsWidgets);
      expect(find.text('3 проекта'), findsOneWidget);
      expect(find.text('34 ч за месяц'), findsOneWidget);
      expect(find.text(nb('558,82 ₽')), findsOneWidget);

      for (final title in [
        'Бот разборов ИИ',
        'Платформа Creora',
        'SaaS Лены',
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      final data = container.read(workDataProvider).requireValue;
      final bot = data.projects.firstWhere((p) => p.title == 'Бот разборов ИИ');
      final creora = data.projects.firstWhere(
        (p) => p.title == 'Платформа Creora',
      );
      expect(
        _text(tester, 'project-remaining-${bot.id}').data,
        'ост. ${nb('5 000 ₽')}',
      );
      expect(
        _text(tester, 'project-remaining-${creora.id}').data,
        'ост. ${nb('55 500 ₽')}',
      );
      expect(
        find.textContaining('Рома · 2 доработки · срок 15 окт.'),
        findsOneWidget,
      );
      expect(find.textContaining('Елена'), findsOneWidget);
      expect(find.text('В РАБОТЕ'), findsNWidgets(3));
    });

    testWidgets('фильтры: в работе, все, с долгом, архив', (tester) async {
      final container = await pumpWork(tester, seed: true);
      final repo = container.read(workRepositoryProvider);
      final data = container.read(workDataProvider).requireValue;
      final saas = data.projects.firstWhere((p) => p.title == 'SaaS Лены');
      final creora = data.projects.firstWhere(
        (p) => p.title == 'Платформа Creora',
      );
      await tester.runAsync(() async {
        // SaaS: завершён и оплачен полностью -> в архив; Creora на паузе.
        await repo.createPayment(
          Payment(id: repo.newId(), paidAt: msk(2026, 9, 29), amount: 2000000),
          [AllocationDraft(projectId: saas.id, amount: 2000000)],
        );
        await repo.setProjectStatus(saas.id, ProjectStatus.completed);
        await repo.setArchived(saas.id, archived: true);
        await repo.setProjectStatus(creora.id, ProjectStatus.paused);
      });
      await tester.pumpAndSettle();

      // «В работе»: активные и на паузе, без архива.
      expect(find.byKey(Key('project-${saas.id}')), findsNothing);
      expect(find.byKey(Key('project-${creora.id}')), findsOneWidget);
      expect(find.text('ПАУЗА'), findsOneWidget);

      await tapKey(tester, 'work-filter-archive');
      expect(find.byKey(Key('project-${saas.id}')), findsOneWidget);
      expect(find.byKey(Key('project-${creora.id}')), findsNothing);
      expect(find.text('ЗАВЕРШЁН'), findsOneWidget);

      await tapKey(tester, 'work-filter-debt');
      expect(find.byKey(Key('project-${creora.id}')), findsOneWidget);
      expect(find.byKey(Key('project-${saas.id}')), findsNothing);

      await tapKey(tester, 'work-filter-all');
      expect(find.byKey(Key('project-${saas.id}')), findsNothing);
      expect(find.byKey(Key('project-${creora.id}')), findsOneWidget);
    });

    testWidgets('пустые фильтры объясняют, что делать', (tester) async {
      await pumpWork(tester, seed: true);
      await tapKey(tester, 'work-filter-archive');
      expect(find.byKey(const Key('work-empty-filter')), findsOneWidget);
      expect(find.text('Архив пуст.'), findsOneWidget);
    });

    testWidgets('нажатие на карточку открывает проект', (tester) async {
      final container = await pumpWork(tester, seed: true);
      final bot = container
          .read(workDataProvider)
          .requireValue
          .projects
          .firstWhere((p) => p.title == 'Бот разборов ИИ');
      await tapKey(tester, 'project-${bot.id}');
      expect(locationOf(tester), '/work/projects/${bot.id}');
      expect(find.byKey(const Key('project-screen')), findsOneWidget);
    });

    testWidgets('ссылки ведут на экраны «Работы»', (tester) async {
      await pumpWork(tester, seed: true);
      final routes = {
        'work-receivables-link': '/work/receivables',
        'work-payments-link': '/work/payments',
        'work-time-link': '/work/time',
        'work-people-link': '/work/people',
        'kpi-owed': '/work/receivables',
        'kpi-received': '/work/payments',
        'kpi-per-hour': '/work/time',
      };
      for (final entry in routes.entries) {
        await tapKey(tester, entry.key);
        expect(locationOf(tester), entry.value, reason: entry.key);
        await tester.tap(find.byTooltip('Назад'));
        await tester.pumpAndSettle();
        expect(locationOf(tester), '/work', reason: entry.key);
      }
      await tapKey(tester, 'work-servers-link');
      expect(locationOf(tester), '/work/servers');
    });

    testWidgets('десктоп: таблица проектов с итогом', (tester) async {
      final container = await pumpWork(tester, seed: true, size: desktopSize);
      expect(find.byKey(const Key('project-table')), findsOneWidget);
      expect(find.text('ПРОЕКТ'), findsOneWidget);
      expect(find.text('ИТОГО'), findsOneWidget);
      // Итог по списку: 126 000 ₽ всего, оплачено 45 500 -> остаток 80 500.
      expect(find.text(nb('126 000 ₽')), findsWidgets);
      expect(find.text(nb('80 500 ₽')), findsWidgets);
      expect(find.text('36,1 %'), findsOneWidget);
      final bot = container
          .read(workDataProvider)
          .requireValue
          .projects
          .firstWhere((p) => p.title == 'Бот разборов ИИ');
      await tapKey(tester, 'project-${bot.id}');
      expect(locationOf(tester), '/work/projects/${bot.id}');
    });

    testWidgets('идущий таймер отмечает проект точкой', (tester) async {
      final container = await pumpWork(tester, seed: true);
      final bot = container
          .read(workDataProvider)
          .requireValue
          .projects
          .firstWhere((p) => p.title == 'Бот разборов ИИ');
      await tester.runAsync(
        () => container
            .read(workRepositoryProvider)
            .startTimer(projectId: bot.id),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('project-timer-dot-${bot.id}')), findsOneWidget);
      expect(find.byKey(const Key('timer-pill')), findsOneWidget);
    });

    testWidgets('ошибка чтения: красная карточка и «Повторить»', (
      tester,
    ) async {
      await pumpWork(
        tester,
        overrides: [
          workDataProvider.overrideWithValue(
            AsyncValue<WorkData>.error(StateError('x'), StackTrace.empty),
          ),
        ],
      );
      expect(find.byKey(const Key('work-error')), findsOneWidget);
      await tapKey(tester, 'work-retry');
      expect(find.byKey(const Key('work-error')), findsOneWidget);
    });
  });
}
