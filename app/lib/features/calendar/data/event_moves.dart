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
        final zone = requireLocation(event.tz!);
        final oldDate = dateOnly(utcToWall(zone, slot.start));
        final newDate = dateOnly(utcToWall(zone, newStart));
        await repo.splitFollowing(
          event,
          key,
          event.copyWith(
            startAt: newStart,
            endAt: newEnd,
            rrule: rewriteRuleForMove(event.rrule!, oldDate, newDate),
          ),
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
        // Серия целиком едет жёстко: все дни недели сдвигаются одинаково.
        rrule = rule
            .copyWith(
              byDay: [
                for (final d in rule.byDay) ByDay((d.weekday + dayShift) % 7),
              ],
            )
            .toRuleString();
      } else {
        rrule = rewriteRuleForMove(
          rrule,
          dateOnly(masterWall),
          dateOnly(shifted),
        );
      }
    }
    return event.copyWith(
      startAt: start,
      endAt: start.add(newEnd.difference(newStart)),
      rrule: rrule,
    );
  }
}

/// Правило серии после переноса экземпляра с даты [from] на дату [to] (для
/// «Это и следующие»): день недели/число/порядковый номер перезаписываются
/// так, чтобы новое начало серии ([to]) подходило под правило (spec 3.2),
/// как это делает редактор (`_ruleFor`). Затрагивается только запись,
/// соответствующая переносимому экземпляру (у `TU,TH` перенос четверга на
/// пятницу даёт `TU,FR`); `COUNT`/`UNTIL`/`INTERVAL` сохраняются.
///
/// Известное ограничение: если экземпляр переносится на более раннюю дату
/// той же недели (или месяца), а другие записи правила лежат между [to] и
/// [from], хвост серии даст по ним лишний экземпляр рядом с уже прошедшими.
String rewriteRuleForMove(String rrule, DateTime from, DateTime to) {
  final rule = RRule.parse(rrule, allDay: false);
  if (from == to) return rrule;
  switch (rule.freq) {
    case 'WEEKLY' when rule.byDay.isNotEmpty:
      final oldDay = weekdayIndex(from);
      final newDay = weekdayIndex(to);
      final days = <int>{
        for (final d in rule.byDay)
          if (d.weekday == oldDay) newDay else d.weekday,
      }.toList()..sort();
      return rule
          .copyWith(byDay: [for (final d in days) ByDay(d)])
          .toRuleString();
    case 'MONTHLY' when rule.byMonthDay.isNotEmpty:
      final fromDim = daysInMonth(from.year, from.month);
      final toDim = daysInMonth(to.year, to.month);
      final days = <int>[];
      for (final e in rule.byMonthDay) {
        final matches = e == from.day || e == from.day - fromDim - 1;
        final next = !matches
            ? e
            : (e < 0 && e == to.day - toDim - 1)
            ? e
            : to.day;
        if (!days.contains(next)) days.add(next);
      }
      return rule.copyWith(byMonthDay: days).toRuleString();
    case 'MONTHLY' when rule.byDay.isNotEmpty:
      final oldOrdinal = (from.day - 1) ~/ 7 + 1;
      final oldLast = from.day + 7 > daysInMonth(from.year, from.month);
      final newOrdinal = (to.day - 1) ~/ 7 + 1;
      final newLast = to.day + 7 > daysInMonth(to.year, to.month);
      final entries = <ByDay>[];
      for (final d in rule.byDay) {
        final matches =
            d.weekday == weekdayIndex(from) &&
            (d.ordinal == null ||
                d.ordinal == oldOrdinal ||
                (oldLast && d.ordinal == -1));
        final next = !matches
            ? d
            : ByDay(
                weekdayIndex(to),
                d.ordinal == null
                    ? null
                    : (newLast && newOrdinal >= 4 ? -1 : newOrdinal),
              );
        if (!entries.contains(next)) entries.add(next);
      }
      return rule.copyWith(byDay: entries).toRuleString();
    default:
      return rrule;
  }
}

final eventMovesProvider = Provider<EventMoves>(
  (ref) => EventMoves(ref.watch(calendarRepositoryProvider)),
);
