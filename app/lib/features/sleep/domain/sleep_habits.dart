import 'package:my_tasker/features/sleep/domain/sleep_models.dart';

/// Привычный режим: отбой и подъём в минутах от полуночи.
typedef UsualTimes = ({int bed, int wake});

/// Режим по умолчанию, пока записей нет: 23:30 → 07:30.
const UsualTimes defaultUsualTimes = (bed: 23 * 60 + 30, wake: 7 * 60 + 30);

/// Сколько последних ночей учитывает привычный режим.
const int usualNights = 14;

int _median(List<int> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) ~/ 2;
}

int? _minutes(String clock) {
  if (clock.length != 5) return null;
  final h = int.tryParse(clock.substring(0, 2));
  final m = int.tryParse(clock.substring(3));
  return h == null || m == null ? null : h * 60 + m;
}

/// Привычные отбой и подъём — медианы по последним [usualNights] ночам (по
/// настенным часам). Отбой после полуночи (00:14) считается продолжением
/// вечера, поэтому медиана не «ломается» на стыке суток. Без записей —
/// [defaultUsualTimes].
UsualTimes usualTimes(List<SleepEntry> entries) {
  final recent = [...entries]..sort((a, b) => b.date.compareTo(a.date));
  final beds = <int>[];
  final wakes = <int>[];
  for (final e in recent.take(usualNights)) {
    final view = e.view;
    if (view == null) continue;
    final bed = _minutes(view.bedLocal);
    final wake = _minutes(view.wakeLocal);
    if (bed == null || wake == null) continue;
    beds.add(bed < 12 * 60 ? bed + 24 * 60 : bed);
    wakes.add(wake);
  }
  if (beds.isEmpty) return defaultUsualTimes;
  return (bed: _median(beds) % (24 * 60), wake: _median(wakes));
}

/// Разброс времени отбоя в минутах: наибольшее отклонение от медианы
/// (по последним ночам); `null`, если ночей меньше двух.
int? bedSpread(List<SleepEntry> entries) {
  final beds = <int>[];
  for (final e in entries) {
    final view = e.view;
    final bed = view == null ? null : _minutes(view.bedLocal);
    if (bed != null) beds.add(bed < 12 * 60 ? bed + 24 * 60 : bed);
  }
  if (beds.length < 2) return null;
  final mid = _median(beds);
  return beds.map((b) => (b - mid).abs()).reduce((a, b) => a > b ? a : b);
}
