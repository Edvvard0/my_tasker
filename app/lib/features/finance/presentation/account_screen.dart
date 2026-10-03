import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';
import 'package:my_tasker/features/finance/presentation/account_actions.dart';
import 'package:my_tasker/features/finance/presentation/account_editor.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/finance_money.dart';
import 'package:my_tasker/features/finance/presentation/reconcile_screen.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_states.dart';
import 'package:my_tasker/features/finance/presentation/widgets/transaction_feed.dart';

/// «Счёт»: баланс, действие «Сверить баланс», операции этого счёта с
/// месячными итогами; правка, архив и удаление — в меню.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({required this.accountId, super.key});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lookups = ref.watch(financeLookupsProvider);
    final feed = ref.watch(
      transactionFeedProvider(TransactionFilter(accountId: accountId)),
    );
    final account = lookups.value?.account(accountId);
    final Widget body;
    if ((lookups.hasError && !lookups.hasValue) ||
        (feed.hasError && !feed.hasValue)) {
      body = const FinanceErrorNotice();
    } else if (!lookups.hasValue || !feed.hasValue) {
      body = const ListSkeleton(rows: 4);
    } else if (account == null) {
      body = EmptyState(
        key: const Key('account-missing'),
        icon: LucideIcons.wallet,
        title: 'Счёт не найден',
        message: 'Возможно, его удалили на другом устройстве.',
        action: ElevatedButton(
          onPressed: () => context.go('/finance'),
          child: const Text('К финансам'),
        ),
      );
    } else {
      body = _AccountBody(
        account: account,
        lookups: lookups.requireValue,
        feed: feed.requireValue,
      );
    }
    return ScreenScaffold(
      title: account?.name ?? 'Счёт',
      parentLabel: 'Финансы',
      onBack: () => context.go('/finance'),
      scrollable: false,
      actions: [
        if (account != null)
          IconButton(
            key: const Key('account-edit'),
            tooltip: 'Изменить счёт',
            onPressed: () =>
                unawaited(showAccountEditor(context, accountId: account.id)),
            icon: const Icon(LucideIcons.pencil, size: 22),
          ),
        if (account != null) _AccountMenu(account: account),
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

class _AccountMenu extends ConsumerWidget {
  const _AccountMenu({required this.account});

  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
    key: const Key('account-menu'),
    tooltip: 'Ещё',
    color: context.colors.surface2,
    icon: const Icon(LucideIcons.ellipsis, size: 22),
    onSelected: (action) async {
      switch (action) {
        case 'archive':
          await toggleArchiveAccount(context, ref, account);
        case 'delete':
          if (await deleteAccountWithConfirm(context, ref, account) &&
              context.mounted) {
            context.go('/finance');
          }
      }
    },
    itemBuilder: (_) => [
      PopupMenuItem(
        key: const Key('account-menu-archive'),
        value: 'archive',
        child: Text(account.archived ? 'Вернуть из архива' : 'В архив'),
      ),
      const PopupMenuItem(
        key: Key('account-menu-delete'),
        value: 'delete',
        child: Text('Удалить'),
      ),
    ],
  );
}

class _AccountBody extends ConsumerWidget {
  const _AccountBody({
    required this.account,
    required this.lookups,
    required this.feed,
  });

  final Account account;
  final FinanceLookups lookups;
  final TransactionFeed feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final balance = ref.watch(accountBalanceProvider(account.id)).value ?? 0;
    final adjustments =
        ref.watch(accountAdjustmentsProvider(account.id)).value ?? const [];
    final zone = ref.watch(deviceTimeZoneProvider);
    final today = ref.watch(todayProvider);
    final bottom = MediaQuery.paddingOf(context).bottom + AppSpacing.s6;
    final last = adjustments.lastOrNull;
    final compact = context.windowClass.isCompact;
    return CustomScrollView(
      key: const Key('account-scroll'),
      slivers: [
        SliverToBoxAdapter(
          child: AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      accountKindIcon(account.kind),
                      size: 18,
                      color: c.textSecondary,
                    ),
                    const SizedBox(width: AppSpacing.s2),
                    Expanded(
                      child: Text(
                        accountSubtitle(account),
                        style: t.bodyS.copyWith(color: c.textSecondary),
                      ),
                    ),
                    if (account.archived)
                      const StatusPill(
                        key: Key('account-archived'),
                        label: 'В архиве',
                        tone: StatusTone.neutral,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s3),
                Text(
                  'БАЛАНС',
                  style: t.overline.copyWith(color: c.textTertiary),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.money(balance),
                    key: const Key('account-balance'),
                    style: compact ? t.kpi : t.display,
                  ),
                ),
                if (!account.includeInTotal)
                  Text(
                    'Не входит в общий баланс',
                    key: const Key('account-not-in-total'),
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                if (account.creditLimit != null)
                  Text(
                    'Кредитный лимит ${context.money(account.creditLimit!)}',
                    key: const Key('account-limit'),
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                if (last != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s1),
                    child: Text(
                      'Сверка ${shortDateText(utcToWall(zone, last.checkedAt), today)}: '
                      '${adjustmentText(last.adjustment, money: context.money).toLowerCase()}',
                      key: const Key('account-last-checkpoint'),
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  ),
                const SizedBox(height: AppSpacing.s4),
                Wrap(
                  spacing: AppSpacing.s2,
                  runSpacing: AppSpacing.s2,
                  children: [
                    FilledButton.icon(
                      key: const Key('account-reconcile'),
                      onPressed: () => context.go(
                        '/finance/accounts/${account.id}/reconcile',
                      ),
                      icon: const Icon(LucideIcons.scale, size: 18),
                      label: const Text('Сверить баланс'),
                    ),
                    ElevatedButton.icon(
                      key: const Key('account-add-tx'),
                      onPressed: () => unawaited(
                        showTransactionEditor(context, accountId: account.id),
                      ),
                      icon: const Icon(LucideIcons.plus, size: 18),
                      label: const Text('Операция'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (feed.items.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s6),
              child: EmptyState(
                key: const Key('account-empty'),
                icon: LucideIcons.receipt,
                title: 'Операций нет',
                message:
                    'По этому счёту пока ничего не записано. Добавь первую '
                    'операцию.',
                action: ElevatedButton(
                  key: const Key('account-empty-add'),
                  onPressed: () => unawaited(
                    showTransactionEditor(context, accountId: account.id),
                  ),
                  child: const Text('Добавить операцию'),
                ),
              ),
            ),
          )
        else ...[
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.s2)),
          ...transactionFeedSlivers(feed, lookups, showAccount: false),
        ],
        SliverToBoxAdapter(child: SizedBox(height: bottom)),
      ],
    );
  }
}
