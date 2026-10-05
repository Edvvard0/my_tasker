import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';

/// Подписи и разбор ввода «Сна и ритуалов» для интерфейса. Длительность
/// («7 ч 30 мин») — `durationText` из `ru_dates.dart`.

/// Цель сна для тепловой карты и подписей (интерфейс, не контракт): 7 часов.
const int sleepGoalMinutes = 420;

/// «7:30» для крупных цифр.
String durationShort(int minutes) =>
    '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}';

/// Доля в базисных пунктах -> «67 %».
String sharePercent(int bp) => '${bp ~/ 100} %';

/// Знаковая разница долей: «+25 п. п.», «−10 п. п.», «0 п. п.».
String differencePoints(int bp) {
  final points = bp ~/ 100;
  if (points == 0) return '0 п. п.';
  return points > 0 ? '+$points п. п.' : '−${-points} п. п.';
}

/// Уровень ячейки тепловой карты 1…4 (design 2.1.7): < 25 %, 25–60 %,
/// 60–100 %, ≥ 100 % цели.
int heatLevel(int minutes, {int goal = sleepGoalMinutes}) {
  final share = minutes * 100 ~/ goal;
  if (share < 25) return 1;
  if (share < 60) return 2;
  if (share < 100) return 3;
  return 4;
}

/// Даты окна из [days] дней, заканчивающегося [through], по возрастанию.
List<String> windowDates(String through, int days) {
  final last = parseDate(through)!;
  return [for (var i = days - 1; i >= 0; i--) formatDate(addDays(last, -i))];
}

/// «Чт, 17 сент.» для даты `YYYY-MM-DD` (или сама строка, если битая).
String dateShort(String iso) {
  final d = parseDate(iso);
  return d == null ? iso : dayTitleShort(d);
}

/// «17 сентября» для даты `YYYY-MM-DD`.
String dateLong(String iso) {
  final d = parseDate(iso);
  return d == null ? iso : dayMonth(d);
}

final RegExp _clockColon = RegExp(r'^(\d{1,2})[:.](\d{1,2})$');
final RegExp _clockDigits = RegExp(r'^(\d{3,4})$');
final RegExp _clockHour = RegExp(r'^(\d{1,2})$');

/// Время из текста: «23:40», «8:05», «8.05», «0740», «740», «8» — минуты от
/// полуночи; `null`, если не время суток.
int? parseClockInput(String text) {
  final t = text.trim();
  int? hour;
  int? minute;
  final colon = _clockColon.firstMatch(t);
  if (colon != null) {
    hour = int.parse(colon.group(1)!);
    minute = int.parse(colon.group(2)!);
  } else if (_clockDigits.hasMatch(t)) {
    final padded = t.padLeft(4, '0');
    hour = int.parse(padded.substring(0, 2));
    minute = int.parse(padded.substring(2));
  } else if (_clockHour.hasMatch(t)) {
    hour = int.parse(t);
    minute = 0;
  }
  if (hour == null || minute == null || hour > 23 || minute > 59) return null;
  return hour * 60 + minute;
}

/// «07:05» для минут от полуночи.
String clockOfMinutes(int minutes) =>
    clockText(minutes ~/ 60 % 24, minutes % 60);
