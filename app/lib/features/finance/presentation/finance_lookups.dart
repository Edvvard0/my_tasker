import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Склеивает два асинхронных значения: ошибка любого без значения — ошибка,
/// пока чего-то нет — загрузка.
AsyncValue<R> joinAsync<A, B, R>(
  AsyncValue<A> a,
  AsyncValue<B> b,
  R Function(A a, B b) combine,
) {
  for (final v in <AsyncValue<Object?>>[a, b]) {
    if (v.hasError && !v.hasValue) {
      return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
    }
  }
  if (!a.hasValue || !b.hasValue) return const AsyncValue.loading();
  return AsyncValue.data(combine(a.requireValue, b.requireValue));
}

/// Видимые счета и категории по id: подписи в строках операций.
class FinanceLookups {
  const FinanceLookups({required this.accounts, required this.categories});

  final Map<String, Account> accounts;
  final Map<String, FinanceCategory> categories;

  Account? account(String? id) => id == null ? null : accounts[id];

  FinanceCategory? category(String? id) => id == null ? null : categories[id];

  /// Название счёта; удалённый показывается как «Счёт».
  String accountName(String? id) => account(id)?.name ?? 'Счёт';
}

final Provider<AsyncValue<FinanceLookups>> financeLookupsProvider =
    Provider<AsyncValue<FinanceLookups>>(
      (ref) => joinAsync(
        ref.watch(accountsProvider),
        ref.watch(categoriesProvider),
        (accounts, categories) => FinanceLookups(
          accounts: {for (final a in accounts) a.id: a},
          categories: {for (final c in categories) c.id: c},
        ),
      ),
    );

/// Перечитывает данные Финансов (кнопка «Повторить» на экране с ошибкой).
void refreshFinance(WidgetRef ref) => ref
  ..invalidate(accountRowsProvider)
  ..invalidate(categoryRowsProvider)
  ..invalidate(transactionRowsProvider)
  ..invalidate(checkpointRowsProvider)
  ..invalidate(debtRowsProvider)
  ..invalidate(repaymentRowsProvider)
  ..invalidate(goalRowsProvider);
