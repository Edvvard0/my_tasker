import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/domain/task_views.dart';
import 'package:timezone/timezone.dart' as tz;

/// Чекбокс задачи (02, 4.2): кольцо 20 px; приоритет — толщиной и
/// заливкой, не цветом. P1 — 3 px `text/primary`, P2 — 2 px
/// `text/primary`, P3 — 2 px `text/secondary`, P4/P5 и без приоритета —
/// 1,5 px `text/tertiary`. Выполнена — белая заливка и чёрная галочка.
/// Зона нажатия 48 dp.
class TaskCheckbox extends StatelessWidget {
  const TaskCheckbox({
    required this.checked,
    required this.onChanged,
    this.priority,
    this.size = 20,
    super.key,
  });

  final bool checked;
  final int? priority;
  final VoidCallback? onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (width, color) = switch (priority) {
      1 => (3.0, c.textPrimary),
      2 => (2.0, c.textPrimary),
      3 => (2.0, c.textSecondary),
      _ => (1.5, c.textTertiary),
    };
    return Semantics(
      button: true,
      checked: checked,
      label: checked ? 'Выполнена' : 'Отметить выполненной',
      excludeSemantics: true,
      child: InkResponse(
        onTap: onChanged,
        radius: 24,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: checked ? c.surfaceInverse : Colors.transparent,
                border: checked ? null : Border.all(color: color, width: width),
              ),
              child: checked
                  ? Icon(LucideIcons.check, size: 14, color: c.textOnInverse)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Вид карточки задачи (02, 4.2).
enum TaskCardStyle {
  /// Строка в списке: без фона, разделитель снизу.
  list,

  /// Карточка на «Сегодня»: `surface/1`, радиус `m`.
  card,

  /// Полоса «весь день» в календаре: одна строка 24 px.
  compact,
}

/// Дополнительные сведения для карточки задачи.
class TaskCardInfo {
  const TaskCardInfo({this.projectTitle, this.subtasks, this.tags = const []});

  final String? projectTitle;

  /// (сделано, всего) пунктов чек-листа.
  final (int, int)? subtasks;
  final List<String> tags;
}

/// Карточка задачи: чекбокс, название (до 2 строк), время справа и вторая
/// строка метаданных — проект, повтор, чек-лист, срок.
class TaskCard extends StatelessWidget {
  const TaskCard({
    required this.entry,
    required this.zone,
    required this.today,
    required this.onTap,
    required this.onToggle,
    this.info = const TaskCardInfo(),
    this.style = TaskCardStyle.list,
    this.showDate = false,
    this.onLongPress,
    super.key,
  });

  final TaskEntry entry;
  final tz.Location zone;
  final DateTime today;
  final TaskCardInfo info;
  final TaskCardStyle style;

  /// Показывать дату срока в метаданных (в списках не по дням).
  final bool showDate;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final task = entry.task;
    final done = entry.done || task.status == TaskStatus.done;
    final cancelled = task.status == TaskStatus.cancelled;
    final time = entry.localTime(zone);
    final meta = _meta(context, done);
    final titleStyle = t.body.copyWith(
      color: done || cancelled ? c.textTertiary : c.textPrimary,
      decoration: done || cancelled ? TextDecoration.lineThrough : null,
    );

    if (style == TaskCardStyle.compact) {
      return InkWell(
        key: Key('task-${task.id}'),
        onTap: onTap,
        borderRadius: AppRadii.borderXs,
        child: SizedBox(
          height: 24,
          child: Row(
            children: [
              TaskCheckbox(
                checked: done,
                priority: task.priority,
                onChanged: onToggle,
                size: 14,
              ),
              Expanded(
                child: Text(
                  task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyS.copyWith(
                    color: done ? c.textTertiary : c.textPrimary,
                    decoration: done ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TaskCheckbox(
          key: Key('task-check-${task.id}'),
          checked: done,
          priority: task.priority,
          onChanged: onToggle,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Wrap(
                      spacing: AppSpacing.s2,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: meta,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (time != null)
          Padding(
            padding: const EdgeInsets.only(
              top: 10,
              left: AppSpacing.s2,
              right: AppSpacing.s1,
            ),
            child: Text(
              timeOf(time),
              key: Key('task-time-${task.id}'),
              style: t.numM.copyWith(color: c.textPrimary),
            ),
          ),
      ],
    );

    final tile = InkWell(
      key: Key('task-${task.id}'),
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: style == TaskCardStyle.card ? AppRadii.borderM : null,
      child: style == TaskCardStyle.card
          ? Padding(
              padding: const EdgeInsets.only(right: AppSpacing.s2),
              child: content,
            )
          : content,
    );
    if (style == TaskCardStyle.card) {
      return Container(
        decoration: BoxDecoration(
          color: c.surface1,
          borderRadius: AppRadii.borderM,
        ),
        child: tile,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: tile,
    );
  }

  List<Widget> _meta(BuildContext context, bool done) {
    final c = context.colors;
    final widgets = <Widget>[];
    final task = entry.task;
    if (info.projectTitle != null) {
      widgets.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: c.textTertiary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              info.projectTitle!,
              style: context.text.bodyS.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      );
    }
    if (task.isRecurring) {
      widgets.add(const MetaInline(icon: LucideIcons.repeat));
    }
    final subtasks = info.subtasks;
    if (subtasks != null && subtasks.$2 > 0) {
      widgets.add(
        MetaInline(
          icon: LucideIcons.listChecks,
          text: '${subtasks.$1}/${subtasks.$2}',
        ),
      );
    }
    if (info.tags.isNotEmpty) {
      widgets.add(MetaInline(text: info.tags.map((t) => '#$t').join(' ')));
    }
    final date = entry.localDate;
    if (entry.overdue && date != null) {
      widgets.add(
        MetaInline(
          icon: LucideIcons.flag,
          text: relativeDay(date, today),
          strong: true,
        ),
      );
    } else {
      if (task.priority == 1 && !done) {
        widgets.add(const MetaInline(icon: LucideIcons.flag));
      }
      if (showDate && date != null && !done) {
        widgets.add(MetaInline(text: dayMonth(date, now: today)));
      }
    }
    return widgets;
  }
}

/// Дата без даты формата `civil` для подписи (вспомогательно для тестов).
String taskDueLabel(TaskEntry entry, DateTime today) {
  final date = entry.localDate;
  if (date == null) return 'Без даты';
  return daysBetween(today, date) == 0 ? 'Сегодня' : dayMonth(date, now: today);
}
