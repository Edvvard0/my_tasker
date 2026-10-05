/// Развёртка расписания на дату, посещаемость, генератор сетки звонков и
/// разбор аудитории — порт эталона `backend/src/tasker/study/reference.py`
/// (spec `stage7_study.md`, разделы 3–6). Все функции чистые; Dart обязан
/// проходить общие векторы `shared-test-vectors/study/` побайтно как Python.
///
/// Даты — строки `YYYY-MM-DD`, время — `HH:MM`: сравнение строк работает
/// как в эталоне.
library;

import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';

const String unsortedTime = '99:99';
const int unsortedNumber = 99;

/// «Близко к лимиту» — от 3/4 лимита.
const int nearNumerator = 3;
const int nearDenominator = 4;

final RegExp _time = RegExp(r'^([01][0-9]|2[0-3]):([0-5][0-9])$');

// ---------------------------------------------------------------- время, звонки

/// Минуты от полуночи для `HH:MM`.
int toMinutes(String text) =>
    int.parse(text.substring(0, 2)) * 60 + int.parse(text.substring(3));

/// `HH:MM` для минут от полуночи.
String fromMinutes(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

/// Строка — корректное время занятий `HH:MM`.
bool isStudyTime(String? text) => text != null && _time.hasMatch(text);

/// Сетка звонков из начала первой пары, длительности пары и перемен
/// ([breaks] — одно число для всех или список: `breaks[i]` после пары
/// `i + 1`). `null`, если аргументы вне диапазона или последняя пара
/// заканчивается позже 23:59.
List<Bell>? generateBells(
  String firstStart,
  int duration,
  Object breaks,
  int count, {
  String semesterId = '',
}) {
  if (!_time.hasMatch(firstStart) ||
      count < 1 ||
      count > 12 ||
      duration < 1 ||
      duration > 300) {
    return null;
  }
  final List<int> gaps;
  if (breaks is int) {
    gaps = List.filled(count - 1, breaks);
  } else if (breaks is List<int>) {
    gaps = breaks;
  } else {
    return null;
  }
  if (gaps.length < count - 1) return null;
  for (final gap in gaps.take(count - 1)) {
    if (gap < 0 || gap > 240) return null;
  }
  final result = <Bell>[];
  var start = toMinutes(firstStart);
  for (var number = 1; number <= count; number++) {
    final end = start + duration;
    if (end > 23 * 60 + 59) return null;
    result.add(
      Bell(
        semesterId: semesterId,
        number: number,
        startTime: fromMinutes(start),
        endTime: fromMinutes(end),
      ),
    );
    if (number < count) start = end + gaps[number - 1];
  }
  return result;
}

/// Звонки, которые предлагаются новому семестру: первая пара в 08:30, пара
/// 90 минут, перемена 10 минут, шесть пар. Их можно сразу поправить.
const String defaultFirstBell = '08:30';
const int defaultBellDuration = 90;
const int defaultBellBreak = 10;
const int defaultBellCount = 6;

// ---------------------------------------------------------------- аудитория

const String _roomMark = '(?:кабинет|каб|аудитория|ауд|к)';
const String _buildingMark = '(?:корпус|корп|к|k)';
const String _roomNumber = '([0-9]+[a-zа-я]?)';
const String _separated = '(?:[ .,/\\-]+$_roomMark?[. ]*|$_roomMark[. ]*)';
final RegExp _withMark = RegExp(
  '^$_buildingMark[. ]*([0-9]{1,2})$_separated$_roomNumber\$',
);
final RegExp _plainPair = RegExp(
  r'^([0-9]{1,2})[ .,/\-]+' + _roomNumber + r'$',
);

/// Максимальная длина введённой аудитории.
const int maxRoomLength = 20;

const String _spaces = '    \t\r\n';

String _collapse(String text) {
  final flat = StringBuffer();
  for (final unit in text.runes) {
    final char = String.fromCharCode(unit);
    flat.write(_spaces.contains(char) ? ' ' : char);
  }
  return flat.toString().split(' ').where((p) => p.isNotEmpty).join(' ');
}

String _fold(String text) {
  final out = StringBuffer();
  for (final c in text.runes) {
    if ((c >= 0x41 && c <= 0x5A) || (c >= 0x410 && c <= 0x42F)) {
      out.writeCharCode(c + 32);
    } else if (c == 0x451 || c == 0x401) {
      out.writeCharCode(0x435);
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// Корпус и кабинет аудитории.
@immutable
class RoomParts {
  const RoomParts(this.building, this.room);

  final String? building;
  final String? room;

  @override
  bool operator ==(Object other) =>
      other is RoomParts && other.building == building && other.room == room;

  @override
  int get hashCode => Object.hash(building, room);

  @override
  String toString() => 'RoomParts($building, $room)';
}

/// «к1 28» → корпус 1, кабинет 28; «К2 101», «к 1 28», «к1-28»,
/// «корп. 2 каб. 101», «1-28»; голое «28» или любой короткий текст —
/// кабинет без корпуса. `null` — пусто или длиннее 20 символов.
RoomParts? parseRoom(String text) {
  final collapsed = _collapse(text);
  if (collapsed.isEmpty || collapsed.runes.length > maxRoomLength) return null;
  final folded = _fold(collapsed);
  for (final pattern in [_withMark, _plainPair]) {
    final match = pattern.firstMatch(folded);
    if (match != null) return RoomParts(match[1], match[2]);
  }
  return RoomParts(null, collapsed);
}

/// Как аудитория показывается и вводится: «к1 28»; корпус без кабинета —
/// «к1».
String formatRoom(String? building, String? room) {
  final hasBuilding = building != null && building.isNotEmpty;
  final hasRoom = room != null && room.isNotEmpty;
  if (hasBuilding && hasRoom) return 'к$building $room';
  if (hasBuilding) return 'к$building';
  return room ?? '';
}

// ---------------------------------------------------------------- вид дня

/// Что за день (`day.kind`).
enum DayKind {
  noSemester('no_semester'),
  regular('regular'),
  holiday('holiday'),
  special('special');

  const DayKind(this.wire);

  final String wire;
}

/// Занятие на дату (поля как в `expand_day`).
@immutable
class Lesson {
  const Lesson({
    required this.key,
    required this.source,
    required this.scheduledDate,
    required this.date,
    required this.kind,
    required this.roomText,
    required this.cancelled,
    required this.changed,
    required this.trackable,
    this.slotId,
    this.ruleId,
    this.number,
    this.start,
    this.end,
    this.title,
    this.subjectId,
    this.building,
    this.room,
    this.movedFrom,
    this.movedTo,
    this.overrideId,
  });

  final String key;

  /// `slot` — пара из расписания, `rule` — занятие особого дня.
  final String source;
  final String? slotId;
  final String? ruleId;

  /// Дата по расписанию (у перенесённого — исходная).
  final String scheduledDate;
  final String date;
  final int? number;
  final String? start;
  final String? end;
  final String? title;
  final String? subjectId;
  final LessonKind kind;
  final String? building;
  final String? room;
  final String roomText;
  final bool cancelled;
  final bool changed;
  final String? movedFrom;
  final String? movedTo;
  final String? overrideId;

  /// Можно отмечать и спрашивать «Был на паре?».
  final bool trackable;

  bool get isSlot => source == 'slot';

  /// Занятие перенесено в другой день (оно остаётся «призраком»).
  bool get isMovedAway => movedTo != null;

  Map<String, Object?> toJson() => {
    'key': key,
    'source': source,
    'slot_id': slotId,
    'rule_id': ruleId,
    'scheduled_date': scheduledDate,
    'date': date,
    'number': number,
    'start': start,
    'end': end,
    'title': title,
    'subject_id': subjectId,
    'kind': kind.wire,
    'building': building,
    'room': room,
    'room_text': roomText,
    'cancelled': cancelled,
    'changed': changed,
    'moved_from': movedFrom,
    'moved_to': movedTo,
    'override_id': overrideId,
    'trackable': trackable,
  };
}

/// Расписание одной даты.
@immutable
class ScheduleDay {
  const ScheduleDay({
    required this.date,
    required this.weekday,
    required this.kind,
    required this.lessons,
    this.semesterId,
    this.cycleWeek,
    this.name,
    this.ruleId,
  });

  final String date;
  final int weekday;
  final String? semesterId;
  final int? cycleWeek;
  final DayKind kind;
  final String? name;
  final String? ruleId;
  final List<Lesson> lessons;

  Map<String, Object?> toJson() => {
    'date': date,
    'weekday': weekday,
    'semester_id': semesterId,
    'cycle_week': cycleWeek,
    'day': {'kind': kind.wire, 'name': name, 'rule_id': ruleId},
    'lessons': [for (final l in lessons) l.toJson()],
  };
}

/// Данные для развёртки: «видимые» строки таблиц (живые, с живыми
/// родителями) и праздники (`дата → название`).
@immutable
class ScheduleInput {
  const ScheduleInput({
    this.semesters = const [],
    this.subjects = const [],
    this.bells = const [],
    this.slots = const [],
    this.dayRules = const [],
    this.overrides = const [],
    this.holidays = const {},
  });

  final List<Semester> semesters;
  final List<Subject> subjects;
  final List<Bell> bells;
  final List<ClassSlot> slots;
  final List<DayRule> dayRules;
  final List<ClassOverride> overrides;
  final Map<String, String> holidays;
}

/// Нерабочие дни из файла праздников Этапа 2 (только `holiday` и
/// `transfer_off`; обычные суббота и воскресенье — учебные дни) на
/// отрезке [first]…[last] (включительно).
Map<String, String> studyHolidays(
  HolidayCalendar calendar,
  String first,
  String last,
) {
  final from = parseDate(first);
  final to = parseDate(last);
  if (from == null || to == null) return const {};
  final found = <String, String>{};
  for (var year = from.year; year <= to.year; year++) {
    final data = calendar.year(year);
    if (data == null) continue;
    for (final entry in data.days.entries) {
      final type = entry.value.type;
      final name = entry.value.name;
      if ((type == HolidayType.holiday || type == HolidayType.transferOff) &&
          name != null &&
          entry.key.compareTo(first) >= 0 &&
          entry.key.compareTo(last) <= 0) {
        found[entry.key] = name;
      }
    }
  }
  return found;
}

// ---------------------------------------------------------------- семестр

/// Живой семестр, которому принадлежит [day]: пересекаются — побеждает
/// более поздний старт, затем больший `id`.
Semester? semesterFor(String day, List<Semester> semesters) {
  Semester? best;
  for (final s in semesters) {
    if (s.archived || s.startDate.compareTo(day) > 0) continue;
    if (day.compareTo(s.endDate) > 0) continue;
    if (best == null) {
      best = s;
      continue;
    }
    final c = s.startDate.compareTo(best.startDate);
    if (c > 0 || (c == 0 && s.id.compareTo(best.id) > 0)) best = s;
  }
  return best;
}

DateTime _day(String text) => parseDate(text)!;

bool _onCycleWeek(int? itemWeek, int number) =>
    itemWeek == null || itemWeek == number;

// ---------------------------------------------------------------- занятия даты

(String?, String?) _times(
  int? number,
  String? ownStart,
  String? ownEnd,
  String semesterId,
  String day,
  List<Bell> bells,
) {
  if (ownStart != null) return (ownStart, ownEnd);
  if (number == null) return (null, null);
  Bell? onDate;
  Bell? regular;
  for (final b in bells) {
    if (b.semesterId != semesterId || b.number != number) continue;
    if (b.onDate == day) {
      onDate ??= b;
    } else if (b.onDate == null) {
      regular ??= b;
    }
  }
  final chosen = onDate ?? regular;
  return chosen == null ? (null, null) : (chosen.startTime, chosen.endTime);
}

(String?, String?) _pair(List<(String?, String?)> levels) {
  for (final (building, room) in levels) {
    if ((building != null && building.isNotEmpty) ||
        (room != null && room.isNotEmpty)) {
      return (building, room);
    }
  }
  return (null, null);
}

Lesson _lesson(
  String day,
  Semester semester,
  ClassSlot slot,
  Map<String, Subject> subjects,
  List<Bell> bells,
  ClassOverride? override, {
  required String scheduled,
  String? movedFrom,
  String? movedTo,
}) {
  final applies =
      override != null &&
      override.action != OverrideAction.cancel &&
      movedTo == null;
  final changes = applies ? override : null;
  final subjectId = _firstNonEmpty(changes?.subjectId, slot.subjectId);
  final subject = subjectId == null ? null : subjects[subjectId];
  var (start, end) = _times(
    slot.number,
    slot.startTime,
    slot.endTime,
    semester.id,
    day,
    bells,
  );
  if (changes?.startTime != null) {
    start = changes!.startTime;
    end = changes.endTime;
  }
  final (building, room) = _pair([
    (changes?.building, changes?.room),
    (slot.building, slot.room),
    (subject?.building, subject?.room),
  ]);
  final title = _firstNonEmpty(changes?.title, slot.title) ?? subject?.name;
  final cancelled =
      override != null && override.action == OverrideAction.cancel;
  return Lesson(
    key: 'slot:${slot.id}@$scheduled',
    source: 'slot',
    slotId: slot.id,
    scheduledDate: scheduled,
    date: day,
    number: slot.number,
    start: start,
    end: end,
    title: title,
    subjectId: subjectId,
    kind: changes?.lessonKind ?? slot.kind,
    building: building,
    room: room,
    roomText: formatRoom(building, room),
    cancelled: cancelled,
    changed: applies,
    movedFrom: movedFrom,
    movedTo: movedTo,
    overrideId: override?.id,
    trackable: !cancelled && movedTo == null,
  );
}

/// Python: `a or b` для строк — пустая строка считается «нет».
String? _firstNonEmpty(String? a, String? b) {
  if (a != null && a.isNotEmpty) return a;
  if (b != null && b.isNotEmpty) return b;
  return null;
}

/// Вступает ли в силу перенос [slot] с [original] на [newDate]: пара
/// действительно идёт в исходный день (день недели, неделя цикла, дата
/// внутри её семестра и этот семестр выигрывает), а [newDate] — день того
/// же семестра. Иначе перенос игнорируется.
bool _moveArrives(
  String original,
  String newDate,
  Semester semester,
  ClassSlot slot,
  List<Semester> semesters,
) {
  for (final day in [original, newDate]) {
    final found = semesterFor(day, semesters);
    if (found == null || found.id != semester.id) return false;
  }
  return _day(original).weekday == slot.weekday &&
      _onCycleWeek(slot.cycleWeek, semester.weekNumber(original));
}

Lesson _itemLesson(
  String day,
  Semester semester,
  DayRule rule,
  RuleItem item,
  List<Bell> bells,
) {
  final (start, end) = _times(
    item.number,
    item.startTime,
    item.endTime,
    semester.id,
    day,
    bells,
  );
  return Lesson(
    key: 'rule:${rule.id}:${item.key}',
    source: 'rule',
    ruleId: rule.id,
    scheduledDate: day,
    date: day,
    number: item.number,
    start: start,
    end: end,
    title: item.title,
    kind: item.kind,
    building: item.building,
    room: item.room,
    roomText: formatRoom(item.building, item.room),
    cancelled: false,
    changed: false,
    trackable: false,
  );
}

int _order(Lesson a, Lesson b) {
  final c1 = (a.start ?? unsortedTime).compareTo(b.start ?? unsortedTime);
  if (c1 != 0) return c1;
  final c2 = (a.number ?? unsortedNumber).compareTo(b.number ?? unsortedNumber);
  return c2 != 0 ? c2 : a.key.compareTo(b.key);
}

DayRule? _activeRule(String day, int weekday, int week, List<DayRule> rules) {
  DayRule? dated;
  for (final r in rules) {
    if (r.onDate == day && (dated == null || r.id.compareTo(dated.id) > 0)) {
      dated = r;
    }
  }
  if (dated != null) return dated;
  DayRule? weekly;
  for (final r in rules) {
    if (r.onDate != null || r.weekday != weekday) continue;
    if (!_onCycleWeek(r.cycleWeek, week)) continue;
    if (weekly == null) {
      weekly = r;
      continue;
    }
    final a = (r.cycleWeek != null ? 1 : 0, r.id);
    final b = (weekly.cycleWeek != null ? 1 : 0, weekly.id);
    if (a.$1 > b.$1 || (a.$1 == b.$1 && a.$2.compareTo(b.$2) > 0)) {
      weekly = r;
    }
  }
  return weekly;
}

/// Расписание одной даты: приоритет «правило на дату → праздник → правило
/// на день недели → обычный день»; изменения на дату (отмена, смена,
/// перенос) применяются к обычным парам; перенесённая пара показывается в
/// день `new_date` при любом виде дня.
ScheduleDay expandDay(String day, ScheduleInput input) {
  final weekday = _day(day).weekday;
  final semester = semesterFor(day, input.semesters);
  if (semester == null) {
    return ScheduleDay(
      date: day,
      weekday: weekday,
      kind: DayKind.noSemester,
      lessons: const [],
    );
  }
  final week = semester.weekNumber(day);
  final bySubject = {for (final s in input.subjects) s.id: s};
  final mySlots = <String, ClassSlot>{
    for (final s in input.slots)
      if (s.semesterId == semester.id) s.id: s,
  };
  final myRules = [
    for (final r in input.dayRules)
      if (r.semesterId == semester.id) r,
  ];
  final sortedOverrides = [...input.overrides]
    ..sort((a, b) => a.id.compareTo(b.id));
  final bySlotDate = <(String, String), ClassOverride>{
    for (final o in sortedOverrides)
      if (mySlots.containsKey(o.slotId)) (o.slotId, o.date): o,
  };

  final rule = _activeRule(day, weekday, week, myRules);
  final datedRule = rule != null && rule.onDate == day;
  final holiday = input.holidays[day];
  final DayKind kind;
  final String? name;
  final String? ruleId;
  if (datedRule || (rule != null && holiday == null)) {
    kind = DayKind.special;
    name = rule.title;
    ruleId = rule.id;
  } else if (holiday != null) {
    kind = DayKind.holiday;
    name = holiday;
    ruleId = null;
  } else {
    kind = DayKind.regular;
    name = null;
    ruleId = null;
  }

  final lessons = <Lesson>[];
  final showsRegular =
      kind == DayKind.regular ||
      (kind == DayKind.special && rule != null && !rule.hideRegular);
  for (final slot in mySlots.values) {
    if (slot.weekday != weekday || !_onCycleWeek(slot.cycleWeek, week)) {
      continue;
    }
    var override = bySlotDate[(slot.id, day)];
    if (override != null &&
        override.action == OverrideAction.move &&
        !_moveArrives(
          day,
          override.newDate ?? '',
          semester,
          slot,
          input.semesters,
        )) {
      override = null; // перенос, который не может прийти: пара остаётся
    }
    if (showsRegular) {
      final movedTo = override != null && override.action == OverrideAction.move
          ? override.newDate
          : null;
      lessons.add(
        _lesson(
          day,
          semester,
          slot,
          bySubject,
          input.bells,
          override,
          scheduled: day,
          movedTo: movedTo,
        ),
      );
    }
  }
  if (kind == DayKind.special && rule != null) {
    for (final item in rule.items) {
      if (_onCycleWeek(item.cycleWeek, week)) {
        lessons.add(_itemLesson(day, semester, rule, item, input.bells));
      }
    }
  }
  for (final entry in bySlotDate.entries) {
    final override = entry.value;
    final original = entry.key.$2;
    if (override.action == OverrideAction.move &&
        override.newDate == day &&
        _moveArrives(
          original,
          day,
          semester,
          mySlots[entry.key.$1]!,
          input.semesters,
        )) {
      lessons.add(
        _lesson(
          day,
          semester,
          mySlots[entry.key.$1]!,
          bySubject,
          input.bells,
          override,
          scheduled: original,
          movedFrom: original,
        ),
      );
    }
  }
  lessons.sort(_order);
  return ScheduleDay(
    date: day,
    weekday: weekday,
    semesterId: semester.id,
    cycleWeek: week,
    kind: kind,
    name: name,
    ruleId: ruleId,
    lessons: lessons,
  );
}

/// [expandDay] для каждой даты от [first] до [last] включительно.
List<ScheduleDay> expandRange(String first, String last, ScheduleInput input) {
  final days = <ScheduleDay>[];
  var current = _day(first);
  final end = _day(last);
  while (!current.isAfter(end)) {
    days.add(expandDay(formatDate(current), input));
    current = addDays(current, 1);
  }
  return days;
}

// ---------------------------------------------------------------- посещаемость

/// Состояние лимита пропусков.
enum AttendanceState {
  noLimit('no_limit'),
  ok('ok'),
  near('near'),
  reached('reached'),
  over('over');

  const AttendanceState(this.wire);

  final String wire;
}

/// `no_limit`, `ok`, `near` (от трёх четвертей лимита), `reached`, `over`.
AttendanceState attendanceState(int absent, int? limit) {
  if (limit == null) return AttendanceState.noLimit;
  if (absent > limit) return AttendanceState.over;
  if (absent == limit) return AttendanceState.reached;
  return absent * nearDenominator >= limit * nearNumerator
      ? AttendanceState.near
      : AttendanceState.ok;
}

/// Счётчики посещаемости предмета.
@immutable
class SubjectAttendance {
  const SubjectAttendance({
    required this.subjectId,
    required this.present,
    required this.absent,
    required this.cancelled,
    required this.unmarked,
    required this.limit,
    required this.left,
    required this.state,
  });

  final String subjectId;
  final int present;
  final int absent;
  final int cancelled;
  final int unmarked;
  final int? limit;

  /// `limit - absent`; `null` без лимита; может быть отрицательным.
  final int? left;
  final AttendanceState state;

  Map<String, Object?> toJson() => {
    'subject_id': subjectId,
    'present': present,
    'absent': absent,
    'cancelled': cancelled,
    'unmarked': unmarked,
    'limit': limit,
    'left': left,
    'state': state.wire,
  };
}

/// Счётчики по предметам (в порядке [ScheduleInput.subjects]): занятия с
/// начала семестра по [through] включительно. Считаются только пары из
/// расписания, не перенесённые в другой день; день принадлежит одному
/// семестру — победителю на эту дату; отменённые пропуском не являются.
List<SubjectAttendance> attendanceSummary(
  String through,
  ScheduleInput input,
  List<AttendanceMark> attendance,
) {
  final marks = <(String, String), AttendanceStatus>{
    for (final a in attendance) (a.slotId, a.date): a.status,
  };
  final counts = <String, List<int>>{
    // present, absent, cancelled, unmarked
    for (final s in input.subjects) s.id: [0, 0, 0, 0],
  };
  for (final semester in input.semesters) {
    if (semester.archived) continue;
    final last = through.compareTo(semester.endDate) < 0
        ? through
        : semester.endDate;
    if (semester.startDate.compareTo(last) > 0) continue;
    for (final entry in expandRange(semester.startDate, last, input)) {
      if (entry.semesterId != semester.id) continue;
      for (final lesson in entry.lessons) {
        if (!lesson.isSlot || lesson.movedTo != null) continue;
        final bucket = counts[lesson.subjectId ?? ''];
        if (bucket == null) continue;
        final mark = marks[(lesson.slotId ?? '', lesson.scheduledDate)];
        if (lesson.cancelled || mark == AttendanceStatus.cancelled) {
          bucket[2]++;
        } else if (mark == AttendanceStatus.present) {
          bucket[0]++;
        } else if (mark == AttendanceStatus.absent) {
          bucket[1]++;
        } else {
          bucket[3]++;
        }
      }
    }
  }
  return [
    for (final subject in input.subjects)
      () {
        final b = counts[subject.id]!;
        final limit = subject.absenceLimit;
        return SubjectAttendance(
          subjectId: subject.id,
          present: b[0],
          absent: b[1],
          cancelled: b[2],
          unmarked: b[3],
          limit: limit,
          left: limit == null ? null : limit - b[1],
          state: attendanceState(b[1], limit),
        );
      }(),
  ];
}
