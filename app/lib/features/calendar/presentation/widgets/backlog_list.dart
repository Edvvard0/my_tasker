import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/tasks/application/task_providers.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/domain/task_views.dart';
import 'package:my_tasker/features/tasks/presentation/task_card.dart';
import 'package:timezone/timezone.dart' as tz;

/// Бэклог «Без даты» (02, 5.1.3): задачи без срока по проектам. На десктопе
/// строки перетаскиваются в сетку (назначают дату и время, 1 час по
/// умолчанию) или в полосу «весь день» (только дату).
class BacklogList extends StatelessWidget {
  const BacklogList({
    required this.data,
    required this.today,
    required this.zone,
    required this.onTap,
    required this.onToggle,
    this.draggable = false,
    super.key,
  });

  final TaskListData data;
  final DateTime today;
  final tz.Location zone;
  final bool draggable;
  final ValueChanged<TaskEntry> onTap;
  final ValueChanged<TaskEntry> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final backlog = data.backlog;
    if (backlog.isEmpty) {
      return Padding(
        key: const Key('backlog-empty'),
        padding: const EdgeInsets.all(AppSpacing.s4),
        child: Text(
          'Все задачи разложены по дням.',
          style: t.bodyS.copyWith(color: c.textSecondary),
        ),
      );
    }
    final groups = <String?, List<TaskEntry>>{};
    for (final e in backlog) {
      groups.putIfAbsent(e.task.projectId, () => []).add(e);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a == null) return 1;
        if (b == null) return -1;
        return (data.projects[a]?.title ?? '').compareTo(
          data.projects[b]?.title ?? '',
        );
      });
    return ListView(
      key: const Key('backlog-list'),
      padding: EdgeInsets.zero,
      children: [
        for (final key in keys) ...[
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s3, bottom: 2),
            child: Text(
              (key == null
                      ? 'БЕЗ ПРОЕКТА'
                      : (data.projects[key]?.title ?? 'БЕЗ ПРОЕКТА'))
                  .toUpperCase(),
              style: t.overline.copyWith(color: c.textTertiary),
            ),
          ),
          for (final entry in groups[key]!) _row(context, entry),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, TaskEntry entry) {
    final card = TaskCard(
      entry: entry,
      zone: zone,
      today: today,
      info: TaskCardInfo(subtasks: data.subtaskProgress[entry.task.id]),
      onTap: () => onTap(entry),
      onToggle: () => onToggle(entry),
    );
    if (!draggable) return card;
    return Draggable<TaskEntity>(
      key: Key('backlog-drag-${entry.task.id}'),
      data: entry.task,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Transform.rotate(
          angle: 0.035,
          child: Container(
            width: 220,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s3,
              vertical: AppSpacing.s2,
            ),
            decoration: BoxDecoration(
              color: context.colors.surface2,
              borderRadius: AppRadii.borderS,
              border: Border.all(color: context.colors.borderStrong),
            ),
            child: Row(
              children: [
                const Icon(LucideIcons.gripVertical, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodyS,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: card,
    );
  }
}
