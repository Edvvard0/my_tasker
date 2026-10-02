import 'package:my_tasker/core/money/money.dart';

/// Стоимость в копейках -> «1 234,56 ₽» (целые копейки, без `double`).
String formatCost(int kopecks) => formatAmount(kopecks);

/// Целое с неразрывными пробелами между разрядами: `12 345`.
String formatCount(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(' ');
    out.write(digits[i]);
  }
  return out.toString();
}

/// «≈ 4 200 ток.».
String formatTokens(int tokens) => '≈ ${formatCount(tokens)} ток.';

const List<String> _monthNames = [
  'январь',
  'февраль',
  'март',
  'апрель',
  'май',
  'июнь',
  'июль',
  'август',
  'сентябрь',
  'октябрь',
  'ноябрь',
  'декабрь',
];

/// `2026-10` -> «октябрь 2026».
String monthLabel(String month) {
  final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(month);
  if (m == null) return month;
  final index = int.parse(m[2]!) - 1;
  if (index < 0 || index > 11) return month;
  return '${_monthNames[index]} ${m[1]}';
}

/// Соседний месяц `YYYY-MM` (`delta` = -1 / +1).
String shiftMonth(String month, int delta) {
  final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(month);
  if (m == null) return month;
  final total = int.parse(m[1]!) * 12 + (int.parse(m[2]!) - 1) + delta;
  final year = total ~/ 12;
  final mon = total % 12 + 1;
  return '${year.toString().padLeft(4, '0')}-${mon.toString().padLeft(2, '0')}';
}

/// Месяц `YYYY-MM` для момента.
String monthOf(DateTime moment) =>
    '${moment.year.toString().padLeft(4, '0')}-'
    '${moment.month.toString().padLeft(2, '0')}';

/// Копейки -> число рублей для поля ввода: `50000` -> `500`, `1250` ->
/// `12,50` (без знака валюты, без группировки).
String rublesInput(int kopecks) {
  final whole = kopecks ~/ 100;
  final cents = kopecks % 100;
  return cents == 0 ? '$whole' : '$whole,${cents.toString().padLeft(2, '0')}';
}
