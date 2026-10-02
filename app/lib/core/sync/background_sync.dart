import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/settings/application/server_connection_controller.dart';

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

/// Что сделать после фонового цикла (успешного или нет): например,
/// пересчитать локальные напоминания по свежим данным. Ошибка хука не
/// влияет на результат синхронизации. Нужен, потому что изолят WorkManager —
/// отдельный процесс: интерфейс с его таймерами там не запущен.
typedef HeadlessSyncHook = Future<void> Function(ProviderContainer container);

/// Один цикл синхронизации без интерфейса: читает токены, выполняет
/// [SyncEngine.runCycle]. Возвращает `false`, только если стоит повторить
/// позже (сбой сервера, сервер ещё не настроен); «нет сети» и «нужен вход» —
/// не повод для повтора.
///
/// Холодный старт: настройки сервера лежат в БД и читаются асинхронно, поэтому
/// перед циклом они дожидаются явно (иначе клиент API был бы `null`, а цикл
/// вернул бы `notConfigured`, который здесь **не** считается успехом).
///
/// Два изолята: WorkManager запускает Dart-изолят рядом с живым приложением.
/// Пока интерфейс на переднем плане, он сам синхронизируется (SSE, таймер) и
/// ведёт отметку в `sync_meta` (`SyncStore.markForeground`); тогда фоновый
/// запуск пропускается и считается успешным. Отметка устаревает за 90 с, так
/// что убитое приложение WorkManager не блокирует.
Future<bool> runHeadlessSync(
  ProviderContainer container, {
  HeadlessSyncHook? afterSync,
}) async {
  final store = container.read(syncStoreProvider);
  try {
    if (await store.isForegroundActive()) return true;
  } on Object {
    // Нет читаемой БД — пусть решает остальной код.
  }
  final auth = container.read(authControllerProvider.notifier);
  await auth.ready;
  if (container.read(authControllerProvider) is! SignedIn) return true;
  try {
    await container.read(serverConnectionSettingsProvider.future);
  } on Object {
    return false;
  }
  final engine = container.read(syncEngineProvider);
  await engine.init();
  final outcome = await engine.runCycle();
  if (afterSync != null) {
    try {
      await afterSync(container);
    } on Object {
      // Хук вторичен: сбой не должен портить результат синхронизации.
    }
  }
  return switch (outcome) {
    SyncOutcome.failed || SyncOutcome.notConfigured => false,
    _ => true,
  };
}
