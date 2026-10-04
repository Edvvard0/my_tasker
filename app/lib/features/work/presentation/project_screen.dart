import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/presentation/change_request_editor.dart';
import 'package:my_tasker/features/work/presentation/payment_editor.dart';
import 'package:my_tasker/features/work/presentation/project_editor.dart';
import 'package:my_tasker/features/work/presentation/time_entry_editor.dart';
import 'package:my_tasker/features/work/presentation/timer_widgets.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart';

enum _MenuAction { edit, addChangeRequest, archive, unarchive, delete }

/// Карточка проекта в стиле «Excel-интерфейса» (02, 5.4.1 и 6.7): плитки
/// «сумма / остаток / ₽ в час», доработки со своими оплатой и остатком,
/// оплаты, часы и доход в час. Итоги считаются, не вводятся.
class ProjectScreen extends ConsumerWidget {
  const ProjectScreen({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(workDataProvider);
    final project = data.value?.projectById[projectId];
    return ScreenScaffold(
      key: const Key('project-screen'),
      title: project?.title ?? 'Проект',
      parentLabel: 'Работа',
      onBack: () => workBack(context),
      actions: [
        if (project != null) ...[
          ProjectTimerButton(projectId: projectId),
          _ProjectMenu(project: project),
        ],
      ],
      child: data.when(
        loading: () => const ListSkeleton(),
        error: (error, _) => const NoticeCard(
          key: Key('project-error-card'),
          label: 'Не загрузилось',
          tone: StatusTone.danger,
          text: 'Не удалось прочитать проект на устройстве.',
        ),
        data: (d) => project == null
            ? const EmptyState(
                key: Key('project-missing'),
                icon: LucideIcons.folderKanban,
                title: 'Проект не найден',
                message:
                    'Возможно, его удалили на другом устройстве. Удалённое '
                    'лежит в корзине 30 дней.',
              )
            : _ProjectBody(data: d, project: project),
      ),
    );
  }
}

class _ProjectMenu extends ConsumerWidget {
  const _ProjectMenu({required this.project});

  final WorkProject project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_MenuAction>(
      key: const Key('project-menu'),
      tooltip: 'Действия',
      icon: const Icon(LucideIcons.ellipsis, size: 22),
      onSelected: (action) => _run(context, ref, action),
      itemBuilder: (_) => [
        const PopupMenuItem(
          key: Key('project-menu-edit'),
          value: _MenuAction.edit,
          child: Text('Изменить'),
        ),
        const PopupMenuItem(
          key: Key('project-menu-add-cr'),
          value: _MenuAction.addChangeRequest,
          child: Text('Добавить доработку'),
        ),
        if (project.archived)
          const PopupMenuItem(
            key: Key('project-menu-unarchive'),
            value: _MenuAction.unarchive,
            child: Text('Вернуть из архива'),
          )
        else if (project.effectiveStatus.archivable)
          const PopupMenuItem(
            key: Key('project-menu-archive'),
            value: _MenuAction.archive,
            child: Text('В архив'),
          ),
        const PopupMenuItem(
          key: Key('project-menu-delete'),
          value: _MenuAction.delete,
          child: Text('Удалить'),
        ),
      ],
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    _MenuAction action,
  ) async {
    final repo = ref.read(workRepositoryProvider);
    switch (action) {
      case _MenuAction.edit:
        await showProjectEditor(context, projectId: project.id);
      case _MenuAction.addChangeRequest:
        await showChangeRequestEditor(context, projectId: project.id);
      case _MenuAction.archive:
        try {
          await repo.setArchived(project.id, archived: true);
        } on ValidationError catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(e.message)));
          }
        }
      case _MenuAction.unarchive:
        await repo.setArchived(project.id, archived: false);
      case _MenuAction.delete:
        final ok = await showConfirmDialog(
          context,
          title: 'Удалить проект «${project.title}»?',
          message:
              'Вместе с проектом уйдут его доработки, распределения оплат и '
              'записи времени. Сами платежи останутся. Вернуть можно из '
              'корзины в течение 30 дней.',
          confirmLabel: 'Удалить',
          danger: true,
        );
        if (!ok || !context.mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        await repo.deleteProject(project.id);
        if (!context.mounted) return;
        workBack(context);
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('Удалено: «${project.title}»'),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(
                label: 'Отменить',
                onPressed: () => repo.restoreProject(project.id),
              ),
            ),
          );
    }
  }
}

class _ProjectBody extends ConsumerWidget {
  const _ProjectBody({required this.data, required this.project});

  final WorkData data;
  final WorkProject project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final s = data.summaryOf(project.id);
    final income = data.incomeFor(projectId: project.id);
    final client = data.clientOf(project);
    final problems = [
      for (final p in data.integrity)
        if (p.code == 'over_allocated' &&
            data
                .allocationsOfPayment(p.id)
                .any((a) => a.projectId == project.id))
          p,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TimerConflictBanner(),
        Row(
          children: [
            StatusPill(
              label: project.effectiveStatus.label,
              tone: projectTone(project.effectiveStatus),
            ),
            if (project.archived) ...[
              const SizedBox(width: AppSpacing.s2),
              const StatusPill(label: 'В архиве', tone: StatusTone.neutral),
            ],
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Text(
                [
                  client?.name ?? 'заказчик не указан',
                  if (project.effectivePayType == PayType.hourly &&
                      project.hourlyRate != null)
                    '${formatAmount(project.hourlyRate!)}/ч',
                ].join(' · '),
                key: const Key('project-meta'),
                style: t.bodyS.copyWith(color: c.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),
        KpiRow(
          tiles: [
            KpiTile(
              key: const Key('project-kpi-total'),
              label: 'Сумма',
              value: formatAmountShort(s.total),
              caption: '${formatPercentBp(s.paidBp)} оплач.',
            ),
            KpiTile(
              key: const Key('project-kpi-remaining'),
              label: s.remaining < 0 ? 'Переплата' : 'Остаток',
              value: formatAmountShort(s.remaining.abs()),
              caption: project.deadlineDate == null
                  ? 'без срока'
                  : 'срок ${formatDateText(project.deadlineDate, data.now)}',
            ),
            KpiTile(
              key: const Key('project-kpi-per-hour'),
              label: '₽ / час',
              value: formatPerHourShort(income.perHourFact),
              caption: income.seconds == 0
                  ? 'нет часов'
                  : '${formatHours(income.seconds)} всего',
            ),
          ],
        ),
        for (final p in problems) ...[
          const SizedBox(height: AppSpacing.s3),
          WorkWarning(
            key: Key('project-overallocated-${p.id}'),
            text:
                'Распределено больше, чем пришло, на ${formatAmount(p.excess!)}. '
                'Исправьте платёж.',
            actions: [
              OutlinedButton(
                onPressed: () => showPaymentEditor(context, paymentId: p.id),
                child: const Text('Открыть платёж'),
              ),
            ],
          ),
        ],
        _ChangeRequests(data: data, project: project, summary: s),
        _Payments(data: data, project: project),
        _TimeSection(data: data, project: project, income: income),
        if ((project.description ?? '').isNotEmpty || project.links.isNotEmpty)
          _About(project: project),
        const SizedBox(height: AppSpacing.s4),
      ],
    );
  }
}

/// Строка таблицы «Excel»: название, сумма, оплата, остаток, статус.
class _MoneyRow extends StatelessWidget {
  const _MoneyRow({
    required this.rowKey,
    required this.title,
    required this.amount,
    required this.basisPoints,
    required this.remaining,
    this.pill,
    this.muted = false,
    this.onTap,
  });

  final Key rowKey;
  final String title;
  final int amount;
  final int basisPoints;
  final int remaining;
  final Widget? pill;
  final bool muted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final compact = context.windowClass.isCompact;
    final fg = muted ? c.textTertiary : c.textPrimary;
    final remainingText = muted
        ? '—'
        : remaining < 0
        ? '+${formatAmount(-remaining)}'
        : formatAmount(remaining);
    final bar = Row(
      children: [
        Expanded(child: PaidBar(basisPoints: muted ? 0 : basisPoints)),
        const SizedBox(width: AppSpacing.s2),
        SizedBox(
          width: 44,
          child: Text(
            muted ? '' : formatPercentWhole(basisPoints),
            style: t.numS.copyWith(color: c.textSecondary),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
    return InkWell(
      key: rowKey,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: t.bodyStrong.copyWith(color: fg),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s2),
                      Text(
                        formatAmount(amount),
                        style: t.numM.copyWith(color: fg),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  bar,
                  const SizedBox(height: AppSpacing.s1),
                  Row(
                    children: [
                      ?pill,
                      const Spacer(),
                      Text(
                        'ост. $remainingText',
                        style: t.numS.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    flex: 34,
                    child: Text(
                      title,
                      style: t.bodyStrong.copyWith(color: fg),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 16,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        formatAmount(amount),
                        style: t.numM.copyWith(color: fg),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s4),
                  Expanded(flex: 24, child: bar),
                  Expanded(
                    flex: 16,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        remainingText,
                        style: t.numM.copyWith(color: fg),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s4),
                  Expanded(
                    flex: 14,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: pill ?? const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Заголовки колонок таблицы доработок на десктопе (те же доли ширины,
/// что у строк [_MoneyRow]).
class _MoneyHeader extends StatelessWidget {
  const _MoneyHeader();

  @override
  Widget build(BuildContext context) {
    final style = context.text.overline.copyWith(
      color: context.colors.textSecondary,
    );
    Widget cell(int flex, String text, {bool right = false}) => Expanded(
      flex: flex,
      child: Align(
        alignment: right ? Alignment.centerRight : Alignment.centerLeft,
        child: Text(text, style: style),
      ),
    );
    return Padding(
      key: const Key('money-header'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s2,
      ),
      child: Row(
        children: [
          cell(34, 'ДОРАБОТКА'),
          cell(16, 'СУММА', right: true),
          const SizedBox(width: AppSpacing.s4),
          cell(24, 'ОПЛАЧЕНО'),
          cell(16, 'ОСТАТОК', right: true),
          const SizedBox(width: AppSpacing.s4),
          cell(14, 'СТАТУС'),
        ],
      ),
    );
  }
}

class _ChangeRequests extends ConsumerWidget {
  const _ChangeRequests({
    required this.data,
    required this.project,
    required this.summary,
  });

  final WorkData data;
  final WorkProject project;
  final ProjectSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final crs = data.changeRequestsOf(project.id);
    final byId = {for (final s in summary.changeRequests) s.id: s};
    final baseBp = paidBasisPoints(summary.baseReceived, project.base);
    final showBase = project.base > 0 || summary.baseReceived > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkSectionHeader(
          title: 'Доработки',
          trailing: TextButton.icon(
            key: const Key('cr-add'),
            onPressed: () =>
                showChangeRequestEditor(context, projectId: project.id),
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('Добавить'),
          ),
        ),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
          child: Column(
            key: const Key('project-money-table'),
            children: [
              if (!context.windowClass.isCompact) ...[
                const _MoneyHeader(),
                Divider(height: 1, color: c.borderSubtle),
              ],
              if (showBase)
                _MoneyRow(
                  rowKey: const Key('money-row-base'),
                  title: 'Основная сумма',
                  amount: project.base,
                  basisPoints: baseBp,
                  remaining: summary.baseRemaining,
                ),
              for (final cr in crs) ...[
                if (showBase || cr != crs.first)
                  Divider(height: 1, color: c.borderSubtle),
                _MoneyRow(
                  rowKey: Key('money-row-${cr.id}'),
                  title: cr.title,
                  amount: cr.amount,
                  basisPoints: paidBasisPoints(
                    byId[cr.id]?.received ?? 0,
                    cr.amount,
                  ),
                  remaining: byId[cr.id]?.remaining ?? 0,
                  muted: cr.status == ChangeRequestStatus.cancelled,
                  pill: StatusPill(
                    label: cr.status.label,
                    tone: changeRequestTone(cr.status),
                  ),
                  onTap: () => showChangeRequestEditor(
                    context,
                    projectId: project.id,
                    changeRequestId: cr.id,
                  ),
                ),
              ],
              if (!showBase && crs.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.s4),
                  child: Text(
                    'Доработок пока нет. Сумма проекта — это базовая сумма '
                    'плюс доработки.',
                    key: const Key('money-empty'),
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                ),
              Divider(height: 1, color: c.borderDefault),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s4,
                  vertical: AppSpacing.s3,
                ),
                child: Row(
                  key: const Key('money-total'),
                  children: [
                    Text(
                      'ИТОГО',
                      style: t.overline.copyWith(color: c.textSecondary),
                    ),
                    const Spacer(),
                    Text(
                      '${formatAmount(summary.total)} · '
                      '${formatPercentBp(summary.paidBp)} · '
                      'ост. ${formatAmount(summary.remaining)}',
                      style: t.numM,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Payments extends ConsumerWidget {
  const _Payments({required this.data, required this.project});

  final WorkData data;
  final WorkProject project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final paymentById = {for (final p in data.payments) p.id: p};
    final rows =
        [
          for (final a in data.allocationsOfProject(project.id))
            if (paymentById.containsKey(a.paymentId)) a,
        ]..sort((a, b) {
          final pa = paymentById[a.paymentId]!.paidAt;
          final pb = paymentById[b.paymentId]!.paidAt;
          return pb.compareTo(pa);
        });
    final monthly = data.monthly(projectId: project.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkSectionHeader(
          title: 'Оплаты',
          trailing: TextButton.icon(
            key: const Key('project-add-payment'),
            onPressed: () => showPaymentEditor(context, projectId: project.id),
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('Платёж'),
          ),
        ),
        if (monthly.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s2),
            child: Wrap(
              key: const Key('project-monthly'),
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s1,
              children: [
                for (final m in monthly)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s3,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface3,
                      borderRadius: AppRadii.borderFull,
                    ),
                    child: Text(
                      '${formatMonthKey(m.month, data.now)} '
                      '${formatAmountShort(m.received)}',
                      style: t.numS,
                    ),
                  ),
              ],
            ),
          ),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
          child: rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.s4),
                  child: Text(
                    'Оплат пока нет.',
                    key: const Key('project-payments-empty'),
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                )
              : Column(
                  key: const Key('project-payments'),
                  children: [
                    for (final a in rows.take(8))
                      _paymentRow(context, paymentById[a.paymentId]!, a),
                    if (rows.length > 8)
                      WorkLinkRow(
                        icon: LucideIcons.banknote,
                        label: 'Все поступления',
                        onTap: () => context.push('/work/payments'),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _paymentRow(BuildContext context, Payment payment, Allocation a) {
    final c = context.colors;
    final t = context.text;
    final target = a.changeRequestId == null
        ? 'Основная сумма'
        : data.changeRequestById[a.changeRequestId]?.title ?? 'Основная сумма';
    final payer = payment.payerId == null
        ? null
        : data.personById[payment.payerId]?.name;
    final caption = [
      target,
      ?payer,
      if (payment.comment != null) payment.comment!,
    ].join(' · ');
    return InkWell(
      key: Key('allocation-${a.id}'),
      onTap: () => showPaymentEditor(context, paymentId: payment.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              child: Text(
                formatDateText(moscowDate(payment.paidAt), data.now),
                style: t.numS.copyWith(color: c.textSecondary),
              ),
            ),
            Expanded(
              child: Text(
                caption,
                style: t.bodyS,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Text(formatAmount(a.amount), style: t.numM),
          ],
        ),
      ),
    );
  }
}

class _TimeSection extends ConsumerWidget {
  const _TimeSection({
    required this.data,
    required this.project,
    required this.income,
  });

  final WorkData data;
  final WorkProject project;
  final IncomeReport income;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final entries = data.entriesOf(project.id);
    final fact = formatPerHour(income.perHourFact);
    final accrued = formatPerHour(income.perHourAccrued);
    final rate = project.hourlyRate;
    final byRate = rate == null
        ? null
        : formatAmount(hourlyBillable(rate, income.seconds));
    final lines = <String>[
      'Оплачиваемых часов: ${formatHours(income.seconds)}',
      'По факту: $fact, по начисленному: $accrued',
      if (project.effectivePayType == PayType.hourly && byRate != null)
        'По ставке набежало: $byRate',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkSectionHeader(
          title: 'Время',
          trailing: TextButton.icon(
            key: const Key('project-add-entry'),
            onPressed: () =>
                showTimeEntryEditor(context, projectId: project.id),
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('Вручную'),
          ),
        ),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Column(
            key: const Key('project-time'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          line,
                          style: t.bodyS.copyWith(color: c.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
              if (entries.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.s2),
                for (final e in entries.take(5)) _entryRow(context, e),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _entryRow(BuildContext context, TimeEntry e) {
    final c = context.colors;
    final t = context.text;
    final seconds = entrySeconds(e);
    final title = [
      formatDateText(moscowDate(e.startedAt), data.now),
      if (e.note != null) e.note!,
      if (!e.billable) 'не оплачивается',
    ].join(' · ');
    return InkWell(
      key: Key('entry-${e.id}'),
      onTap: e.isRunning
          ? () => showTimerSheet(context)
          : () => showTimeEntryEditor(context, entryId: e.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s2,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: t.bodyS,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              seconds == null ? 'идёт' : formatHours(seconds),
              style: t.numM.copyWith(
                color: seconds == null ? c.accent : c.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _About extends StatelessWidget {
  const _About({required this.project});

  final WorkProject project;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const WorkSectionHeader(title: 'О проекте'),
        AppCard(
          child: Column(
            key: const Key('project-about'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ((project.description ?? '').isNotEmpty)
                Text(project.description!, style: t.body),
              for (final l in project.links)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s2),
                  child: Row(
                    children: [
                      Icon(LucideIcons.link, size: 16, color: c.textSecondary),
                      const SizedBox(width: AppSpacing.s2),
                      Expanded(
                        child: Text(
                          l.title == null ? l.url : '${l.title} · ${l.url}',
                          style: t.bodyS.copyWith(color: c.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
