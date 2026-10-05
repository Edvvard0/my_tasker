import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/banks/platform/bank_platform.dart';

/// Выдан ли доступ к уведомлениям (перечитывается по `invalidate`: после
/// возврата из системных настроек).
final FutureProvider<bool> listenerEnabledProvider = FutureProvider<bool>(
  (ref) => ref.watch(bankPlatformProvider).isListenerEnabled(),
);

/// Исключено ли приложение из оптимизации батареи.
final FutureProvider<bool> batteryExemptProvider = FutureProvider<bool>(
  (ref) => ref.watch(bankPlatformProvider).isIgnoringBatteryOptimizations(),
);
