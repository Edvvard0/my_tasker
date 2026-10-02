import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/domain/recurrence_scope.dart';

/// Перенос и изменение длительности события перетаскиванием в сетке
/// (02, 5.1.6): для повторяющегося — «Только это · Это и следующие · Все».
class EventMoves {
  EventMoves(this.repo);

  final CalendarRepository repo;

  /// Переносит экземпляр [key] события [event] на новые границы
  /// [newStart]…[newEnd] (моменты UTC; событие с временем) по правилу
  /// [scope]. Для не повторяющегося события [scope] игнорируется.
  Future<void> move(
    EventEntity event, {
    required String key,
    required DateTime newStart,
    required DateTime newEnd,
    RecurrenceScope scope = RecurrenceScope.all,
  }) async {
    if (event.allDay) {
      throw const ValidationError('События на весь день не переносятся мышью');
    }
    if (!event.isRecurring) {
      await repo.updateEvent(event.copyWith(startAt: newStart, endAt: newEnd));
      return;
    }
    final series = event.series;
    final slot = series?.slotOf(key);
    if (series == null || slot == null) {
      throw const ValidationError('Экземпляр не найден');
    }
    switch (scope) {
      case RecurrenceScope.only:
        final existing = (await repo.overridesOf(event.id))
            .where((o) => o.originalStart == key)
            .firstOrNull;
        await repo.overrideInstance(
          event,
          key,
          InstanceChange(
            title: existing?.title,
            description: existing?.description,
            location: existing?.location,
            reminders: existing?.reminders,
            startAt: newStart,
            endAt: newEnd,
          ),
        );
      case RecurrenceScope.following:
        await repo.splitFollowing(
          event,
          key,
          event.copyWith(startAt: newStart, endAt: newEnd),
        );
      case RecurrenceScope.all:
        await repo.updateEvent(
          _shiftedMaster(event, slot.start, newStart, newEnd),
        );
    }
  }

  /// Серия целиком: начало сдвигается на ту же «настенную» разницу в поясе
  /// события, дни недели правила (`BYDAY`) — на то же число дней.
  EventEntity _shiftedMaster(
    EventEntity event,
    DateTime oldStart,
    DateTime newStart,
    DateTime newEnd,
  ) {
    final zone = requireLocation(event.tz!);
    final oldWall = utcToWall(zone, oldStart);
    final newWall = utcToWall(zone, newStart);
    final masterWall = utcToWall(zone, event.startAt!);
    final shifted = DateTime.utc(
      masterWall.year,
      masterWall.month,
      masterWall.day + daysBetween(dateOnly(oldWall), dateOnly(newWall)),
      masterWall.hour + (newWall.hour - oldWall.hour),
      masterWall.minute + (newWall.minute - oldWall.minute),
      masterWall.second,
    );
    final start = wallToUtc(
      zone,
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
    );
    final dayShift = daysBetween(dateOnly(oldWall), dateOnly(newWall));
    var rrule = event.rrule;
    if (rrule != null && dayShift != 0) {
      final rule = RRule.parse(rrule, allDay: false);
      if (rule.freq == 'WEEKLY' && rule.byDay.isNotEmpty) {
        rrule = rule
            .copyWith(
              byDay: [
                for (final d in rule.byDay) ByDay((d.weekday + dayShift) % 7),
              ],
            )
            .toRuleString();
      }
    }
    return event.copyWith(
      startAt: start,
      endAt: start.add(newEnd.difference(newStart)),
      rrule: rrule,
    );
  }
}

final eventMovesProvider = Provider<EventMoves>(
  (ref) => EventMoves(ref.watch(calendarRepositoryProvider)),
);
