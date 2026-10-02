/// Форматирование дат и чисел для интерфейса (русский язык).
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Сокращённые родительные названия месяцев: везде с точкой, кроме «мая»,
/// которое не сокращается.
const List<String> _months = [
  'янв.',
  'февр.',
  'мар.',
  'апр.',
  'мая',
  'июн.',
  'июл.',
  'авг.',
  'сент.',
  'окт.',
  'нояб.',
  'дек.',
];

/// Смещение часового пояса для показа времени. `null` — пояс устройства
/// (`toLocal`). Golden-тесты закрепляют UTC, чтобы подписи вида «сегодня в
/// 14:02» не зависели от пояса машины, на которой снимали эталоны.
@visibleForTesting
Duration? debugUtcOffset;

DateTime _local(DateTime t) =>
    debugUtcOffset == null ? t.toLocal() : t.toUtc().add(debugUtcOffset!);

/// Форма слова по числу: 1 день, 2 дня, 5 дней.
String pluralRu(int n, String one, String few, String many) {
  final mod100 = n.abs() % 100;
  final mod10 = n.abs() % 10;
  if (mod100 >= 11 && mod100 <= 14) return many;
  if (mod10 == 1) return one;
  if (mod10 >= 2 && mod10 <= 4) return few;
  return many;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// «14:02».
String formatClock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// «12 сент.» (год добавляется, если он не текущий).
String formatDate(DateTime t, DateTime now) {
  final base = '${t.day} ${_months[t.month - 1]}';
  return t.year == now.year ? base : '$base ${t.year}';
}

/// Момент в прошлом человеческим языком: «только что», «5 мин назад»,
/// «сегодня в 14:02», «вчера в 14:02», «12 сент., 14:02».
String formatMoment(DateTime moment, DateTime now) {
  final t = _local(moment);
  final n = _local(now);
  final diff = n.difference(t);
  if (diff.isNegative || diff.inSeconds < 45) return 'только что';
  if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final days = today.difference(day).inDays;
  if (days == 0) return 'сегодня в ${formatClock(t)}';
  if (days == 1) return 'вчера в ${formatClock(t)}';
  return '${formatDate(t, n)}, ${formatClock(t)}';
}

/// «через 5 дней», «через 1 день», «сегодня» — срок хранения в корзине.
String formatDaysLeft(int days) {
  if (days <= 0) return 'удалится сегодня';
  return 'удалится через $days ${pluralRu(days, 'день', 'дня', 'дней')}';
}
