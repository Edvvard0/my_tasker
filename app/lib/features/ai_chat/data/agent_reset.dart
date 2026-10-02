import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/ai_chat/data/ai_api.dart';

/// «Сбросить» системный промт предустановленного агента (spec Этапа 3, 7):
/// сервер возвращает строки в формате `pull` (профиль и новую версию
/// `reset`), клиент применяет их как строки pull. Сеть недоступна —
/// исключение сети остаётся вызывающему.
Future<void> resetAgentPrompt({
  required AiApi api,
  required SyncStore store,
  required String seedKey,
}) async {
  final changes = await api.resetAgent(seedKey);
  for (final change in changes) {
    await store.applyChange(change);
  }
}
