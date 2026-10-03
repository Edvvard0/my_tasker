import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Подписи, иконки и форматы Финансов для интерфейса (02, 2.2.3, 7.3).

/// Форматер сумм: [moneyText] либо `context.money` (учитывает «скрыть
/// суммы»). Чистые функции подписей принимают его параметром.
typedef MoneyFormat = String Function(int kopecks, {bool signed});

/// Деньги: разряды и «₽» через неразрывные пробелы, настоящий минус «−»,
/// у [signed] положительных — «+» (02, 2.2.3). Копейки — только ненулевые.
String moneyText(int kopecks, {bool signed = false}) {
  final abs = kopecks.abs();
  final body = abs > maxKopecks
      ? '$abs коп.'
      : formatAmount(abs).replaceAll(' ', ' ');
  if (kopecks < 0) return '−$body';
  return signed && kopecks > 0 ? '+$body' : body;
}

/// Сумма операции со знаком по виду: расход «−», доход «+», перевод без знака.
String transactionAmountText(FinanceTransaction t) => switch (t.kind) {
  TransactionKind.expense => moneyText(-t.amount),
  TransactionKind.income => moneyText(t.amount, signed: true),
  TransactionKind.transfer => moneyText(t.amount),
};

/// Копейки как текст поля суммы: `123450` -> «1 234,50» (разряды через
/// неразрывный пробел, копейки только ненулевые).
String amountInputText(int kopecks) {
  final abs = kopecks.abs();
  final whole = (abs ~/ 100).toString();
  final cents = abs % 100;
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(' ');
    grouped.write(whole[i]);
  }
  final fraction = cents == 0 ? '' : ',${cents.toString().padLeft(2, '0')}';
  return '${kopecks < 0 ? '−' : ''}$grouped$fraction';
}

/// «СЕНТЯБРЬ 2026» для заголовка месяца `YYYY-MM`.
String monthHeaderText(String month) {
  final year = month.substring(0, 4);
  final number = int.parse(month.substring(5, 7));
  return '${monthNames[number - 1]} $year'.toUpperCase();
}

/// «Сегодня, 14:02», «Вчера, 14:02», «12 сент., 14:02», с годом — если он
/// отличается от текущего.
String whenText(DateTime wall, DateTime today) {
  final day = dateOnly(wall);
  final diff = daysBetween(today, day);
  final clock = timeOf(wall);
  if (diff == 0) return 'Сегодня, $clock';
  if (diff == -1) return 'Вчера, $clock';
  final base = '${day.day} ${monthShortNames[day.month - 1]}';
  return '${day.year == today.year ? base : '$base ${day.year}'}, $clock';
}

/// «12 сент.» (с годом, если он не текущий) — дата сверки.
String shortDateText(DateTime wall, DateTime today) {
  final day = dateOnly(wall);
  final base = '${day.day} ${monthShortNames[day.month - 1]}';
  return day.year == today.year ? base : '$base ${day.year}';
}

/// Иконка вида счёта.
IconData accountKindIcon(AccountKind kind) => switch (kind) {
  AccountKind.cash => LucideIcons.banknote,
  AccountKind.debitCard => LucideIcons.creditCard,
  AccountKind.creditCard => LucideIcons.creditCard,
  AccountKind.savings => LucideIcons.piggyBank,
  AccountKind.deposit => LucideIcons.landmark,
  AccountKind.other => LucideIcons.wallet,
};

/// Иконка вида операции.
IconData transactionKindIcon(TransactionKind kind) => switch (kind) {
  TransactionKind.expense => LucideIcons.arrowUpRight,
  TransactionKind.income => LucideIcons.arrowDownLeft,
  TransactionKind.transfer => LucideIcons.arrowRightLeft,
};

/// Строка под названием счёта: «Т-Банк · •• 4242» либо вид счёта.
String accountSubtitle(Account a) {
  final parts = <String>[
    if (a.bank != null) a.bank!,
    if (a.cardLast4 != null) '•• ${a.cardLast4}',
  ];
  return parts.isEmpty ? a.kind.label : parts.join(' · ');
}

/// Набор иконок категорий (имена — как в spec 3.2): имя -> иконка Lucide.
const Map<String, IconData> categoryIcons = {
  'shopping_basket': LucideIcons.shoppingBasket,
  'restaurant': LucideIcons.utensils,
  'directions_bus': LucideIcons.bus,
  'home': LucideIcons.house,
  'wifi': LucideIcons.wifi,
  'medical_services': LucideIcons.heartPulse,
  'checkroom': LucideIcons.shirt,
  'movie': LucideIcons.clapperboard,
  'school': LucideIcons.graduationCap,
  'card_giftcard': LucideIcons.gift,
  'chair': LucideIcons.armchair,
  'subscriptions': LucideIcons.repeat,
  'directions_car': LucideIcons.car,
  'flight': LucideIcons.plane,
  'more_horiz': LucideIcons.ellipsis,
  'local_taxi': LucideIcons.carTaxiFront,
  'train': LucideIcons.trainFront,
  'local_gas_station': LucideIcons.fuel,
  'build': LucideIcons.wrench,
  'key': LucideIcons.keyRound,
  'bolt': LucideIcons.zap,
  'medication': LucideIcons.pill,
  'stethoscope': LucideIcons.stethoscope,
  'payments': LucideIcons.banknote,
  'work': LucideIcons.briefcase,
  'redeem': LucideIcons.gift,
  'savings': LucideIcons.piggyBank,
};

/// Иконка категории; неизвестное имя или `null` — «тег».
IconData categoryIcon(String? name) => categoryIcons[name] ?? LucideIcons.tag;

/// Небольшой фиксированный набор цветов категорий (`#RRGGBB`).
const List<String> categoryColors = [
  '#9E9E9E',
  '#4C8DFF',
  '#4CAF50',
  '#F5B942',
  '#E8624F',
  '#B07CFF',
  '#3FB8AF',
  '#F27BB0',
];

/// Цвет из `#RRGGBB`; `null` для пустого или неверного значения.
Color? parseHexColor(String? hex) {
  if (hex == null || !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
}

/// Сумма на оси графика (02, 5.3.3): рубли без копеек, тысячи — «к», миллионы
/// — «М», одна цифра после запятой, без «,0»: `12 500 ₽` -> «12,5к»,
/// `205 000 ₽` -> «205к», `1 200 000 ₽` -> «1,2М». Только целые числа.
String axisAmountText(int kopecks) {
  final rubles = kopecks.abs() ~/ 100;
  final String body;
  if (rubles >= 1000000) {
    body = '${_oneDecimal(rubles ~/ 100000)}М';
  } else if (rubles >= 1000) {
    body = '${_oneDecimal(rubles ~/ 100)}к';
  } else {
    body = '$rubles';
  }
  return kopecks < 0 && rubles > 0 ? '−$body' : body;
}

/// Десятые доли: `125` -> «12,5», `2050` -> «205».
String _oneDecimal(int tenths) {
  final fraction = tenths % 10;
  return fraction == 0 ? '${tenths ~/ 10}' : '${tenths ~/ 10},$fraction';
}

/// Короткие названия месяцев для подписей осей.
const List<String> axisMonthNames = [
  'янв',
  'фев',
  'мар',
  'апр',
  'май',
  'июн',
  'июл',
  'авг',
  'сен',
  'окт',
  'ноя',
  'дек',
];

/// «авг» для месяца `YYYY-MM` (подпись столбика).
String axisMonthText(String month) =>
    axisMonthNames[int.parse(month.substring(5, 7)) - 1];
