import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/day_agenda.dart';

/// Вид «Расписание» (по умолчанию на телефоне, 02, 5.1.2): лента по дням с
/// липким заголовком дня; пустые дни схлопываются в строку «1–3 окт ·
/// ничего не запланировано». Сегодня показывается всегда.
class ScheduleView extends StatelessWidget {
  const ScheduleView({
    required this.from,
    required this.to,
    required this.items,
    required this.today,
    required this.nowWall,
    required this.holidays,
    required this.onItemTap,
    required this.onToggleTask,
    required this.bottomPadding,
    this.cycle,
    this.showHolidays = true,
    super.key,
  });

  final DateTime from;
  final DateTime to;
  final List<CalendarItem> items;
  final DateTime today;
  final DateTime nowWall;
  final HolidayCalendar holidays;
  final WeekCycle? cycle;
  final bool showHolidays;
  final double bottomPadding;
  final ValueChanged<CalendarItem> onItemTap;
  final ValueChanged<TaskItem> onToggleTask;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final slivers = <Widget>[];
    var day = from;
    var emptyFrom = -1;
    var anyItem = false;

    void flushEmpty(DateTime end) {
      if (emptyFrom < 0) return;
      final start = addDays(from, emptyFrom);
      final last = addDays(end, -1);
      final label = start == last
          ? dayTitleShort(start)
          : '${start.day}${start.month == last.month ? '' : ' ${monthShortNames[start.month - 1]}'}'
                '–${last.day} ${monthShortNames[last.month - 1]}';
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            key: Key('empty-days-${formatDate(start)}'),
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              '$label · ничего не запланировано',
              style: t.bodyS.copyWith(color: c.textTertiary),
            ),
          ),
        ),
      );
      emptyFrom = -1;
    }

    while (day.isBefore(to)) {
      final current = day;
      final dayItems = itemsOn(items, current);
      final keep =
          dayItems.isNotEmpty ||
          day == today ||
          (showHolidays && holidays.holidayName(day) != null);
      if (!keep) {
        if (emptyFrom < 0) emptyFrom = daysBetween(from, day);
      } else {
        flushEmpty(day);
        anyItem = anyItem || dayItems.isNotEmpty;
        final weekLabel = cycle != null && cycle!.isEnabled
            ? cycle!.labelForDate(day)
            : null;
        slivers.add(
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: _HeaderDelegate(
                  DayHeaderLabel(
                    day: day,
                    today: today,
                    holidays: holidays,
                    showHolidays: showHolidays,
                    weekLabel: weekLabel != null && day.weekday == 1
                        ? weekLabel
                        : null,
                  ),
                ),
              ),
              if (dayItems.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      'Свободный день',
                      key: Key('free-day-${formatDate(day)}'),
                      style: t.bodyS.copyWith(color: c.textTertiary),
                    ),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: dayItems.length,
                  itemBuilder: (context, i) => AgendaRow(
                    item: dayItems[i],
                    day: current,
                    nowWall: nowWall,
                    onTap: () => onItemTap(dayItems[i]),
                    onToggleTask: onToggleTask,
                  ),
                ),
            ],
          ),
        );
      }
      day = addDays(day, 1);
    }
    flushEmpty(to);
    if (!anyItem) {
      return const EmptyState(
        key: Key('schedule-empty'),
        icon: LucideIcons.calendarCheck,
        title: 'Ничего не запланировано',
        message:
            'Нажмите «+», чтобы добавить событие или задачу. '
            'Ближайшие два месяца свободны.',
      );
    }
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: bottomPadding)));
    return CustomScrollView(key: const Key('schedule-list'), slivers: slivers);
  }
}

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  _HeaderDelegate(this.child);

  final Widget child;

  @override
  double get minExtent => 40;

  @override
  double get maxExtent => 40;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox(height: 40, child: child);

  @override
  bool shouldRebuild(_HeaderDelegate oldDelegate) => oldDelegate.child != child;
}
