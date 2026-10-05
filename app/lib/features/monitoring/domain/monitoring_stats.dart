/// Числа «Пульса» (spec `stage9_monitoring.md`, раздел 9).
///
/// Доступность и отклик считает сервер; клиент показывает готовые числа и
/// решает подсветку порогов. [availabilityBp] — тот же расчёт, что у сервера
/// (`stats.py`), общий контракт `shared-test-vectors/monitoring/
/// availability.json`: целочисленный, в базисных пунктах вниз.
library;

const int hourSeconds = 3600;
const int basis = 10000;

/// Окна доступности: 24 часа, 7 и 30 суток — в часовых корзинах.
const int hours24 = 24;
const int hours7d = 7 * 24;
const int hours30d = 30 * 24;

/// Часовая корзина итогов: начало часа (Unix-секунды), проверок, успешных.
class Bucket {
  const Bucket(this.hour, this.total, this.ok);

  final int hour;
  final int total;
  final int ok;
}

int hourFloor(int ts) => ts - ts % hourSeconds;

/// Доля успешных проверок за последние [hours] корзин, считая от корзины
/// момента [now] включительно (текущая неполная среди них), в базисных
/// пунктах вниз; `null` — в окне нет проверок.
int? availabilityBp(Iterable<Bucket> buckets, int now, int hours) {
  final last = hourFloor(now);
  final first = last - (hours - 1) * hourSeconds;
  var total = 0;
  var ok = 0;
  for (final b in buckets) {
    if (b.hour >= first && b.hour <= last) {
      total += b.total;
      ok += b.ok;
    }
  }
  return total == 0 ? null : ok * basis ~/ total;
}

/// Доступность текстом: `9884` -> «98,84 %», `10000` -> «100 %», `null` — «—».
/// Дробная часть без хвостовых нулей («99,9 %»).
String formatAvailability(int? bp) {
  if (bp == null) return '—';
  final whole = bp ~/ 100;
  final frac = bp % 100;
  if (frac == 0) return '$whole %';
  final digits = frac.toString().padLeft(2, '0');
  final trimmed = digits.endsWith('0') ? digits.substring(0, 1) : digits;
  return '$whole,$trimmed %';
}

/// Отклик текстом: «178 мс», «1,2 с», `null` — «—».
String formatResponse(int? ms) {
  if (ms == null) return '—';
  if (ms < 1000) return '$ms мс';
  final tenths = (ms / 100).round();
  final whole = tenths ~/ 10;
  final frac = tenths % 10;
  return frac == 0 ? '$whole с' : '$whole,$frac с';
}

/// Порог подсветки доступности (02, 5.5): ниже 99 % значение становится
/// белым жирным с иконкой предупреждения.
const int availabilityWarnBp = 9900;

/// Порог подсветки отклика: больше 500 мс.
const int responseWarnMs = 500;

bool availabilityWarns(int? bp) => bp != null && bp < availabilityWarnBp;

bool responseWarns(int? ms) => ms != null && ms > responseWarnMs;
