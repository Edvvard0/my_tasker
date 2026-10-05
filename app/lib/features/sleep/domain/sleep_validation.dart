/// Проверки «Сна и ритуалов» на клиенте (spec `stage8_sleep_rituals.md`,
/// раздел 2). Сервер отвергает то же самое построчно
/// (`backend/src/tasker/sleep/schema.py`); здесь — те же правила с русскими
/// сообщениями для форм. Каждая функция возвращает первую проблему или `null`.
library;

import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/features/sleep/domain/sleep_calc.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';

/// Не больше «главных дел» в плане.
const int maxPlanTasks = 10;

/// Не больше задач в чек-ине (сделано / перенесено).
const int maxCheckinTasks = 50;

const int maxNoteLength = 2000;

final RegExp _uuidLower = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

bool _realDate(String? date) => date != null && parseDate(date) != null;

String? _noteProblem(String? note) =>
    (note?.length ?? 0) > maxNoteLength ? 'Заметка слишком длинная' : null;

String? _idsProblem(String what, List<String> ids, int limit) {
  if (ids.length > limit) return '$what: не больше $limit задач';
  if (!ids.every(_uuidLower.hasMatch)) return '$what: неверный идентификатор';
  if (ids.toSet().length != ids.length) return '$what: задача повторяется';
  return null;
}

/// Сон: время, зоны, дата = локальная дата пробуждения.
String? sleepProblem(SleepEntry e) {
  if (!_realDate(e.date)) return 'Дата сна: нет такой даты';
  if (findLocation(e.wakeTz) == null) return 'Неизвестный часовой пояс';
  final bedTz = e.bedTz;
  if (bedTz != null && findLocation(bedTz) == null) {
    return 'Неизвестный часовой пояс';
  }
  if (!e.wakeAt.isAfter(e.bedAt)) return 'Подъём должен быть позже отбоя';
  if (e.wakeAt.difference(e.bedAt).inSeconds > maxSleepMinutes * 60) {
    return 'Сон — не длиннее 24 часов';
  }
  final q = e.quality;
  if (q != null && (q < 1 || q > 5)) return 'Самочувствие — от 1 до 5';
  if (sleepDate(formatInstant(e.wakeAt), e.wakeTz) != e.date) {
    return 'Дата сна — день пробуждения';
  }
  return _noteProblem(e.note);
}

/// Ни один из моментов сна не дальше суток вперёд от часов устройства
/// (сервер отвергает такое по своим часам: `sleep_time_problem`).
String? sleepTimeProblem(SleepEntry e, DateTime now) {
  final limit = now.toUtc().add(const Duration(days: 1));
  if (e.bedAt.isAfter(limit) || e.wakeAt.isAfter(limit)) {
    return 'Время сна не может быть в будущем';
  }
  return null;
}

/// Утренний план: до 10 задач, «главное» — настоящий uuid.
String? planProblem(DailyPlan p) {
  if (!_realDate(p.date)) return 'Дата плана: нет такой даты';
  final main = p.mainTaskId;
  if (main != null && !_uuidLower.hasMatch(main)) {
    return 'Главное дело: неверный идентификатор';
  }
  return _idsProblem('План', p.taskIds, maxPlanTasks) ?? _noteProblem(p.note);
}

/// Вечерний чек-ин: оценка 1…5, до 50 сделанных и до 50 решений.
String? checkinProblem(EveningCheckin c) {
  if (!_realDate(c.date)) return 'Дата чек-ина: нет такой даты';
  final r = c.rating;
  if (r != null && (r < 1 || r > 5)) return 'Оценка дня — от 1 до 5';
  final done = _idsProblem('Сделано', c.doneTaskIds, maxCheckinTasks);
  if (done != null) return done;
  if (c.carryOver.length > maxCheckinTasks) {
    return 'Перенос: не больше $maxCheckinTasks задач';
  }
  final seen = <String>{};
  for (final d in c.carryOver) {
    if (!isUuid(d.taskId)) return 'Перенос: неверный идентификатор';
    if (!seen.add(d.taskId)) return 'Перенос: задача повторяется';
    final date = d.date;
    if (date != null && !_realDate(date)) return 'Перенос: нет такой даты';
  }
  return _noteProblem(c.note);
}
