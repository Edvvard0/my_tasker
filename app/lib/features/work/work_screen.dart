import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/presentation/project_editor.dart';
import 'package:my_tasker/features/work/presentation/project_list.dart';
import 'package:my_tasker/features/work/presentation/timer_widgets.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart';

/// «Работа» (02, 6.6): плитки «получено / мне должны / ₽ в час», переходы
/// в «Мне должны», «Поступления», «Время», «Люди» и «Серверы», фильтры
/// проектов и сами проекты — карточками на телефоне и таблицей на десктопе.
class WorkScreen extends ConsumerWidget {
  const WorkScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(workDataProvider);
    return ScreenScaffold(
      key: const Key('work-overview'),
      title: 'Работа',
      actions: [
        IconButton(
          key: const Key('work-add-project'),
          tooltip: 'Новый проект',
          onPressed: () => showProjectEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: data.when(
        loading: () => const ListSkeleton(rows: 4),
        error: (error, _) => const WorkErrorCard(
          key: Key('work-error'),
          text: 'Не удалось прочитать данные «Работы» на устройстве.',
        ),
        data: (d) => _WorkBody(data: d),
      ),
    );
  }
}

class _WorkBody extends ConsumerWidget {
  const _WorkBody({required this.data});

  final WorkData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(projectFilterProvider);
    final compact = context.windowClass.isCompact;
    final month = data.incomeFor(period: data.thisMonth);
    final owed = data.receivablesAll;
    final monthIndex = int.parse(moscowMonth(data.now).substring(5, 7)) - 1;
    final projects = filterProjects(data, filter);
    final debtors = owed.clients.fold<int>(0, (n, c) => n + c.projects.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TimerConflictBanner(),
        KpiRow(
          tiles: [
            KpiTile(
              key: const Key('kpi-received'),
              label: 'Получено',
              value: formatAmountShort(month.received),
              caption: 'за ${monthNames[monthIndex].toLowerCase()}',
              onTap: () => context.push('/work/payments'),
            ),
            KpiTile(
              key: const Key('kpi-owed'),
              label: 'Мне должны',
              value: formatAmountShort(owed.total),
              caption: debtors == 0
                  ? 'долгов нет'
                  : '$debtors ${pluralWord(debtors, 'проект', 'проекта', 'проектов')}',
              onTap: () => context.push('/work/receivables'),
            ),
            KpiTile(
              key: const Key('kpi-per-hour'),
              label: '₽ / час',
              value: formatPerHourShort(month.perHourFact),
              caption: month.seconds == 0
                  ? 'нет часов за месяц'
                  : '${formatHours(month.seconds)} за месяц',
              onTap: () => context.push('/work/time'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              WorkLinkRow(
                key: const Key('work-receivables-link'),
                icon: LucideIcons.wallet,
                label: 'Мне должны',
                trailingText: owed.total == 0
                    ? null
                    : formatAmountShort(owed.total),
                onTap: () => context.push('/work/receivables'),
              ),
              WorkLinkRow(
                key: const Key('work-payments-link'),
                icon: LucideIcons.banknote,
                label: 'Поступления',
                onTap: () => context.push('/work/payments'),
              ),
              WorkLinkRow(
                key: const Key('work-time-link'),
                icon: LucideIcons.timer,
                label: 'Трекер времени',
                onTap: () => context.push('/work/time'),
              ),
              WorkLinkRow(
                key: const Key('work-people-link'),
                icon: LucideIcons.users,
                label: 'Люди',
                onTap: () => context.push('/work/people'),
              ),
              WorkLinkRow(
                key: const Key('work-servers-link'),
                icon: LucideIcons.server,
                label: 'Серверы',
                onTap: () => context.go('/work/servers'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        ChipRow(
          children: [
            for (final f in ProjectFilter.values)
              FilterPill(
                key: Key('work-filter-${f.name}'),
                label: f.label,
                selected: filter == f,
                onTap: () => ref.read(projectFilterProvider.notifier).select(f),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),
        if (projects.isEmpty)
          _Empty(filter: filter, hasProjects: data.projects.isNotEmpty)
        else if (compact)
          ProjectCards(data: data, projects: projects)
        else
          ProjectTable(data: data, projects: projects),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.filter, required this.hasProjects});

  final ProjectFilter filter;
  final bool hasProjects;

  @override
  Widget build(BuildContext context) {
    if (!hasProjects) {
      return EmptyState(
        key: const Key('work-empty'),
        icon: LucideIcons.folderKanban,
        title: 'Проектов пока нет',
        message:
            'Заведите проект: сумма, доработки, оплаты и часы будут в одном '
            'месте.',
        action: FilledButton(
          key: const Key('work-empty-add'),
          onPressed: () => showProjectEditor(context),
          child: const Text('Добавить проект'),
        ),
      );
    }
    final text = switch (filter) {
      ProjectFilter.active => 'Нет проектов в работе.',
      ProjectFilter.all => 'Нет проектов.',
      ProjectFilter.debt => 'Долгов по проектам нет.',
      ProjectFilter.archive => 'Архив пуст.',
    };
    return EmptyState(
      key: const Key('work-empty-filter'),
      icon: LucideIcons.folderKanban,
      title: text,
      message: 'Смените фильтр, чтобы увидеть остальные проекты.',
    );
  }
}
