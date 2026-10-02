import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';

/// Компактная лента дня 08:00–23:00 для «Сегодня» (02, 3.6, блок 5):
/// блоки событий и линия «сейчас», без сетки.
class DayTimeline extends StatelessWidget {
  const DayTimeline({
    required this.day,
    required this.items,
    required this.nowWall,
    required this.onTap,
    super.key,
  });

  final DateTime day;
  final List<CalendarItem> items;
  final DateTime nowWall;
  final ValueChanged<CalendarItem> onTap;

  static const int fromHour = 8;
  static const int toHour = 23;
  static const double hourHeight = 40;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    const height = (toHour - fromHour) * hourHeight;
    final timed = [
      for (final i in items)
        if (i is EventItem && !i.allDay && i.coversDay(day)) i,
    ];
    double y(int minutes) =>
        ((minutes - fromHour * 60) / 60 * hourHeight).clamp(0, height);
    final nowMinutes = nowWall.hour * 60 + nowWall.minute;
    final showNow = nowMinutes >= fromHour * 60 && nowMinutes <= toHour * 60;
    return SizedBox(
      key: const Key('day-timeline'),
      height: height,
      child: Stack(
        children: [
          for (var h = fromHour; h <= toHour; h++)
            Positioned(
              left: 0,
              right: 0,
              top: (h - fromHour) * hourHeight,
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      clockText(h, 0),
                      style: t.caption.copyWith(color: c.textTertiary),
                    ),
                  ),
                  Expanded(child: Container(height: 1, color: c.borderSubtle)),
                ],
              ),
            ),
          for (final item in timed)
            Positioned(
              left: 48,
              right: 4,
              top: y(item.startMinuteOn(day)),
              height: math.max(
                22,
                y(item.endMinuteOn(day)) - y(item.startMinuteOn(day)) - 2,
              ),
              child: InkWell(
                key: Key('timeline-${item.event.id}'),
                onTap: () => onTap(item),
                borderRadius: AppRadii.borderXs,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: c.surface3,
                    borderRadius: AppRadii.borderXs,
                    border: Border(
                      left: BorderSide(color: c.textSecondary, width: 3),
                    ),
                  ),
                  child: Text(
                    '${timeOf(item.start)} ${item.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyS.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          if (showNow)
            Positioned(
              key: const Key('timeline-now'),
              left: 40,
              right: 0,
              top: y(nowMinutes) - 1,
              child: IgnorePointer(
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: c.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(child: Container(height: 2, color: c.accent)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
