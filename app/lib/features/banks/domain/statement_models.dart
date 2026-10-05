import 'package:flutter/foundation.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart'
    show parseFinanceInstant;

/// Строка выписки — кандидат в операции (ответ `POST /banks/statements/parse`,
/// spec `stage6_banks.md`, раздел 5.7).
@immutable
class StatementLine {
  const StatementLine({
    required this.index,
    required this.row,
    required this.occurredAt,
    required this.dateOnly,
    required this.kind,
    required this.amount,
    required this.currency,
    required this.needsReview,
    this.originalAmount,
    this.originalCurrency,
    this.merchant,
    this.cardLast4,
    this.externalId,
    this.mcc,
    this.bankCategory,
    this.balanceAfter,
    this.reviewReason,
    this.serverTail,
    this.suggestedCategoryId,
  });

  factory StatementLine.fromJson(Map<String, Object?> json) {
    final suggested = json['suggested_category'];
    return StatementLine(
      index: (json['index'] as int?) ?? 0,
      row: (json['row'] as int?) ?? 0,
      occurredAt: parseFinanceInstant(json['occurred_at']),
      dateOnly: json['date_only'] == true,
      kind: (json['kind'] as String?) == 'income' ? 'income' : 'expense',
      amount: (json['amount'] as int?) ?? 0,
      currency: (json['currency'] as String?) ?? 'RUB',
      originalAmount: json['original_amount'] as int?,
      originalCurrency: json['original_currency'] as String?,
      merchant: json['merchant'] as String?,
      cardLast4: json['card_last4'] as String?,
      externalId: json['external_id'] as String?,
      mcc: json['mcc'] as String?,
      bankCategory: json['bank_category'] as String?,
      balanceAfter: json['balance_after'] as int?,
      needsReview: json['needs_review'] == true,
      reviewReason: json['review_reason'] as String?,
      serverTail: json['dedup_tail'] as String?,
      suggestedCategoryId: suggested is Map
          ? suggested['category_id'] as String?
          : null,
    );
  }

  /// Номер кандидата в ответе.
  final int index;

  /// Номер строки таблицы в файле (для сообщений пользователю).
  final int row;

  /// Момент (UTC); у строки только с датой — 12:00 по Москве.
  final DateTime occurredAt;
  final bool dateOnly;

  /// `expense` или `income`.
  final String kind;

  /// Копейки.
  final int amount;
  final String currency;
  final int? originalAmount;
  final String? originalCurrency;
  final String? merchant;
  final String? cardLast4;
  final String? externalId;
  final String? mcc;
  final String? bankCategory;
  final int? balanceAfter;
  final bool needsReview;
  final String? reviewReason;

  /// `dedup_tail` сервера (клиент считает свой с тем же правилом).
  final String? serverTail;

  /// Категория, которую предложил сервер (правила пользователя и словарь).
  final String? suggestedCategoryId;
}

/// Остаток на конец периода.
@immutable
class ClosingBalance {
  const ClosingBalance({required this.amount, required this.at});

  final int amount;
  final DateTime at;
}

/// Пропущенная строка выписки.
@immutable
class SkippedRow {
  const SkippedRow({required this.row, required this.reason});

  final int row;
  final String reason;
}

/// Разобранная выписка.
@immutable
class ParsedStatement {
  const ParsedStatement({
    required this.format,
    required this.bank,
    required this.cards,
    required this.lines,
    required this.skipped,
    this.periodFrom,
    this.periodTo,
    this.closingBalance,
  });

  factory ParsedStatement.fromJson(Map<String, Object?> json) {
    final period = json['period'];
    final closing = json['closing_balance'];
    return ParsedStatement(
      format: (json['format'] as String?) ?? '',
      bank: (json['bank'] as String?) ?? 'generic',
      periodFrom: period is Map ? period['from'] as String? : null,
      periodTo: period is Map ? period['to'] as String? : null,
      closingBalance: closing is Map
          ? ClosingBalance(
              amount: closing['amount']! as int,
              at: parseFinanceInstant(closing['at']),
            )
          : null,
      cards: [
        for (final c in (json['cards'] as List<Object?>?) ?? const [])
          c! as String,
      ],
      lines: [
        for (final c in (json['candidates'] as List<Object?>?) ?? const [])
          StatementLine.fromJson((c! as Map).cast<String, Object?>()),
      ],
      skipped: [
        for (final s in (json['skipped'] as List<Object?>?) ?? const [])
          _skipped((s! as Map).cast<String, Object?>()),
      ],
    );
  }

  final String format;

  /// Профиль: `tbank`, `vtb` или `generic`.
  final String bank;
  final String? periodFrom;
  final String? periodTo;
  final ClosingBalance? closingBalance;

  /// Последние цифры карт, найденные в строках.
  final List<String> cards;
  final List<StatementLine> lines;
  final List<SkippedRow> skipped;
}

SkippedRow _skipped(Map<String, Object?> json) => SkippedRow(
  row: (json['row'] as int?) ?? 0,
  reason: (json['reason'] as String?) ?? '',
);

/// Название банка профиля для интерфейса.
String statementBankName(String bank) => switch (bank) {
  'tbank' => 'Т-Банк',
  'vtb' => 'ВТБ',
  _ => 'Банк не определён',
};

/// Причина пропуска строки по-русски.
String skippedReasonText(String reason) {
  if (reason.startsWith('status ')) return 'Операция не проведена';
  return switch (reason) {
    'bad_date' => 'Не удалось прочитать дату',
    'no_amount' => 'Нет суммы',
    _ => 'Строка пропущена',
  };
}
