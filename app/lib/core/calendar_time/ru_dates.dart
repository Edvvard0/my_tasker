import 'package:my_tasker/core/calendar_time/civil_date.dart';

/// Русские названия дней и месяцев для календаря.

const List<String> weekdayShortNames = [
  'Пн',
  'Вт',
  'Ср',
  'Чт',
  'Пт',
  'Сб',
  'Вс',
];

const List<String> weekdayFullNames = [
  'Понедельник',
  'Вторник',
  'Среда',
  'Четверг',
  'Пятница',
  'Суббота',
  'Воскресенье',
];

const List<String> monthNames = [
  'Январь',
  'Февраль',
  'Март',
  'Апрель',
  'Май',
  'Июнь',
  'Июль',
  'Август',
  'Сентябрь',
  'Октябрь',
  'Ноябрь',
  'Декабрь',
];

const List<String> monthGenitiveNames = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

const List<String> monthShortNames = [
  'янв.',
  'февр.',
  'марта',
  'апр.',
  'мая',
  'июня',
  'июля',
  'авг.',
  'сент.',
  'окт.',
  'нояб.',
  'дек.',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// «14:05».
String clockText(int hour, int minute) => '${_two(hour)}:${_two(minute)}';

/// Время из настенных полей [DateTime] (`DateTime.utc` как «наивное»).
String timeOf(DateTime wall) => clockText(wall.hour, wall.minute);

/// «Ср, 30 сентября».
String dayTitle(DateTime date) =>
    '${weekdayShortNames[weekdayIndex(date)]}, ${date.day} '
    '${monthGenitiveNames[date.month - 1]}';

/// «Ср, 30 сент.».
String dayTitleShort(DateTime date) =>
    '${weekdayShortNames[weekdayIndex(date)]}, ${date.day} '
    '${monthShortNames[date.month - 1]}';

/// «30 сентября» (с годом, если он не `now.year`).
String dayMonth(DateTime date, {DateTime? now}) {
  final base = '${date.day} ${monthGenitiveNames[date.month - 1]}';
  return now == null || date.year == now.year ? base : '$base ${date.year}';
}

/// «Сентябрь 2026».
String monthYear(DateTime date) => '${monthNames[date.month - 1]} ${date.year}';

/// «Сентябрь» либо «Сентябрь 2026» для года, отличного от [now].
String monthTitle(DateTime date, DateTime now) =>
    date.year == now.year ? monthNames[date.month - 1] : monthYear(date);

/// Период недели: «28 сент. – 4 окт.».
String weekRange(DateTime monday) {
  final sunday = addDays(monday, 6);
  final from = monday.month == sunday.month
      ? '${monday.day}'
      : '${monday.day} ${monthShortNames[monday.month - 1]}';
  return '$from – ${sunday.day} ${monthShortNames[sunday.month - 1]}';
}

/// «1 ч 30 мин», «45 мин», «2 ч».
String durationText(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m мин';
  if (m == 0) return '$h ч';
  return '$h ч $m мин';
}

/// Число суток от `today` до `date` словами: «сегодня», «вчера», «3 дня назад»,
/// «завтра», «через 5 дней».
String relativeDay(DateTime date, DateTime today) {
  final days = daysBetween(today, date);
  if (days == 0) return 'Сегодня';
  if (days == 1) return 'Завтра';
  if (days == -1) return 'Вчера';
  final n = days.abs();
  final word = _plural(n, 'день', 'дня', 'дней');
  return days < 0 ? '$n $word назад' : 'через $n $word';
}

String _plural(int n, String one, String few, String many) {
  final mod100 = n % 100;
  final mod10 = n % 10;
  if (mod100 >= 11 && mod100 <= 14) return many;
  if (mod10 == 1) return one;
  if (mod10 >= 2 && mod10 <= 4) return few;
  return many;
}
