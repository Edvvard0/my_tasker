import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

final RegExp _tagPattern = RegExp(r'^[^\s#@+!]{1,50}$');

/// Имя тега допустимо: 1–50 символов без пробельных символов и `# @ + !`.
bool isValidTagName(String name) => _tagPattern.hasMatch(name);

/// Проверка задачи целиком (spec 4.1).
String? taskProblem(TaskEntity t) {
  final title = nameProblem(t.title, 500);
  if (title != null) return title;
  if ((t.notes?.length ?? 0) > 20000) return 'Заметки слишком длинные';
  if (t.priority != null && (t.priority! < 1 || t.priority! > 5)) {
    return 'Приоритет — от P1 до P5';
  }
  if (t.durationMinutes != null &&
      (t.durationMinutes! < 1 || t.durationMinutes! > 1440)) {
    return 'Длительность — от 1 минуты до 24 часов';
  }
  final reminders = remindersProblem(t.reminders);
  if (reminders != null) return reminders;
  if (t.due.hasTime && findLocation(t.due.tz ?? '') == null) {
    return 'Неизвестная таймзона';
  }
  if (t.rrule == null) {
    if (t.recurrenceMode != null) return 'Режим повторения без правила';
  } else {
    if (t.due.isNone) return 'Повторяющейся задаче нужен срок';
    if (t.recurrenceMode == null) return 'Выберите режим повторения';
    final problem = rulesProblem(
      t.rrule,
      allDay: !t.due.hasTime,
      startUtc: t.due.at,
      startDate: t.due.date,
    );
    if (problem != null) return problem;
  }
  if ((t.reminders?.isNotEmpty ?? false) && t.due.isNone) {
    return 'Напоминание требует срока';
  }
  if (t.sortOrder != null && t.sortOrder! < 0) return 'Порядок вне диапазона';
  return null;
}
