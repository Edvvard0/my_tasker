import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/presentation/payment_editor.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart';

/// «Поступления» (02, 5.4.2): деньги по месяцам (колонки Excel, месяц —
/// по Москве) и список платежей. Платёж к проекту не привязан сам:
/// деньги к проектам относят распределения; не разнесённая часть видна.
class PaymentsScreen extends ConsumerWidget {
  const PaymentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(workDataProvider);
    return ScreenScaffold(
      key: const Key('payments-screen'),
      title: 'Поступления',
      parentLabel: 'Работа',
      onBack: () => workBack(context),
      actions: [
        IconButton(
          key: const Key('payments-add'),
          tooltip: 'Новый платёж',
          onPressed: () => showPaymentEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: data.when(
        loading: () => const ListSkeleton(),
        error: (error, _) => const NoticeCard(
          label: 'Не загрузилось',
          tone: StatusTone.danger,
          text: 'Не удалось прочитать платежи на устройстве.',
        ),
        data: (d) => _Body(data: d),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.data});

  final WorkData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    if (data.payments.isEmpty) {
      return EmptyState(
        key: const Key('payments-empty'),
        icon: LucideIcons.banknote,
        title: 'Платежей пока нет',
        message:
            'Внесите первый платёж и распределите его по проектам и '
            'доработкам.',
        action: FilledButton(
          key: const Key('payments-empty-add'),
          onPressed: () => showPaymentEditor(context),
          child: const Text('Добавить платёж'),
        ),
      );
    }
    final months = data.monthly().reversed.toList();
    final over = [
      for (final p in data.integrity)
        if (p.code == 'over_allocated') p,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in over) ...[
          WorkWarning(
            key: Key('payments-overallocated-${p.id}'),
            text:
                'По одному платежу распределено больше, чем пришло, на '
                '${formatAmount(p.excess!)}.',
            actions: [
              OutlinedButton(
                onPressed: () => showPaymentEditor(context, paymentId: p.id),
                child: const Text('Открыть платёж'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
        ],
        const WorkSectionHeader(title: 'По месяцам'),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
          child: Column(
            key: const Key('payments-months'),
            children: [
              for (final m in months)
                Padding(
                  key: Key('month-${m.month}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s4,
                    vertical: AppSpacing.s3,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          formatMonthKey(m.month, data.now),
                          style: t.bodyStrong,
                        ),
                      ),
                      if ((m.unallocated ?? 0) != 0) ...[
                        Text(
                          (m.unallocated! > 0 ? 'не разнесено ' : 'лишнего ') +
                              formatAmount(m.unallocated!.abs()),
                          style: t.caption.copyWith(color: c.textSecondary),
                        ),
                        const SizedBox(width: AppSpacing.s3),
                      ],
                      Text(formatAmount(m.received), style: t.numL),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const WorkSectionHeader(title: 'Платежи'),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
          child: Column(
            key: const Key('payments-list'),
            children: [for (final p in data.payments) _row(context, p)],
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
      ],
    );
  }

  Widget _row(BuildContext context, Payment p) {
    final c = context.colors;
    final t = context.text;
    final payer = p.payerId == null ? null : data.personById[p.payerId]?.name;
    final targets = <String>{
      for (final a in data.allocationsOfPayment(p.id))
        ?data.projectById[a.projectId]?.title,
    };
    final free = data.unallocatedOf(p);
    final caption = [
      ?payer,
      if (targets.isNotEmpty) targets.join(', '),
      if (p.comment != null) p.comment!,
      if (free > 0) 'не разнесено ${formatAmount(free)}',
      if (free < 0) 'распределено больше на ${formatAmount(-free)}',
    ].join(' · ');
    return InkWell(
      key: Key('payment-${p.id}'),
      onTap: () => showPaymentEditor(context, paymentId: p.id),
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
                formatDateText(moscowDate(p.paidAt), data.now),
                style: t.numS.copyWith(color: c.textSecondary),
              ),
            ),
            Expanded(
              child: Text(
                caption.isEmpty ? 'Платёж' : caption,
                style: t.bodyS,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Text(formatAmount(p.amount), style: t.numM),
          ],
        ),
      ),
    );
  }
}
