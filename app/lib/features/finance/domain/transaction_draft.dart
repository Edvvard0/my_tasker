import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

const Object _unset = Object();

/// Черновик операции в форме редактора: чистая логика без виджетов.
///
/// * сумма вводится текстом («1 234,5») и разбирается в целые копейки
///   хелперами `core/money` (никаких `double`);
/// * смена вида сохраняет согласованность (spec 1.3): у перевода нет
///   категории, «куда» бывает только у перевода, категория — того же вида;
/// * предупреждение «задним числом» (spec 4.2).
@immutable
class TransactionDraft {
  const TransactionDraft({
    required this.kind,
    required this.occurredAt,
    this.amountText = '',
    this.accountId,
    this.toAccountId,
    this.categoryId,
    this.merchant = '',
    this.comment = '',
  });

  /// Черновик существующей операции (правка).
  factory TransactionDraft.fromTransaction(FinanceTransaction t) =>
      TransactionDraft(
        kind: t.kind,
        occurredAt: t.occurredAt,
        amountText: _amountText(t.amount),
        accountId: t.accountId,
        toAccountId: t.toAccountId,
        categoryId: t.categoryId,
        merchant: t.merchant ?? '',
        comment: t.comment ?? '',
      );

  static String _amountText(int kopecks) {
    final whole = kopecks ~/ 100;
    final cents = kopecks % 100;
    return cents == 0 ? '$whole' : '$whole,${cents.toString().padLeft(2, '0')}';
  }

  final TransactionKind kind;

  /// Момент операции (UTC).
  final DateTime occurredAt;
  final String amountText;
  final String? accountId;
  final String? toAccountId;
  final String? categoryId;
  final String merchant;
  final String comment;

  bool get isTransfer => kind == TransactionKind.transfer;

  /// Сумма в копейках; `null` — пусто, не число или вне диапазона.
  int? get amountKopecks {
    final text = amountText.trim();
    if (text.isEmpty) return null;
    final fixed = text.endsWith(',') || text.endsWith('.')
        ? text.substring(0, text.length - 1)
        : text;
    final value = tryParseAmount(fixed);
    if (value == null || value < 1 || value > maxKopecks) return null;
    return value;
  }

  TransactionDraft copyWith({
    DateTime? occurredAt,
    String? amountText,
    Object? accountId = _unset,
    Object? toAccountId = _unset,
    Object? categoryId = _unset,
    String? merchant,
    String? comment,
  }) => TransactionDraft(
    kind: kind,
    occurredAt: occurredAt ?? this.occurredAt,
    amountText: amountText ?? this.amountText,
    accountId: identical(accountId, _unset)
        ? this.accountId
        : accountId as String?,
    toAccountId: identical(toAccountId, _unset)
        ? this.toAccountId
        : toAccountId as String?,
    categoryId: identical(categoryId, _unset)
        ? this.categoryId
        : categoryId as String?,
    merchant: merchant ?? this.merchant,
    comment: comment ?? this.comment,
  );

  /// Переключает вид. У перевода категория сбрасывается; при уходе с
  /// перевода сбрасывается «куда»; категория другого вида ([categoryKind] —
  /// вид текущей категории) сбрасывается.
  TransactionDraft withKind(
    TransactionKind next, {
    CategoryKind? categoryKind,
  }) {
    if (next == kind) return this;
    final keepCategory =
        next != TransactionKind.transfer &&
        categoryId != null &&
        categoryKind?.wire == next.wire;
    return TransactionDraft(
      kind: next,
      occurredAt: occurredAt,
      amountText: amountText,
      accountId: accountId,
      toAccountId: next == TransactionKind.transfer ? toAccountId : null,
      categoryId: keepCategory ? categoryId : null,
      merchant: merchant,
      comment: comment,
    );
  }

  /// Выбор счёта «откуда» (или единственного счёта операции): если он
  /// совпал со счётом «куда», «куда» сбрасывается.
  TransactionDraft withAccount(String id) => copyWith(
    accountId: id,
    toAccountId: toAccountId == id ? null : toAccountId,
  );

  /// Меняет «откуда» и «куда» местами (перевод).
  TransactionDraft swapped() =>
      copyWith(accountId: toAccountId, toAccountId: accountId);

  /// Первая проблема формы (русский текст) или `null`. Правила значений
  /// репозитория проверяет сам репозиторий и отдаёт их текстом.
  String? get problem {
    if (amountKopecks == null) return 'Введи сумму больше нуля';
    if (accountId == null) {
      return isTransfer ? 'Выбери счёт, откуда переводим' : 'Выбери счёт';
    }
    if (isTransfer) {
      if (toAccountId == null) return 'Выбери счёт, куда переводим';
      if (toAccountId == accountId) {
        return 'Перевод — между двумя разными счетами';
      }
    }
    return null;
  }

  /// Операция из черновика. [base] — существующая (остальные поля —
  /// источник, статус, внешние ссылки — сохраняются).
  ///
  /// Операция, привязанная к долгу (`debt_id`: погашение или выдача), не
  /// меняет вид и сумму через форму: они согласованы с долгом и меняются
  /// только через погашение. Остальное (счёт, категория, мерчант,
  /// комментарий, дата) правится как обычно, `debt_id` сохраняется.
  FinanceTransaction toTransaction(String id, {FinanceTransaction? base}) {
    final linked = base != null && base.debtId != null;
    final source =
        base ??
        FinanceTransaction(
          id: id,
          kind: kind,
          accountId: accountId!,
          amount: 1,
          occurredAt: occurredAt,
        );
    final resultKind = linked ? base.kind : kind;
    final transfer = resultKind == TransactionKind.transfer;
    return FinanceTransaction(
      id: id,
      kind: resultKind,
      accountId: accountId!,
      toAccountId: transfer ? toAccountId : null,
      amount: linked ? base.amount : amountKopecks!,
      occurredAt: occurredAt,
      categoryId: transfer ? null : categoryId,
      merchant: merchant.trim().isEmpty ? null : merchant,
      comment: comment.trim().isEmpty ? null : comment,
      source: source.source,
      status: source.status,
      externalId: source.externalId,
      dedupHash: source.dedupHash,
      workPaymentId: transfer ? null : source.workPaymentId,
      debtId: transfer ? null : source.debtId,
    );
  }

  /// Счета операции, у которых последняя точка сверки не раньше момента
  /// операции: баланс такого счёта операция не изменит (spec 4.2).
  List<String> backdatedAccounts(List<BalanceCheckpoint> checkpoints) {
    final latest = <String, DateTime>{};
    for (final c in checkpoints) {
      final known = latest[c.accountId];
      if (known == null || c.checkedAt.isAfter(known)) {
        latest[c.accountId] = c.checkedAt;
      }
    }
    return [
      for (final id in <String?>[accountId, if (isTransfer) toAccountId])
        if (id != null &&
            latest[id] != null &&
            !occurredAt.isAfter(latest[id]!))
          id,
    ];
  }
}
