import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/finance_money.dart';
import 'package:my_tasker/features/finance/presentation/transaction_actions.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_tiles.dart';

/// Лента операций слайверами: месяцы с липкими заголовками (доход / расход /
/// итого, 02, 4.10) и строки. Строка: тап — правка; на телефоне свайп
/// влево — удалить (снэкбар «Отменить»), на десктопе — меню «⋯».
List<Widget> transactionFeedSlivers(
  TransactionFeed feed,
  FinanceLookups lookups, {
  bool showAccount = true,
}) {
  final items = feed.items;
  final groups = <(String, List<FinanceTransaction>)>[];
  for (final t in items) {
    final month = t.moscowDay.substring(0, 7);
    if (groups.isNotEmpty && groups.last.$1 == month) {
      groups.last.$2.add(t);
    } else {
      groups.add((month, [t]));
    }
  }
  return [
    for (final (month, list) in groups)
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _MonthHeader(
              feed.months[month] ??
                  MonthTotals(month: month, income: 0, expense: 0),
            ),
          ),
          SliverList.builder(
            itemCount: list.length,
            itemBuilder: (context, i) => FeedRow(
              transaction: list[i],
              lookups: lookups,
              showAccount: showAccount,
            ),
          ),
        ],
      ),
  ];
}

class _MonthHeader extends SliverPersistentHeaderDelegate {
  const _MonthHeader(this.totals);

  final MonthTotals totals;

  static const double extent = 60;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  bool shouldRebuild(_MonthHeader oldDelegate) => oldDelegate.totals != totals;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final c = context.colors;
    final t = context.text;
    final month = totals.month;
    return Container(
      key: Key('month-header-$month'),
      color: c.bgBase,
      alignment: Alignment.bottomLeft,
      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  monthHeaderText(month),
                  style: t.overline.copyWith(color: c.textTertiary),
                ),
              ),
              Text(
                'Итого ${context.money(totals.net, signed: true)}',
                key: Key('month-net-$month'),
                style: t.numM.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Доход ${context.money(totals.income, signed: true)} · '
            'Расход ${context.money(-totals.expense)}',
            key: Key('month-sums-$month'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.caption.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Строка ленты с действиями (правка, удаление).
class FeedRow extends ConsumerWidget {
  const FeedRow({
    required this.transaction,
    required this.lookups,
    this.showAccount = true,
    super.key,
  });

  final FinanceTransaction transaction;
  final FinanceLookups lookups;
  final bool showAccount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = context.windowClass.isCompact;
    final zone = ref.watch(deviceTimeZoneProvider);
    final today = ref.watch(todayProvider);
    final c = context.colors;
    final tx = transaction;
    void edit() =>
        unawaited(showTransactionEditor(context, transactionId: tx.id));
    final tile = TransactionTile(
      transaction: tx,
      lookups: lookups,
      showAccount: showAccount,
      when: whenText(utcToWall(zone, tx.occurredAt), today),
      onTap: edit,
      menu: compact
          ? null
          : PopupMenuButton<String>(
              key: Key('tx-menu-${tx.id}'),
              tooltip: 'Действия',
              color: c.surface2,
              icon: Icon(
                LucideIcons.ellipsis,
                size: 18,
                color: c.textSecondary,
              ),
              onSelected: (action) {
                if (action == 'edit') {
                  edit();
                } else {
                  unawaited(deleteTransactionWithUndo(context, ref, tx));
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  key: Key('tx-menu-edit-${tx.id}'),
                  value: 'edit',
                  child: const Text('Изменить'),
                ),
                PopupMenuItem(
                  key: Key('tx-menu-delete-${tx.id}'),
                  value: 'delete',
                  child: const Text('Удалить'),
                ),
              ],
            ),
    );
    if (!compact) return tile;
    return Dismissible(
      key: ValueKey('dismiss-tx-${tx.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: c.surface3,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
        child: Icon(LucideIcons.trash2, size: 22, color: c.textSecondary),
      ),
      confirmDismiss: (_) async {
        await deleteTransactionWithUndo(context, ref, tx);
        // Строка исчезнет, когда обновится лента: сам виджет остаётся.
        return false;
      },
      child: tile,
    );
  }
}
