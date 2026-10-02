import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/tasks/presentation/task_card.dart';

/// Строка расписания: время слева (`num-m`), справа название и место
/// (02, 5.1.2). Для задачи — чекбокс.
class AgendaRow extends StatelessWidget {
  const AgendaRow({
    required this.item,
    required this.day,
    required this.nowWall,
    required this.onTap,
    required this.onToggleTask,
    super.key,
  });

  final CalendarItem item;
  final DateTime day;
  final DateTime nowWall;
  final VoidCallback onTap;
  final ValueChanged<TaskItem> onToggleTask;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final item = this.item;
    final past = !item.allDay && nowWall.isAfter(item.end);
    final String top;
    String? bottom;
    if (item.allDay) {
      top = 'весь день';
    } else if (item.firstDay.isBefore(dateOnly(day))) {
      top = 'до ${timeOf(item.end)}';
    } else {
      top = timeOf(item.start);
      if (item.end.isAfter(item.start)) bottom = timeOf(item.end);
    }
    final done = item is TaskItem && item.done;
    final subtitle = switch (item) {
      EventItem(:final location) => location,
      TaskItem() => null,
    };
    return Opacity(
      opacity: past || done ? 0.6 : 1,
      child: InkWell(
        key: Key(
          item is EventItem
              ? 'agenda-event-${item.event.id}-${item.key}-${formatDate(day)}'
              : 'agenda-task-${(item as TaskItem).task.id}-${item.instanceDate}',
        ),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 56,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      top,
                      style: item.allDay || top.startsWith('до')
                          ? t.caption.copyWith(color: c.textSecondary)
                          : t.numM,
                    ),
                    if (bottom != null)
                      Text(
                        bottom,
                        style: t.numS.copyWith(color: c.textTertiary),
                      ),
                  ],
                ),
              ),
              if (item is TaskItem)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.s2),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: TaskCheckbox(
                      checked: item.done,
                      priority: item.task.priority,
                      onChanged: () => onToggleTask(item),
                      size: 16,
                    ),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodyStrong.copyWith(
                              decoration: done
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        if (item is EventItem && item.alternating)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Icon(
                              LucideIcons.repeat2,
                              size: 13,
                              color: c.textSecondary,
                            ),
                          ),
                      ],
                    ),
                    if (subtitle != null && subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodyS.copyWith(color: c.textSecondary),
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

/// Заголовок дня в расписании: «Ср, 30 сент.», праздник и метка недели.
class DayHeaderLabel extends StatelessWidget {
  const DayHeaderLabel({
    required this.day,
    required this.today,
    required this.holidays,
    this.weekLabel,
    this.showHolidays = true,
    super.key,
  });

  final DateTime day;
  final DateTime today;
  final HolidayCalendar holidays;
  final String? weekLabel;
  final bool showHolidays;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final isToday = day == today;
    final name = showHolidays ? holidays.holidayName(day) : null;
    return Container(
      color: c.bgBase,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(
            dayTitleShort(day),
            key: Key('day-header-${formatDate(day)}'),
            style: t.h3.copyWith(
              color: isToday ? c.textPrimary : c.textSecondary,
            ),
          ),
          if (isToday) ...[
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: c.accent, width: 2),
              ),
            ),
          ],
          if (name != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodyS.copyWith(color: c.textTertiary),
              ),
            ),
          ],
          const Spacer(),
          if (weekLabel != null)
            Text(weekLabel!, style: t.caption.copyWith(color: c.textTertiary)),
        ],
      ),
    );
  }
}
