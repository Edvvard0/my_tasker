import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_view.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/calendar_tasks_switcher.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/presentation/calendar_actions.dart';
import 'package:my_tasker/features/calendar/presentation/event_details.dart';
import 'package:my_tasker/features/calendar/presentation/event_editor.dart';
import 'package:my_tasker/features/calendar/presentation/layers_screen.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/backlog_list.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/day_agenda.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/month_view.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/schedule_view.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/time_grid.dart';
import 'package:my_tasker/features/tasks/application/task_providers.dart';
import 'package:my_tasker/features/tasks/presentation/task_actions.dart';
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';

export 'package:my_tasker/features/tasks/presentation/tasks_screen.dart'
    show TasksScreen;

/// «Календарь» (02, 5.1, 6.2): расписание, день, 3 дня, неделя и месяц;
/// на телефоне по умолчанию «Расписание», на десктопе — «Неделя» с
/// бэклогом «Без даты» справа. Слои, «Сегодня», бейдж недели цикла.
class CalendarScreen extends ConsumerWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(calendarBootstrapProvider);
    final compact = context.windowClass.isCompact;
    final view = ref.watch(calendarViewProvider);
    final mode =
        view.mode ??
        (compact ? CalendarViewMode.schedule : CalendarViewMode.week);
    return ScreenScaffold(
      title: 'Календарь',
      scrollable: false,
      actions: [
        IconButton(
          key: const Key('calendar-layers'),
          tooltip: 'Слои',
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            builder: (_) => const LayersSheet(),
          ),
          icon: const Icon(LucideIcons.layers, size: 22),
        ),
        IconButton(
          key: const Key('calendar-settings'),
          tooltip: 'Настройки календаря',
          onPressed: () => context.go('/calendar/settings'),
          icon: const Icon(LucideIcons.settings2, size: 22),
        ),
      ],
      child: _CalendarBody(mode: mode, focus: view.focus),
    );
  }
}

class _CalendarBody extends ConsumerStatefulWidget {
  const _CalendarBody({required this.mode, required this.focus});

  final CalendarViewMode mode;
  final DateTime focus;

  @override
  ConsumerState<_CalendarBody> createState() => _CalendarBodyState();
}

class _CalendarBodyState extends ConsumerState<_CalendarBody> {
  DateTime? _selectedDay;

  /// Бэклог «Без даты» свёрнут в узкую полосу: выбор пользователя; пока его
  /// нет — свёрнут в окнах уже 1000 px (сетке нужно место).
  bool? _backlogCollapsedByUser;

  @override
  Widget build(BuildContext context) {
    final compact = context.windowClass.isCompact;
    final mode = widget.mode;
    final focus = widget.focus;
    final span = spanOf(mode, focus);
    final items = ref.watch(calendarItemsProvider(span));
    final today = ref.watch(todayProvider);
    final nowWall = ref.watch(nowWallProvider);
    final holidays = ref.watch(holidaysProvider);
    final cycle = ref.watch(weekCycleProvider).value;
    final data = ref.watch(calendarDataProvider).value;
    final showHolidays = data?.holidaysVisible ?? true;
    final notifier = ref.read(calendarViewProvider.notifier);
    final actions = CalendarActions(context, ref);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final desktop = !compact;

    var body = items.when<Widget>(
      loading: () => const SingleChildScrollView(child: ListSkeleton(rows: 4)),
      error: (error, _) => NoticeCard(
        key: const Key('calendar-error'),
        label: 'Не загрузилось',
        tone: StatusTone.danger,
        text: 'Не удалось прочитать календарь на устройстве.',
        actions: [
          FilledButton(
            key: const Key('calendar-retry'),
            onPressed: () => ref
              ..invalidate(eventsProvider)
              ..invalidate(tasksProvider),
            child: const Text('Повторить'),
          ),
        ],
      ),
      data: (list) => _view(
        context,
        list,
        span: span,
        today: today,
        nowWall: nowWall,
        holidays: holidays,
        cycle: cycle,
        showHolidays: showHolidays,
        actions: actions,
        bottom: bottom,
      ),
    );

    if (compact && mode != CalendarViewMode.schedule) {
      body = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v < -300) notifier.step(1, mode);
          if (v > 300) notifier.step(-1, mode);
        },
        child: body,
      );
    }

    final showBacklog = desktop && mode != CalendarViewMode.month;
    final width = MediaQuery.sizeOf(context).width;
    final backlogCollapsed = _backlogCollapsedByUser ?? width < 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compact) ...[
          const CalendarTasksSwitcher(tasksSelected: false),
          const SizedBox(height: AppSpacing.s2),
        ],
        _Toolbar(mode: mode, focus: focus, cycle: cycle, today: today),
        const SizedBox(height: AppSpacing.s2),
        Expanded(
          child: showBacklog
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: body),
                    const SizedBox(width: AppSpacing.s4),
                    if (backlogCollapsed)
                      _BacklogRail(
                        onExpand: () =>
                            setState(() => _backlogCollapsedByUser = false),
                      )
                    else
                      SizedBox(
                        // На окне ≤ 1440 px сетке нужно место: панель уже.
                        width: width <= 1440 ? 240 : 300,
                        child: _BacklogPanel(
                          actions: actions,
                          today: today,
                          onCollapse: () =>
                              setState(() => _backlogCollapsedByUser = true),
                        ),
                      ),
                  ],
                )
              : body,
        ),
        if (compact && mode.isGrid)
          Padding(
            padding: EdgeInsets.only(bottom: bottom),
            child: _BacklogPeek(today: today),
          ),
      ],
    );
  }

  Widget _view(
    BuildContext context,
    List<CalendarItem> list, {
    required DateSpan span,
    required DateTime today,
    required DateTime nowWall,
    required HolidayCalendar holidays,
    required WeekCycle? cycle,
    required bool showHolidays,
    required CalendarActions actions,
    required double bottom,
  }) {
    final mode = widget.mode;
    final focus = widget.focus;
    final compact = context.windowClass.isCompact;
    void openItem(CalendarItem item) {
      switch (item) {
        case EventItem():
          unawaited(showEventDetails(context, item));
        case TaskItem():
          unawaited(showTaskEditor(context, taskId: item.task.id));
      }
    }

    switch (mode) {
      case CalendarViewMode.schedule:
        return ScheduleView(
          from: span.from,
          to: span.to,
          items: list,
          today: today,
          nowWall: nowWall,
          holidays: holidays,
          cycle: cycle,
          showHolidays: showHolidays,
          bottomPadding: bottom + AppSpacing.s6,
          onItemTap: openItem,
          onToggleTask: (t) => unawaited(toggleTaskItem(context, ref, t)),
        );
      case CalendarViewMode.day:
      case CalendarViewMode.threeDays:
      case CalendarViewMode.week:
        final days = [
          for (var i = 0; i < (span.to.difference(span.from).inDays); i++)
            addDays(span.from, i),
        ];
        return TimeGridView(
          key: ValueKey('${mode.name}-${formatDate(span.from)}'),
          days: days,
          items: list,
          today: today,
          nowWall: nowWall,
          holidays: holidays,
          showHolidays: showHolidays,
          desktop: !compact,
          onEventTap: (e) => unawaited(showEventDetails(context, e)),
          onTaskTap: (t) =>
              unawaited(showTaskEditor(context, taskId: t.task.id)),
          onTaskToggle: (t) => unawaited(toggleTaskItem(context, ref, t)),
          onCreateAt: (day, minutes) => unawaited(
            showEventEditor(
              context,
              initialDate: day,
              initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
            ),
          ),
          onMove: compact
              ? null
              : (i, d, m) => unawaited(actions.move(i, d, m)),
          onResize: compact ? null : (i, m) => unawaited(actions.resize(i, m)),
          onDropTask: compact
              ? null
              : (t, d, m) => unawaited(actions.dropTask(t, d, m)),
          onDayTap: (d) {
            final n = ref.read(calendarViewProvider.notifier)..goTo(d);
            unawaited(n.setMode(CalendarViewMode.day));
          },
        );
      case CalendarViewMode.month:
        final month = DateTime.utc(focus.year, focus.month);
        final monthView = MonthView(
          month: month,
          items: list,
          today: today,
          holidays: holidays,
          cycle: cycle,
          showHolidays: showHolidays,
          desktop: !compact,
          selected: compact ? (_selectedDay ?? today) : null,
          onDayTap: (d) {
            if (compact) {
              setState(() => _selectedDay = d);
            } else {
              final n = ref.read(calendarViewProvider.notifier)..goTo(d);
              unawaited(n.setMode(CalendarViewMode.day));
            }
          },
        );
        if (!compact) return monthView;
        final day = _selectedDay ?? today;
        final dayItems = itemsOn(list, day);
        return Column(
          children: [
            Expanded(flex: 5, child: monthView),
            Divider(height: 1, color: context.colors.borderSubtle),
            Expanded(
              flex: 4,
              child: ListView(
                key: const Key('month-day-list'),
                padding: EdgeInsets.only(bottom: bottom + AppSpacing.s6),
                children: [
                  DayHeaderLabel(
                    day: day,
                    today: today,
                    holidays: holidays,
                    showHolidays: showHolidays,
                  ),
                  if (dayItems.isEmpty)
                    Text(
                      'В этот день ничего не запланировано',
                      key: const Key('month-day-empty'),
                      style: context.text.bodyS.copyWith(
                        color: context.colors.textTertiary,
                      ),
                    )
                  else
                    for (final item in dayItems)
                      AgendaRow(
                        item: item,
                        day: day,
                        nowWall: nowWall,
                        onTap: () => openItem(item),
                        onToggleTask: (t) =>
                            unawaited(toggleTaskItem(context, ref, t)),
                      ),
                ],
              ),
            ),
          ],
        );
    }
  }
}

/// Верхняя панель календаря: шаги назад/вперёд, период, бейдж недели цикла
/// («Нечётная»), «Сегодня» и выбор вида.
class _Toolbar extends ConsumerWidget {
  const _Toolbar({
    required this.mode,
    required this.focus,
    required this.cycle,
    required this.today,
  });

  final CalendarViewMode mode;
  final DateTime focus;
  final WeekCycle? cycle;
  final DateTime today;

  String _title() {
    switch (mode) {
      case CalendarViewMode.month:
        return monthYear(focus);
      case CalendarViewMode.week:
        final monday = mondayOf(focus);
        return '${weekRange(monday)} ${addDays(monday, 6).year}';
      case CalendarViewMode.threeDays:
        final last = addDays(focus, 2);
        return '${focus.day}${focus.month == last.month ? '' : ' ${monthShortNames[focus.month - 1]}'}'
            '–${last.day} ${monthShortNames[last.month - 1]}';
      case CalendarViewMode.day:
        return dayTitle(focus);
      case CalendarViewMode.schedule:
        return monthTitle(focus, today);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final compact = context.windowClass.isCompact;
    final notifier = ref.read(calendarViewProvider.notifier);
    final range = spanOf(mode, focus);
    final away = switch (mode) {
      CalendarViewMode.month =>
        focus.year != today.year || focus.month != today.month,
      CalendarViewMode.schedule => focus != today,
      _ => today.isBefore(range.from) || !today.isBefore(range.to),
    };
    final cycle = this.cycle;
    final showBadge =
        cycle != null && cycle.isEnabled && mode != CalendarViewMode.month;
    return Row(
      children: [
        if (!compact)
          IconButton(
            key: const Key('calendar-prev'),
            tooltip: 'Назад',
            visualDensity: VisualDensity.compact,
            onPressed: () => notifier.step(-1, mode),
            icon: const Icon(LucideIcons.chevronLeft, size: 22),
          ),
        if (!compact)
          IconButton(
            key: const Key('calendar-next'),
            tooltip: 'Вперёд',
            visualDensity: VisualDensity.compact,
            onPressed: () => notifier.step(1, mode),
            icon: const Icon(LucideIcons.chevronRight, size: 22),
          ),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  _title(),
                  key: const Key('calendar-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: compact ? t.h3 : t.h2,
                ),
              ),
              if (showBadge) ...[
                const SizedBox(width: AppSpacing.s2),
                Container(
                  key: const Key('week-badge'),
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.surface3,
                    borderRadius: AppRadii.borderFull,
                  ),
                  child: Text(
                    cycle.labelForDate(focus),
                    style: t.label.copyWith(color: c.textSecondary),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (away || !compact)
          TextButton(
            key: const Key('calendar-today'),
            onPressed: notifier.goToday,
            child: const Text('Сегодня'),
          ),
        if (compact) _ViewMenu(mode: mode) else _ViewSegments(mode: mode),
      ],
    );
  }
}

class _ViewMenu extends ConsumerWidget {
  const _ViewMenu({required this.mode});

  final CalendarViewMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return PopupMenuButton<CalendarViewMode>(
      key: const Key('calendar-view-menu'),
      tooltip: 'Вид календаря',
      color: c.surface2,
      onSelected: (m) => ref.read(calendarViewProvider.notifier).setMode(m),
      itemBuilder: (context) => [
        for (final m in CalendarViewMode.values)
          PopupMenuItem(
            key: Key('view-${m.name}'),
            value: m,
            child: Row(
              children: [
                Expanded(child: Text(m.label)),
                if (m == mode) const Icon(LucideIcons.check, size: 16),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(mode.label, style: context.text.label),
            const SizedBox(width: 2),
            const Icon(LucideIcons.chevronDown, size: 16),
          ],
        ),
      ),
    );
  }
}

class _ViewSegments extends ConsumerWidget {
  const _ViewSegments({required this.mode});

  final CalendarViewMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s1),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: AppRadii.borderFull,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in const [
            CalendarViewMode.day,
            CalendarViewMode.threeDays,
            CalendarViewMode.week,
            CalendarViewMode.month,
            CalendarViewMode.schedule,
          ])
            InkWell(
              key: Key('view-${m.name}'),
              borderRadius: AppRadii.borderFull,
              onTap: () => ref.read(calendarViewProvider.notifier).setMode(m),
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: m == mode ? c.surface1 : Colors.transparent,
                  borderRadius: AppRadii.borderFull,
                ),
                child: Text(
                  m == CalendarViewMode.schedule ? 'Расп.' : m.label,
                  style: context.text.label.copyWith(
                    color: m == mode ? c.textPrimary : c.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Бэклог «Без даты» справа на десктопе: перетаскивание задач в сетку.
class _BacklogPanel extends ConsumerWidget {
  const _BacklogPanel({
    required this.actions,
    required this.today,
    required this.onCollapse,
  });

  final CalendarActions actions;
  final DateTime today;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final data = ref.watch(taskListDataProvider);
    final zone = ref.watch(deviceTimeZoneProvider);
    return Container(
      key: const Key('backlog-panel'),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: AppRadii.borderL,
      ),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  data.value == null
                      ? 'Без даты'
                      : 'Без даты · ${data.value!.backlog.length}',
                  key: const Key('backlog-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.h3,
                ),
              ),
              IconButton(
                key: const Key('backlog-add'),
                tooltip: 'Новая задача',
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(showTaskEditor(context)),
                icon: const Icon(LucideIcons.plus, size: 18),
              ),
              IconButton(
                key: const Key('backlog-collapse'),
                tooltip: 'Свернуть',
                visualDensity: VisualDensity.compact,
                onPressed: onCollapse,
                icon: const Icon(LucideIcons.panelRightClose, size: 18),
              ),
            ],
          ),
          Expanded(
            child: data.when(
              loading: () => const SizedBox.shrink(),
              error: (e, _) => Text(
                'Не удалось прочитать задачи',
                style: context.text.bodyS.copyWith(color: c.danger),
              ),
              data: (d) => BacklogList(
                data: d,
                today: today,
                zone: zone,
                draggable: true,
                onTap: (e) =>
                    unawaited(showTaskEditor(context, taskId: e.task.id)),
                onToggle: (e) => unawaited(toggleTaskDone(context, ref, e)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Свёрнутый бэклог: узкая полоса с числом задач и кнопкой «развернуть».
class _BacklogRail extends ConsumerWidget {
  const _BacklogRail({required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final count = ref.watch(taskListDataProvider).value?.backlog.length ?? 0;
    return Container(
      key: const Key('backlog-rail'),
      width: 44,
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: AppRadii.borderL,
      ),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
      child: Column(
        children: [
          IconButton(
            key: const Key('backlog-expand'),
            tooltip: 'Без даты · $count',
            onPressed: onExpand,
            icon: const Icon(LucideIcons.panelRightOpen, size: 18),
          ),
          Text(
            '$count',
            key: const Key('backlog-rail-count'),
            style: context.text.label.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// «Пик» бэклога на телефоне (02, 5.1.3): полоса «Без даты · 7», тап
/// раскрывает список.
class _BacklogPeek extends ConsumerWidget {
  const _BacklogPeek({required this.today});

  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final data = ref.watch(taskListDataProvider).value;
    final count = data?.backlog.length ?? 0;
    return InkWell(
      key: const Key('backlog-peek'),
      borderRadius: AppRadii.borderL,
      onTap: () => showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        builder: (_) => const _BacklogSheet(),
      ),
      child: Container(
        height: 48,
        margin: const EdgeInsets.only(top: AppSpacing.s2),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: AppRadii.borderL,
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: c.borderStrong,
                borderRadius: AppRadii.borderFull,
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            Text('Без даты · $count', style: context.text.label),
            const Spacer(),
            Icon(LucideIcons.chevronUp, size: 18, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _BacklogSheet extends ConsumerWidget {
  const _BacklogSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(taskListDataProvider);
    final today = ref.watch(todayProvider);
    final zone = ref.watch(deviceTimeZoneProvider);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                data.value == null
                    ? 'Без даты'
                    : 'Без даты · ${data.value!.backlog.length}',
                style: context.text.h2,
              ),
              const SizedBox(height: AppSpacing.s2),
              Expanded(
                child: data.when(
                  loading: () => const SizedBox.shrink(),
                  error: (e, _) => const Text('Не удалось прочитать задачи'),
                  data: (d) => BacklogList(
                    data: d,
                    today: today,
                    zone: zone,
                    onTap: (e) {
                      Navigator.of(context).pop();
                      unawaited(showTaskEditor(context, taskId: e.task.id));
                    },
                    onToggle: (e) => unawaited(toggleTaskDone(context, ref, e)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Фильтр-чип для внешних экранов календаря (вид по умолчанию).
Widget viewChip(CalendarViewMode mode, {required bool selected}) =>
    FilterPill(label: mode.label, selected: selected, onTap: null);
