import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/calendar_tables.dart';

// DSL-описания таблиц исполняются только генератором кода (drift_dev).
// coverage:ignore-start

/// Синхронизируемые таблицы Этапа 7 (spec `stage7_study.md`, раздел 1).
/// Даты — текст `YYYY-MM-DD`, время занятий — `HH:MM` (без пояса).
/// Внешних ключей SQLite нет (как у всех синхронизируемых таблиц):
/// видимость строк считает `SyncStore`.

/// Семестры (1.1).
@DataClassName('StudySemesterRow')
class StudySemesters extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get startDate => text()();
  TextColumn get endDate => text()();
  TextColumn get week1Start => text()();
  IntColumn get cycleLength => integer()();
  TextColumn get weekShifts => text().nullable()();
  BoolColumn get archived => boolean()();

  @override
  String get tableName => 'study_semesters';
}

/// Предметы (1.2).
@DataClassName('StudySubjectRow')
@TableIndex(name: 'study_subjects_semester_idx', columns: {#semesterId})
class StudySubjects extends Table with SyncColumns {
  TextColumn get semesterId => text()();
  TextColumn get name => text()();
  TextColumn get teacher => text().nullable()();
  TextColumn get building => text().nullable()();
  TextColumn get room => text().nullable()();
  IntColumn get absenceLimit => integer().nullable()();
  TextColumn get note => text().nullable()();
  BoolColumn get archived => boolean()();

  @override
  String get tableName => 'study_subjects';
}

/// Сетка звонков (1.3): одна строка = одна пара.
@DataClassName('StudyBellRow')
@TableIndex(name: 'study_bells_semester_idx', columns: {#semesterId})
class StudyBells extends Table with SyncColumns {
  TextColumn get semesterId => text()();
  TextColumn get onDate => text().nullable()();
  IntColumn get number => integer()();
  TextColumn get startTime => text()();
  TextColumn get endTime => text()();

  @override
  String get tableName => 'study_bells';
}

/// Пары расписания (1.4).
@DataClassName('ClassSlotRow')
@TableIndex(name: 'class_slots_semester_idx', columns: {#semesterId})
@TableIndex(name: 'class_slots_subject_idx', columns: {#subjectId})
class ClassSlots extends Table with SyncColumns {
  TextColumn get semesterId => text()();
  TextColumn get subjectId => text().nullable()();
  TextColumn get title => text().nullable()();
  IntColumn get weekday => integer()();
  IntColumn get number => integer().nullable()();
  TextColumn get startTime => text().nullable()();
  TextColumn get endTime => text().nullable()();
  TextColumn get kind => text()();
  TextColumn get building => text().nullable()();
  TextColumn get room => text().nullable()();
  IntColumn get cycleWeek => integer().nullable()();

  @override
  String get tableName => 'class_slots';
}

/// Особые дни (1.5).
@DataClassName('StudyDayRuleRow')
@TableIndex(name: 'study_day_rules_semester_idx', columns: {#semesterId})
class StudyDayRules extends Table with SyncColumns {
  TextColumn get semesterId => text()();
  IntColumn get weekday => integer().nullable()();
  TextColumn get onDate => text().nullable()();
  IntColumn get cycleWeek => integer().nullable()();
  TextColumn get title => text()();
  BoolColumn get hideRegular => boolean()();
  TextColumn get items => text()();

  @override
  String get tableName => 'study_day_rules';
}

/// Изменения на дату (1.6).
@DataClassName('ClassOverrideRow')
@TableIndex(name: 'class_overrides_slot_idx', columns: {#slotId})
class ClassOverrides extends Table with SyncColumns {
  TextColumn get slotId => text()();
  TextColumn get date => text()();
  TextColumn get action => text()();
  TextColumn get newDate => text().nullable()();
  TextColumn get startTime => text().nullable()();
  TextColumn get endTime => text().nullable()();
  TextColumn get building => text().nullable()();
  TextColumn get room => text().nullable()();
  TextColumn get subjectId => text().nullable()();
  TextColumn get title => text().nullable()();
  TextColumn get lessonKind => text().nullable()();

  @override
  String get tableName => 'class_overrides';
}

/// Посещаемость (1.7).
@DataClassName('StudyAttendanceRow')
@TableIndex(name: 'study_attendance_slot_idx', columns: {#slotId})
class StudyAttendance extends Table with SyncColumns {
  TextColumn get slotId => text()();
  TextColumn get date => text()();
  TextColumn get status => text()();
  TextColumn get note => text().nullable()();

  @override
  String get tableName => 'study_attendance';
}

/// Долги: лабораторные, практические, зачёты (1.8).
@DataClassName('StudyDebtRow')
@TableIndex(name: 'study_debts_subject_idx', columns: {#subjectId})
class StudyDebts extends Table with SyncColumns {
  TextColumn get subjectId => text()();
  TextColumn get kind => text()();
  TextColumn get title => text()();
  TextColumn get status => text()();
  TextColumn get dueDate => text().nullable()();
  TextColumn get doneDate => text().nullable()();
  TextColumn get note => text().nullable()();
  TextColumn get taskId => text().nullable()();

  @override
  String get tableName => 'study_debts';
}

/// Метаданные вложений (1.9); содержимое файлов — вне синхронизации.
@DataClassName('AttachmentRow')
@TableIndex(name: 'attachments_subject_idx', columns: {#subjectId})
@TableIndex(name: 'attachments_debt_idx', columns: {#debtId})
class Attachments extends Table with SyncColumns {
  TextColumn get subjectId => text().nullable()();
  TextColumn get debtId => text().nullable()();
  TextColumn get fileName => text()();
  TextColumn get mimeType => text()();
  IntColumn get sizeBytes => integer()();
  TextColumn get sha256 => text()();
  TextColumn get uploadStatus => text()();

  @override
  String get tableName => 'attachments';
}

// coverage:ignore-end
