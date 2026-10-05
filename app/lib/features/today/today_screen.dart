import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/format/ru_format.dart' show pluralRu;
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_view.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/presentation/event_details.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:my_tasker/features/sleep/application/sleep_providers.dart';
import 'package:my_tasker/features/sleep/presentation/rituals_block.dart';
import 'package:my_tasker/features/tasks/application/task_providers.dart';
import 'package:my_tasker/features/tasks/domain/task_views.dart';
import 'package:my_tasker/features/tasks/presentation/quick_add_bar.dart';
import 'package:my_tasker/features/tasks/presentation/task_actions.dart';
import 'package:my_tasker/features/tasks/presentation/task_card.dart';
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';
import 'package:my_tasker/features/today/presentation/day_timeline.dart';
import 'package:timezone/timezone.dart' as tz;

/// «Сегодня» — главный экран (02, 3.6, 6.1): шапка с неделей цикла и
/// счётчиками, тревога «Просрочено», карточка «Сейчас / Далее» с синей
/// обводкой, задачи на сегодня (просроченные первыми, до 5, «Все N›»),
/// быстрое добавление и лента дня, блок «Сон и ритуалы» (Этап 8; утром без
/// записи сна — первым после тревог). Блоки других этапов (цифры, учёба,
/// работа) появятся вместе с ними.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(calendarBootstrapProvider);
    final today = ref.watch(todayProvider);
    final nowWall = ref.watch(nowWallProvider);
    final cycle = ref.watch(weekCycleProvider).value;
    final zone = ref.watch(deviceTimeZoneProvider);
    final span = DateSpan(today, addDays(today, 1));
    final items = ref.watch(calendarItemsProvider(span));
    final tasks = ref.watch(taskListDataProvider);
    final permission = ref.watch(reminderPermissionProvider).value;
    final compact = context.windowClass.isCompact;
    final t = context.text;
    final c = context.colors;

    final isLoading = items.isLoading || tasks.isLoading;
    final error = items.hasError
        ? items.error
        : (tasks.hasError ? tasks.error : null);

    // Задачи на сегодня: срок сегодня или раньше, не закрытые.
    final todayEntries = <TaskEntry>[];
    var overdueCount = 0;
    if (tasks.hasValue) {
      final all = tasks.requireValue.entries;
      final open = [
        for (final e in all)
          if (e.task.isOpen &&
              !e.done &&
              e.task.archivedAt == null &&
              e.localDate != null &&
              !e.localDate!.isAfter(today))
            e,
      ];
      overdueCount = open.where((e) => e.overdue).length;
      open.sort((a, b) {
        if (a.overdue != b.overdue) return a.overdue ? -1 : 1;
        return compareEntries(a, b);
      });
      todayEntries.addAll(open);
    }
    final events = items.hasValue
        ? [
            for (final i in items.requireValue)
              if (i is EventItem) i,
          ]
        : <EventItem>[];

    final subtitle = <String>[
      if (cycle != null && cycle.isEnabled)
        '${cycle.labelForDate(today)} неделя',
      if (todayEntries.isNotEmpty)
        '${todayEntries.length} ${pluralRu(todayEntries.length, 'задача', 'задачи', 'задач')}',
      if (events.isNotEmpty)
        '${events.length} ${pluralRu(events.length, 'событие', 'события', 'событий')}',
    ];

    final Widget content;
    if (error != null) {
      content = NoticeCard(
        key: const Key('today-error'),
        label: 'Не загрузилось',
        tone: StatusTone.danger,
        text: 'Не удалось прочитать данные на устройстве.',
        actions: [
          FilledButton(
            key: const Key('today-retry'),
            onPressed: () => ref
              ..invalidate(tasksProvider)
              ..invalidate(eventsProvider),
            child: const Text('Повторить'),
          ),
        ],
      );
    } else if (isLoading) {
      content = const ListSkeleton();
    } else {
      final alerts = <Widget>[
        if (overdueCount > 0)
          _Banner(
            key: const Key('today-overdue-banner'),
            icon: LucideIcons.flag,
            text:
                'Просрочено $overdueCount ${pluralRu(overdueCount, 'задача', 'задачи', 'задач')}',
            onTap: () => context.go('/calendar/tasks'),
          ),
        if (permission == ReminderPermission.notificationsDenied ||
            permission == ReminderPermission.exactAlarmsDenied)
          _Banner(
            key: const Key('today-permission-banner'),
            icon: LucideIcons.bellOff,
            text: permission == ReminderPermission.notificationsDenied
                ? 'Уведомления выключены — напоминания не придут'
                : 'Нет доступа к точным будильникам — напоминания опаздывают',
            actionLabel: 'Разрешить',
            onTap: () async {
              await ref.read(reminderSchedulerProvider).requestPermission();
              ref.invalidate(reminderPermissionProvider);
            },
          ),
      ];
      final next = _nextEvent(events, nowWall);
      final nowNext = next == null
          ? null
          : _NextCard(item: next.$1, current: next.$2, nowWall: nowWall);
      final taskBlock = _TasksBlock(
        entries: todayEntries,
        data: tasks.value!,
        zone: zone,
        today: today,
      );
      final allDay = [
        for (final e in events)
          if (e.allDay) e,
      ];
      final timeline = events.isEmpty
          ? null
          : _Block(
              title: 'ЛЕНТА ДНЯ',
              child: DayTimeline(
                day: today,
                items: items.requireValue,
                nowWall: nowWall,
                onTap: (i) {
                  if (i is EventItem) unawaited(showEventDetails(context, i));
                },
              ),
            );
      final allDayBlock = allDay.isEmpty
          ? null
          : _Block(
              title: 'ВЕСЬ ДЕНЬ',
              child: Column(
                children: [
                  for (final e in allDay)
                    InkWell(
                      key: Key('today-allday-${e.event.id}'),
                      onTap: () => unawaited(showEventDetails(context, e)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Container(
                              width: 3,
                              height: 18,
                              color: c.textSecondary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(e.title, style: t.body)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            );
      // Утром без записи сна блок «Сон» — первым после тревог; иначе — в
      // конце (docs/02, 3.6).
      final sleepData = ref.watch(sleepDataProvider).value;
      final sleepFirst =
          sleepData != null && sleepPromptFirst(sleepData, nowWall);
      final sleepBlock = SleepRitualsBlock(nowWall: nowWall);
      if (compact) {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._spaced(alerts),
            if (sleepFirst) ...[
              sleepBlock,
              const SizedBox(height: AppSpacing.s4),
            ],
            ?nowNext,
            if (nowNext != null) const SizedBox(height: AppSpacing.s4),
            ?allDayBlock,
            if (allDayBlock != null) const SizedBox(height: AppSpacing.s4),
            taskBlock,
            if (timeline != null) ...[
              const SizedBox(height: AppSpacing.s4),
              timeline,
            ],
            if (!sleepFirst) ...[
              const SizedBox(height: AppSpacing.s4),
              sleepBlock,
            ],
          ],
        );
      } else {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._spaced(alerts),
            if (sleepFirst) ...[
              sleepBlock,
              const SizedBox(height: AppSpacing.s4),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ?nowNext,
                      if (nowNext != null)
                        const SizedBox(height: AppSpacing.s4),
                      ?allDayBlock,
                      if (allDayBlock != null)
                        const SizedBox(height: AppSpacing.s4),
                      taskBlock,
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s6),
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      timeline ?? const _EmptyDay(),
                      if (!sleepFirst) ...[
                        const SizedBox(height: AppSpacing.s4),
                        sleepBlock,
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      }
    }

    return ScreenScaffold(
      title: dayTitle(today),
      actions: [
        if (compact)
          IconButton(
            key: const Key('open-sections'),
            tooltip: 'Разделы',
            onPressed: () => context.push('/sections'),
            icon: const Icon(LucideIcons.layoutGrid, size: 24),
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s4),
              child: Text(
                subtitle.join(' · '),
                key: const Key('today-subtitle'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ),
          content,
        ],
      ),
    );
  }

  List<Widget> _spaced(List<Widget> widgets) => [
    for (final w in widgets) ...[w, const SizedBox(height: AppSpacing.s3)],
  ];

  /// Ближайшее событие: идущее сейчас (`current`) или следующее за ним.
  (EventItem, bool)? _nextEvent(List<EventItem> events, DateTime nowWall) {
    EventItem? upcoming;
    for (final e in events) {
      if (e.allDay) continue;
      if (!nowWall.isBefore(e.start) && nowWall.isBefore(e.end)) {
        return (e, true);
      }
      if (e.start.isAfter(nowWall) &&
          (upcoming == null || e.start.isBefore(upcoming.start))) {
        upcoming = e;
      }
    }
    return upcoming == null ? null : (upcoming, false);
  }
}

class _EmptyDay extends StatelessWidget {
  const _EmptyDay();

  @override
  Widget build(BuildContext context) => _Block(
    title: 'ЛЕНТА ДНЯ',
    child: Padding(
      key: const Key('today-no-events'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
      child: Text(
        'На сегодня событий нет.',
        style: context.text.bodyS.copyWith(color: context.colors.textSecondary),
      ),
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.onTap,
    this.actionLabel,
    super.key,
  });

  final IconData icon;
  final String text;
  final VoidCallback onTap;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      borderRadius: AppRadii.borderM,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: AppRadii.borderM,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: c.textPrimary),
            const SizedBox(width: AppSpacing.s3),
            Expanded(child: Text(text, style: context.text.bodyStrong)),
            if (actionLabel != null)
              Text(
                actionLabel!,
                style: context.text.label.copyWith(color: c.accent),
              )
            else
              Icon(LucideIcons.chevronRight, size: 16, color: c.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.s2),
          child: Row(
            children: [
              Text(
                title,
                style: context.text.overline.copyWith(color: c.textTertiary),
              ),
              const Spacer(),
              ?trailing,
            ],
          ),
        ),
        child,
      ],
    );
  }
}

/// Карточка «Сейчас / Далее» с синей обводкой (`emphasis/accent`).
class _NextCard extends StatelessWidget {
  const _NextCard({
    required this.item,
    required this.current,
    required this.nowWall,
  });

  final EventItem item;
  final bool current;
  final DateTime nowWall;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final minutes = item.start.difference(nowWall).inMinutes;
    final label = current
        ? 'СЕЙЧАС'
        : (minutes < 60
              ? 'ДАЛЕЕ · через $minutes мин'
              : 'ДАЛЕЕ · в ${timeOf(item.start)}');
    return InkWell(
      key: const Key('today-next-card'),
      borderRadius: AppRadii.borderL,
      onTap: () => unawaited(showEventDetails(context, item)),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface1,
          borderRadius: AppRadii.borderL,
          border: Border.all(color: c.accent, width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: t.overline.copyWith(color: c.textSecondary)),
            const SizedBox(height: AppSpacing.s1),
            Text(item.title, style: t.h2),
            const SizedBox(height: 2),
            Text(
              '${timeOf(item.start)}–${timeOf(item.end)}'
              '${item.location == null || item.location!.isEmpty ? '' : ' · ${item.location}'}',
              style: t.numM.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Блок «Задачи на сегодня».
class _TasksBlock extends ConsumerWidget {
  const _TasksBlock({
    required this.entries,
    required this.data,
    required this.zone,
    required this.today,
  });

  final List<TaskEntry> entries;
  final TaskListData data;
  final tz.Location zone;
  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final shown = entries.take(5).toList();
    return _Block(
      title: 'ЗАДАЧИ НА СЕГОДНЯ',
      trailing: entries.length > 5
          ? InkWell(
              key: const Key('today-tasks-all'),
              onTap: () => context.go('/calendar/tasks'),
              child: Text(
                'Все ${entries.length} ›',
                style: t.label.copyWith(color: c.accent),
              ),
            )
          : null,
      child: Column(
        key: const Key('today-tasks'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          QuickAddBar(
            onCreated: (r) => ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Задача добавлена'))),
          ),
          const SizedBox(height: AppSpacing.s2),
          if (shown.isEmpty)
            AppCard(
              child: Row(
                key: const Key('today-tasks-empty'),
                children: [
                  Icon(LucideIcons.check, size: 20, color: c.textSecondary),
                  const SizedBox(width: AppSpacing.s3),
                  Text('На сегодня всё', style: t.body),
                ],
              ),
            )
          else
            for (final entry in shown) ...[
              TaskCard(
                entry: entry,
                zone: zone,
                today: today,
                style: TaskCardStyle.card,
                info: TaskCardInfo(
                  projectTitle: data.projects[entry.task.projectId]?.title,
                  subtasks: data.subtaskProgress[entry.task.id],
                ),
                onTap: () =>
                    unawaited(showTaskEditor(context, taskId: entry.task.id)),
                onLongPress: () =>
                    unawaited(showTaskMenu(context, ref, entry.task)),
                onToggle: () => unawaited(toggleTaskDone(context, ref, entry)),
              ),
              const SizedBox(height: AppSpacing.s2),
            ],
        ],
      ),
    );
  }
}
