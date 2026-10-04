import 'package:drift/drift.dart';

// DSL-описания таблиц исполняются только генератором кода (drift_dev).
// coverage:ignore-start

/// Служебные колонки каждой синхронизируемой таблицы (spec Этапа 1, 3.1).
/// Прикладные колонки — по `docs/specs/stage2_calendar_tasks.md`.
/// Внешних ключей SQLite нет: строки приходят в порядке `server_version`,
/// родитель может прийти позже потомка (видимость считает `SyncStore`).
mixin SyncColumns on Table {
  TextColumn get id => text()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  IntColumn get serverVersion => integer().withDefault(const Constant(0))();
  TextColumn get originDeviceId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Слои календаря (spec 3.1).
@DataClassName('CalendarRow')
class Calendars extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();
  TextColumn get kind => text()();
  TextColumn get systemKey => text().nullable()();
  BoolColumn get visible => boolean()();
  IntColumn get position => integer()();

  @override
  String get tableName => 'calendars';
}

/// События (spec 3.2).
@DataClassName('EventRow')
@TableIndex(name: 'events_calendar_idx', columns: {#calendarId})
class Events extends Table with SyncColumns {
  TextColumn get calendarId => text()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get location => text().nullable()();
  BoolColumn get allDay => boolean()();
  TextColumn get startAt => text().nullable()();
  TextColumn get endAt => text().nullable()();
  TextColumn get tz => text().nullable()();
  TextColumn get startDate => text().nullable()();
  TextColumn get endDate => text().nullable()();
  TextColumn get rrule => text().nullable()();
  TextColumn get reminders => text().nullable()();
  TextColumn get source => text()();

  @override
  String get tableName => 'events';
}

/// Переопределения экземпляров повторяющихся событий (spec 3.3).
@DataClassName('EventOverrideRow')
@TableIndex(name: 'event_overrides_event_idx', columns: {#eventId})
class EventOverrides extends Table with SyncColumns {
  TextColumn get eventId => text()();
  TextColumn get originalStart => text()();
  BoolColumn get cancelled => boolean()();
  TextColumn get title => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get location => text().nullable()();
  TextColumn get startAt => text().nullable()();
  TextColumn get endAt => text().nullable()();
  TextColumn get startDate => text().nullable()();
  TextColumn get endDate => text().nullable()();
  TextColumn get reminders => text().nullable()();

  @override
  String get tableName => 'event_overrides';
}

/// Проекты: заготовка Этапа 2 (spec 4.3) + колонки Этапа 4
/// (`docs/specs/stage4_work.md`, 1.1) — все необязательные.
@DataClassName('ProjectRow')
class Projects extends Table with SyncColumns {
  TextColumn get title => text()();
  TextColumn get color => text().nullable()();
  BoolColumn get archived => boolean()();
  TextColumn get clientId => text().nullable()();
  TextColumn get status => text().nullable()();
  TextColumn get payType => text().nullable()();
  IntColumn get baseAmount => integer().nullable()();
  IntColumn get hourlyRate => integer().nullable()();
  TextColumn get startDate => text().nullable()();
  TextColumn get deadlineDate => text().nullable()();
  TextColumn get completedDate => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get links => text().nullable()();

  @override
  String get tableName => 'projects';
}

/// Люди: заготовка Этапа 2 (spec 4.3) + `role` и `contact` Этапа 4 (1.2).
@DataClassName('PersonRow')
class People extends Table with SyncColumns {
  TextColumn get name => text()();
  BoolColumn get archived => boolean()();
  TextColumn get role => text().nullable()();
  TextColumn get contact => text().nullable()();

  @override
  String get tableName => 'people';
}

/// Теги: `id = uuid5(ns("tags"), lower(name))` (spec 4.3).
@DataClassName('TagRow')
class Tags extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();

  @override
  String get tableName => 'tags';
}

/// Задачи (spec 4.1).
@DataClassName('TaskRow')
@TableIndex(name: 'tasks_due_date_idx', columns: {#dueDate})
@TableIndex(name: 'tasks_due_at_idx', columns: {#dueAt})
class Tasks extends Table with SyncColumns {
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get status => text()();
  IntColumn get priority => integer().nullable()();
  TextColumn get dueDate => text().nullable()();
  TextColumn get dueAt => text().nullable()();
  TextColumn get dueTz => text().nullable()();
  IntColumn get durationMinutes => integer().nullable()();
  TextColumn get rrule => text().nullable()();
  TextColumn get recurrenceMode => text().nullable()();
  TextColumn get completedAt => text().nullable()();
  TextColumn get archivedAt => text().nullable()();
  TextColumn get projectId => text().nullable()();
  TextColumn get personId => text().nullable()();
  TextColumn get reminders => text().nullable()();
  IntColumn get sortOrder => integer().nullable()();
  TextColumn get source => text()();

  @override
  String get tableName => 'tasks';
}

/// Подзадачи-пункты чек-листа (spec 4.2).
@DataClassName('SubtaskRow')
@TableIndex(name: 'subtasks_task_idx', columns: {#taskId})
class Subtasks extends Table with SyncColumns {
  TextColumn get taskId => text()();
  TextColumn get title => text()();
  BoolColumn get done => boolean()();
  IntColumn get position => integer()();

  @override
  String get tableName => 'subtasks';
}

/// Связь задача–тег (spec 4.4).
@DataClassName('TaskTagRow')
@TableIndex(name: 'task_tags_task_idx', columns: {#taskId})
class TaskTags extends Table with SyncColumns {
  TextColumn get taskId => text()();
  TextColumn get tagId => text()();

  @override
  String get tableName => 'task_tags';
}

/// Отметки выполнения экземпляров повторяющихся задач (spec 4.4).
@DataClassName('TaskCompletionRow')
@TableIndex(name: 'task_completions_task_idx', columns: {#taskId})
class TaskCompletions extends Table with SyncColumns {
  TextColumn get taskId => text()();
  TextColumn get instanceDate => text()();
  TextColumn get state => text()();
  TextColumn get completedAt => text()();

  @override
  String get tableName => 'task_completions';
}

// coverage:ignore-end
