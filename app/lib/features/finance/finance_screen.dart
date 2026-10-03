import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';
import 'package:my_tasker/features/finance/presentation/account_editor.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_states.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_tiles.dart';
import 'package:my_tasker/features/finance/presentation/widgets/transaction_feed.dart';

/// Сколько последних операций показывает обзор.
const int recentTransactionsCount = 6;

/// «Финансы» (02, 6.5): общий баланс, быстрые действия, счета с балансами
/// и последние операции. На телефоне счета — карточкой в списке, на десктопе
/// — левой панелью.
class FinanceScreen extends ConsumerWidget {
  const FinanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Засев предустановленных категорий после первой синхронизации.
    ref.watch(financeBootstrapProvider);
    final accounts = ref.watch(accountsProvider);
    final balances = ref.watch(financeBalancesProvider);
    final lookups = ref.watch(financeLookupsProvider);
    final feed = ref.watch(transactionFeedProvider(const TransactionFilter()));

    final failed = [
      accounts,
      balances,
      feed,
    ].any((v) => v.hasError && !v.hasValue);
    final Widget body;
    if (failed) {
      body = const SingleChildScrollView(child: FinanceErrorNotice());
    } else if (!accounts.hasValue ||
        !balances.hasValue ||
        !feed.hasValue ||
        !lookups.hasValue) {
      body = const SingleChildScrollView(child: ListSkeleton(rows: 4));
    } else if (accounts.requireValue.isEmpty) {
      body = EmptyState(
        key: const Key('finance-empty'),
        icon: LucideIcons.wallet,
        title: 'Счетов пока нет',
        message:
            'Добавь наличные или карту и записывай операции: баланс '
            'посчитается сам.',
        action: FilledButton(
          key: const Key('finance-add-account'),
          onPressed: () => unawaited(showAccountEditor(context)),
          child: const Text('Добавить счёт'),
        ),
      );
    } else {
      body = _Overview(
        accounts: accounts.requireValue,
        balances: balances.requireValue,
        lookups: lookups.requireValue,
        recent: feed.requireValue.items
            .take(recentTransactionsCount)
            .toList(growable: false),
      );
    }
    return ScreenScaffold(
      title: 'Финансы',
      scrollable: false,
      actions: [
        IconButton(
          key: const Key('finance-open-feed'),
          tooltip: 'Операции и поиск',
          onPressed: () {
            ref.read(transactionFilterProvider.notifier).reset();
            context.go('/finance/transactions');
          },
          icon: const Icon(LucideIcons.search, size: 22),
        ),
        IconButton(
          key: const Key('finance-open-debts'),
          tooltip: 'Долги',
          onPressed: () => context.go('/finance/debts'),
          icon: const Icon(LucideIcons.handCoins, size: 22),
        ),
        IconButton(
          key: const Key('finance-open-categories'),
          tooltip: 'Категории',
          onPressed: () => context.go('/finance/categories'),
          icon: const Icon(LucideIcons.tags, size: 22),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FinanceOfflineNotice(),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _Overview extends StatefulWidget {
  const _Overview({
    required this.accounts,
    required this.balances,
    required this.lookups,
    required this.recent,
  });

  final List<Account> accounts;
  final FinanceBalances balances;
  final FinanceLookups lookups;
  final List<FinanceTransaction> recent;

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  bool _showArchived = false;

  Widget _accountsList() => _AccountsList(
    accounts: widget.accounts,
    balances: widget.balances,
    showArchived: _showArchived,
    onToggleArchived: () => setState(() => _showArchived = !_showArchived),
  );

  @override
  Widget build(BuildContext context) {
    final compact = context.windowClass.isCompact;
    final bottom = MediaQuery.paddingOf(context).bottom + AppSpacing.s6;
    final main = <Widget>[
      _TotalCard(
        accounts: widget.accounts,
        balances: widget.balances,
        showAccounts: compact,
      ),
      const SizedBox(height: AppSpacing.s3),
      const _QuickActions(),
      if (compact) ...[
        const SizedBox(height: AppSpacing.s4),
        AppCard(child: _accountsList()),
      ],
      const SizedBox(height: AppSpacing.s4),
      _RecentCard(recent: widget.recent, lookups: widget.lookups),
    ];
    if (compact) {
      return ListView(
        key: const Key('finance-overview'),
        padding: EdgeInsets.only(bottom: bottom),
        children: main,
      );
    }
    return Row(
      key: const Key('finance-overview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 300,
          child: Container(
            key: const Key('finance-accounts-panel'),
            padding: const EdgeInsets.all(AppSpacing.s3),
            decoration: BoxDecoration(
              color: context.colors.surface1,
              borderRadius: const BorderRadius.all(Radius.circular(24)),
            ),
            child: SingleChildScrollView(child: _accountsList()),
          ),
        ),
        const SizedBox(width: AppSpacing.s4),
        Expanded(
          child: ListView(
            padding: EdgeInsets.only(bottom: bottom),
            children: main,
          ),
        ),
      ],
    );
  }
}

/// Список счетов: активные с балансами, «Добавить счёт», свёрнутый архив.
class _AccountsList extends StatelessWidget {
  const _AccountsList({
    required this.accounts,
    required this.balances,
    required this.showArchived,
    required this.onToggleArchived,
  });

  final List<Account> accounts;
  final FinanceBalances balances;
  final bool showArchived;
  final VoidCallback onToggleArchived;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final active = [
      for (final a in accounts)
        if (!a.archived) a,
    ];
    final archived = [
      for (final a in accounts)
        if (a.archived) a,
    ];
    Widget tile(Account a) => AccountTile(
      key: Key('account-tile-${a.id}'),
      account: a,
      balance: balances.of(a.id),
      onTap: () => context.go('/finance/accounts/${a.id}'),
    );
    return Column(
      key: const Key('accounts-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: AppSpacing.s2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'СЧЕТА',
                  style: t.overline.copyWith(color: c.textTertiary),
                ),
              ),
              IconButton(
                key: const Key('finance-open-goals'),
                tooltip: 'Цели',
                visualDensity: VisualDensity.compact,
                onPressed: () => context.go('/finance/goals'),
                icon: Icon(
                  LucideIcons.target,
                  size: 20,
                  color: c.textSecondary,
                ),
              ),
              IconButton(
                key: const Key('finance-open-analytics'),
                tooltip: 'Аналитика',
                visualDensity: VisualDensity.compact,
                onPressed: () => context.go('/finance/analytics'),
                icon: Icon(
                  LucideIcons.chartColumn,
                  size: 20,
                  color: c.textSecondary,
                ),
              ),
              TextButton.icon(
                key: const Key('finance-add-account'),
                onPressed: () => unawaited(showAccountEditor(context)),
                icon: const Icon(LucideIcons.plus, size: 16),
                label: const Text('Счёт'),
              ),
            ],
          ),
        ),
        if (active.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s2),
            child: Text(
              'Все счета в архиве.',
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          ),
        for (final a in active) tile(a),
        if (archived.isNotEmpty) ...[
          InkWell(
            key: const Key('accounts-archive-toggle'),
            onTap: onToggleArchived,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s2),
              child: Row(
                children: [
                  Icon(
                    showArchived
                        ? LucideIcons.chevronDown
                        : LucideIcons.chevronRight,
                    size: 14,
                    color: c.textTertiary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'АРХИВ · ${archived.length}',
                    style: t.overline.copyWith(color: c.textTertiary),
                  ),
                ],
              ),
            ),
          ),
          if (showArchived)
            for (final a in archived) tile(a),
        ],
      ],
    );
  }
}

/// Hero-карточка: общий баланс (02, 6.5) и, на телефоне, разбивка по счетам
/// в общем балансе.
class _TotalCard extends StatelessWidget {
  const _TotalCard({
    required this.accounts,
    required this.balances,
    required this.showAccounts,
  });

  final List<Account> accounts;
  final FinanceBalances balances;
  final bool showAccounts;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final counted = [
      for (final a in accounts)
        if (a.includeInTotal && !a.archived) a,
    ];
    final breakdown = counted
        .take(4)
        .map((a) => '${a.name} ${moneyText(balances.of(a.id))}')
        .join(' · ');
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ОБЩИЙ БАЛАНС',
            style: t.overline.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: AppSpacing.s1),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              moneyText(balances.total),
              key: const Key('finance-total'),
              style: t.display,
            ),
          ),
          if (showAccounts && breakdown.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s2),
            Text(
              breakdown,
              key: const Key('finance-breakdown'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    Widget action(String keyName, TransactionKind kind, String label) =>
        Expanded(
          child: ElevatedButton.icon(
            key: Key('finance-quick-$keyName'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
            ),
            onPressed: () =>
                unawaited(showTransactionEditor(context, kind: kind)),
            icon: Icon(transactionKindIcon(kind), size: 18),
            label: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
          ),
        );
    return Row(
      children: [
        action('expense', TransactionKind.expense, 'Расход'),
        const SizedBox(width: AppSpacing.s2),
        action('income', TransactionKind.income, 'Доход'),
        const SizedBox(width: AppSpacing.s2),
        action('transfer', TransactionKind.transfer, 'Перевод'),
      ],
    );
  }
}

class _RecentCard extends ConsumerWidget {
  const _RecentCard({required this.recent, required this.lookups});

  final List<FinanceTransaction> recent;
  final FinanceLookups lookups;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    return AppCard(
      key: const Key('finance-recent'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.s2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'ПОСЛЕДНИЕ ОПЕРАЦИИ',
                    style: t.overline.copyWith(color: c.textTertiary),
                  ),
                ),
                TextButton(
                  key: const Key('finance-all-ops'),
                  onPressed: () {
                    ref.read(transactionFilterProvider.notifier).reset();
                    context.go('/finance/transactions');
                  },
                  child: const Text('Все ›'),
                ),
              ],
            ),
          ),
          if (recent.isEmpty) ...[
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s2),
              child: Text(
                'Операций пока нет. Добавь первую — расход, доход или '
                'перевод.',
                key: const Key('finance-recent-empty'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  key: const Key('finance-empty-ops-add'),
                  onPressed: () => unawaited(showTransactionEditor(context)),
                  child: const Text('Добавить операцию'),
                ),
              ),
            ),
          ] else
            for (final tx in recent)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
                child: FeedRow(transaction: tx, lookups: lookups),
              ),
        ],
      ),
    );
  }
}
