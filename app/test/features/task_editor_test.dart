import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';

import '../support/stage2_env.dart';

BuildContext _ctx(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first);

Future<void> _open(WidgetTester tester, {String? taskId}) async {
  unawaited(showTaskEditor(_ctx(tester), taskId: taskId));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<List<TaskEntity>> _tasks(
  WidgetTester tester,
  ProviderContainer container,
) async => (await tester.runAsync(() => container.read(tasksProvider.future)))!;

void main() {
  group('создание', () {
    testWidgets('все поля: сохраняется задача с подзадачами и тегами', (
      tester,
    ) async {
      final container = await pumpStage2(tester);
      await _open(tester);
      await tester.enterText(find.byKey(const Key('task-title')), 'Отчёт');
      await _tap(tester, 'task-status-in_progress');
      await _tap(tester, 'task-priority-1');
      await _tap(tester, 'task-date-tomorrow');
      await _tap(tester, 'task-time-1500');
      await _tap(tester, 'task-duration-90');
      await _tap(tester, 'reminder-10');
      await _tap(tester, 'reminder-1440');
      await tester.enterText(find.byKey(const Key('subtask-new')), 'Черновик');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('task-tag-new')), '#работа');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('task-notes')), 'Заметка');
      await _tap(tester, 'task-save');
      final tasks = await _tasks(tester, container);
      final t = tasks.single;
      expect(t.title, 'Отчёт');
      expect(t.status, TaskStatus.inProgress);
      expect(t.priority, 1);
      expect(t.due.at, DateTime.utc(2026, 10, 1, 12));
      expect(t.due.tz, 'Europe/Moscow');
      expect(t.durationMinutes, 90);
      expect(t.reminders, [10, 1440]);
      expect(t.notes, 'Заметка');
      final repo = container.read(taskRepositoryProvider);
      final subtasks = (await tester.runAsync(() => repo.subtasksOf(t.id)))!;
      expect(subtasks.single.title, 'Черновик');
      final tags = (await tester.runAsync(() => repo.tagsOfTask(t.id)))!;
      expect(tags.single.name, 'работа');
    });

    testWidgets('пустое название: ошибка, задача не создаётся', (tester) async {
      final container = await pumpStage2(tester);
      await _open(tester);
      await _tap(tester, 'task-save');
      expect(find.byKey(const Key('task-error')), findsOneWidget);
      expect(await _tasks(tester, container), isEmpty);
    });

    testWidgets('без даты: Входящие, повторение недоступно', (tester) async {
      final container = await pumpStage2(tester);
      await _open(tester);
      expect(
        find.text('Повторение доступно для задач со сроком.'),
        findsOneWidget,
      );
      expect(find.text('Напоминания'), findsNothing);
      await tester.enterText(find.byKey(const Key('task-title')), 'Идея');
      await _tap(tester, 'task-save');
      final t = (await _tasks(tester, container)).single;
      expect(t.status, TaskStatus.inbox);
      expect(t.due.isNone, isTrue);
    });

    testWidgets('выбор даты назначает «К выполнению»; «Без даты» очищает', (
      tester,
    ) async {
      final container = await pumpStage2(tester);
      await _open(tester);
      await tester.enterText(find.byKey(const Key('task-title')), 'Дата');
      await _tap(tester, 'task-date-today');
      await _tap(tester, 'reminder-0');
      await _tap(tester, 'task-date-none');
      expect(find.text('Напоминания'), findsNothing);
      await _tap(tester, 'task-date-monday');
      await _tap(tester, 'task-save');
      final t = (await _tasks(tester, container)).single;
      expect(t.status, TaskStatus.todo);
      expect(t.due.date, DateTime.utc(2026, 10, 5));
      expect(t.reminders, isNull);
    });

    testWidgets('произвольные дата и время через выбор', (tester) async {
      final container = await pumpStage2(tester);
      await _open(tester);
      await tester.enterText(find.byKey(const Key('task-title')), 'Свои');
      await _tap(tester, 'task-date-pick');
      await tester.tap(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(TextButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'task-time-pick');
      await tester.tap(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(TextButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'task-save');
      final t = (await _tasks(tester, container)).single;
      expect(t.due.hasTime, isTrue);
      expect(t.due.at, DateTime.utc(2026, 9, 30, 6));
    });

    testWidgets('повторение: неделя, чётные недели, режим', (tester) async {
      final container = await pumpStage2(tester, seed: true);
      await _open(tester);
      await tester.enterText(find.byKey(const Key('task-title')), 'Уборка');
      await _tap(tester, 'task-date-today');
      await _tap(tester, 'repeat-freq-weekly');
      await _tap(tester, 'repeat-day-4');
      await _tap(tester, 'repeat-cycle-2');
      await _tap(tester, 'task-mode-after_completion');
      await _tap(tester, 'task-mode-schedule');
      await _tap(tester, 'task-save');
      final t = (await _tasks(
        tester,
        container,
      )).firstWhere((t) => t.title == 'Уборка');
      expect(t.rrule, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=WE,FR');
      expect(t.recurrenceMode, RecurrenceMode.schedule);
      // 30 сентября — нечётная неделя; чётная начинается 5 октября.
      expect(t.due.date, DateTime.utc(2026, 10, 7));
    });

    testWidgets('повторение с концом: число раз и дата', (tester) async {
      final container = await pumpStage2(tester);
      await _open(tester);
      await tester.enterText(find.byKey(const Key('task-title')), 'Курс');
      await _tap(tester, 'task-date-today');
      await _tap(tester, 'repeat-freq-daily');
      await _tap(tester, 'repeat-interval-plus');
      await _tap(tester, 'repeat-end-count');
      await _tap(tester, 'repeat-count-plus');
      await _tap(tester, 'repeat-count-minus');
      await _tap(tester, 'task-save');
      final t = (await _tasks(tester, container)).single;
      expect(t.rrule, 'FREQ=DAILY;INTERVAL=2;COUNT=10');
    });

    testWidgets('проект и человек: создать новых и выбрать', (tester) async {
      final container = await pumpStage2(tester);
      await _open(tester);
      await tester.enterText(find.byKey(const Key('task-title')), 'С проектом');
      await _tap(tester, 'task-project-new');
      await tester.enterText(find.byKey(const Key('ask-name-field')), 'Бот');
      await tester.tap(find.byKey(const Key('ask-name-ok')));
      await tester.pumpAndSettle();
      await _tap(tester, 'task-person-new');
      await tester.enterText(find.byKey(const Key('ask-name-field')), 'Ира');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await _tap(tester, 'task-save');
      final t = (await _tasks(tester, container)).single;
      expect(t.projectId, isNotNull);
      expect(t.personId, isNotNull);
    });

    testWidgets('тег: недопустимое имя — ошибка, дубли не добавляются', (
      tester,
    ) async {
      await pumpStage2(tester);
      await _open(tester);
      await tester.enterText(
        find.byKey(const Key('task-tag-new')),
        'два слова',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-error')), findsOneWidget);
      for (final name in ['Дом', 'дом']) {
        await tester.enterText(find.byKey(const Key('task-tag-new')), name);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const Key('task-tag-Дом')), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('task-tag-Дом')),
          matching: find.byType(InkWell),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-tag-Дом')), findsNothing);
    });
  });

  group('правка', () {
    testWidgets('форма заполнена; «Выполнено» ставит completed_at', (
      tester,
    ) async {
      late TaskEntity task;
      final container = await pumpStage2(
        tester,
        seedWith: (c) async {
          task = await addTask(
            c,
            title: 'Старое',
            due: TaskDue.at(utc('2026-10-02T07:00:00'), 'Europe/Moscow'),
            priority: 3,
            duration: 30,
            reminders: const [15],
          );
        },
      );
      await _open(tester, taskId: task.id);
      expect(find.text('Старое'), findsOneWidget);
      expect(find.byKey(const Key('reminder-15')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('task-title')), 'Новое');
      await _tap(tester, 'task-status-done');
      await _tap(tester, 'task-save');
      final t = (await _tasks(tester, container)).single;
      expect(t.title, 'Новое');
      expect(t.status, TaskStatus.done);
      expect(t.completedAt, demoNow);
      expect(t.durationMinutes, 30);
    });

    testWidgets('чек-лист правится, порядок и отметки сохраняются', (
      tester,
    ) async {
      late TaskEntity task;
      final container = await pumpStage2(
        tester,
        seedWith: (c) async {
          task = await addTask(c, title: 'Список');
          final repo = c.read(taskRepositoryProvider);
          await repo.addSubtask(task.id, 'A');
          await repo.addSubtask(task.id, 'B');
        },
      );
      await _open(tester, taskId: task.id);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await _tap(tester, 'subtask-remove-1');
      await tester.enterText(find.byKey(const Key('subtask-new')), 'C');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await _tap(tester, 'task-save');
      final repo = container.read(taskRepositoryProvider);
      final list = (await tester.runAsync(() => repo.subtasksOf(task.id)))!;
      expect(list.map((s) => s.title), ['A', 'C']);
      expect(list.first.done, isTrue);
    });

    testWidgets('удаление и «Отменить»', (tester) async {
      late TaskEntity task;
      final container = await pumpStage2(
        tester,
        seedWith: (c) async => task = await addTask(c, title: 'Удаляемая'),
      );
      await _open(tester, taskId: task.id);
      await _tap(tester, 'task-delete');
      expect(find.textContaining('Удалено: «Удаляемая»'), findsOneWidget);
      expect(await _tasks(tester, container), isEmpty);
      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(await _tasks(tester, container), hasLength(1));
    });

    testWidgets('повторяющаяся задача восстанавливает черновик повторения', (
      tester,
    ) async {
      late TaskEntity task;
      await pumpStage2(
        tester,
        seedWith: (c) async {
          task = await addTask(
            c,
            title: 'Зарядка',
            due: TaskDue.date(DateTime.utc(2026, 10)),
            rrule: 'FREQ=WEEKLY;BYDAY=MO,WE;COUNT=8',
            mode: RecurrenceMode.afterCompletion,
          );
        },
      );
      await _open(tester, taskId: task.id);
      expect(find.byKey(const Key('repeat-count-value')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('repeat-count-value'))).data,
        '8',
      );
    });

    testWidgets('задача не найдена (удалена на другом устройстве)', (
      tester,
    ) async {
      await pumpStage2(tester);
      await _open(tester, taskId: 'нет-такой');
      expect(find.textContaining('Задача не найдена'), findsOneWidget);
    });
  });
}
