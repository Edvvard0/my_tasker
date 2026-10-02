import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/finance/preset_categories.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

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
