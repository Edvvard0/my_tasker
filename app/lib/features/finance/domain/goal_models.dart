import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';

const Object _unset = Object();

/// Вид слагаемого формулы «Есть» (spec Этапа 5, 6.2).
enum GoalTermKind {
  accounts('accounts', 'Выбранные счета'),
  allAccounts('all_accounts', 'Все счета'),
  debtsToMe('debts_to_me', 'Мне должны'),
  myDebts('my_debts', 'Я должен'),
  receivables('receivables', 'Ожидаемые поступления');

  const GoalTermKind(this.wire, this.label);

  /// Значение `kind` в JSON формулы.
  final String wire;
  final String label;

  static GoalTermKind? tryParse(Object? value) {
    for (final k in values) {
      if (k.wire == value) return k;
    }
    return null;
  }
}

/// Знак слагаемого: прибавка или вычет.
enum GoalSign {
  plus('+', '+'),
  minus('-', '−');

  const GoalSign(this.wire, this.label);

  /// Значение `sign` в JSON формулы (`+` / `-`).
  final String wire;

  /// Подпись с настоящим минусом.
  final String label;

  static GoalSign? tryParse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return null;
  }
}

/// Слагаемое формулы: `{kind, sign, [account_ids | client_ids]}`; только
/// «свои» ключи вида (spec 3.1).
@immutable
class GoalTerm {
  const GoalTerm({
    required this.kind,
    this.sign = GoalSign.plus,
    this.accountIds,
    this.clientIds,
  });

  /// Слагаемое по умолчанию для вида [kind]: `my_debts` — вычет (spec 6.2),
  /// остальные — прибавка; у `accounts` список пуст, пока не выбраны счета.
  factory GoalTerm.initial(GoalTermKind kind) => GoalTerm(
    kind: kind,
    sign: kind == GoalTermKind.myDebts ? GoalSign.minus : GoalSign.plus,
    accountIds: kind == GoalTermKind.accounts ? const [] : null,
  );

  /// Из JSON-слагаемого; `null`, если вид или знак неизвестны.
  static GoalTerm? tryParse(Object? json) {
    if (json is! Map) return null;
    final kind = GoalTermKind.tryParse(json['kind']);
    final sign = GoalSign.tryParse(json['sign']);
    if (kind == null || sign == null) return null;
    List<String>? ids(Object? value) =>
        value is List ? [for (final v in value) '$v'] : null;
    return GoalTerm(
      kind: kind,
      sign: sign,
      accountIds: kind == GoalTermKind.accounts
          ? (ids(json['account_ids']) ?? const [])
          : null,
      clientIds: kind == GoalTermKind.receivables
          ? ids(json['client_ids'])
          : null,
    );
  }

  final GoalTermKind kind;
  final GoalSign sign;

  /// Только у `accounts`: счета слагаемого (1–50 при сохранении).
  final List<String>? accountIds;

  /// Только у `receivables`: заказчики Работы; `null` — все.
  final List<String>? clientIds;

  /// JSON слагаемого — ровно «свои» ключи вида.
  Json toJson() => {
    'kind': kind.wire,
    'sign': sign.wire,
    if (kind == GoalTermKind.accounts) 'account_ids': accountIds ?? const [],
    if (kind == GoalTermKind.receivables) 'client_ids': clientIds,
  };

  GoalTerm copyWith({GoalSign? sign, Object? accountIds = _unset}) => GoalTerm(
    kind: kind,
    sign: sign ?? this.sign,
    accountIds: identical(accountIds, _unset)
        ? this.accountIds
        : accountIds as List<String>?,
    clientIds: clientIds,
  );

  @override
  bool operator ==(Object other) =>
      other is GoalTerm &&
      other.kind == kind &&
      other.sign == sign &&
      listEquals(other.accountIds, accountIds) &&
      listEquals(other.clientIds, clientIds);

  @override
  int get hashCode => Object.hash(
    kind,
    sign,
    Object.hashAll(accountIds ?? const []),
    Object.hashAll(clientIds ?? const []),
  );
}

/// Формула по умолчанию у новой цели (spec 6.2): воспроизводит расчёт из
/// Excel заказчика — общий баланс, долги мне, ожидаемые поступления Работы.
/// «Мои долги» в неё не входят.
List<GoalTerm> defaultGoalFormula() => const [
  GoalTerm(kind: GoalTermKind.allAccounts),
  GoalTerm(kind: GoalTermKind.debtsToMe),
  GoalTerm(kind: GoalTermKind.receivables),
];

/// JSON формулы (колонка `formula`).
List<Json> formulaToJson(List<GoalTerm> terms) => [
  for (final t in terms) t.toJson(),
];

/// Цель (`goals`): формула «Есть» хранится списком слагаемых.
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

  factory Goal.fromRow(Json row) => Goal(
    id: row['id']! as String,
    name: row['name']! as String,
    targetAmount: row['target_amount']! as int,
    deadlineDate: row['deadline_date'] as String?,
    formula: [
      for (final t in (row['formula'] as List<Object?>? ?? const []))
        ?GoalTerm.tryParse(t),
    ],
    archived: row['archived']! as bool,
  );

  final String id;
  final String name;

  /// Целевая сумма, копейки, ≥ 1.
  final int targetAmount;

  /// Срок `YYYY-MM-DD` или `null`.
  final String? deadlineDate;

  /// Слагаемые формулы «Есть».
  final List<GoalTerm> formula;
  final bool archived;

  /// В формуле есть ожидаемые поступления из Работы: пока клиента «Работы»
  /// нет, они считаются как 0.
  bool get hasReceivables =>
      formula.any((t) => t.kind == GoalTermKind.receivables);

  Json toFields() => {
    'name': name,
    'target_amount': targetAmount,
    'deadline_date': deadlineDate,
    'formula': formulaToJson(formula),
    'archived': archived,
  };

  Json toRow() => {'id': id, ...toFields()};

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
