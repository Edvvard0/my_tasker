import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/category_picker.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';

/// Лента операций с фильтрами: вид, счёт, категория, месяц, поиск,
/// «требуют проверки» (черновики не входят в итоги, но видны здесь).
class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('transactions-screen'),
      title: 'Операции',
      parentLabel: 'Финансы',
      onBack: () => financeBack(context),
      actions: [
        IconButton(
          key: const Key('transactions-add'),
          tooltip: 'Новая операция',
          onPressed: () => showTransactionEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: FinanceBuilder(builder: (context, data) => _Body(data: data)),
    );
  }
}

/// Сколько операций показывать сразу; остальные — по кнопке.
const int _pageSize = 50;

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.data});

  final FinanceData data;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  final _search = TextEditingController();
  int _shown = _pageSize;

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(txFilterProvider).query;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _set(TxFilter filter) {
    setState(() => _shown = _pageSize);
    ref.read(txFilterProvider.notifier).set(filter);
  }

  Future<void> _pickCategory(TxFilter filter) async {
    final kind = filter.kind == TxKind.income
        ? CategoryKind.income
        : CategoryKind.expense;
    final choice = await showCategoryPicker(
      context,
      kind: kind,
      topLevelOnly: true,
    );
    if (choice != null && mounted) _set(filter.copyWith(categoryId: choice.id));
  }

  String _dayLabel(String day, FinanceData data) {
    if (day == data.today) return 'Сегодня';
    final yesterday = formatDate(addDays(parseDate(data.today)!, -1));
    if (day == yesterday) return 'Вчера';
    return formatDateText(day, data.now);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final filter = ref.watch(txFilterProvider);
    final list = applyTxFilter(data, filter);
    final visible = list.take(_shown).toList();
    final unconfirmed = [
      for (final t in data.transactions)
        if (!t.isConfirmed) t,
    ].length;
    final months = monthsBack(data.thisMonth, 6).reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormTextField(
          key: const Key('tx-search'),
          controller: _search,
          onChanged: (v) => _set(filter.copyWith(query: v)),
          decoration: const InputDecoration(
            hintText: 'Поиск по контрагенту и комментарию',
            prefixIcon: Icon(LucideIcons.search, size: 18),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        ChipRow(
          children: [
            FilterPill(
              key: const Key('tx-filter-all'),
              label: 'Все',
              selected: filter.kind == null && !filter.onlyUnconfirmed,
              onTap: () =>
                  _set(filter.copyWith(kind: null, onlyUnconfirmed: false)),
            ),
            for (final k in TxKind.values)
              FilterPill(
                key: Key('tx-filter-${k.wire}'),
                label: switch (k) {
                  TxKind.expense => 'Расходы',
                  TxKind.income => 'Доходы',
                  TxKind.transfer => 'Переводы',
                },
                selected: filter.kind == k,
                onTap: () => _set(
                  filter.copyWith(
                    kind: filter.kind == k ? null : k,
                    categoryId: k == TxKind.transfer ? null : filter.categoryId,
                  ),
                ),
              ),
            if (unconfirmed > 0)
              FilterPill(
                key: const Key('tx-filter-unconfirmed'),
                label: 'Требуют проверки · $unconfirmed',
                selected: filter.onlyUnconfirmed,
                onTap: () => _set(
                  filter.copyWith(onlyUnconfirmed: !filter.onlyUnconfirmed),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        ChipRow(
          children: [
            FilterPill(
              key: const Key('tx-filter-account-all'),
              label: 'Все счета',
              selected: filter.accountId == null,
              onTap: () => _set(filter.copyWith(accountId: null)),
            ),
            for (final a in data.accounts)
              FilterPill(
                key: Key('tx-filter-account-${a.id}'),
                label: a.name,
                selected: filter.accountId == a.id,
                onTap: () => _set(
                  filter.copyWith(
                    accountId: filter.accountId == a.id ? null : a.id,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        ChipRow(
          children: [
            FilterPill(
              key: const Key('tx-filter-month-all'),
              label: 'Всё время',
              selected: filter.month == null,
              onTap: () => _set(filter.copyWith(month: null)),
            ),
            for (final m in months)
              FilterPill(
                key: Key('tx-filter-month-$m'),
                label: monthShortLabel(m),
                selected: filter.month == m,
                onTap: () =>
                    _set(filter.copyWith(month: filter.month == m ? null : m)),
              ),
            if (filter.kind != TxKind.transfer)
              FilterPill(
                key: const Key('tx-filter-category'),
                label: filter.categoryId == null
                    ? 'Категория'
                    : data.categoryTitle(filter.categoryId),
                selected: filter.categoryId != null,
                icon: LucideIcons.tag,
                onTap: () => filter.categoryId != null
                    ? _set(filter.copyWith(categoryId: null))
                    : _pickCategory(filter),
              ),
          ],
        ),
        if (!filter.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('tx-filter-reset'),
              onPressed: () {
                _search.clear();
                setState(() => _shown = _pageSize);
                ref.read(txFilterProvider.notifier).reset();
              },
              icon: const Icon(LucideIcons.x, size: 16),
              label: const Text('Сбросить фильтры'),
            ),
          )
        else
          const SizedBox(height: AppSpacing.s3),
        if (list.isEmpty)
          _Empty(
            filtered: !filter.isEmpty,
            hasAny: data.transactions.isNotEmpty,
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s2),
            child: Text(
              '${list.length} ${plural(list.length, 'операция', 'операции', 'операций')}',
              key: const Key('tx-count'),
              style: context.text.caption.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
          ),
          for (var i = 0; i < visible.length; i++) ...[
            if (i == 0 ||
                moscowDay(visible[i].occurredAt) !=
                    moscowDay(visible[i - 1].occurredAt))
              FinanceSection(
                title: _dayLabel(moscowDay(visible[i].occurredAt), data),
              ),
            AppCard(
              padding: EdgeInsets.zero,
              child: TransactionTile(
                data: data,
                tx: visible[i],
                showDate: false,
                perspective: filter.accountId,
                onTap: () =>
                    showTransactionEditor(context, txId: visible[i].id),
              ),
            ),
            const SizedBox(height: AppSpacing.s1),
          ],
          if (list.length > visible.length)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s3),
              child: Center(
                child: OutlinedButton(
                  key: const Key('tx-more'),
                  onPressed: () => setState(() => _shown += _pageSize),
                  child: const Text('Показать ещё'),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.filtered, required this.hasAny});

  final bool filtered;
  final bool hasAny;

  @override
  Widget build(BuildContext context) {
    if (filtered && hasAny) {
      return const EmptyState(
        key: Key('tx-empty-filter'),
        icon: LucideIcons.search,
        title: 'Ничего не найдено',
        message: 'Смените фильтры или поисковый запрос.',
      );
    }
    return EmptyState(
      key: const Key('tx-empty'),
      icon: LucideIcons.receipt,
      title: 'Операций пока нет',
      message: 'Запишите первую трату или доход: сумма, категория, счёт.',
      action: FilledButton(
        key: const Key('tx-empty-add'),
        onPressed: () => showTransactionEditor(context),
        child: const Text('Добавить операцию'),
      ),
    );
  }
}
