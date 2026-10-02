import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/expansion.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';

const Object _unset = Object();

/// Статус задачи (docs/04, 1.1 #5; spec 4.1).
enum TaskStatus {
  inbox('Входящие'),
  todo('К выполнению'),
  inProgress('В работе'),
  done('Выполнено'),
  cancelled('Отменено');

  const TaskStatus(this.label);

  final String label;

  /// Значение колонки `status`.
  String get wire => switch (this) {
    inbox => 'inbox',
    todo => 'todo',
    inProgress => 'in_progress',
    done => 'done',
    cancelled => 'cancelled',
  };

  static TaskStatus parse(Object? value) => TaskStatus.values.firstWhere(
    (s) => s.wire == value,
    orElse: () => TaskStatus.todo,
  );

  /// Задача закрыта (выполнена или отменена).
  bool get isClosed => this == done || this == cancelled;
}

/// Режим повторения задачи (spec 4.1).
enum RecurrenceMode {
  schedule('По расписанию'),
  afterCompletion('От даты выполнения');

  const RecurrenceMode(this.label);

  final String label;

  String get wire => this == schedule ? 'schedule' : 'after_completion';

  static RecurrenceMode? parse(Object? value) => switch (value) {
    'schedule' => schedule,
    'after_completion' => afterCompletion,
    _ => null,
  };
}

/// Источник задачи (spec 4.1).
enum TaskSource { manual, ai, telegram, import }

/// Срок задачи: без срока, дата или момент с таймзоной.
@immutable
class TaskDue {
  const TaskDue.none() : date = null, at = null, tz = null;

  const TaskDue.date(DateTime this.date) : at = null, tz = null;

  const TaskDue.at(DateTime this.at, String this.tz) : date = null;

  final DateTime? date;
  final DateTime? at;
  final String? tz;

  bool get isNone => date == null && at == null;
  bool get hasTime => at != null;
  bool get hasDate => date != null;

  /// Локальная дата срока (для момента — в его зоне [tz]).
  DateTime? get localDate {
    if (date != null) return date;
    if (at == null) return null;
    final zone = findLocation(tz!);
    return zone == null ? dateOnly(at!) : dateOnly(utcToWall(zone, at!));
  }

  @override
  bool operator ==(Object other) =>
      other is TaskDue &&
      other.date == date &&
      other.at == at &&
      other.tz == tz;

  @override
  int get hashCode => Object.hash(date, at, tz);
}

/// Задача (`tasks`).
@immutable
class TaskEntity {
  const TaskEntity({
    required this.id,
    required this.title,
    required this.status,
    this.notes,
    this.priority,
    this.due = const TaskDue.none(),
    this.durationMinutes,
    this.rrule,
    this.recurrenceMode,
    this.completedAt,
    this.archivedAt,
    this.projectId,
    this.personId,
    this.reminders,
    this.sortOrder,
    this.source = TaskSource.manual,
    this.createdAt,
  });

  factory TaskEntity.fromRow(Json row) {
    final dueAt = parseStoredInstant(row['due_at']);
    final dueDate = parseStoredDate(row['due_date']);
    return TaskEntity(
      id: row['id']! as String,
      title: row['title']! as String,
      status: TaskStatus.parse(row['status']),
      notes: row['notes'] as String?,
      priority: row['priority'] as int?,
      due: dueAt != null
          ? TaskDue.at(dueAt, (row['due_tz'] as String?) ?? 'UTC')
          : dueDate != null
          ? TaskDue.date(dueDate)
          : const TaskDue.none(),
      durationMinutes: row['duration_minutes'] as int?,
      rrule: row['rrule'] as String?,
      recurrenceMode: RecurrenceMode.parse(row['recurrence_mode']),
      completedAt: parseStoredInstant(row['completed_at']),
      archivedAt: parseStoredInstant(row['archived_at']),
      projectId: row['project_id'] as String?,
      personId: row['person_id'] as String?,
      reminders: parseReminders(row['reminders']),
      sortOrder: row['sort_order'] as int?,
      source: TaskSource.values.firstWhere(
        (s) => s.name == row['source'],
        orElse: () => TaskSource.manual,
      ),
      createdAt: parseStoredInstant(row['created_at']),
    );
  }

  final String id;
  final String title;
  final TaskStatus status;
  final String? notes;
  final int? priority;
  final TaskDue due;
  final int? durationMinutes;
  final String? rrule;
  final RecurrenceMode? recurrenceMode;
  final DateTime? completedAt;
  final DateTime? archivedAt;
  final String? projectId;
  final String? personId;
  final List<int>? reminders;
  final int? sortOrder;
  final TaskSource source;
  final DateTime? createdAt;

  bool get isRecurring => rrule != null;

  /// Длина блока в сетке (по умолчанию 60 минут, spec 4.1).
  int get blockMinutes => durationMinutes ?? 60;

  bool get isOpen => !status.isClosed;

  /// Прикладные колонки строки `tasks`.
  Json toFields() => {
    'title': title,
    'notes': notes,
    'status': status.wire,
    'priority': priority,
    'due_date': storedDate(due.date),
    'due_at': storedInstant(due.at),
    'due_tz': due.tz,
    'duration_minutes': durationMinutes,
    'rrule': rrule,
    'recurrence_mode': recurrenceMode?.wire,
    'completed_at': storedInstant(completedAt),
    'archived_at': storedInstant(archivedAt),
    'project_id': projectId,
    'person_id': personId,
    'reminders': reminders,
    'sort_order': sortOrder,
    'source': source.name,
  };

  /// Колонки срока: уходят в одной операции целиком (spec 0).
  Json dueFields() => {
    'due_date': storedDate(due.date),
    'due_at': storedInstant(due.at),
    'due_tz': due.tz,
  };

  /// Серия повторений задачи (spec 4.1: `due_date` — как «весь день»,
  /// `due_at` — как событие длиной `duration_minutes`, 0 если не задана).
  SeriesDefinition? get series {
    if (rrule == null || due.isNone) return null;
    final rule = RRule.parse(rrule!, allDay: !due.hasTime);
    if (!due.hasTime) {
      return SeriesDefinition.allDay(
        startDate: due.date!,
        endDate: due.date!,
        rule: rule,
      );
    }
    final zone = findLocation(due.tz!);
    if (zone == null) return null;
    return SeriesDefinition.timed(
      location: zone,
      startUtc: due.at!,
      endUtc: due.at!.add(Duration(minutes: durationMinutes ?? 0)),
      rule: rule,
    );
  }

  TaskEntity copyWith({
    String? title,
    TaskStatus? status,
    Object? notes = _unset,
    Object? priority = _unset,
    TaskDue? due,
    Object? durationMinutes = _unset,
    Object? rrule = _unset,
    Object? recurrenceMode = _unset,
    Object? completedAt = _unset,
    Object? archivedAt = _unset,
    Object? projectId = _unset,
    Object? personId = _unset,
    Object? reminders = _unset,
    Object? sortOrder = _unset,
    TaskSource? source,
  }) => TaskEntity(
    id: id,
    title: title ?? this.title,
    status: status ?? this.status,
    notes: identical(notes, _unset) ? this.notes : notes as String?,
    priority: identical(priority, _unset) ? this.priority : priority as int?,
    due: due ?? this.due,
    durationMinutes: identical(durationMinutes, _unset)
        ? this.durationMinutes
        : durationMinutes as int?,
    rrule: identical(rrule, _unset) ? this.rrule : rrule as String?,
    recurrenceMode: identical(recurrenceMode, _unset)
        ? this.recurrenceMode
        : recurrenceMode as RecurrenceMode?,
    completedAt: identical(completedAt, _unset)
        ? this.completedAt
        : completedAt as DateTime?,
    archivedAt: identical(archivedAt, _unset)
        ? this.archivedAt
        : archivedAt as DateTime?,
    projectId: identical(projectId, _unset)
        ? this.projectId
        : projectId as String?,
    personId: identical(personId, _unset) ? this.personId : personId as String?,
    reminders: identical(reminders, _unset)
        ? this.reminders
        : reminders as List<int>?,
    sortOrder: identical(sortOrder, _unset)
        ? this.sortOrder
        : sortOrder as int?,
    source: source ?? this.source,
    createdAt: createdAt,
  );
}

/// Пункт чек-листа (`subtasks`).
@immutable
class Subtask {
  const Subtask({
    required this.id,
    required this.taskId,
    required this.title,
    required this.done,
    required this.position,
  });

  factory Subtask.fromRow(Json row) => Subtask(
    id: row['id']! as String,
    taskId: row['task_id']! as String,
    title: row['title']! as String,
    done: row['done']! as bool,
    position: row['position']! as int,
  );

  final String id;
  final String taskId;
  final String title;
  final bool done;
  final int position;
}

/// Проект (минимальный, Этап 2).
@immutable
class Project {
  const Project({
    required this.id,
    required this.title,
    required this.archived,
    this.color,
  });

  factory Project.fromRow(Json row) => Project(
    id: row['id']! as String,
    title: row['title']! as String,
    color: row['color'] as String?,
    archived: row['archived']! as bool,
  );

  final String id;
  final String title;
  final String? color;
  final bool archived;
}

/// Человек (минимальный, Этап 2).
@immutable
class Person {
  const Person({required this.id, required this.name, required this.archived});

  factory Person.fromRow(Json row) => Person(
    id: row['id']! as String,
    name: row['name']! as String,
    archived: row['archived']! as bool,
  );

  final String id;
  final String name;
  final bool archived;
}

/// Тег.
@immutable
class Tag {
  const Tag({required this.id, required this.name, this.color});

  factory Tag.fromRow(Json row) => Tag(
    id: row['id']! as String,
    name: row['name']! as String,
    color: row['color'] as String?,
  );

  final String id;
  final String name;
  final String? color;
}

/// Отметка экземпляра повторяющейся задачи.
@immutable
class TaskCompletion {
  const TaskCompletion({
    required this.id,
    required this.taskId,
    required this.instanceDate,
    required this.skipped,
    required this.completedAt,
  });

  factory TaskCompletion.fromRow(Json row) => TaskCompletion(
    id: row['id']! as String,
    taskId: row['task_id']! as String,
    instanceDate: row['instance_date']! as String,
    skipped: row['state'] == 'skipped',
    completedAt: parseStoredInstant(row['completed_at'])!,
  );

  final String id;
  final String taskId;
  final String instanceDate;
  final bool skipped;
  final DateTime completedAt;
}
