import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';

/// Путь встроенной копии `shared-data/calendar/holidays_ru.json`. Flutter не
/// умеет брать assets вне пакета, поэтому в `app/assets/` лежит
/// **байт-в-байт копия** канонического файла; тест
/// `test/core/holidays_test.dart` сравнивает копию с каноническим файлом
/// (порядок обновления — spec Этапа 2, раздел 7).
const String holidaysAssetPath = 'assets/calendar/holidays_ru.json';

/// Тип записи в файле праздников.
enum HolidayType {
  /// Праздничный день на своей дате.
  holiday,

  /// Дополнительный выходной по переносу (всегда будний день).
  transferOff,

  /// Рабочая суббота/воскресенье.
  workingWeekend;

  static HolidayType? parse(String value) => switch (value) {
    'holiday' => holiday,
    'transfer_off' => transferOff,
    'working_weekend' => workingWeekend,
    _ => null,
  };
}

/// Что известно о дне: нерабочий ли он и название из файла (или `null`).
@immutable
class DayInfo {
  const DayInfo({required this.isDayOff, this.name, this.type});

  final bool isDayOff;
  final String? name;
  final HolidayType? type;

  /// Праздник или перенос — есть что показать в календаре.
  bool get isNamed => name != null;
}

/// Статус данных года: `official` — по постановлению Правительства,
/// `provisional` — расчёт по ст. 112 ТК РФ, подлежит замене.
@immutable
class HolidayYear {
  const HolidayYear({required this.status, required this.days});

  final String status;
  final Map<String, DayInfo> days;

  bool get isProvisional => status == 'provisional';
}

/// Праздники РФ: встроенные статические данные (spec 7).
class HolidayCalendar {
  HolidayCalendar._(this._years, this.updated);

  /// Разбор файла `holidays_ru.json`.
  factory HolidayCalendar.fromJsonString(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    final years = <int, HolidayYear>{};
    final rawYears = data['years'] as Map<String, dynamic>;
    for (final entry in rawYears.entries) {
      final year = entry.value as Map<String, dynamic>;
      final days = <String, DayInfo>{};
      for (final raw in year['days'] as List<dynamic>) {
        final day = raw as Map<String, dynamic>;
        final type = HolidayType.parse(day['type'] as String);
        if (type == null) continue;
        days[day['date'] as String] = DayInfo(
          isDayOff: type != HolidayType.workingWeekend,
          name: day['name'] as String?,
          type: type,
        );
      }
      years[int.parse(entry.key)] = HolidayYear(
        status: year['status'] as String,
        days: days,
      );
    }
    return HolidayCalendar._(years, data['updated'] as String?);
  }

  /// Пустой календарь: только субботы и воскресенья.
  HolidayCalendar.empty() : _years = const {}, updated = null;

  final Map<int, HolidayYear> _years;
  final String? updated;

  /// Год есть в файле.
  bool hasYear(int year) => _years.containsKey(year);

  HolidayYear? year(int year) => _years[year];

  /// Правило дня: запись `holiday`/`transfer_off` — выходной,
  /// `working_weekend` — рабочий; дата без записи (и год, которого нет в
  /// файле) — выходной ровно в субботу и воскресенье.
  DayInfo dayInfo(DateTime date) {
    final entry = _years[date.year]?.days[formatDate(date)];
    if (entry != null) return entry;
    return DayInfo(isDayOff: date.weekday >= DateTime.saturday);
  }

  /// Праздничное название дня (`null`, если дня нет в файле).
  String? holidayName(DateTime date) => dayInfo(date).name;
}

/// Праздники из встроенного ассета. Тесты подменяют.
final holidayCalendarProvider = FutureProvider<HolidayCalendar>((ref) async {
  final source = await rootBundle.loadString(holidaysAssetPath);
  return HolidayCalendar.fromJsonString(source);
});
