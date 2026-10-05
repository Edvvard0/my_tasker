import 'package:flutter/foundation.dart';
import 'package:my_tasker/features/banks/domain/notification_engine.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart'
    show parseFinanceInstant;

/// Сырое уведомление банка, как его отдаёт платформа (Android).
@immutable
class RawNotification {
  const RawNotification({
    required this.package,
    required this.title,
    required this.text,
    required this.postedAt,
  });

  factory RawNotification.fromMap(Map<Object?, Object?> map) => RawNotification(
    package: (map['package'] as String?) ?? '',
    title: (map['title'] as String?) ?? '',
    text: (map['text'] as String?) ?? '',
    postedAt: DateTime.fromMillisecondsSinceEpoch(
      (map['posted_at_ms'] as int?) ?? 0,
      isUtc: true,
    ),
  );

  final String package;
  final String title;
  final String text;
  final DateTime postedAt;
}

/// Состояние сохранённого уведомления.
enum NotificationState {
  /// Не разобрано: нет правила, нечитаемая сумма, неизвестная валюта.
  unrecognized('unrecognized'),

  /// Разобрано, но счёт не определён: нужен выбор пользователя.
  needsAccount('needs_account'),

  /// Операция создана (или уже была).
  processed('processed'),

  /// Пользователь убрал.
  dismissed('dismissed');

  const NotificationState(this.wire);

  final String wire;

  static NotificationState parse(String? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return unrecognized;
  }
}

/// Уведомление банка, хранимое локально (30 дней).
@immutable
class BankNotification {
  const BankNotification({
    required this.id,
    required this.package,
    required this.title,
    required this.body,
    required this.postedAt,
    required this.receivedAt,
    required this.state,
    this.reason,
    this.parsed,
    this.txId,
  });

  final String id;
  final String package;
  final String title;
  final String body;
  final DateTime postedAt;
  final DateTime receivedAt;
  final NotificationState state;
  final String? reason;

  /// Результат разбора (у `needs_account`).
  final NotificationParse? parsed;
  final String? txId;

  static DateTime instant(String text) => parseFinanceInstant(text);
}

/// Короткая подпись причины (в пилюле статуса).
String reviewReasonLabel(String? reason) => switch (reason) {
  'no_rule' => 'Не распознано',
  'bad_amount' => 'Сумма не прочитана',
  'unknown_currency' => 'Неизвестная валюта',
  'no_account' => 'Нужен счёт',
  'ambiguous_account' => 'Несколько счетов',
  'foreign_currency' => 'Чужая валюта',
  _ => 'Нужна проверка',
};

/// Понятная причина для списка «Требует проверки».
String reviewReasonText(String? reason) => switch (reason) {
  'no_rule' => 'Формат уведомления пока не известен',
  'bad_amount' => 'Не удалось прочитать сумму',
  'unknown_currency' => 'Неизвестная валюта',
  'no_account' => 'Не найден счёт с такими последними цифрами карты',
  'ambiguous_account' => 'Карте подходит несколько счетов',
  'foreign_currency' => 'Операция в иностранной валюте',
  _ => 'Нужна проверка',
};
