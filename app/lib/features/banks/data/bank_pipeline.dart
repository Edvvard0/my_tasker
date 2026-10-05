import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/async/async_mutex.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/banks/data/banks_repository.dart';
import 'package:my_tasker/features/banks/data/notification_store.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/domain/bank_operations.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/banks/domain/notification_engine.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Чем закончилась обработка уведомления.
enum ProcessOutcome {
  /// Не наш банк или служебное уведомление: ничего не делаем.
  ignored,

  /// Уже обрабатывалось (тот же отпечаток).
  alreadySeen,

  /// Формат не распознан: в «Требует проверки» с исходным текстом.
  unrecognized,

  /// Разобрано, счёт не определён: нужен выбор пользователя.
  needsAccount,

  /// Создан черновик операции.
  draftCreated,

  /// Такая операция уже есть (дедупликация): черновик не создан.
  duplicate,
}

/// Конвейер уведомлений: уведомление → разбор по правилам → черновик
/// операции (`source = notification`, `status = draft`; счёт по
/// `card_last4`, иначе «нужен счёт») → дедупликация → остаток в точку
/// сверки (`source = notification`).
///
/// Сырой текст остаётся только в локальной таблице (30 дней); на сервер
/// через синхронизацию уходят лишь операция и точка сверки.
class BankPipeline {
  BankPipeline({
    required this.loadData,
    required this.store,
    required this.finance,
    required this.banks,
    required this.notifications,
  });

  final Future<BankData> Function() loadData;
  final SyncStore store;
  final FinanceRepository finance;
  final BanksRepository banks;
  final NotificationStore notifications;

  final AsyncMutex _mutex = AsyncMutex();

  /// Обрабатывает пачку уведомлений по очереди; возвращает исходы.
  Future<List<ProcessOutcome>> ingest(Iterable<RawNotification> batch) async {
    await notifications.purgeExpired();
    final outcomes = <ProcessOutcome>[];
    for (final raw in batch) {
      outcomes.add(await process(raw));
    }
    return outcomes;
  }

  /// Обрабатывает одно уведомление (обработки идут строго по очереди).
  Future<ProcessOutcome> process(RawNotification raw) =>
      _mutex.protect(() => _process(raw));

  Future<ProcessOutcome> _process(RawNotification raw) async {
    if (await notifications.seen(raw)) return ProcessOutcome.alreadySeen;
    final data = await loadData();
    final parsed = parseNotification(
      data.notifications,
      package: raw.package,
      title: raw.title,
      text: raw.text,
    );
    switch (parsed.status) {
      case NotificationStatus.ignored:
        return ProcessOutcome.ignored;
      case NotificationStatus.unrecognized:
        await notifications.insert(
          raw,
          state: NotificationState.unrecognized,
          reason: parsed.reason,
        );
        return ProcessOutcome.unrecognized;
      case NotificationStatus.parsed:
        break;
    }
    final accounts = await _accountsForCard(parsed.cardLast4);
    if (accounts.length != 1) {
      await notifications.insert(
        raw,
        state: NotificationState.needsAccount,
        reason: accounts.isEmpty ? 'no_account' : 'ambiguous_account',
        parsed: parsed,
      );
      return ProcessOutcome.needsAccount;
    }
    final created = await _createDraft(data, raw, parsed, accounts.single);
    await notifications.insert(
      raw,
      state: NotificationState.processed,
      txId: created.txId,
    );
    return created.duplicate
        ? ProcessOutcome.duplicate
        : ProcessOutcome.draftCreated;
  }

  /// Пользователь выбрал счёт для разобранного уведомления
  /// («Требует проверки»): создаёт черновик.
  Future<ProcessOutcome> assignAccount(
    BankNotification notification,
    String accountId,
  ) => _mutex.protect(() async {
    final parsed = notification.parsed;
    if (parsed == null || !parsed.isParsed) {
      throw StateError('Уведомление не разобрано: счёт выбирать не для чего');
    }
    final row = await store.getRow('accounts', accountId);
    if (row == null || row['deleted_at'] != null) {
      throw StateError('Счёт не найден');
    }
    final raw = RawNotification(
      package: notification.package,
      title: notification.title,
      text: notification.body,
      postedAt: notification.postedAt,
    );
    final created = await _createDraft(
      await loadData(),
      raw,
      parsed,
      Account.fromRow(row),
    );
    await notifications.markProcessed(notification.id, txId: created.txId);
    return created.duplicate
        ? ProcessOutcome.duplicate
        : ProcessOutcome.draftCreated;
  });

  Future<List<Account>> _accountsForCard(String? last4) async {
    if (last4 == null) return const [];
    final accounts = [
      for (final r in await store.visibleRows('accounts')) Account.fromRow(r),
    ];
    return [
      for (final a in accounts)
        if (a.cardLast4 == last4 && !a.archived) a,
    ];
  }

  Future<List<FinTransaction>> _transactionsOf(String accountId) async => [
    for (final r in await store.visibleRows(
      'transactions',
      where: 't.account_id = ? OR t.to_account_id = ?',
      args: [accountId, accountId],
    ))
      FinTransaction.fromRow(r),
  ];

  Future<({String? txId, bool duplicate})> _createDraft(
    BankData data,
    RawNotification raw,
    NotificationParse parsed,
    Account account,
  ) async {
    final kind = parsed.kind!;
    final occurredAt = notificationMoment(raw.postedAt, parsed.time);
    final candidate = StatementCandidate(
      kind: kind,
      amount: parsed.amount!,
      currency: parsed.currency ?? homeCurrency,
      occurredAt: occurredAt,
      merchant: parsed.merchant,
    );
    final existing = existingOperationsFor(
      account.id,
      await _transactionsOf(account.id),
    );
    // 1. Точное совпадение — любой источник (повторная публикация того же
    //    уведомления в ту же минуту).
    final exact = classifyCandidates(
      data.normalization,
      accountId: account.id,
      candidates: [candidate],
      existing: existing,
    ).single;
    if (exact.action == MatchAction.duplicate && exact.reason != 'fuzzy') {
      return (txId: exact.existingId, duplicate: true);
    }
    // 2. Нечётко — только с операциями, которые уже внесли другим путём
    //    (вручную, из выписки): две настоящие покупки подряд в одном
    //    магазине — две операции, поэтому уведомления между собой нечётко
    //    не склеиваются.
    final other = classifyCandidates(
      data.normalization,
      accountId: account.id,
      candidates: [candidate],
      existing: [
        for (final e in existing)
          if (e.source != 'notification') e,
      ],
    ).single;
    if (other.action != MatchAction.create) {
      return (txId: other.existingId, duplicate: true);
    }
    final rules = await banks.rules();
    var suggestion = suggestCategory(
      data,
      merchant: parsed.merchant,
      mcc: null,
      kind: kind,
      userRules: rules,
    );
    if (suggestion.categoryId == null && parsed.refund) {
      // Возврат: категория как у расхода того же мерчанта.
      suggestion = suggestCategory(
        data,
        merchant: parsed.merchant,
        mcc: null,
        kind: 'expense',
        userRules: rules,
      );
    }
    final merchant = parsed.merchant == null || parsed.merchant!.length <= 200
        ? parsed.merchant
        : parsed.merchant!.substring(0, 200);
    final txId = finance.newId();
    await store.transaction(() async {
      await finance.createTransaction(
        FinTransaction(
          id: txId,
          kind: kind == 'income' ? TxKind.income : TxKind.expense,
          accountId: account.id,
          amount: parsed.amount!,
          occurredAt: occurredAt,
          categoryId: suggestion.categoryId,
          merchant: merchant,
          comment: parsed.needsReview
              ? 'Сумма в ${parsed.currency}: ${_amountText(parsed.amount!)}. '
                    'Укажите сумму в рублях.'
              : null,
          source: TxSource.notification,
          status: parsed.needsReview ? TxStatus.needsReview : TxStatus.draft,
          dedupHash: exact.dedupHash,
        ),
      );
      final balance = parsed.balance;
      if (balance != null && !parsed.needsReview) {
        await finance.reconcile(
          accountId: account.id,
          actualBalance: balance,
          checkedAt: occurredAt,
          note: 'Остаток из уведомления банка',
          source: CheckpointSource.notification,
        );
      }
    });
    return (txId: txId, duplicate: false);
  }

  static String _amountText(int kopecks) {
    final whole = kopecks ~/ 100;
    final cents = (kopecks % 100).toString().padLeft(2, '0');
    return '$whole,$cents';
  }
}

final Provider<BankPipeline> bankPipelineProvider = Provider<BankPipeline>(
  (ref) => BankPipeline(
    loadData: () => ref.read(bankDataProvider.future),
    store: ref.watch(syncStoreProvider),
    finance: ref.watch(financeRepositoryProvider),
    banks: ref.watch(banksRepositoryProvider),
    notifications: ref.watch(notificationStoreProvider),
  ),
);
