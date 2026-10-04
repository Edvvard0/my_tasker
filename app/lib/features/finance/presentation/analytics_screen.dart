import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';

/// «Аналитика»: доход и расход по месяцам (Москва), категории с
/// подкатегориями, топ мерчантов, динамика общего баланса. Переводы,
/// черновики и движение по долгам в доход и расход не входят.
class AnalyticsScreen extends ConsumerWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('analytics-screen'),
      title: 'Аналитика',
      parentLabel: 'Финансы',
      onBack: () => financeBack(context),
      child: FinanceBuilder(builder: (context, data) => _Body(data: data)),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.data});

  final FinanceData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final state = ref.watch(analyticsStateProvider);
    final notifier = ref.read(analyticsStateProvider.notifier);
    final format = ref.watch(amountFormatProvider);
    final months = monthsBack(data.thisMonth, state.months);
    final selected = state.month != null && months.contains(state.month)
        ? state.month!
        : data.thisMonth;
    final totals = {
      for (final m in monthlyTotals(data.transactions)) m.month: m,
    };
    final bars = [
      for (final m in months)
        MonthBar(
          month: m,
          income: totals[m]?.income ?? 0,
          expense: totals[m]?.expense ?? 0,
        ),
    ];
    final chosen = totals[selected];
    final income = chosen?.income ?? 0;
    final expense = chosen?.expense ?? 0;
    final period = monthPeriod(selected);
    final breakdown = categoryBreakdown(
      data.transactions,
      data.categories,
      state.kind,
      period: period,
    );
    final merchants = topMerchants(
      data.transactions,
      kind: state.kind,
      period: period,
    );
    final dates = [for (final m in months.take(months.length - 1)) monthEnd(m)];
    final dynamics = balanceDynamics(
      data.accounts,
      data.transactions,
      data.checkpoints,
      [...dates, data.today],
    );
    final hasAny = data.transactions.any(countsInAnalytics);
    if (!hasAny && data.accounts.isEmpty) {
      return const EmptyState(
        key: Key('analytics-empty'),
        icon: LucideIcons.chartColumn,
        title: 'Пока нечего анализировать',
        message: 'Добавьте счёт и первые операции: графики появятся сами.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChipRow(
          children: [
            for (final n in const [6, 12])
              FilterPill(
                key: Key('analytics-months-$n'),
                label: '$n мес',
                selected: state.months == n,
                onTap: () => notifier.set(state.copyWith(months: n)),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'ДОХОД И РАСХОД ПО МЕСЯЦАМ',
                      style: t.overline.copyWith(color: c.textSecondary),
                    ),
                  ),
                  _legend(context, AppColors.chartSeries[1], 'доход'),
                  const SizedBox(width: AppSpacing.s3),
                  _legend(context, AppColors.chartSeries[3], 'расход'),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              MonthBars(
                months: bars,
                currentMonth: data.thisMonth,
                selected: selected,
                onSelect: (m) => notifier.set(state.copyWith(month: m)),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                monthYearTitle(selected).toUpperCase(),
                key: const Key('analytics-month-title'),
                style: t.overline.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s2),
              _kv(context, 'Доход', format.signed(income), 'analytics-income'),
              _kv(context, 'Расход', format.full(expense), 'analytics-expense'),
              _kv(
                context,
                'Итог',
                format.signed(income - expense),
                'analytics-net',
                strong: true,
              ),
            ],
          ),
        ),
        const FinanceSection(title: 'Категории'),
        ChipRow(
          children: [
            for (final k in const [TxKind.expense, TxKind.income])
              FilterPill(
                key: Key('analytics-kind-${k.wire}'),
                label: k == TxKind.expense ? 'Расходы' : 'Доходы',
                selected: state.kind == k,
                onTap: () => notifier.set(state.copyWith(kind: k)),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        if (breakdown.groups.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Text(
              'Нет операций за этот месяц',
              key: const Key('analytics-categories-empty'),
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          )
        else
          AppCard(
            child: Column(
              children: [
                for (final g in breakdown.groups) ...[
                  BarRow(
                    key: Key('analytics-cat-${g.categoryId ?? 'none'}'),
                    label: data.categoryTitle(g.categoryId),
                    amount: g.total,
                    fraction: breakdown.groups.first.total == 0
                        ? 0
                        : g.total / breakdown.groups.first.total,
                    percent: breakdown.total == 0
                        ? 0
                        : g.total * 100 ~/ breakdown.total,
                  ),
                  for (final k in g.children)
                    BarRow(
                      key: Key('analytics-cat-${k.categoryId}'),
                      label:
                          data.categoryById[k.categoryId]?.name ??
                          'Без категории',
                      amount: k.total,
                      fraction: breakdown.groups.first.total == 0
                          ? 0
                          : k.total / breakdown.groups.first.total,
                      percent: breakdown.total == 0
                          ? 0
                          : k.total * 100 ~/ breakdown.total,
                      indent: true,
                    ),
                ],
              ],
            ),
          ),
        const FinanceSection(title: 'Топ мерчантов'),
        if (merchants.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Text(
              'Контрагентов за этот месяц нет',
              key: const Key('analytics-merchants-empty'),
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          )
        else
          ListCard(
            children: [
              for (var i = 0; i < merchants.length; i++)
                ListTile(
                  key: Key('analytics-merchant-$i'),
                  title: Text(merchants[i].merchant, style: t.body),
                  subtitle: Text(
                    '${merchants[i].count} ${plural(merchants[i].count, 'операция', 'операции', 'операций')}',
                    style: t.caption.copyWith(color: c.textSecondary),
                  ),
                  trailing: AmountText(merchants[i].total, style: t.numM),
                ),
            ],
          ),
        const FinanceSection(title: 'Динамика общего баланса'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BalanceLine(
                key: const Key('analytics-dynamics'),
                values: [for (final p in dynamics) p.total],
                height: 96,
              ),
              const SizedBox(height: AppSpacing.s2),
              Row(
                children: [
                  Text(
                    monthShortLabel(months.first),
                    style: t.caption.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  AmountText(
                    dynamics.first.total,
                    style: t.numS.copyWith(color: c.textSecondary),
                  ),
                  const Spacer(),
                  Text(
                    'сейчас',
                    style: t.caption.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  AmountText(
                    dynamics.last.total,
                    style: t.numS,
                    textKey: const Key('analytics-dynamics-now'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const FinanceSection(title: 'Остатки по счетам'),
        ListCard(
          children: [
            for (final a in data.activeAccounts)
              ListTile(
                key: Key('analytics-account-${a.id}'),
                title: Text(a.name, style: t.body),
                trailing: AmountText(data.balanceOf(a.id), style: t.numM),
              ),
            if (data.activeAccounts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s4),
                child: Text(
                  'Счетов нет',
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _legend(BuildContext context, Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 4),
      Text(
        label,
        style: context.text.caption.copyWith(
          color: context.colors.textSecondary,
        ),
      ),
    ],
  );

  Widget _kv(
    BuildContext context,
    String label,
    String value,
    String key, {
    bool strong = false,
  }) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: t.bodyS.copyWith(color: c.textSecondary)),
          ),
          Text(value, key: Key(key), style: strong ? t.numL : t.numM),
        ],
      ),
    );
  }
}
