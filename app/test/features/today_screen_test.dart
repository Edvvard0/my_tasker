import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/presentation/task_card.dart';

import '../support/fake_reminder_scheduler.dart';
import '../support/pump_app.dart';
import '../support/stage2_env.dart';

Text _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key)));

void main() {
  group('«Сегодня»', () {
    testWidgets('пусто: «На сегодня всё», ни тревог, ни события', (
      tester,
    ) async {
      await pumpStage2(tester);
      expect(find.text('Ср, 30 сентября'), findsOneWidget);
      expect(find.byKey(const Key('today-tasks-empty')), findsOneWidget);
      expect(find.text('На сегодня всё'), findsOneWidget);
      expect(find.byKey(const Key('today-subtitle')), findsNothing);
      expect(find.byKey(const Key('today-overdue-banner')), findsNothing);
      expect(find.byKey(const Key('today-next-card')), findsNothing);
      expect(find.byKey(const Key('quick-add-field')), findsOneWidget);
    });

    testWidgets('данные: неделя цикла, счётчики, просрочка, «Далее»', (
      tester,
    ) async {
      await pumpStage2(tester, seed: true);
      expect(
        _text(tester, 'today-subtitle').data,
        'Нечётная неделя · 4 задачи · 2 события',
      );
      expect(find.text('Просрочено 2 задачи'), findsOneWidget);
      expect(find.text('ДАЛЕЕ · в 15:00'), findsOneWidget);
      expect(find.text('Созвон Creora'), findsWidgets);
      expect(find.text('15:00–16:00 · Zoom'), findsOneWidget);
      expect(find.text('Оплатить домен'), findsOneWidget);
      expect(find.text('Доработать вход в бот'), findsOneWidget);
      // Выполненная сегодня не в списке «на сегодня».
      expect(find.text('Отправить счёт'), findsNothing);
      expect(find.byKey(const Key('day-timeline')), findsOneWidget);
    });

    testWidgets('идущее событие — «СЕЙЧАС», скоро — «через N мин»', (
      tester,
    ) async {
      await pumpStage2(
        tester,
        seed: true,
        now: DateTime.utc(2026, 9, 30, 12, 30),
      );
      expect(find.text('СЕЙЧАС'), findsOneWidget);
    });

    testWidgets('до события меньше часа — «через 25 мин»', (tester) async {
      await pumpStage2(
        tester,
        seed: true,
        now: DateTime.utc(2026, 9, 30, 11, 35),
      );
      expect(find.text('ДАЛЕЕ · через 25 мин'), findsOneWidget);
    });

    testWidgets('событие на весь день и открытие карточки события', (
      tester,
    ) async {
      await pumpStage2(
        tester,
        seedWith: (c) => addAllDayEvent(
          c,
          title: 'Отпуск Ромы',
          date: DateTime.utc(2026, 9, 30),
        ),
      );
      expect(find.text('ВЕСЬ ДЕНЬ'), findsOneWidget);
      await tester.tap(find.text('Отпуск Ромы'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('details-edit')), findsOneWidget);
    });

    testWidgets('больше пяти задач: «Все N ›» ведёт в «Задачи»', (
      tester,
    ) async {
      await pumpStage2(
        tester,
        seedWith: (c) async {
          for (var i = 0; i < 7; i++) {
            await addTask(
              c,
              title: 'Задача $i',
              due: TaskDue.date(DateTime.utc(2026, 9, 30)),
            );
          }
        },
      );
      expect(find.byKey(const Key('today-tasks-all')), findsOneWidget);
      expect(find.text('Все 7 ›'), findsOneWidget);
      await tester.tap(find.byKey(const Key('today-tasks-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tasks-list')), findsOneWidget);
    });

    testWidgets('баннер «Просрочено» ведёт в «Задачи»', (tester) async {
      await pumpStage2(tester, seed: true);
      await tester.tap(find.byKey(const Key('today-overdue-banner')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tasks-list')), findsOneWidget);
    });

    testWidgets('выполнить задачу: снэкбар и «Отменить»', (tester) async {
      await pumpStage2(
        tester,
        seedWith: (c) => addTask(
          c,
          title: 'Купить хлеб',
          due: TaskDue.date(DateTime.utc(2026, 9, 30)),
        ),
      );
      await tester.tap(find.byType(TaskCheckbox).first);
      await tester.pumpAndSettle();
      expect(find.text('Задача выполнена'), findsOneWidget);
      expect(find.text('На сегодня всё'), findsOneWidget);
      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(find.text('Купить хлеб'), findsOneWidget);
    });

    testWidgets('быстрое добавление создаёт задачу', (tester) async {
      final container = await pumpStage2(tester);
      await tester.enterText(
        find.byKey(const Key('quick-add-field')),
        'Позвонить маме завтра 15:00 !2',
      );
      await tester.pump();
      expect(find.byKey(const Key('quick-chip-date')), findsOneWidget);
      expect(find.byKey(const Key('quick-chip-time')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quick-add-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Задача добавлена'), findsOneWidget);
      final tasks = await tester.runAsync(
        () => container.read(tasksProvider.future),
      );
      expect(tasks!.single.title, 'Позвонить маме');
      expect(tasks.single.priority, 2);
    });

    testWidgets('нет доступа к уведомлениям: баннер «Разрешить»', (
      tester,
    ) async {
      final scheduler = FakeReminderScheduler()
        ..state = ReminderPermission.notificationsDenied;
      await pumpStage2(
        tester,
        overrides: [reminderSchedulerProvider.overrideWithValue(scheduler)],
      );
      expect(find.byKey(const Key('today-permission-banner')), findsOneWidget);
      await tester.tap(find.text('Разрешить'));
      await tester.pumpAndSettle();
      expect(scheduler.permissionRequests, 1);
      expect(find.byKey(const Key('today-permission-banner')), findsNothing);
    });

    testWidgets('точные будильники запрещены: пояснение в баннере', (
      tester,
    ) async {
      final scheduler = FakeReminderScheduler()
        ..state = ReminderPermission.exactAlarmsDenied;
      await pumpStage2(
        tester,
        overrides: [reminderSchedulerProvider.overrideWithValue(scheduler)],
      );
      expect(find.textContaining('точным будильникам'), findsOneWidget);
    });

    testWidgets('загрузка: скелетон; ошибка: «Повторить»', (tester) async {
      await pumpStage2(
        tester,
        overrides: [tasksProvider.overrideWith((ref) => const Stream.empty())],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
    });

    testWidgets('ошибка чтения: NoticeCard и «Повторить»', (tester) async {
      await pumpStage2(
        tester,
        overrides: [
          tasksProvider.overrideWith((ref) => Stream.error(StateError('x'))),
        ],
      );
      expect(find.byKey(const Key('today-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('today-retry')));
      await tester.pump();
    });

    testWidgets('десктоп: две колонки, разделы не показываются', (
      tester,
    ) async {
      await pumpStage2(tester, seed: true, size: desktopSize);
      expect(find.byKey(const Key('open-sections')), findsNothing);
      expect(find.byKey(const Key('day-timeline')), findsOneWidget);
    });

    testWidgets('десктоп без событий: «На сегодня событий нет»', (
      tester,
    ) async {
      await pumpStage2(tester, size: desktopSize);
      expect(find.byKey(const Key('today-no-events')), findsOneWidget);
    });
  });
}
