import 'package:my_tasker/core/sync/sync_table.dart';

/// Синхронизируемые таблицы Этапа 7 (spec `stage7_study.md`, раздел 1;
/// сервер: `backend/src/tasker/study/tables.py`, `STUDY_TABLES`). Порядок
/// регистрации — родители вперёд. Каскады делает сервер; клиент шлёт одну
/// операцию `delete` родителя, потомков скрывает видимость строк.
///
/// Колонки `id` у звонков, особых дней, изменений на дату и отметок —
/// детерминированные (`study_ids.dart`).

/// `study_semesters` — семестры (1.1).
const SyncTableSpec studySemestersSpec = SyncTableSpec(
  name: 'study_semesters',
  label: 'Семестр',
  columns: [
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('start_date', SyncColumnType.text),
    SyncColumn('end_date', SyncColumnType.text),
    SyncColumn('week1_start', SyncColumnType.text),
    SyncColumn('cycle_length', SyncColumnType.integer),
    SyncColumn('week_shifts', SyncColumnType.json, nullable: true),
    SyncColumn('archived', SyncColumnType.boolean),
  ],
  titleOf: _name,
);

/// `study_subjects` — предметы (1.2).
const SyncTableSpec studySubjectsSpec = SyncTableSpec(
  name: 'study_subjects',
  label: 'Предмет',
  columns: [
    SyncColumn('semester_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('teacher', SyncColumnType.text, nullable: true),
    SyncColumn('building', SyncColumnType.text, nullable: true),
    SyncColumn('room', SyncColumnType.text, nullable: true),
    SyncColumn('absence_limit', SyncColumnType.integer, nullable: true),
    SyncColumn('note', SyncColumnType.text, nullable: true),
    SyncColumn('archived', SyncColumnType.boolean),
  ],
  parents: [SyncRelation('semester_id', 'study_semesters')],
  titleOf: _name,
);

/// `study_bells` — сетка звонков (1.3). `on_date`, `number`, `semester_id`
/// неизменяемы.
const SyncTableSpec studyBellsSpec = SyncTableSpec(
  name: 'study_bells',
  label: 'Звонок',
  columns: [
    SyncColumn('semester_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('on_date', SyncColumnType.text, nullable: true, immutable: true),
    SyncColumn('number', SyncColumnType.integer, immutable: true),
    SyncColumn('start_time', SyncColumnType.text),
    SyncColumn('end_time', SyncColumnType.text),
  ],
  parents: [SyncRelation('semester_id', 'study_semesters')],
  titleOf: _bellTitle,
  inTrash: false,
);

/// `class_slots` — пары расписания (1.4).
const SyncTableSpec classSlotsSpec = SyncTableSpec(
  name: 'class_slots',
  label: 'Пара',
  columns: [
    SyncColumn('semester_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('subject_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('title', SyncColumnType.text, nullable: true),
    SyncColumn('weekday', SyncColumnType.integer),
    SyncColumn('number', SyncColumnType.integer, nullable: true),
    SyncColumn('start_time', SyncColumnType.text, nullable: true),
    SyncColumn('end_time', SyncColumnType.text, nullable: true),
    SyncColumn('kind', SyncColumnType.text),
    SyncColumn('building', SyncColumnType.text, nullable: true),
    SyncColumn('room', SyncColumnType.text, nullable: true),
    SyncColumn('cycle_week', SyncColumnType.integer, nullable: true),
  ],
  parents: [
    SyncRelation('semester_id', 'study_semesters'),
    SyncRelation('subject_id', 'study_subjects'),
  ],
  titleOf: _slotTitle,
);

/// `study_day_rules` — особые дни (1.5). Область правила неизменяема.
const SyncTableSpec studyDayRulesSpec = SyncTableSpec(
  name: 'study_day_rules',
  label: 'Особый день',
  columns: [
    SyncColumn('semester_id', SyncColumnType.uuid, immutable: true),
    SyncColumn(
      'weekday',
      SyncColumnType.integer,
      nullable: true,
      immutable: true,
    ),
    SyncColumn('on_date', SyncColumnType.text, nullable: true, immutable: true),
    SyncColumn(
      'cycle_week',
      SyncColumnType.integer,
      nullable: true,
      immutable: true,
    ),
    SyncColumn('title', SyncColumnType.text),
    SyncColumn('hide_regular', SyncColumnType.boolean),
    SyncColumn('items', SyncColumnType.json),
  ],
  parents: [SyncRelation('semester_id', 'study_semesters')],
  titleOf: _title,
);

/// `class_overrides` — изменения на дату (1.6). `subject_id` — мягкая
/// ссылка (замена предмета).
const SyncTableSpec classOverridesSpec = SyncTableSpec(
  name: 'class_overrides',
  label: 'Изменение пары',
  columns: [
    SyncColumn('slot_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('date', SyncColumnType.text, immutable: true),
    SyncColumn('action', SyncColumnType.text),
    SyncColumn('new_date', SyncColumnType.text, nullable: true),
    SyncColumn('start_time', SyncColumnType.text, nullable: true),
    SyncColumn('end_time', SyncColumnType.text, nullable: true),
    SyncColumn('building', SyncColumnType.text, nullable: true),
    SyncColumn('room', SyncColumnType.text, nullable: true),
    SyncColumn('subject_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('title', SyncColumnType.text, nullable: true),
    SyncColumn('lesson_kind', SyncColumnType.text, nullable: true),
  ],
  parents: [SyncRelation('slot_id', 'class_slots')],
  titleOf: _overrideTitle,
  inTrash: false,
);

/// `study_attendance` — посещаемость (1.7).
const SyncTableSpec studyAttendanceSpec = SyncTableSpec(
  name: 'study_attendance',
  label: 'Отметка посещаемости',
  columns: [
    SyncColumn('slot_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('date', SyncColumnType.text, immutable: true),
    SyncColumn('status', SyncColumnType.text),
    SyncColumn('note', SyncColumnType.text, nullable: true),
  ],
  parents: [SyncRelation('slot_id', 'class_slots')],
  titleOf: _attendanceTitle,
  inTrash: false,
);

/// `study_debts` — долги (1.8). `task_id` — мягкая ссылка на задачу.
const SyncTableSpec studyDebtsSpec = SyncTableSpec(
  name: 'study_debts',
  label: 'Долг',
  columns: [
    SyncColumn('subject_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('kind', SyncColumnType.text),
    SyncColumn('title', SyncColumnType.text),
    SyncColumn('status', SyncColumnType.text),
    SyncColumn('due_date', SyncColumnType.text, nullable: true),
    SyncColumn('done_date', SyncColumnType.text, nullable: true),
    SyncColumn('note', SyncColumnType.text, nullable: true),
    SyncColumn('task_id', SyncColumnType.uuid, nullable: true),
  ],
  parents: [SyncRelation('subject_id', 'study_subjects')],
  titleOf: _title,
);

/// `attachments` — метаданные вложений (1.9). Владелец, тип, размер и хеш
/// неизменяемы; `upload_status` ставит клиент после успешной загрузки.
const SyncTableSpec attachmentsSpec = SyncTableSpec(
  name: 'attachments',
  label: 'Вложение',
  columns: [
    SyncColumn(
      'subject_id',
      SyncColumnType.uuid,
      nullable: true,
      immutable: true,
    ),
    SyncColumn('debt_id', SyncColumnType.uuid, nullable: true, immutable: true),
    SyncColumn('file_name', SyncColumnType.text),
    SyncColumn('mime_type', SyncColumnType.text, immutable: true),
    SyncColumn('size_bytes', SyncColumnType.integer, immutable: true),
    SyncColumn('sha256', SyncColumnType.text, immutable: true),
    SyncColumn('upload_status', SyncColumnType.text),
  ],
  parents: [
    SyncRelation('subject_id', 'study_subjects'),
    SyncRelation('debt_id', 'study_debts'),
  ],
  titleOf: _fileName,
);

/// Все таблицы Этапа 7 в порядке регистрации.
const List<SyncTableSpec> studySyncSpecs = [
  studySemestersSpec,
  studySubjectsSpec,
  studyBellsSpec,
  classSlotsSpec,
  studyDayRulesSpec,
  classOverridesSpec,
  studyAttendanceSpec,
  studyDebtsSpec,
  attachmentsSpec,
];

String _name(Map<String, Object?> row) => '${row['name']}';

String _title(Map<String, Object?> row) => '${row['title']}';

String _fileName(Map<String, Object?> row) => '${row['file_name']}';

String _bellTitle(Map<String, Object?> row) {
  final day = row['on_date'];
  return day is String
      ? 'Звонок ${row['number']} на $day'
      : 'Звонок ${row['number']}';
}

String _slotTitle(Map<String, Object?> row) {
  final title = row['title'];
  return title is String && title.isNotEmpty ? title : 'Пара';
}

String _overrideTitle(Map<String, Object?> row) =>
    'Изменение пары на ${row['date']}';

String _attendanceTitle(Map<String, Object?> row) =>
    'Посещаемость ${row['date']}';
