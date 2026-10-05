/// Проверки «Учёбы» на клиенте (spec `stage7_study.md`, раздел 1). Сервер
/// отвергает то же самое построчно (`backend/src/tasker/study/schema.py`);
/// здесь — те же правила с русскими сообщениями для форм. Каждая функция
/// возвращает первую проблему или `null`.
library;

import 'dart:convert';

import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';

/// Семестр длится не больше стольких суток.
const int maxSemesterDays = 400;
const int maxShifts = 30;
const int maxRuleItems = 12;
const int maxRuleItemsBytes = 8192;
const int maxWeekShiftsBytes = 4096;

/// Лимит файла: 25 МиБ (`attachments.size_bytes`).
const int maxFileBytes = 25 * 1024 * 1024;

final RegExp _buildingPattern = RegExp(r'^[^ \t\r\n]{1,10}$');
final RegExp _itemKeyPattern = RegExp(r'^[a-z0-9_]{1,20}$');
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// Разрешённые типы файлов: MIME -> расширения (строчные, с точкой).
const Map<String, List<String>> allowedFiles = {
  'image/jpeg': ['.jpg', '.jpeg'],
  'image/png': ['.png'],
  'image/heic': ['.heic', '.heif'],
  'image/heif': ['.heic', '.heif'],
  'image/webp': ['.webp'],
  'application/pdf': ['.pdf'],
  'application/msword': ['.doc'],
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': [
    '.docx',
  ],
  'application/vnd.ms-excel': ['.xls'],
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': [
    '.xlsx',
  ],
  'application/vnd.ms-powerpoint': ['.ppt'],
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': [
    '.pptx',
  ],
  'text/plain': ['.txt'],
  'application/zip': ['.zip'],
};

bool _realDate(String? date) => date != null && parseDate(date) != null;

/// Размер JSON так, как его считает сервер: компактный JSON Python
/// (`ensure_ascii`): символ вне ASCII — 6 байт (`\uXXXX`), вне BMP — 12.
int serverJsonBytes(Object? value) {
  var bytes = 0;
  for (final unit in jsonEncode(value).codeUnits) {
    bytes += unit < 0x80 ? 1 : 6;
  }
  return bytes;
}

String? _timesProblem(String? start, String? end) {
  if ((start == null) != (end == null)) {
    return 'Укажите и начало, и конец времени';
  }
  if (start != null && end != null) {
    if (!isStudyTime(start) || !isStudyTime(end)) {
      return 'Время — в формате ЧЧ:ММ';
    }
    if (end.compareTo(start) <= 0) return 'Конец должен быть позже начала';
  }
  return null;
}

/// Корпус: до 10 символов без пробелов; кабинет — до 20.
String? roomProblem(String? building, String? room) {
  if (building != null && !_buildingPattern.hasMatch(building)) {
    return 'Корпус — до 10 символов без пробелов';
  }
  if (room != null && (room.isEmpty || room.length > 20)) {
    return 'Кабинет — от 1 до 20 символов';
  }
  return null;
}

/// Семестр: название, даты, длина ≤ 400 суток, сдвиги чётности.
String? semesterProblem(Semester s) {
  final name = nameProblem(s.name, 100);
  if (name != null) return name;
  final first = parseDate(s.startDate);
  final last = parseDate(s.endDate);
  if (first == null || last == null || !_realDate(s.week1Start)) {
    return 'Даты семестра: укажите настоящие даты';
  }
  if (last.isBefore(first)) return 'Конец семестра раньше начала';
  if (last.difference(first).inDays > maxSemesterDays) {
    return 'Семестр — не длиннее $maxSemesterDays суток';
  }
  if (s.cycleLength < 1 || s.cycleLength > 8) {
    return 'Цикл недель — от 1 до 8';
  }
  if (s.weekShifts.length > maxShifts) {
    return 'Сдвигов чётности — не больше $maxShifts';
  }
  for (final shift in s.weekShifts) {
    if (shift.weeks < -8 || shift.weeks > 8) {
      return 'Сдвиг чётности — от −8 до 8 недель';
    }
  }
  if (s.weekShifts.isNotEmpty &&
      serverJsonBytes([for (final w in s.weekShifts) w.toJson()]) >
          maxWeekShiftsBytes) {
    return 'Слишком много сдвигов чётности';
  }
  return null;
}

/// Предмет: название, преподаватель, аудитория, лимит, заметка.
String? subjectProblem(Subject s) {
  final name = nameProblem(s.name, 200);
  if (name != null) return name;
  if ((s.teacher?.length ?? 0) > 200) {
    return 'ФИО преподавателя — не длиннее 200 символов';
  }
  final room = roomProblem(s.building, s.room);
  if (room != null) return room;
  final limit = s.absenceLimit;
  if (limit != null && (limit < 1 || limit > 999)) {
    return 'Лимит пропусков — от 1 до 999';
  }
  if ((s.note?.length ?? 0) > 5000) return 'Заметка слишком длинная';
  return null;
}

/// Звонок: номер 1…12, время и конец позже начала.
String? bellProblem(int number, String start, String end, {String? onDate}) {
  if (number < 1 || number > 12) return 'Номер пары — от 1 до 12';
  if (onDate != null && !_realDate(onDate)) {
    return 'Дата звонка: нет такой даты';
  }
  if (!isStudyTime(start) || !isStudyTime(end)) {
    return 'Время — в формате ЧЧ:ММ';
  }
  return _timesProblem(start, end);
}

/// Пара расписания.
String? slotProblem(ClassSlot s) {
  final hasTitle = s.title != null && s.title!.trim().isNotEmpty;
  if (s.subjectId == null && !hasTitle) {
    return 'Выберите предмет или впишите название';
  }
  if (s.title != null && !hasTitle) return 'Название не может быть пустым';
  if ((s.title?.length ?? 0) > 200) return 'Название — не длиннее 200 символов';
  if (s.weekday < 1 || s.weekday > 7) return 'День недели — от 1 до 7';
  if (s.number == null && s.startTime == null) {
    return 'Укажите номер пары или своё время';
  }
  final n = s.number;
  if (n != null && (n < 1 || n > 12)) return 'Номер пары — от 1 до 12';
  final cw = s.cycleWeek;
  if (cw != null && (cw < 1 || cw > 8)) return 'Неделя цикла — от 1 до 8';
  return _timesProblem(s.startTime, s.endTime) ??
      roomProblem(s.building, s.room);
}

String? _itemProblem(RuleItem i) {
  if (!_itemKeyPattern.hasMatch(i.key)) {
    return 'Ключ занятия — 1…20 символов a-z 0-9 _';
  }
  final title = nameProblem(i.title, 200);
  if (title != null) return title;
  final n = i.number;
  if (n != null && (n < 1 || n > 12)) return 'Номер пары — от 1 до 12';
  final cw = i.cycleWeek;
  if (cw != null && (cw < 1 || cw > 8)) return 'Неделя цикла — от 1 до 8';
  if (n == null && i.startTime == null) {
    return 'У занятия нужен номер пары или своё время';
  }
  return _timesProblem(i.startTime, i.endTime) ??
      roomProblem(i.building, i.room);
}

/// Особый день: правило на день недели или на дату, занятия.
String? dayRuleProblem(DayRule r) {
  final title = nameProblem(r.title, 200);
  if (title != null) return title;
  if ((r.weekday == null) == (r.onDate == null)) {
    return 'Правило — на день недели или на дату';
  }
  final wd = r.weekday;
  if (wd != null && (wd < 1 || wd > 7)) return 'День недели — от 1 до 7';
  if (r.onDate != null && !_realDate(r.onDate)) {
    return 'Дата правила: нет такой даты';
  }
  if (r.cycleWeek != null && r.weekday == null) {
    return 'Неделя цикла — только у правила на день недели';
  }
  final cw = r.cycleWeek;
  if (cw != null && (cw < 1 || cw > 8)) return 'Неделя цикла — от 1 до 8';
  if (r.items.length > maxRuleItems) {
    return 'В особом дне — не больше $maxRuleItems занятий';
  }
  final keys = <String>{};
  for (final item in r.items) {
    final problem = _itemProblem(item);
    if (problem != null) return problem;
    if (!keys.add(item.key)) return 'Ключи занятий не должны повторяться';
  }
  if (serverJsonBytes([for (final i in r.items) i.toJson()]) >
      maxRuleItemsBytes) {
    return 'Слишком много данных в занятиях особого дня';
  }
  return null;
}

/// Изменение на дату.
String? overrideProblem(ClassOverride o) {
  if (!_realDate(o.date)) return 'Дата: нет такой даты';
  if (o.action == OverrideAction.move) {
    if (!_realDate(o.newDate)) return 'Укажите дату, на которую переносим';
    if (o.newDate == o.date) return 'Перенос — на другую дату';
  } else if (o.newDate != null) {
    return 'Дату переноса задаёт только перенос';
  }
  if (o.title != null && o.title!.trim().isEmpty) {
    return 'Название не может быть пустым';
  }
  if ((o.title?.length ?? 0) > 200) return 'Название — не длиннее 200 символов';
  return _timesProblem(o.startTime, o.endTime) ??
      roomProblem(o.building, o.room);
}

/// Отметка посещаемости.
String? attendanceProblem(String date, String? note) {
  if (!_realDate(date)) return 'Дата: нет такой даты';
  if ((note?.length ?? 0) > 500) return 'Заметка — не длиннее 500 символов';
  return null;
}

/// Долг.
String? debtProblem(StudyDebt d) {
  final title = nameProblem(d.title, 200);
  if (title != null) return title;
  for (final (name, value) in [
    ('Срок', d.dueDate),
    ('Дата сдачи', d.doneDate),
  ]) {
    if (value != null && !_realDate(value)) return '$name: нет такой даты';
  }
  if ((d.note?.length ?? 0) > 5000) return 'Заметка слишком длинная';
  return null;
}

/// Имя файла: без `/`, `\` и управляющих символов.
String? fileNameProblem(String name) {
  final t = name.trim();
  if (t.isEmpty || t == '.' || t == '..') return 'Имя файла пустое';
  if (name.length > 255) return 'Имя файла — не длиннее 255 символов';
  for (final unit in name.codeUnits) {
    if (unit < 32 || unit == 127 || unit == 0x2F || unit == 0x5C) {
      return r'В имени файла нельзя использовать / и \';
    }
  }
  return null;
}

/// Расширение файла строчными с точкой (`''`, если его нет).
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

/// MIME-тип по расширению для разрешённых файлов; `null` — тип не
/// разрешён.
String? mimeTypeOf(String fileName) {
  final ext = fileExtension(fileName);
  if (ext == '.heic' || ext == '.heif') return 'image/heic';
  for (final e in allowedFiles.entries) {
    if (e.key == 'image/heif') continue;
    if (e.value.contains(ext)) return e.key;
  }
  return null;
}

/// Вложение: владелец ровно один, имя, тип, размер, хеш.
String? attachmentProblem(Attachment a) {
  if ((a.subjectId == null) == (a.debtId == null)) {
    return 'Вложение принадлежит предмету или долгу';
  }
  final name = fileNameProblem(a.fileName);
  if (name != null) return name;
  final extensions = allowedFiles[a.mimeType];
  if (extensions == null) {
    return 'Такой тип файла не поддерживается: допустимы фото, PDF, '
        'документы Office, TXT и ZIP';
  }
  if (!extensions.contains(fileExtension(a.fileName))) {
    return 'Расширение файла не подходит к его типу';
  }
  if (a.sizeBytes < 1) return 'Файл пустой';
  if (a.sizeBytes > maxFileBytes) return 'Файл больше 25 МБ';
  if (!_sha256Pattern.hasMatch(a.sha256)) return 'Не удалось посчитать SHA-256';
  return null;
}
