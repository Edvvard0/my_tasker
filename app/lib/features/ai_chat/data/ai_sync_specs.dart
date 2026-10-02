import 'package:my_tasker/core/sync/sync_table.dart';

/// Синхронизируемые таблицы ИИ-чата (spec Этапа 3, раздел 1). Порядок
/// регистрации — родители вперёд (`backend/src/tasker/ai/tables.py`).

/// `ai_agent_profiles` — профили агентов (spec 1.1).
const SyncTableSpec aiAgentProfilesSpec = SyncTableSpec(
  name: 'ai_agent_profiles',
  label: 'Агент ИИ',
  columns: [
    SyncColumn(
      'seed_key',
      SyncColumnType.text,
      nullable: true,
      immutable: true,
    ),
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('topic', SyncColumnType.text),
    SyncColumn('system_prompt', SyncColumnType.text),
    SyncColumn('prompt_version', SyncColumnType.integer),
    SyncColumn('default_model', SyncColumnType.text, nullable: true),
    SyncColumn('enabled_tools', SyncColumnType.json),
    SyncColumn(
      'default_context_preset_id',
      SyncColumnType.uuid,
      nullable: true,
    ),
    SyncColumn('position', SyncColumnType.integer),
  ],
  titleOf: _name,
);

/// `ai_prompt_versions` — история промтов (spec 1.2).
const SyncTableSpec aiPromptVersionsSpec = SyncTableSpec(
  name: 'ai_prompt_versions',
  label: 'Версия промта',
  columns: [
    SyncColumn('profile_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('version', SyncColumnType.integer, immutable: true),
    SyncColumn('text', SyncColumnType.text),
    SyncColumn('source', SyncColumnType.text),
  ],
  parents: [SyncRelation('profile_id', 'ai_agent_profiles')],
  titleOf: _promptTitle,
);

/// `ai_context_presets` — пресеты контекста (spec 1.3).
const SyncTableSpec aiContextPresetsSpec = SyncTableSpec(
  name: 'ai_context_presets',
  label: 'Пресет контекста',
  columns: [
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('sources', SyncColumnType.json),
    SyncColumn('sensitive', SyncColumnType.boolean),
  ],
  titleOf: _name,
);

/// `ai_model_favorites` — избранные модели (spec 1.4).
const SyncTableSpec aiModelFavoritesSpec = SyncTableSpec(
  name: 'ai_model_favorites',
  label: 'Избранная модель',
  columns: [
    SyncColumn('model_id', SyncColumnType.text, immutable: true),
    SyncColumn('display_name', SyncColumnType.text),
    SyncColumn('position', SyncColumnType.integer),
    SyncColumn('supports_tools', SyncColumnType.boolean),
  ],
  titleOf: _displayName,
);

/// `ai_conversations` — чаты (spec 1.5).
const SyncTableSpec aiConversationsSpec = SyncTableSpec(
  name: 'ai_conversations',
  label: 'Чат ИИ',
  columns: [
    SyncColumn('title', SyncColumnType.text),
    SyncColumn('topic', SyncColumnType.text),
    SyncColumn('agent_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('model', SyncColumnType.text, nullable: true),
    SyncColumn('context_preset_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('pinned', SyncColumnType.boolean),
    SyncColumn('archived', SyncColumnType.boolean),
    SyncColumn('mode', SyncColumnType.text),
  ],
  titleOf: _conversationTitle,
);

/// `ai_messages` — сообщения (spec 1.6).
const SyncTableSpec aiMessagesSpec = SyncTableSpec(
  name: 'ai_messages',
  label: 'Сообщение ИИ',
  columns: [
    SyncColumn('conversation_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('role', SyncColumnType.text, immutable: true),
    SyncColumn('text', SyncColumnType.text),
    SyncColumn('parts', SyncColumnType.json),
    SyncColumn('status', SyncColumnType.text),
    SyncColumn('model', SyncColumnType.text, nullable: true),
    SyncColumn('agent_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('prompt_version', SyncColumnType.integer, nullable: true),
    SyncColumn('prompt_tokens', SyncColumnType.integer, nullable: true),
    SyncColumn('completion_tokens', SyncColumnType.integer, nullable: true),
    SyncColumn('cost_kopecks', SyncColumnType.integer, nullable: true),
    SyncColumn('latency_ms', SyncColumnType.integer, nullable: true),
    SyncColumn('finish_reason', SyncColumnType.text, nullable: true),
    SyncColumn('error_code', SyncColumnType.text, nullable: true),
  ],
  parents: [SyncRelation('conversation_id', 'ai_conversations')],
  titleOf: _messageTitle,
);

/// `ai_tool_proposals` — предложения инструментов (spec 1.7).
const SyncTableSpec aiToolProposalsSpec = SyncTableSpec(
  name: 'ai_tool_proposals',
  label: 'Предложение ИИ',
  columns: [
    SyncColumn('message_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('tool_call_id', SyncColumnType.text, immutable: true),
    SyncColumn('tool', SyncColumnType.text, immutable: true),
    SyncColumn('entity_type', SyncColumnType.text, immutable: true),
    SyncColumn('entity_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('original_arguments', SyncColumnType.json, immutable: true),
    SyncColumn('arguments', SyncColumnType.json),
    SyncColumn('status', SyncColumnType.text),
    SyncColumn('reject_reason', SyncColumnType.text, nullable: true),
    SyncColumn('decided_at', SyncColumnType.datetime, nullable: true),
  ],
  parents: [SyncRelation('message_id', 'ai_messages')],
  titleOf: _proposalTitle,
);

/// Все таблицы Этапа 3 в порядке регистрации.
const List<SyncTableSpec> aiSyncSpecs = [
  aiAgentProfilesSpec,
  aiPromptVersionsSpec,
  aiContextPresetsSpec,
  aiModelFavoritesSpec,
  aiConversationsSpec,
  aiMessagesSpec,
  aiToolProposalsSpec,
];

String _name(Map<String, Object?> row) => '${row['name']}';

String _displayName(Map<String, Object?> row) => '${row['display_name']}';

String _promptTitle(Map<String, Object?> row) =>
    'Версия промта ${row['version']}';

String _conversationTitle(Map<String, Object?> row) {
  final title = '${row['title'] ?? ''}'.trim();
  return title.isEmpty ? 'Чат без названия' : title;
}

String _messageTitle(Map<String, Object?> row) {
  final text = '${row['text'] ?? ''}'.trim();
  if (text.isEmpty) return 'Сообщение';
  return text.length > 60 ? '${text.substring(0, 60)}…' : text;
}

String _proposalTitle(Map<String, Object?> row) {
  final args = row['arguments'];
  if (args is Map && args['title'] is String) return '${args['title']}';
  return 'Предложение ИИ';
}
