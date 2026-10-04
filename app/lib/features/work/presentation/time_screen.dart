import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/work/application/timer_providers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/presentation/time_entry_editor.dart';
import 'package:my_tasker/features/work/presentation/timer_widgets.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart';

/// «Трекер времени»: идущий таймер (или запуск по проекту), часы за
/// неделю и месяц, доход в час по факту и по начисленному, записи по дням.
class TimeScreen extends ConsumerWidget {
  const TimeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(workDataProvider);
    return ScreenScaffold(
      key: const Key('time-screen'),
      title: 'Время',
      parentLabel: 'Работа',
      onBack: () => workBack(context),
      actions: [
        IconButton(
          key: const Key('time-add'),
          tooltip: 'Добавить время вручную',
          onPressed: () => showTimeEntryEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: data.when(
        loading: () => const ListSkeleton(),
        error: (error, _) => const NoticeCard(
          label: 'Не загрузилось',
          tone: StatusTone.danger,
          text: 'Не удалось прочитать записи времени на устройстве.',
        ),
        data: (d) => _Body(data: d),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.data});

  final WorkData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final today = parseDate(moscowDate(data.now))!;
    final weekFrom = formatDate(mondayOf(today));
    final weekTo = formatDate(addDays(mondayOf(today), 6));
    final week = data.incomeFor(
      period: DatePeriod(from: weekFrom, to: weekTo),
    );
    final month = data.incomeFor(period: data.thisMonth);
    final done = [
      for (final e in data.entries)
        if (!e.isRunning) e,
    ].take(60).toList();
    final groups = <String, List<TimeEntry>>{};
    for (final e in done) {
      groups.putIfAbsent(moscowDate(e.startedAt), () => []).add(e);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TimerConflictBanner(),
        const _TimerCard(),
        const SizedBox(height: AppSpacing.s3),
        KpiRow(
          tiles: [
            KpiTile(
              key: const Key('time-kpi-week'),
              label: 'Неделя',
              value: formatHours(week.seconds),
              caption: 'оплачиваемых',
            ),
            KpiTile(
              key: const Key('time-kpi-month'),
              label: 'Месяц',
              value: formatHours(month.seconds),
              caption: 'оплачиваемых',
            ),
            KpiTile(
              key: const Key('time-kpi-per-hour'),
              label: '₽ / час',
              value: formatPerHourShort(month.perHourFact),
              caption: month.perHourAccrued == null
                  ? 'по факту'
                  : 'по начисл. ${formatPerHourShort(month.perHourAccrued)}',
            ),
          ],
        ),
        if (groups.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.s6),
            child: EmptyState(
              key: Key('time-empty'),
              icon: LucideIcons.timer,
              title: 'Записей времени пока нет',
              message:
                  'Запустите таймер по проекту или добавьте время вручную: '
                  'часы дадут доход в час.',
            ),
          )
        else
          for (final day in groups.entries) ...[
            WorkSectionHeader(
              title: formatDateText(day.key, data.now),
              trailing: Text(
                formatHours(
                  day.value.fold<int>(0, (n, e) => n + (entrySeconds(e) ?? 0)),
                ),
                style: t.numS.copyWith(color: c.textSecondary),
              ),
            ),
            AppCard(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
              child: Column(
                children: [for (final e in day.value) _entryRow(context, e)],
              ),
            ),
          ],
        const SizedBox(height: AppSpacing.s4),
      ],
    );
  }

  Widget _entryRow(BuildContext context, TimeEntry e) {
    final c = context.colors;
    final t = context.text;
    final project = data.projectById[e.projectId]?.title ?? 'Проект';
    final cr = e.changeRequestId == null
        ? null
        : data.changeRequestById[e.changeRequestId]?.title;
    final caption = [
      project,
      ?cr,
      if (e.note != null) e.note!,
      if (!e.billable) 'не оплачивается',
    ].join(' · ');
    return InkWell(
      key: Key('time-entry-${e.id}'),
      onTap: () => showTimeEntryEditor(context, entryId: e.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                caption,
                style: t.bodyS.copyWith(
                  color: e.billable ? c.textPrimary : c.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Text(formatHours(entrySeconds(e) ?? 0), style: t.numM),
          ],
        ),
      ),
    );
  }
}

class _TimerCard extends ConsumerWidget {
  const _TimerCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final timer = ref.watch(primaryTimerProvider);
    final now = ref.watch(timerTickProvider);
    if (timer != null) {
      return AppCard(
        key: const Key('time-running'),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    formatTimer(timer.elapsed(now)),
                    key: const Key('time-running-time'),
                    style: t.kpi,
                  ),
                  Text(
                    timer.title,
                    style: t.bodyS.copyWith(color: c.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              key: const Key('time-stop'),
              onPressed: () => stopTimerWithToast(context, ref, timer),
              icon: const Icon(LucideIcons.square, size: 18),
              label: const Text('Стоп'),
            ),
          ],
        ),
      );
    }
    final projects = [
      for (final p
          in ref.watch(workProjectsProvider).value ?? const <WorkProject>[])
        if (!p.archived &&
            (p.effectiveStatus == ProjectStatus.active ||
                p.effectiveStatus == ProjectStatus.paused))
          p,
    ];
    return AppCard(
      key: const Key('time-idle'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Таймер не запущен', style: t.bodyStrong),
          const SizedBox(height: 2),
          Text(
            projects.isEmpty
                ? 'Создайте проект «в работе», чтобы вести время.'
                : 'Выберите проект, чтобы начать:',
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
          if (projects.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s3),
            ChipRow(
              children: [
                for (final p in projects)
                  FilterPill(
                    key: Key('time-start-${p.id}'),
                    label: p.title,
                    selected: false,
                    icon: LucideIcons.play,
                    onTap: () => startTimerFor(context, ref, projectId: p.id),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
