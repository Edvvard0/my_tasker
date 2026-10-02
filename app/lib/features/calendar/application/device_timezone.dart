import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:timezone/timezone.dart' as tz;

/// Источник имени таймзоны устройства (IANA). Платформенная часть тонкая:
/// `flutter_timezone` спрашивает у Android/Windows текущий пояс.
abstract interface class DeviceTimeZoneSource {
  /// Имя IANA (`Europe/Moscow`) или `null`, если определить не удалось.
  Future<String?> currentName();
}

/// Платформенная реализация на `flutter_timezone`.
// coverage:ignore-start
class PlatformDeviceTimeZoneSource implements DeviceTimeZoneSource {
  const PlatformDeviceTimeZoneSource();

  @override
  Future<String?> currentName() async {
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      return info.identifier;
    } on Object {
      return null;
    }
  }
}
// coverage:ignore-end

final deviceTimeZoneSourceProvider = Provider<DeviceTimeZoneSource>(
  (ref) => const PlatformDeviceTimeZoneSource(),
);

/// Часовой пояс устройства, в котором показывается календарь.
///
/// До ответа платформы используется пояс с фиксированным смещением,
/// снятым с системных часов; после — настоящая зона IANA (с летним
/// временем). [refresh] перечитывает пояс (при возврате в приложение и по
/// таймеру): смена пояса пересчитывает и экраны, и напоминания.
class DeviceTimeZoneNotifier extends Notifier<tz.Location> {
  @override
  tz.Location build() {
    ensureTimeZones();
    unawaited(Future.microtask(refresh));
    return _fixedOffset(DateTime.now().timeZoneOffset);
  }

  static tz.Location _fixedOffset(Duration offset) {
    final name = offset == Duration.zero ? 'UTC' : 'UTC${_fmt(offset)}';
    return tz.Location(name, [tz.minTime], [0], [
      tz.TimeZone(offset, isDst: false, abbreviation: name),
    ]);
  }

  static String _fmt(Duration offset) {
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final h = abs.inHours;
    final m = abs.inMinutes % 60;
    return m == 0 ? '$sign$h' : '$sign$h:${m.toString().padLeft(2, '0')}';
  }

  /// Перечитывает пояс устройства; `true`, если он изменился.
  Future<bool> refresh() async {
    final name = await ref.read(deviceTimeZoneSourceProvider).currentName();
    if (!ref.mounted || name == null) return false;
    final location = findLocation(name);
    if (location == null || location.name == state.name) return false;
    state = location;
    return true;
  }
}

final deviceTimeZoneProvider =
    NotifierProvider<DeviceTimeZoneNotifier, tz.Location>(
      DeviceTimeZoneNotifier.new,
    );

/// Пояс устройства подходит для записи в `tz` события (настоящее имя IANA).
bool isIanaLocation(tz.Location location) =>
    findLocation(location.name) != null;

/// Для тестов: зафиксированный пояс без обращения к платформе.
@visibleForTesting
class FixedTimeZoneSource implements DeviceTimeZoneSource {
  const FixedTimeZoneSource(this.name);

  final String? name;

  @override
  Future<String?> currentName() async => name;
}
