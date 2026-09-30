import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/auth/auth_models.dart';

/// Что приложение знает о своём устройстве: имя по умолчанию и платформа
/// для экрана входа (spec 1.1).
class DeviceInfoSource {
  const DeviceInfoSource({required this.defaultName, required this.platform});

  /// По данным ОС (`dart:io`).
  factory DeviceInfoSource.system() {
    if (Platform.isAndroid) {
      return const DeviceInfoSource(
        defaultName: 'Android',
        platform: DevicePlatform.android,
      );
    }
    final host = Platform.localHostname;
    final name = host.isEmpty ? 'Компьютер' : host;
    return DeviceInfoSource(
      defaultName: name.length > 64 ? name.substring(0, 64) : name,
      platform: Platform.isWindows
          ? DevicePlatform.windows
          : Platform.isLinux
          ? DevicePlatform.linux
          : Platform.isMacOS
          ? DevicePlatform.macos
          : Platform.isIOS
          ? DevicePlatform.ios
          : DevicePlatform.other,
    );
  }

  final String defaultName;
  final DevicePlatform platform;

  /// Подпись платформы для интерфейса.
  String get platformLabel => switch (platform) {
    DevicePlatform.android => 'Android',
    DevicePlatform.windows => 'Windows',
    DevicePlatform.linux => 'Linux',
    DevicePlatform.macos => 'macOS',
    DevicePlatform.ios => 'iOS',
    DevicePlatform.web => 'Веб',
    DevicePlatform.other => 'Другая',
  };
}

final deviceInfoSourceProvider = Provider<DeviceInfoSource>(
  (ref) => DeviceInfoSource.system(),
);
