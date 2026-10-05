import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart'
    show parseClockMinutes;
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart'
    show ValidationError;
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';

/// Ключи настроек напоминаний «Сна» в `user_settings` (общие для устройств).
const String morningReminderKey = 'sleep.morning_reminder';
const String eveningReminderKey = 'sleep.evening_reminder';

/// Время по умолчанию: утреннее «Как спал?» — 09:00 (к этому времени человек
/// обычно уже проснулся, а запись сна ещё свежа); вечерний чек-ин — 21:30
/// (день по сути закончился, до сна остаётся время перенести дела).
const String defaultMorningTime = '09:00';
const String defaultEveningTime = '21:30';

/// Настройка одного напоминания: включено ли и во сколько (`ЧЧ:ММ`).
@immutable
class SleepReminderSetting {
  const SleepReminderSetting({required this.enabled, required this.time});

  factory SleepReminderSetting.fromValue(Object? value, String fallbackTime) {
    if (value is Map) {
      final time = value['time'];
      return SleepReminderSetting(
        enabled: value['enabled'] != false,
        time: time is String && parseClockMinutes(time) != null
            ? time
            : fallbackTime,
      );
    }
    return SleepReminderSetting(enabled: true, time: fallbackTime);
  }

  final bool enabled;
  final String time;

  /// Минуты от полуночи.
  int get minutes => parseClockMinutes(time) ?? 0;

  Map<String, Object?> toJson() => {'enabled': enabled, 'time': time};

  SleepReminderSetting copyWith({bool? enabled, String? time}) =>
      SleepReminderSetting(
        enabled: enabled ?? this.enabled,
        time: time ?? this.time,
      );

  @override
  bool operator ==(Object other) =>
      other is SleepReminderSetting &&
      other.enabled == enabled &&
      other.time == time;

  @override
  int get hashCode => Object.hash(enabled, time);
}

/// Напоминания «Сна» в `user_settings`: утреннее «Как спал?» и вечерний
/// чек-ин.
class SleepSettingsRepository {
  SleepSettingsRepository(this._settings);

  final UserSettingsRepository _settings;

  Future<SleepReminderSetting> readMorning() async =>
      SleepReminderSetting.fromValue(
        await _settings.read(morningReminderKey),
        defaultMorningTime,
      );

  Future<SleepReminderSetting> readEvening() async =>
      SleepReminderSetting.fromValue(
        await _settings.read(eveningReminderKey),
        defaultEveningTime,
      );

  Stream<SleepReminderSetting> watchMorning() => _settings
      .watch(morningReminderKey)
      .map((v) => SleepReminderSetting.fromValue(v, defaultMorningTime));

  Stream<SleepReminderSetting> watchEvening() => _settings
      .watch(eveningReminderKey)
      .map((v) => SleepReminderSetting.fromValue(v, defaultEveningTime));

  Future<void> _write(String key, SleepReminderSetting setting) async {
    if (parseClockMinutes(setting.time) == null) {
      throw const ValidationError('Время — в формате ЧЧ:ММ');
    }
    await _settings.set(key, setting.toJson());
  }

  Future<void> writeMorning(SleepReminderSetting setting) =>
      _write(morningReminderKey, setting);

  Future<void> writeEvening(SleepReminderSetting setting) =>
      _write(eveningReminderKey, setting);
}

final sleepSettingsRepositoryProvider = Provider<SleepSettingsRepository>(
  (ref) => SleepSettingsRepository(ref.watch(userSettingsRepositoryProvider)),
);
