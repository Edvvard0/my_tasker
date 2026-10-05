import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:my_tasker/features/sleep/data/sleep_settings.dart';
import 'package:timezone/timezone.dart' as tz;

/// Горизонт напоминаний «Сна» (дней вперёд, включая сегодня).
const int sleepReminderHorizonDays = 7;

/// Вид напоминания «Сна».
enum SleepReminderKind {
  /// Утреннее «Как спал?» — быстрый ввод сна.
  morning('morning'),

  /// Вечерний чек-ин.
  evening('evening');

  const SleepReminderKind(this.wire);

  final String wire;
}

/// Куда ведёт нажатие: `sleep:<morning|evening>|<дата>`.
String sleepReminderPayload(SleepReminderKind kind, String date) =>
    'sleep:${kind.wire}|$date';

/// Напоминания «Сна» на ближайшие дни (spec `stage8`, объём клиента):
/// утреннее «Как спал?» в [morning] и вечерний чек-ин в [evening], каждый день
/// горизонта. Утреннее не планируется на день, за который сон уже записан,
/// вечернее — на день с готовым чек-ином. Время — на часах пояса
/// устройства; моменты, которые уже прошли, пропускаются.
List<PlannedReminder> planSleepReminders({
  required SleepReminderSetting morning,
  required SleepReminderSetting evening,
  required Set<String> sleepDates,
  required Set<String> checkinDates,
  required DateTime now,
  required tz.Location zone,
  int horizonDays = sleepReminderHorizonDays,
}) {
  final today = dateOnly(utcToWall(zone, now));
  final result = <PlannedReminder>[];

  void add(
    SleepReminderKind kind,
    SleepReminderSetting setting,
    String date,
    DateTime day,
    String title,
    String body,
  ) {
    final fireAt = wallToUtc(
      zone,
      day.year,
      day.month,
      day.day,
      setting.minutes ~/ 60,
      setting.minutes % 60,
    );
    if (fireAt.isBefore(now)) return;
    result.add(
      PlannedReminder(
        id: reminderId(
          'sleep|${kind.wire}|$date|${fireAt.millisecondsSinceEpoch}|$body',
        ),
        fireAt: fireAt,
        title: title,
        body: body,
        payload: sleepReminderPayload(kind, date),
      ),
    );
  }

  for (var i = 0; i < horizonDays; i++) {
    final day = addDays(today, i);
    final date = formatDate(day);
    if (morning.enabled && !sleepDates.contains(date)) {
      add(
        SleepReminderKind.morning,
        morning,
        date,
        day,
        'Как спал?',
        'Запишите, когда легли и встали, — это пара касаний',
      );
    }
    if (evening.enabled && !checkinDates.contains(date)) {
      add(
        SleepReminderKind.evening,
        evening,
        date,
        day,
        'Вечерний чек-ин',
        'Что сделано, что перенести и как прошёл день',
      );
    }
  }
  result.sort((a, b) {
    final c = a.fireAt.compareTo(b.fireAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return result;
}

/// Источник напоминаний «Сна» для общего планировщика Этапа 2: пересчёт
/// идёт при правке записей сна, чек-инов и настроек.
class SleepReminderSource implements ExtraReminderSource {
  SleepReminderSource({required this.store, required this.settings});

  final SyncStore store;
  final SleepSettingsRepository settings;

  @override
  List<String> get tables => const [
    'sleep_entries',
    'evening_checkins',
    'user_settings',
  ];

  @override
  Future<List<PlannedReminder>> plan(DateTime now, tz.Location zone) async {
    final morning = await settings.readMorning();
    final evening = await settings.readEvening();
    if (!morning.enabled && !evening.enabled) return const [];
    return planSleepReminders(
      morning: morning,
      evening: evening,
      sleepDates: {
        for (final r in await store.visibleRows('sleep_entries'))
          r['date']! as String,
      },
      checkinDates: {
        for (final r in await store.visibleRows('evening_checkins'))
          r['date']! as String,
      },
      now: now,
      zone: zone,
    );
  }
}

final Provider<SleepReminderSource> sleepReminderSourceProvider =
    Provider<SleepReminderSource>(
      (ref) => SleepReminderSource(
        store: ref.watch(syncStoreProvider),
        settings: ref.watch(sleepSettingsRepositoryProvider),
      ),
    );
