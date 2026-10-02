import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/local_llm/chat_routing.dart';
import 'package:my_tasker/core/local_llm/device_resources.dart';
import 'package:my_tasker/core/local_llm/flutter_gemma_engine.dart';
import 'package:my_tasker/core/local_llm/idle_unloader.dart';
import 'package:my_tasker/core/local_llm/llama_cpp_engine.dart';
import 'package:my_tasker/core/local_llm/local_benchmark.dart';
import 'package:my_tasker/core/local_llm/local_chat_service.dart';
import 'package:my_tasker/core/local_llm/local_context.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';
import 'package:my_tasker/core/local_llm/model_catalog.dart';
import 'package:my_tasker/core/local_llm/model_downloader.dart';
import 'package:my_tasker/core/local_llm/model_manager.dart';
import 'package:my_tasker/core/local_llm/network_probe.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart' show ChatMode;
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';
import 'package:path_provider/path_provider.dart';

/// Ключ настройки: качать модели только по Wi-Fi (по умолчанию да).
const String wifiOnlyKey = 'ai.local.wifi_only';

/// Движок локальной модели: на Android (arm64) — `flutter_gemma`, на
/// остальных платформах (Windows) — заглушка «недоступно».
final localLlmEngineProvider = Provider<LocalLlmEngine>((ref) {
  final engine = Platform.isAndroid
      ? FlutterGemmaEngine()
      : const UnsupportedLlmEngine();
  ref.onDispose(() => unawaited(engine.unload()));
  return engine;
});

final deviceResourcesProvider = Provider<DeviceResources>(
  (ref) => const ProcDeviceResources(),
);

final networkProbeProvider = Provider<NetworkProbe>(
  (ref) => PlatformNetworkProbe(),
);

final modelDownloaderProvider = Provider<ModelDownloader>(
  (ref) => DioModelDownloader(),
);

/// Каталог моделей: на Android — каталог приложения во внешнем хранилище
/// (`getExternalStorageDirectory`): без разрешений, не попадает в
/// автокопию Android (лимит 25 МБ, 2,6 ГБ её сломали бы) и не чистится
/// системой, как кэш. Иначе — каталог поддержки приложения.
final modelsDirProvider = Provider<Future<Directory> Function()>(
  (ref) => () async {
    Directory? base;
    if (Platform.isAndroid) {
      try {
        base = await getExternalStorageDirectory();
      } on Object {
        base = null;
      }
    }
    base ??= await getApplicationSupportDirectory();
    return await Directory('${base.path}/local_models').create(recursive: true);
  },
);

/// Настройка «качать только по Wi-Fi» (по умолчанию включена).
final StreamProvider<bool> wifiOnlyProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(userSettingsRepositoryProvider)
      .watch(wifiOnlyKey)
      .map((v) => v is! bool || v),
);

final localModelManagerProvider = Provider<LocalModelManager>((ref) {
  final engine = ref.watch(localLlmEngineProvider);
  final manager = LocalModelManager(
    modelsDir: ref.watch(modelsDirProvider),
    downloader: ref.watch(modelDownloaderProvider),
    resources: ref.watch(deviceResourcesProvider),
    network: ref.watch(networkProbeProvider),
    wifiOnly: () async {
      final value = await ref
          .read(userSettingsRepositoryProvider)
          .read(wifiOnlyKey);
      return value is! bool || value;
    },
    isInUse: (id) => engine.loadedModel?.modelId == id,
  );
  ref.onDispose(() => unawaited(manager.dispose()));
  return manager;
});

/// Состояния моделей каталога (сканирование диска + события менеджера).
final StreamProvider<Map<String, LocalModelState>> localModelStatesProvider =
    StreamProvider<Map<String, LocalModelState>>((ref) async* {
      final manager = ref.watch(localModelManagerProvider);
      await manager.refresh();
      yield manager.snapshot;
      yield* manager.states;
    });

/// Есть ли сеть (по `connectivity_plus`).
final StreamProvider<bool> isOnlineProvider = StreamProvider<bool>((
  ref,
) async* {
  final monitor = ref.watch(connectivityMonitorProvider);
  yield await monitor.isOnline();
  yield* monitor.onlineChanges;
});

/// Готовность локального режима: платформа + скачанная модель.
final localAvailabilityProvider = Provider<LocalAvailability>((ref) {
  final engine = ref.watch(localLlmEngineProvider);
  if (!engine.isSupported) return LocalAvailability.unsupportedPlatform;
  final states = ref.watch(localModelStatesProvider).value;
  final ready = states?[gemma4E2b.id]?.isReady ?? false;
  return ready ? LocalAvailability.ready : LocalAvailability.modelNotReady;
});

/// Загружает модель в движок перед ответом: проверка ОЗУ и файла.
Future<void> ensureLocalModelLoaded(Ref ref, String modelId) async {
  final engine = ref.read(localLlmEngineProvider);
  if (engine.loadedModel?.modelId == modelId) return;
  final manager = ref.read(localModelManagerProvider);
  final check = await manager.checkCanRun(modelId);
  if (!check.canRun) {
    throw LocalLlmException(
      LocalLlmErrorKind.outOfMemory,
      check.failure!.message,
    );
  }
  final file = await manager.modelFile(modelId);
  if (file == null) {
    throw const LocalLlmException(
      LocalLlmErrorKind.notLoaded,
      'Модель не скачана: откройте «Настройки ИИ» -> «Офлайн-модель»',
    );
  }
  await engine.load(file);
}

/// Сервис локального чата. Интеграция в чат этапа 3 — через
/// `ChatModeSwitch` и `LocalChatService.reply` (см. README модуля в
/// комментарии `local_chat_service.dart`).
final localChatServiceProvider = Provider<LocalChatService>((ref) {
  final repo = ref.watch(aiRepositoryProvider);
  final engine = ref.watch(localLlmEngineProvider);
  // Модель занимает ~3 ГБ ОЗУ: выгружаем после 5 минут без ответов.
  final idle = IdleUnloader(unload: engine.unload);
  ref.onDispose(idle.dispose);
  return LocalChatService(
    onBusyChanged: ({required busy}) => busy ? idle.hold() : idle.touch(),
    engine: engine,
    store: ref.watch(syncStoreProvider),
    repository: repo,
    ensureModelLoaded: (id) => ensureLocalModelLoaded(ref, id),
    contextText: (conversation) async {
      final presetId = conversation.contextPresetId;
      final preset = presetId == null ? null : await repo.getPreset(presetId);
      final package = await buildLocalContext(
        ref.read(contextBuilderProvider),
        ref.read(contextEnvProvider)(),
        preset: preset,
      );
      return package.text;
    },
    zone: () => ref.read(deviceTimeZoneProvider),
    now: ref.watch(clockProvider),
  );
});

/// Состояние экрана замеров.
class BenchmarkState {
  const BenchmarkState({
    this.running = false,
    this.done = 0,
    this.total = 20,
    this.report,
    this.error,
    this.loadingModel = false,
  });

  final bool running;
  final bool loadingModel;
  final int done;
  final int total;
  final BenchmarkReport? report;
  final String? error;
}

class BenchmarkController extends Notifier<BenchmarkState> {
  BenchmarkCancel? _cancel;

  @override
  BenchmarkState build() => const BenchmarkState();

  /// Запускает прогон 20 фраз на скачанной модели.
  Future<void> start() async {
    if (state.running) return;
    state = const BenchmarkState(running: true, loadingModel: true);
    final engine = ref.read(localLlmEngineProvider);
    try {
      await ensureLocalModelLoaded(ref, gemma4E2b.id);
      final cancel = _cancel = BenchmarkCancel();
      state = const BenchmarkState(running: true);
      final runner = LocalBenchmarkRunner(
        engine: engine,
        resources: ref.read(deviceResourcesProvider),
        zone: ref.read(deviceTimeZoneProvider),
        modelLabel: gemma4E2b.name,
      );
      final report = await runner.run(
        cancel: cancel,
        onProgress: (done, total, _) {
          state = BenchmarkState(running: true, done: done, total: total);
        },
      );
      state = BenchmarkState(report: report, done: report.items.length);
    } on LocalLlmException catch (e) {
      state = BenchmarkState(error: e.message);
    } on Object catch (e) {
      state = BenchmarkState(error: '$e');
    } finally {
      _cancel = null;
    }
  }

  Future<void> stop() async {
    _cancel?.cancel();
    await ref.read(localLlmEngineProvider).cancel();
  }
}

final benchmarkControllerProvider =
    NotifierProvider<BenchmarkController, BenchmarkState>(
      BenchmarkController.new,
    );

/// Решение по отправке сообщения: режим беседы + сеть + готовность модели
/// (`decideRoute`). Чат этапа 3 читает его перед отправкой.
// Тип семейства Riverpod 3 недоступен из публичного API.
// ignore: specify_nonobvious_property_types
final routeDecisionProvider = Provider.family<RouteDecision, ChatMode>((
  ref,
  mode,
) {
  final online = ref.watch(isOnlineProvider).value ?? true;
  return decideRoute(
    mode: mode,
    online: online,
    local: ref.watch(localAvailabilityProvider),
  );
});

/// Сведения об устройстве для экрана моделей.
class LocalDeviceInfo {
  const LocalDeviceInfo({
    this.usedBytes = 0,
    this.freeBytes,
    this.totalRamBytes,
    this.availableRamBytes,
  });

  final int usedBytes;
  final int? freeBytes;
  final int? totalRamBytes;
  final int? availableRamBytes;
}

/// Занятое моделями место, свободное место и ОЗУ (обновляется при каждом
/// изменении состояний моделей).
final FutureProvider<LocalDeviceInfo> localDeviceInfoProvider =
    FutureProvider.autoDispose<LocalDeviceInfo>((ref) async {
      ref.watch(localModelStatesProvider);
      final manager = ref.watch(localModelManagerProvider);
      final resources = ref.watch(deviceResourcesProvider);
      return LocalDeviceInfo(
        usedBytes: await manager.usedBytes(),
        freeBytes: await manager.freeBytes(),
        totalRamBytes: await resources.totalRamBytes(),
        availableRamBytes: await resources.availableRamBytes(),
      );
    });

/// Записывает настройку «только Wi-Fi» (синхронизируется как обычная
/// настройка).
final setWifiOnlyProvider = Provider<ValueChanged<bool>>(
  (ref) =>
      (value) => unawaited(
        ref.read(userSettingsRepositoryProvider).set(wifiOnlyKey, value),
      ),
);
