import 'package:flutter/material.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/calendar_blocks.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/time_grid.dart';

/// Вид «Месяц» (02, 5.1.2): 6 недель с понедельника. На телефоне — ячейки
/// с серыми точками (до 3 и «+2»); на десктопе — плашки событий и «Ещё 2».
/// Слева узкая колонка меток чередования недель («Н»/«Ч»), если цикл
/// включён. Выбранный день выделен; тап по дню сообщает [onDayTap].
class MonthView extends StatelessWidget {
  const MonthView({
    required this.month,
    required this.items,
    required this.today,
    required this.holidays,
    required this.onDayTap,
    this.selected,
    this.cycle,
    this.desktop = false,
    this.showHolidays = true,
    super.key,
  });

  /// Любая дата отображаемого месяца.
  final DateTime month;
  final List<CalendarItem> items;
  final DateTime today;
  final HolidayCalendar holidays;
  final DateTime? selected;
  final WeekCycle? cycle;
  final bool desktop;
  final bool showHolidays;
  final ValueChanged<DateTime> onDayTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final first = mondayOf(DateTime.utc(month.year, month.month));
    final cycleOn = cycle != null && cycle!.isEnabled;
    return LayoutBuilder(
      builder: (context, constraints) {
        final rowHeight = (constraints.maxHeight - 24) / 6;
        return Column(
          children: [
            SizedBox(
              height: 24,
              child: Row(
                children: [
                  if (cycleOn) const SizedBox(width: 22),
                  for (var d = 0; d < 7; d++)
                    Expanded(
                      child: Center(
                        child: Text(
                          weekdayShortNames[d].toUpperCase(),
                          style: t.overline.copyWith(color: c.textTertiary),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            for (var w = 0; w < 6; w++)
              SizedBox(
                height: rowHeight,
                child: Row(
                  children: [
                    if (cycleOn)
                      SizedBox(
                        width: 22,
                        child: Center(
                          child: Text(
                            _cycleMark(addDays(first, 7 * w)),
                            key: Key('week-mark-$w'),
                            style: t.caption.copyWith(color: c.textTertiary),
                          ),
                        ),
                      ),
                    for (var d = 0; d < 7; d++)
                      Expanded(
                        child: _DayCell(
                          day: addDays(first, 7 * w + d),
                          month: month,
                          items: items,
                          today: today,
                          selected: selected,
                          holidays: holidays,
                          showHolidays: showHolidays,
                          desktop: desktop,
                          onTap: onDayTap,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  String _cycleMark(DateTime monday) {
    final cycle = this.cycle!;
    final label = cycle.labelForDate(monday);
    if (cycle.length == 2) return label.substring(0, 1).toUpperCase();
    return '${cycle.weekNumber(monday)}';
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.month,
    required this.items,
    required this.today,
    required this.selected,
    required this.holidays,
    required this.showHolidays,
    required this.desktop,
    required this.onTap,
  });

  final DateTime day;
  final DateTime month;
  final List<CalendarItem> items;
  final DateTime today;
  final DateTime? selected;
  final HolidayCalendar holidays;
  final bool showHolidays;
  final bool desktop;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final inMonth = day.month == month.month;
    final dayItems = itemsOn(items, day);
    final info = holidays.dayInfo(day);
    final holiday = showHolidays ? info.name : null;
    final dayOff = showHolidays && info.isDayOff;
    final isSelected = selected != null && day == dateOnly(selected!);
    const maxShown = 3;
    return InkWell(
      key: Key('month-cell-${formatDate(day)}'),
      onTap: () => onTap(day),
      child: Container(
        margin: const EdgeInsets.all(0.5),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected ? c.surface3 : null,
          borderRadius: AppRadii.borderXs,
          border: Border(top: BorderSide(color: c.borderSubtle)),
        ),
        child: Opacity(
          opacity: inMonth ? 1 : 0.45,
          child: Column(
            children: [
              DayNumberBadge(
                day: day,
                today: today,
                dayOff: dayOff,
                size: desktop ? 24 : 26,
              ),
              if (desktop) ...[
                if (holiday != null)
                  Text(
                    holiday,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.caption.copyWith(color: c.textSecondary),
                  ),
                Expanded(
                  child: ClipRect(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final item in dayItems.take(
                          maxShown - (holiday != null ? 1 : 0),
                        ))
                          AllDayChip(
                            title: item.allDay || item is TaskItem
                                ? item.title
                                : '${timeOf(item.start)} ${item.title}',
                            height: 18,
                            outlined:
                                item is EventItem && item.layerKind == 'work',
                            onTap: () => onTap(day),
                          ),
                        if (dayItems.length >
                            maxShown - (holiday != null ? 1 : 0))
                          Text(
                            'Ещё ${dayItems.length - (maxShown - (holiday != null ? 1 : 0))}',
                            style: t.caption.copyWith(color: c.textSecondary),
                          ),
                      ],
                    ),
                  ),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    key: Key('month-dots-${formatDate(day)}'),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < dayItems.length && i < 3; i++)
                        Container(
                          width: 5,
                          height: 5,
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          decoration: BoxDecoration(
                            color: c.textTertiary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      if (dayItems.length > 3)
                        Padding(
                          padding: const EdgeInsets.only(left: 2),
                          child: Text(
                            '+${dayItems.length - 3}',
                            style: t.caption.copyWith(
                              color: c.textSecondary,
                              fontSize: 9,
                              height: 1,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Пометка выходного/праздничного числа доступна и вне месяца.
bool isDayOff(HolidayCalendar holidays, DateTime day) =>
    holidays.dayInfo(day).isDayOff;
