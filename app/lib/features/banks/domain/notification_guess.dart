import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/banks/domain/notification_engine.dart';

/// Догадка по тексту нераспознанного уведомления для заготовки операции:
/// первая сумма в рублях и вид (доход/расход). Только подсказка — человек
/// поправит в форме.
@immutable
class NotificationGuess {
  const NotificationGuess({this.amount, this.isIncome = false});

  /// Копейки или `null`.
  final int? amount;
  final bool isIncome;
}

final RegExp _rubles = RegExp(
  r'([0-9][0-9 ]*(?:[.,][0-9]{1,2})?) ?(?:₽|руб|р\.|RUB)',
);
final RegExp _incomeWords = RegExp(
  'поступлени|пополнени|зачислен|получен|возврат|кэшбэк|кешбэк|зарплат|'
  'входящ',
  caseSensitive: false,
);

NotificationGuess guessFromNotification(String title, String text) {
  final clean = normalizeNotificationText('$title $text');
  final match = _rubles.firstMatch(clean);
  final amount = match == null ? null : tryParseAmount(match.group(1)!);
  return NotificationGuess(
    amount: amount != null && amount > 0 ? amount : null,
    isIncome: _incomeWords.hasMatch(clean),
  );
}
