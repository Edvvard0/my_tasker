import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/quick_input/quick_input_parser.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/tasks/domain/recurring_tasks.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/domain/task_validation.dart';
import 'package:timezone/timezone.dart' as tz;

/// Шаг позиции пунктов чек-листа (spec 4.2).
const int subtaskStep = 1024;

/// Совпадение имени `#проект`/`@человек` со строкой: без учёта регистра,
/// `_` приравнивается к пробелу (spec 4.3).
String matchKey(String name) => name.replaceAll('_', ' ').trim().toLowerCase();

/// Что записал быстрый ввод.
class QuickTaskResult {
  const QuickTaskResult({required this.taskId, required this.created});

  final String taskId;

  /// Созданные по ходу проекты/люди/теги (для сообщения пользователю).
  final List<String> created;
}

/// Задачи, подзадачи, теги, проекты, люди и отметки выполнения: локальные
/// записи через [SyncStore] (строка + HLC + outbox в одной транзакции).
class TaskRepository {
  TaskRepository(
    this._store, {
    String Function()? newId,
    DateTime Function()? now,
  }) : _newId = newId ?? uuid7,
       _now = now ?? DateTime.now;

  final SyncStore _store;
  final String Function() _newId;
  final DateTime Function() _now;

  static const String tasksTable = 'tasks';
  static const String subtasksTable = 'subtasks';
  static const String tagsTable = 'tags';
  static const String taskTagsTable = 'task_tags';
  static const String projectsTable = 'projects';
  static const String peopleTable = 'people';
  static const String completionsTable = 'task_completions';

  DateTime get _nowUtc => _now().toUtc();

  // ---- задачи --------------------------------------------------------------

  Future<TaskEntity?> getTask(String id) async {
    final row = await _store.getRow(tasksTable, id);
    return row == null ? null : TaskEntity.fromRow(row);
  }

  String newTaskId() => _newId();

  /// Создаёт задачу; `task.id` задаёт вызывающий.
  Future<String> createTask(TaskEntity task) async {
    ensureValid(taskProblem(task));
    await _store.create(
      tasksTable,
      task.id,
      task.copyWith(title: task.title.trim()).toFields(),
    );
    return task.id;
  }

  /// Правка задачи. Связанные группы уходят целиком (spec 0): срок
  /// `(due_date, due_at, due_tz)`, правило с сроком и режимом,
  /// `(status, completed_at)`.
  Future<void> updateTask(TaskEntity next) async {
    ensureValid(taskProblem(next));
    await _store.transaction(() async {
      final current = await getTask(next.id);
      if (current == null) throw StateError('Задачи ${next.id} нет');
      final before = current.toFields();
      final after = next.copyWith(title: next.title.trim()).toFields();
      final fields = <String, Object?>{
        for (final e in after.entries)
          if (_differs(before[e.key], e.value)) e.key: e.value,
      };
      const dueGroup = ['due_date', 'due_at', 'due_tz'];
      const ruleGroup = ['rrule', 'recurrence_mode'];
      const statusGroup = ['status', 'completed_at'];
      void whole(List<String> group) {
        for (final k in group) {
          fields[k] = after[k];
        }
      }

      if (dueGroup.any(fields.containsKey) ||
          ruleGroup.any(fields.containsKey)) {
        whole(dueGroup);
        whole(ruleGroup);
      }
      if (statusGroup.any(fields.containsKey)) whole(statusGroup);
      if (fields.isEmpty) return;
      await _store.update(tasksTable, next.id, fields);
    });
  }

  bool _differs(Object? a, Object? b) {
    if (a is List && b is List) return a.toString() != b.toString();
    return a != b;
  }

  /// Смена статуса: переход в `done` ставит `completed_at = now`, выход из
  /// `done` — `null`; оба поля уходят одной операцией (spec 4.1).
  Future<void> setStatus(String id, TaskStatus status) async {
    final task = await getTask(id);
    if (task == null) return;
    if (task.status == status) return;
    final completedAt = switch (status) {
      TaskStatus.done => _nowUtc,
      _ => null,
    };
    await _store.update(tasksTable, id, {
      'status': status.wire,
      'completed_at': storedInstant(completedAt),
    });
  }

  /// Отметка «выполнено»/«не выполнено» для задачи любого вида.
  /// Повторяющуюся задачу `after_completion` сдвигает на следующий срок,
  /// а `schedule` — отмечает экземпляр [instanceDate] (по умолчанию
  /// ближайший необработанный). Возвращает `true`, если задача закрыта.
  Future<bool> toggleDone(
    TaskEntity task, {
    String? instanceDate,
    DateTime? localToday,
  }) async {
    if (task.isRecurring && task.recurrenceMode != null) {
      return await _toggleRecurring(task, instanceDate, localToday);
    }
    final wasDone = task.status == TaskStatus.done;
    await setStatus(
      task.id,
      wasDone
          ? (task.due.isNone ? TaskStatus.inbox : TaskStatus.todo)
          : TaskStatus.done,
    );
    return !wasDone;
  }

  Future<bool> _toggleRecurring(
    TaskEntity task,
    String? instanceDate,
    DateTime? localToday,
  ) async {
    final date =
        instanceDate ??
        formatDate(task.due.localDate ?? localToday ?? dateOnly(_nowUtc));
    if (task.recurrenceMode == RecurrenceMode.schedule) {
      final existing = await completionOf(task.id, date);
      if (existing != null && !existing.skipped) {
        await unmarkInstance(task.id, date);
        // Возврат экземпляра открывает задачу, если серия была закрыта.
        if (task.status == TaskStatus.done) {
          await setStatus(task.id, TaskStatus.todo);
        }
        return false;
      }
      await markInstance(task, date);
      return true;
    }
    // after_completion: сдвиг срока на следующее значение.
    final today = localToday ?? dateOnly(_nowUtc);
    final next = nextDueAfterCompletion(task, today);
    await _store.transaction(() async {
      await _writeCompletion(task.id, date, skipped: false);
      if (next == null) {
        await setStatus(task.id, TaskStatus.done);
      } else {
        await _store.update(tasksTable, task.id, {
          ...task.copyWith(due: next.due, rrule: next.rrule).dueFields(),
          'rrule': next.rrule,
          'recurrence_mode': task.recurrenceMode!.wire,
        });
      }
    });
    return next == null;
  }

  Future<void> deleteTask(String id) => _store.softDelete(tasksTable, id);

  Future<void> restoreTask(String id) => _store.restore(tasksTable, id);

  /// Переносит на новый срок; повторения и напоминания остаются.
  Future<void> reschedule(String id, TaskDue due) async {
    final task = await getTask(id);
    if (task == null) return;
    // Задача из «Входящих», которой назначили срок, становится «К выполнению».
    final status = task.status == TaskStatus.inbox && !due.isNone
        ? TaskStatus.todo
        : task.status;
    await updateTask(task.copyWith(due: due, status: status));
  }

  /// Автоархив: `archived_at` у `done`/`cancelled` старше [age] (spec 4.1).
  Future<int> archiveClosedOlderThan(Duration age) async {
    final cutoff = _nowUtc.subtract(age);
    final rows = await _store.visibleRows(
      tasksTable,
      where: "t.archived_at IS NULL AND t.status IN ('done', 'cancelled')",
    );
    var count = 0;
    for (final r in rows) {
      final task = TaskEntity.fromRow(r);
      final closedAt = task.completedAt ?? task.createdAt;
      if (closedAt != null && closedAt.isBefore(cutoff)) {
        await _store.update(tasksTable, task.id, {
          'archived_at': storedInstant(_nowUtc),
        });
        count++;
      }
    }
    return count;
  }

  // ---- отметки экземпляров ---------------------------------------------------

  Future<TaskCompletion?> completionOf(String taskId, String date) async {
    final row = await _store.getRow(
      completionsTable,
      taskCompletionId(taskId, date),
    );
    if (row == null || row['deleted_at'] != null) return null;
    return TaskCompletion.fromRow(row);
  }

  Future<Map<String, TaskCompletion>> completionsOf(String taskId) async => {
    for (final r in await _store.visibleRows(
      completionsTable,
      where: 't.task_id = ?',
      args: [taskId],
    ))
      r['instance_date']! as String: TaskCompletion.fromRow(r),
  };

  Future<void> _writeCompletion(
    String taskId,
    String date, {
    required bool skipped,
  }) async {
    final id = taskCompletionId(taskId, date);
    final row = await _store.getRow(completionsTable, id);
    final fields = {
      'state': skipped ? 'skipped' : 'done',
      'completed_at': storedInstant(_nowUtc),
    };
    if (row == null) {
      await _store.create(completionsTable, id, {
        'task_id': taskId,
        'instance_date': date,
        ...fields,
      });
      return;
    }
    await _store.update(completionsTable, id, fields);
    if (row['deleted_at'] != null) await _store.restore(completionsTable, id);
  }

  /// Отмечает экземпляр [date] задачи `schedule` выполненным (или
  /// пропущенным). Когда экземпляров больше нет и все отмечены — задача
  /// переходит в `done` (spec 4.1).
  Future<void> markInstance(
    TaskEntity task,
    String date, {
    bool skipped = false,
  }) => _store.transaction(() async {
    await _writeCompletion(task.id, date, skipped: skipped);
    final completions = await completionsOf(task.id);
    if (isSeriesFinished(task, completions)) {
      await setStatus(task.id, TaskStatus.done);
    }
  });

  /// Снимает отметку экземпляра.
  Future<void> unmarkInstance(String taskId, String date) async {
    final id = taskCompletionId(taskId, date);
    final row = await _store.getRow(completionsTable, id);
    if (row != null && row['deleted_at'] == null) {
      await _store.softDelete(completionsTable, id);
    }
  }

  // ---- подзадачи ---------------------------------------------------------------

  Future<List<Subtask>> subtasksOf(String taskId) async => [
    for (final r in await _store.visibleRows(
      subtasksTable,
      where: 't.task_id = ?',
      args: [taskId],
      orderBy: 't.position, t.id',
    ))
      Subtask.fromRow(r),
  ];

  /// Добавляет пункт в конец списка (шаг [subtaskStep]).
  Future<String> addSubtask(String taskId, String title) async {
    ensureValid(nameProblem(title, 500, what: 'Пункт'));
    final id = _newId();
    await _store.transaction(() async {
      final list = await subtasksOf(taskId);
      final position = list.isEmpty
          ? subtaskStep
          : list.last.position + subtaskStep;
      await _store.create(subtasksTable, id, {
        'task_id': taskId,
        'title': title.trim(),
        'done': false,
        'position': position,
      });
    });
    return id;
  }

  Future<void> renameSubtask(String id, String title) async {
    ensureValid(nameProblem(title, 500, what: 'Пункт'));
    await _store.update(subtasksTable, id, {'title': title.trim()});
  }

  Future<void> setSubtaskDone(String id, {required bool done}) =>
      _store.update(subtasksTable, id, {'done': done});

  Future<void> deleteSubtask(String id) => _store.softDelete(subtasksTable, id);

  /// Переставляет пункты в порядке [orderedIds] с шагом [subtaskStep]
  /// (перенумерация одной транзакцией).
  Future<void> reorderSubtasks(String taskId, List<String> orderedIds) =>
      _store.transaction(() async {
        final current = {for (final s in await subtasksOf(taskId)) s.id: s};
        for (var i = 0; i < orderedIds.length; i++) {
          final s = current[orderedIds[i]];
          final position = (i + 1) * subtaskStep;
          if (s != null && s.position != position) {
            await _store.update(subtasksTable, s.id, {'position': position});
          }
        }
      });

  // ---- проекты, люди, теги -------------------------------------------------------

  Future<List<Project>> projects({bool includeArchived = false}) async => [
    for (final r in await _store.visibleRows(projectsTable, orderBy: 't.title'))
      if (includeArchived || r['archived'] != true) Project.fromRow(r),
  ];

  Future<List<Person>> people({bool includeArchived = false}) async => [
    for (final r in await _store.visibleRows(peopleTable, orderBy: 't.name'))
      if (includeArchived || r['archived'] != true) Person.fromRow(r),
  ];

  Future<List<Tag>> tags() async => [
    for (final r in await _store.visibleRows(tagsTable, orderBy: 't.name'))
      Tag.fromRow(r),
  ];

  /// Проект по имени (без учёта регистра, `_` = пробел) или `null`.
  Future<Project?> findProject(String name) async {
    final key = matchKey(name);
    for (final p in await projects(includeArchived: true)) {
      if (matchKey(p.title) == key) return p;
    }
    return null;
  }

  Future<Person?> findPerson(String name) async {
    final key = matchKey(name);
    for (final p in await people(includeArchived: true)) {
      if (matchKey(p.name) == key) return p;
    }
    return null;
  }

  Future<String> createProject(String title, {String? color}) async {
    final name = title.replaceAll('_', ' ').trim();
    ensureValid(nameProblem(name, 200));
    ensureValid(colorProblem(color));
    final id = _newId();
    await _store.create(projectsTable, id, {
      'title': name,
      'color': color,
      'archived': false,
    });
    return id;
  }

  Future<String> createPerson(String name) async {
    final clean = name.replaceAll('_', ' ').trim();
    ensureValid(nameProblem(clean, 100));
    final id = _newId();
    await _store.create(peopleTable, id, {'name': clean, 'archived': false});
    return id;
  }

  /// Тег по имени: создаётся с детерминированным id (spec 4.3); если тег
  /// в корзине — возвращается из неё.
  Future<Tag> ensureTag(String name) async {
    final clean = name.trim();
    if (!isValidTagName(clean)) {
      throw const ValidationError('Имя тега: без пробелов и символов # @ + !');
    }
    final id = tagId(clean);
    var row = await _store.getRow(tagsTable, id);
    if (row == null) {
      row = await _store.create(tagsTable, id, {'name': clean, 'color': null});
    } else if (row['deleted_at'] != null) {
      await _store.restore(tagsTable, id);
    }
    return Tag.fromRow(row);
  }

  Future<List<Tag>> tagsOfTask(String taskId) async {
    final links = await _store.visibleRows(
      taskTagsTable,
      where: 't.task_id = ?',
      args: [taskId],
    );
    final ids = {for (final l in links) l['tag_id']! as String};
    return [
      for (final t in await tags())
        if (ids.contains(t.id)) t,
    ];
  }

  /// Задаёт набор тегов задачи: недостающие связи создаются (или
  /// восстанавливаются) с детерминированным id, лишние — удаляются.
  Future<void> setTaskTags(String taskId, List<String> names) =>
      _store.transaction(() async {
        final wanted = <String, Tag>{};
        for (final n in names) {
          final tag = await ensureTag(n);
          wanted[tag.id] = tag;
        }
        final existing = await _store.visibleRows(
          taskTagsTable,
          where: 't.task_id = ?',
          args: [taskId],
        );
        final have = {for (final l in existing) l['tag_id']! as String};
        for (final l in existing) {
          if (!wanted.containsKey(l['tag_id'])) {
            await _store.softDelete(taskTagsTable, l['id']! as String);
          }
        }
        for (final tag in wanted.values) {
          if (have.contains(tag.id)) continue;
          final id = taskTagId(taskId, tag.id);
          final row = await _store.getRow(taskTagsTable, id);
          if (row == null) {
            await _store.create(taskTagsTable, id, {
              'task_id': taskId,
              'tag_id': tag.id,
            });
          } else if (row['deleted_at'] != null) {
            await _store.restore(taskTagsTable, id);
          }
        }
      });

  // ---- быстрый ввод ------------------------------------------------------------

  /// Создаёт задачу из разобранной строки быстрого ввода (spec 4.1: `todo`,
  /// если указана дата или время, иначе `inbox`). Проекты, люди и теги,
  /// которых нет, создаются. [zone] — таймзона устройства для срока со
  /// временем. Вернёт [ValidationError], если названия нет.
  Future<QuickTaskResult> createFromQuickInput(
    QuickInput input, {
    required tz.Location zone,
  }) async {
    final created = <String>[];
    late String id;
    await _store.transaction(() async {
      String? projectId;
      if (input.project != null) {
        final found = await findProject(input.project!);
        if (found == null) {
          projectId = await createProject(input.project!);
          created.add('#${input.project}');
        } else {
          projectId = found.id;
        }
      }
      String? personId;
      if (input.people.isNotEmpty) {
        final name = input.people.first;
        final found = await findPerson(name);
        if (found == null) {
          personId = await createPerson(name);
          created.add('@$name');
        } else {
          personId = found.id;
        }
      }
      final due = _dueOf(input, zone);
      id = _newId();
      await createTask(
        TaskEntity(
          id: id,
          title: input.title,
          status: due.isNone ? TaskStatus.inbox : TaskStatus.todo,
          priority: input.priority,
          due: due,
          durationMinutes: due.hasTime ? input.durationMinutes : null,
          projectId: projectId,
          personId: personId,
        ),
      );
      if (input.tags.isNotEmpty) await setTaskTags(id, input.tags);
    });
    return QuickTaskResult(taskId: id, created: created);
  }

  TaskDue _dueOf(QuickInput input, tz.Location zone) {
    final date = input.date == null ? null : parseDate(input.date!);
    if (date == null) return const TaskDue.none();
    final time = input.time;
    if (time == null) return TaskDue.date(date);
    final hour = int.parse(time.substring(0, 2));
    final minute = int.parse(time.substring(3, 5));
    return TaskDue.at(
      wallToUtc(zone, date.year, date.month, date.day, hour, minute),
      zone.name,
    );
  }
}

final taskRepositoryProvider = Provider<TaskRepository>(
  (ref) => TaskRepository(
    ref.watch(syncStoreProvider),
    now: ref.watch(clockProvider),
  ),
);
