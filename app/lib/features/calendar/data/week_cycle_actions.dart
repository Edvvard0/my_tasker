import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/expansion.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:timezone/timezone.dart' as tz;

/// Экземпляр серии, отменённый действием «Пропустить неделю».
typedef SkippedInstance = ({String eventId, String key});

/// Массовые действия над чередующимся расписанием (spec 6): «Пропустить
/// неделю» (каникулы) и «Сдвинуть чётность».
class WeekCycleActions {
  WeekCycleActions({
    required this.store,
    required this.calendars,
    required this.settings,
  });

  final SyncStore store;
  final CalendarRepository calendars;
  final CalendarSettingsRepository settings;

  Future<List<EventEntity>> _recurringEvents() async => [
    for (final r in await store.visibleRows('events'))
      if (r['rrule'] != null) EventEntity.fromRow(r),
  ];

  /// «Пропустить неделю» (spec 6): для каждой серии с экземпляром на
  /// неделе [monday]–воскресенье создаётся отмена экземпляра
  /// (детерминированные id — повтор с другого устройства безопасен).
  /// Возвращает отменённые экземпляры (для «Отменить»).
  Future<List<SkippedInstance>> skipWeek(
    DateTime monday,
    tz.Location zone,
  ) async {
    final from = dateOnly(monday);
    final to = addDays(from, 7);
    final skipped = <SkippedInstance>[];
    await store.transaction(() async {
      final overrides = <String, Set<String>>{};
      for (final r in await store.visibleRows('event_overrides')) {
        final o = EventOverride.fromRow(r);
        if (o.cancelled) {
          overrides.putIfAbsent(o.eventId, () => {}).add(o.originalStart);
        }
      }
      for (final event in await _recurringEvents()) {
        final series = event.series;
        if (series == null) continue;
        final found = expandSeries(
          series,
          from: event.allDay
              ? from
              : wallToUtc(zone, from.year, from.month, from.day),
          to: event.allDay ? to : wallToUtc(zone, to.year, to.month, to.day),
          cancelled: overrides[event.id] ?? const {},
        );
        for (final o in found) {
          await calendars.cancelInstance(event, o.key);
          skipped.add((eventId: event.id, key: o.key));
        }
      }
    });
    return skipped;
  }

  /// Отменяет [skipWeek]: удаляет строки отмены.
  Future<void> undoSkipWeek(List<SkippedInstance> skipped) =>
      store.transaction(() async {
        for (final s in skipped) {
          final event = await calendars.getEvent(s.eventId);
          if (event != null) await calendars.restoreInstance(event, s.key);
        }
      });

  /// «Сдвинуть чётность» с понедельника [monday] (spec 6): в настройку
  /// цикла добавляется сдвиг, а каждая серия чередования, активная на эту
  /// дату, разрезается: старая заканчивается, новая начинается на неделю
  /// позже (тот же день и время). Возвращает число сдвинутых серий.
  Future<int> shiftParity(DateTime monday) async {
    final from = mondayOf(monday);
    final cycle = await settings.readWeekCycle();
    if (cycle == null || !cycle.isEnabled) {
      throw const ValidationError('Цикл недель выключен');
    }
    var shifted = 0;
    await store.transaction(() async {
      await settings.writeWeekCycle(
        cycle.withShift(WeekShift(from: from, weeks: 1)),
      );
      for (final event in await _recurringEvents()) {
        final rule = RRule.parse(event.rrule!, allDay: event.allDay);
        if (rule.freq != 'WEEKLY' || rule.interval != cycle.length) continue;
        if (await _shiftSeries(event, from)) shifted++;
      }
    });
    return shifted;
  }

  Future<bool> _shiftSeries(EventEntity event, DateTime from) async {
    final series = event.series;
    if (series == null) return false;
    final zone = event.allDay ? null : requireLocation(event.tz!);
    for (final o in series.originals()) {
      final date = event.allDay ? o.start : dateOnly(utcToWall(zone!, o.start));
      if (date.isBefore(from)) continue;
      final EventEntity moved;
      if (event.allDay) {
        moved = event.copyWith(
          startDate: addDays(o.start, 7),
          endDate: addDays(o.end, 7),
        );
      } else {
        final wall = utcToWall(zone!, o.start);
        final next = wallToUtc(
          zone,
          wall.year,
          wall.month,
          wall.day + 7,
          wall.hour,
          wall.minute,
          wall.second,
        );
        moved = event.copyWith(
          startAt: next,
          endAt: next.add(o.end.difference(o.start)),
        );
      }
      try {
        await calendars.splitFollowing(event, o.key, moved);
      } on ValidationError {
        // Новая серия начиналась бы после `UNTIL`: старая просто кончается.
        await calendars.deleteFollowing(event, o.key);
      }
      return true;
    }
    return false;
  }
}

final weekCycleActionsProvider = Provider<WeekCycleActions>(
  (ref) => WeekCycleActions(
    store: ref.watch(syncStoreProvider),
    calendars: ref.watch(calendarRepositoryProvider),
    settings: ref.watch(calendarSettingsRepositoryProvider),
  ),
);
