/// Проверки «Финансов» на клиенте (spec Этапа 5, раздел 1 и 3). Сервер
/// отвергает то же самое построчно; правила, где участвует больше одной
/// строки (глубина категорий, погашение не больше остатка), проверяет
/// клиент при вводе.
library;

import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Суммы: |копейки| ≤ 99 999 999 999 999.
const int maxFinanceKopecks = maxKopecks;

/// Раньше этого момента операции и сверки не принимаются (Москва = UTC+3
/// без перехода на летнее время).
final DateTime financeEpoch = DateTime.utc(2015);

const int maxFormulaTerms = 30;
const int maxTermIds = 50;

final RegExp _last4 = RegExp(r'^[0-9]{4}$');
final RegExp _hash = RegExp(r'^[0-9a-f]{16,64}$');

bool _isRealDate(String? date) => date != null && parseDate(date) != null;

String? _moneyProblem(
  int? value,
  String what, {
  int min = 0,
  bool signed = false,
}) {
  if (value == null) return null;
  final low = signed ? -maxFinanceKopecks : min;
  if (value < low || value > maxFinanceKopecks) {
    return signed
        ? '$what: не больше 999 999 999 999,99 ₽ по модулю'
        : (min > 0
              ? '$what: от 0,01 ₽ до 999 999 999 999,99 ₽'
              : '$what: от 0 до 999 999 999 999,99 ₽');
  }
  return null;
}

String? _textLimit(String? value, int max, String what) =>
    value != null && value.length > max
    ? '$what — не длиннее $max символов'
    : null;

/// Счёт.
String? accountProblem(Account a) {
  final name = nameProblem(a.name, 100, what: 'Название счёта');
  if (name != null) return name;
  final bank = _textLimit(a.bank, 100, 'Банк');
  if (bank != null) return bank;
  final last4 = a.cardLast4;
  if (last4 != null) {
    if (!a.kind.isCard) return 'Последние 4 цифры — только у карты';
    if (!_last4.hasMatch(last4)) return 'Последние цифры карты — ровно 4 цифры';
  }
  final opening = _moneyProblem(
    a.openingBalance,
    'Начальный остаток',
    signed: true,
  );
  if (opening != null) return opening;
  if (!_isRealDate(a.openingDate)) return 'Дата открытия: нет такой даты';
  final limit = a.creditLimit;
  if (limit != null) {
    if (a.kind != AccountKind.creditCard) {
      return 'Кредитный лимит — только у кредитной карты';
    }
    return _moneyProblem(limit, 'Кредитный лимит');
  }
  return null;
}

/// Категория; [parent] — её родитель (если есть): категория верхнего
/// уровня того же вида (`category_parent_invalid`, spec 1.2).
String? categoryProblem(FinCategory c, {FinCategory? parent}) {
  final name = nameProblem(c.name, 100);
  if (name != null) return name;
  final icon = c.icon;
  if (icon != null && (icon.isEmpty || icon.length > 50)) {
    return 'Иконка — от 1 до 50 символов';
  }
  final color = colorProblem(c.color);
  if (color != null) return color;
  if (c.parentId != null && parent != null) {
    if (parent.parentId != null) {
      return 'Подкатегория входит только в категорию верхнего уровня';
    }
    if (parent.kind != c.kind) {
      return 'Подкатегория того же вида, что и родитель';
    }
  }
  return null;
}

/// Операция (межполевые правила 1.3).
String? transactionProblem(FinTransaction tx) {
  final amount = _moneyProblem(tx.amount, 'Сумма', min: 1);
  if (amount != null) return amount;
  if (tx.occurredAt.isBefore(financeEpoch)) return 'Операция раньше 2015 года';
  final merchant = _textLimit(tx.merchant, 200, 'Контрагент');
  if (merchant != null) return merchant;
  final comment = _textLimit(tx.comment, 2000, 'Комментарий');
  if (comment != null) return comment;
  final external = tx.externalId;
  if (external != null && (external.isEmpty || external.length > 200)) {
    return 'Внешний идентификатор — от 1 до 200 символов';
  }
  final hash = tx.dedupHash;
  if (hash != null && !_hash.hasMatch(hash)) {
    return 'Хеш операции — 16–64 символа 0-9a-f';
  }
  if (tx.kind == TxKind.transfer) {
    final to = tx.toAccountId;
    if (to == null) return 'Укажите счёт, куда переводите';
    if (to == tx.accountId) return 'Переведите между двумя разными счетами';
    if (tx.categoryId != null ||
        tx.workPaymentId != null ||
        tx.debtId != null) {
      return 'У перевода нет категории, платежа Работы и долга';
    }
  } else if (tx.toAccountId != null) {
    return 'Счёт «куда» бывает только у перевода';
  }
  if (tx.workPaymentId != null && tx.kind != TxKind.income) {
    return 'Платёж Работы привязывается только к доходу';
  }
  if ((tx.source == TxSource.workPayment) != (tx.workPaymentId != null)) {
    return 'Источник «платёж по проекту» и ссылка на платёж идут вместе';
  }
  return null;
}

/// Точка сверки.
String? checkpointProblem(BalanceCheckpoint cp) {
  if (cp.checkedAt.isBefore(financeEpoch)) return 'Сверка раньше 2015 года';
  final actual = _moneyProblem(
    cp.actualBalance,
    'Фактический баланс',
    signed: true,
  );
  if (actual != null) return actual;
  return _textLimit(cp.note, 500, 'Заметка');
}

/// Долг.
String? debtProblem(Debt d) {
  if (d.personId == null && isBlank(d.counterparty)) {
    return 'Укажите, кто должен или кому должны';
  }
  final who = _textLimit(d.counterparty, 200, 'Контрагент');
  if (who != null) return who;
  final amount = _moneyProblem(d.amount, 'Сумма долга', min: 1);
  if (amount != null) return amount;
  if (!_isRealDate(d.debtDate)) return 'Дата долга: нет такой даты';
  final due = d.dueDate;
  if (due != null) {
    if (!_isRealDate(due)) return 'Срок: нет такой даты';
    if (due.compareTo(d.debtDate) < 0) return 'Срок раньше даты долга';
  }
  return _textLimit(d.comment, 2000, 'Комментарий');
}

/// Погашение (одна строка).
String? repaymentProblem(DebtRepayment r) {
  final amount = _moneyProblem(r.amount, 'Сумма погашения', min: 1);
  if (amount != null) return amount;
  if (!_isRealDate(r.repaidOn)) return 'Дата погашения: нет такой даты';
  return _textLimit(r.note, 500, 'Заметка');
}

/// Формула цели: 1–30 слагаемых; у «счетов» — 1–50 счетов, у «ожидаемых»
/// — все заказчики или 1–50 выбранных.
String? formulaProblem(List<GoalTerm> formula) {
  if (formula.isEmpty || formula.length > maxFormulaTerms) {
    return 'В формуле — от 1 до $maxFormulaTerms слагаемых';
  }
  for (final t in formula) {
    if (t.kind == GoalTermKind.accounts &&
        (t.accountIds.isEmpty || t.accountIds.length > maxTermIds)) {
      return 'В слагаемом «счета» — от 1 до $maxTermIds счетов';
    }
    final clients = t.clientIds;
    if (t.kind == GoalTermKind.receivables &&
        clients != null &&
        (clients.isEmpty || clients.length > maxTermIds)) {
      return 'Выберите заказчиков (до $maxTermIds) или «всех»';
    }
  }
  return null;
}

/// Цель.
String? goalProblem(Goal g) {
  final name = nameProblem(g.name, 200);
  if (name != null) return name;
  final target = _moneyProblem(g.targetAmount, 'Целевая сумма', min: 1);
  if (target != null) return target;
  final deadline = g.deadlineDate;
  if (deadline != null && !_isRealDate(deadline)) return 'Срок: нет такой даты';
  return formulaProblem(g.formula);
}
