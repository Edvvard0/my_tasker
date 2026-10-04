import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/account_editor.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/finance/presentation/reconcile_sheet.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';

/// «Счета»: общий баланс крупной цифрой и карточки счетов с балансами
/// (02, 6.5). Кредитка — обычный счёт: отрицательный баланс — потрачено
/// сверх положительного.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('accounts-screen'),
      title: 'Счета',
      parentLabel: 'Финансы',
      onBack: () => financeBack(context),
      actions: [
        IconButton(
          key: const Key('accounts-add'),
          tooltip: 'Новый счёт',
          onPressed: () => showAccountEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: FinanceBuilder(
        builder: (context, data) => AccountsBody(data: data),
      ),
    );
  }
}

/// Содержимое экрана «Счета» (также используется в golden-тесте).
class AccountsBody extends ConsumerStatefulWidget {
  const AccountsBody({required this.data, super.key});

  final FinanceData data;

  @override
  ConsumerState<AccountsBody> createState() => _AccountsBodyState();
}

class _AccountsBodyState extends ConsumerState<AccountsBody> {
  bool _archive = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final c = context.colors;
    final t = context.text;
    final shown = [
      for (final a in data.accounts)
        if (a.archived == _archive) a,
    ];
    final archivedCount = data.accounts.where((a) => a.archived).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ОБЩИЙ БАЛАНС',
                style: t.overline.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s1),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AmountText(
                  data.balances.total,
                  style: t.display,
                  textKey: const Key('accounts-total'),
                ),
              ),
              Text(
                'Сумма счетов с флагом «В общем балансе»',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
        if (archivedCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s3),
            child: ChipRow(
              children: [
                FilterPill(
                  key: const Key('accounts-filter-open'),
                  label: 'Открытые',
                  selected: !_archive,
                  onTap: () => setState(() => _archive = false),
                ),
                FilterPill(
                  key: const Key('accounts-filter-archive'),
                  label: 'Архив · $archivedCount',
                  selected: _archive,
                  onTap: () => setState(() => _archive = true),
                ),
              ],
            ),
          ),
        if (shown.isEmpty)
          EmptyState(
            key: const Key('accounts-empty'),
            icon: LucideIcons.wallet,
            title: _archive ? 'Архив пуст' : 'Счетов пока нет',
            message: _archive
                ? 'Сюда попадают скрытые счета.'
                : 'Добавьте наличные, карту или вклад: с них считается общий '
                      'баланс.',
            action: _archive ? null : addAccountButton(context),
          )
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final a in shown)
                  AccountTile(
                    key: Key('account-${a.id}'),
                    account: a,
                    balance: data.balanceOf(a.id),
                    onTap: () => context.push('/finance/accounts/${a.id}'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Карточка счёта: баланс, действия (операция, сверка, правка), корректировки
/// и операции счёта.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({required this.accountId, super.key});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('account-screen'),
      title:
          ref.watch(financeDataProvider).value?.accountById[accountId]?.name ??
          'Счёт',
      parentLabel: 'Счета',
      onBack: () =>
          context.canPop() ? context.pop() : context.go('/finance/accounts'),
      actions: [
        IconButton(
          key: const Key('account-edit'),
          tooltip: 'Изменить счёт',
          onPressed: () => showAccountEditor(context, accountId: accountId),
          icon: const Icon(LucideIcons.pencil, size: 22),
        ),
      ],
      child: FinanceBuilder(
        builder: (context, data) {
          final account = data.accountById[accountId];
          if (account == null) {
            return const EmptyState(
              key: Key('account-missing'),
              icon: LucideIcons.wallet,
              title: 'Счёт не найден',
              message: 'Возможно, его удалили на другом устройстве.',
            );
          }
          return _AccountBody(data: data, account: account);
        },
      ),
    );
  }
}

class _AccountBody extends ConsumerWidget {
  const _AccountBody({required this.data, required this.account});

  final FinanceData data;
  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final txs = data.transactionsOf(account.id);
    final gaps = data.adjustmentsOf(account).reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                account.kind.label.toUpperCase(),
                style: t.overline.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s1),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AmountText(
                  data.balanceOf(account.id),
                  style: t.display,
                  textKey: const Key('account-balance'),
                ),
              ),
              Text(
                [
                  if (account.bank != null) account.bank!,
                  if (account.cardLast4 != null) '•••• ${account.cardLast4}',
                  if (!account.includeInTotal) 'не в общем балансе',
                  if (account.archived) 'в архиве',
                ].join(' · '),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
              if (account.creditLimit != null)
                Row(
                  children: [
                    Text(
                      'Лимит (справочно): ',
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                    AmountText(
                      account.creditLimit!,
                      style: t.numM.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
            ],
          ),
        ),
        Wrap(
          spacing: AppSpacing.s2,
          runSpacing: AppSpacing.s2,
          children: [
            FilledButton.icon(
              key: const Key('account-add-tx'),
              onPressed: () =>
                  showTransactionEditor(context, accountId: account.id),
              icon: const Icon(LucideIcons.plus, size: 18),
              label: const Text('Операция'),
            ),
            OutlinedButton.icon(
              key: const Key('account-reconcile'),
              onPressed: () => showReconcileSheet(context, account.id),
              icon: const Icon(LucideIcons.scale, size: 18),
              label: const Text('Сверить с банком'),
            ),
          ],
        ),
        if (gaps.isNotEmpty) ...[
          const FinanceSection(title: 'Сверки'),
          ListCard(
            children: [
              for (final g in gaps)
                ListTile(
                  key: Key('adjustment-${g.checkpointId}'),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'В банке ',
                          style: t.bodyS.copyWith(color: c.textSecondary),
                        ),
                      ),
                      AmountText(g.actual, style: t.numM),
                    ],
                  ),
                  subtitle: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${formatDayMoscow(g.checkedAt, data.now)} · '
                          'корректировка',
                          style: t.caption.copyWith(color: c.textTertiary),
                        ),
                      ),
                      AmountText(
                        g.adjustment,
                        signed: true,
                        style: t.numS.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    key: Key('checkpoint-delete-${g.checkpointId}'),
                    tooltip: 'Удалить сверку',
                    icon: const Icon(LucideIcons.trash2, size: 18),
                    onPressed: () => ref
                        .read(financeRepositoryProvider)
                        .deleteCheckpoint(g.checkpointId),
                  ),
                ),
            ],
          ),
        ],
        const FinanceSection(title: 'Операции'),
        if (txs.isEmpty)
          const EmptyState(
            key: Key('account-no-tx'),
            icon: LucideIcons.receipt,
            title: 'Операций нет',
            message: 'Записанные по счёту траты и поступления появятся здесь.',
          )
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final tx in txs.take(50))
                  TransactionTile(
                    data: data,
                    tx: tx,
                    perspective: account.id,
                    onTap: () => showTransactionEditor(context, txId: tx.id),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// «5 окт.» для момента по Москве.
String formatDayMoscow(DateTime instant, DateTime now) =>
    formatDateText(moscowDay(instant), now);
