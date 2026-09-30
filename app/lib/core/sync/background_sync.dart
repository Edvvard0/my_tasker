import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';

/// Фоновая синхронизация ОС (spec 5.2: WorkManager ≈ 15 мин на Android;
/// на Windows работает таймер приложения).
///
/// Интерфейс тонкий: планировщик ОС только будит приложение и просит
/// выполнить один цикл ([runHeadlessSync]).
abstract interface class BackgroundSync {
  /// Ставит периодическую задачу (идемпотентно).
  Future<void> register();

  /// Снимает периодическую задачу (выход из аккаунта).
  Future<void> cancel();
}

/// Заглушка: платформы без фонового планировщика (Windows, тесты).
class NoBackgroundSync implements BackgroundSync {
  const NoBackgroundSync();

  @override
  Future<void> register() async {}

  @override
  Future<void> cancel() async {}
}

/// Один цикл синхронизации без интерфейса: читает токены, выполняет
/// [SyncEngine.runCycle]. Возвращает `false`, только если стоит повторить
/// позже (сбой сервера); «нет сети» и «нужен вход» — не повод для повтора.
Future<bool> runHeadlessSync(ProviderContainer container) async {
  final auth = container.read(authControllerProvider.notifier);
  await auth.ready;
  if (container.read(authControllerProvider) is! SignedIn) return true;
  final engine = container.read(syncEngineProvider);
  await engine.init();
  final outcome = await engine.runCycle();
  return outcome != SyncOutcome.failed;
}
