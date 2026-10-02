import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/quick_input/quick_input_parser.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

TaskEntity _task(
  int n, {
  TaskStatus status = TaskStatus.todo,
  TaskDue due = const TaskDue.none(),
  String? rrule,
  RecurrenceMode? mode,
  List<int>? reminders,
}) => TaskEntity(
  id: _uuid(n),
  title: 'Задача $n',
  status: status,
  due: due,
  rrule: rrule,
  recurrenceMode: mode,
  reminders: reminders,
);

void main() {
  ensureTimeZones();
  late ManualClock clock;
  late FakeSyncServer server;
  late CalendarDevice d;
  late TaskRepository repo;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    d = await CalendarDevice.create(
      server,
      clock: clock,
      newId: () => _uuid(500 + ++counter),
    );
    repo = d.tasks;
  });
  tearDown(() async {
    await d.close();
    await server.dispose();
  });

  group('задачи', () {
    test('создание и чтение; название обрезается', () async {
      await repo.createTask(_task(1).copyWith(title: '  Купить хлеб '));
      final t = (await repo.getTask(_uuid(1)))!;
      expect(t.title, 'Купить хлеб');
      expect(t.status, TaskStatus.todo);
      expect(await repo.getTask('нет'), isNull);
      expect(repo.newTaskId(), _uuid(501));
    });

    test('проверки значений', () async {
      for (final bad in [
        _task(1).copyWith(title: ' '),
        _task(1).copyWith(priority: 6),
        _task(1).copyWith(durationMinutes: 0),
        _task(1, reminders: [0]),
        _task(1, rrule: 'FREQ=DAILY', mode: RecurrenceMode.schedule),
        _task(
          1,
          due: TaskDue.date(DateTime.utc(2026, 10, 5)),
          rrule: 'FREQ=DAILY',
        ),
        _task(1, mode: RecurrenceMode.schedule),
        _task(1, due: TaskDue.at(DateTime.utc(2026, 10, 5), 'Нет/Такой')),
        _task(
          1,
          due: TaskDue.date(DateTime.utc(2026, 10, 5)),
          rrule: 'FREQ=HOURLY',
          mode: RecurrenceMode.schedule,
        ),
      ]) {
        await expectLater(
          repo.createTask(bad),
          throwsA(isA<ValidationError>()),
          reason: bad.title,
        );
      }
    });

    test(
      'статусы: done ставит completed_at, выход из done сбрасывает',
      () async {
        await repo.createTask(_task(1));
        await d.device.sync();
        await repo.setStatus(_uuid(1), TaskStatus.done);
        var t = (await repo.getTask(_uuid(1)))!;
        expect(t.status, TaskStatus.done);
        expect(t.completedAt, clock.now);
        final op = (await d.device.store.outbox()).single;
        expect(op.fields!.keys, containsAll(['status', 'completed_at']));
        await repo.setStatus(_uuid(1), TaskStatus.done);
        await repo.setStatus(_uuid(1), TaskStatus.inProgress);
        t = (await repo.getTask(_uuid(1)))!;
        expect(t.completedAt, isNull);
        await repo.setStatus('нет', TaskStatus.done);
      },
    );

    test('toggleDone у обычной задачи', () async {
      await repo.createTask(
        _task(1, due: TaskDue.date(DateTime.utc(2026, 10, 5))),
      );
      final t = (await repo.getTask(_uuid(1)))!;
      expect(await repo.toggleDone(t), isTrue);
      final done = (await repo.getTask(_uuid(1)))!;
      expect(done.status, TaskStatus.done);
      expect(await repo.toggleDone(done), isFalse);
      expect((await repo.getTask(_uuid(1)))!.status, TaskStatus.todo);
      // Без срока возвращается во «Входящие».
      final inbox = _task(2, status: TaskStatus.inbox);
      await repo.createTask(inbox);
      await repo.toggleDone(inbox);
      await repo.toggleDone((await repo.getTask(_uuid(2)))!);
      expect((await repo.getTask(_uuid(2)))!.status, TaskStatus.inbox);
    });

    test('правка срока отправляет группу целиком', () async {
      await repo.createTask(_task(1));
      await d.device.sync();
      final t = (await repo.getTask(_uuid(1)))!;
      await repo.updateTask(
        t.copyWith(
          due: TaskDue.at(DateTime.utc(2026, 10, 6, 7), 'Europe/Moscow'),
          priority: 2,
        ),
      );
      final op = (await d.device.store.outbox()).single;
      expect(
        op.fields!.keys,
        containsAll([
          'due_date',
          'due_at',
          'due_tz',
          'rrule',
          'recurrence_mode',
        ]),
      );
      expect(op.fields!['priority'], 2);
      await repo.updateTask((await repo.getTask(_uuid(1)))!);
      expect(await d.device.store.outbox(), hasLength(1));
      expect(() => repo.updateTask(_task(99)), throwsA(isA<StateError>()));
    });

    test('reschedule сохраняет остальное', () async {
      await repo.createTask(_task(1).copyWith(priority: 3));
      await repo.reschedule(_uuid(1), TaskDue.date(DateTime.utc(2026, 10, 9)));
      final t = (await repo.getTask(_uuid(1)))!;
      expect(t.due.date, DateTime.utc(2026, 10, 9));
      expect(t.priority, 3);
      await repo.reschedule('нет', const TaskDue.none());
    });

    test('удаление и восстановление', () async {
      await repo.createTask(_task(1));
      await repo.deleteTask(_uuid(1));
      expect(await d.device.store.visibleRows('tasks'), isEmpty);
      await repo.restoreTask(_uuid(1));
      expect(await d.device.store.visibleRows('tasks'), hasLength(1));
    });

    test('автоархив закрытых задач', () async {
      await repo.createTask(_task(1, status: TaskStatus.done));
      await repo.createTask(_task(2));
      await repo.setStatus(_uuid(1), TaskStatus.cancelled);
      clock.advance(const Duration(days: 40));
      await repo.setStatus(_uuid(2), TaskStatus.done);
      clock.advance(const Duration(days: 1));
      expect(await repo.archiveClosedOlderThan(const Duration(days: 30)), 1);
      expect((await repo.getTask(_uuid(1)))!.archivedAt, isNotNull);
      expect((await repo.getTask(_uuid(2)))!.archivedAt, isNull);
    });
  });

  group('повторяющиеся задачи', () {
    test(
      'schedule: отметка экземпляра, конец серии закрывает задачу',
      () async {
        final task = _task(
          1,
          due: TaskDue.date(DateTime.utc(2026, 10, 5)),
          rrule: 'FREQ=DAILY;COUNT=2',
          mode: RecurrenceMode.schedule,
        );
        await repo.createTask(task);
        expect(await repo.toggleDone(task, instanceDate: '2026-10-05'), isTrue);
        expect((await repo.getTask(_uuid(1)))!.status, TaskStatus.todo);
        expect(
          (await repo.completionOf(_uuid(1), '2026-10-05'))!.skipped,
          isFalse,
        );
        // Повторный тап снимает отметку.
        expect(
          await repo.toggleDone(task, instanceDate: '2026-10-05'),
          isFalse,
        );
        expect(await repo.completionOf(_uuid(1), '2026-10-05'), isNull);
        await repo.markInstance(task, '2026-10-05');
        await repo.markInstance(task, '2026-10-06', skipped: true);
        expect((await repo.getTask(_uuid(1)))!.status, TaskStatus.done);
        expect(await repo.completionsOf(_uuid(1)), hasLength(2));
        // Возврат экземпляра открывает задачу.
        await repo.toggleDone(
          (await repo.getTask(_uuid(1)))!,
          instanceDate: '2026-10-05',
        );
        expect((await repo.getTask(_uuid(1)))!.status, TaskStatus.todo);
        await repo.unmarkInstance(_uuid(1), '2026-10-07');
      },
    );

    test('schedule без указания экземпляра берёт дату срока', () async {
      final task = _task(
        1,
        due: TaskDue.date(DateTime.utc(2026, 10, 5)),
        rrule: 'FREQ=WEEKLY',
        mode: RecurrenceMode.schedule,
      );
      await repo.createTask(task);
      await repo.toggleDone(task);
      expect(await repo.completionOf(_uuid(1), '2026-10-05'), isNotNull);
      expect(
        (await repo.completionOf(_uuid(1), '2026-10-05'))!.id,
        taskCompletionId(_uuid(1), '2026-10-05'),
      );
    });

    test('after_completion: срок сдвигается, задача остаётся todo', () async {
      final task = _task(
        1,
        due: TaskDue.date(DateTime.utc(2026, 10)),
        rrule: 'FREQ=DAILY;INTERVAL=3',
        mode: RecurrenceMode.afterCompletion,
      );
      await repo.createTask(task);
      expect(
        await repo.toggleDone(task, localToday: DateTime.utc(2026, 10, 5)),
        isFalse,
      );
      final t = (await repo.getTask(_uuid(1)))!;
      expect(t.due.date, DateTime.utc(2026, 10, 8));
      expect(t.status, TaskStatus.todo);
      expect(await repo.completionOf(_uuid(1), '2026-10-01'), isNotNull);
    });

    test('after_completion: конец серии закрывает задачу', () async {
      final task = _task(
        1,
        due: TaskDue.date(DateTime.utc(2026, 10)),
        rrule: 'FREQ=DAILY;COUNT=1',
        mode: RecurrenceMode.afterCompletion,
      );
      await repo.createTask(task);
      expect(
        await repo.toggleDone(task, localToday: DateTime.utc(2026, 10, 5)),
        isTrue,
      );
      expect((await repo.getTask(_uuid(1)))!.status, TaskStatus.done);
    });
  });

  group('подзадачи', () {
    test('добавление, порядок, отметка, удаление', () async {
      await repo.createTask(_task(1));
      final a = await repo.addSubtask(_uuid(1), 'Первый');
      final b = await repo.addSubtask(_uuid(1), ' Второй ');
      var list = await repo.subtasksOf(_uuid(1));
      expect(list.map((s) => s.title), ['Первый', 'Второй']);
      expect(list.map((s) => s.position), [subtaskStep, 2 * subtaskStep]);
      await repo.setSubtaskDone(a, done: true);
      await repo.renameSubtask(b, 'Второй!');
      await repo.reorderSubtasks(_uuid(1), [b, a]);
      list = await repo.subtasksOf(_uuid(1));
      expect(list.map((s) => s.title), ['Второй!', 'Первый']);
      expect(list.last.done, isTrue);
      await repo.deleteSubtask(a);
      expect(await repo.subtasksOf(_uuid(1)), hasLength(1));
      await expectLater(
        repo.addSubtask(_uuid(1), ' '),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        repo.renameSubtask(b, ''),
        throwsA(isA<ValidationError>()),
      );
    });
  });

  group('теги, проекты, люди', () {
    test('теги: детерминированный id, набор задачи, восстановление', () async {
      await repo.createTask(_task(1));
      await repo.setTaskTags(_uuid(1), ['Работа', 'дом']);
      var tags = await repo.tagsOfTask(_uuid(1));
      expect(tags.map((t) => t.name), ['Работа', 'дом']);
      expect(tags.first.id, tagId('работа'));
      await repo.setTaskTags(_uuid(1), ['дом']);
      expect((await repo.tagsOfTask(_uuid(1))).map((t) => t.name), ['дом']);
      // Тот же тег другим регистром — та же строка и та же связь.
      await repo.setTaskTags(_uuid(1), ['ДОМ', 'работа']);
      tags = await repo.tagsOfTask(_uuid(1));
      expect(tags, hasLength(2));
      expect(await repo.tags(), hasLength(2));
      await d.device.store.softDelete('tags', tagId('дом'));
      await repo.ensureTag('дом');
      expect(await repo.tags(), hasLength(2));
      await expectLater(
        repo.ensureTag('два слова'),
        throwsA(isA<ValidationError>()),
      );
    });

    test('проекты и люди: поиск без регистра, «_» = пробел', () async {
      final p = await repo.createProject('Бот_разборов');
      expect((await repo.findProject('бот РАЗБОРОВ'))!.id, p);
      expect((await repo.findProject('Бот_разборов'))!.title, 'Бот разборов');
      expect(await repo.findProject('нет'), isNull);
      final person = await repo.createPerson('Елена_К');
      expect((await repo.findPerson('елена к'))!.id, person);
      expect(await repo.findPerson('нет'), isNull);
      expect(await repo.projects(), hasLength(1));
      expect(await repo.people(), hasLength(1));
      await expectLater(
        repo.createProject('  '),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        repo.createPerson(' '),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        repo.createProject('x', color: 'синий'),
        throwsA(isA<ValidationError>()),
      );
    });
  });

  group('быстрый ввод', () {
    final zone = requireLocation('Europe/Moscow');

    test('дата и время: todo, проект/человек/теги создаются', () async {
      final input = parseQuickInput(
        'Позвонить @Елена #creora +срочно !2 завтра 15:00 на час',
        DateTime(2026, 10, 5, 12),
      );
      final result = await repo.createFromQuickInput(input, zone: zone);
      expect(result.created, ['#creora', '@Елена']);
      final t = (await repo.getTask(result.taskId))!;
      expect(t.title, 'Позвонить');
      expect(t.status, TaskStatus.todo);
      expect(t.priority, 2);
      expect(t.due.at, DateTime.utc(2026, 10, 6, 12));
      expect(t.due.tz, 'Europe/Moscow');
      expect(t.durationMinutes, 60);
      expect(t.projectId, isNotNull);
      expect((await repo.tagsOfTask(t.id)).single.name, 'срочно');
      // Второй раз: проект и человек уже есть.
      final again = await repo.createFromQuickInput(input, zone: zone);
      expect(again.created, isEmpty);
    });

    test('без даты — Входящие; только дата — задача с датой', () async {
      final plain = await repo.createFromQuickInput(
        parseQuickInput('Купить хлеб', DateTime(2026, 10, 5, 12)),
        zone: zone,
      );
      expect((await repo.getTask(plain.taskId))!.status, TaskStatus.inbox);
      final dated = await repo.createFromQuickInput(
        parseQuickInput('Сдать отчёт 15 октября', DateTime(2026, 10, 5, 12)),
        zone: zone,
      );
      final t = (await repo.getTask(dated.taskId))!;
      expect(t.due.date, DateTime.utc(2026, 10, 15));
      expect(t.status, TaskStatus.todo);
    });

    test('пустое название — ошибка и ничего не пишется', () async {
      await expectLater(
        repo.createFromQuickInput(
          parseQuickInput('#проект', DateTime(2026, 10, 5, 12)),
          zone: zone,
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(await repo.projects(), isEmpty);
    });
  });

  test('civil: справочно', () {
    expect(formatDate(DateTime.utc(2026, 10, 5)), '2026-10-05');
  });
}
