import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';

/// Предел длины системного промта (spec 1.1).
const int maxPromptLength = 20000;

/// Ошибка проверки данных пользователя (текст — для показа).
class AiValidationError implements Exception {
  const AiValidationError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Идентификатор версии промта (spec 1.2).
String promptVersionId(String profileId, int version) =>
    uuid5(tableNamespace('ai_prompt_versions'), '$profileId|$version');

/// Идентификатор избранной модели (spec 1.4).
String modelFavoriteId(String modelId) =>
    uuid5(tableNamespace('ai_model_favorites'), modelId);

/// Локальные записи ИИ-чата через [SyncStore]: строка, метка HLC и операция
/// outbox — одной транзакцией (spec Этапа 1, 5.1).
class AiRepository {
  AiRepository(
    this._store, {
    String Function()? newId,
    DateTime Function()? now,
  }) : _newId = newId ?? uuid7,
       _now = now ?? DateTime.now;

  final SyncStore _store;
  final String Function() _newId;
  final DateTime Function() _now;

  static const conversationsTable = 'ai_conversations';
  static const messagesTable = 'ai_messages';
  static const proposalsTable = 'ai_tool_proposals';
  static const agentsTable = 'ai_agent_profiles';
  static const promptsTable = 'ai_prompt_versions';
  static const presetsTable = 'ai_context_presets';
  static const favoritesTable = 'ai_model_favorites';

  String newId() => _newId();

  /// Хранилище — для тестов, имитирующих запись сервера (профили агентов,
  /// ответы и предложения создаёт сервер, клиент их не создаёт).
  @visibleForTesting
  SyncStore get storeForTests => _store;

  // ---- чаты ----------------------------------------------------------------

  Future<Conversation?> getConversation(String id) async {
    final row = await _store.getRow(conversationsTable, id);
    return row == null || row['deleted_at'] != null
        ? null
        : Conversation.fromRow(row);
  }

  /// Создаёт строку чата, если её ещё нет (черновик становится чатом при
  /// первой отправке).
  Future<void> ensureConversation(Conversation draft) async {
    await _store.transaction(() async {
      if (await _store.getRow(conversationsTable, draft.id) != null) return;
      await _store.create(conversationsTable, draft.id, draft.toFields());
    });
  }

  Future<void> _updateConversation(String id, Json fields) =>
      _store.update(conversationsTable, id, fields);

  Future<void> rename(String id, String title) {
    final clean = title.trim();
    if (clean.length > 200) {
      throw const AiValidationError('Не длиннее 200 знаков');
    }
    return _updateConversation(id, {'title': clean});
  }

  Future<void> setPinned(String id, {required bool pinned}) =>
      _updateConversation(id, {'pinned': pinned});

  Future<void> setArchived(String id, {required bool archived}) =>
      _updateConversation(id, {'archived': archived});

  Future<void> setModel(String id, String? model) =>
      _updateConversation(id, {'model': model});

  Future<void> setAgent(String id, {String? agentId, AiTopic? topic}) =>
      _updateConversation(id, {'agent_id': agentId, 'topic': ?topic?.wire});

  Future<void> setContextPreset(String id, String? presetId) =>
      _updateConversation(id, {'context_preset_id': presetId});

  /// Удаляет чат в корзину (сообщения скрываются каскадом).
  Future<void> deleteConversation(String id) =>
      _store.softDelete(conversationsTable, id);

  Stream<List<Conversation>> watchConversations() => _store
      .watchVisibleRows(conversationsTable, orderBy: 't.id DESC')
      .map((rows) => [for (final r in rows) Conversation.fromRow(r)]);

  Stream<Conversation?> watchConversation(String id) => _store
      .watchRow(conversationsTable, id)
      .map(
        (row) => row == null || row['deleted_at'] != null
            ? null
            : Conversation.fromRow(row),
      );

  /// Последнее сообщение каждого чата (для превью и времени в списке).
  Stream<Map<String, ChatMessage>> watchLastMessages() => _store
      .watchVisibleRows(
        messagesTable,
        where:
            't.id = (SELECT MAX(x.id) FROM ai_messages x '
            'WHERE x.conversation_id = t.conversation_id '
            'AND x.deleted_at IS NULL)',
      )
      .map((rows) {
        final map = <String, ChatMessage>{};
        for (final r in rows) {
          final m = ChatMessage.fromRow(r);
          map[m.conversationId] = m;
        }
        return map;
      });

  // ---- сообщения -------------------------------------------------------------

  Stream<List<ChatMessage>> watchMessages(String conversationId) => _store
      .watchVisibleRows(
        messagesTable,
        where: 't.conversation_id = ?',
        args: [conversationId],
        orderBy: 't.id',
      )
      .map((rows) => [for (final r in rows) ChatMessage.fromRow(r)]);

  Future<List<ChatMessage>> messagesOf(String conversationId) async => [
    for (final r in await _store.visibleRows(
      messagesTable,
      where: 't.conversation_id = ?',
      args: [conversationId],
      orderBy: 't.id',
    ))
      ChatMessage.fromRow(r),
  ];

  Future<ChatMessage?> getMessage(String id) async {
    final row = await _store.getRow(messagesTable, id);
    return row == null || row['deleted_at'] != null
        ? null
        : ChatMessage.fromRow(row);
  }

  /// Сообщение пользователя (spec 1.6: `role = user`, `status = done`).
  /// Пустой заголовок чата заполняется первыми словами.
  Future<String> addUserMessage(String conversationId, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) throw const AiValidationError('Пустое сообщение');
    final id = _newId();
    await _store.transaction(() async {
      await _store.create(messagesTable, id, {
        'conversation_id': conversationId,
        'role': 'user',
        'text': clean,
        'parts': [
          {'type': 'text', 'text': clean},
        ],
        'status': 'done',
      });
      final conversation = await getConversation(conversationId);
      if (conversation != null && conversation.title.isEmpty) {
        await _updateConversation(conversationId, {'title': titleFrom(clean)});
      }
    });
    return id;
  }

  /// Заголовок чата из первых слов вопроса (до 40 знаков).
  static String titleFrom(String text) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= 40) return oneLine;
    final cut = oneLine.substring(0, 40);
    final space = cut.lastIndexOf(' ');
    return '${space > 15 ? cut.substring(0, space) : cut}…';
  }

  // ---- предложения -----------------------------------------------------------

  Stream<Map<String, ToolProposal>> watchProposals(String conversationId) =>
      _store
          .watchVisibleRows(
            proposalsTable,
            where:
                't.message_id IN (SELECT id FROM ai_messages '
                'WHERE conversation_id = ?)',
            args: [conversationId],
          )
          .map((rows) {
            final map = <String, ToolProposal>{};
            for (final r in rows) {
              final p = ToolProposal.fromRow(r);
              map[p.id] = p;
            }
            return map;
          });

  Future<Map<String, ToolProposal>> proposalsOf(String conversationId) async {
    final rows = await _store.visibleRows(
      proposalsTable,
      where:
          't.message_id IN (SELECT id FROM ai_messages '
          'WHERE conversation_id = ?)',
      args: [conversationId],
    );
    return {for (final r in rows) r['id']! as String: ToolProposal.fromRow(r)};
  }

  // ---- агенты и промты -------------------------------------------------------

  Stream<List<AgentProfile>> watchAgents() => _store
      .watchVisibleRows(agentsTable, orderBy: 't.position, t.id')
      .map((rows) => [for (final r in rows) AgentProfile.fromRow(r)]);

  /// Живые агенты разовым запросом (без потока).
  Future<List<AgentProfile>> agents() async => [
    for (final r in await _store.visibleRows(
      agentsTable,
      orderBy: 't.position, t.id',
    ))
      AgentProfile.fromRow(r),
  ];

  Future<AgentProfile?> getAgent(String id) async {
    final row = await _store.getRow(agentsTable, id);
    return row == null || row['deleted_at'] != null
        ? null
        : AgentProfile.fromRow(row);
  }

  Stream<List<PromptVersion>> watchPromptVersions(String profileId) => _store
      .watchVisibleRows(
        promptsTable,
        where: 't.profile_id = ?',
        args: [profileId],
        orderBy: 't.version DESC',
      )
      .map((rows) => [for (final r in rows) PromptVersion.fromRow(r)]);

  /// Правка промта (spec 1.2): одна транзакция — новая версия
  /// (`source = user`) и обновлённый профиль. Тот же текст — ничего не
  /// делает (`false`).
  Future<bool> editPrompt(String profileId, String text) =>
      _writePrompt(profileId, text, PromptSource.user);

  /// Откат к версии [version]: новая версия с текстом старой
  /// (`source = rollback`), история не переписывается.
  Future<bool> rollbackPrompt(String profileId, int version) async {
    final row = await _store.getRow(
      promptsTable,
      promptVersionId(profileId, version),
    );
    if (row == null || row['deleted_at'] != null) {
      throw const AiValidationError('Такой версии промта нет');
    }
    final changed = await _writePrompt(
      profileId,
      PromptVersion.fromRow(row).text,
      PromptSource.rollback,
    );
    return changed;
  }

  Future<bool> _writePrompt(
    String profileId,
    String text,
    PromptSource source,
  ) async {
    if (text.trim().isEmpty) {
      throw const AiValidationError('Промт не может быть пустым');
    }
    if (text.length > maxPromptLength) {
      throw const AiValidationError('Промт длиннее 20 000 знаков');
    }
    final changed = await _store.transaction(() async {
      final profile = await getAgent(profileId);
      if (profile == null) throw const AiValidationError('Агента нет');
      if (profile.systemPrompt == text) return false;
      final version = profile.promptVersion + 1;
      final id = promptVersionId(profileId, version);
      if (await _store.getRow(promptsTable, id) == null) {
        await _store.create(promptsTable, id, {
          'profile_id': profileId,
          'version': version,
          'text': text,
          'source': source.name,
        });
      }
      await _store.update(agentsTable, profileId, {
        'system_prompt': text,
        'prompt_version': version,
      });
      return true;
    });
    return changed;
  }

  Future<void> setAgentDefaultPreset(String profileId, String? presetId) =>
      _store.update(agentsTable, profileId, {
        'default_context_preset_id': presetId,
      });

  Future<void> setAgentDefaultModel(String profileId, String? model) =>
      _store.update(agentsTable, profileId, {'default_model': model});

  // ---- пресеты контекста -------------------------------------------------------

  Stream<List<ContextPreset>> watchPresets() => _store
      .watchVisibleRows(presetsTable, orderBy: 't.name, t.id')
      .map((rows) => [for (final r in rows) ContextPreset.fromRow(r)]);

  Future<ContextPreset?> getPreset(String id) async {
    final row = await _store.getRow(presetsTable, id);
    return row == null || row['deleted_at'] != null
        ? null
        : ContextPreset.fromRow(row);
  }

  Json _presetFields(
    String name,
    List<ContextSourceRef> sources, {
    required bool sensitive,
  }) {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 100) {
      throw const AiValidationError('Название пресета: от 1 до 100 знаков');
    }
    if (sources.length > 32) {
      throw const AiValidationError('Не больше 32 источников');
    }
    return {
      'name': clean,
      'sources': [for (final s in sources) s.toJson()],
      'sensitive': sensitive,
    };
  }

  Future<String> createPreset(
    String name,
    List<ContextSourceRef> sources, {
    required bool sensitive,
  }) async {
    final fields = _presetFields(name, sources, sensitive: sensitive);
    final id = _newId();
    await _store.create(presetsTable, id, fields);
    return id;
  }

  Future<void> updatePreset(
    String id,
    String name,
    List<ContextSourceRef> sources, {
    required bool sensitive,
  }) => _store.update(
    presetsTable,
    id,
    _presetFields(name, sources, sensitive: sensitive),
  );

  Future<void> deletePreset(String id) => _store.softDelete(presetsTable, id);

  // ---- избранные модели ----------------------------------------------------------

  Stream<List<ModelFavorite>> watchFavorites() => _store
      .watchVisibleRows(favoritesTable, orderBy: 't.position, t.id')
      .map((rows) => [for (final r in rows) ModelFavorite.fromRow(r)]);

  Future<List<ModelFavorite>> favorites() async => [
    for (final r in await _store.visibleRows(
      favoritesTable,
      orderBy: 't.position, t.id',
    ))
      ModelFavorite.fromRow(r),
  ];

  /// Добавляет модель в быстрый выбор (в конец списка); вернёт из корзины,
  /// если она там.
  Future<void> addFavorite(ModelInfo model) => _store.transaction(() async {
    final id = modelFavoriteId(model.id);
    final row = await _store.getRow(favoritesTable, id);
    final position = (await favorites()).length;
    if (row == null) {
      await _store.create(favoritesTable, id, {
        'model_id': model.id,
        'display_name': model.name,
        'position': position,
        'supports_tools': model.supportsTools,
      });
    } else if (row['deleted_at'] != null) {
      await _store.restore(favoritesTable, id);
      await _store.update(favoritesTable, id, {
        'display_name': model.name,
        'position': position,
        'supports_tools': model.supportsTools,
      });
    }
  });

  Future<void> removeFavorite(String modelId) =>
      _store.softDelete(favoritesTable, modelFavoriteId(modelId));

  /// Сдвигает модель в списке на [delta] позиций (-1 вверх, +1 вниз).
  Future<void> moveFavorite(String modelId, int delta) =>
      _store.transaction(() async {
        final list = await favorites();
        final from = list.indexWhere((f) => f.modelId == modelId);
        final to = from + delta;
        if (from < 0 || to < 0 || to >= list.length) return;
        final moved = list.removeAt(from);
        list.insert(to, moved);
        for (var i = 0; i < list.length; i++) {
          if (list[i].position != i) {
            await _store.update(favoritesTable, list[i].id, {'position': i});
          }
        }
      });

  /// Текущее время (для решений по предложениям).
  DateTime get now => _now().toUtc();
}

final aiRepositoryProvider = Provider<AiRepository>(
  (ref) => AiRepository(ref.watch(syncStoreProvider)),
);
