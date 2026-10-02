import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_remote.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_api.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';

import 'calendar_env.dart' show appRegistry;
import 'fake_server/fake_sync_server.dart';
import 'fake_server/server_remote.dart';
import 'fakes.dart';
import 'in_memory_opener.dart';
import 'manual_clock.dart';

/// Поддельные эндпоинты ИИ: записывает запросы, ответ потока задаёт тест.
class FakeAiApi implements AiApi {
  FakeAiApi({
    this.catalog = const ModelCatalog(
      models: [
        ModelInfo(
          id: 'openai/gpt-4o',
          name: 'GPT-4o',
          supportsTools: true,
          contextLength: 128000,
          priceInputKopecksPerMtok: 25000,
          priceOutputKopecksPerMtok: 100000,
        ),
        ModelInfo(
          id: 'anthropic/claude-sonnet',
          name: 'Claude Sonnet',
          supportsTools: true,
          contextLength: 200000,
        ),
        ModelInfo(
          id: 'meta/llama-small',
          name: 'Llama Small',
          supportsTools: false,
        ),
      ],
    ),
  });

  ModelCatalog catalog;
  Exception? modelsError;
  int modelsCalls = 0;
  bool lastRefresh = false;

  UsageSummary usageValue = const UsageSummary(
    month: '2026-10',
    spentKopecks: 1234,
    requests: 12,
    promptTokens: 40000,
    completionTokens: 9000,
    limitKopecks: 50000,
    remainingKopecks: 48766,
    byModel: [
      ModelUsage(
        model: 'openai/gpt-4o',
        requests: 12,
        promptTokens: 40000,
        completionTokens: 9000,
        costKopecks: 1234,
      ),
    ],
  );
  Exception? usageError;
  final List<String?> usageMonths = [];

  int bootstrapCalls = 0;
  Exception? bootstrapError;

  List<SyncChange> resetChanges = const [];
  Exception? resetError;
  final List<String> resets = [];

  /// Сценарий ответа на запрос completion.
  Stream<ChatEvent> Function(CompletionRequest request)? onCompletion;
  final List<CompletionRequest> requests = [];
  final List<String> cancelled = [];
  Exception? cancelError;

  @override
  Future<AiBootstrap> bootstrap() async {
    bootstrapCalls++;
    if (bootstrapError != null) throw bootstrapError!;
    return const AiBootstrap(agentIds: []);
  }

  @override
  Future<List<SyncChange>> resetAgent(String seedKey) async {
    resets.add(seedKey);
    if (resetError != null) throw resetError!;
    return resetChanges;
  }

  @override
  Future<ModelCatalog> models({bool refresh = false}) async {
    modelsCalls++;
    lastRefresh = refresh;
    if (modelsError != null) throw modelsError!;
    return catalog;
  }

  @override
  Future<UsageSummary> usage({String? month}) async {
    usageMonths.add(month);
    if (usageError != null) throw usageError!;
    return usageValue;
  }

  @override
  Stream<ChatEvent> completions(CompletionRequest request) {
    requests.add(request);
    final handler = onCompletion;
    if (handler == null) throw StateError('onCompletion не задан');
    return handler(request);
  }

  @override
  Future<bool> cancel(String messageId) async {
    cancelled.add(messageId);
    if (cancelError != null) throw cancelError!;
    return true;
  }
}

/// Поток из готовых событий; закрывается после последнего.
Stream<ChatEvent> eventsStream(List<ChatEvent> events) =>
    Stream<ChatEvent>.fromIterable(events);

/// Обычный успешный ответ: `start`, дельты, `usage`, `done`.
List<ChatEvent> okAnswer(String messageId, List<String> deltas) => [
  ChatStart(messageId: messageId, model: 'openai/gpt-4o'),
  for (final d in deltas) ChatDelta(d),
  const ChatUsage(promptTokens: 100, completionTokens: 20, costKopecks: 12),
  ChatDone(
    messageId: messageId,
    finishReason: 'stop',
    promptTokens: 100,
    completionTokens: 20,
    costKopecks: 12,
  ),
];

/// [SyncRemote] устройства напрямую поверх [FakeSyncServer]: идентификатор
/// устройства берётся у хранилища при каждом вызове (оно создаёт его само).
class LazyDirectRemote implements SyncRemote {
  LazyDirectRemote(this.server, this._deviceId, {FaultPlan? faults})
    : faults = faults ?? FaultPlan();

  final FakeSyncServer server;
  final Future<String> Function() _deviceId;
  final FaultPlan faults;

  Future<DirectRemote> get _remote async =>
      DirectRemote(server, await _deviceId(), faults: faults);

  @override
  Future<PushResponse> push(List<Json> ops) async {
    final remote = await _remote;
    return await remote.push(ops);
  }

  @override
  Future<PullPage> pull({required int since, required int limit}) async {
    final remote = await _remote;
    return await remote.pull(since: since, limit: limit);
  }

  @override
  Future<ConflictsPage> conflicts({
    String reverted = 'all',
    int limit = 50,
    String? before,
  }) async {
    final remote = await _remote;
    return await remote.conflicts(
      reverted: reverted,
      limit: limit,
      before: before,
    );
  }

  @override
  Future<RevertResult> revert(String conflictId) async {
    final remote = await _remote;
    return await remote.revert(conflictId);
  }
}

/// Устройство ИИ-чата без интерфейса: провайдеры Riverpod, БД в памяти,
/// общий [FakeSyncServer], поддельное API ИИ. Сеть выключается через
/// [faults].
class AiDevice {
  AiDevice._(this.container, this.api, this.server, this.faults, this.clock);

  final ProviderContainer container;
  final FakeAiApi api;
  final FakeSyncServer server;
  final FaultPlan faults;
  final ManualClock clock;

  static Future<AiDevice> create(
    FakeSyncServer server, {
    required ManualClock clock,
    FakeAiApi? api,
    List<Override> overrides = const [],
  }) async {
    final fake = api ?? FakeAiApi();
    final faults = FaultPlan();
    late final ProviderContainer container;
    container = ProviderContainer(
      overrides: [
        databaseOpenerProvider.overrideWithValue(InMemoryDatabaseOpener()),
        connectivityMonitorProvider.overrideWithValue(FakeConnectivity()),
        syncAutostartProvider.overrideWithValue(false),
        clockProvider.overrideWithValue(() => clock.now),
        deviceTimeZoneSourceProvider.overrideWithValue(
          const FixedTimeZoneSource('Europe/Moscow'),
        ),
        aiApiProvider.overrideWithValue(fake),
        syncRemoteProvider.overrideWith(
          (ref) => LazyDirectRemote(
            server,
            () => ref.read(syncStoreProvider).deviceId(),
            faults: faults,
          ),
        ),
        ...overrides,
      ],
    );
    final device = AiDevice._(container, fake, server, faults, clock);
    // Движок поднимается как в приложении: до первого цикла.
    await container.read(syncEngineProvider).init();
    // Пояс устройства платформа сообщает асинхронно: ждём, как «Москва».
    await container.read(deviceTimeZoneProvider.notifier).refresh();
    return device;
  }

  Future<void> sync() => container.read(syncEngineProvider).runCycle();

  void dispose() => container.dispose();
}

/// Ошибка HTTP сервера ИИ до начала потока.
ApiException httpError(
  int status,
  String code, {
  Map<String, Object?>? details,
}) => ApiException(
  kind: ApiErrorKind.http,
  status: status,
  code: code,
  details: details ?? const {},
);

/// Сервер синхронизации с реестром приложения (включая таблицы ИИ).
FakeSyncServer aiServer(ManualClock clock) =>
    FakeSyncServer(registry: appRegistry(), nowMs: clock.call);
