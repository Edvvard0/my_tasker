import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/calendar_tasks_switcher.dart';
import 'package:my_tasker/features/tasks/application/task_providers.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/domain/task_views.dart';
import 'package:my_tasker/features/tasks/presentation/quick_add_bar.dart';
import 'package:my_tasker/features/tasks/presentation/task_actions.dart';
import 'package:my_tasker/features/tasks/presentation/task_card.dart';
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';
import 'package:timezone/timezone.dart' as tz;

/// Вкладка «Задачи» внутри «Календаря» (02, 6.3): быстрое добавление,
/// фильтры (срок, статус, приоритет, проект, тег), группы «Просрочено /
/// Сегодня / Завтра / На неделе / Позже / Без даты / Выполнено», свайпы
/// (вправо — выполнить, влево — перенести), долгое нажатие — меню.
class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  bool _showDone = false;

  @override
  Widget build(BuildContext context) {
    ref.watch(calendarBootstrapProvider);
    final data = ref.watch(taskListDataProvider);
    final filter = ref.watch(taskFilterProvider);
    final compact = context.windowClass.isCompact;
    final gutter = context.windowClass.gutter;
    return ScreenScaffold(
      title: 'Задачи',
      scrollable: false,
      actions: [
        IconButton(
          key: const Key('tasks-add'),
          tooltip: 'Новая задача',
          onPressed: () => showTaskEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CalendarTasksSwitcher(tasksSelected: true),
              const SizedBox(height: AppSpacing.s3),
              QuickAddBar(
                onCreated: (result) => ScaffoldMessenger.of(context)
                    .showSnackBar(
                      SnackBar(
                        content: Text(
                          result.created.isEmpty
                              ? 'Задача добавлена'
                              : 'Задача добавлена · создано: '
                                    '${result.created.join(', ')}',
                        ),
                      ),
                    ),
              ),
              const SizedBox(height: AppSpacing.s2),
              _FilterBar(filter: filter),
              const SizedBox(height: AppSpacing.s2),
              Expanded(
                child: data.when(
                  loading: () =>
                      const SingleChildScrollView(child: ListSkeleton(rows: 4)),
                  error: (error, _) => NoticeCard(
                    key: const Key('tasks-error'),
                    label: 'Не загрузилось',
                    tone: StatusTone.danger,
                    text: 'Не удалось прочитать задачи на устройстве.',
                    actions: [
                      FilledButton(
                        key: const Key('tasks-retry'),
                        onPressed: () => ref
                          ..invalidate(tasksProvider)
                          ..invalidate(taskCompletionsProvider),
                        child: const Text('Повторить'),
                      ),
                    ],
                  ),
                  data: (d) => _TaskList(
                    data: d,
                    filter: filter,
                    showDone: _showDone,
                    onToggleDone: () => setState(() => _showDone = !_showDone),
                    bottom:
                        MediaQuery.paddingOf(context).bottom +
                        (compact ? AppSpacing.s6 : gutter),
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

class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.filter});

  final TaskFilter filter;

  int get _extra =>
      filter.statuses.length +
      filter.priorities.length +
      (filter.projectId != null ? 1 : 0) +
      (filter.tagId != null ? 1 : 0) +
      (filter.showCancelled ? 1 : 0) +
      (filter.showArchived ? 1 : 0);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(taskFilterProvider.notifier);
    return ChipRow(
      children: [
        for (final r in TaskRange.values)
          FilterPill(
            key: Key('tasks-range-${r.name}'),
            label: r.label,
            selected: filter.range == r,
            onTap: () => notifier.setRange(r),
          ),
        FilterPill(
          key: const Key('tasks-filters'),
          label: _extra == 0 ? 'Фильтры' : 'Фильтры · $_extra',
          selected: _extra > 0,
          icon: LucideIcons.listFilter,
          onTap: () => showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            builder: (_) => const TaskFiltersSheet(),
          ),
        ),
        if (filter.isActive)
          TextButton(
            key: const Key('tasks-reset'),
            onPressed: notifier.reset,
            child: const Text('Сбросить'),
          ),
      ],
    );
  }
}

/// Лист фильтров: статусы, приоритеты, проект, тег, отменённые и архив.
class TaskFiltersSheet extends ConsumerWidget {
  const TaskFiltersSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(taskFilterProvider);
    final notifier = ref.read(taskFilterProvider.notifier);
    final projects = ref.watch(projectsProvider).value ?? const [];
    final tags = ref.watch(tagsProvider).value ?? const [];
    final t = context.text;
    Widget block(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s2),
            child: Text(
              label,
              style: t.bodyS.copyWith(color: context.colors.textSecondary),
            ),
          ),
          child,
        ],
      ),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.s6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Фильтры', style: t.h2),
            const SizedBox(height: AppSpacing.s4),
            block(
              'Поиск',
              FormTextField(
                key: const Key('filter-query'),
                controller: TextEditingController(text: filter.query),
                onChanged: notifier.setQuery,
                decoration: const InputDecoration(hintText: 'Часть названия'),
              ),
            ),
            block(
              'Статус',
              Wrap(
                spacing: AppSpacing.s2,
                runSpacing: AppSpacing.s2,
                children: [
                  for (final s in TaskStatus.values)
                    FilterPill(
                      key: Key('filter-status-${s.wire}'),
                      label: s.label,
                      selected: filter.statuses.contains(s),
                      check: true,
                      onTap: () => notifier.toggleStatus(s),
                    ),
                ],
              ),
            ),
            block(
              'Приоритет',
              Wrap(
                spacing: AppSpacing.s2,
                runSpacing: AppSpacing.s2,
                children: [
                  for (var p = 1; p <= 5; p++)
                    FilterPill(
                      key: Key('filter-priority-$p'),
                      label: 'P$p',
                      selected: filter.priorities.contains(p),
                      check: true,
                      onTap: () => notifier.togglePriority(p),
                    ),
                  FilterPill(
                    key: const Key('filter-priority-0'),
                    label: 'Без приоритета',
                    selected: filter.priorities.contains(0),
                    check: true,
                    onTap: () => notifier.togglePriority(0),
                  ),
                ],
              ),
            ),
            if (projects.isNotEmpty)
              block(
                'Проект',
                Wrap(
                  spacing: AppSpacing.s2,
                  runSpacing: AppSpacing.s2,
                  children: [
                    for (final p in projects)
                      FilterPill(
                        key: Key('filter-project-${p.id}'),
                        label: p.title,
                        selected: filter.projectId == p.id,
                        icon: LucideIcons.folder,
                        onTap: () => notifier.setProject(
                          filter.projectId == p.id ? null : p.id,
                        ),
                      ),
                  ],
                ),
              ),
            if (tags.isNotEmpty)
              block(
                'Тег',
                Wrap(
                  spacing: AppSpacing.s2,
                  runSpacing: AppSpacing.s2,
                  children: [
                    for (final tag in tags)
                      FilterPill(
                        key: Key('filter-tag-${tag.id}'),
                        label: '#${tag.name}',
                        selected: filter.tagId == tag.id,
                        icon: LucideIcons.tag,
                        onTap: () => notifier.setTag(
                          filter.tagId == tag.id ? null : tag.id,
                        ),
                      ),
                  ],
                ),
              ),
            block(
              'Показывать',
              Wrap(
                spacing: AppSpacing.s2,
                runSpacing: AppSpacing.s2,
                children: [
                  FilterPill(
                    key: const Key('filter-cancelled'),
                    label: 'Отменённые',
                    selected: filter.showCancelled,
                    check: true,
                    onTap: () =>
                        notifier.setShowCancelled(value: !filter.showCancelled),
                  ),
                  FilterPill(
                    key: const Key('filter-archived'),
                    label: 'Архив',
                    selected: filter.showArchived,
                    check: true,
                    onTap: () =>
                        notifier.setShowArchived(value: !filter.showArchived),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                TextButton(
                  key: const Key('filters-reset'),
                  onPressed: notifier.reset,
                  child: const Text('Сбросить'),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('filters-done'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Готово'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Поле поиска по названию: свой контроллер, чтобы курсор не прыгал при
/// перестроении листа.
class _QueryField extends StatefulWidget {
  const _QueryField({required this.initial, required this.onChanged});

  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<_QueryField> createState() => _QueryFieldState();
}

class _QueryFieldState extends State<_QueryField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FormTextField(
    key: const Key('filter-query'),
    controller: _controller,
    onChanged: widget.onChanged,
    decoration: const InputDecoration(hintText: 'Часть названия'),
  );
}

class _TaskList extends ConsumerWidget {
  const _TaskList({
    required this.data,
    required this.filter,
    required this.showDone,
    required this.onToggleDone,
    required this.bottom,
  });

  final TaskListData data;
  final TaskFilter filter;
  final bool showDone;
  final VoidCallback onToggleDone;
  final double bottom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(todayProvider);
    final zone = ref.watch(deviceTimeZoneProvider);
    final filtered = applyTaskFilter(
      data.entries,
      filter,
      today: today,
      taskTags: data.tagLinks,
    );
    if (data.entries.isEmpty) {
      return EmptyState(
        key: const Key('tasks-empty'),
        icon: LucideIcons.circleCheck,
        title: 'Задач пока нет',
        message:
            'Добавьте первую: «Позвонить завтра 15:00 !2 #работа». '
            'Дата, время, приоритет и проект распознаются сами.',
        action: FilledButton(
          onPressed: () => showTaskEditor(context),
          child: const Text('Новая задача'),
        ),
      );
    }
    final groups = groupTaskEntries(filtered, today: today);
    if (groups.isEmpty) {
      return EmptyState(
        key: const Key('tasks-filter-empty'),
        icon: LucideIcons.listFilter,
        title: 'Ничего не найдено',
        message: 'Под выбранные фильтры не подходит ни одна задача.',
        action: ElevatedButton(
          onPressed: ref.read(taskFilterProvider.notifier).reset,
          child: const Text('Сбросить фильтры'),
        ),
      );
    }
    final t = context.text;
    final c = context.colors;
    final children = <Widget>[];
    for (final group in groups) {
      final collapsed = group.kind == TaskGroupKind.done && !showDone;
      children.add(
        InkWell(
          key: Key('group-${group.kind.name}'),
          onTap: group.kind == TaskGroupKind.done ? onToggleDone : null,
          child: Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.s4,
              bottom: AppSpacing.s1,
            ),
            child: Row(
              children: [
                if (group.kind == TaskGroupKind.done)
                  Icon(
                    collapsed
                        ? LucideIcons.chevronRight
                        : LucideIcons.chevronDown,
                    size: 14,
                    color: c.textTertiary,
                  ),
                Text(
                  '${group.title} · ${group.entries.length}',
                  style: t.overline.copyWith(color: c.textTertiary),
                ),
              ],
            ),
          ),
        ),
      );
      if (collapsed) continue;
      for (final entry in group.entries) {
        children.add(
          _TaskRow(
            entry: entry,
            data: data,
            zone: zone,
            today: today,
            showDate:
                group.kind == TaskGroupKind.week ||
                group.kind == TaskGroupKind.later,
          ),
        );
      }
    }
    return ListView(
      key: const Key('tasks-list'),
      padding: EdgeInsets.only(bottom: bottom),
      children: children,
    );
  }
}

class _TaskRow extends ConsumerWidget {
  const _TaskRow({
    required this.entry,
    required this.data,
    required this.zone,
    required this.today,
    required this.showDate,
  });

  final TaskEntry entry;
  final TaskListData data;
  final tz.Location zone;
  final DateTime today;
  final bool showDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = entry.task;
    final c = context.colors;
    final tags = [
      for (final id in data.tagLinks[task.id] ?? const <String>{})
        ?data.tags.where((t) => t.id == id).firstOrNull?.name,
    ];
    final card = TaskCard(
      entry: entry,
      zone: zone,
      today: today,
      showDate: showDate,
      info: TaskCardInfo(
        projectTitle: data.projects[task.projectId]?.title,
        subtasks: data.subtaskProgress[task.id],
        tags: tags,
      ),
      onTap: () => showTaskEditor(context, taskId: task.id),
      onLongPress: () => showTaskMenu(context, ref, task),
      onToggle: () => toggleTaskDone(context, ref, entry),
    );
    if (!context.windowClass.isCompact) return card;
    Widget bg(IconData icon, Alignment alignment) => Container(
      color: c.surface3,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
      child: Icon(icon, size: 22, color: c.textSecondary),
    );
    return Dismissible(
      key: ValueKey('dismiss-${task.id}-${entry.instanceDate}'),
      background: bg(LucideIcons.check, Alignment.centerLeft),
      secondaryBackground: bg(
        LucideIcons.calendarArrowUp,
        Alignment.centerRight,
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await toggleTaskDone(context, ref, entry);
        } else {
          await rescheduleTask(context, ref, task);
        }
        return false;
      },
      child: card,
    );
  }
}
