import 'dart:convert';

import 'package:my_tasker/core/calendar_time/calendar_ids.dart'
    show foldTagName;
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/domain/task_validation.dart';
import 'package:timezone/timezone.dart' as tz;

/// Аргументы `create_task` -> задача (spec Этапа 3, 6.3 «Отображение в
/// `tasks` при одобрении»): `due_date` без `due_time` — срок-дата; с
/// `due_time` — момент в поясе пользователя; статус `todo` при наличии
/// срока, иначе `inbox` (spec Этапа 2, 4.1); `source = ai`.
///
/// [projectId] — результат поиска проекта по названию (клиент сопоставляет
/// сам, Этап 2, 4.3); `null`, если проекта нет.
TaskEntity taskFromArguments(
  Map<String, Object?> args, {
  required String entityId,
  required tz.Location zone,
  String? projectId,
}) {
  final date = _date(args['due_date']);
  final time = _time(args['due_time']);
  final TaskDue due;
  if (date == null) {
    due = const TaskDue.none();
  } else if (time == null) {
    due = TaskDue.date(date);
  } else {
    due = TaskDue.at(
      wallToUtc(zone, date.year, date.month, date.day, time.$1, time.$2),
      zone.name,
    );
  }
  final priority = args['priority'];
  final duration = args['duration_minutes'];
  final notes = args['notes'];
  return TaskEntity(
    id: entityId,
    title: '${args['title'] ?? ''}'.trim(),
    status: due.isNone ? TaskStatus.inbox : TaskStatus.todo,
    notes: notes is String && notes.trim().isNotEmpty ? notes : null,
    priority: priority is int ? priority : null,
    due: due,
    durationMinutes: duration is int ? duration : null,
    projectId: projectId,
    source: TaskSource.ai,
  );
}

/// Допустимые имена тегов из аргументов (не более 5, без повторов).
List<String> tagsFromArguments(Map<String, Object?> args) {
  final raw = args['tags'];
  if (raw is! List) return const [];
  final result = <String>[];
  for (final t in raw) {
    final name = '$t'.trim();
    if (isValidTagName(name) &&
        !result.any((r) => foldTagName(r) == foldTagName(name))) {
      result.add(name);
    }
  }
  return result.take(5).toList();
}

/// Название проекта из аргументов или `null`.
String? projectFromArguments(Map<String, Object?> args) {
  final p = args['project'];
  return p is String && p.trim().isNotEmpty ? p.trim() : null;
}

/// Проверка аргументов перед одобрением; текст проблемы или `null`.
String? proposalProblem(
  Map<String, Object?> args, {
  required tz.Location zone,
}) {
  final title = '${args['title'] ?? ''}'.trim();
  if (title.isEmpty) return 'Введите название задачи';
  final due = args['due_date'];
  if (due != null && _date(due) == null) return 'Дата в формате ГГГГ-ММ-ДД';
  final time = args['due_time'];
  if (time != null && _time(time) == null) return 'Время в формате ЧЧ:ММ';
  if (time != null && due == null) return 'Время без даты задать нельзя';
  return taskProblem(taskFromArguments(args, entityId: 'check', zone: zone));
}

/// Аргументы отличаются от исходных (по значению, порядок ключей не важен).
bool argumentsDiffer(Map<String, Object?> a, Map<String, Object?> b) =>
    jsonEncode(_canonical(a)) != jsonEncode(_canonical(b));

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _canonical(value[k])};
  }
  if (value is List) return [for (final v in value) _canonical(v)];
  return value;
}

DateTime? _date(Object? value) => value is String ? parseDate(value) : null;

(int, int)? _time(Object? value) {
  if (value is! String) return null;
  final m = RegExp(r'^([01][0-9]|2[0-3]):([0-5][0-9])$').firstMatch(value);
  if (m == null) return null;
  return (int.parse(m[1]!), int.parse(m[2]!));
}
