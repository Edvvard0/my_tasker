import 'dart:convert';

import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/finance/preset_categories.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';

/// Клиентская проверка значений до записи в outbox: зеркало серверной
/// (`backend/src/tasker/finance/schema.py`, spec Этапа 5, 1 и 3.1), но с
/// русскими сообщениями для формы. Возвращает первую проблему или `null`.
/// Строки обрезаются репозиторием до проверки, поэтому длина считается по
/// обрезанным значениям.

final RegExp _last4Pattern = RegExp(r'^[0-9]{4}$');
final RegExp _hashPattern = RegExp(r'^[0-9a-f]{16,64}$');
final RegExp _systemKeyPattern = RegExp(r'^[a-z][a-z0-9_.]{0,47}$');

/// Не раньше 2015-01-01 и не позже года 2200 (диапазон значений sync).
String? _momentProblem(DateTime instant, String what) {
  final seconds = instant.millisecondsSinceEpoch ~/ 1000;
  if (seconds < financeEpochSeconds) {
    return '$what не может быть раньше 1 января 2015';
  }
  if (instant.year >= maxYear) return '$what: год вне диапазона';
  return null;
}

String? _signedMoneyProblem(int value, String what) =>
    value.abs() > maxKopecks ? '$what вне допустимого диапазона' : null;

String? _textProblem(String? value, int max, String what, {int min = 0}) {
  if (value == null) return null;
  if (value.length < min) return '$what не может быть пустым';
  if (value.length > max) return '$what — не длиннее $max символов';
  return null;
}

/// Счёт (spec 1.1).
String? accountProblem(Account a) {
  final name = nameProblem(a.name, 100, what: 'Название счёта');
  if (name != null) return name;
  final bank = _textProblem(a.bank, 100, 'Банк');
  if (bank != null) return bank;
  if (a.cardLast4 != null) {
    if (!a.kind.isCard) return 'Последние цифры есть только у карты';
    if (!_last4Pattern.hasMatch(a.cardLast4!)) {
      return 'Последние цифры карты — ровно 4 цифры';
    }
  }
  final balance = _signedMoneyProblem(a.openingBalance, 'Начальный баланс');
  if (balance != null) return balance;
  if (parseDate(a.openingDate) == null) return 'Дата открытия — реальная дата';
  final limit = a.creditLimit;
  if (limit != null) {
    if (a.kind != AccountKind.creditCard) {
      return 'Кредитный лимит бывает только у кредитной карты';
    }
    if (limit < 0 || limit > maxKopecks) {
      return 'Кредитный лимит вне допустимого диапазона';
    }
  }
  return null;
}

/// Категория (spec 1.2) без проверки родителя — её делает
/// [categoryParentProblem].
String? categoryProblem(FinanceCategory c) {
  final name = nameProblem(c.name, 100, what: 'Название категории');
  if (name != null) return name;
  final icon = _textProblem(c.icon, 50, 'Иконка', min: 1);
  if (icon != null) return icon;
  final color = colorProblem(c.color);
  if (color != null) return color;
  final key = c.systemKey;
  if (key != null) {
    if (!_systemKeyPattern.hasMatch(key) ||
        !presetCategories.any((p) => p.key == key)) {
      return 'Неизвестный ключ предустановленной категории';
    }
  }
  return null;
}

/// Родитель категории: у подкатегории родитель — живая категория верхнего
/// уровня того же вида (spec 1.2, `category_parent_invalid`); у категории с
/// подкатегориями родителя быть не может ([hasChildren]).
String? categoryParentProblem(
  FinanceCategory c,
  FinanceCategory? parent, {
  bool hasChildren = false,
}) {
  final parentId = c.parentId;
  if (parentId == null) return null;
  if (parentId == c.id) return 'Категория не может быть своим родителем';
  if (hasChildren) return 'У категории с подкатегориями не может быть родителя';
  if (parent == null) return 'Родительская категория не найдена';
  if (parent.parentId != null) return 'Подкатегории — только два уровня';
  if (parent.kind != c.kind) {
    return 'Подкатегория того же вида, что и родитель';
  }
  return null;
}

/// Операция (spec 1.3, межполевые правила и `validation_failed`).
String? transactionProblem(FinanceTransaction t) {
  if (t.amount < 1 || t.amount > maxKopecks) {
    return 'Сумма — от 0,01 ₽ до ${formatAmount(maxKopecks)}';
  }
  final moment = _momentProblem(t.occurredAt, 'Дата операции');
  if (moment != null) return moment;
  final merchant = _textProblem(t.merchant, 200, 'Мерчант');
  if (merchant != null) return merchant;
  final comment = _textProblem(t.comment, 2000, 'Комментарий');
  if (comment != null) return comment;
  final external = _textProblem(t.externalId, 200, 'Внешний id', min: 1);
  if (external != null) return external;
  if (t.dedupHash != null && !_hashPattern.hasMatch(t.dedupHash!)) {
    return 'Хеш операции — 16–64 символа 0-9a-f';
  }
  if (t.isTransfer) {
    if (t.toAccountId == null) return 'У перевода нужен счёт «куда»';
    if (t.toAccountId == t.accountId) {
      return 'Перевод — между двумя разными счетами';
    }
    if (t.categoryId != null) return 'У перевода не бывает категории';
    if (t.workPaymentId != null) return 'У перевода не бывает платежа Работы';
    if (t.debtId != null) return 'У перевода не бывает долга';
  } else if (t.toAccountId != null) {
    return 'Счёт «куда» бывает только у перевода';
  }
  if (t.workPaymentId != null && t.kind != TransactionKind.income) {
    return 'Платёж Работы привязывается только к доходу';
  }
  if ((t.source == TransactionSource.workPayment) !=
      (t.workPaymentId != null)) {
    return 'Источник «платёж по проекту» и ссылка на платёж — вместе';
  }
  return null;
}

/// Точка сверки (spec 1.4).
String? checkpointProblem(BalanceCheckpoint c) {
  final moment = _momentProblem(c.checkedAt, 'Дата сверки');
  if (moment != null) return moment;
  final balance = _signedMoneyProblem(c.actualBalance, 'Фактический баланс');
  if (balance != null) return balance;
  return _textProblem(c.note, 500, 'Заметка');
}

String? _positiveMoneyProblem(int value, String what) =>
    value < 1 || value > maxKopecks
    ? '$what — от 0,01 ₽ до ${formatAmount(maxKopecks)}'
    : null;

/// Код расхождения погашения и операции (spec 1.6, раздел 8).
const String repaymentTransactionMismatchCode =
    'repayment_transaction_mismatch';

/// Долг (spec 1.5): контрагент текстом (человека из «Работы» пока нет),
/// сумма, реальные даты, срок не раньше даты долга.
String? debtProblem(Debt d) {
  if (d.personId == null && isBlank(d.counterparty)) {
    return 'Укажи, кто должен или кому должен ты';
  }
  final who = _textProblem(d.counterparty, 200, 'Контрагент');
  if (who != null) return who;
  final amount = _positiveMoneyProblem(d.amount, 'Сумма долга');
  if (amount != null) return amount;
  if (parseDate(d.debtDate) == null) return 'Дата долга — реальная дата';
  final due = d.dueDate;
  if (due != null) {
    if (parseDate(due) == null) return 'Срок — реальная дата';
    if (due.compareTo(d.debtDate) < 0) {
      return 'Срок не может быть раньше даты долга';
    }
  }
  return _textProblem(d.comment, 2000, 'Комментарий');
}

/// Погашение (spec 1.6).
String? repaymentProblem(DebtRepayment r) {
  final amount = _positiveMoneyProblem(r.amount, 'Сумма погашения');
  if (amount != null) return amount;
  if (parseDate(r.repaidOn) == null) return 'Дата погашения — реальная дата';
  return _textProblem(r.note, 500, 'Заметка');
}

/// Связь погашения с операцией (spec 1.6): [transactionDebtId] — `debt_id`
/// найденной операции ([transactionFound] — она существует). Операция
/// должна двигать тело именно этого долга, иначе
/// `repayment_transaction_mismatch`.
String? repaymentTransactionProblem(
  DebtRepayment r, {
  required bool transactionFound,
  String? transactionDebtId,
}) {
  if (r.transactionId == null) return null;
  if (!transactionFound) return 'Операция погашения не найдена';
  if (transactionDebtId != r.debtId) {
    return 'Операция погашения относится к другому долгу '
        '($repaymentTransactionMismatchCode)';
  }
  return null;
}

/// Слагаемых в формуле цели: 1–30 (spec 3.1, `MAX_GOAL_TERMS`).
const int maxGoalTerms = 30;

/// Счетов или заказчиков в слагаемом: 1–50 (`MAX_TERM_IDS`).
const int maxTermIds = 50;

/// Размер формулы в JSON, байт (`json_column("formula", max_bytes=8192)`).
const int maxFormulaBytes = 8192;

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Ключи слагаемого по виду (`_TERM_KEYS` сервера).
const Map<String, Set<String>> goalTermKeys = {
  'accounts': {'kind', 'sign', 'account_ids'},
  'all_accounts': {'kind', 'sign'},
  'debts_to_me': {'kind', 'sign'},
  'my_debts': {'kind', 'sign'},
  'receivables': {'kind', 'sign', 'client_ids'},
};

String? _idsProblem(String name, Object? value, {required bool nullable}) {
  if (value == null) return nullable ? null : '$name обязателен';
  if (value is! List || value.isEmpty || value.length > maxTermIds) {
    return '$name — от 1 до $maxTermIds идентификаторов';
  }
  for (final item in value) {
    if (item is! String || !_uuidPattern.hasMatch(item)) {
      return '$name — только строчные uuid';
    }
  }
  return null;
}

/// Формула «Есть» (`formula_problem` сервера, spec 3.1): список 1–30
/// слагаемых; у каждого `kind` из пяти известных, `sign` — `+` или `-` и
/// только «свои» ключи вида (`account_ids` у `accounts`, `client_ids` у
/// `receivables`); `account_ids` — 1–50 строчных uuid, `client_ids` — `null`
/// или 1–50 строчных uuid; размер JSON не больше 8 КБ.
String? formulaProblem(Object? value) {
  if (value is! List || value.isEmpty || value.length > maxGoalTerms) {
    return 'В формуле — от 1 до $maxGoalTerms слагаемых';
  }
  for (final term in value) {
    if (term is! Map || !goalTermKeys.containsKey(term['kind'])) {
      return 'У слагаемого должен быть известный вид';
    }
    final kind = term['kind']! as String;
    if (term.keys.any((k) => !goalTermKeys[kind]!.contains(k)) ||
        (term['sign'] != '+' && term['sign'] != '-')) {
      return 'У слагаемого — только свои поля и знак «+» или «−»';
    }
    final problem = switch (kind) {
      'accounts' => _idsProblem(
        'Список счетов',
        term['account_ids'],
        nullable: false,
      ),
      'receivables' => _idsProblem(
        'Список заказчиков',
        term['client_ids'],
        nullable: true,
      ),
      _ => null,
    };
    if (problem != null) return problem;
  }
  if (utf8.encode(jsonEncode(value)).length > maxFormulaBytes) {
    return 'Формула слишком большая (больше 8 КБ)';
  }
  return null;
}

/// Цель (spec 1.7): название, сумма цели, срок и формула «Есть».
String? goalProblem(Goal g) {
  final name = nameProblem(g.name, 200, what: 'Название цели');
  if (name != null) return name;
  final target = _positiveMoneyProblem(g.targetAmount, 'Сумма цели');
  if (target != null) return target;
  final due = g.deadlineDate;
  if (due != null && parseDate(due) == null) return 'Срок — реальная дата';
  return formulaProblem(formulaToJson(g.formula));
}
