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
    this.key,
    this.whenMs,
  });

  factory RawNotification.fromMap(Map<Object?, Object?> map) => RawNotification(
    package: (map['package'] as String?) ?? '',
    title: (map['title'] as String?) ?? '',
    text: (map['text'] as String?) ?? '',
    postedAt: DateTime.fromMillisecondsSinceEpoch(
      (map['posted_at_ms'] as int?) ?? 0,
      isUtc: true,
    ),
    key: map['key'] as String?,
    whenMs: map['when_ms'] as int?,
  );

  final String package;
  final String title;
  final String text;
  final DateTime postedAt;

  /// Ключ уведомления в системе (`StatusBarNotification.key`): одно и то же
  /// уведомление, опубликованное повторно, сохраняет его.
  final String? key;

  /// `Notification.when` (мс от эпохи), если задан: время самого события;
  /// при повторной публикации обычно не меняется, в отличие от `postTime`.
  final int? whenMs;
}

/// Состояние сохранённого уведомления.
enum NotificationState {
  /// Не разобрано: нет правила, нечитаемая сумма, неизвестная валюта.
  unrecognized('unrecognized'),

  /// Разобрано, но счёт не определён: нужен выбор пользователя.
  needsAccount('needs_account'),

  /// Операция создана (или уже была).
  processed('processed'),

  /// Черновик создан, но очень похож на уже внесённую операцию (выписка,
  /// ручная): ждёт решения «дубль / отдельная покупка».
  possibleDuplicate('possible_duplicate'),

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
  'possible_duplicate' => 'Возможный дубль',
  'error' => 'Сбой обработки',
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
  'possible_duplicate' =>
    'Похожая операция уже есть: дубль или отдельная покупка?',
  'error' => 'Не удалось обработать уведомление: создайте операцию вручную',
  _ => 'Нужна проверка',
};
