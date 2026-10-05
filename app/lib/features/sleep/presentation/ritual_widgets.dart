import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart'
    show tasksProvider;
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/tasks/application/task_providers.dart';
import 'package:my_tasker/features/tasks/domain/task_views.dart';
import 'package:timezone/timezone.dart' as tz;

/// Подпись под названием задачи в ритуалах: «просрочено», время срока или
/// «без времени», приоритет.
String taskCaption(TaskEntry entry, tz.Location zone) {
  final parts = <String>[
    if (entry.overdue)
      'просрочено'
    else if (entry.due.at != null)
      timeOf(entry.localTime(zone)!)
    else if (entry.localDate != null)
      'весь день'
    else
      'без срока',
    if (entry.task.priority != null) 'P${entry.task.priority}',
    if (entry.task.isRecurring) 'повторяется',
  ];
  return parts.join(' · ');
}

/// Содержимое экранов ритуалов: пока задачи читаются — скелетон, при
/// ошибке — карточка «Не загрузилось», иначе [builder].
class RitualTasksBody extends ConsumerWidget {
  const RitualTasksBody({required this.builder, super.key});

  final Widget Function(
    BuildContext context,
    TaskListData tasks,
    tz.Location zone,
  )
  builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(taskListDataProvider);
    final zone = ref.watch(deviceTimeZoneProvider);
    return tasks.when(
      loading: () => const ListSkeleton(rows: 4),
      error: (error, _) => NoticeCard(
        key: const Key('ritual-error'),
        label: 'Не загрузилось',
        tone: StatusTone.danger,
        text: 'Не удалось прочитать задачи на устройстве.',
        actions: [
          FilledButton(
            key: const Key('ritual-retry'),
            onPressed: () => ref.invalidate(tasksProvider),
            child: const Text('Повторить'),
          ),
        ],
      ),
      data: (data) => builder(context, data, zone),
    );
  }
}

/// Подзаголовок блока ритуала: `overline` слева, справа — необязательный
/// текст (счётчик).
class RitualHeader extends StatelessWidget {
  const RitualHeader({required this.title, this.trailing, super.key});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: t.overline.copyWith(color: c.textSecondary),
            ),
          ),
          if (trailing != null)
            Text(trailing!, style: t.caption.copyWith(color: c.textSecondary)),
        ],
      ),
    );
  }
}

/// Строка «время · название · пояснение» для пар и событий.
class RitualInfoRow extends StatelessWidget {
  const RitualInfoRow({
    required this.time,
    required this.title,
    this.caption,
    super.key,
  });

  final String time;
  final String title;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(time, style: t.numS.copyWith(color: c.textSecondary)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.body),
                if (caption != null && caption!.isNotEmpty)
                  Text(
                    caption!,
                    style: t.caption.copyWith(color: c.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Круглая метка оценки дня и самочувствия: 1…5 в ряд, выбранная — белая
/// заливка (как чипы).
class RatingRow extends StatelessWidget {
  const RatingRow({
    required this.value,
    required this.onChanged,
    required this.keyPrefix,
    super.key,
  });

  final int? value;
  final ValueChanged<int?> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Row(
      children: [
        for (var n = 1; n <= 5; n++) ...[
          if (n > 1) const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Semantics(
              button: true,
              selected: value == n,
              label: 'Оценка $n из 5',
              excludeSemantics: true,
              child: InkWell(
                key: Key('$keyPrefix-$n'),
                borderRadius: AppRadii.borderFull,
                onTap: () => onChanged(value == n ? null : n),
                child: Container(
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == n ? c.surfaceInverse : c.surface3,
                    borderRadius: AppRadii.borderFull,
                  ),
                  child: Text(
                    '$n',
                    style: t.numM.copyWith(
                      color: value == n ? c.textOnInverse : c.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
