import 'package:my_tasker/core/sync/sync_table.dart';

/// Синхронизируемые таблицы задач (spec Этапа 2, раздел 4).

/// `projects` — проекты: заготовка Этапа 2 (spec 4.3) и колонки Этапа 4
/// (`stage4_work.md`, 1.1), все необязательные.
const SyncTableSpec projectsSpec = SyncTableSpec(
  name: 'projects',
  label: 'Проект',
  columns: [
    SyncColumn('title', SyncColumnType.text),
    SyncColumn('color', SyncColumnType.text, nullable: true),
    SyncColumn('archived', SyncColumnType.boolean),
    // Мягкая ссылка на заказчика (`people.id`), без FK и каскада.
    SyncColumn('client_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('status', SyncColumnType.text, nullable: true),
    SyncColumn('pay_type', SyncColumnType.text, nullable: true),
    SyncColumn('base_amount', SyncColumnType.integer, nullable: true),
    SyncColumn('hourly_rate', SyncColumnType.integer, nullable: true),
    SyncColumn('start_date', SyncColumnType.text, nullable: true),
    SyncColumn('deadline_date', SyncColumnType.text, nullable: true),
    SyncColumn('completed_date', SyncColumnType.text, nullable: true),
    SyncColumn('description', SyncColumnType.text, nullable: true),
    SyncColumn('links', SyncColumnType.json, nullable: true),
  ],
  titleOf: _title,
);

/// `people` — люди: заготовка Этапа 2 (spec 4.3) и `role`/`contact`
/// Этапа 4 (`stage4_work.md`, 1.2).
const SyncTableSpec peopleSpec = SyncTableSpec(
  name: 'people',
  label: 'Человек',
  columns: [
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('archived', SyncColumnType.boolean),
    SyncColumn('role', SyncColumnType.text, nullable: true),
    SyncColumn('contact', SyncColumnType.text, nullable: true),
  ],
  titleOf: _name,
);

/// `tags` — теги (spec 4.3); имя неизменяемо, id — `uuid5(lower(name))`.
const SyncTableSpec tagsSpec = SyncTableSpec(
  name: 'tags',
  label: 'Тег',
  columns: [
    SyncColumn('name', SyncColumnType.text, immutable: true),
    SyncColumn('color', SyncColumnType.text, nullable: true),
  ],
  titleOf: _name,
);

/// `tasks` — задачи (spec 4.1).
const SyncTableSpec tasksSpec = SyncTableSpec(
  name: 'tasks',
  label: 'Задача',
  columns: [
    SyncColumn('title', SyncColumnType.text),
    SyncColumn('notes', SyncColumnType.text, nullable: true),
    SyncColumn('status', SyncColumnType.text),
    SyncColumn('priority', SyncColumnType.integer, nullable: true),
    SyncColumn('due_date', SyncColumnType.text, nullable: true),
    SyncColumn('due_at', SyncColumnType.datetime, nullable: true),
    SyncColumn('due_tz', SyncColumnType.text, nullable: true),
    SyncColumn('duration_minutes', SyncColumnType.integer, nullable: true),
    SyncColumn('rrule', SyncColumnType.text, nullable: true),
    SyncColumn('recurrence_mode', SyncColumnType.text, nullable: true),
    SyncColumn('completed_at', SyncColumnType.datetime, nullable: true),
    SyncColumn('archived_at', SyncColumnType.datetime, nullable: true),
    // Мягкие ссылки без внешнего ключа (spec 2.3).
    SyncColumn('project_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('person_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('reminders', SyncColumnType.json, nullable: true),
    SyncColumn('sort_order', SyncColumnType.integer, nullable: true),
    SyncColumn('source', SyncColumnType.text),
  ],
  titleOf: _title,
);

/// `subtasks` — пункты чек-листа (spec 4.2).
const SyncTableSpec subtasksSpec = SyncTableSpec(
  name: 'subtasks',
  label: 'Пункт списка',
  columns: [
    SyncColumn('task_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('title', SyncColumnType.text),
    SyncColumn('done', SyncColumnType.boolean),
    SyncColumn('position', SyncColumnType.integer),
  ],
  parents: [SyncRelation('task_id', 'tasks')],
  titleOf: _title,
);

/// `task_tags` — связь задача–тег (spec 4.4).
const SyncTableSpec taskTagsSpec = SyncTableSpec(
  name: 'task_tags',
  label: 'Тег задачи',
  columns: [
    SyncColumn('task_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('tag_id', SyncColumnType.uuid, immutable: true),
  ],
  parents: [SyncRelation('task_id', 'tasks'), SyncRelation('tag_id', 'tags')],
  titleOf: _taskTagTitle,
);

/// `task_completions` — отметки экземпляров повторяющихся задач (spec 4.4).
const SyncTableSpec taskCompletionsSpec = SyncTableSpec(
  name: 'task_completions',
  label: 'Отметка выполнения',
  columns: [
    SyncColumn('task_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('instance_date', SyncColumnType.text, immutable: true),
    SyncColumn('state', SyncColumnType.text),
    SyncColumn('completed_at', SyncColumnType.datetime),
  ],
  parents: [SyncRelation('task_id', 'tasks')],
  titleOf: _completionTitle,
);

String _title(Map<String, Object?> row) => '${row['title']}';

String _name(Map<String, Object?> row) => '${row['name']}';

String _taskTagTitle(Map<String, Object?> row) => 'Тег снят с задачи';

String _completionTitle(Map<String, Object?> row) =>
    'Отметка за ${row['instance_date']}';
