import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';

/// Ключ настройки «во сколько напоминать о событиях на весь день» (spec 2.4).
const String allDayReminderTimeKey = 'calendar.all_day_reminder_time';

/// Значение по умолчанию (spec 2.4).
const String defaultAllDayReminderTime = '09:00';

final RegExp _clockPattern = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');

/// Разбор `ЧЧ:ММ` (минуты от полуночи) или `null`.
int? parseClockMinutes(String? value) {
  if (value == null || !_clockPattern.hasMatch(value)) return null;
  return int.parse(value.substring(0, 2)) * 60 + int.parse(value.substring(3));
}

/// Настройки календаря в `user_settings` (общие для устройств): цикл недель
/// и время напоминаний для событий на весь день.
class CalendarSettingsRepository {
  CalendarSettingsRepository(this._settings);

  final UserSettingsRepository _settings;

  Future<WeekCycle?> readWeekCycle() async =>
      WeekCycle.tryParse(await _settings.read(weekCycleSettingKey));

  Stream<WeekCycle?> watchWeekCycle() =>
      _settings.watch(weekCycleSettingKey).map(WeekCycle.tryParse);

  /// Сохраняет цикл; `null` или длина 1 — цикл выключен (ключ удаляется).
  Future<void> writeWeekCycle(WeekCycle? cycle) async {
    if (cycle == null || !cycle.isEnabled) {
      await _settings.remove(weekCycleSettingKey);
      return;
    }
    if (cycle.length > WeekCycle.maxLength) {
      throw const ValidationError('Цикл — не длиннее 8 недель');
    }
    await _settings.set(weekCycleSettingKey, cycle.toJson());
  }

  Future<String> readAllDayReminderTime() async {
    final value = await _settings.read(allDayReminderTimeKey);
    return value is String && parseClockMinutes(value) != null
        ? value
        : defaultAllDayReminderTime;
  }

  Stream<String> watchAllDayReminderTime() => _settings
      .watch(allDayReminderTimeKey)
      .map(
        (v) => v is String && parseClockMinutes(v) != null
            ? v
            : defaultAllDayReminderTime,
      );

  Future<void> writeAllDayReminderTime(String value) async {
    if (parseClockMinutes(value) == null) {
      throw const ValidationError('Время — в формате ЧЧ:ММ');
    }
    await _settings.set(allDayReminderTimeKey, value);
  }
}

final calendarSettingsRepositoryProvider = Provider<CalendarSettingsRepository>(
  (ref) =>
      CalendarSettingsRepository(ref.watch(userSettingsRepositoryProvider)),
);
