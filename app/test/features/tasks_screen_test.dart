import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../support/pump_app.dart';
import '../support/stage2_env.dart';

/// Прокручивает ряд чипов к виджету и нажимает его.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

final Finder _list = find.descendant(
  of: find.byKey(const Key('tasks-list')),
  matching: find.byType(Scrollable),
);

Future<T> _run<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

void main() {
  group('«Задачи»: состояния', () {
    testWidgets('пусто: подсказка и кнопка «Новая задача»', (tester) async {
      await pumpStage2(tester, location: '/calendar/tasks');
      expect(find.byKey(const Key('tasks-empty')), findsOneWidget);
      expect(find.text('Задач пока нет'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Новая задача'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-title')), findsOneWidget);
    });

    testWidgets('загрузка: скелетон', (tester) async {
      await pumpStage2(
        tester,
        location: '/calendar/tasks',
        overrides: [tasksProvider.overrideWith((ref) => const Stream.empty())],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
    });

    testWidgets('ошибка: «Повторить»', (tester) async {
      await pumpStage2(
        tester,
        location: '/calendar/tasks',
        overrides: [
          tasksProvider.overrideWith((ref) => Stream.error(StateError('x'))),
        ],
      );
      expect(find.byKey(const Key('tasks-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tasks-retry')));
      await tester.pump();
    });

    testWidgets('группы, счётчики и свёрнутое «Выполнено»', (tester) async {
      await pumpStage2(tester, seed: true, location: '/calendar/tasks');
      expect(find.text('ПРОСРОЧЕНО · 2'), findsOneWidget);
      expect(find.text('СЕГОДНЯ · 2'), findsOneWidget);
      expect(find.text('ЗАВТРА · 1'), findsOneWidget);
      expect(find.text('БЕЗ ДАТЫ · 5'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('ВЫПОЛНЕНО · 1'),
        200,
        scrollable: _list,
      );
      expect(find.text('Отправить счёт'), findsNothing);
      await _tap(tester, find.byKey(const Key('group-done')));
      await tester.scrollUntilVisible(
        find.text('Отправить счёт'),
        200,
        scrollable: _list,
      );
      expect(find.text('Отправить счёт'), findsOneWidget);
    });
  });

  group('«Задачи»: фильтры', () {
    testWidgets('срок: Сегодня, Неделя, Без даты, Все', (tester) async {
      await pumpStage2(tester, seed: true, location: '/calendar/tasks');
      await _tap(tester, find.byKey(const Key('tasks-range-noDate')));
      expect(find.text('Записаться к врачу'), findsOneWidget);
      expect(find.text('Оплатить домен'), findsNothing);
      await _tap(tester, find.byKey(const Key('tasks-range-today')));
      expect(find.text('Оплатить домен'), findsOneWidget);
      expect(find.text('Созвон с Ромой'), findsNothing);
      await _tap(tester, find.byKey(const Key('tasks-range-week')));
      expect(find.text('Созвон с Ромой'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('tasks-reset')));
      expect(find.byKey(const Key('tasks-reset')), findsNothing);
    });

    testWidgets('лист фильтров: приоритет, статус, проект, поиск', (
      tester,
    ) async {
      await pumpStage2(tester, seed: true, location: '/calendar/tasks');
      await _tap(tester, find.byKey(const Key('tasks-filters')));
      await tester.tap(find.byKey(const Key('filter-priority-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filters-done')));
      await tester.pumpAndSettle();
      expect(find.text('Оплатить домен'), findsOneWidget);
      expect(find.text('Ответить Эмиру'), findsNothing);
      expect(find.text('Фильтры · 1'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('tasks-filters')));
      await tester.tap(find.byKey(const Key('filters-reset')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('filter-query')), 'смета');
      await tester.tap(find.byKey(const Key('filter-status-todo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filters-done')));
      await tester.pumpAndSettle();
      expect(find.text('Смета для Елены'), findsOneWidget);
      expect(find.text('Оплатить домен'), findsNothing);
    });

    testWidgets('проект, тег, отменённые и «ничего не найдено»', (
      tester,
    ) async {
      String? cancelledId;
      final container = await pumpStage2(
        tester,
        seed: true,
        location: '/calendar/tasks',
        seedWith: (c) async {
          final repo = c.read(taskRepositoryProvider);
          final t = await addTask(c, title: 'Отменённая идея');
          await repo.setStatus(t.id, TaskStatus.cancelled);
          cancelledId = t.id;
          final tagged = await addTask(c, title: 'С тегом');
          await repo.setTaskTags(tagged.id, ['срочно']);
        },
      );
      expect(cancelledId, isNotNull);
      expect(find.text('Отменённая идея'), findsNothing);
      await _tap(tester, find.byKey(const Key('tasks-filters')));
      final project = (await _run(
        tester,
        () => container.read(taskRepositoryProvider).projects(),
      )).firstWhere((p) => p.title == 'Creora');
      await tester.tap(find.byKey(Key('filter-project-${project.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filters-done')));
      await tester.pumpAndSettle();
      expect(find.text('Смета для Елены'), findsOneWidget);
      expect(find.text('Оплатить домен'), findsNothing);

      await _tap(tester, find.byKey(const Key('tasks-filters')));
      await tester.tap(find.byKey(const Key('filters-reset')));
      final tag = (await _run(
        tester,
        () => container.read(taskRepositoryProvider).tags(),
      )).single;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('filter-tag-${tag.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filters-done')));
      await tester.pumpAndSettle();
      expect(find.text('С тегом'), findsOneWidget);
      expect(find.text('Оплатить домен'), findsNothing);

      await _tap(tester, find.byKey(const Key('tasks-filters')));
      await tester.tap(find.byKey(const Key('filters-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-cancelled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-archived')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filters-done')));
      await tester.pumpAndSettle();
      final list = _list;
      await tester.scrollUntilVisible(
        find.byKey(const Key('group-done')),
        200,
        scrollable: list,
      );
      await _tap(tester, find.byKey(const Key('group-done')));
      await tester.scrollUntilVisible(
        find.text('Отменённая идея'),
        200,
        scrollable: list,
      );
      expect(find.text('Отменённая идея'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('tasks-filters')));
      await tester.enterText(
        find.byKey(const Key('filter-query')),
        'нет такой',
      );
      await tester.tap(find.byKey(const Key('filters-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tasks-filter-empty')), findsOneWidget);
      await tester.tap(find.text('Сбросить фильтры'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tasks-filter-empty')), findsNothing);
    });
  });

  group('«Задачи»: действия', () {
    testWidgets('быстрое добавление: чипы, убрать чип возвращает слова', (
      tester,
    ) async {
      final container = await pumpStage2(tester, location: '/calendar/tasks');
      await tester.enterText(
        find.byKey(const Key('quick-add-field')),
        'Купить хлеб завтра !1 #дом @Ира +еда',
      );
      await tester.pump();
      for (final k in ['date', 'priority', 'project', 'person', 'tag']) {
        expect(find.byKey(Key('quick-chip-$k')), findsOneWidget, reason: k);
      }
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('quick-chip-date')),
          matching: find.byType(InkWell),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('quick-chip-date')), findsNothing);
      await tester.tap(find.byKey(const Key('quick-add-submit')));
      await tester.pumpAndSettle();
      final tasks = await _run(
        tester,
        () => container.read(tasksProvider.future),
      );
      expect(tasks.single.title, 'Купить хлеб завтра');
      expect(tasks.single.priority, 1);
      expect(tasks.single.due.isNone, isTrue);
      expect(find.textContaining('создано: #дом, @Ира'), findsOneWidget);
    });

    testWidgets('пустое название: ошибка под полем', (tester) async {
      await pumpStage2(tester, location: '/calendar/tasks');
      await tester.enterText(find.byKey(const Key('quick-add-field')), '#дом');
      await tester.tap(find.byKey(const Key('quick-add-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Введите название задачи'), findsOneWidget);
    });

    testWidgets('свайп вправо — выполнить, влево — перенести', (tester) async {
      final container = await pumpStage2(
        tester,
        location: '/calendar/tasks',
        seedWith: (c) async {
          await addTask(
            c,
            title: 'Первая',
            due: TaskDue.date(DateTime.utc(2026, 9, 30)),
          );
          await addTask(
            c,
            title: 'Вторая',
            due: TaskDue.date(DateTime.utc(2026, 9, 30)),
            priority: 3,
          );
        },
      );
      await tester.drag(find.text('Вторая'), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.text('Задача выполнена'), findsOneWidget);
      var tasks = await _run(
        tester,
        () => container.read(tasksProvider.future),
      );
      expect(
        tasks.firstWhere((t) => t.title == 'Вторая').status,
        TaskStatus.done,
      );
      await tester.drag(find.text('Первая'), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reschedule-tomorrow')));
      await tester.pumpAndSettle();
      tasks = await _run(tester, () => container.read(tasksProvider.future));
      expect(
        tasks.firstWhere((t) => t.title == 'Первая').due.date,
        DateTime.utc(2026, 10),
      );
    });

    testWidgets('меню долгого нажатия: приоритет, дубль, удаление', (
      tester,
    ) async {
      final container = await pumpStage2(
        tester,
        location: '/calendar/tasks',
        seedWith: (c) => addTask(
          c,
          title: 'Меню',
          due: TaskDue.date(DateTime.utc(2026, 9, 30)),
        ),
      );
      Future<void> menu(String key) async {
        await tester.longPress(find.text('Меню').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('menu-$key')));
        await tester.pumpAndSettle();
      }

      await menu('priority');
      await tester.tap(find.byKey(const Key('priority-pick-2')));
      await tester.pumpAndSettle();
      var tasks = await _run(
        tester,
        () => container.read(tasksProvider.future),
      );
      expect(tasks.single.priority, 2);

      await menu('duplicate');
      tasks = await _run(tester, () => container.read(tasksProvider.future));
      expect(tasks, hasLength(2));

      await menu('reschedule');
      await tester.tap(find.byKey(const Key('reschedule-none')));
      await tester.pumpAndSettle();

      await menu('edit');
      expect(find.byKey(const Key('task-title')), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();

      await menu('delete');
      expect(find.textContaining('Удалено'), findsOneWidget);
      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      tasks = await _run(tester, () => container.read(tasksProvider.future));
      expect(tasks, hasLength(2));
    });

    testWidgets('быстрые варианты переноса: сегодня, выходные', (tester) async {
      final container = await pumpStage2(
        tester,
        location: '/calendar/tasks',
        seedWith: (c) => addTask(c, title: 'Одна'),
      );
      Future<void> pick(String key) async {
        await tester.longPress(find.text('Одна').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('menu-reschedule')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
      }

      await pick('reschedule-weekend');
      var task = (await _run(
        tester,
        () => container.read(tasksProvider.future),
      )).single;
      expect(task.due.date, DateTime.utc(2026, 10, 3));
      expect(
        task.status,
        TaskStatus.todo,
        reason: 'из Входящих в К выполнению',
      );
      await pick('reschedule-today');
      task = (await _run(
        tester,
        () => container.read(tasksProvider.future),
      )).single;
      expect(task.due.date, DateTime.utc(2026, 9, 30));
    });
  });

  testWidgets('десктоп: список без свайпов, редактор — панель справа', (
    tester,
  ) async {
    await pumpStage2(
      tester,
      seed: true,
      location: '/calendar/tasks',
      size: desktopSize,
    );
    expect(find.byType(Dismissible), findsNothing);
    await tester.tap(find.text('Оплатить домен'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byKey(const Key('task-title')), findsOneWidget);
  });
}
