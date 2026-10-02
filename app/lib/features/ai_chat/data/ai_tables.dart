import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/calendar_tables.dart';

// DSL-описания таблиц исполняются только генератором кода (drift_dev).
// coverage:ignore-start

/// Синхронизируемые таблицы Этапа 3 (spec `stage3_ai_chat.md`, раздел 1).
/// Служебные колонки — `SyncColumns`; колонка `text` называется `body` в
/// Dart (имя `text` занято методом `Table.text`).

/// Профили агентов (1.1).
@DataClassName('AiAgentProfileRow')
class AiAgentProfiles extends Table with SyncColumns {
  TextColumn get seedKey => text().nullable()();
  TextColumn get name => text()();
  TextColumn get topic => text()();
  TextColumn get systemPrompt => text()();
  IntColumn get promptVersion => integer()();
  TextColumn get defaultModel => text().nullable()();
  TextColumn get enabledTools => text()();
  TextColumn get defaultContextPresetId => text().nullable()();
  IntColumn get position => integer()();

  @override
  String get tableName => 'ai_agent_profiles';
}

/// Версии системных промтов (1.2).
@DataClassName('AiPromptVersionRow')
@TableIndex(name: 'ai_prompt_versions_profile_idx', columns: {#profileId})
class AiPromptVersions extends Table with SyncColumns {
  TextColumn get profileId => text()();
  IntColumn get version => integer()();
  TextColumn get body => text().named('text')();
  TextColumn get source => text()();

  @override
  String get tableName => 'ai_prompt_versions';
}

/// Пресеты контекста (1.3).
@DataClassName('AiContextPresetRow')
class AiContextPresets extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get sources => text()();
  BoolColumn get sensitive => boolean()();

  @override
  String get tableName => 'ai_context_presets';
}

/// Избранные модели (1.4).
@DataClassName('AiModelFavoriteRow')
class AiModelFavorites extends Table with SyncColumns {
  TextColumn get modelId => text()();
  TextColumn get displayName => text()();
  IntColumn get position => integer()();
  BoolColumn get supportsTools => boolean()();

  @override
  String get tableName => 'ai_model_favorites';
}

/// Чаты (1.5).
@DataClassName('AiConversationRow')
class AiConversations extends Table with SyncColumns {
  TextColumn get title => text()();
  TextColumn get topic => text()();
  TextColumn get agentId => text().nullable()();
  TextColumn get model => text().nullable()();
  TextColumn get contextPresetId => text().nullable()();
  BoolColumn get pinned => boolean()();
  BoolColumn get archived => boolean()();
  TextColumn get mode => text()();

  @override
  String get tableName => 'ai_conversations';
}

/// Сообщения (1.6).
@DataClassName('AiMessageRow')
@TableIndex(name: 'ai_messages_conversation_idx', columns: {#conversationId})
class AiMessages extends Table with SyncColumns {
  TextColumn get conversationId => text()();
  TextColumn get role => text()();
  TextColumn get body => text().named('text')();
  TextColumn get parts => text()();
  TextColumn get status => text()();
  TextColumn get model => text().nullable()();
  TextColumn get agentId => text().nullable()();
  IntColumn get promptVersion => integer().nullable()();
  IntColumn get promptTokens => integer().nullable()();
  IntColumn get completionTokens => integer().nullable()();
  IntColumn get costKopecks => integer().nullable()();
  IntColumn get latencyMs => integer().nullable()();
  TextColumn get finishReason => text().nullable()();
  TextColumn get errorCode => text().nullable()();

  @override
  String get tableName => 'ai_messages';
}

/// Предложения инструментов (1.7).
@DataClassName('AiToolProposalRow')
@TableIndex(name: 'ai_tool_proposals_message_idx', columns: {#messageId})
class AiToolProposals extends Table with SyncColumns {
  TextColumn get messageId => text()();
  TextColumn get toolCallId => text()();
  TextColumn get tool => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get originalArguments => text()();
  TextColumn get arguments => text()();
  TextColumn get status => text()();
  TextColumn get rejectReason => text().nullable()();
  TextColumn get decidedAt => text().nullable()();

  @override
  String get tableName => 'ai_tool_proposals';
}
// coverage:ignore-end
