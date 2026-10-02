import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';

/// Ключ `user_settings` с настройкой цикла недель (spec 6).
const String weekCycleSettingKey = 'calendar.week_cycle';

/// Запись «сдвинуть чётность»: с недели, содержащей [from], номер недели
/// цикла увеличивается на [weeks] (может быть отрицательным).
@immutable
class WeekShift {
  const WeekShift({required this.from, required this.weeks});

  final DateTime from;
  final int weeks;

  Map<String, Object?> toJson() => {'from': formatDate(from), 'weeks': weeks};

  @override
  bool operator ==(Object other) =>
      other is WeekShift && other.from == from && other.weeks == weeks;

  @override
  int get hashCode => Object.hash(from, weeks);
}

/// Настройка `calendar.week_cycle` (spec 6): длина цикла, опорная неделя
/// №1, названия недель и сдвиги чётности. Нет настройки — цикл выключен
/// («каждую неделю одинаково»).
@immutable
class WeekCycle {
  const WeekCycle({
    required this.length,
    required this.week1Start,
    this.labels,
    this.shifts = const [],
  });

  final int length;
  final DateTime week1Start;
  final List<String>? labels;
  final List<WeekShift> shifts;

  static const int maxLength = 8;
  static const int maxLabelLength = 30;

  /// Цикл включён (длина больше 1).
  bool get isEnabled => length > 1;

  /// Разбор значения настройки; `null`, если значение не по спецификации
  /// (проверки — на клиенте: сервер значение не проверяет).
  static WeekCycle? tryParse(Object? json) {
    if (json is! Map) return null;
    final length = json['length'];
    final start = json['week1_start'];
    if (length is! int || length < 1 || length > maxLength) return null;
    if (start is! String) return null;
    final startDate = parseDate(start);
    if (startDate == null) return null;
    List<String>? labels;
    final rawLabels = json['labels'];
    if (rawLabels != null) {
      if (rawLabels is! List || rawLabels.length != length) return null;
      final parsed = <String>[];
      for (final l in rawLabels) {
        if (l is! String || l.trim().isEmpty || l.length > maxLabelLength) {
          return null;
        }
        parsed.add(l);
      }
      labels = parsed;
    }
    final shifts = <WeekShift>[];
    final rawShifts = json['shifts'];
    if (rawShifts != null) {
      if (rawShifts is! List) return null;
      for (final s in rawShifts) {
        if (s is! Map) return null;
        final from = s['from'];
        final weeks = s['weeks'];
        if (from is! String || weeks is! int) return null;
        final fromDate = parseDate(from);
        if (fromDate == null) return null;
        shifts.add(WeekShift(from: fromDate, weeks: weeks));
      }
    }
    return WeekCycle(
      length: length,
      week1Start: startDate,
      labels: labels,
      shifts: shifts,
    );
  }

  Map<String, Object?> toJson() => {
    'length': length,
    'week1_start': formatDate(week1Start),
    if (labels != null) 'labels': labels,
    if (shifts.isNotEmpty) 'shifts': [for (final s in shifts) s.toJson()],
  };

  /// Номер недели цикла (с 1), в которую попадает [day] (spec 6):
  /// делим вниз, а не к нулю — даты до опоры тоже работают.
  int weekNumber(DateTime day) {
    final monday = mondayOf(day);
    final days = daysBetween(mondayOf(week1Start), monday);
    var weeks = days ~/ 7;
    if (days % 7 != 0 && days < 0) weeks -= 1;
    for (final s in shifts) {
      if (!mondayOf(s.from).isAfter(monday)) weeks += s.weeks;
    }
    return weeks % length + 1;
  }

  /// Ближайшая дата `>= after` с днём недели [weekday] (0 = пн) в неделе
  /// цикла [week] (spec 6, «Создание»).
  DateTime firstDate(DateTime after, int weekday, int week) {
    var candidate = addDays(mondayOf(after), weekday);
    if (candidate.isBefore(dateOnly(after))) candidate = addDays(candidate, 7);
    // Номера недель периодичны (после последнего сдвига — с периодом
    // length); предел лишь защищает от бесконечного цикла.
    for (var i = 0; i < 2000; i++) {
      if (weekNumber(candidate) == week) return candidate;
      candidate = addDays(candidate, 7);
    }
    return candidate;
  }

  /// Подпись недели [number] (1…length): из [labels] или по умолчанию.
  String labelOf(int number) {
    final custom = labels;
    if (custom != null) return custom[number - 1];
    if (length == 2) return number == 1 ? 'Нечётная' : 'Чётная';
    return 'Неделя $number';
  }

  /// Подпись недели, в которую попадает [day].
  String labelForDate(DateTime day) => labelOf(weekNumber(day));

  WeekCycle withShift(WeekShift shift) => WeekCycle(
    length: length,
    week1Start: week1Start,
    labels: labels,
    shifts: [...shifts, shift],
  );

  @override
  bool operator ==(Object other) =>
      other is WeekCycle &&
      other.length == length &&
      other.week1Start == week1Start &&
      listEquals(other.labels, labels) &&
      listEquals(other.shifts, shifts);

  @override
  int get hashCode => Object.hash(
    length,
    week1Start,
    Object.hashAll(labels ?? const []),
    Object.hashAll(shifts),
  );
}
