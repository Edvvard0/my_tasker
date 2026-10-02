import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Показание температуры (для экрана замеров; «если доступно»).
class ThermalSample {
  const ThermalSample({required this.maxCelsius, required this.source});

  final double maxCelsius;

  /// Откуда прочитано (`thermal_zone3`, ...), для отчёта.
  final String source;
}

/// Ресурсы устройства, нужные менеджеру моделей и замерам. Реализация по
/// умолчанию — [ProcDeviceResources]; тесты подставляют поддельную.
///
/// Любой метод вправе вернуть `null` («узнать не удалось»): проверки тогда
/// не блокируют действие, а в отчёте стоит прочерк.
abstract interface class DeviceResources {
  /// Свободное место на разделе, где лежит [path], байты.
  Future<int?> freeDiskBytes(String path);

  Future<int?> totalRamBytes();

  /// Доступная без вытеснения ОЗУ (`MemAvailable`).
  Future<int?> availableRamBytes();

  /// Текущий резидентный размер процесса приложения.
  Future<int?> currentRssBytes();

  /// Пиковый резидентный размер процесса за всё время (`VmHWM`).
  Future<int?> peakRssBytes();

  Future<ThermalSample?> thermal();
}

/// Разбор `/proc/meminfo`: ключ -> килобайты.
Map<String, int> parseMemInfo(String text) {
  final result = <String, int>{};
  for (final line in text.split('\n')) {
    final match = RegExp(r'^(\w+):\s+(\d+)\s*kB').firstMatch(line);
    if (match != null) result[match[1]!] = int.parse(match[2]!);
  }
  return result;
}

/// Значение `Vm*` из `/proc/self/status` в килобайтах (`VmRSS`, `VmHWM`).
int? parseProcStatusKb(String text, String key) {
  final match = RegExp(
    '^$key:\\s+(\\d+)\\s*kB',
    multiLine: true,
  ).firstMatch(text);
  return match == null ? null : int.parse(match[1]!);
}

/// Читает ресурсы из `/proc` и `/sys` (Android и Linux), место на диске —
/// через `statvfs` из libc (FFI). Без плагинов: чтение этих файлов приложению
/// разрешено, а недоступное возвращается как `null`.
// Тонкий слой над ОС: логика разбора вынесена в чистые функции выше.
class ProcDeviceResources implements DeviceResources {
  const ProcDeviceResources();

  Future<String?> _read(String path) async {
    try {
      return await File(path).readAsString();
    } on Object {
      return null;
    }
  }

  @override
  Future<int?> freeDiskBytes(String path) async => statvfsFreeBytes(path);

  @override
  Future<int?> totalRamBytes() async {
    final text = await _read('/proc/meminfo');
    final kb = text == null ? null : parseMemInfo(text)['MemTotal'];
    return kb == null ? null : kb * 1024;
  }

  @override
  Future<int?> availableRamBytes() async {
    final text = await _read('/proc/meminfo');
    final kb = text == null ? null : parseMemInfo(text)['MemAvailable'];
    return kb == null ? null : kb * 1024;
  }

  Future<int?> _status(String key) async {
    final text = await _read('/proc/self/status');
    final kb = text == null ? null : parseProcStatusKb(text, key);
    return kb == null ? null : kb * 1024;
  }

  @override
  Future<int?> currentRssBytes() => _status('VmRSS');

  @override
  Future<int?> peakRssBytes() => _status('VmHWM');

  @override
  Future<ThermalSample?> thermal() async {
    // На новых Android SELinux часто закрывает /sys/class/thermal для
    // приложений: тогда вернётся null, экран покажет «недоступно».
    try {
      final dir = Directory('/sys/class/thermal');
      if (!dir.existsSync()) return null;
      ThermalSample? best;
      for (final entity in dir.listSync()) {
        final name = entity.path.split('/').last;
        if (!name.startsWith('thermal_zone')) continue;
        final raw = await _read('${entity.path}/temp');
        final milli = int.tryParse(raw?.trim() ?? '');
        if (milli == null) continue;
        // Значения в милли-градусах; отбрасываем мусор вне 0..150 °C.
        final celsius = milli / 1000;
        if (celsius < 0 || celsius > 150) continue;
        if (best == null || celsius > best.maxCelsius) {
          best = ThermalSample(maxCelsius: celsius, source: name);
        }
      }
      return best;
    } on Object {
      return null;
    }
  }
}

typedef _StatvfsNative = Int32 Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _StatvfsDart = int Function(Pointer<Utf8>, Pointer<Uint8>);

/// Свободное для приложения место (`f_bavail * f_frsize`) на разделе [path];
/// `null`, если вызов недоступен (не Linux/Android, ошибка).
///
/// Раскладка `struct statvfs` на 64-разрядных Linux и Android (bionic):
/// `f_bsize`, `f_frsize`, `f_blocks`, `f_bfree`, `f_bavail` — по 8 байт.
int? statvfsFreeBytes(String path) {
  if (!Platform.isLinux && !Platform.isAndroid) return null;
  final pathPtr = path.toNativeUtf8();
  final buffer = calloc<Uint8>(512);
  try {
    final statvfs = DynamicLibrary.process()
        .lookupFunction<_StatvfsNative, _StatvfsDart>('statvfs');
    if (statvfs(pathPtr, buffer) != 0) return null;
    final words = buffer.cast<Uint64>();
    final fragmentSize = words[1];
    final available = words[4];
    return available * fragmentSize;
  } on Object {
    return null;
  } finally {
    calloc
      ..free(pathPtr)
      ..free(buffer);
  }
}
