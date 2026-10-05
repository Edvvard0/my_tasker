import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/finance/data/secret_store.dart';

import 'ai_env.dart';
import 'fake_server/fake_sync_server.dart';
import 'fake_server/server_remote.dart';
import 'manual_clock.dart';
import 'pump_app.dart';

/// «Сейчас» для экранов ИИ: среда, 30 сентября 2026, 11:40 по Москве.
final DateTime aiNow = DateTime.utc(2026, 9, 30, 8, 40);

/// Всё, что нужно виджет-тесту экранов ИИ.
class AiUi {
  AiUi(this.container, this.api, this.server, this.faults);

  final ProviderContainer container;
  final FakeAiApi api;
  final FakeSyncServer server;
  final FaultPlan faults;

  AiRepository get repo => container.read(aiRepositoryProvider);

  /// Один цикл синхронизации (вызывать внутри `tester.runAsync`).
  Future<void> sync() => container.read(syncEngineProvider).runCycle();

  /// Репозиторий для сидов: идентификаторы «в момент» [aiNow], чтобы время
  /// последней активности в списке не зависело от настоящих часов.
  AiRepository get seedRepo => AiRepository(
    repo.storeForTests,
    newId: () => uuid7(nowMs: aiNow.millisecondsSinceEpoch),
    now: () => aiNow,
  );

  /// Записи в БД из виджет-теста идут вне фейковых часов.
  Future<void> seed(
    WidgetTester tester,
    Future<void> Function(AiRepository repo) body,
  ) async {
    await tester.runAsync(() => body(seedRepo));
    await tester.pump();
  }
}

/// Запускает приложение на экране ИИ: поддельный API ИИ, поддельный сервер
/// синхронизации (чат уходит на него перед запросом), Москва, фиксированное
/// время.
Future<AiUi> pumpAi(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/ai',
  FakeAiApi? api,
  Future<void> Function(AiRepository repo)? seed,
  List<Override> overrides = const [],
  bool settle = true,
  SecretStore? secretStore,
}) async {
  final fake = api ?? FakeAiApi();
  final clock = ManualClock(aiNow.millisecondsSinceEpoch);
  final server = aiServer(clock);
  final faults = FaultPlan();
  final container = await pumpApp(
    tester,
    size: size,
    location: location,
    now: aiNow,
    settle: false,
    defaultAiApi: false,
    secretStore: secretStore,
    overrides: [
      aiApiProvider.overrideWithValue(fake),
      deviceTimeZoneSourceProvider.overrideWithValue(
        const FixedTimeZoneSource('Europe/Moscow'),
      ),
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
  final ui = AiUi(container, fake, server, faults);
  if (seed != null) await ui.seed(tester, seed);
  if (settle) await tester.pumpAndSettle();
  return ui;
}

/// Профиль агента как его создаёт сервер.
Future<void> seedAgent(
  AiRepository repo,
  AiTopic topic, {
  required String id,
  String? seedKey,
  String? name,
  String prompt = 'Ты помощник.',
  int version = 1,
}) async {
  // Прямая запись через хранилище: профили создаёт сервер.
  final store = repoStore(repo);
  await store.create('ai_agent_profiles', id, {
    'seed_key': seedKey ?? topic.wire,
    'name': name ?? topic.label,
    'topic': topic.wire,
    'system_prompt': prompt,
    'prompt_version': version,
    'default_model': null,
    'enabled_tools': ['get_tasks', 'get_events', 'create_task'],
    'default_context_preset_id': null,
    'position': AiTopic.values.indexOf(topic),
  });
  await store.create('ai_prompt_versions', promptVersionId(id, version), {
    'profile_id': id,
    'version': version,
    'text': prompt,
    'source': 'seed',
  });
}

/// Сообщение ассистента, сохранённое сервером.
Future<void> seedAssistantMessage(
  AiRepository repo, {
  required String id,
  required String conversationId,
  required String text,
  List<Map<String, Object?>>? parts,
  String status = 'done',
  String? finishReason = 'stop',
  String? errorCode,
  int? promptTokens = 1000,
  int? completionTokens = 234,
  int? costKopecks = 12,
}) => repoStore(repo)
    .create('ai_messages', id, {
      'conversation_id': conversationId,
      'role': 'assistant',
      'text': text,
      'parts':
          parts ??
          [
            {'type': 'text', 'text': text},
          ],
      'status': status,
      'model': 'openai/gpt-4o',
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'cost_kopecks': costKopecks,
      'finish_reason': finishReason,
      'error_code': errorCode,
    })
    .then((_) {});

/// Хранилище репозитория (для сидов, имитирующих запись сервера).
SyncStore repoStore(AiRepository repo) => repo.storeForTests;

/// Находит поле по ключу и вводит текст.
Future<void> typeInto(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

/// Уникальный ответ потока для тестов интерфейса.
List<ChatEvent> answer(String id, List<String> deltas) => okAnswer(id, deltas);
