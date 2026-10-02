import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_pickers.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_states.dart';
import 'package:my_tasker/features/finance/presentation/widgets/transaction_feed.dart';

/// «Операции»: лента с фильтрами (вид, счёт, категория, период) и поиском по
/// сумме и мерчанту; месяцы с липкими итогами «доход / расход / итого».
class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  late final TextEditingController _search;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(
      text: ref.read(transactionFilterProvider).query,
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reset() {
    _search.clear();
    ref.read(transactionFilterProvider.notifier).reset();
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(transactionFilterProvider);
    final feed = ref.watch(filteredTransactionFeedProvider);
    final lookups = ref.watch(financeLookupsProvider);
    final anyRows = ref.watch(transactionRowsProvider).value?.isNotEmpty;
    final Widget body;
    if ((feed.hasError && !feed.hasValue) ||
        (lookups.hasError && !lookups.hasValue)) {
      body = const SingleChildScrollView(child: FinanceErrorNotice());
    } else if (!feed.hasValue || !lookups.hasValue) {
      body = const SingleChildScrollView(child: ListSkeleton(rows: 5));
    } else if (feed.requireValue.items.isEmpty) {
      body = anyRows ?? false
          ? EmptyState(
              key: const Key('feed-filter-empty'),
              icon: LucideIcons.listFilter,
              title: 'Ничего не нашлось',
              message: 'Попробуй другое слово или убери фильтры.',
              action: ElevatedButton(
                key: const Key('feed-empty-reset'),
                onPressed: _reset,
                child: const Text('Сбросить фильтры'),
              ),
            )
          : EmptyState(
              key: const Key('feed-empty'),
              icon: LucideIcons.receipt,
              title: 'Операций нет',
              message:
                  'Пока ничего не записано. Добавь первую — расход, доход '
                  'или перевод.',
              action: FilledButton(
                key: const Key('feed-empty-add'),
                onPressed: () => unawaited(showTransactionEditor(context)),
                child: const Text('Добавить операцию'),
              ),
            );
    } else {
      body = CustomScrollView(
        key: const Key('feed-list'),
        slivers: [
          ...transactionFeedSlivers(feed.requireValue, lookups.requireValue),
          SliverToBoxAdapter(
            child: SizedBox(
              height: MediaQuery.paddingOf(context).bottom + AppSpacing.s6,
            ),
          ),
        ],
      );
    }
    return ScreenScaffold(
      title: 'Операции',
      parentLabel: 'Финансы',
      onBack: () => context.go('/finance'),
      scrollable: false,
      actions: [
        IconButton(
          key: const Key('feed-add'),
          tooltip: 'Новая операция',
          onPressed: () => unawaited(showTransactionEditor(context)),
          icon: const Icon(LucideIcons.plus, size: 22),
        ),
      ],
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const FinanceOfflineNotice(),
              FormTextField(
                key: const Key('feed-search'),
                controller: _search,
                textInputAction: TextInputAction.search,
                onChanged: ref
                    .read(transactionFilterProvider.notifier)
                    .setQuery,
                decoration: const InputDecoration(
                  hintText: 'Сумма или мерчант',
                  prefixIcon: Icon(LucideIcons.search, size: 18),
                ),
              ),
              const SizedBox(height: AppSpacing.s2),
              _FilterBar(filter: filter, onReset: _reset),
              const SizedBox(height: AppSpacing.s2),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.filter, required this.onReset});

  final TransactionFilter filter;
  final VoidCallback onReset;

  static String _day(DateTime d) => formatDate(d);

  Future<void> _pickAccount(BuildContext context, WidgetRef ref) async {
    final picked = await showAccountPicker(
      context,
      accounts: ref.read(accountsProvider).value ?? const [],
      balances: ref.read(financeBalancesProvider).value,
      selectedId: filter.accountId,
      allLabel: 'Все счета',
    );
    if (picked == null) return;
    ref
        .read(transactionFilterProvider.notifier)
        .setAccount(picked.isEmpty ? null : picked);
  }

  Future<void> _pickCategory(BuildContext context, WidgetRef ref) async {
    final pick = await showCategoryPicker(
      context,
      categories: ref.read(categoriesProvider).value ?? const [],
      selectedId: filter.categoryId,
      noneLabel: 'Все категории',
      withWithout: true,
    );
    if (pick == null) return;
    final notifier = ref.read(transactionFilterProvider.notifier);
    if (pick.without) {
      notifier.setWithoutCategory(value: true);
    } else {
      notifier.setCategory(pick.id);
    }
  }

  Future<void> _pickPeriod(BuildContext context, WidgetRef ref) async {
    final today = ref.read(todayProvider);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: DateTime(today.year + 1, 12, 31),
      locale: const Locale('ru'),
    );
    if (picked == null) return;
    ref
        .read(transactionFilterProvider.notifier)
        .setPeriod(
          from: _day(
            civil(picked.start.year, picked.start.month, picked.start.day),
          ),
          to: _day(civil(picked.end.year, picked.end.month, picked.end.day)),
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(transactionFilterProvider.notifier);
    final lookups = ref.watch(financeLookupsProvider).value;
    final today = ref.watch(todayProvider);
    final monthFrom = _day(civil(today.year, today.month, 1));
    final monthTo = _day(civil(today.year, today.month + 1, 0));
    final prevFrom = _day(civil(today.year, today.month - 1, 1));
    final prevTo = _day(civil(today.year, today.month, 0));
    final thisMonth = filter.from == monthFrom && filter.to == monthTo;
    final prevMonth = filter.from == prevFrom && filter.to == prevTo;
    final customPeriod =
        (filter.from != null || filter.to != null) && !thisMonth && !prevMonth;
    final category = lookups?.category(filter.categoryId);
    final categoryLabel = filter.withoutCategory
        ? 'Без категории'
        : category?.name ?? 'Категория';
    String? customLabel;
    if (customPeriod) {
      String short(String? iso) {
        final d = iso == null ? null : parseDate(iso);
        return d == null ? '…' : '${d.day} ${monthShortNames[d.month - 1]}';
      }

      customLabel = '${short(filter.from)} – ${short(filter.to)}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChipRow(
          children: [
            FilterPill(
              key: const Key('feed-kind-all'),
              label: 'Все',
              selected: filter.kind == null,
              onTap: () => notifier.setKind(null),
            ),
            for (final k in TransactionKind.values)
              FilterPill(
                key: Key('feed-kind-${k.name}'),
                label: switch (k) {
                  TransactionKind.expense => 'Расходы',
                  TransactionKind.income => 'Доходы',
                  TransactionKind.transfer => 'Переводы',
                },
                selected: filter.kind == k,
                onTap: () => notifier.setKind(k),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        ChipRow(
          children: [
            FilterPill(
              key: const Key('feed-account'),
              label: filter.accountId == null
                  ? 'Счёт'
                  : lookups?.accountName(filter.accountId) ?? 'Счёт',
              selected: filter.accountId != null,
              icon: LucideIcons.wallet,
              onTap: () => unawaited(_pickAccount(context, ref)),
            ),
            FilterPill(
              key: const Key('feed-category'),
              label: categoryLabel,
              selected: filter.categoryId != null || filter.withoutCategory,
              icon: LucideIcons.tag,
              onTap: () => unawaited(_pickCategory(context, ref)),
            ),
            FilterPill(
              key: const Key('feed-period-all'),
              label: 'Всё время',
              selected: filter.from == null && filter.to == null,
              onTap: notifier.setPeriod,
            ),
            FilterPill(
              key: const Key('feed-period-month'),
              label: 'Этот месяц',
              selected: thisMonth,
              onTap: () => notifier.setPeriod(from: monthFrom, to: monthTo),
            ),
            FilterPill(
              key: const Key('feed-period-prev'),
              label: 'Прошлый месяц',
              selected: prevMonth,
              onTap: () => notifier.setPeriod(from: prevFrom, to: prevTo),
            ),
            FilterPill(
              key: const Key('feed-period-pick'),
              label: customLabel ?? 'Период',
              selected: customPeriod,
              icon: LucideIcons.calendar,
              onTap: () => unawaited(_pickPeriod(context, ref)),
            ),
            if (!filter.isEmpty)
              TextButton(
                key: const Key('feed-reset'),
                onPressed: onReset,
                child: const Text('Сбросить'),
              ),
          ],
        ),
      ],
    );
  }
}
