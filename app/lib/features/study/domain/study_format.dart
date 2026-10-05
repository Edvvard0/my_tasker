import 'package:my_tasker/core/calendar_time/civil_date.dart' as civil_date;
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/format/ru_format.dart' show pluralRu;
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';

/// Подписи «Учёбы» для интерфейса.

/// «Понедельник» для дня недели 1…7.
String weekdayName(int weekday) => weekdayFullNames[(weekday - 1) % 7];

/// «Пн» для дня недели 1…7.
String weekdayShort(int weekday) => weekdayShortNames[(weekday - 1) % 7];

/// «Чт, 17 сент.» для даты `YYYY-MM-DD` (или сама строка, если битая).
String dateLabel(String iso) {
  final d = civil_date.parseDate(iso);
  return d == null ? iso : dayTitleShort(d);
}

/// «17 сентября» для даты `YYYY-MM-DD`.
String dateLong(String iso) {
  final d = civil_date.parseDate(iso);
  return d == null ? iso : '${d.day} ${monthGenitiveNames[d.month - 1]}';
}

/// «08:30–10:00» или «—», если у занятия нет времени.
String lessonTime(String? start, String? end) =>
    start == null ? 'без времени' : (end == null ? start : '$start–$end');

/// «2 пропуска», «1 пропуск».
String absencesText(int n) =>
    '$n ${pluralRu(n, 'пропуск', 'пропуска', 'пропусков')}';

/// «Пропуски 2 из 4» или «Пропуски 2» без лимита.
String absencesLimitText(SubjectAttendance a) => a.limit == null
    ? 'Пропуски ${a.absent}'
    : 'Пропуски ${a.absent} из ${a.limit}';

/// Подпись состояния лимита.
String limitStateText(SubjectAttendance a) => switch (a.state) {
  AttendanceState.noLimit => 'Лимит не задан',
  AttendanceState.ok => 'Осталось ${a.left}',
  AttendanceState.near => 'Осталось ${a.left}: близко к лимиту',
  AttendanceState.reached => 'Лимит исчерпан',
  AttendanceState.over => 'Лимит превышен на ${-(a.left ?? 0)}',
};

/// «2 долга», «1 долг», «нет долгов».
String debtsCountText(int n) =>
    n == 0 ? 'нет долгов' : '$n ${pluralRu(n, 'долг', 'долга', 'долгов')}';

/// Срок долга относительно [today] (`YYYY-MM-DD`): «Срок 12 окт.»,
/// «Просрочено на 3 дня». Пусто, если срока нет.
String dueText(StudyDebt debt, String today) {
  final due = debt.dueDate;
  if (due == null) return '';
  if (debt.isOverdue(today)) {
    final days = civil_date.daysBetween(
      civil_date.parseDate(due)!,
      civil_date.parseDate(today)!,
    );
    return 'Просрочено на $days ${pluralRu(days, 'день', 'дня', 'дней')}';
  }
  return 'Срок ${dateLabel(due)}';
}

/// Размер файла: «512 Б», «1,2 КБ», «3,4 МБ».
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  String one(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
  if (bytes < 1024 * 1024) return '${one(bytes / 1024)} КБ';
  return '${one(bytes / (1024 * 1024))} МБ';
}

/// Время `ЧЧ:ММ` из ввода: «8:30», «830», «8.30» → «08:30»; `null`, если
/// не время.
String? normalizeTime(String text) {
  final t = text.trim().replaceAll('.', ':').replaceAll(' ', '');
  final match = RegExp(r'^(\d{1,2}):?(\d{2})$').firstMatch(t);
  if (match == null) return null;
  final result = '${match[1]!.padLeft(2, '0')}:${match[2]}';
  return isStudyTime(result) ? result : null;
}

/// Подпись недели цикла в семестре.
String cycleWeekLabel(Semester? semester, int? week) {
  if (week == null) return 'Каждая неделя';
  return semester?.weekLabel(week) ?? 'Неделя $week';
}
