import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/calendar_blocks.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

/// Минимальная ширина колонки блока при раскладке пересечений: сколько
/// блоков помещается рядом — `floor(ширина колонки дня / minLaneWidth)`.
const double minLaneWidth = 56;

/// Сетка времени для видов «День», «3 дня» и «Неделя» (02, 5.1.1):
/// заголовки дней, полоса «весь день», часовая шкала, блоки событий и
/// задач, линия «сейчас». На десктопе блоки перетаскиваются (сдвиг на
/// 15 минут / на день), растягиваются за нижний край, а задачи из
/// бэклога можно бросить на сетку.
class TimeGridView extends ConsumerStatefulWidget {
  const TimeGridView({
    required this.days,
    required this.items,
    required this.today,
    required this.nowWall,
    required this.holidays,
    required this.onEventTap,
    required this.onTaskTap,
    required this.onTaskToggle,
    required this.onCreateAt,
    this.showHolidays = true,
    this.desktop = false,
    this.onMove,
    this.onResize,
    this.onDropTask,
    this.onDayTap,
    super.key,
  });

  final List<DateTime> days;
  final List<CalendarItem> items;
  final DateTime today;

  /// Текущее «настенное» время в поясе устройства.
  final DateTime nowWall;
  final HolidayCalendar holidays;
  final bool showHolidays;
  final bool desktop;
  final ValueChanged<EventItem> onEventTap;
  final ValueChanged<TaskItem> onTaskTap;
  final ValueChanged<TaskItem> onTaskToggle;

  /// Тап по пустому месту: день и минуты от полуночи (шаг 30).
  final void Function(DateTime day, int minutes) onCreateAt;

  /// Перетащили блок: сдвиг в днях и минутах.
  final void Function(CalendarItem item, int days, int minutes)? onMove;

  /// Растянули нижний край: новая длительность в минутах.
  final void Function(CalendarItem item, int minutes)? onResize;

  /// Задачу из бэклога бросили в сетку (минуты `null` — в полосу «весь день»).
  final void Function(TaskEntity task, DateTime day, int? minutes)? onDropTask;
  final ValueChanged<DateTime>? onDayTap;

  @override
  ConsumerState<TimeGridView> createState() => _TimeGridViewState();
}

class _Drag {
  _Drag(this.item, {required this.resize});

  final CalendarItem item;
  final bool resize;
  Offset delta = Offset.zero;
}

class _TimeGridViewState extends ConsumerState<TimeGridView> {
  late final ScrollController _scroll;
  final GlobalKey _bodyKey = GlobalKey();
  final GlobalKey _stripKey = GlobalKey();
  bool _allDayExpanded = false;
  _Drag? _drag;

  double get _hour => widget.desktop ? 56.0 : 52.0;
  // Телефон: в недельной сетке колонки узкие, шкале времени — меньше места.
  double get _gutter =>
      widget.desktop ? 56.0 : (widget.days.length >= 5 ? 40.0 : 48.0);

  @override
  void initState() {
    super.initState();
    final showsToday = widget.days.any((d) => d == widget.today);
    final startHour = showsToday ? math.max(0, widget.nowWall.hour - 2) : 7;
    _scroll = ScrollController(initialScrollOffset: startHour * _hour);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<CalendarItem> _timed(DateTime day) => [
    for (final i in widget.items)
      if (!i.allDay && i.coversDay(day)) i,
  ];

  List<CalendarItem> _allDay(DateTime day) => [
    for (final i in widget.items)
      if (i.allDay && i.coversDay(day)) i,
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final colWidth =
            (constraints.maxWidth - _gutter) / math.max(1, widget.days.length);
        return Column(
          children: [
            _header(context, colWidth),
            _allDayStrip(context, colWidth),
            Divider(height: 1, color: context.colors.borderSubtle),
            Expanded(child: _body(context, colWidth)),
          ],
        );
      },
    );
  }

  // ---- заголовок --------------------------------------------------------------

  Widget _header(BuildContext context, double colWidth) {
    final c = context.colors;
    final t = context.text;
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          SizedBox(width: _gutter),
          for (final day in widget.days)
            SizedBox(
              width: colWidth,
              child: InkWell(
                key: Key('grid-day-${formatDate(day)}'),
                onTap: widget.onDayTap == null
                    ? null
                    : () => widget.onDayTap!(day),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      weekdayShortNames[weekdayIndex(day)].toUpperCase(),
                      style: t.overline.copyWith(color: c.textTertiary),
                    ),
                    const SizedBox(height: 2),
                    _DayNumber(
                      day: day,
                      today: widget.today,
                      dayOff:
                          widget.showHolidays &&
                          widget.holidays.dayInfo(day).isDayOff,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- «весь день» ----------------------------------------------------------------

  Widget _allDayStrip(BuildContext context, double colWidth) {
    final c = context.colors;
    final t = context.text;
    final narrow = colWidth < 80;
    final columns = <Widget>[];
    var maxRows = 0;
    for (final day in widget.days) {
      final entries = <Widget>[];
      final holiday = widget.showHolidays
          ? widget.holidays.holidayName(day)
          : null;
      if (holiday != null) {
        entries.add(
          AllDayChip(
            key: Key('holiday-${formatDate(day)}'),
            title: holiday,
            onTap: null,
            outlined: true,
            dense: narrow,
          ),
        );
      }
      for (final item in _allDay(day)) {
        if (item is EventItem) {
          entries.add(
            AllDayChip(
              key: Key(
                'allday-${item.event.id}-${item.key}-${formatDate(day)}',
              ),
              title: item.title,
              outlined: item.layerKind == 'work',
              dense: narrow,
              onTap: () => widget.onEventTap(item),
            ),
          );
        } else if (item is TaskItem) {
          entries.add(
            SizedBox(
              height: 24,
              child: TaskCardCompactRow(
                dense: narrow,
                item: item,
                onTap: () => widget.onTaskTap(item),
                onToggle: () => widget.onTaskToggle(item),
              ),
            ),
          );
        }
      }
      final limit = _allDayExpanded ? entries.length : 3;
      final shown = entries.take(limit).toList();
      if (entries.length > limit) {
        shown.add(
          InkWell(
            key: Key('allday-more-${formatDate(day)}'),
            onTap: () => setState(() => _allDayExpanded = true),
            child: SizedBox(
              height: 20,
              child: Text(
                '+${entries.length - limit}',
                style: t.caption.copyWith(color: c.textSecondary),
              ),
            ),
          ),
        );
      }
      maxRows = math.max(maxRows, shown.length);
      columns.add(
        SizedBox(
          width: colWidth,
          child: DragTarget<TaskEntity>(
            onWillAcceptWithDetails: (_) => widget.onDropTask != null,
            onAcceptWithDetails: (details) =>
                widget.onDropTask?.call(details.data, day, null),
            builder: (context, candidates, _) => Container(
              key: Key('allday-cell-${formatDate(day)}'),
              padding: const EdgeInsets.symmetric(horizontal: 1),
              color: candidates.isEmpty ? null : c.surface3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: shown,
              ),
            ),
          ),
        ),
      );
    }
    if (maxRows == 0) {
      return const SizedBox(key: Key('allday-empty'), height: 4);
    }
    return Container(
      key: _stripKey,
      constraints: const BoxConstraints(maxHeight: 200),
      padding: const EdgeInsets.only(bottom: 4),
      child: SingleChildScrollView(
        // Ячейки тянутся на всю высоту полосы: в пустой день тоже можно
        // бросить задачу.
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _gutter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, right: 6),
                  child: Text(
                    'ВЕСЬ ДЕНЬ',
                    textAlign: TextAlign.right,
                    style: t.caption.copyWith(
                      color: c.textTertiary,
                      fontSize: 9,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
              ...columns,
            ],
          ),
        ),
      ),
    );
  }

  // ---- часовая сетка ------------------------------------------------------------------

  Widget _body(BuildContext context, double colWidth) {
    final c = context.colors;
    final t = context.text;
    final height = 24 * _hour;
    final dragging = _drag;
    return DragTarget<TaskEntity>(
      onWillAcceptWithDetails: (_) => widget.onDropTask != null,
      onAcceptWithDetails: (details) => _drop(details, colWidth),
      builder: (context, candidates, _) => SingleChildScrollView(
        key: const Key('grid-scroll'),
        controller: _scroll,
        child: SizedBox(
          key: _bodyKey,
          height: height,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (details) => _tapEmpty(details.localPosition, colWidth),
            child: Stack(
              children: [
                // Часы: фон рабочего времени и линии.
                for (var h = 0; h < 24; h++)
                  Positioned(
                    left: _gutter,
                    right: 0,
                    top: h * _hour,
                    height: _hour,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: h >= 8 && h < 22
                            ? const Color(0xFF0A0A0A)
                            : c.bgBase,
                        border: Border(top: BorderSide(color: c.borderSubtle)),
                      ),
                    ),
                  ),
                for (var h = 1; h < 24; h++)
                  Positioned(
                    left: 0,
                    width: _gutter - 4,
                    top: h * _hour - 8,
                    child: Text(
                      clockText(h, 0),
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.right,
                      style: t.caption.copyWith(color: c.textTertiary),
                    ),
                  ),
                // Вертикальные линии колонок.
                for (var i = 0; i < widget.days.length; i++)
                  Positioned(
                    left: _gutter + i * colWidth,
                    top: 0,
                    bottom: 0,
                    width: 1,
                    child: ColoredBox(color: c.borderSubtle),
                  ),
                for (var i = 0; i < widget.days.length; i++)
                  ..._columnBlocks(context, i, colWidth),
                if (dragging != null && !dragging.resize)
                  ..._dragOverlay(context, dragging, colWidth),
                ..._nowLine(context, colWidth),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _tapEmpty(Offset local, double colWidth) {
    if (local.dx < _gutter) return;
    final col = ((local.dx - _gutter) / colWidth).floor().clamp(
      0,
      widget.days.length - 1,
    );
    final minutes = (local.dy / _hour * 60 / 30).floor() * 30;
    widget.onCreateAt(widget.days[col], minutes.clamp(0, 23 * 60 + 30));
  }

  void _drop(DragTargetDetails<TaskEntity> details, double colWidth) {
    final box = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(details.offset);
    if (local.dx < _gutter) return;
    final col = ((local.dx - _gutter) / colWidth).floor().clamp(
      0,
      widget.days.length - 1,
    );
    final minutes = ((local.dy / _hour * 60) / 15).round() * 15;
    widget.onDropTask?.call(
      details.data,
      widget.days[col],
      minutes.clamp(0, 23 * 60 + 45),
    );
  }

  List<Widget> _columnBlocks(BuildContext context, int col, double colWidth) {
    final day = widget.days[col];
    final items = _timed(day);
    final spans = [
      for (final i in items)
        (
          start: i.startMinuteOn(day),
          end: math.max(i.endMinuteOn(day), i.startMinuteOn(day) + 20),
        ),
    ];
    // Не больше одной колонки на каждые 56 px; остальное — плашка «+N».
    final layout = layoutLanes(
      spans,
      maxLanes: math.max(1, (colWidth / minLaneWidth).floor()),
    );
    final widgets = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final lane = layout.placements[i];
      if (lane.hidden) continue;
      final top = spans[i].start / 60 * _hour;
      final minutes = math.max(20, spans[i].end - spans[i].start);
      final blockHeight = math.max(16, minutes / 60 * _hour - 1);
      final width = (colWidth - 3) / lane.lanes;
      final left = _gutter + col * colWidth + 1 + lane.lane * width;
      final dragging = _drag != null && identical(_drag!.item, item);
      final isPast = widget.nowWall.isAfter(item.end);
      final Widget block;
      if (item is EventItem) {
        block = EventBlock(
          item: item,
          past: isPast,
          onTap: () => widget.onEventTap(item),
        );
      } else {
        final task = item as TaskItem;
        block = TaskBlock(
          item: task,
          onTap: () => widget.onTaskTap(task),
          onToggle: () => widget.onTaskToggle(task),
        );
      }
      final movable = widget.desktop && widget.onMove != null;
      var dh = blockHeight.toDouble();
      if (dragging && _drag!.resize) {
        final extra = _snapMinutes(_drag!.delta.dy);
        dh = math.max(16, blockHeight + extra / 60 * _hour);
      }
      widgets.add(
        Positioned(
          key: Key('grid-item-${_itemId(item)}-${formatDate(day)}'),
          left: left,
          top: top,
          width: width - 1,
          height: dh,
          child: movable
              ? _MoveHandle(
                  onStart: () =>
                      setState(() => _drag = _Drag(item, resize: false)),
                  onUpdate: (d) => setState(() => _drag?.delta += d),
                  onEnd: () => _finishMove(colWidth),
                  onCancel: () => setState(() => _drag = null),
                  onResizeStart: () =>
                      setState(() => _drag = _Drag(item, resize: true)),
                  onResizeUpdate: (d) => setState(() => _drag?.delta += d),
                  onResizeEnd: () => _finishResize(item),
                  child: Opacity(
                    opacity: dragging && !_drag!.resize ? 0.4 : 1,
                    child: block,
                  ),
                )
              : block,
        ),
      );
    }
    for (final o in layout.overflows) {
      widgets.add(_overflowChip(context, day, col, colWidth, o, spans, layout));
    }
    return widgets;
  }

  /// Плашка «+N» в нижнем правом углу блока-якоря: тап открывает день
  /// целиком (там колонка шире и помещается больше блоков).
  Widget _overflowChip(
    BuildContext context,
    DateTime day,
    int col,
    double colWidth,
    LaneOverflow o,
    List<({int start, int end})> spans,
    LaneLayout layout,
  ) {
    final c = context.colors;
    final lane = layout.placements[o.anchor];
    final laneWidth = (colWidth - 3) / lane.lanes;
    final blockLeft = _gutter + col * colWidth + 1 + lane.lane * laneWidth;
    final blockTop = spans[o.anchor].start / 60 * _hour;
    final minutes = math.max(20, spans[o.anchor].end - spans[o.anchor].start);
    final blockBottom = blockTop + math.max(16, minutes / 60 * _hour - 1);
    final width = 12.0 + 6.5 * '${o.count}'.length + 6;
    return Positioned(
      key: Key('grid-more-${formatDate(day)}-${o.startMinute}'),
      left: blockLeft + laneWidth - 1 - width - 1,
      top: math.max(blockTop + 14, blockBottom - 19),
      width: width,
      height: 17,
      child: Semantics(
        button: true,
        label: 'Ещё ${o.count} событий',
        excludeSemantics: true,
        child: InkWell(
          onTap: widget.onDayTap == null ? null : () => widget.onDayTap!(day),
          borderRadius: AppRadii.borderXs,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: AppRadii.borderXs,
              border: Border.all(color: c.borderStrong),
            ),
            child: Text(
              '+${o.count}',
              maxLines: 1,
              softWrap: false,
              style: context.text.caption.copyWith(
                color: c.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 10.5,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _itemId(CalendarItem item) => switch (item) {
    EventItem() => '${item.event.id}-${item.key}',
    TaskItem() => '${item.task.id}-${item.instanceDate}',
  };

  int _snapMinutes(double dy) => (dy / _hour * 60 / 15).round() * 15;

  void _finishMove(double colWidth) {
    final drag = _drag;
    if (drag == null) return;
    final minutes = _snapMinutes(drag.delta.dy);
    final days = (drag.delta.dx / colWidth).round();
    setState(() => _drag = null);
    if (minutes != 0 || days != 0) {
      widget.onMove?.call(drag.item, days, minutes);
    }
  }

  void _finishResize(CalendarItem item) {
    final drag = _drag;
    if (drag == null) return;
    final extra = _snapMinutes(drag.delta.dy);
    setState(() => _drag = null);
    final current = item.end.difference(item.start).inMinutes;
    final next = math.max(15, current + extra);
    if (next != current) widget.onResize?.call(item, next);
  }

  List<Widget> _dragOverlay(BuildContext context, _Drag drag, double colWidth) {
    final item = drag.item;
    final startCol = widget.days.indexWhere((d) => d == dateOnly(item.start));
    if (startCol < 0 || item.allDay) return const [];
    final minutes = _snapMinutes(drag.delta.dy);
    final days = (drag.delta.dx / colWidth).round();
    final top = (item.startMinuteOn(item.firstDay) + minutes) / 60 * _hour;
    final col = (startCol + days).clamp(0, widget.days.length - 1);
    final duration = math.max(
      15,
      item.endMinuteOn(item.firstDay) - item.startMinuteOn(item.firstDay),
    );
    final label = timeOf(
      DateTime.utc(2000).add(
        Duration(minutes: (item.startMinuteOn(item.firstDay) + minutes) % 1440),
      ),
    );
    return [
      Positioned(
        key: const Key('drag-overlay'),
        left: _gutter + col * colWidth + 1,
        top: top,
        width: colWidth - 4,
        height: math.max(16, duration / 60 * _hour - 1),
        child: IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: item is EventItem
                    ? EventBlock(item: item, onTap: null, highlight: true)
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: AppRadii.borderXs,
                          border: Border.all(color: context.colors.textPrimary),
                        ),
                      ),
              ),
              Positioned(
                top: -18,
                left: 0,
                child: Container(
                  key: const Key('drag-label'),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: context.colors.surfaceInverse,
                    borderRadius: AppRadii.borderFull,
                  ),
                  child: Text(
                    label,
                    style: context.text.numS.copyWith(
                      color: context.colors.textOnInverse,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _nowLine(BuildContext context, double colWidth) {
    final c = context.colors;
    final idx = widget.days.indexWhere((d) => d == widget.today);
    final minutes = widget.nowWall.hour * 60 + widget.nowWall.minute;
    final y = minutes / 60 * _hour;
    return [
      for (var i = 0; i < widget.days.length; i++)
        if (widget.days[i] == widget.today)
          Positioned(
            key: const Key('now-line'),
            left: _gutter + i * colWidth,
            top: y - 1,
            width: colWidth,
            height: 2,
            child: IgnorePointer(child: ColoredBox(color: c.accent)),
          )
        else if (idx >= 0 || widget.days.contains(widget.today))
          Positioned(
            left: _gutter + i * colWidth,
            top: y,
            width: colWidth,
            height: 1,
            child: IgnorePointer(
              child: ColoredBox(color: c.accent.withValues(alpha: 0.25)),
            ),
          ),
      if (idx >= 0)
        Positioned(
          left: _gutter + idx * colWidth - 4,
          top: y - 4,
          child: IgnorePointer(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
    ];
  }
}

/// Число дня в заголовке: сегодня — в круге с синей обводкой 2 px;
/// выходные и праздники — `text/secondary`.
class _DayNumber extends StatelessWidget {
  const _DayNumber({
    required this.day,
    required this.today,
    required this.dayOff,
  });

  final DateTime day;
  final DateTime today;
  final bool dayOff;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isToday = day == today;
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: isToday
          ? BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.accent, width: 2),
            )
          : null,
      child: Text(
        '${day.day}',
        key: Key('day-number-${formatDate(day)}'),
        style: context.text.h3.copyWith(
          color: dayOff && !isToday ? c.textSecondary : c.textPrimary,
        ),
      ),
    );
  }
}

/// Число дня для сетки/месяца, доступное другим видам.
class DayNumberBadge extends StatelessWidget {
  const DayNumberBadge({
    required this.day,
    required this.today,
    required this.dayOff,
    this.size = 28,
    super.key,
  });

  final DateTime day;
  final DateTime today;
  final bool dayOff;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isToday = day == today;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: isToday
          ? BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.accent, width: 2),
            )
          : null,
      child: Text(
        '${day.day}',
        style: context.text.label.copyWith(
          color: dayOff && !isToday ? c.textSecondary : c.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Обёртка блока: перетаскивание (сдвиг) и растяжение за нижний край (6 px).
class _MoveHandle extends StatelessWidget {
  const _MoveHandle({
    required this.child,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
  });

  final Widget child;
  final VoidCallback onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;
  final VoidCallback onCancel;
  final VoidCallback onResizeStart;
  final ValueChanged<Offset> onResizeUpdate;
  final VoidCallback onResizeEnd;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const Key('grid-move-handle'),
            onPanStart: (_) => onStart(),
            onPanUpdate: (d) => onUpdate(d.delta),
            onPanEnd: (_) => onEnd(),
            onPanCancel: onCancel,
            child: child,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 8,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpDown,
            child: GestureDetector(
              key: const Key('grid-resize-handle'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => onResizeStart(),
              onPanUpdate: (d) => onResizeUpdate(d.delta),
              onPanEnd: (_) => onResizeEnd(),
              onPanCancel: onCancel,
            ),
          ),
        ),
      ],
    );
  }
}

/// Одна строка задачи «весь день» в полосе: чекбокс и название.
class TaskCardCompactRow extends StatelessWidget {
  const TaskCardCompactRow({
    required this.item,
    required this.onTap,
    required this.onToggle,
    this.dense = false,
    super.key,
  });

  /// Узкая колонка: без чекбокса, мелкий текст.
  final bool dense;

  final TaskItem item;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (dense) {
      return InkWell(
        key: Key('task-chip-${item.task.id}-${item.instanceDate}'),
        onTap: onTap,
        borderRadius: AppRadii.borderXs,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 3),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            borderRadius: AppRadii.borderXs,
            border: Border.all(color: c.borderStrong),
          ),
          child: WordEllipsisText(
            item.title,
            style: context.text.caption.copyWith(
              fontSize: 10,
              height: 1.2,
              color: item.done ? c.textTertiary : c.textPrimary,
              decoration: item.done ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      );
    }
    return InkWell(
      key: Key('task-chip-${item.task.id}-${item.instanceDate}'),
      onTap: onTap,
      borderRadius: AppRadii.borderXs,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: InkResponse(
              onTap: onToggle,
              radius: 14,
              child: Center(
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: item.done ? c.surfaceInverse : Colors.transparent,
                    border: item.done
                        ? null
                        : Border.all(
                            color: item.task.priority == 1
                                ? c.textPrimary
                                : c.textTertiary,
                            width: item.task.priority == 1 ? 2.5 : 1.5,
                          ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: WordEllipsisText(
              item.title,
              style: context.text.caption.copyWith(
                color: item.done ? c.textTertiary : c.textPrimary,
                decoration: item.done ? TextDecoration.lineThrough : null,
                height: 1,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s05),
        ],
      ),
    );
  }
}
