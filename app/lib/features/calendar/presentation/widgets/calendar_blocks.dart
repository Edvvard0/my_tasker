import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/tasks/presentation/task_card.dart';

/// Диагональная штриховка 45° для слоя «Учёба» (02, 5.1.1): слои
/// различаются рисунком, не цветом.
class HatchPainter extends CustomPainter {
  const HatchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const step = 8.0;
    for (var x = -size.height; x < size.width; x += step) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(HatchPainter oldDelegate) => oldDelegate.color != color;
}

/// Блок события в сетке (02, 5.1.1): личное — сплошная заливка, работа —
/// контурный блок, учёба — заливка со штриховкой; слева полоса 3 px;
/// прошедшее — 60 %; чередующееся — значок `repeat-2`; короткое (< 30 мин)
/// — одна строка «15:00 Созвон». В узкой колонке — только название мелким
/// шрифтом.
class EventBlock extends StatelessWidget {
  const EventBlock({
    required this.item,
    required this.onTap,
    this.past = false,
    this.ghost = false,
    this.highlight = false,
    super.key,
  });

  final EventItem item;
  final VoidCallback? onTap;
  final bool past;

  /// «Призрак» на старом месте при перетаскивании (60 %).
  final bool ghost;

  /// Подсвечен во время перетаскивания.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final work = item.layerKind == 'work';
    final study = item.layerKind == 'study';
    final minutes = item.end.difference(item.start).inMinutes;
    final short = !item.allDay && minutes < 30;
    final opacity = ghost ? 0.4 : (past ? 0.6 : 1.0);
    final timeText = item.allDay
        ? null
        : '${timeOf(item.start)}–${timeOf(item.end)}';
    return Opacity(
      opacity: opacity,
      child: Semantics(
        button: true,
        label:
            '${item.title}${timeText == null ? '' : ', $timeText'}'
            '${item.location == null ? '' : ', ${item.location}'}',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadii.borderXs,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 72;
              return Container(
                key: Key('event-block-${item.event.id}-${item.key}'),
                decoration: BoxDecoration(
                  color: work ? Colors.transparent : c.surface3,
                  borderRadius: AppRadii.borderXs,
                  border: Border.all(
                    color: highlight
                        ? c.textPrimary
                        : (work ? c.borderStrong : Colors.transparent),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: AppRadii.borderXs,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (study)
                        CustomPaint(
                          painter: HatchPainter(
                            c.textSecondary.withValues(alpha: 0.18),
                          ),
                        ),
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: 3,
                        child: ColoredBox(color: c.textSecondary),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          narrow ? 6 : 9,
                          3,
                          narrow ? 2 : 4,
                          2,
                        ),
                        child: narrow
                            ? Text(
                                item.title,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: t.caption.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 10.5,
                                  height: 1.1,
                                ),
                              )
                            : short
                            ? Text(
                                '${timeOf(item.start)} ${item.title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodyS.copyWith(
                                  fontWeight: FontWeight.w600,
                                  height: 1.1,
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: t.bodyS.copyWith(
                                      fontWeight: FontWeight.w600,
                                      height: 1.15,
                                    ),
                                  ),
                                  if (timeText != null)
                                    Flexible(
                                      child: Text(
                                        item.location == null
                                            ? timeText
                                            : '$timeText · ${item.location}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: t.numS.copyWith(
                                          color: c.textSecondary,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      if (item.alternating && !narrow)
                        Positioned(
                          right: 3,
                          top: 3,
                          child: Icon(
                            LucideIcons.repeat2,
                            size: 11,
                            color: c.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Блок задачи со временем в сетке: прозрачный, обводка 1 px, слева мини-
/// чекбокс; выполненная — зачёркнута, 50 % (02, 5.1.1). В узкой колонке
/// (неделя на телефоне) вместо чекбокса — маленькое кольцо.
class TaskBlock extends StatelessWidget {
  const TaskBlock({
    required this.item,
    required this.onTap,
    required this.onToggle,
    this.ghost = false,
    super.key,
  });

  final TaskItem item;
  final VoidCallback? onTap;
  final VoidCallback? onToggle;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final done = item.done;
    return Opacity(
      opacity: ghost ? 0.4 : (done ? 0.5 : 1),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadii.borderXs,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 72;
            final style = (narrow ? t.caption : t.bodyS).copyWith(
              height: 1.15,
              fontSize: narrow ? 10.5 : null,
              decoration: done ? TextDecoration.lineThrough : null,
            );
            return Container(
              key: Key('task-block-${item.task.id}-${item.instanceDate}'),
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                borderRadius: AppRadii.borderXs,
                border: Border.all(color: c.borderStrong),
              ),
              padding: EdgeInsets.fromLTRB(
                narrow ? 3 : 2,
                narrow ? 2 : 0,
                3,
                0,
              ),
              child: narrow
                  ? Text(
                      item.title,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TaskCheckbox(
                          checked: done,
                          priority: item.task.priority,
                          onChanged: onToggle,
                          size: 12,
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: style,
                            ),
                          ),
                        ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}

/// Плашка «весь день» (событие) в полосе или в ячейке месяца: одна строка
/// 20–24 px с полосой слева.
class AllDayChip extends StatelessWidget {
  const AllDayChip({
    required this.title,
    required this.onTap,
    this.height = 22,
    this.outlined = false,
    this.dense = false,
    super.key,
  });

  /// Узкая колонка: мелкий текст и тонкая полоса.
  final bool dense;

  final String title;
  final VoidCallback? onTap;
  final double height;

  /// Слой «Работа»: контур без заливки.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.borderXs,
      child: Container(
        height: height,
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: outlined ? Colors.transparent : c.surface3,
          borderRadius: AppRadii.borderXs,
          border: outlined ? Border.all(color: c.borderStrong) : null,
        ),
        child: Row(
          children: [
            Container(width: dense ? 2 : 3, color: c.textSecondary),
            SizedBox(width: dense ? 3 : 5),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.caption.copyWith(
                  color: c.textPrimary,
                  fontWeight: FontWeight.w500,
                  fontSize: dense ? 10 : null,
                  height: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Раскладка пересекающихся блоков по колонкам (максимум [maxLanes] рядом).
/// Для каждого элемента возвращает номер колонки и число колонок кластера.
List<({int lane, int lanes})> layoutLanes(
  List<({int start, int end})> spans, {
  int maxLanes = 3,
}) {
  final order = List<int>.generate(spans.length, (i) => i)
    ..sort((a, b) {
      final c = spans[a].start.compareTo(spans[b].start);
      return c != 0 ? c : spans[b].end.compareTo(spans[a].end);
    });
  final result = List<({int lane, int lanes})>.filled(spans.length, (
    lane: 0,
    lanes: 1,
  ));
  var cluster = <int>[];
  var clusterEnd = -1;
  final laneEnds = <int>[];
  void flush() {
    final lanes = math.min(maxLanes, math.max(1, laneEnds.length));
    for (final i in cluster) {
      result[i] = (lane: result[i].lane, lanes: lanes);
    }
    cluster = [];
    laneEnds.clear();
  }

  for (final i in order) {
    final s = spans[i];
    if (cluster.isNotEmpty && s.start >= clusterEnd) flush();
    var lane = laneEnds.indexWhere((end) => end <= s.start);
    if (lane == -1) {
      laneEnds.add(s.end);
      lane = laneEnds.length - 1;
    } else {
      laneEnds[lane] = s.end;
    }
    result[i] = (lane: math.min(lane, maxLanes - 1), lanes: 1);
    cluster.add(i);
    clusterEnd = math.max(clusterEnd, s.end);
  }
  if (cluster.isNotEmpty) flush();
  return result;
}
