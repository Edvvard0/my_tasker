import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/device_resources.dart';
import 'package:my_tasker/core/local_llm/network_probe.dart';

void main() {
  test('разбор /proc/meminfo', () {
    const text =
        'MemTotal:        7845412 kB\n'
        'MemFree:          310000 kB\n'
        'MemAvailable:    3100000 kB\n'
        'SwapTotal:             0 kB\n'
        'мусор без значения\n';
    final map = parseMemInfo(text);
    expect(map['MemTotal'], 7845412);
    expect(map['MemAvailable'], 3100000);
    expect(map.containsKey('Swap'), isFalse);
  });

  test('разбор /proc/self/status', () {
    const text = 'Name:\tapp\nVmHWM:\t 2900000 kB\nVmRSS:\t  800000 kB\n';
    expect(parseProcStatusKb(text, 'VmHWM'), 2900000);
    expect(parseProcStatusKb(text, 'VmRSS'), 800000);
    expect(parseProcStatusKb(text, 'VmSwap'), isNull);
  });

  test('statvfs возвращает положительное свободное место (Linux)', () {
    final free = statvfsFreeBytes(Directory.systemTemp.path);
    if (Platform.isLinux) {
      expect(free, isNotNull);
      expect(free, greaterThan(0));
      // Несуществующий путь — null, а не исключение.
      expect(statvfsFreeBytes('/нет/такого/пути'), isNull);
    } else {
      expect(free, isNull);
    }
  });

  test('чтение ресурсов на хосте разработки не падает', () async {
    const resources = ProcDeviceResources();
    final free = await resources.freeDiskBytes(Directory.systemTemp.path);
    final total = await resources.totalRamBytes();
    final peak = await resources.peakRssBytes();
    await resources.currentRssBytes();
    await resources.availableRamBytes();
    await resources.thermal();
    if (Platform.isLinux) {
      expect(free, greaterThan(0));
      expect(total, greaterThan(0));
      expect(peak, greaterThan(0));
    }
  });

  group('тип сети', () {
    test('Wi-Fi и кабель безлимитны, мобильная — нет', () {
      expect(networkKindOf([ConnectivityResult.wifi]).isUnmetered, isTrue);
      expect(networkKindOf([ConnectivityResult.ethernet]).isUnmetered, isTrue);
      expect(networkKindOf([ConnectivityResult.mobile]), NetworkKind.cellular);
      expect(NetworkKind.cellular.isUnmetered, isFalse);
    });

    test('Wi-Fi важнее мобильной сети; пусто — нет сети; VPN — неизвестно', () {
      expect(
        networkKindOf([ConnectivityResult.mobile, ConnectivityResult.wifi]),
        NetworkKind.wifi,
      );
      expect(networkKindOf([ConnectivityResult.none]), NetworkKind.none);
      expect(networkKindOf([ConnectivityResult.vpn]), NetworkKind.other);
      expect(NetworkKind.none.isOnline, isFalse);
      expect(NetworkKind.other.isOnline, isTrue);
    });
  });
}
