import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Таймзоны (IANA) с встроенной базой `timezone` — работает офлайн и без
/// зависимости от системной базы (Android/Windows).
bool _initialized = false;

/// Загружает базу таймзон (один раз). Вызывается при старте приложения и
/// в тестах; повторный вызов безопасен.
void ensureTimeZones() {
  if (_initialized) return;
  tzdata.initializeTimeZones();
  _initialized = true;
}

/// Таймзона по имени IANA (`Europe/Moscow`, `UTC`); `null`, если имени нет.
tz.Location? findLocation(String name) {
  ensureTimeZones();
  try {
    return tz.getLocation(name);
  } on tz.LocationNotFoundException {
    return null;
  }
}

/// Таймзона по имени; [ArgumentError], если имени нет в базе.
tz.Location requireLocation(String name) =>
    findLocation(name) ?? (throw ArgumentError.value(name, 'tz', 'нет в IANA'));

/// «Настенное» время [year]-[month]-[day] [hour]:[minute]:[second] в зоне
/// [location] -> момент UTC (spec 1.1).
///
/// Правило одно для всех реализаций: берётся смещение, действовавшее **до**
/// ближайшего перехода. Неоднозначное время (осенью 02:30 дважды) — первое
/// вхождение; несуществующее (весной 02:30 не бывает) — сдвигается вперёд
/// на величину скачка. Пакет `timezone` в разрывах ведёт себя иначе, поэтому
/// шаг сделан явно.
DateTime wallToUtc(
  tz.Location location,
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
  int second = 0,
]) {
  const dayMs = 86400000;
  final naive = DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second,
  ).millisecondsSinceEpoch;
  final before = location.timeZone(naive - dayMs).offset.inMilliseconds;
  final after = location.timeZone(naive + dayMs).offset.inMilliseconds;
  if (before == after) {
    return DateTime.fromMillisecondsSinceEpoch(naive - before, isUtc: true);
  }
  final candidates = <int>{
    for (final offset in {before, after})
      if (location.timeZone(naive - offset).offset.inMilliseconds == offset)
        naive - offset,
  };
  if (candidates.isEmpty) {
    // Разрыв: смещение до перехода.
    return DateTime.fromMillisecondsSinceEpoch(naive - before, isUtc: true);
  }
  // Одно значение — обычное время; два — неоднозначное: раньше по UTC.
  final chosen = candidates.reduce((a, b) => a < b ? a : b);
  return DateTime.fromMillisecondsSinceEpoch(chosen, isUtc: true);
}

/// Момент UTC -> «настенные» поля в зоне [location] (как `DateTime.utc`
/// с теми же числами: год, месяц, день, час, минута, секунда).
DateTime utcToWall(tz.Location location, DateTime instant) {
  final ms = instant.millisecondsSinceEpoch;
  final offset = location.timeZone(ms).offset.inMilliseconds;
  return DateTime.fromMillisecondsSinceEpoch(ms + offset, isUtc: true);
}

/// Смещение зоны [location] в момент [instant].
Duration offsetAt(tz.Location location, DateTime instant) =>
    location.timeZone(instant.millisecondsSinceEpoch).offset;
