import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/banks/presentation/banks_widgets.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/finance/presentation/reconcile_sheet.dart';

/// Сверка с банком (spec Этапа 5, 4.4): человек вводит фактический остаток
/// из приложения банка и видит корректировку — разницу между ним и
/// расчётным балансом. Остатки из уведомлений и выписок ложатся сюда же
/// автоматически (точки сверки с источником).
class BankReconcileScreen extends ConsumerWidget {
  const BankReconcileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('bank-reconcile-screen'),
      title: 'Сверка с банком',
      parentLabel: 'Банки',
      onBack: () => financeBack(context),
      child: FinanceBuilder(
        builder: (context, data) => ReconcileBody(data: data),
      ),
    );
  }
}

/// Название источника точки сверки.
String checkpointSourceLabel(CheckpointSource source) => switch (source) {
  CheckpointSource.manual => 'вручную',
  CheckpointSource.notification => 'из уведомления банка',
  CheckpointSource.statement => 'из выписки',
};

class ReconcileBody extends StatelessWidget {
  const ReconcileBody({required this.data, super.key});

  final FinanceData data;

  @override
  Widget build(BuildContext context) {
    final accounts = data.activeAccounts;
    if (accounts.isEmpty) {
      return const EmptyState(
        key: Key('reconcile-empty'),
        icon: LucideIcons.wallet,
        title: 'Нет счетов',
        message: 'Добавьте счёт в «Финансах», чтобы сверять его с банком.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final a in accounts) ...[
          _AccountCard(data: data, account: a),
          const SizedBox(height: AppSpacing.s2),
        ],
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.data, required this.account});

  final FinanceData data;
  final Account account;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final adjustments = data.adjustmentsOf(account);
    final last = adjustments.isEmpty ? null : adjustments.last;
    final checkpoints = [
      for (final cp in data.checkpoints)
        if (cp.accountId == account.id) cp,
    ];
    final lastCheckpoint = checkpoints.isEmpty ? null : checkpoints.last;
    return AppCard(
      key: Key('reconcile-account-${account.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(account.name, style: t.bodyStrong)),
              AmountText(
                data.balanceOf(account.id),
                style: t.numL,
                textKey: Key('reconcile-balance-${account.id}'),
              ),
            ],
          ),
          if (lastCheckpoint != null) ...[
            const SizedBox(height: AppSpacing.s1),
            Text(
              'Последняя сверка: '
              '${momentText(lastCheckpoint.checkedAt, data.now)} · '
              '${checkpointSourceLabel(lastCheckpoint.source)}',
              key: Key('reconcile-last-${account.id}'),
              style: t.caption.copyWith(color: c.textSecondary),
            ),
          ],
          if (last != null) ...[
            const SizedBox(height: AppSpacing.s2),
            Row(
              children: [
                StatusPill(
                  label: last.adjustment == 0 ? 'Сходится' : 'Корректировка',
                  tone: last.adjustment == 0
                      ? StatusTone.success
                      : StatusTone.warning,
                ),
                const SizedBox(width: AppSpacing.s2),
                if (last.adjustment != 0)
                  AmountText(
                    last.adjustment,
                    signed: true,
                    style: t.numM,
                    textKey: Key('reconcile-adjustment-${account.id}'),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.s3),
          OutlinedButton.icon(
            key: Key('reconcile-open-${account.id}'),
            onPressed: () => showReconcileSheet(context, account.id),
            icon: const Icon(LucideIcons.scale, size: 18),
            label: const Text('Сверить с банком'),
          ),
        ],
      ),
    );
  }
}
