// coverage:ignore-file
// Тонкая платформенная прослойка: без устройства не проверяется. Логика
// (что делать с уведомлением) — в `bank_pipeline.dart` и покрыта тестами на
// поддельной платформе. Нативная часть — Kotlin
// (`android/app/src/main/kotlin/.../BankNotificationListener.kt`).

import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/platform/bank_platform.dart';

const String _methodChannelName = 'my_tasker/banks';
const String _eventChannelName = 'my_tasker/banks/events';

/// Платформа Банков для текущей ОС: Android — слушатель уведомлений через
/// `MethodChannel`/`EventChannel`; остальные — [NoBankPlatform]. Проверяется
/// настоящая ОС, а не `defaultTargetPlatform`: `flutter test` выдаёт себя
/// за Android, а каналов там нет.
BankPlatform createPlatformBankPlatform() =>
    Platform.isAndroid ? _AndroidBankPlatform() : const NoBankPlatform();

class _AndroidBankPlatform implements BankPlatform {
  static const MethodChannel _method = MethodChannel(_methodChannelName);
  static const EventChannel _events = EventChannel(_eventChannelName);

  @override
  bool get isSupported => true;

  @override
  Future<void> setWatchedPackages(List<String> packages) =>
      _method.invokeMethod<void>('setPackages', packages);

  @override
  Future<bool> isListenerEnabled() async =>
      await _method.invokeMethod<bool>('isListenerEnabled') ?? false;

  @override
  Future<void> openListenerSettings() =>
      _method.invokeMethod<void>('openListenerSettings');

  @override
  Future<bool> isIgnoringBatteryOptimizations() async =>
      await _method.invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
      false;

  @override
  Future<void> openBatterySettings() =>
      _method.invokeMethod<void>('openBatterySettings');

  @override
  Future<List<RawNotification>> drain() async {
    final raw = await _method.invokeListMethod<Object?>('drain');
    return [
      for (final m in raw ?? const <Object?>[])
        RawNotification.fromMap((m! as Map).cast<Object?, Object?>()),
    ];
  }

  @override
  Stream<void> get wakeups => _events.receiveBroadcastStream().map((_) {});
}
