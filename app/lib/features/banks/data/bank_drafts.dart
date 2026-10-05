import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/banks/data/banks_repository.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart'
    show ValidationError;
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Действия над черновиками операций из банков: подтвердить (по желанию —
/// запомнить категорию для мерчанта), отклонить, склеить перевод между
/// своими счетами.
class BankDrafts {
  BankDrafts({
    required this.loadData,
    required this.store,
    required this.finance,
    required this.banks,
  });

  final Future<BankData> Function() loadData;
  final SyncStore store;
  final FinanceRepository finance;
  final BanksRepository banks;

  /// Подтверждает черновик: операция входит в суммы по своему `occurred_at`.
  /// [remember] — «запомнить для этого мерчанта»: правило категории
  /// (`exact` по нормализованному имени); без мерчанта или категории
  /// ничего не запоминается.
  Future<void> confirm(String txId, {bool remember = false}) async {
    final tx = await finance.getTransaction(txId);
    if (tx == null) throw StateError('Операции $txId нет');
    await store.transaction(() async {
      if (remember) await _remember(tx);
      await finance.confirmTransaction(txId);
    });
  }

  /// Массовое подтверждение: только черновики (`draft`); «Требует
  /// проверки» подтверждается по одной. Возвращает число подтверждённых.
  Future<int> confirmAll(Iterable<String> txIds) async {
    var count = 0;
    await store.transaction(() async {
      for (final id in txIds) {
        final tx = await finance.getTransaction(id);
        if (tx == null || tx.status != TxStatus.draft) continue;
        await finance.confirmTransaction(id);
        count++;
      }
    });
    return count;
  }

  /// Отклоняет черновик: операция уходит в корзину.
  Future<void> reject(String txId) => finance.deleteTransaction(txId);

  Future<void> _remember(FinTransaction tx) async {
    final merchant = tx.merchant;
    final category = tx.categoryId;
    if (merchant == null || category == null || tx.kind == TxKind.transfer) {
      return;
    }
    try {
      await banks.rememberMerchant(
        data: (await loadData()).normalization,
        merchant: merchant,
        kind: tx.kind.wire,
        categoryId: category,
      );
    } on ValidationError {
      // У названия нет слов (только цифры и знаки): правило не нужно.
    }
  }

  /// Склеивает расход и доход в один перевод между своими счетами
  /// (spec 4.5): две строки уходят в корзину, создаётся одна `transfer`.
  /// Идентификатор банка и хеш расхода переходят к переводу, чтобы повторный
  /// импорт нашёл его как дубликат.
  Future<String> mergeTransfer({
    required String expenseId,
    required String incomeId,
  }) async {
    final expense = await finance.getTransaction(expenseId);
    final income = await finance.getTransaction(incomeId);
    if (expense == null ||
        income == null ||
        expense.kind != TxKind.expense ||
        income.kind != TxKind.income) {
      throw const ValidationError('Операции для перевода не найдены');
    }
    final id = finance.newId();
    await store.transaction(() async {
      await finance.createTransaction(
        FinTransaction(
          id: id,
          kind: TxKind.transfer,
          accountId: expense.accountId,
          toAccountId: income.accountId,
          amount: expense.amount,
          occurredAt: expense.occurredAt,
          merchant: expense.merchant ?? income.merchant,
          source: expense.source,
          externalId: expense.externalId,
          dedupHash: expense.dedupHash,
        ),
      );
      await finance.deleteTransaction(expenseId);
      await finance.deleteTransaction(incomeId);
    });
    return id;
  }
}

final Provider<BankDrafts> bankDraftsProvider = Provider<BankDrafts>(
  (ref) => BankDrafts(
    loadData: () => ref.read(bankDataProvider.future),
    store: ref.watch(syncStoreProvider),
    finance: ref.watch(financeRepositoryProvider),
    banks: ref.watch(banksRepositoryProvider),
  ),
);

/// Ключ в `local_settings`: пары «не склеивать» (JSON-список ключей).
const String dismissedTransfersKey = 'banks.dismissed_transfers';

/// Пары, которые пользователь отказался склеивать (локально, на устройстве).
class DismissedTransfers extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    final raw = await ref
        .read(localSettingsRepositoryProvider)
        .read(dismissedTransfersKey);
    if (raw == null) return <String>{};
    try {
      return {for (final k in jsonDecode(raw) as List<Object?>) k! as String};
    } on Object {
      return <String>{};
    }
  }

  Future<void> dismiss(String pairKey) async {
    final next = {...?state.value, pairKey};
    state = AsyncData(next);
    await ref
        .read(localSettingsRepositoryProvider)
        .write(dismissedTransfersKey, jsonEncode(next.toList()));
  }
}

final AsyncNotifierProvider<DismissedTransfers, Set<String>>
dismissedTransfersProvider =
    AsyncNotifierProvider<DismissedTransfers, Set<String>>(
      DismissedTransfers.new,
    );
