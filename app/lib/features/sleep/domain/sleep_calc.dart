/// Расчёты «Сна и ритуалов»: длительность сна, средний сон, связь сна с
/// задачами, серии ритуалов, перенос задач из чек-ина. Порт эталона
/// `backend/src/tasker/sleep/reference.py` (spec `stage8_sleep_rituals.md`,
/// разделы 3–6); общие векторы — `shared-test-vectors/sleep/`.
///
/// Чистые функции над «JSON-строками» таблиц (карты с именами колонок;
/// моменты `YYYY-MM-DDTHH:MM:SSZ` в UTC, даты `YYYY-MM-DD`). Всё
/// целочисленное: длительность — целые минуты (вниз), среднее — вниз, доли —
/// в базисных пунктах (1/10 000, вниз). Деления на ноль нет: результат
/// `null`.
library;

import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart' show Json;

/// Сон длиннее 24 часов невозможен.
const int maxSleepMinutes = 24 * 60;

/// Ночь короче 6 часов — «короткая» (константа контракта, 3.3).
const int shortSleepMinutes = 360;

/// Дней с задачами в каждой группе, чтобы сравнение считалось осмысленным.
const int minGroupDays = 2;

/// Окно связи сна с задачами — неделя.
const int weekDays = 7;

/// Базисные пункты: 10 000 = 100 %.
const int basis = 10000;

// ------------------------------------------------------------------ одна ночь

/// Целые минуты (вниз) между двумя моментами UTC; `null`, если длина не
/// положительна, больше 24 часов или момент не разбирается. Пояса в
/// длительности не участвуют: это разность моментов, поэтому ночь через
/// полночь, смену пояса и переход на летнее время считаются верно сами.
int? durationMinutes(String bedAt, String wakeAt) {
  final bed = parseInstant(bedAt);
  final wake = parseInstant(wakeAt);
  if (bed == null || wake == null) return null;
  final seconds = wake.difference(bed).inSeconds;
  if (seconds <= 0 || seconds > maxSleepMinutes * 60) return null;
  return seconds ~/ 60;
}

/// «Настенное» время момента в зоне [tz] (поля как у `DateTime.utc`);
/// `null` — момент или зона не разбираются.
DateTime? localMoment(String moment, String tz) {
  final instant = parseInstant(moment);
  final zone = findLocation(tz);
  if (instant == null || zone == null) return null;
  return utcToWall(zone, instant);
}

/// Дата сна: локальная дата пробуждения в зоне, где проснулись.
String? sleepDate(String wakeAt, String wakeTz) {
  final local = localMoment(wakeAt, wakeTz);
  return local == null ? null : formatDate(local);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// `ЧЧ:ММ` момента на часах зоны [tz] (минуты отбрасываются).
String? localClock(String moment, String tz) {
  final local = localMoment(moment, tz);
  return local == null ? null : '${_two(local.hour)}:${_two(local.minute)}';
}

/// Что показывает строка сна: длительность, дата и два времени на часах.
class EntryView {
  const EntryView({
    required this.date,
    required this.minutes,
    required this.bedLocal,
    required this.wakeLocal,
  });

  final String date;
  final int minutes;
  final String bedLocal;
  final String wakeLocal;

  Json toJson() => {
    'date': date,
    'minutes': minutes,
    'bed_local': bedLocal,
    'wake_local': wakeLocal,
  };
}

/// Вид строки сна: отбой — в `bed_tz` (по умолчанию `wake_tz`), подъём — в
/// `wake_tz`; `null` для невалидной строки (битый момент, длина, зона).
EntryView? entryView(Json row) {
  final bedAt = row['bed_at'];
  final wakeAt = row['wake_at'];
  final wakeTz = row['wake_tz'];
  if (bedAt is! String || wakeAt is! String || wakeTz is! String) return null;
  final minutes = durationMinutes(bedAt, wakeAt);
  if (minutes == null) return null;
  final bedTz = (row['bed_tz'] as String?)?.isNotEmpty == true
      ? row['bed_tz']! as String
      : wakeTz;
  final date = sleepDate(wakeAt, wakeTz);
  final bed = localClock(bedAt, bedTz);
  final wake = localClock(wakeAt, wakeTz);
  if (date == null || bed == null || wake == null) return null;
  return EntryView(
    date: date,
    minutes: minutes,
    bedLocal: bed,
    wakeLocal: wake,
  );
}

// ------------------------------------------------------------------ окна

/// Окно из [days] дат, заканчивающееся датой [through] включительно.
(DateTime, DateTime) window(String through, int days) {
  final last = parseDate(through);
  if (last == null || days < 1) {
    throw ArgumentError('Окно: реальная дата и не меньше одного дня');
  }
  return (addDays(last, -(days - 1)), last);
}

/// Минуты сна по датам окна; невалидные строки пропускаются, при двух
/// строках на дату побеждает большой `id` (с детерминированными id не
/// бывает).
Map<String, int> minutesByDate(
  List<Json> entries,
  DateTime first,
  DateTime last,
) {
  final sorted = [...entries]
    ..sort((a, b) => '${a['id'] ?? ''}'.compareTo('${b['id'] ?? ''}'));
  final found = <String, int>{};
  for (final row in sorted) {
    final view = entryView(row);
    if (view == null) continue;
    final day = parseDate('${row['date']}');
    if (day != null && !day.isBefore(first) && !day.isAfter(last)) {
      found[formatDate(day)] = view.minutes;
    }
  }
  return found;
}

/// Средний сон окна.
class SleepAverage {
  const SleepAverage({
    required this.from,
    required this.to,
    required this.days,
    required this.daysWithData,
    required this.totalMinutes,
    required this.averageMinutes,
  });

  final String from;
  final String to;
  final int days;
  final int daysWithData;
  final int totalMinutes;

  /// `null` без единой записи.
  final int? averageMinutes;

  Json toJson() => {
    'from': from,
    'to': to,
    'days': days,
    'days_with_data': daysWithData,
    'total_minutes': totalMinutes,
    'average_minutes': averageMinutes,
  };
}

/// Средняя ночь окна. Дни без записи **пропускаются**, а не считаются
/// нулями: `average = floor(сумма / дней с данными)`.
SleepAverage averageSleep(List<Json> entries, String through, int days) {
  final (first, last) = window(through, days);
  final byDate = minutesByDate(entries, first, last);
  final total = byDate.values.fold<int>(0, (a, b) => a + b);
  return SleepAverage(
    from: formatDate(first),
    to: formatDate(last),
    days: days,
    daysWithData: byDate.length,
    totalMinutes: total,
    averageMinutes: byDate.isEmpty ? null : total ~/ byDate.length,
  );
}

// ------------------------------------------------------------------ сон и задачи

/// День задачи: `due_date` либо локальная дата `due_at` в `due_tz`; `null` —
/// задача без даты.
String? taskDay(Json task) {
  final dueDate = task['due_date'];
  if (dueDate is String && dueDate.isNotEmpty) return dueDate;
  final dueAt = task['due_at'];
  final dueTz = task['due_tz'];
  if (dueAt is String &&
      dueAt.isNotEmpty &&
      dueTz is String &&
      dueTz.isNotEmpty) {
    final local = localMoment(dueAt, dueTz);
    return local == null ? null : formatDate(local);
  }
  return null;
}

bool _countsForLink(Json task) {
  final rrule = task['rrule'];
  return (rrule == null || rrule == '') && task['status'] != 'cancelled';
}

/// Одна группа сравнения: дни с задачами, задачи, сделанные, доля.
class LinkGroup {
  const LinkGroup({
    required this.days,
    required this.tasks,
    required this.done,
    required this.shareBp,
  });

  final int days;
  final int tasks;
  final int done;

  /// Доля сделанных в базисных пунктах; `null` без задач.
  final int? shareBp;

  Json toJson() => {
    'days': days,
    'tasks': tasks,
    'done': done,
    'share_bp': shareBp,
  };
}

LinkGroup _group(int days, int tasks, int done) => LinkGroup(
  days: days,
  tasks: tasks,
  done: done,
  shareBp: tasks == 0 ? null : done * basis ~/ tasks,
);

/// Сравнение долей выполненных задач после короткого и нормального сна.
class SleepTaskLink {
  const SleepTaskLink({
    required this.from,
    required this.to,
    required this.thresholdMinutes,
    required this.short,
    required this.normal,
    required this.differenceBp,
    required this.daysWithoutSleep,
    required this.enoughData,
  });

  final String from;
  final String to;
  final int thresholdMinutes;
  final LinkGroup short;
  final LinkGroup normal;

  /// `normal - short` со знаком; `null`, если одной из долей нет.
  final int? differenceBp;
  final int daysWithoutSleep;
  final bool enoughData;

  Json toJson() => {
    'from': from,
    'to': to,
    'threshold_minutes': thresholdMinutes,
    'short': short.toJson(),
    'normal': normal.toJson(),
    'difference_bp': differenceBp,
    'days_without_sleep': daysWithoutSleep,
    'enough_data': enoughData,
  };
}

/// Связь сна с выполненными задачами за 7 дней до [through] (3.3). Это
/// сравнение двух долей, а не статистика и не причинность.
SleepTaskLink sleepTaskLink(
  List<Json> entries,
  List<Json> tasks,
  String through,
) {
  final (first, last) = window(through, weekDays);
  final minutes = minutesByDate(entries, first, last);
  final planned = <String, List<int>>{}; // дата -> [задач, сделано]
  for (final task in tasks) {
    final day = taskDay(task);
    if (day == null || !_countsForLink(task)) continue;
    final parsed = parseDate(day);
    if (parsed == null || parsed.isBefore(first) || parsed.isAfter(last)) {
      continue;
    }
    final counts = planned.putIfAbsent(day, () => [0, 0]);
    counts[0] += 1;
    if (task['status'] == 'done') counts[1] += 1;
  }
  final short = [0, 0, 0]; // дней, задач, сделано
  final normal = [0, 0, 0];
  var withoutSleep = 0;
  for (final entry in planned.entries) {
    final slept = minutes[entry.key];
    if (slept == null) {
      withoutSleep += 1;
      continue;
    }
    final group = slept < shortSleepMinutes ? short : normal;
    group[0] += 1;
    group[1] += entry.value[0];
    group[2] += entry.value[1];
  }
  final shortGroup = _group(short[0], short[1], short[2]);
  final normalGroup = _group(normal[0], normal[1], normal[2]);
  final shortShare = shortGroup.shareBp;
  final normalShare = normalGroup.shareBp;
  return SleepTaskLink(
    from: formatDate(first),
    to: formatDate(last),
    thresholdMinutes: shortSleepMinutes,
    short: shortGroup,
    normal: normalGroup,
    differenceBp: shortShare != null && normalShare != null
        ? normalShare - shortShare
        : null,
    daysWithoutSleep: withoutSleep,
    enoughData:
        shortGroup.days >= minGroupDays && normalGroup.days >= minGroupDays,
  );
}

// ------------------------------------------------------------------ серии

/// Серия: сколько дней подряд, лучшая серия и последняя дата.
class Streak {
  const Streak({required this.current, required this.best, required this.last});

  final int current;
  final int best;
  final String? last;

  Json toJson() => {'current': current, 'best': best, 'last': last};
}

/// Подряд идущие дни с ритуалом. `current` считается от [through]; если
/// сегодня ещё не отмечено — серия «жива» и считается от вчера. `best` —
/// самая длинная серия до [through]; `last` — последняя дата не позднее
/// [through]. Даты после [through] и мусор игнорируются.
Streak streak(Iterable<String> dates, String through) {
  final end = parseDate(through);
  if (end == null) throw ArgumentError('through — реальная дата');
  final done = <DateTime>{};
  for (final text in dates) {
    final d = parseDate(text);
    if (d != null && !d.isAfter(end)) done.add(d);
  }
  var cursor = done.contains(end) ? end : addDays(end, -1);
  var current = 0;
  while (done.contains(cursor)) {
    current += 1;
    cursor = addDays(cursor, -1);
  }
  final sorted = done.toList()..sort();
  var best = 0;
  var run = 0;
  DateTime? previous;
  for (final day in sorted) {
    run = previous != null && daysBetween(previous, day) == 1 ? run + 1 : 1;
    if (run > best) best = run;
    previous = day;
  }
  return Streak(
    current: current,
    best: best,
    last: sorted.isEmpty ? null : formatDate(sorted.last),
  );
}

/// Серии ритуалов: утренний план, вечерний чек-ин и оба сразу.
class RitualStreaks {
  const RitualStreaks({
    required this.morning,
    required this.evening,
    required this.both,
  });

  final Streak morning;
  final Streak evening;
  final Streak both;

  Json toJson() => {
    'morning': morning.toJson(),
    'evening': evening.toJson(),
    'both': both.toJson(),
  };
}

RitualStreaks ritualStreaks(
  Iterable<String> morning,
  Iterable<String> evening,
  String through,
) {
  final plan = morning.toSet();
  final checkin = evening.toSet();
  return RitualStreaks(
    morning: streak(plan, through),
    evening: streak(checkin, through),
    both: streak(plan.intersection(checkin), through),
  );
}

// ------------------------------------------------------------------ перенос задач

/// Что делает перенос с задачей.
enum CarryAction {
  setDueDate('set_due_date'),
  setDueAt('set_due_at'),
  skip('skip');

  const CarryAction(this.wire);

  final String wire;
}

/// Результат решения о переносе: что изменить у задачи или почему пропущено.
class CarryChange {
  const CarryChange._(
    this.taskId,
    this.action, {
    this.dueDate,
    this.dueAt,
    this.dueTz,
    this.status,
    this.reason,
  });

  const CarryChange.skip(String taskId, String reason)
    : this._(taskId, CarryAction.skip, reason: reason);

  const CarryChange.dueDate(String taskId, String dueDate, String? status)
    : this._(taskId, CarryAction.setDueDate, dueDate: dueDate, status: status);

  const CarryChange.dueAt(
    String taskId,
    String dueAt,
    String dueTz,
    String? status,
  ) : this._(
        taskId,
        CarryAction.setDueAt,
        dueAt: dueAt,
        dueTz: dueTz,
        status: status,
      );

  final String taskId;
  final CarryAction action;

  /// `set_due_date`: новая дата.
  final String? dueDate;

  /// `set_due_at`: новый момент (UTC) и прежняя зона задачи.
  final String? dueAt;
  final String? dueTz;

  /// `"todo"`, если задача была во «Входящих»; `null` — статус не менять.
  final String? status;

  /// `skip`: `not_found`, `closed`, `recurring`, `duplicate`,
  /// `not_in_future`, `unchanged`.
  final String? reason;

  bool get isSkip => action == CarryAction.skip;

  Json toJson() => switch (action) {
    CarryAction.skip => {
      'task_id': taskId,
      'action': action.wire,
      'reason': reason,
    },
    CarryAction.setDueDate => {
      'task_id': taskId,
      'action': action.wire,
      'due_date': dueDate,
      'status': status,
    },
    CarryAction.setDueAt => {
      'task_id': taskId,
      'action': action.wire,
      'due_at': dueAt,
      'due_tz': dueTz,
      'status': status,
    },
  };
}

/// То же настенное время на дате [target] в зоне [tz], момент UTC. Времени,
/// которого нет (переход вперёд), берётся смещение до перехода — момент
/// уходит вперёд на длину пропуска (02:30 -> 03:30); неоднозначное время
/// (переход назад) — первое вхождение (PEP 495 `fold = 0`).
String _atLocalDate(String moment, String tz, DateTime target) {
  final local = localMoment(moment, tz)!;
  final zone = requireLocation(tz);
  return formatInstant(
    wallToUtc(
      zone,
      target.year,
      target.month,
      target.day,
      local.hour,
      local.minute,
      local.second,
    ),
  );
}

/// Что изменить в задачах, которые чек-ин переносит; по одному результату на
/// решение, в порядке решений. Функция только считает: клиент применяет план
/// обычными правками задач (`SleepRepository.applyCarryOver`).
///
/// `to = tomorrow` — день после [checkinDate]; `to = date` — заданная дата,
/// строго позже [checkinDate]. Задача со сроком-датой (или без даты) получает
/// новый `due_date`; задача с `due_at` сохраняет настенное время в своём
/// `due_tz`. Задача из «Входящих» становится `todo`.
List<CarryChange> planCarryOver(
  String checkinDate,
  List<Json> decisions,
  List<Json> tasks,
) {
  final today = parseDate(checkinDate);
  if (today == null) throw ArgumentError('checkinDate — реальная дата');
  final byId = {for (final t in tasks) '${t['id']}': t};
  final seen = <String>{};
  final results = <CarryChange>[];
  for (final decision in decisions) {
    final taskId = '${decision['task_id']}';
    final task = byId[taskId];
    if (seen.contains(taskId)) {
      results.add(CarryChange.skip(taskId, 'duplicate'));
      continue;
    }
    seen.add(taskId);
    if (task == null) {
      results.add(CarryChange.skip(taskId, 'not_found'));
      continue;
    }
    final status = task['status'];
    if (status == 'done' || status == 'cancelled') {
      results.add(CarryChange.skip(taskId, 'closed'));
      continue;
    }
    final rrule = task['rrule'];
    if (rrule != null && rrule != '') {
      results.add(CarryChange.skip(taskId, 'recurring'));
      continue;
    }
    final target = decision['to'] == 'tomorrow'
        ? addDays(today, 1)
        : parseDate('${decision['date']}');
    if (target == null || !target.isAfter(today)) {
      results.add(CarryChange.skip(taskId, 'not_in_future'));
      continue;
    }
    final targetIso = formatDate(target);
    final dueAt = task['due_at'];
    final dueTz = task['due_tz'];
    final timed =
        dueAt is String &&
        dueAt.isNotEmpty &&
        dueTz is String &&
        dueTz.isNotEmpty;
    if (timed && taskDay(task) == targetIso) {
      results.add(CarryChange.skip(taskId, 'unchanged'));
      continue;
    }
    if (!timed && task['due_date'] == targetIso) {
      results.add(CarryChange.skip(taskId, 'unchanged'));
      continue;
    }
    final newStatus = status == 'inbox' ? 'todo' : null;
    results.add(
      timed
          ? CarryChange.dueAt(
              taskId,
              _atLocalDate(dueAt, dueTz, target),
              dueTz,
              newStatus,
            )
          : CarryChange.dueDate(taskId, targetIso, newStatus),
    );
  }
  return results;
}
