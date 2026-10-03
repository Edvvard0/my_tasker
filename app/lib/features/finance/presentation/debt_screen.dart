import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/debt_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/debt_actions.dart';
import 'package:my_tasker/features/finance/presentation/debt_editor.dart';
import 'package:my_tasker/features/finance/presentation/debt_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/repayment_sheet.dart';
import 'package:my_tasker/features/finance/presentation/widgets/debt_tiles.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_states.dart';

/// «Долг»: остаток, прогресс возврата, срок и просрочка, действия
/// «Погашение» и «Закрыть остаток», история погашений. Правка — карандаш,
/// удаление — меню.
class DebtScreen extends ConsumerWidget {
  const DebtScreen({required this.debtId, super.key});

  final String debtId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(debtDetailProvider(debtId));
    final debt = detail.value?.debt;
    final Widget body;
    if (detail.hasError && !detail.hasValue) {
      body = const SingleChildScrollView(child: FinanceErrorNotice());
    } else if (!detail.hasValue) {
      body = const SingleChildScrollView(child: ListSkeleton());
    } else if (detail.requireValue == null) {
      body = EmptyState(
        key: const Key('debt-missing'),
        icon: LucideIcons.handCoins,
        title: 'Долг не найден',
        message: 'Возможно, его удалили на другом устройстве.',
        action: ElevatedButton(
          onPressed: () => context.go('/finance/debts'),
          child: const Text('К долгам'),
        ),
      );
    } else {
      body = _DebtBody(detail: detail.requireValue!);
    }
    return ScreenScaffold(
      title: debt?.who ?? 'Долг',
      parentLabel: 'Долги',
      onBack: () => context.go('/finance/debts'),
      scrollable: false,
      actions: [
        if (debt != null)
          IconButton(
            key: const Key('debt-edit'),
            tooltip: 'Изменить долг',
            onPressed: () =>
                unawaited(showDebtEditor(context, debtId: debt.id)),
            icon: const Icon(LucideIcons.pencil, size: 22),
          ),
        if (debt != null) _DebtMenu(debt: debt),
      ],
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const FinanceOfflineNotice(),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

class _DebtMenu extends ConsumerWidget {
  const _DebtMenu({required this.debt});

  final Debt debt;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
    key: const Key('debt-menu'),
    tooltip: 'Ещё',
    color: context.colors.surface2,
    icon: const Icon(LucideIcons.ellipsis, size: 22),
    onSelected: (action) async {
      if (action == 'delete' &&
          await deleteDebtWithConfirm(context, ref, debt) &&
          context.mounted) {
        context.go('/finance/debts');
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(
        key: Key('debt-menu-delete'),
        value: 'delete',
        child: Text('Удалить'),
      ),
    ],
  );
}

class _DebtBody extends ConsumerWidget {
  const _DebtBody({required this.detail});

  final DebtDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final state = detail.state;
    final debt = detail.debt;
    final today = ref.watch(moscowTodayProvider);
    final lookups = ref.watch(financeLookupsProvider).value;
    final txAccount = <String, String>{
      for (final r
          in ref.watch(transactionRowsProvider).value ?? const <Json>[])
        r['id']! as String: r['account_id']! as String,
    };
    final bottom = MediaQuery.paddingOf(context).bottom + AppSpacing.s6;
    final due = debt.dueDate;
    return ListView(
      key: const Key('debt-scroll'),
      padding: EdgeInsets.only(bottom: bottom),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    debtDirectionIcon(debt.direction),
                    size: 18,
                    color: c.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      debt.direction.label,
                      key: const Key('debt-direction-label'),
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  ),
                  StatusPill(
                    key: const Key('debt-status-pill'),
                    label: state.status.label,
                    tone: debtStatusTone(state.status),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                'ОСТАТОК',
                style: t.overline.copyWith(color: c.textTertiary),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  moneyText(state.remaining),
                  key: const Key('debt-remaining'),
                  style: t.display,
                ),
              ),
              const SizedBox(height: AppSpacing.s2),
              Text(
                'Вернули ${moneyText(state.repaid)} из '
                '${moneyText(debt.amount)}',
                key: const Key('debt-repaid-line'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s2),
              DebtProgressBar(state: state),
              if (state.overpaid > 0)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s2),
                  child: Text(
                    'Переплата ${moneyText(state.overpaid)}: погашений больше '
                    'суммы долга.',
                    key: const Key('debt-overpaid'),
                    style: t.bodyS.copyWith(color: c.textPrimary),
                  ),
                ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                'Дата долга: ${ymdText(debt.debtDate, today)}',
                key: const Key('debt-date-line'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
              if (due != null)
                Text(
                  'Срок возврата: ${ymdText(due, today)}',
                  key: const Key('debt-due-line'),
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              if (state.overdue)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s1),
                  child: Row(
                    key: const Key('debt-overdue'),
                    children: [
                      Icon(LucideIcons.clock, size: 16, color: c.textPrimary),
                      const SizedBox(width: 6),
                      Text(
                        overdueText(state.overdueDays),
                        style: t.bodyS.copyWith(
                          color: c.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              if (debt.comment != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s3),
                  child: Text(
                    debt.comment!,
                    key: const Key('debt-comment-text'),
                    style: t.body,
                  ),
                ),
              const SizedBox(height: AppSpacing.s4),
              Wrap(
                spacing: AppSpacing.s2,
                runSpacing: AppSpacing.s2,
                children: [
                  FilledButton.icon(
                    key: const Key('debt-repay'),
                    onPressed: () =>
                        unawaited(showRepaymentSheet(context, debtId: debt.id)),
                    icon: const Icon(LucideIcons.plus, size: 18),
                    label: const Text('Погашение'),
                  ),
                  if (!state.isClosed)
                    ElevatedButton.icon(
                      key: const Key('debt-close-rest'),
                      onPressed: () => unawaited(
                        showRepaymentSheet(
                          context,
                          debtId: debt.id,
                          closeRemaining: true,
                        ),
                      ),
                      icon: const Icon(LucideIcons.circleCheck, size: 18),
                      label: const Text('Закрыть остаток'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        AppCard(
          key: const Key('debt-history'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.s2),
                child: Text(
                  'ПОГАШЕНИЯ · ${detail.repayments.length}',
                  style: t.overline.copyWith(color: c.textTertiary),
                ),
              ),
              if (detail.repayments.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.s2),
                  child: Text(
                    'Погашений пока нет.',
                    key: const Key('debt-no-repayments'),
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                )
              else
                for (final r in detail.repayments)
                  _RepaymentTile(
                    repayment: r,
                    direction: debt.direction,
                    today: today,
                    accountName: r.transactionId == null
                        ? null
                        : lookups?.accountName(txAccount[r.transactionId]),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Строка погашения: сумма, дата, куда пришли деньги (или «без движения
/// денег») и заметка.
class _RepaymentTile extends StatelessWidget {
  const _RepaymentTile({
    required this.repayment,
    required this.direction,
    required this.today,
    required this.accountName,
  });

  final DebtRepayment repayment;
  final DebtDirection direction;
  final String today;
  final String? accountName;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final r = repayment;
    final incoming = direction == DebtDirection.owedToMe;
    final where = r.transactionId == null
        ? 'без движения денег'
        : (incoming ? 'на счёт' : 'со счёта') +
              (accountName == null ? '' : ' «$accountName»');
    final note = r.note;
    return InkWell(
      key: Key('repayment-row-${r.id}'),
      borderRadius: AppRadii.borderM,
      onTap: () => unawaited(
        showRepaymentSheet(context, debtId: r.debtId, repaymentId: r.id),
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.surface3,
                shape: BoxShape.circle,
              ),
              child: Icon(
                r.transactionId == null
                    ? LucideIcons.circleMinus
                    : incoming
                    ? LucideIcons.arrowDownLeft
                    : LucideIcons.arrowUpRight,
                size: 20,
                color: c.textSecondary,
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${ymdText(r.repaidOn, today)} · $where',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyStrong,
                  ),
                  if (note != null)
                    Text(
                      note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Text(
              moneyText(r.amount),
              key: Key('repayment-amount-${r.id}'),
              style: t.numM.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
