import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/banks/domain/statement_models.dart';
import 'package:my_tasker/features/banks/domain/statement_plan.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Итог импорта выписки.
@immutable
class ImportResult {
  const ImportResult({
    required this.created,
    required this.refined,
    required this.skipped,
    required this.checkpointCreated,
  });

  /// Создано операций (`source = statement`).
  final int created;

  /// Уточнено существующих черновиков.
  final int refined;

  /// Строк, которые не импортировались (дубликаты и снятые отметки).
  final int skipped;

  /// Создана точка сверки по остатку на конец периода.
  final bool checkpointCreated;
}

/// Подтверждение импорта выписки: подтверждённые строки становятся обычными
/// операциями `source = statement`, совпавшие с черновиками уточняют их,
/// остаток на конец периода — точка сверки `source = statement`.
class StatementImporter {
  StatementImporter({required this.store, required this.finance});

  final SyncStore store;
  final FinanceRepository finance;

  Future<ImportResult> commit({
    required ParsedStatement statement,
    required List<ImportItem> items,
  }) async {
    var created = 0;
    var refined = 0;
    var checkpoint = false;
    await store.transaction(() async {
      for (final item in items) {
        final accountId = item.accountId;
        final match = item.match;
        if (!item.selected || accountId == null || match == null) continue;
        if (item.isRefinement && match.existingId != null) {
          if (await _refine(item)) {
            refined++;
            continue;
          }
        }
        await _create(item, accountId, match);
        created++;
      }
      checkpoint = await _closingBalance(statement, items);
    });
    return ImportResult(
      created: created,
      refined: refined,
      skipped: items.length - created - refined,
      checkpointCreated: checkpoint,
    );
  }

  Future<void> _create(
    ImportItem item,
    String accountId,
    MatchResult match,
  ) async {
    final line = item.line;
    final foreign = line.needsReview;
    final merchant = line.merchant;
    await finance.createTransaction(
      FinTransaction(
        id: finance.newId(),
        kind: line.kind == 'income' ? TxKind.income : TxKind.expense,
        accountId: accountId,
        amount: line.amount,
        occurredAt: line.occurredAt,
        categoryId: item.categoryId,
        merchant: merchant == null || merchant.length <= 200
            ? merchant
            : merchant.substring(0, 200),
        comment: foreign ? _foreignComment(line) : null,
        source: TxSource.statement,
        status: foreign ? TxStatus.needsReview : TxStatus.confirmed,
        externalId: line.externalId,
        // Хеш нужен там, где банк не дал идентификатор (spec 4.1).
        dedupHash: line.externalId == null ? match.dedupHash : null,
      ),
    );
  }

  /// Выписка уточняет черновик уведомления (или ручную операцию): момент и
  /// мерчант из строки, идентификатор банка и хеш выписки — чтобы повторный
  /// импорт нашёл строку точным совпадением.
  Future<bool> _refine(ImportItem item) async {
    final match = item.match!;
    final existing = await finance.getTransaction(match.existingId!);
    if (existing == null) return false;
    final refine = match.refine ?? const {};
    final moment = refine['occurred_at'];
    final fromNotification = existing.source == TxSource.notification;
    await finance.updateTransaction(
      existing.copyWith(
        occurredAt: moment == null ? null : parseFinanceInstant(moment),
        merchant: refine['merchant'] ?? existing.merchant,
        externalId: existing.externalId ?? item.line.externalId,
        dedupHash: fromNotification ? match.dedupHash : existing.dedupHash,
        source: fromNotification ? TxSource.statement : null,
      ),
    );
    return true;
  }

  Future<bool> _closingBalance(
    ParsedStatement statement,
    List<ImportItem> items,
  ) async {
    final closing = statement.closingBalance;
    if (closing == null) return false;
    final accounts = {
      for (final i in items)
        if (i.accountId != null) i.accountId!,
    };
    // Остаток относится к одному счёту: если строки легли на несколько,
    // однозначно привязать его нельзя.
    if (accounts.length != 1) return false;
    final accountId = accounts.single;
    for (final row in await store.visibleRows(
      FinanceRepository.checkpointsTable,
      where: 't.account_id = ?',
      args: [accountId],
    )) {
      final cp = BalanceCheckpoint.fromRow(row);
      if (cp.source == CheckpointSource.statement &&
          cp.checkedAt == closing.at &&
          cp.actualBalance == closing.amount) {
        return false;
      }
    }
    await finance.reconcile(
      accountId: accountId,
      actualBalance: closing.amount,
      checkedAt: closing.at,
      note: 'Остаток из выписки',
      source: CheckpointSource.statement,
    );
    return true;
  }

  static String _foreignComment(StatementLine line) {
    final original = line.originalAmount;
    final currency = line.originalCurrency ?? line.currency;
    if (original == null) {
      return 'Операция в валюте $currency. Проверьте сумму в рублях.';
    }
    final whole = original ~/ 100;
    final cents = (original % 100).toString().padLeft(2, '0');
    return 'Операция на $whole,$cents $currency. Сумма в рублях взята '
        'из выписки — проверьте.';
  }
}

final Provider<StatementImporter> statementImporterProvider =
    Provider<StatementImporter>(
      (ref) => StatementImporter(
        store: ref.watch(syncStoreProvider),
        finance: ref.watch(financeRepositoryProvider),
      ),
    );
