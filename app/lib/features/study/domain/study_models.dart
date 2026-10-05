import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';

/// Модели «Учёбы» (spec `stage7_study.md`, раздел 1). Даты — строки
/// `YYYY-MM-DD`, время занятий — `HH:MM` (местное время вуза, без пояса):
/// строки сравниваются как в эталоне `reference.py`. День недели — 1…7,
/// понедельник = 1.
///
/// Чтение «мягкое»: строка с неизвестным значением перечисления (новая
/// версия сервера) читается как значение по умолчанию, а не ломает экран.

const Object _unset = Object();

/// Тип занятия (`class_slots.kind`).
enum LessonKind {
  lecture('lecture', 'Лекция'),
  practice('practice', 'Практика'),
  lab('lab', 'Лабораторная'),
  other('other', 'Другое');

  const LessonKind(this.wire, this.label);

  final String wire;
  final String label;

  static LessonKind parse(Object? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => other);
}

/// Действие изменения на дату (`class_overrides.action`).
enum OverrideAction {
  cancel('cancel', 'Отмена'),
  change('change', 'Изменение'),
  move('move', 'Перенос');

  const OverrideAction(this.wire, this.label);

  final String wire;
  final String label;

  static OverrideAction parse(Object? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => change);
}

/// Отметка посещаемости (`study_attendance.status`).
enum AttendanceStatus {
  present('present', 'Был'),
  absent('absent', 'Пропустил'),
  cancelled('cancelled', 'Отменена');

  const AttendanceStatus(this.wire, this.label);

  final String wire;
  final String label;

  static AttendanceStatus? parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return null;
  }
}

/// Вид долга (`study_debts.kind`).
enum DebtKind {
  lab('lab', 'Лабораторная'),
  practice('practice', 'Практическая'),
  rgr('rgr', 'РГР'),
  coursework('coursework', 'Курсовая'),
  credit('credit', 'Зачёт'),
  exam('exam', 'Экзамен'),
  other('other', 'Другое');

  const DebtKind(this.wire, this.label);

  final String wire;
  final String label;

  static DebtKind parse(Object? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => other);
}

/// Статус долга (`study_debts.status`).
enum DebtStatus {
  open('open', 'Не сдана'),
  submitted('submitted', 'Сдана'),
  credited('credited', 'Зачтена');

  const DebtStatus(this.wire, this.label);

  final String wire;
  final String label;

  static DebtStatus parse(Object? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => open);
}

/// Состояние загрузки вложения (`attachments.upload_status`).
enum UploadStatus {
  pending('pending'),
  uploaded('uploaded');

  const UploadStatus(this.wire);

  final String wire;

  static UploadStatus parse(Object? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => pending);
}

/// Семестр (`study_semesters`).
@immutable
class Semester {
  const Semester({
    required this.id,
    required this.name,
    required this.startDate,
    required this.endDate,
    required this.week1Start,
    this.cycleLength = 2,
    this.weekShifts = const [],
    this.archived = false,
  });

  factory Semester.fromRow(Json row) => Semester(
    id: row['id']! as String,
    name: (row['name'] as String?) ?? '',
    startDate: (row['start_date'] as String?) ?? '',
    endDate: (row['end_date'] as String?) ?? '',
    week1Start: (row['week1_start'] as String?) ?? '',
    cycleLength: (row['cycle_length'] as int?) ?? 1,
    weekShifts: _shifts(row['week_shifts']),
    archived: row['archived'] == true,
  );

  final String id;
  final String name;
  final String startDate;
  final String endDate;

  /// Любая дата недели №1 (опора чередования этого семестра).
  final String week1Start;

  /// 2 — чёт/нечёт, 1 — без чередования.
  final int cycleLength;
  final List<WeekShift> weekShifts;
  final bool archived;

  /// Цикл недель семестра (`null`, если опорная дата битая).
  WeekCycle? get cycle {
    final anchor = parseDate(week1Start);
    if (anchor == null || cycleLength < 1) return null;
    return WeekCycle(
      length: cycleLength,
      week1Start: anchor,
      shifts: weekShifts,
    );
  }

  /// Номер недели цикла (с 1) у даты [day] (`YYYY-MM-DD`).
  int weekNumber(String day) {
    final parsed = parseDate(day);
    final c = cycle;
    if (parsed == null || c == null) return 1;
    return c.weekNumber(parsed);
  }

  /// Подпись недели: «Нечётная» / «Чётная» / «Неделя 3».
  String weekLabel(int number) {
    if (cycleLength == 1) return 'Каждая неделя';
    if (cycleLength == 2) return number == 1 ? 'Нечётная' : 'Чётная';
    return 'Неделя $number';
  }

  Json toFields() => {
    'name': name,
    'start_date': startDate,
    'end_date': endDate,
    'week1_start': week1Start,
    'cycle_length': cycleLength,
    'week_shifts': weekShifts.isEmpty
        ? null
        : [for (final s in weekShifts) s.toJson()],
    'archived': archived,
  };

  Semester copyWith({
    String? name,
    String? startDate,
    String? endDate,
    String? week1Start,
    int? cycleLength,
    List<WeekShift>? weekShifts,
    bool? archived,
  }) => Semester(
    id: id,
    name: name ?? this.name,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    week1Start: week1Start ?? this.week1Start,
    cycleLength: cycleLength ?? this.cycleLength,
    weekShifts: weekShifts ?? this.weekShifts,
    archived: archived ?? this.archived,
  );
}

List<WeekShift> _shifts(Object? value) {
  if (value is! List) return const [];
  final out = <WeekShift>[];
  for (final s in value) {
    if (s is! Map) continue;
    final from = s['from'];
    final weeks = s['weeks'];
    final date = from is String ? parseDate(from) : null;
    if (date == null || weeks is! int) continue;
    out.add(WeekShift(from: date, weeks: weeks));
  }
  return out;
}

/// Предмет (`study_subjects`).
@immutable
class Subject {
  const Subject({
    required this.id,
    required this.semesterId,
    required this.name,
    this.teacher,
    this.building,
    this.room,
    this.absenceLimit,
    this.note,
    this.archived = false,
  });

  factory Subject.fromRow(Json row) => Subject(
    id: row['id']! as String,
    semesterId: (row['semester_id'] as String?) ?? '',
    name: (row['name'] as String?) ?? '',
    teacher: row['teacher'] as String?,
    building: row['building'] as String?,
    room: row['room'] as String?,
    absenceLimit: row['absence_limit'] as int?,
    note: row['note'] as String?,
    archived: row['archived'] == true,
  );

  final String id;
  final String semesterId;
  final String name;
  final String? teacher;
  final String? building;
  final String? room;
  final int? absenceLimit;
  final String? note;
  final bool archived;

  /// Колонки строки без `semester_id` (он неизменяем).
  Json toFields() => {
    'name': name,
    'teacher': teacher,
    'building': building,
    'room': room,
    'absence_limit': absenceLimit,
    'note': note,
    'archived': archived,
  };

  Subject copyWith({
    String? name,
    Object? teacher = _unset,
    Object? building = _unset,
    Object? room = _unset,
    Object? absenceLimit = _unset,
    Object? note = _unset,
    bool? archived,
  }) => Subject(
    id: id,
    semesterId: semesterId,
    name: name ?? this.name,
    teacher: identical(teacher, _unset) ? this.teacher : teacher as String?,
    building: identical(building, _unset) ? this.building : building as String?,
    room: identical(room, _unset) ? this.room : room as String?,
    absenceLimit: identical(absenceLimit, _unset)
        ? this.absenceLimit
        : absenceLimit as int?,
    note: identical(note, _unset) ? this.note : note as String?,
    archived: archived ?? this.archived,
  );
}

/// Звонок: одна пара сетки (`study_bells`). [onDate] `null` — обычная
/// сетка семестра, дата — звонок только на этот день.
@immutable
class Bell {
  const Bell({
    required this.semesterId,
    required this.number,
    required this.startTime,
    required this.endTime,
    this.id = '',
    this.onDate,
  });

  factory Bell.fromRow(Json row) => Bell(
    id: (row['id'] as String?) ?? '',
    semesterId: (row['semester_id'] as String?) ?? '',
    onDate: row['on_date'] as String?,
    number: (row['number'] as int?) ?? 0,
    startTime: (row['start_time'] as String?) ?? '',
    endTime: (row['end_time'] as String?) ?? '',
  );

  final String id;
  final String semesterId;
  final String? onDate;
  final int number;
  final String startTime;
  final String endTime;
}

/// Пара расписания (`class_slots`).
@immutable
class ClassSlot {
  const ClassSlot({
    required this.id,
    required this.semesterId,
    required this.weekday,
    required this.kind,
    this.subjectId,
    this.title,
    this.number,
    this.startTime,
    this.endTime,
    this.building,
    this.room,
    this.cycleWeek,
  });

  factory ClassSlot.fromRow(Json row) => ClassSlot(
    id: row['id']! as String,
    semesterId: (row['semester_id'] as String?) ?? '',
    subjectId: row['subject_id'] as String?,
    title: row['title'] as String?,
    weekday: (row['weekday'] as int?) ?? 1,
    number: row['number'] as int?,
    startTime: row['start_time'] as String?,
    endTime: row['end_time'] as String?,
    kind: LessonKind.parse(row['kind']),
    building: row['building'] as String?,
    room: row['room'] as String?,
    cycleWeek: row['cycle_week'] as int?,
  );

  final String id;
  final String semesterId;
  final String? subjectId;
  final String? title;
  final int weekday;
  final int? number;
  final String? startTime;
  final String? endTime;
  final LessonKind kind;
  final String? building;
  final String? room;

  /// Неделя цикла; `null` — каждая неделя.
  final int? cycleWeek;

  /// Колонки строки без `semester_id`.
  Json toFields() => {
    'subject_id': subjectId,
    'title': title,
    'weekday': weekday,
    'number': number,
    'start_time': startTime,
    'end_time': endTime,
    'kind': kind.wire,
    'building': building,
    'room': room,
    'cycle_week': cycleWeek,
  };

  ClassSlot copyWith({
    Object? subjectId = _unset,
    Object? title = _unset,
    int? weekday,
    Object? number = _unset,
    Object? startTime = _unset,
    Object? endTime = _unset,
    LessonKind? kind,
    Object? building = _unset,
    Object? room = _unset,
    Object? cycleWeek = _unset,
  }) => ClassSlot(
    id: id,
    semesterId: semesterId,
    subjectId: identical(subjectId, _unset)
        ? this.subjectId
        : subjectId as String?,
    title: identical(title, _unset) ? this.title : title as String?,
    weekday: weekday ?? this.weekday,
    number: identical(number, _unset) ? this.number : number as int?,
    startTime: identical(startTime, _unset)
        ? this.startTime
        : startTime as String?,
    endTime: identical(endTime, _unset) ? this.endTime : endTime as String?,
    kind: kind ?? this.kind,
    building: identical(building, _unset) ? this.building : building as String?,
    room: identical(room, _unset) ? this.room : room as String?,
    cycleWeek: identical(cycleWeek, _unset)
        ? this.cycleWeek
        : cycleWeek as int?,
  );
}

/// Занятие особого дня (элемент `study_day_rules.items`).
@immutable
class RuleItem {
  const RuleItem({
    required this.key,
    required this.title,
    required this.kind,
    this.number,
    this.startTime,
    this.endTime,
    this.building,
    this.room,
    this.cycleWeek,
  });

  factory RuleItem.fromJson(Map<Object?, Object?> json) => RuleItem(
    key: (json['key'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    kind: LessonKind.parse(json['kind']),
    number: json['number'] as int?,
    startTime: json['start_time'] as String?,
    endTime: json['end_time'] as String?,
    building: json['building'] as String?,
    room: json['room'] as String?,
    cycleWeek: json['cycle_week'] as int?,
  );

  final String key;
  final String title;
  final LessonKind kind;
  final int? number;
  final String? startTime;
  final String? endTime;
  final String? building;
  final String? room;
  final int? cycleWeek;

  /// JSON занятия: только заданные поля (сервер принимает лишь свои ключи).
  Json toJson() => {
    'key': key,
    'title': title,
    'kind': kind.wire,
    'number': ?number,
    'start_time': ?startTime,
    'end_time': ?endTime,
    'building': ?building,
    'room': ?room,
    'cycle_week': ?cycleWeek,
  };
}

/// Особый день (`study_day_rules`): правило на день недели ([weekday]) или
/// на дату ([onDate]).
@immutable
class DayRule {
  const DayRule({
    required this.id,
    required this.semesterId,
    required this.title,
    this.weekday,
    this.onDate,
    this.cycleWeek,
    this.hideRegular = false,
    this.items = const [],
  });

  factory DayRule.fromRow(Json row) => DayRule(
    id: (row['id'] as String?) ?? '',
    semesterId: (row['semester_id'] as String?) ?? '',
    weekday: row['weekday'] as int?,
    onDate: row['on_date'] as String?,
    cycleWeek: row['cycle_week'] as int?,
    title: (row['title'] as String?) ?? '',
    hideRegular: row['hide_regular'] == true,
    items: _items(row['items']),
  );

  final String id;
  final String semesterId;
  final int? weekday;
  final String? onDate;
  final int? cycleWeek;
  final String title;
  final bool hideRegular;
  final List<RuleItem> items;

  /// Изменяемые колонки строки (`weekday`, `on_date`, `cycle_week` и
  /// `semester_id` неизменяемы).
  Json toMutableFields() => {
    'title': title,
    'hide_regular': hideRegular,
    'items': [for (final i in items) i.toJson()],
  };

  /// Все прикладные колонки (создание строки).
  Json toFields(String semesterId) => {
    'semester_id': semesterId,
    'weekday': weekday,
    'on_date': onDate,
    'cycle_week': cycleWeek,
    ...toMutableFields(),
  };
}

List<RuleItem> _items(Object? value) {
  if (value is! List) return const [];
  return [
    for (final i in value)
      if (i is Map) RuleItem.fromJson(i),
  ];
}

/// Изменение на дату (`class_overrides`): отмена, изменение или перенос
/// пары в конкретный день. [date] — дата **по расписанию**.
@immutable
class ClassOverride {
  const ClassOverride({
    required this.slotId,
    required this.date,
    required this.action,
    this.id = '',
    this.newDate,
    this.startTime,
    this.endTime,
    this.building,
    this.room,
    this.subjectId,
    this.title,
    this.lessonKind,
  });

  factory ClassOverride.fromRow(Json row) => ClassOverride(
    id: (row['id'] as String?) ?? '',
    slotId: (row['slot_id'] as String?) ?? '',
    date: (row['date'] as String?) ?? '',
    action: OverrideAction.parse(row['action']),
    newDate: row['new_date'] as String?,
    startTime: row['start_time'] as String?,
    endTime: row['end_time'] as String?,
    building: row['building'] as String?,
    room: row['room'] as String?,
    subjectId: row['subject_id'] as String?,
    title: row['title'] as String?,
    lessonKind: row['lesson_kind'] == null
        ? null
        : LessonKind.parse(row['lesson_kind']),
  );

  final String id;
  final String slotId;
  final String date;
  final OverrideAction action;
  final String? newDate;
  final String? startTime;
  final String? endTime;
  final String? building;
  final String? room;
  final String? subjectId;
  final String? title;
  final LessonKind? lessonKind;

  /// Изменяемые колонки (`slot_id` и `date` неизменяемы).
  Json toMutableFields() => {
    'action': action.wire,
    'new_date': newDate,
    'start_time': startTime,
    'end_time': endTime,
    'building': building,
    'room': room,
    'subject_id': subjectId,
    'title': title,
    'lesson_kind': lessonKind?.wire,
  };
}

/// Отметка посещаемости (`study_attendance`).
@immutable
class AttendanceMark {
  const AttendanceMark({
    required this.slotId,
    required this.date,
    required this.status,
    this.id = '',
    this.note,
  });

  factory AttendanceMark.fromRow(Json row) => AttendanceMark(
    id: (row['id'] as String?) ?? '',
    slotId: (row['slot_id'] as String?) ?? '',
    date: (row['date'] as String?) ?? '',
    status: AttendanceStatus.parse(row['status']) ?? AttendanceStatus.present,
    note: row['note'] as String?,
  );

  final String id;
  final String slotId;
  final String date;
  final AttendanceStatus status;
  final String? note;
}

/// Долг (`study_debts`): лабораторная, практическая, РГР, зачёт…
@immutable
class StudyDebt {
  const StudyDebt({
    required this.id,
    required this.subjectId,
    required this.title,
    this.kind = DebtKind.lab,
    this.status = DebtStatus.open,
    this.dueDate,
    this.doneDate,
    this.note,
    this.taskId,
  });

  factory StudyDebt.fromRow(Json row) => StudyDebt(
    id: row['id']! as String,
    subjectId: (row['subject_id'] as String?) ?? '',
    kind: DebtKind.parse(row['kind']),
    title: (row['title'] as String?) ?? '',
    status: DebtStatus.parse(row['status']),
    dueDate: row['due_date'] as String?,
    doneDate: row['done_date'] as String?,
    note: row['note'] as String?,
    taskId: row['task_id'] as String?,
  );

  final String id;
  final String subjectId;
  final DebtKind kind;
  final String title;
  final DebtStatus status;
  final String? dueDate;
  final String? doneDate;
  final String? note;

  /// Мягкая ссылка на задачу Этапа 2 («создать задачу»).
  final String? taskId;

  bool get isOpen => status == DebtStatus.open;

  /// Просрочен: не сдан и срок раньше [today] (`YYYY-MM-DD`).
  bool isOverdue(String today) =>
      isOpen && dueDate != null && dueDate!.compareTo(today) < 0;

  /// Колонки без `subject_id` (неизменяем).
  Json toFields() => {
    'kind': kind.wire,
    'title': title,
    'status': status.wire,
    'due_date': dueDate,
    'done_date': doneDate,
    'note': note,
    'task_id': taskId,
  };

  StudyDebt copyWith({
    DebtKind? kind,
    String? title,
    DebtStatus? status,
    Object? dueDate = _unset,
    Object? doneDate = _unset,
    Object? note = _unset,
    Object? taskId = _unset,
  }) => StudyDebt(
    id: id,
    subjectId: subjectId,
    kind: kind ?? this.kind,
    title: title ?? this.title,
    status: status ?? this.status,
    dueDate: identical(dueDate, _unset) ? this.dueDate : dueDate as String?,
    doneDate: identical(doneDate, _unset) ? this.doneDate : doneDate as String?,
    note: identical(note, _unset) ? this.note : note as String?,
    taskId: identical(taskId, _unset) ? this.taskId : taskId as String?,
  );
}

/// Метаданные вложения (`attachments`); содержимое — вне синхронизации.
@immutable
class Attachment {
  const Attachment({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256,
    this.subjectId,
    this.debtId,
    this.uploadStatus = UploadStatus.pending,
  });

  factory Attachment.fromRow(Json row) => Attachment(
    id: row['id']! as String,
    subjectId: row['subject_id'] as String?,
    debtId: row['debt_id'] as String?,
    fileName: (row['file_name'] as String?) ?? '',
    mimeType: (row['mime_type'] as String?) ?? '',
    sizeBytes: (row['size_bytes'] as int?) ?? 0,
    sha256: (row['sha256'] as String?) ?? '',
    uploadStatus: UploadStatus.parse(row['upload_status']),
  );

  final String id;
  final String? subjectId;
  final String? debtId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String sha256;
  final UploadStatus uploadStatus;

  /// Картинку можно показать в приложении.
  bool get isImage => mimeType.startsWith('image/');

  /// Все прикладные колонки (создание строки).
  Json toFields() => {
    'subject_id': subjectId,
    'debt_id': debtId,
    'file_name': fileName,
    'mime_type': mimeType,
    'size_bytes': sizeBytes,
    'sha256': sha256,
    'upload_status': uploadStatus.wire,
  };
}
