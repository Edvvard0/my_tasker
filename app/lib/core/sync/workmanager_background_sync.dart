// coverage:ignore-file
// Тонкая привязка к плагину `workmanager`: без Android-окружения её
// не проверить. Вся логика цикла — в `runHeadlessSync` (покрыт тестами).
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/sync/background_sync.dart';
import 'package:workmanager/workmanager.dart';

const String _uniqueName = 'my_tasker.periodic_sync';
const String _taskName = 'sync';

/// Точка входа фонового изолята WorkManager. Должна быть top-level и
/// помечена `vm:entry-point`, иначе AOT-сборка её вырежет.
@pragma('vm:entry-point')
void syncCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final container = ProviderContainer();
    try {
      return await runHeadlessSync(container);
    } on Object {
      return false; // WorkManager повторит с задержкой
    } finally {
      container.dispose();
    }
  });
}

/// Периодическая синхронизация на Android: каждые ≈15 минут (минимум
/// WorkManager) при наличии сети. На других платформах — пустышка.
///
/// Как проверить в фазе сборки: команда `adb shell cmd jobscheduler run -f`
/// с идентификатором пакета и номером задачи либо отладочные уведомления
/// `Workmanager`.
class WorkmanagerBackgroundSync implements BackgroundSync {
  const WorkmanagerBackgroundSync();

  static bool get supported => Platform.isAndroid;

  @override
  Future<void> register() async {
    if (!supported) return;
    await Workmanager().initialize(syncCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      _uniqueName,
      _taskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  @override
  Future<void> cancel() async {
    if (!supported) return;
    await Workmanager().cancelByUniqueName(_uniqueName);
  }
}
