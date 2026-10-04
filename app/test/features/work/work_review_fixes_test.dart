// Исправления по ревью Этапа 4: «Повторить» на всех экранах, «Показать ещё»
// во «Времени», архивные проекты с долгом в распределении платежа.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart';

import '../../support/work_env.dart';

WorkData _data(ProviderContainer c) => c.read(workDataProvider).requireValue;

/// Сумма дня в заголовке группы (плитки «Неделя»/«Месяц» не считаются).
Finder daySum(int seconds) => find.descendant(
  of: find.byType(WorkSectionHeader),
  matching: find.text(formatHours(seconds)),
);

/// «Сейчас», которое тест двигает вручную.
class _TestNow extends NowNotifier {
  @override
  DateTime build() => DateTime.utc(2026, 9, 30, 8, 40);

  // Метод, а не сеттер: тест вызывает его как команду «сдвинуть часы».
  // ignore: use_setters_to_change_properties
  void set(DateTime moment) => state = moment;
}

void main() {
  test('снимок «Работы» пересчитывается при смене московской даты, '
      'а не каждые 30 секунд', () async {
    final container = ProviderContainer(
      overrides: [
        nowProvider.overrideWith(_TestNow.new),
        workProjectsProvider.overrideWith((ref) => Stream.value(const [])),
        workPeopleProvider.overrideWith((ref) => Stream.value(const [])),
        changeRequestsProvider.overrideWith((ref) => Stream.value(const [])),
        paymentsProvider.overrideWith((ref) => Stream.value(const [])),
        allocationsProvider.overrideWith((ref) => Stream.value(const [])),
        timeEntriesProvider.overrideWith((ref) => Stream.value(const [])),
      ],
    );
    addTearDown(container.dispose);
    var emissions = 0;
    container.listen(workDataProvider, (_, _) => emissions++);
    await pumpEventQueue();
    expect(container.read(workDataProvider).hasValue, isTrue);
    final base = emissions;
    final now = container.read(nowProvider.notifier) as _TestNow
      ..set(DateTime.utc(2026, 9, 30, 8, 40, 30))
      ..set(DateTime.utc(2026, 9, 30, 20, 59));
    await pumpEventQueue();
    expect(emissions, base, reason: 'та же московская дата — без пересчёта');

    // 21:00 UTC — уже полночь в Москве: 1 октября.
    now.set(DateTime.utc(2026, 9, 30, 21));
    await pumpEventQueue();
    expect(emissions, base + 1);
    expect(
      container.read(workDataProvider).requireValue.now,
      DateTime.utc(2026, 9, 30, 21),
    );
  });

  group('«Повторить» пересоздаёт все потоки раздела', () {
    for (final (route, errorKey) in [
      ('/work', 'work-error'),
      ('/work/receivables', 'receivables-error'),
      ('/work/payments', 'payments-error'),
      ('/work/time', 'time-error'),
    ]) {
      testWidgets('$route: ошибка в потоке людей, повтор читает заново', (
        tester,
      ) async {
        var builds = 0;
        await pumpWork(
          tester,
          location: route,
          overrides: [
            // Раньше «Повторить» трогало только проекты и платежи — поток
            // людей оставался в ошибке навсегда.
            workPeopleProvider.overrideWith((ref) {
              builds++;
              return builds == 1
                  ? Stream<List<WorkPerson>>.error(StateError('x'))
                  : Stream.value(const <WorkPerson>[]);
            }),
          ],
        );
        expect(find.byKey(Key(errorKey)), findsOneWidget);
        await tapKey(tester, 'work-retry');
        expect(builds, 2);
        expect(find.byKey(Key(errorKey)), findsNothing);
      });
    }
  });

  group('«Время»: показать ещё', () {
    testWidgets('сумма дня считается по всем записям, список — по 60', (
      tester,
    ) async {
      late String bot;
      final container = await pumpWork(
        tester,
        seedWith: (c) async {
          final repo = c.read(workRepositoryProvider);
          bot = repo.newId();
          await repo.createProject(
            WorkProject(id: bot, title: 'Бот', status: ProjectStatus.active),
          );
          // 62 записи по 10 минут 28 сентября и 3 записи по часу 27-го.
          for (var i = 0; i < 62; i++) {
            final start = msk(2026, 9, 28, 1).add(Duration(minutes: i));
            await repo.addManualEntry(
              TimeEntry(
                id: repo.newId(),
                projectId: bot,
                startedAt: start,
                endedAt: start.add(const Duration(minutes: 10)),
                billable: true,
                source: TimeSource.manual,
              ),
            );
          }
          for (var i = 0; i < 3; i++) {
            await repo.addManualEntry(
              TimeEntry(
                id: repo.newId(),
                projectId: bot,
                startedAt: msk(2026, 9, 27, 10 + i),
                endedAt: msk(2026, 9, 27, 11 + i),
                billable: true,
                source: TimeSource.manual,
              ),
            );
          }
        },
      );
      await goTo(tester, container, '/work/time');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      final entries = _data(container).entries.where((e) => !e.isRunning);
      final onTwentyEighth = entries
          .where((e) => e.startedAt.isAfter(msk(2026, 9, 28, 0)))
          .toList();
      expect(onTwentyEighth, hasLength(62));
      // Сумма 28-го — 62 × 10 мин = 10 ч 20 мин, хотя видно не все 62.
      expect(daySum(62 * 600), findsOneWidget);
      expect(find.byKey(const Key('time-show-more')), findsOneWidget);
      expect(entries, hasLength(65));
      expect(find.textContaining('Показать ещё (5)'), findsOneWidget);
      // Старые записи пока не видны (27 сентября показан не будет).
      expect(daySum(3 * 3600), findsNothing);
      await tapKey(tester, 'time-show-more');
      expect(find.byKey(const Key('time-show-more')), findsNothing);
      expect(daySum(3 * 3600), findsOneWidget);
      expect(daySum(62 * 600), findsOneWidget);
    });
  });

  group('распределение платежа: архивные проекты', () {
    testWidgets('архивный завершённый с долгом доступен, без долга — нет', (
      tester,
    ) async {
      late String owing;
      late String paid;
      final container = await pumpWork(
        tester,
        seed: true,
        seedWith: (c) async {
          final repo = c.read(workRepositoryProvider);
          Future<String> archived(String title, int base) async {
            final id = repo.newId();
            await repo.createProject(
              WorkProject(
                id: id,
                title: title,
                status: ProjectStatus.completed,
                completedDate: '2026-09-01',
                baseAmount: base,
              ),
            );
            return id;
          }

          owing = await archived('Старый с долгом', 500000);
          paid = await archived('Старый оплаченный', 100000);
          await repo.createPayment(
            Payment(id: repo.newId(), paidAt: msk(2026, 9, 2), amount: 100000),
            [AllocationDraft(projectId: paid, amount: 100000)],
          );
          await repo.setArchived(owing, archived: true);
          await repo.setArchived(paid, archived: true);
        },
      );
      await goTo(tester, container, '/work/payments');
      await tapKey(tester, 'payments-add');
      await tapKey(tester, 'alloc-project-0');
      expect(find.byKey(Key('alloc-project-0-$owing')), findsOneWidget);
      expect(find.text('Старый с долгом · в архиве'), findsOneWidget);
      expect(find.byKey(Key('alloc-project-0-$paid')), findsNothing);
      await tapKey(tester, 'alloc-project-0-$owing');
      expect(find.text('Старый с долгом · в архиве'), findsOneWidget);
    });
  });
}
