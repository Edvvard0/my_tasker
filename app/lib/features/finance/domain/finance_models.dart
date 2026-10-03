import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';

const Object _unset = Object();

/// Вид счёта (spec Этапа 5, 1.1).
enum AccountKind {
  cash('Наличные', 'cash'),
  debitCard('Дебетовая карта', 'debit_card'),
  creditCard('Кредитная карта', 'credit_card'),
  savings('Накопительный счёт', 'savings'),
  deposit('Вклад', 'deposit'),
  other('Другое', 'other');

  const AccountKind(this.label, this.wire);

  final String label;

  /// Значение колонки `kind`.
  final String wire;

  static AccountKind parse(Object? value) => AccountKind.values.firstWhere(
    (k) => k.wire == value,
    orElse: () => AccountKind.other,
  );

  /// Карта: можно указать последние 4 цифры.
  bool get isCard => this == debitCard || this == creditCard;
}

/// Вид категории (spec 1.2): совпадает с видом операции `expense`/`income`.
enum CategoryKind {
  expense('Расход', 'expense'),
  income('Доход', 'income');

  const CategoryKind(this.label, this.wire);

  final String label;
  final String wire;

  static CategoryKind parse(Object? value) =>
      value == 'income' ? income : expense;
}

/// Вид операции (spec 1.3).
enum TransactionKind {
  expense('Расход', 'expense'),
  income('Доход', 'income'),
  transfer('Перевод', 'transfer');

  const TransactionKind(this.label, this.wire);

  final String label;
  final String wire;

  static TransactionKind parse(Object? value) =>
      TransactionKind.values.firstWhere(
        (k) => k.wire == value,
        orElse: () => TransactionKind.expense,
      );
}

/// Источник операции (spec 1.3). В срезе 5a создаётся только `manual`.
enum TransactionSource {
  manual('manual'),
  notification('notification'),
  statement('statement'),
  workPayment('work_payment');

  const TransactionSource(this.wire);

  final String wire;

  static TransactionSource parse(Object? value) =>
      TransactionSource.values.firstWhere(
        (s) => s.wire == value,
        orElse: () => TransactionSource.manual,
      );
}

/// Статус операции (spec 1.3, 4.3): считается только `confirmed`.
enum TransactionStatus {
  confirmed('confirmed'),
  draft('draft'),
  needsReview('needs_review');

  const TransactionStatus(this.wire);

  final String wire;

  static TransactionStatus parse(Object? value) =>
      TransactionStatus.values.firstWhere(
        (s) => s.wire == value,
        orElse: () => TransactionStatus.confirmed,
      );
}

/// Источник точки сверки (spec 1.4).
enum CheckpointSource {
  manual('manual'),
  notification('notification'),
  statement('statement');

  const CheckpointSource(this.wire);

  final String wire;

  static CheckpointSource parse(Object? value) =>
      CheckpointSource.values.firstWhere(
        (s) => s.wire == value,
        orElse: () => CheckpointSource.manual,
      );
}

/// Направление долга (spec 1.5).
enum DebtDirection {
  owedToMe('Мне должны', 'owed_to_me'),
  iOwe('Я должен', 'i_owe');

  const DebtDirection(this.label, this.wire);

  final String label;
  final String wire;

  static DebtDirection parse(Object? value) =>
      value == 'i_owe' ? iOwe : owedToMe;
}

DateTime _instant(Object? value) => DateTime.fromMillisecondsSinceEpoch(
  instantSeconds(value! as String) * 1000,
  isUtc: true,
);

String _stored(DateTime instant) =>
    formatSeconds(instant.millisecondsSinceEpoch ~/ 1000);

/// Счёт (`accounts`).
@immutable
class Account {
  const Account({
    required this.id,
    required this.name,
    required this.kind,
    required this.openingBalance,
    required this.openingDate,
    this.bank,
    this.cardLast4,
    this.includeInTotal = true,
    this.creditLimit,
    this.archived = false,
  });

  factory Account.fromRow(Json row) => Account(
    id: row['id']! as String,
    name: row['name']! as String,
    kind: AccountKind.parse(row['kind']),
    bank: row['bank'] as String?,
    cardLast4: row['card_last4'] as String?,
    openingBalance: row['opening_balance']! as int,
    openingDate: row['opening_date']! as String,
    includeInTotal: row['include_in_total']! as bool,
    creditLimit: row['credit_limit'] as int?,
    archived: row['archived']! as bool,
  );

  final String id;
  final String name;
  final AccountKind kind;
  final String? bank;
  final String? cardLast4;

  /// Копейки со знаком.
  final int openingBalance;

  /// Московская дата `YYYY-MM-DD`: с её начала счёт «открыт».
  final String openingDate;
  final bool includeInTotal;

  /// Справочный кредитный лимит (только у кредитной карты), копейки.
  final int? creditLimit;
  final bool archived;

  /// Прикладные колонки строки (без служебных).
  Json toFields() => {
    'name': name,
    'kind': kind.wire,
    'bank': bank,
    'card_last4': cardLast4,
    'opening_balance': openingBalance,
    'opening_date': openingDate,
    'include_in_total': includeInTotal,
    'credit_limit': creditLimit,
    'archived': archived,
  };

  /// «JSON-строка» для расчётов `core/finance`.
  Json toRow() => {'id': id, ...toFields()};

  Account copyWith({
    String? name,
    AccountKind? kind,
    Object? bank = _unset,
    Object? cardLast4 = _unset,
    int? openingBalance,
    String? openingDate,
    bool? includeInTotal,
    Object? creditLimit = _unset,
    bool? archived,
  }) => Account(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    bank: identical(bank, _unset) ? this.bank : bank as String?,
    cardLast4: identical(cardLast4, _unset)
        ? this.cardLast4
        : cardLast4 as String?,
    openingBalance: openingBalance ?? this.openingBalance,
    openingDate: openingDate ?? this.openingDate,
    includeInTotal: includeInTotal ?? this.includeInTotal,
    creditLimit: identical(creditLimit, _unset)
        ? this.creditLimit
        : creditLimit as int?,
    archived: archived ?? this.archived,
  );
}

/// Категория (`categories`).
@immutable
class FinanceCategory {
  const FinanceCategory({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    this.icon,
    this.color,
    this.systemKey,
  });

  factory FinanceCategory.fromRow(Json row) => FinanceCategory(
    id: row['id']! as String,
    name: row['name']! as String,
    kind: CategoryKind.parse(row['kind']),
    parentId: row['parent_id'] as String?,
    icon: row['icon'] as String?,
    color: row['color'] as String?,
    systemKey: row['system_key'] as String?,
  );

  final String id;
  final String name;
  final CategoryKind kind;

  /// Родитель верхнего уровня того же вида (мягкая ссылка) или `null`.
  final String? parentId;
  final String? icon;

  /// `#RRGGBB`.
  final String? color;

  /// У предустановленных — ключ из spec 3.2; неизменяем.
  final String? systemKey;

  bool get isPreset => systemKey != null;

  Json toFields() => {
    'name': name,
    'kind': kind.wire,
    'parent_id': parentId,
    'icon': icon,
    'color': color,
    'system_key': systemKey,
  };

  Json toRow() => {'id': id, ...toFields()};

  FinanceCategory copyWith({
    String? name,
    CategoryKind? kind,
    Object? parentId = _unset,
    Object? icon = _unset,
    Object? color = _unset,
  }) => FinanceCategory(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    parentId: identical(parentId, _unset) ? this.parentId : parentId as String?,
    icon: identical(icon, _unset) ? this.icon : icon as String?,
    color: identical(color, _unset) ? this.color : color as String?,
    systemKey: systemKey,
  );
}

/// Операция (`transactions`): расход, доход или перевод.
@immutable
class FinanceTransaction {
  const FinanceTransaction({
    required this.id,
    required this.kind,
    required this.accountId,
    required this.amount,
    required this.occurredAt,
    this.toAccountId,
    this.categoryId,
    this.merchant,
    this.comment,
    this.source = TransactionSource.manual,
    this.status = TransactionStatus.confirmed,
    this.externalId,
    this.dedupHash,
    this.workPaymentId,
    this.debtId,
  });

  factory FinanceTransaction.fromRow(Json row) => FinanceTransaction(
    id: row['id']! as String,
    kind: TransactionKind.parse(row['kind']),
    accountId: row['account_id']! as String,
    toAccountId: row['to_account_id'] as String?,
    amount: row['amount']! as int,
    occurredAt: _instant(row['occurred_at']),
    categoryId: row['category_id'] as String?,
    merchant: row['merchant'] as String?,
    comment: row['comment'] as String?,
    source: TransactionSource.parse(row['source']),
    status: TransactionStatus.parse(row['status']),
    externalId: row['external_id'] as String?,
    dedupHash: row['dedup_hash'] as String?,
    workPaymentId: row['work_payment_id'] as String?,
    debtId: row['debt_id'] as String?,
  );

  final String id;
  final TransactionKind kind;

  /// Счёт операции; у перевода — «откуда».
  final String accountId;

  /// Только у перевода — «куда».
  final String? toAccountId;

  /// Копейки, всегда положительные: знак задаёт [kind].
  final int amount;

  /// Момент (UTC, целые секунды); месяц и день — по Москве.
  final DateTime occurredAt;
  final String? categoryId;
  final String? merchant;
  final String? comment;
  final TransactionSource source;
  final TransactionStatus status;
  final String? externalId;
  final String? dedupHash;
  final String? workPaymentId;
  final String? debtId;

  bool get isTransfer => kind == TransactionKind.transfer;

  /// Московская дата операции `YYYY-MM-DD`.
  String get moscowDay => moscowDateOfSeconds(
    occurredAt.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond,
  );

  Json toFields() => {
    'kind': kind.wire,
    'account_id': accountId,
    'to_account_id': toAccountId,
    'amount': amount,
    'occurred_at': _stored(occurredAt),
    'category_id': categoryId,
    'merchant': merchant,
    'comment': comment,
    'source': source.wire,
    'status': status.wire,
    'external_id': externalId,
    'dedup_hash': dedupHash,
    'work_payment_id': workPaymentId,
    'debt_id': debtId,
  };

  Json toRow() => {'id': id, ...toFields()};

  FinanceTransaction copyWith({
    TransactionKind? kind,
    String? accountId,
    Object? toAccountId = _unset,
    int? amount,
    DateTime? occurredAt,
    Object? categoryId = _unset,
    Object? merchant = _unset,
    Object? comment = _unset,
    TransactionStatus? status,
  }) => FinanceTransaction(
    id: id,
    kind: kind ?? this.kind,
    accountId: accountId ?? this.accountId,
    toAccountId: identical(toAccountId, _unset)
        ? this.toAccountId
        : toAccountId as String?,
    amount: amount ?? this.amount,
    occurredAt: occurredAt ?? this.occurredAt,
    categoryId: identical(categoryId, _unset)
        ? this.categoryId
        : categoryId as String?,
    merchant: identical(merchant, _unset) ? this.merchant : merchant as String?,
    comment: identical(comment, _unset) ? this.comment : comment as String?,
    source: source,
    status: status ?? this.status,
    externalId: externalId,
    dedupHash: dedupHash,
    workPaymentId: workPaymentId,
    debtId: debtId,
  );
}

/// Точка сверки баланса (`balance_checkpoints`).
@immutable
class BalanceCheckpoint {
  const BalanceCheckpoint({
    required this.id,
    required this.accountId,
    required this.checkedAt,
    required this.actualBalance,
    this.source = CheckpointSource.manual,
    this.note,
  });

  factory BalanceCheckpoint.fromRow(Json row) => BalanceCheckpoint(
    id: row['id']! as String,
    accountId: row['account_id']! as String,
    checkedAt: _instant(row['checked_at']),
    actualBalance: row['actual_balance']! as int,
    source: CheckpointSource.parse(row['source']),
    note: row['note'] as String?,
  );

  final String id;
  final String accountId;

  /// Момент, на который баланс известен (UTC, целые секунды).
  final DateTime checkedAt;

  /// Фактический баланс счёта, копейки со знаком.
  final int actualBalance;
  final CheckpointSource source;
  final String? note;

  Json toFields() => {
    'account_id': accountId,
    'checked_at': _stored(checkedAt),
    'actual_balance': actualBalance,
    'source': source.wire,
    'note': note,
  };

  Json toRow() => {'id': id, ...toFields()};
}

/// Корректировка сверки (spec 4.4): сколько не хватало «у нас» до факта.
@immutable
class BalanceAdjustment {
  const BalanceAdjustment({
    required this.checkpointId,
    required this.checkedAt,
    required this.actual,
    required this.expected,
  });

  factory BalanceAdjustment.fromJson(Json json) => BalanceAdjustment(
    checkpointId: json['checkpoint_id']! as String,
    checkedAt: _instant(json['checked_at']),
    actual: json['actual']! as int,
    expected: json['expected']! as int,
  );

  final String checkpointId;
  final DateTime checkedAt;

  /// Фактический баланс из банка.
  final int actual;

  /// Баланс на этот момент по учёту (от открытия и более ранних точек).
  final int expected;

  /// `actual - expected`: положительная — в банке больше, чем «у нас».
  int get adjustment => actual - expected;
}

/// Долг (`debts`): статус не хранится, он вычисляется (spec 6.1).
@immutable
class Debt {
  const Debt({
    required this.id,
    required this.direction,
    required this.amount,
    required this.debtDate,
    this.personId,
    this.counterparty,
    this.dueDate,
    this.comment,
  });

  factory Debt.fromRow(Json row) => Debt(
    id: row['id']! as String,
    direction: DebtDirection.parse(row['direction']),
    personId: row['person_id'] as String?,
    counterparty: row['counterparty'] as String?,
    amount: row['amount']! as int,
    debtDate: row['debt_date']! as String,
    dueDate: row['due_date'] as String?,
    comment: row['comment'] as String?,
  );

  final String id;
  final DebtDirection direction;

  /// Контрагент из «Людей» (мягкая ссылка); пока клиента «Работы» нет,
  /// остаётся `null`.
  final String? personId;

  /// Контрагент текстом.
  final String? counterparty;

  /// Исходная сумма, копейки.
  final int amount;

  /// Дата долга `YYYY-MM-DD`.
  final String debtDate;

  /// Срок `YYYY-MM-DD`; не раньше [debtDate].
  final String? dueDate;
  final String? comment;

  /// Имя для списков: контрагент или «Без имени».
  String get who {
    final name = counterparty?.trim();
    return name == null || name.isEmpty ? 'Без имени' : name;
  }

  Json toFields() => {
    'direction': direction.wire,
    'person_id': personId,
    'counterparty': counterparty,
    'amount': amount,
    'debt_date': debtDate,
    'due_date': dueDate,
    'comment': comment,
  };

  Json toRow() => {'id': id, ...toFields()};

  Debt copyWith({
    DebtDirection? direction,
    Object? counterparty = _unset,
    int? amount,
    String? debtDate,
    Object? dueDate = _unset,
    Object? comment = _unset,
  }) => Debt(
    id: id,
    direction: direction ?? this.direction,
    personId: personId,
    counterparty: identical(counterparty, _unset)
        ? this.counterparty
        : counterparty as String?,
    amount: amount ?? this.amount,
    debtDate: debtDate ?? this.debtDate,
    dueDate: identical(dueDate, _unset) ? this.dueDate : dueDate as String?,
    comment: identical(comment, _unset) ? this.comment : comment as String?,
  );
}

/// Погашение долга (`debt_repayments`); `debt_id` неизменяем.
@immutable
class DebtRepayment {
  const DebtRepayment({
    required this.id,
    required this.debtId,
    required this.amount,
    required this.repaidOn,
    this.transactionId,
    this.note,
  });

  factory DebtRepayment.fromRow(Json row) => DebtRepayment(
    id: row['id']! as String,
    debtId: row['debt_id']! as String,
    amount: row['amount']! as int,
    repaidOn: row['repaid_on']! as String,
    transactionId: row['transaction_id'] as String?,
    note: row['note'] as String?,
  );

  final String id;
  final String debtId;

  /// Копейки, больше нуля.
  final int amount;

  /// Дата погашения `YYYY-MM-DD`.
  final String repaidOn;

  /// Операция счёта, которой деньги реально двигались (её `debt_id` — этот
  /// долг); `null` — «списать без движения денег».
  final String? transactionId;
  final String? note;

  Json toFields() => {
    'debt_id': debtId,
    'amount': amount,
    'repaid_on': repaidOn,
    'transaction_id': transactionId,
    'note': note,
  };

  Json toRow() => {'id': id, ...toFields()};

  DebtRepayment copyWith({
    int? amount,
    String? repaidOn,
    Object? transactionId = _unset,
    Object? note = _unset,
  }) => DebtRepayment(
    id: id,
    debtId: debtId,
    amount: amount ?? this.amount,
    repaidOn: repaidOn ?? this.repaidOn,
    transactionId: identical(transactionId, _unset)
        ? this.transactionId
        : transactionId as String?,
    note: identical(note, _unset) ? this.note : note as String?,
  );
}
