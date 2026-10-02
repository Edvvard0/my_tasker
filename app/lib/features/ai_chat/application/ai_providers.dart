import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/network/api_providers.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_api.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_format.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';

/// Ключ настройки: месячный лимит расходов в копейках (spec 5.5).
const String monthlyLimitKey = 'ai.monthly_limit_kopecks';

final aiApiProvider = Provider<AiApi>(
  (ref) => HttpAiApi(() => resolveApiClient(ref)),
);

final StreamProvider<List<Conversation>> conversationsProvider =
    StreamProvider<List<Conversation>>(
      (ref) => ref.watch(aiRepositoryProvider).watchConversations(),
    );

final StreamProvider<Map<String, ChatMessage>> lastMessagesProvider =
    StreamProvider<Map<String, ChatMessage>>(
      (ref) => ref.watch(aiRepositoryProvider).watchLastMessages(),
    );

final StreamProvider<List<AgentProfile>> agentsProvider =
    StreamProvider<List<AgentProfile>>(
      (ref) => ref.watch(aiRepositoryProvider).watchAgents(),
    );

final StreamProvider<List<ContextPreset>> presetsProvider =
    StreamProvider<List<ContextPreset>>(
      (ref) => ref.watch(aiRepositoryProvider).watchPresets(),
    );

final StreamProvider<List<ModelFavorite>> favoritesProvider =
    StreamProvider<List<ModelFavorite>>(
      (ref) => ref.watch(aiRepositoryProvider).watchFavorites(),
    );

// Тип семейства Riverpod 3 недоступен из публичного API.
// ignore: specify_nonobvious_property_types
final conversationProvider = StreamProvider.autoDispose
    .family<Conversation?, String>(
      (ref, id) => ref.watch(aiRepositoryProvider).watchConversation(id),
    );

// Тип семейства Riverpod 3 недоступен из публичного API.
// ignore: specify_nonobvious_property_types
final messagesProvider = StreamProvider.autoDispose
    .family<List<ChatMessage>, String>(
      (ref, id) => ref.watch(aiRepositoryProvider).watchMessages(id),
    );

// Тип семейства Riverpod 3 недоступен из публичного API.
// ignore: specify_nonobvious_property_types
final proposalsProvider = StreamProvider.autoDispose
    .family<Map<String, ToolProposal>, String>(
      (ref, id) => ref.watch(aiRepositoryProvider).watchProposals(id),
    );

// Тип семейства Riverpod 3 недоступен из публичного API.
// ignore: specify_nonobvious_property_types
final promptVersionsProvider = StreamProvider.autoDispose
    .family<List<PromptVersion>, String>(
      (ref, id) => ref.watch(aiRepositoryProvider).watchPromptVersions(id),
    );

/// Каталог моделей `GET /ai/models`. Недоступность сети — ошибка
/// провайдера; интерфейс показывает «Каталог недоступен».
class ModelCatalogNotifier extends AsyncNotifier<ModelCatalog> {
  @override
  Future<ModelCatalog> build() => ref.watch(aiApiProvider).models();

  /// Принудительно обновляет каталог на сервере (`refresh=true`).
  Future<void> refresh() async {
    state = const AsyncLoading<ModelCatalog>();
    state = await AsyncValue.guard(
      () => ref.read(aiApiProvider).models(refresh: true),
    );
  }
}

final modelCatalogProvider =
    AsyncNotifierProvider<ModelCatalogNotifier, ModelCatalog>(
      ModelCatalogNotifier.new,
      // Сеть недоступна — экран показывает «Каталог недоступен» и кнопку
      // обновления, а не крутит автоповторы.
      retry: (_, _) => null,
    );

/// Расход за месяц `YYYY-MM` (`null` — текущий).
// Тип семейства Riverpod 3 недоступен из публичного API.
// ignore: specify_nonobvious_property_types
final usageProvider = FutureProvider.autoDispose.family<UsageSummary, String?>(
  (ref, month) => ref.watch(aiApiProvider).usage(month: month),
);

/// Месячный лимит (копейки) из синхронизируемых настроек; `null` — нет.
final StreamProvider<int?> monthlyLimitProvider = StreamProvider<int?>(
  (ref) => ref
      .watch(userSettingsRepositoryProvider)
      .watch(monthlyLimitKey)
      .map((v) => v is int && v >= 0 ? v : null),
);

/// Текущий месяц `YYYY-MM` в таймзоне биллинга сервера (Москва, UTC+3).
String billingMonth(DateTime now) =>
    monthOf(now.toUtc().add(const Duration(hours: 3)));

final billingMonthProvider = Provider<String>(
  (ref) => billingMonth(ref.watch(clockProvider)()),
);

/// Заводит предустановленных агентов на сервере и подтягивает их
/// (spec 3, `POST /ai/bootstrap`): при первом входе в раздел ИИ, пока
/// локально нет ни одного агента. Сбой (нет сети) не критичен: агентов
/// можно будет получить позже.
final aiBootstrapProvider = FutureProvider<void>((ref) async {
  final repo = ref.watch(aiRepositoryProvider);
  final agents = await repo.agents();
  if (agents.isNotEmpty) return;
  try {
    await ref.read(aiApiProvider).bootstrap();
    await ref.read(syncEngineProvider).runCycle();
  } on Object {
    // Нет сети или сервера: раздел работает и без агентов.
  }
});
