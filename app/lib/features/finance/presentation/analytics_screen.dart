import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/analytics_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/widgets/charts.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_pickers.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_states.dart';
import 'package:my_tasker/features/finance/presentation/widgets/segmented_pill.dart';

/// Глоссарий метрик (spec 5.1): подсказка «что это значит».
const List<(String, String)> analyticsGlossary = [
  (
    'Доход месяца',
    'Сумма подтверждённых доходов за месяц (по московскому времени). '
        'Переводы между своими счетами и движение денег по долгам сюда не '
        'входят.',
  ),
  (
    'Расход месяца',
    'То же для расходов: переводы и выдача или возврат долгов расходом не '
        'считаются.',
  ),
  ('Итог месяца', 'Доход минус расход за месяц, со знаком.'),
  (
    'Общий баланс',
    'Сумма балансов счетов, отмеченных «Учитывать в общем балансе». '
        'Кредитная карта — обычный счёт с балансом.',
  ),
  (
    'Мне должны / Я должен',
    'Сумма открытых остатков личных долгов по направлению.',
  ),
];

/// Открывает подсказку с глоссарием метрик.
Future<void> showAnalyticsGlossary(BuildContext context) =>
    showPickerSheet<void>(
      context,
      title: 'Что считаем',
      builder: (sheetContext) {
        final c = sheetContext.colors;
        final t = sheetContext.text;
        return Column(
          key: const Key('analytics-glossary-sheet'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (term, text) in analyticsGlossary)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s2,
                  vertical: AppSpacing.s2,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(term, style: t.bodyStrong),
                    const SizedBox(height: 2),
                    Text(text, style: t.bodyS.copyWith(color: c.textSecondary)),
                  ],
                ),
              ),
          ],
        );
      },
    );

/// «Аналитика» (02, 5.3, spec 5): период, доход / расход / итог по месяцам,
/// категории с подкатегориями, топ мерчантов, остатки по счетам и динамика
/// общего баланса. Графики — серые с одним синим акцентом.
class AnalyticsScreen extends ConsumerWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(analyticsReportProvider);
    final lookups = ref.watch(financeLookupsProvider);
    final accounts = ref.watch(accountsProvider);
    final failed = [
      report,
      lookups,
      accounts,
    ].any((v) => v.hasError && !v.hasValue);
    final Widget body;
    if (failed) {
      body = const SingleChildScrollView(child: FinanceErrorNotice());
    } else if (!report.hasValue || !lookups.hasValue || !accounts.hasValue) {
      body = const SingleChildScrollView(child: ListSkeleton());
    } else {
      body = _AnalyticsBody(
        report: report.requireValue,
        lookups: lookups.requireValue,
        accounts: accounts.requireValue,
      );
    }
    return ScreenScaffold(
      title: 'Аналитика',
      parentLabel: 'Финансы',
      onBack: () => context.go('/finance'),
      scrollable: false,
      actions: [
        IconButton(
          key: const Key('analytics-glossary'),
          tooltip: 'Что считаем',
          onPressed: () => showAnalyticsGlossary(context),
          icon: const Icon(LucideIcons.info, size: 22),
        ),
      ],
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
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

class _AnalyticsBody extends ConsumerStatefulWidget {
  const _AnalyticsBody({
    required this.report,
    required this.lookups,
    required this.accounts,
  });

  final AnalyticsReport report;
  final FinanceLookups lookups;
  final List<Account> accounts;

  @override
  ConsumerState<_AnalyticsBody> createState() => _AnalyticsBodyState();
}

class _AnalyticsBodyState extends ConsumerState<_AnalyticsBody> {
  CategoryKind _kind = CategoryKind.expense;
  final Set<String> _expanded = {};

  AnalyticsReport get _report => widget.report;

  Widget _periodSelector() => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.s3),
    child: SegmentedPill<AnalyticsPreset>(
      keyPrefix: 'analytics-period',
      options: {for (final p in AnalyticsPreset.values) p: p.label},
      selected: _report.preset,
      onChanged: (p) => ref.read(analyticsPresetProvider.notifier).select(p),
    ),
  );

  Widget _card(String keyName, String title, List<Widget> children) {
    final c = context.colors;
    final t = context.text;
    return AppCard(
      key: Key(keyName),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s3),
            child: Text(
              title,
              style: t.overline.copyWith(color: c.textTertiary),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _kpi(String keyName, String label, int value, {bool signed = false}) {
    final c = context.colors;
    final t = context.text;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.caption.copyWith(color: c.textTertiary)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              moneyText(value, signed: signed),
              key: Key(keyName),
              style: t.numL.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: context.text.bodyS.copyWith(color: c.textSecondary)),
      ],
    );
  }

  Widget _hintButton(String keyName, String text) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      key: Key(keyName),
      onPressed: () => showAnalyticsGlossary(context),
      icon: const Icon(LucideIcons.info, size: 16),
      label: Text(text),
    ),
  );

  Widget _monthsCard() {
    final report = _report;
    return _card('analytics-months', 'ДОХОД И РАСХОД ПО МЕСЯЦАМ', [
      Row(
        children: [
          _kpi('analytics-income', 'Доход', report.income),
          const SizedBox(width: AppSpacing.s2),
          _kpi('analytics-expense', 'Расход', report.expense),
          const SizedBox(width: AppSpacing.s2),
          _kpi('analytics-net', 'Итог', report.net, signed: true),
        ],
      ),
      const SizedBox(height: AppSpacing.s4),
      if (report.hasOperations) ...[
        Wrap(
          spacing: AppSpacing.s4,
          runSpacing: AppSpacing.s1,
          children: [
            _legendDot(incomeBarColor, 'Доход'),
            _legendDot(expenseBarColor, 'Расход'),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),
        MonthBarsChart(
          months: report.months,
          currentMonth: report.today.substring(0, 7),
        ),
      ] else
        const KeyedSubtree(key: Key('analytics-empty'), child: EmptyChart()),
      _hintButton('analytics-hint-income', 'Что такое доход месяца?'),
    ]);
  }

  String _categoryName(String? id) =>
      id == null ? 'Без категории' : widget.lookups.category(id)?.name ?? '—';

  Widget _amountRow({
    required String label,
    required int total,
    required int grand,
    required int count,
    required double fraction,
    required bool highlight,
    Key? key,
    VoidCallback? onTap,
    bool child = false,
    Widget? trailingIcon,
  }) {
    final c = context.colors;
    final t = context.text;
    final share = grand <= 0 ? 0 : total * 10000 ~/ grand;
    return InkWell(
      key: key,
      borderRadius: AppRadii.borderM,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(
          left: child ? AppSpacing.s6 : 0,
          top: AppSpacing.s2,
          bottom: AppSpacing.s2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ?trailingIcon,
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: child
                        ? t.bodyS.copyWith(color: c.textSecondary)
                        : t.bodyStrong,
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                Text(
                  moneyText(total),
                  style: t.numM.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: AppSpacing.s2),
                SizedBox(
                  width: 56,
                  child: Text(
                    '${basisPointsText(share)} %',
                    textAlign: TextAlign.end,
                    style: t.caption.copyWith(color: c.textTertiary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ShareBar(fraction: fraction, highlight: highlight),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '$count ${count == 1 ? 'операция' : 'операций'}',
                style: t.caption.copyWith(color: c.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoriesCard() {
    final c = context.colors;
    final t = context.text;
    final expense = _kind == CategoryKind.expense;
    final breakdown = expense ? _report.expenses : _report.incomes;
    final groups = breakdown.groups;
    final biggest = groups.isEmpty ? 1 : groups.first.total;
    return _card('analytics-categories', 'ПО КАТЕГОРИЯМ', [
      SegmentedPill<CategoryKind>(
        keyPrefix: 'analytics-kind',
        options: {for (final k in CategoryKind.values) k: '${k.label}ы'},
        selected: _kind,
        onChanged: (k) => setState(() => _kind = k),
      ),
      const SizedBox(height: AppSpacing.s3),
      if (groups.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Text(
            expense
                ? 'Расходов за этот период нет.'
                : 'Доходов за этот период нет.',
            key: const Key('analytics-categories-empty'),
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
        )
      else
        for (var i = 0; i < groups.length; i++) ...[
          () {
            final g = groups[i];
            final id = g.categoryId ?? 'none';
            final open = _expanded.contains(id);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _amountRow(
                  key: Key('analytics-category-$id'),
                  label: _categoryName(g.categoryId),
                  total: g.total,
                  grand: breakdown.total,
                  count: g.count,
                  fraction: g.total / biggest,
                  highlight: i == 0,
                  onTap: g.children.isEmpty
                      ? null
                      : () => setState(
                          () => open ? _expanded.remove(id) : _expanded.add(id),
                        ),
                  trailingIcon: g.children.isEmpty
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(
                            open
                                ? LucideIcons.chevronDown
                                : LucideIcons.chevronRight,
                            size: 14,
                            color: c.textTertiary,
                          ),
                        ),
                ),
                if (open) ...[
                  if (g.own > 0)
                    _amountRow(
                      key: Key('analytics-category-$id-own'),
                      label: 'Без подкатегории',
                      total: g.own,
                      grand: breakdown.total,
                      count:
                          g.count - g.children.fold(0, (s, x) => s + x.count),
                      fraction: g.own / biggest,
                      highlight: false,
                      child: true,
                    ),
                  for (final child in g.children)
                    _amountRow(
                      key: Key('analytics-category-${child.categoryId}'),
                      label: _categoryName(child.categoryId),
                      total: child.total,
                      grand: breakdown.total,
                      count: child.count,
                      fraction: child.total / biggest,
                      highlight: false,
                      child: true,
                    ),
                ],
              ],
            );
          }(),
        ],
    ]);
  }

  Widget _merchantsCard() {
    final c = context.colors;
    final t = context.text;
    final expense = _kind == CategoryKind.expense;
    final merchants = expense
        ? _report.merchantsExpense
        : _report.merchantsIncome;
    final biggest = merchants.isEmpty ? 1 : merchants.first.total;
    return _card(
      'analytics-merchants',
      expense ? 'ТОП МЕРЧАНТОВ ПО РАСХОДАМ' : 'ТОП ИСТОЧНИКОВ ДОХОДА',
      [
        if (merchants.isEmpty)
          Text(
            'Мерчанты в операциях не указаны.',
            key: const Key('analytics-merchants-empty'),
            style: t.bodyS.copyWith(color: c.textSecondary),
          )
        else
          for (var i = 0; i < merchants.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
              child: Column(
                key: Key('analytics-merchant-$i'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          merchants[i].merchant,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodyStrong,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s2),
                      Text(
                        moneyText(merchants[i].total),
                        style: t.numM.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ShareBar(
                    fraction: merchants[i].total / biggest,
                    highlight: i == 0,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${merchants[i].count} '
                      '${merchants[i].count == 1 ? 'операция' : 'операций'}',
                      style: t.caption.copyWith(color: c.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _balancesCard() {
    final c = context.colors;
    final t = context.text;
    final accounts = [
      for (final a in widget.accounts)
        if (!a.archived) a,
    ];
    final balances = _report.balances;
    var biggest = 1;
    for (final a in accounts) {
      biggest = biggest < balances.of(a.id).abs()
          ? balances.of(a.id).abs()
          : biggest;
    }
    return _card('analytics-balances', 'ОСТАТКИ ПО СЧЕТАМ', [
      for (final a in accounts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
          child: Column(
            key: Key('analytics-account-${a.id}'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    accountKindIcon(a.kind),
                    size: 16,
                    color: c.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      a.includeInTotal ? a.name : '${a.name} · вне общего',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyStrong,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Text(
                    moneyText(balances.of(a.id)),
                    key: Key('analytics-balance-${a.id}'),
                    style: t.numM.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ShareBar(fraction: balances.of(a.id).abs() / biggest),
            ],
          ),
        ),
      const Divider(),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
        child: Row(
          children: [
            Expanded(child: Text('Общий баланс', style: t.bodyStrong)),
            Text(
              moneyText(balances.total),
              key: const Key('analytics-total'),
              style: t.numL.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
      _hintButton('analytics-hint-balance', 'Что такое общий баланс?'),
    ]);
  }

  Widget _dynamicsCard() => _card(
    'analytics-dynamics',
    'ОБЩИЙ БАЛАНС: ДИНАМИКА',
    [
      Text(
        'На конец каждого месяца и сегодня.',
        style: context.text.bodyS.copyWith(color: context.colors.textSecondary),
      ),
      const SizedBox(height: AppSpacing.s3),
      BalanceLineChart(points: _report.dynamics),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom + AppSpacing.s6;
    final hasAccounts = widget.accounts.isNotEmpty;
    final left = <Widget>[
      _monthsCard(),
      if (hasAccounts) _dynamicsCard(),
      if (hasAccounts) _balancesCard(),
    ];
    final right = <Widget>[
      if (_report.hasOperations) _categoriesCard(),
      if (_report.hasOperations) _merchantsCard(),
    ];
    Widget stack(List<Widget> cards) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final card in cards) ...[
          card,
          const SizedBox(height: AppSpacing.s4),
        ],
      ],
    );
    if (context.windowClass.isCompact || right.isEmpty) {
      return ListView(
        key: const Key('analytics-scroll'),
        padding: EdgeInsets.only(bottom: bottom),
        children: [
          _periodSelector(),
          stack([left.first, ...right, ...left.skip(1)]),
        ],
      );
    }
    return SingleChildScrollView(
      key: const Key('analytics-scroll'),
      padding: EdgeInsets.only(bottom: bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _periodSelector(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: stack(left)),
              const SizedBox(width: AppSpacing.s4),
              Expanded(child: stack(right)),
            ],
          ),
        ],
      ),
    );
  }
}
