import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';

/// Клиентская проверка значений до записи в outbox: то же, что проверяет
/// сервер (spec 9), но с русскими сообщениями для формы. Возвращает первую
/// найденную проблему или `null`.

const int maxReminders = 5;
const int maxReminderMinutes = 40320;
const int maxSpanDays = 366;

final RegExp colorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

/// Ошибка проверки значений (сообщение — для пользователя).
class ValidationError implements Exception {
  const ValidationError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Бросает [ValidationError], если [problem] не `null`.
void ensureValid(String? problem) {
  if (problem != null) throw ValidationError(problem);
}

bool isBlank(String? value) => value == null || value.trim().isEmpty;

/// Напоминания: список уникальных «минут до начала» 0…40320, не более 5.
String? remindersProblem(List<int>? reminders) {
  if (reminders == null) return null;
  if (reminders.length > maxReminders) {
    return 'Не больше $maxReminders напоминаний';
  }
  if (reminders.toSet().length != reminders.length) {
    return 'Напоминания не должны повторяться';
  }
  for (final m in reminders) {
    if (m < 0 || m > maxReminderMinutes) {
      return 'Напоминание — от 0 минут до 28 суток';
    }
  }
  return null;
}

/// Название слоя, проекта и т. п.: 1…[max] символов, не пустое после trim.
String? nameProblem(String? name, int max, {String what = 'Название'}) {
  if (isBlank(name)) return '$what не может быть пустым';
  if (name!.length > max) return '$what — не длиннее $max символов';
  return null;
}

String? colorProblem(String? color) =>
    color == null || colorPattern.hasMatch(color)
    ? null
    : 'Цвет — в формате #RRGGBB';

/// Правило повторения [rrule] допустимо и `UNTIL` не раньше начала серии.
String? rulesProblem(
  String? rrule, {
  required bool allDay,
  DateTime? startUtc,
  DateTime? startDate,
}) {
  if (rrule == null) return null;
  final RRule rule;
  try {
    rule = RRule.parse(rrule, allDay: allDay);
  } on RRuleError catch (e) {
    return 'Повторение: ${e.message}';
  }
  if (allDay &&
      rule.untilDate != null &&
      startDate != null &&
      rule.untilDate!.isBefore(startDate)) {
    return 'Повторение заканчивается раньше начала';
  }
  if (!allDay &&
      rule.untilUtc != null &&
      startUtc != null &&
      rule.untilUtc!.isBefore(startUtc)) {
    return 'Повторение заканчивается раньше начала';
  }
  return null;
}

/// Год момента/даты вне 1970…2200 (spec 1).
bool _yearOut(DateTime? value) =>
    value != null && (value.year < minYear || value.year > maxYear);

/// Границы и длительность пары начало/конец (события и переопределения,
/// spec 3.2/3.3): оба или ни одного, конец не раньше начала, не длиннее
/// 366 суток, годы 1970…2200 — то же, что проверяет сервер.
String? spanProblem({
  DateTime? startAt,
  DateTime? endAt,
  DateTime? startDate,
  DateTime? endDate,
}) {
  if ((startAt == null) != (endAt == null) ||
      (startDate == null) != (endDate == null)) {
    return 'Начало и конец — вместе';
  }
  if (startAt != null && endAt != null) {
    if (_yearOut(startAt) || _yearOut(endAt)) return 'Год вне диапазона';
    if (endAt.isBefore(startAt)) return 'Конец раньше начала';
    if (endAt.difference(startAt).inDays > maxSpanDays) {
      return 'Событие не длиннее $maxSpanDays суток';
    }
  }
  if (startDate != null && endDate != null) {
    if (_yearOut(startDate) || _yearOut(endDate)) return 'Год вне диапазона';
    if (endDate.isBefore(startDate)) return 'Конец раньше начала';
    if (daysBetween(startDate, endDate) > maxSpanDays) {
      return 'Событие не длиннее $maxSpanDays суток';
    }
  }
  return null;
}

final RegExp _instanceKeyPattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}Z)?$',
);

/// Проверка переопределения экземпляра (spec 3.3): ключ, название,
/// напоминания, время/дата без одновременного задания обоих видов.
String? overrideProblem({
  required String originalStart,
  String? title,
  List<int>? reminders,
  DateTime? startAt,
  DateTime? endAt,
  DateTime? startDate,
  DateTime? endDate,
}) {
  if (!_instanceKeyPattern.hasMatch(originalStart) ||
      (originalStart.length == 10
              ? parseDate(originalStart)
              : parseInstant(originalStart)) ==
          null) {
    return 'Некорректный ключ экземпляра';
  }
  if (title != null) {
    final problem = nameProblem(title, 300);
    if (problem != null) return problem;
  }
  final rem = remindersProblem(reminders);
  if (rem != null) return rem;
  if (startAt != null && startDate != null) {
    return 'Экземпляр переносится либо по времени, либо по дате';
  }
  return spanProblem(
    startAt: startAt,
    endAt: endAt,
    startDate: startDate,
    endDate: endDate,
  );
}

/// Проверка события целиком (spec 3.2).
String? eventProblem(EventEntity e) {
  final title = nameProblem(e.title, 300);
  if (title != null) return title;
  if ((e.description?.length ?? 0) > 10000) return 'Описание слишком длинное';
  if ((e.location?.length ?? 0) > 500) return 'Место слишком длинное';
  final reminders = remindersProblem(e.reminders);
  if (reminders != null) return reminders;
  if (e.allDay) {
    if (e.startAt != null || e.endAt != null || e.tz != null) {
      return 'У события на весь день нет времени и таймзоны';
    }
    final start = e.startDate;
    final end = e.endDate;
    if (start == null || end == null) return 'Укажите даты события';
    final span = spanProblem(startDate: start, endDate: end);
    if (span != null) return span;
    return rulesProblem(e.rrule, allDay: true, startDate: start);
  }
  if (e.startDate != null || e.endDate != null) {
    return 'У события со временем нет дат «на весь день»';
  }
  final start = e.startAt;
  final end = e.endAt;
  if (start == null || end == null) return 'Укажите время начала и конца';
  final zone = e.tz;
  if (zone == null || findLocation(zone) == null) {
    return 'Неизвестная таймзона';
  }
  final span = spanProblem(startAt: start, endAt: end);
  if (span != null) return span;
  return rulesProblem(e.rrule, allDay: false, startUtc: start);
}
