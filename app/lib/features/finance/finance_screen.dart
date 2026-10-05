import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/account_editor.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/finance/presentation/goals_screen.dart';
import 'package:my_tasker/features/finance/presentation/lock_settings_sheet.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show KpiRow, KpiTile, WorkLinkRow;

/// «Финансы» (02, 6.5): общий баланс, плитки «мне должны / кредитки /
/// ожидается», цель с прогрессом, доходы и расходы по месяцам, категории
/// месяца, последние операции и переходы в подразделы.
class FinanceScreen extends ConsumerWidget {
  const FinanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Засев предустановленных категорий после первой синхронизации.
    ref.watch(financeBootstrapProvider);
    final hidden = ref.watch(hideAmountsProvider);
    return ScreenScaffold(
      key: const Key('finance-overview'),
      title: 'Финансы',
      actions: [
        IconButton(
          key: const Key('finance-hide-amounts'),
          tooltip: hidden ? 'Показать суммы' : 'Скрыть суммы',
          onPressed: () =>
              ref.read(hideAmountsProvider.notifier).set(hidden: !hidden),
          icon: Icon(hidden ? LucideIcons.eyeOff : LucideIcons.eye, size: 22),
        ),
        IconButton(
          key: const Key('finance-privacy'),
          tooltip: 'Приватность',
          onPressed: () => showLockSettings(context),
          icon: const Icon(LucideIcons.shield, size: 22),
        ),
        IconButton(
          key: const Key('finance-add-tx'),
          tooltip: 'Новая операция',
          onPressed: () => showTransactionEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: FinanceBuilder(
        builder: (context, data) => FinanceOverviewBody(data: data),
      ),
    );
  }
}

/// Содержимое обзора (используется и в golden-тесте).
class FinanceOverviewBody extends ConsumerWidget {
  const FinanceOverviewBody({required this.data, super.key});

  final FinanceData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = context.windowClass.isCompact;
    if (data.accounts.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EmptyState(
            key: const Key('finance-empty'),
            icon: LucideIcons.wallet,
            title: 'Начните со счёта',
            message:
                'Добавьте наличные, карту или вклад — потом записывайте '
                'траты и доходы, а баланс посчитается сам.',
            action: addAccountButton(context),
          ),
          _Links(data: data),
        ],
      );
    }
    final hero = _Hero(data: data);
    final kpis = _Kpis(data: data);
    final goal = _GoalBlock(data: data);
    final months = _MonthsCard(data: data);
    final categories = _CategoriesCard(data: data);
    final recent = _Recent(data: data);
    const gap = SizedBox(height: AppSpacing.s3);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compact) ...[
          hero,
          gap,
          kpis,
          gap,
          goal,
          gap,
          months,
          gap,
          categories,
          recent,
        ] else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 6, child: hero),
              const SizedBox(width: AppSpacing.s3),
              Expanded(flex: 6, child: kpis),
            ],
          ),
          gap,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: goal),
              const SizedBox(width: AppSpacing.s3),
              Expanded(child: months),
            ],
          ),
          gap,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: categories),
              const SizedBox(width: AppSpacing.s3),
              Expanded(child: recent),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.s3),
        _Links(data: data),
        if (data.problems.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s3),
          _Problems(data: data),
        ],
      ],
    );
  }
}

class _Hero extends ConsumerWidget {
  const _Hero({required this.data});

  final FinanceData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final format = ref.watch(amountFormatProvider);
    final months = monthsBack(data.thisMonth, 6);
    final dynamics = balanceDynamics(
      data.accounts,
      data.transactions,
      data.checkpoints,
      [for (final m in months.take(months.length - 1)) monthEnd(m), data.today],
    );
    final inTotal = [
      for (final a in data.activeAccounts)
        if (a.includeInTotal) a,
    ];
    return InkWell(
      key: const Key('finance-hero'),
      borderRadius: AppRadii.borderL,
      onTap: () => context.push('/finance/accounts'),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
                textKey: const Key('finance-total'),
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            BalanceLine(values: [for (final p in dynamics) p.total]),
            const SizedBox(height: AppSpacing.s2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    [
                      for (final a in inTotal.take(3))
                        '${a.name} ${format.short(data.balanceOf(a.id))}',
                    ].join(' · '),
                    style: t.caption.copyWith(color: c.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(LucideIcons.chevronRight, size: 18, color: c.textTertiary),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Kpis extends ConsumerWidget {
  const _Kpis({required this.data});

  final FinanceData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final format = ref.watch(amountFormatProvider);
    final owedCount = [
      for (final d in data.debts)
        if (data.debtSummary.stateOf(d.id)?.direction ==
                DebtDirection.owedToMe &&
            data.debtSummary.stateOf(d.id)!.remaining > 0)
          d,
    ].length;
    final cards = [
      for (final a in data.activeAccounts)
        if (a.kind == AccountKind.creditCard) a,
    ];
    final clients = data.receivables.clients.length;
    return KpiRow(
      tiles: [
        KpiTile(
          key: const Key('kpi-owed'),
          label: 'Мне должны',
          value: format.short(data.debtSummary.owedToMe),
          caption: owedCount == 0
              ? 'долгов нет'
              : '$owedCount ${plural(owedCount, 'долг', 'долга', 'долгов')}',
          onTap: () => context.push('/finance/debts'),
        ),
        KpiTile(
          key: const Key('kpi-credit'),
          label: 'Кредитки',
          value: format.short(data.creditCardsBalance),
          caption: cards.isEmpty
              ? 'нет карт'
              : (cards.length == 1
                    ? cards.first.name
                    : '${cards.length} карты'),
          onTap: () => context.push('/finance/accounts'),
        ),
        KpiTile(
          key: const Key('kpi-expected'),
          label: 'Ожидается',
          value: format.short(data.receivables.total),
          caption: clients == 0
              ? 'от заказчиков'
              : '$clients ${plural(clients, 'заказчик', 'заказчика', 'заказчиков')}',
          onTap: () => context.push('/finance/work'),
        ),
      ],
    );
  }
}

class _GoalBlock extends StatelessWidget {
  const _GoalBlock({required this.data});

  final FinanceData data;

  @override
  Widget build(BuildContext context) {
    final goals = [
      for (final g in data.goals)
        if (!g.archived) g,
    ];
    if (goals.isEmpty) {
      return AppCard(
        key: const Key('finance-no-goal'),
        child: Row(
          children: [
            Icon(
              LucideIcons.target,
              size: 20,
              color: context.colors.textSecondary,
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(child: Text('Цели пока нет', style: context.text.body)),
            TextButton(
              key: const Key('finance-add-goal'),
              onPressed: () => context.push('/finance/goals'),
              child: const Text('Задать цель'),
            ),
          ],
        ),
      );
    }
    return GoalCard(data: data, goal: goals.first);
  }
}

class _MonthsCard extends ConsumerWidget {
  const _MonthsCard({required this.data});

  final FinanceData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final format = ref.watch(amountFormatProvider);
    final months = monthsBack(data.thisMonth, 6);
    final totals = {
      for (final m in monthlyTotals(data.transactions)) m.month: m,
    };
    final current = totals[data.thisMonth];
    return InkWell(
      key: const Key('finance-months'),
      borderRadius: AppRadii.borderL,
      onTap: () => context.push('/finance/analytics'),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    monthYearTitle(data.thisMonth)
                        .split(' ')
                        .first
                        .toUpperCase(),
                    style: t.overline.copyWith(color: c.textSecondary),
                  ),
                ),
                Text(
                  '${format.signed(current?.income ?? 0)}  '
                  '${format.full(-(current?.expense ?? 0))}',
                  key: const Key('finance-month-sums'),
                  style: t.numM,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            MonthBars(
              months: [
                for (final m in months)
                  MonthBar(
                    month: m,
                    income: totals[m]?.income ?? 0,
                    expense: totals[m]?.expense ?? 0,
                  ),
              ],
              currentMonth: data.thisMonth,
              height: 72,
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoriesCard extends StatelessWidget {
  const _CategoriesCard({required this.data});

  final FinanceData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final b = categoryBreakdown(
      data.transactions,
      data.categories,
      TxKind.expense,
      period: monthPeriod(data.thisMonth),
    );
    final top = b.groups.take(4).toList();
    return InkWell(
      key: const Key('finance-categories-card'),
      borderRadius: AppRadii.borderL,
      onTap: () => context.push('/finance/analytics'),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'РАСХОДЫ ПО КАТЕГОРИЯМ',
              style: t.overline.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s2),
            if (top.isEmpty)
              Text(
                'За этот месяц расходов нет',
                key: const Key('finance-no-expenses'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              )
            else
              for (final g in top)
                BarRow(
                  label: data.categoryTitle(g.categoryId),
                  amount: g.total,
                  fraction: top.first.total == 0
                      ? 0
                      : g.total / top.first.total,
                  percent: b.total == 0 ? 0 : g.total * 100 ~/ b.total,
                ),
          ],
        ),
      ),
    );
  }
}

class _Recent extends ConsumerWidget {
  const _Recent({required this.data});

  final FinanceData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = data.transactions.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FinanceSection(
          title: 'Последние операции',
          trailing: TextButton(
            key: const Key('finance-all-tx'),
            onPressed: () {
              ref.read(txFilterProvider.notifier).reset();
              unawaited(context.push('/finance/transactions'));
            },
            child: const Text('Все ›'),
          ),
        ),
        if (latest.isEmpty)
          AppCard(
            key: const Key('finance-no-tx'),
            child: Text(
              'Операций пока нет',
              style: context.text.bodyS.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
          )
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final tx in latest)
                  TransactionTile(
                    data: data,
                    tx: tx,
                    onTap: () => showTransactionEditor(context, txId: tx.id),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Links extends ConsumerWidget {
  const _Links({required this.data});

  final FinanceData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unconfirmed = data.transactions.where((t) => !t.isConfirmed).length;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          WorkLinkRow(
            key: const Key('finance-link-accounts'),
            icon: LucideIcons.wallet,
            label: 'Счета',
            trailingText: data.accounts.isEmpty
                ? null
                : '${data.activeAccounts.length}',
            onTap: () => context.push('/finance/accounts'),
          ),
          WorkLinkRow(
            key: const Key('finance-link-transactions'),
            icon: LucideIcons.receipt,
            label: 'Операции',
            onTap: () {
              ref.read(txFilterProvider.notifier).reset();
              unawaited(context.push('/finance/transactions'));
            },
          ),
          if (unconfirmed > 0)
            WorkLinkRow(
              key: const Key('finance-link-unconfirmed'),
              icon: LucideIcons.clipboardCheck,
              label: 'Требуют проверки',
              trailingText: '$unconfirmed',
              onTap: () {
                ref
                    .read(txFilterProvider.notifier)
                    .set(const TxFilter(onlyUnconfirmed: true));
                unawaited(context.push('/finance/transactions'));
              },
            ),
          WorkLinkRow(
            key: const Key('finance-link-categories'),
            icon: LucideIcons.tags,
            label: 'Категории',
            onTap: () => context.push('/finance/categories'),
          ),
          WorkLinkRow(
            key: const Key('finance-link-debts'),
            icon: LucideIcons.handCoins,
            label: 'Долги',
            onTap: () => context.push('/finance/debts'),
          ),
          WorkLinkRow(
            key: const Key('finance-link-goals'),
            icon: LucideIcons.target,
            label: 'Цели',
            onTap: () => context.push('/finance/goals'),
          ),
          WorkLinkRow(
            key: const Key('finance-link-analytics'),
            icon: LucideIcons.chartColumn,
            label: 'Аналитика',
            onTap: () => context.push('/finance/analytics'),
          ),
          WorkLinkRow(
            key: const Key('finance-link-banks'),
            icon: LucideIcons.landmark,
            label: 'Банки',
            onTap: () => context.push('/finance/banks'),
          ),
          WorkLinkRow(
            key: const Key('finance-link-work'),
            icon: LucideIcons.briefcase,
            label: 'Ожидаемые из «Работы»',
            onTap: () => context.push('/finance/work'),
          ),
        ],
      ),
    );
  }
}

/// Человеческое описание нарушения целостности (spec 8).
String problemText(FinanceProblem p) => switch (p.code) {
  'category_parent_invalid' =>
    'У подкатегории неверный родитель (глубина или вид).',
  'category_kind_mismatch' => 'Вид операции не совпадает с видом категории.',
  'duplicate_external_id' => 'Возможный дубль банковской операции.',
  'repayment_transaction_mismatch' =>
    'Погашение ссылается на операцию другого долга.',
  'over_repaid' => 'Долг погашен с переплатой.',
  'work_payment_over_linked' =>
    'К платежу Работы привязано доходов больше его суммы.',
  _ => 'Нарушение данных: ${p.code}',
};

class _Problems extends StatelessWidget {
  const _Problems({required this.data});

  final FinanceData data;

  @override
  Widget build(BuildContext context) {
    final shown = data.problems.take(3).toList();
    final more = data.problems.length - shown.length;
    return FinanceWarning(
      key: const Key('finance-problems'),
      text: [
        'Нашлись расхождения в данных (${data.problems.length}):',
        for (final p in shown) '• ${problemText(p)}',
        if (more > 0) 'и ещё $more',
      ].join('\n'),
    );
  }
}
