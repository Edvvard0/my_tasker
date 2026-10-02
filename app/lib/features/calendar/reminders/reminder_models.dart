import 'package:flutter/foundation.dart';

/// Одно запланированное локальное уведомление.
@immutable
class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.fireAt,
    required this.title,
    required this.body,
    required this.payload,
  });

  /// Стабильный числовой идентификатор уведомления: зависит от объекта,
  /// экземпляра, «за сколько минут», момента срабатывания и текста — любая
  /// правка даёт новый id (старое отменяется, новое планируется).
  final int id;

  /// Когда сработать (момент UTC).
  final DateTime fireAt;
  final String title;
  final String body;

  /// Куда вести по нажатию: `event:<id>|<ключ экземпляра>` или `task:<id>`.
  final String payload;

  @override
  bool operator ==(Object other) =>
      other is PlannedReminder &&
      other.id == id &&
      other.fireAt == fireAt &&
      other.title == title &&
      other.body == body &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash(id, fireAt, title, body, payload);

  @override
  String toString() => 'PlannedReminder($id, $fireAt, $title, $body)';
}

/// 31-битный хеш FNV-1a: идентификатор уведомления (Android принимает int).
int reminderId(String key) {
  var hash = 0x811C9DC5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}

/// Разрешение на уведомления.
enum ReminderPermission {
  /// Всё разрешено: уведомления и точные будильники.
  granted,

  /// Уведомления запрещены.
  notificationsDenied,

  /// Уведомления разрешены, но точные будильники (Android 12+) — нет:
  /// напоминания придут с задержкой.
  exactAlarmsDenied,

  /// Платформа не требует разрешений (Windows) или не поддерживается.
  notRequired,
}
