import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/finance/domain/debt_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';

/// Подписи и форматы экранов долгов (02, 5.4.3, 7.3).

/// «12 сент.» для даты `YYYY-MM-DD`; год добавляется, если он не текущий
/// (год [today] — московской даты `YYYY-MM-DD`).
String ymdText(String ymd, String today) {
  final day = parseDate(ymd);
  if (day == null) return ymd;
  final base = '${day.day} ${monthShortNames[day.month - 1]}';
  return ymd.substring(0, 4) == today.substring(0, 4)
      ? base
      : '$base ${day.year}';
}

/// «Просрочен на 5 дн.» / «Просрочен на 1 день».
String overdueText(int days) =>
    'Просрочен на $days ${pluralRu(days, 'день', 'дня', 'дней')}';

/// Иконка направления: мне должны — рука с монетами, я должен — «рукопожатие».
IconData debtDirectionIcon(DebtDirection direction) =>
    direction == DebtDirection.owedToMe
    ? LucideIcons.handCoins
    : LucideIcons.handshake;

/// Тон пилюли статуса: без красного (02, 2.2): форма точки и слово.
StatusTone debtStatusTone(DebtStatus status) => switch (status) {
  DebtStatus.open => StatusTone.neutral,
  DebtStatus.partial => StatusTone.warning,
  DebtStatus.closed => StatusTone.success,
};

/// Первая буква контрагента для аватара-инициала.
String debtInitial(Debt debt) {
  final who = debt.who.trim();
  return who.isEmpty ? '?' : who.characters.first.toUpperCase();
}

/// Подпись под именем в списке: сколько вернули, срок.
String debtSubtitle(
  DebtState s,
  String today, {
  MoneyFormat money = moneyText,
}) {
  final parts = <String>[];
  if (s.isClosed) {
    parts.add('Закрыт');
  } else if (s.status == DebtStatus.partial) {
    parts.add('Вернули ${money(s.repaid)} из ${money(s.debt.amount)}');
  } else {
    parts.add('с ${ymdText(s.debt.debtDate, today)}');
  }
  final due = s.debt.dueDate;
  if (due != null && !s.isClosed) parts.add('срок ${ymdText(due, today)}');
  return parts.join(' · ');
}

/// Заголовок погашения: «Мне вернули» / «Я вернул».
String repaymentVerb(DebtDirection direction) =>
    direction == DebtDirection.owedToMe ? 'Мне вернули' : 'Я вернул';
