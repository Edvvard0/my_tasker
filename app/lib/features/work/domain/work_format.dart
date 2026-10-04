/// Показ чисел «Работы»: суммы, доли, часы. Никаких округлений вверх:
/// компактные суммы и проценты усекаются, как и расчёты (spec 4.1).
library;

import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/money/money.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// Сумма для крупных плиток: до 10 000 ₽ — полностью, дальше `80,5к ₽`
/// и `1,2 млн ₽` (усечением до одного знака, без округления вверх).
String formatAmountShort(int kopecks) {
  final abs = kopecks.abs();
  final sign = kopecks < 0 ? '-' : '';
  final rubles = abs ~/ 100;
  if (rubles < 10000) return formatAmount(kopecks);
  if (rubles < 1000000) {
    final tenths = rubles ~/ 100;
    return '$sign${_tenths(tenths)}к\u00A0₽';
  }
  final tenths = rubles ~/ 100000;
  return '$sign${_tenths(tenths)}\u00A0млн\u00A0₽';
}

String _tenths(int tenths) {
  final whole = tenths ~/ 10;
  final frac = tenths % 10;
  return frac == 0 ? '$whole' : '$whole,$frac';
}

/// Доля оплаты из сотых долей процента: `3333` → «33,3 %», `9999` →
/// «99,9 %» (усечение: «100 %» только при полной оплате).
String formatPercentBp(int bp) {
  final tenths = bp ~/ 10;
  return '${_tenths(tenths)} %';
}

/// Целые проценты для узких мест (прогресс-бар): вниз.
String formatPercentWhole(int bp) => '${bp ~/ 100}%';

/// Часы из секунд: «34 ч 15 мин», «45 мин», «0 мин».
String formatHours(int seconds) {
  final minutes = seconds ~/ 60;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m мин';
  return m == 0 ? '$h ч' : '$h ч $m мин';
}

/// Таймер: «01:12:43».
String formatTimer(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${_two(total ~/ 3600)}:${_two(total % 3600 ~/ 60)}:${_two(total % 60)}';
}

/// Доход в час: «333,33 ₽/ч»; `null` (нет часов) — «—».
String formatPerHour(int? kopecksPerHour) =>
    kopecksPerHour == null ? '—' : '${formatAmount(kopecksPerHour)}/ч';

/// Крупная цифра дохода в час для плитки: «2 150 ₽» / «—».
String formatPerHourShort(int? kopecksPerHour) =>
    kopecksPerHour == null ? '—' : formatAmountShort(kopecksPerHour);

/// Месяц `YYYY-MM` для заголовков: «окт. 2026» (текущий год — «окт.»).
String formatMonthKey(String month, DateTime now) {
  final year = int.parse(month.substring(0, 4));
  final m = int.parse(month.substring(5, 7));
  const names = [
    'янв.',
    'февр.',
    'март',
    'апр.',
    'май',
    'июнь',
    'июль',
    'авг.',
    'сент.',
    'окт.',
    'нояб.',
    'дек.',
  ];
  return year == now.year ? names[m - 1] : '${names[m - 1]} $year';
}

/// Дата `YYYY-MM-DD` как «15 окт.».
String formatDateText(String? date, DateTime now) {
  if (date == null || date.length != 10) return '—';
  final y = int.tryParse(date.substring(0, 4));
  final m = int.tryParse(date.substring(5, 7));
  final d = int.tryParse(date.substring(8, 10));
  if (y == null || m == null || d == null) return '—';
  return formatDate(DateTime.utc(y, m, d), now);
}
