import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';
import 'package:my_tasker/features/finance/presentation/debt_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';

/// Подписи экранов «Цели» (02, 5.3.2, 6.5).

/// Честная пометка: формула с `receivables` сохраняется как есть, но
/// клиента «Работы» ещё нет, поэтому слагаемое считается как 0.
const String goalReceivablesNote =
    'Раздел «Работа» ещё не подключён — ожидаемые поступления сейчас '
    'считаются как 0';

/// «Не хватает 70 400 ₽» либо «Цель достигнута, +54 600 ₽» (без красного и
/// зелёного: словом и знаком «+»).
String goalMissingText(GoalProgress p, {MoneyFormat money = moneyText}) {
  if (!p.reached) return 'Не хватает ${money(p.missing)}';
  return p.surplus > 0
      ? 'Цель достигнута, ${money(p.surplus, signed: true)}'
      : 'Цель достигнута';
}

/// Срок цели: «Срок 31 дек.» и, пока цель не достигнута, сколько осталось.
/// `null` — срока нет.
String? goalDeadlineText(Goal goal, String today, {required bool reached}) {
  final due = goal.deadlineDate;
  if (due == null) return null;
  final base = 'Срок ${ymdText(due, today)}';
  if (reached) return base;
  final dueDay = parseDate(due);
  final nowDay = parseDate(today);
  if (dueDay == null || nowDay == null) return base;
  final left = daysBetween(nowDay, dueDay);
  if (left < 0) return '$base · срок прошёл';
  if (left == 0) return '$base · срок сегодня';
  return '$base · осталось $left ${pluralRu(left, 'день', 'дня', 'дней')}';
}

/// Подпись слагаемого для таблицы разбора и редактора; названия счетов — из
/// [lookups] (удалённый счёт — «Счёт»).
String goalTermLabel(GoalTerm term, FinanceLookups? lookups) {
  switch (term.kind) {
    case GoalTermKind.accounts:
      final ids = term.accountIds ?? const [];
      if (ids.isEmpty) return 'Выбранные счета';
      final names = [for (final id in ids) lookups?.accountName(id) ?? 'Счёт'];
      return 'Счета: ${names.join(', ')}';
    case GoalTermKind.receivables:
      final ids = term.clientIds;
      return ids == null
          ? 'Ожидаемые поступления (Работа)'
          : 'Ожидаемые поступления: заказчики (${ids.length})';
    case GoalTermKind.allAccounts:
    case GoalTermKind.debtsToMe:
    case GoalTermKind.myDebts:
      return term.kind.label;
  }
}

/// Пояснение под видом слагаемого в списке выбора.
String goalKindHint(GoalTermKind kind) => switch (kind) {
  GoalTermKind.accounts => 'Баланс выбранных счетов, даже если они не в общем',
  GoalTermKind.allAccounts => 'Общий баланс: счета «в общем балансе»',
  GoalTermKind.debtsToMe => 'Сумма открытых остатков долгов мне',
  GoalTermKind.myDebts => 'Сумма открытых остатков моих долгов',
  GoalTermKind.receivables => 'Что должны по проектам «Работы»',
};
