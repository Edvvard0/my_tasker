import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';
import 'package:my_tasker/features/work/application/timer_providers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/pump_app.dart';
import '../../support/work_env.dart';

WorkData _data(ProviderContainer c) => c.read(workDataProvider).requireValue;

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  late TimerClock clock;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    String location = '/work',
    Size size = phoneSize,
    bool seed = true,
  }) {
    clock = TimerClock(workNow);
    return pumpWork(
      tester,
      location: location,
      size: size,
      seed: seed,
      fixedClock: false,
      overrides: clock.overrides,
    );
  }

  Future<TimerStartResult> start(
    WidgetTester tester,
    ProviderContainer container,
    String title, {
    String? changeRequestId,
    String? taskId,
  }) async {
    late TimerStartResult result;
    await tester.runAsync(() async {
      result = await container
          .read(workRepositoryProvider)
          .startTimer(
            projectId: projectIdOf(container, title),
            changeRequestId: changeRequestId,
            taskId: taskId,
          );
    });
    await tester.pumpAndSettle();
    return result;
  }

  group('плашка «идёт таймер»', () {
    testWidgets('нет таймера — нет плашки; идёт — проект и время', (
      tester,
    ) async {
      final container = await pump(tester);
      expect(find.byKey(const Key('timer-pill')), findsNothing);
      await start(tester, container, 'Бот разборов ИИ');
      expect(find.byKey(const Key('timer-pill')), findsOneWidget);
      expect(find.text('Бот разборов ИИ'), findsWidgets);
      expect(_text(tester, 'timer-pill-time'), '00:00:00');
      clock.advance(
        container,
        const Duration(hours: 1, minutes: 12, seconds: 43),
      );
      await tester.pump();
      expect(_text(tester, 'timer-pill-time'), '01:12:43');
    });

    testWidgets('плашка видна на любом экране и на десктопе', (tester) async {
      final container = await pump(tester, size: desktopSize);
      await start(tester, container, 'Платформа Creora');
      expect(find.byKey(const Key('timer-pill')), findsOneWidget);
      await goTo(tester, container, '/today');
      expect(find.byKey(const Key('timer-pill')), findsOneWidget);
      await goTo(tester, container, '/calendar');
      expect(find.byKey(const Key('timer-pill')), findsOneWidget);
    });

    testWidgets('доработка попадает в название таймера', (tester) async {
      final container = await pump(tester);
      final bot = projectIdOf(container, 'Бот разборов ИИ');
      final cr = _data(container).changeRequestsOf(bot).first;
      await start(tester, container, 'Бот разборов ИИ', changeRequestId: cr.id);
      expect(find.text('Бот разборов ИИ · ${cr.title}'), findsOneWidget);
    });

    testWidgets('«Стоп» на плашке: запись закрыта, снэкбар с итогом', (
      tester,
    ) async {
      final container = await pump(tester);
      final started = await start(tester, container, 'Бот разборов ИИ');
      clock.advance(
        container,
        const Duration(hours: 1, minutes: 12, seconds: 43),
      );
      await tapKey(tester, 'timer-pill-stop');
      expect(find.byKey(const Key('timer-pill')), findsNothing);
      expect(
        find.text('Записано 1 ч 12 мин · Бот разборов ИИ'),
        findsOneWidget,
      );
      final entry = _data(container).entries
          .firstWhere((e) => e.id == started.started.id);
      expect(entrySeconds(entry), 4363);
      expect(entry.endedAt, clock.moment);
    });

    testWidgets('лист таймера: время, заметка, «Стоп»', (tester) async {
      final container = await pump(tester);
      final started = await start(tester, container, 'Бот разборов ИИ');
      clock.advance(container, const Duration(minutes: 5, seconds: 1));
      await tester.tap(find.byKey(const Key('timer-pill')));
      await tester.pumpAndSettle();
      expect(_text(tester, 'timer-sheet-time'), '00:05:01');
      await tester.enterText(find.byKey(const Key('timer-note')), 'Вход');
      await tapKey(tester, 'timer-stop');
      expect(find.byKey(const Key('timer-sheet-time')), findsNothing);
      expect(find.byKey(const Key('timer-pill')), findsNothing);
      final entry = _data(container).entries
          .firstWhere((e) => e.id == started.started.id);
      expect(entry.note, 'Вход');
      expect(entry.isRunning, isFalse);
    });

    testWidgets('«Отменить запись» убирает идущий таймер', (tester) async {
      final container = await pump(tester);
      final started = await start(tester, container, 'Бот разборов ИИ');
      await tester.tap(find.byKey(const Key('timer-pill')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'timer-discard');
      expect(find.byKey(const Key('timer-pill')), findsNothing);
      expect(
        _data(container).entries.any((e) => e.id == started.started.id),
        isFalse,
      );
    });

    testWidgets('лист без таймера: «Таймер остановлен»', (tester) async {
      final container = await pump(tester);
      await start(tester, container, 'Бот разборов ИИ');
      await tester.tap(find.byKey(const Key('timer-pill')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final repo = container.read(workRepositoryProvider);
        for (final e in await repo.runningEntries()) {
          await repo.stopTimer(e.id);
        }
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timer-sheet-empty')), findsOneWidget);
    });
  });

  group('старт и стоп из проекта', () {
    testWidgets('кнопка в верхней панели проекта', (tester) async {
      final container = await pump(tester);
      final bot = projectIdOf(container, 'Бот разборов ИИ');
      await goTo(tester, container, '/work/projects/$bot');
      await tapKey(tester, 'project-timer-start');
      expect(find.byKey(const Key('timer-pill')), findsOneWidget);
      expect(find.byKey(const Key('project-timer-stop')), findsOneWidget);
      expect(find.byKey(const Key('project-timer-start')), findsNothing);
      clock.advance(container, const Duration(minutes: 30));
      await tapKey(tester, 'project-timer-stop');
      expect(find.byKey(const Key('timer-pill')), findsNothing);
      expect(find.byKey(const Key('project-timer-start')), findsOneWidget);
      expect(find.text('Записано 30 мин · Бот разборов ИИ'), findsOneWidget);
    });

    testWidgets('старт на другом проекте останавливает первый с тостом', (
      tester,
    ) async {
      final container = await pump(tester);
      final bot = projectIdOf(container, 'Бот разборов ИИ');
      final creora = projectIdOf(container, 'Платформа Creora');
      await goTo(tester, container, '/work/projects/$bot');
      await tapKey(tester, 'project-timer-start');
      clock.advance(container, const Duration(minutes: 30));
      await goTo(tester, container, '/work/projects/$creora');
      await tapKey(tester, 'project-timer-start');
      expect(
        find.text('Таймер Бот разборов ИИ остановлен · 30 мин'),
        findsOneWidget,
      );
      final running = _data(container).entries.where((e) => e.isRunning);
      expect(running.single.projectId, creora);
      // Ровно один идущий таймер.
      expect(container.read(runningTimersProvider), hasLength(1));
    });
  });

  group('экран «Время»', () {
    testWidgets('нет таймера: чипы проектов запускают таймер', (tester) async {
      final container = await pump(tester, location: '/work/time');
      expect(find.byKey(const Key('time-idle')), findsOneWidget);
      final saas = projectIdOf(container, 'SaaS Лены');
      await tapKey(tester, 'time-start-$saas');
      expect(find.byKey(const Key('time-running')), findsOneWidget);
      expect(find.byKey(const Key('time-idle')), findsNothing);
      clock.advance(container, const Duration(minutes: 90, seconds: 5));
      await tester.pump();
      expect(_text(tester, 'time-running-time'), '01:30:05');
      await tapKey(tester, 'time-stop');
      expect(find.byKey(const Key('time-idle')), findsOneWidget);
      expect(find.text('Записано 1 ч 30 мин · SaaS Лены'), findsOneWidget);
      // Запись попала в сегодняшнюю группу и в «Неделю».
      expect(find.text('30 СЕНТ.'), findsOneWidget);
    });

    testWidgets('плитки: неделя, месяц, доход в час; записи по дням', (
      tester,
    ) async {
      final container = await pump(tester, location: '/work/time');
      // Неделя 28 сент.–4 окт.: Бот 21 сент. не входит, Creora 29 сент. 8 ч.
      Finder tile(String key, String text) =>
          find.descendant(of: find.byKey(Key(key)), matching: find.text(text));
      expect(tile('time-kpi-week', '8 ч'), findsOneWidget);
      // Сентябрь: Бот 10 ч + Creora 24 ч.
      expect(tile('time-kpi-month', '34 ч'), findsOneWidget);
      expect(find.text(nb('558,82 ₽')), findsOneWidget);
      expect(find.text('по начисл. ${nb('0 ₽')}'), findsOneWidget);
      final entries = _data(container).entries;
      for (final e in entries) {
        expect(find.byKey(Key('time-entry-${e.id}')), findsOneWidget);
      }
      expect(find.text('29 СЕНТ.'), findsOneWidget);
      expect(find.text('18 АВГ.'), findsOneWidget);
    });

    testWidgets('нет записей: подсказка; нет проектов: подсказка', (
      tester,
    ) async {
      await pump(tester, location: '/work/time', seed: false);
      expect(find.byKey(const Key('time-empty')), findsOneWidget);
      expect(
        find.text('Создайте проект «в работе», чтобы вести время.'),
        findsOneWidget,
      );
    });
  });

  group('два таймера после синхронизации', () {
    testWidgets('предупреждение и остановка любого из них', (tester) async {
      final container = await pump(tester);
      final first = await start(tester, container, 'Бот разборов ИИ');
      // Второй таймер «пришёл с другого устройства»: идёт, но его запустили
      // независимо (в обход «одного таймера на устройстве»).
      final creora = projectIdOf(container, 'Платформа Creora');
      final foreignId = container.read(workRepositoryProvider).newId();
      clock.advance(container, const Duration(minutes: 10));
      await tester.runAsync(
        () => container
            .read(syncStoreProvider)
            .create(
              'time_entries',
              foreignId,
              TimeEntry(
                id: foreignId,
                projectId: creora,
                startedAt: clock.moment,
                billable: true,
                source: TimeSource.timer,
              ).toFields(),
            ),
      );
      await tester.pumpAndSettle();
      expect(container.read(timerConflictProvider), isTrue);
      expect(find.byKey(const Key('timer-conflict')), findsOneWidget);
      expect(
        find.text(
          'Идёт 2 таймера: их запустили офлайн на разных '
          'устройствах. Остановите лишний.',
        ),
        findsOneWidget,
      );
      // Главный на плашке — запущенный позже.
      expect(container.read(primaryTimerProvider)!.entry.id, foreignId);

      await tapKey(tester, 'timer-conflict-stop-$foreignId');
      expect(find.byKey(const Key('timer-conflict')), findsNothing);
      expect(
        container.read(runningTimersProvider).single.entry.id,
        first.started.id,
      );
      expect(find.byKey(const Key('timer-pill')), findsOneWidget);
    });

    testWidgets('предупреждение и в листе таймера, и на экране «Время»', (
      tester,
    ) async {
      final container = await pump(tester, location: '/work/time');
      await start(tester, container, 'Бот разборов ИИ');
      final other = container.read(workRepositoryProvider).newId();
      await tester.runAsync(
        () => container
            .read(syncStoreProvider)
            .create(
              'time_entries',
              other,
              TimeEntry(
                id: other,
                projectId: projectIdOf(container, 'SaaS Лены'),
                startedAt: clock.moment.add(const Duration(minutes: 1)),
                billable: true,
                source: TimeSource.timer,
              ).toFields(),
            ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timer-conflict')), findsOneWidget);
      await tester.tap(find.byKey(const Key('timer-pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timer-conflict')), findsNWidgets(2));
    });
  });

  group('таймер из задачи', () {
    Future<String> task(
      WidgetTester tester,
      ProviderContainer container, {
      String? projectTitle,
    }) async {
      late String id;
      await tester.runAsync(() async {
        final repo = container.read(taskRepositoryProvider);
        id = repo.newTaskId();
        await repo.createTask(
          TaskEntity(
            id: id,
            title: 'Доработать вход',
            status: TaskStatus.todo,
            projectId: projectTitle == null
                ? null
                : projectIdOf(container, projectTitle),
          ),
        );
      });
      return id;
    }

    Future<void> openEditor(WidgetTester tester, String taskId) async {
      unawaited(
        showTaskEditor(
          tester.element(find.byType(Scaffold).first),
          taskId: taskId,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('у задачи с проектом: старт пишет задачу и проект', (
      tester,
    ) async {
      final container = await pump(tester);
      final id = await task(tester, container, projectTitle: 'Бот разборов ИИ');
      await openEditor(tester, id);
      await tapKey(tester, 'task-timer-start');
      expect(find.byKey(const Key('task-title')), findsNothing);
      final running = _data(container).entries.singleWhere((e) => e.isRunning);
      expect(running.taskId, id);
      expect(running.projectId, projectIdOf(container, 'Бот разборов ИИ'));
      expect(running.note, 'Доработать вход');
      expect(find.byKey(const Key('timer-pill')), findsOneWidget);

      await openEditor(tester, id);
      expect(find.byKey(const Key('task-timer-stop')), findsOneWidget);
      expect(find.byKey(const Key('task-timer-start')), findsNothing);
      clock.advance(container, const Duration(minutes: 20));
      await tapKey(tester, 'task-timer-stop');
      expect(_data(container).entries.where((e) => e.isRunning), isEmpty);
    });

    testWidgets('у задачи без проекта: сначала выбор проекта', (tester) async {
      final container = await pump(tester);
      final id = await task(tester, container);
      await openEditor(tester, id);
      await tapKey(tester, 'task-timer-start');
      final creora = projectIdOf(container, 'Платформа Creora');
      await tapKey(tester, 'project-picker-$creora');
      final running = _data(container).entries.singleWhere((e) => e.isRunning);
      expect(running.projectId, creora);
      expect(running.taskId, id);
    });

    testWidgets('выбор проекта можно закрыть — таймер не стартует', (
      tester,
    ) async {
      final container = await pump(tester);
      final id = await task(tester, container);
      await openEditor(tester, id);
      await tapKey(tester, 'task-timer-start');
      await tester.tap(find.byTooltip('Закрыть').last);
      await tester.pumpAndSettle();
      expect(_data(container).entries.where((e) => e.isRunning), isEmpty);
    });

    testWidgets('нет проектов: подсказка в выборе', (tester) async {
      final container = await pump(tester, seed: false);
      final id = await task(tester, container);
      await openEditor(tester, id);
      await tapKey(tester, 'task-timer-start');
      expect(find.byKey(const Key('project-picker-empty')), findsOneWidget);
    });

    testWidgets('у новой задачи кнопки таймера нет', (tester) async {
      await pump(tester);
      unawaited(showTaskEditor(tester.element(find.byType(Scaffold).first)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-timer-start')), findsNothing);
      expect(find.byType(DateChoiceRow), findsOneWidget);
    });
  });
}
