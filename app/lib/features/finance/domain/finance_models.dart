import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/features/work/domain/work_models.dart'
    show storedWorkInstant;

/// Модели «Финансов» (spec Этапа 5, раздел 1). Даты — строки
/// `YYYY-MM-DD` (как в эталоне: сравнение строк), моменты — UTC
/// [DateTime] без долей секунды, деньги — целые копейки.
///
/// Чтение «мягкое»: строка с неизвестным значением перечисления (новая
/// версия сервера) читается как безопасное значение по умолчанию, а не
/// ломает экран; недостающие необязательные колонки читаются как `null`.

const Object _unset = Object();

/// Момент из строки `…Z`; доли секунды отбрасываются (все правила
/// считаются в целых секундах, spec 0). Непонятное значение — `2015-01-01`.
DateTime parseFinanceInstant(Object? value) {
  final parsed = value is String ? DateTime.tryParse(value)?.toUtc() : null;
  if (parsed == null) return DateTime.utc(2015);
  return DateTime.fromMillisecondsSinceEpoch(
    (parsed.millisecondsSinceEpoch ~/ 1000) * 1000,
    isUtc: true,
  );
}

/// Момент в виде колонки `datetime` (`…Z`, без долей).
String financeInstantText(DateTime value) => storedWorkInstant(value)!;

/// Вид счёта.
enum AccountKind {
  cash('Наличные', 'cash'),
  debitCard('Дебетовая карта', 'debit_card'),
  creditCard('Кредитная карта', 'credit_card'),
  savings('Накопительный счёт', 'savings'),
  deposit('Вклад', 'deposit'),
  other('Другое', 'other');

  const AccountKind(this.label, this.wire);

  final String label;
  final String wire;

  static AccountKind parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return other;
  }

  bool get isCard => this == debitCard || this == creditCard;
}

/// Вид категории.
enum CategoryKind {
  expense('Расход', 'expense'),
  income('Доход', 'income');

  const CategoryKind(this.label, this.wire);

  final String label;
  final String wire;

  static CategoryKind parse(Object? value) =>
      value == 'income' ? income : expense;
}

/// Вид операции.
enum TxKind {
  expense('Расход', 'expense'),
  income('Доход', 'income'),
  transfer('Перевод', 'transfer');

  const TxKind(this.label, this.wire);

  final String label;
  final String wire;

  static TxKind parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return expense;
  }
}

/// Источник операции.
enum TxSource {
  manual('Вручную', 'manual'),
  notification('Уведомление банка', 'notification'),
  statement('Выписка', 'statement'),
  workPayment('Платёж по проекту', 'work_payment');

  const TxSource(this.label, this.wire);

  final String label;
  final String wire;

  static TxSource parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return manual;
  }
}

/// Статус операции: считается только [confirmed] (spec 4.3).
enum TxStatus {
  confirmed('Подтверждена', 'confirmed'),
  draft('Черновик', 'draft'),
  needsReview('Требует проверки', 'needs_review');

  const TxStatus(this.label, this.wire);

  final String label;
  final String wire;

  /// Неизвестное значение читается как неподтверждённое: в суммы не
  /// попадёт.
  static TxStatus parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return needsReview;
  }
}

/// Источник точки сверки.
enum CheckpointSource {
  manual('manual'),
  notification('notification'),
  statement('statement');

  const CheckpointSource(this.wire);

  final String wire;

  static CheckpointSource parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return manual;
  }
}

/// Направление долга.
enum DebtDirection {
  owedToMe('Мне должны', 'owed_to_me'),
  iOwe('Я должен', 'i_owe');

  const DebtDirection(this.label, this.wire);

  final String label;
  final String wire;

  static DebtDirection parse(Object? value) =>
      value == 'i_owe' ? iOwe : owedToMe;
}

/// Статус долга (вычисляется, spec 6.1).
enum DebtStatus {
  open('Открыт', 'open'),
  partial('Частично', 'partial'),
  closed('Закрыт', 'closed');

  const DebtStatus(this.label, this.wire);

  final String label;
  final String wire;
}

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
    id: (row['id'] as String?) ?? '',
    name: (row['name'] as String?) ?? '',
    kind: AccountKind.parse(row['kind']),
    bank: row['bank'] as String?,
    cardLast4: row['card_last4'] as String?,
    openingBalance: (row['opening_balance'] as int?) ?? 0,
    openingDate: (row['opening_date'] as String?) ?? '2015-01-01',
    includeInTotal: row['include_in_total'] != false,
    creditLimit: row['credit_limit'] as int?,
    archived: row['archived'] == true,
  );

  final String id;
  final String name;
  final AccountKind kind;
  final String? bank;
  final String? cardLast4;
  final int openingBalance;

  /// `YYYY-MM-DD`: с начала этих московских суток счёт «открыт».
  final String openingDate;
  final bool includeInTotal;

  /// Справочное поле кредитки: в расчёты не входит.
  final int? creditLimit;
  final bool archived;

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
class FinCategory {
  const FinCategory({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    this.icon,
    this.color,
    this.systemKey,
  });

  factory FinCategory.fromRow(Json row) => FinCategory(
    id: (row['id'] as String?) ?? '',
    name: (row['name'] as String?) ?? '',
    kind: CategoryKind.parse(row['kind']),
    parentId: row['parent_id'] as String?,
    icon: row['icon'] as String?,
    color: row['color'] as String?,
    systemKey: row['system_key'] as String?,
  );

  final String id;
  final String name;
  final CategoryKind kind;

  /// Мягкая ссылка на категорию верхнего уровня.
  final String? parentId;
  final String? icon;
  final String? color;

  /// Неизменяем; у пользовательских — `null`.
  final String? systemKey;

  /// Колонки для создания (`system_key` неизменяем и в правку не идёт).
  Json toFields() => {
    'name': name,
    'kind': kind.wire,
    'parent_id': parentId,
    'icon': icon,
    'color': color,
    'system_key': systemKey,
  };

  FinCategory copyWith({
    String? name,
    CategoryKind? kind,
    Object? parentId = _unset,
    Object? icon = _unset,
    Object? color = _unset,
  }) => FinCategory(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    parentId: identical(parentId, _unset) ? this.parentId : parentId as String?,
    icon: identical(icon, _unset) ? this.icon : icon as String?,
    color: identical(color, _unset) ? this.color : color as String?,
    systemKey: systemKey,
  );
}

/// Операция (`transactions`).
@immutable
class FinTransaction {
  const FinTransaction({
    required this.id,
    required this.kind,
    required this.accountId,
    required this.amount,
    required this.occurredAt,
    this.toAccountId,
    this.categoryId,
    this.merchant,
    this.comment,
    this.source = TxSource.manual,
    this.status = TxStatus.confirmed,
    this.externalId,
    this.dedupHash,
    this.workPaymentId,
    this.debtId,
  });

  factory FinTransaction.fromRow(Json row) => FinTransaction(
    id: (row['id'] as String?) ?? '',
    kind: TxKind.parse(row['kind']),
    accountId: (row['account_id'] as String?) ?? '',
    toAccountId: row['to_account_id'] as String?,
    amount: (row['amount'] as int?) ?? 0,
    occurredAt: parseFinanceInstant(row['occurred_at']),
    categoryId: row['category_id'] as String?,
    merchant: row['merchant'] as String?,
    comment: row['comment'] as String?,
    source: TxSource.parse(row['source']),
    status: row.containsKey('status')
        ? TxStatus.parse(row['status'])
        : TxStatus.confirmed,
    externalId: row['external_id'] as String?,
    dedupHash: row['dedup_hash'] as String?,
    workPaymentId: row['work_payment_id'] as String?,
    debtId: row['debt_id'] as String?,
  );

  final String id;
  final TxKind kind;

  /// Счёт операции (у перевода — откуда).
  final String accountId;

  /// Только у перевода — куда.
  final String? toAccountId;

  /// Всегда положительная; знак задаёт [kind].
  final int amount;
  final DateTime occurredAt;
  final String? categoryId;
  final String? merchant;
  final String? comment;
  final TxSource source;
  final TxStatus status;
  final String? externalId;
  final String? dedupHash;
  final String? workPaymentId;
  final String? debtId;

  bool get isConfirmed => status == TxStatus.confirmed;

  Json toFields() => {
    'kind': kind.wire,
    'account_id': accountId,
    'to_account_id': toAccountId,
    'amount': amount,
    'occurred_at': financeInstantText(occurredAt),
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

  FinTransaction copyWith({
    TxKind? kind,
    String? accountId,
    Object? toAccountId = _unset,
    int? amount,
    DateTime? occurredAt,
    Object? categoryId = _unset,
    Object? merchant = _unset,
    Object? comment = _unset,
    TxSource? source,
    TxStatus? status,
    Object? externalId = _unset,
    Object? dedupHash = _unset,
    Object? workPaymentId = _unset,
    Object? debtId = _unset,
  }) => FinTransaction(
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
    source: source ?? this.source,
    status: status ?? this.status,
    externalId: identical(externalId, _unset)
        ? this.externalId
        : externalId as String?,
    dedupHash: identical(dedupHash, _unset)
        ? this.dedupHash
        : dedupHash as String?,
    workPaymentId: identical(workPaymentId, _unset)
        ? this.workPaymentId
        : workPaymentId as String?,
    debtId: identical(debtId, _unset) ? this.debtId : debtId as String?,
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
    id: (row['id'] as String?) ?? '',
    accountId: (row['account_id'] as String?) ?? '',
    checkedAt: parseFinanceInstant(row['checked_at']),
    actualBalance: (row['actual_balance'] as int?) ?? 0,
    source: CheckpointSource.parse(row['source']),
    note: row['note'] as String?,
  );

  final String id;
  final String accountId;
  final DateTime checkedAt;

  /// Фактический баланс счёта на момент (как в банке).
  final int actualBalance;
  final CheckpointSource source;
  final String? note;

  Json toFields() => {
    'account_id': accountId,
    'checked_at': financeInstantText(checkedAt),
    'actual_balance': actualBalance,
    'source': source.wire,
    'note': note,
  };
}

/// Долг (`debts`); статус не хранится (spec 6.1).
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
    id: (row['id'] as String?) ?? '',
    direction: DebtDirection.parse(row['direction']),
    personId: row['person_id'] as String?,
    counterparty: row['counterparty'] as String?,
    amount: (row['amount'] as int?) ?? 0,
    debtDate: (row['debt_date'] as String?) ?? '2015-01-01',
    dueDate: row['due_date'] as String?,
    comment: row['comment'] as String?,
  );

  final String id;
  final DebtDirection direction;

  /// Мягкая ссылка на `people.id`.
  final String? personId;
  final String? counterparty;

  /// Исходная сумма.
  final int amount;
  final String debtDate;
  final String? dueDate;
  final String? comment;

  Json toFields() => {
    'direction': direction.wire,
    'person_id': personId,
    'counterparty': counterparty,
    'amount': amount,
    'debt_date': debtDate,
    'due_date': dueDate,
    'comment': comment,
  };

  Debt copyWith({
    DebtDirection? direction,
    Object? personId = _unset,
    Object? counterparty = _unset,
    int? amount,
    String? debtDate,
    Object? dueDate = _unset,
    Object? comment = _unset,
  }) => Debt(
    id: id,
    direction: direction ?? this.direction,
    personId: identical(personId, _unset) ? this.personId : personId as String?,
    counterparty: identical(counterparty, _unset)
        ? this.counterparty
        : counterparty as String?,
    amount: amount ?? this.amount,
    debtDate: debtDate ?? this.debtDate,
    dueDate: identical(dueDate, _unset) ? this.dueDate : dueDate as String?,
    comment: identical(comment, _unset) ? this.comment : comment as String?,
  );
}

/// Погашение долга (`debt_repayments`).
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
    id: (row['id'] as String?) ?? '',
    debtId: (row['debt_id'] as String?) ?? '',
    amount: (row['amount'] as int?) ?? 0,
    repaidOn: (row['repaid_on'] as String?) ?? '2015-01-01',
    transactionId: row['transaction_id'] as String?,
    note: row['note'] as String?,
  );

  final String id;
  final String debtId;
  final int amount;
  final String repaidOn;

  /// Мягкая ссылка на операцию, которой деньги реально двигались.
  final String? transactionId;
  final String? note;

  Json toFields() => {
    'debt_id': debtId,
    'amount': amount,
    'repaid_on': repaidOn,
    'transaction_id': transactionId,
    'note': note,
  };
}

/// Вид слагаемого формулы «Есть» (spec 6.2).
enum GoalTermKind {
  accounts('Конкретные счета', 'accounts'),
  allAccounts('Все счета в общем балансе', 'all_accounts'),
  debtsToMe('Долги мне', 'debts_to_me'),
  myDebts('Мои долги', 'my_debts'),
  receivables('Ожидаемые из «Работы»', 'receivables');

  const GoalTermKind(this.label, this.wire);

  final String label;
  final String wire;

  static GoalTermKind? parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return null;
  }
}

/// Слагаемое формулы цели: величина неотрицательна, знак делает её
/// прибавкой или вычетом.
@immutable
class GoalTerm {
  const GoalTerm({
    required this.kind,
    this.plus = true,
    this.accountIds = const [],
    this.clientIds,
  });

  /// `null` — слагаемое неизвестного вида (из будущей версии) пропускается.
  static GoalTerm? fromJson(Object? value) {
    if (value is! Map) return null;
    final kind = GoalTermKind.parse(value['kind']);
    if (kind == null) return null;
    List<String>? ids(Object? raw) => raw is List
        ? [
            for (final item in raw)
              if (item is String) item,
          ]
        : null;
    return GoalTerm(
      kind: kind,
      plus: value['sign'] != '-',
      accountIds: ids(value['account_ids']) ?? const [],
      clientIds: ids(value['client_ids']),
    );
  }

  final GoalTermKind kind;
  final bool plus;

  /// Только у [GoalTermKind.accounts].
  final List<String> accountIds;

  /// Только у [GoalTermKind.receivables]; `null` — все заказчики.
  final List<String>? clientIds;

  /// Слагаемое в виде колонки `formula` (только свои ключи, spec 3.1).
  Json toJson() => {
    'kind': kind.wire,
    'sign': plus ? '+' : '-',
    if (kind == GoalTermKind.accounts) 'account_ids': accountIds,
    if (kind == GoalTermKind.receivables) 'client_ids': clientIds,
  };

  GoalTerm copyWith({
    bool? plus,
    List<String>? accountIds,
    Object? clientIds = _unset,
  }) => GoalTerm(
    kind: kind,
    plus: plus ?? this.plus,
    accountIds: accountIds ?? this.accountIds,
    clientIds: identical(clientIds, _unset)
        ? this.clientIds
        : clientIds as List<String>?,
  );
}

/// Формула по умолчанию: случай из Excel заказчика (spec 6.2).
List<GoalTerm> defaultGoalFormula() => const [
  GoalTerm(kind: GoalTermKind.allAccounts),
  GoalTerm(kind: GoalTermKind.debtsToMe),
  GoalTerm(kind: GoalTermKind.receivables),
];

/// Цель (`goals`).
@immutable
class Goal {
  const Goal({
    required this.id,
    required this.name,
    required this.targetAmount,
    required this.formula,
    this.deadlineDate,
    this.archived = false,
  });

  factory Goal.fromRow(Json row) {
    final raw = row['formula'];
    return Goal(
      id: (row['id'] as String?) ?? '',
      name: (row['name'] as String?) ?? '',
      targetAmount: (row['target_amount'] as int?) ?? 0,
      deadlineDate: row['deadline_date'] as String?,
      formula: raw is List
          ? [for (final item in raw) ?GoalTerm.fromJson(item)]
          : const [],
      archived: row['archived'] == true,
    );
  }

  final String id;
  final String name;
  final int targetAmount;
  final String? deadlineDate;
  final List<GoalTerm> formula;
  final bool archived;

  Json toFields() => {
    'name': name,
    'target_amount': targetAmount,
    'deadline_date': deadlineDate,
    'formula': [for (final t in formula) t.toJson()],
    'archived': archived,
  };

  Goal copyWith({
    String? name,
    int? targetAmount,
    Object? deadlineDate = _unset,
    List<GoalTerm>? formula,
    bool? archived,
  }) => Goal(
    id: id,
    name: name ?? this.name,
    targetAmount: targetAmount ?? this.targetAmount,
    deadlineDate: identical(deadlineDate, _unset)
        ? this.deadlineDate
        : deadlineDate as String?,
    formula: formula ?? this.formula,
    archived: archived ?? this.archived,
  );
}
