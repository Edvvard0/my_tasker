import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/sync/ids.dart';

/// Максимальное значение счётчика HLC (5 цифр).
const int hlcMaxCounter = 99999;

/// Длина строки HLC: `15 + 1 + 5 + 1 + 36`.
const int hlcLength = 58;

/// Строка не является корректным HLC или его компонент вне диапазона.
class HlcFormatException extends FormatException {
  const HlcFormatException(super.message);
}

final RegExp _hlcPattern = RegExp(
  '^([0-9]{15})-([0-9]{5})-'
  r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$',
);

/// Разобранный HLC (spec 2.1).
@immutable
class Hlc implements Comparable<Hlc> {
  const Hlc(this.ms, this.counter, this.device);

  /// Разбирает строку; бросает [HlcFormatException].
  factory Hlc.parse(String value) {
    final match = _hlcPattern.firstMatch(value);
    if (match == null) throw const HlcFormatException('malformed hlc');
    return Hlc(int.parse(match[1]!), int.parse(match[2]!), match[3]!);
  }

  final int ms;
  final int counter;
  final String device;

  @override
  int compareTo(Hlc other) => toString().compareTo(other.toString());

  @override
  String toString() => formatHlc(ms, counter, device);

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.ms == ms &&
      other.counter == counter &&
      other.device == device;

  @override
  int get hashCode => Object.hash(ms, counter, device);
}

/// `"{ms:015d}-{counter:05d}-{device}"`; бросает [HlcFormatException],
/// если `ms` или `counter` вне диапазона либо [device] — не uuid.
String formatHlc(int ms, int counter, String device) {
  if (ms < 0 || ms >= 1000000000000000 || counter < 0 || counter > 99999) {
    throw const HlcFormatException('hlc component out of range');
  }
  if (!isUuid(device)) throw const HlcFormatException('bad device id');
  return '${ms.toString().padLeft(15, '0')}-'
      '${counter.toString().padLeft(5, '0')}-$device';
}

/// Миллисекунды HLC (первые 15 символов корректной строки).
int hlcMs(String hlc) => int.parse(hlc.substring(0, 15));

/// Устройство HLC (последние 36 символов корректной строки).
String hlcDevice(String hlc) => hlc.substring(hlc.length - 36);

/// Сравнение HLC: обычное сравнение строк (spec 2.1) -> -1, 0 или 1.
int compareHlc(String a, String b) => a.compareTo(b).sign;

/// Проверка формата без исключения.
bool isValidHlc(String value) => _hlcPattern.hasMatch(value);

/// Состояние часов `(l, c)` (spec 2.2).
@immutable
class HlcState {
  const HlcState(this.l, this.c);

  static const zero = HlcState(0, 0);

  final int l;
  final int c;

  @override
  bool operator ==(Object other) =>
      other is HlcState && other.l == l && other.c == c;

  @override
  int get hashCode => Object.hash(l, c);

  @override
  String toString() => 'HlcState($l, $c)';
}

/// Гибридные логические часы устройства (spec 2.2). Чистая логика без
/// хранения: постоянное хранение состояния делает `SyncStore` в той же
/// локальной транзакции, что и правка строки.
class HlcClock {
  HlcClock(this.device, [HlcState state = HlcState.zero])
    : _l = state.l,
      _c = state.c;

  final String device;
  int _l;
  int _c;

  HlcState get state => HlcState(_l, _c);

  /// Метка для новой локальной правки.
  String send(int nowMs) {
    if (nowMs > _l) {
      _l = nowMs;
      _c = 0;
    } else {
      _c += 1;
    }
    _normalize();
    return formatHlc(_l, _c, device);
  }

  /// Учитывает `updated_at` строки, пришедшей с сервера.
  void receive(String remote, int nowMs) {
    final parsed = Hlc.parse(remote);
    final l = [_l, parsed.ms, nowMs].reduce((a, b) => a > b ? a : b);
    if (l == _l && l == parsed.ms) {
      _c = (_c > parsed.counter ? _c : parsed.counter) + 1;
    } else if (l == _l) {
      _c += 1;
    } else if (l == parsed.ms) {
      _c = parsed.counter + 1;
    } else {
      _c = 0;
    }
    _l = l;
    _normalize();
  }

  void _normalize() {
    if (_c > hlcMaxCounter) {
      _l += 1;
      _c = 0;
    }
  }
}
