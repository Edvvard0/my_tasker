import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';

const Object _unset = Object();

/// Время из метки HLC строки (`updated_at`) или `null`, если она неразборчива.
DateTime? _hlcTime(Object? hlc) {
  if (hlc is! String) return null;
  try {
    return DateTime.fromMillisecondsSinceEpoch(hlcMs(hlc), isUtc: true);
  } on FormatException {
    return null;
  }
}

/// Время создания по UUIDv7 (первые 48 бит — миллисекунды Unix) или `null`.
DateTime? uuid7Time(String id) {
  final hex = id.replaceAll('-', '');
  if (hex.length != 32) return null;
  final ms = int.tryParse(hex.substring(0, 12), radix: 16);
  return ms == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// Тема чата и агента (spec 1.1: `topic`).
enum AiTopic {
  general('general', 'Общий', 'Любые вопросы', LucideIcons.sparkles),
  calendarTasks(
    'calendar_tasks',
    'Календарь и задачи',
    'Планы, сроки, приоритеты',
    LucideIcons.calendarCheck,
  ),
  work('work', 'Работа', 'Проекты, оценки, переписка', LucideIcons.briefcase),
  finance('finance', 'Финансы', 'Баланс, траты, цели', LucideIcons.wallet),
  study('study', 'Учёба', 'Расписание, конспекты', LucideIcons.graduationCap),
  sleep('sleep', 'Сон', 'Режим и самочувствие', LucideIcons.moon),
  custom('custom', 'Свой', 'Пользовательский агент', LucideIcons.bot);

  const AiTopic(this.wire, this.label, this.hint, this.icon);

  final String wire;
  final String label;
  final String hint;
  final IconData icon;

  static AiTopic parse(Object? value) => AiTopic.values.firstWhere(
    (t) => t.wire == value,
    orElse: () => AiTopic.general,
  );

  /// Темы, из которых пользователь выбирает при создании чата.
  static List<AiTopic> get selectable => [
    for (final t in values)
      if (t != custom) t,
  ];
}

/// Режим чата (spec 1.5). В Этапе 3 работает только `cloud`.
enum ChatMode {
  cloud,
  local;

  static ChatMode parse(Object? value) =>
      value == 'local' ? ChatMode.local : ChatMode.cloud;
}

/// Профиль агента (`ai_agent_profiles`).
@immutable
class AgentProfile {
  const AgentProfile({
    required this.id,
    required this.name,
    required this.topic,
    required this.systemPrompt,
    required this.promptVersion,
    required this.position,
    this.seedKey,
    this.defaultModel,
    this.enabledTools = const [],
    this.defaultContextPresetId,
  });

  factory AgentProfile.fromRow(Json row) => AgentProfile(
    id: row['id']! as String,
    seedKey: row['seed_key'] as String?,
    name: row['name']! as String,
    topic: AiTopic.parse(row['topic']),
    systemPrompt: row['system_prompt']! as String,
    promptVersion: row['prompt_version']! as int,
    defaultModel: row['default_model'] as String?,
    enabledTools: [
      for (final t in (row['enabled_tools'] as List<Object?>?) ?? const [])
        '$t',
    ],
    defaultContextPresetId: row['default_context_preset_id'] as String?,
    position: row['position']! as int,
  );

  final String id;
  final String? seedKey;
  final String name;
  final AiTopic topic;
  final String systemPrompt;
  final int promptVersion;
  final String? defaultModel;
  final List<String> enabledTools;
  final String? defaultContextPresetId;
  final int position;

  /// Предустановленный профиль (его можно сбросить к исходному промту).
  bool get isSeed => seedKey != null;
}

/// Источник промта в истории (spec 1.2).
enum PromptSource {
  seed('Исходный'),
  user('Правка'),
  reset('Сброс'),
  rollback('Откат');

  const PromptSource(this.label);

  final String label;

  static PromptSource parse(Object? value) => PromptSource.values.firstWhere(
    (s) => s.name == value,
    orElse: () => PromptSource.user,
  );
}

/// Версия системного промта (`ai_prompt_versions`).
@immutable
class PromptVersion {
  const PromptVersion({
    required this.id,
    required this.profileId,
    required this.version,
    required this.text,
    required this.source,
    this.createdAt,
  });

  factory PromptVersion.fromRow(Json row) => PromptVersion(
    id: row['id']! as String,
    profileId: row['profile_id']! as String,
    version: row['version']! as int,
    text: row['text']! as String,
    source: PromptSource.parse(row['source']),
    createdAt: parseStoredInstant(row['created_at']),
  );

  final String id;
  final String profileId;
  final int version;
  final String text;
  final PromptSource source;
  final DateTime? createdAt;
}

/// Один источник контекста в пресете: `{"source", "filter", "token_limit"}`.
@immutable
class ContextSourceRef {
  const ContextSourceRef({
    required this.source,
    this.filter = const {},
    this.tokenLimit = defaultTokenLimit,
  });

  factory ContextSourceRef.fromJson(Object? json) {
    final map = json is Map ? json : const <Object?, Object?>{};
    final filter = map['filter'];
    final limit = map['token_limit'];
    return ContextSourceRef(
      source: '${map['source'] ?? ''}',
      filter: filter is Map
          ? filter.cast<String, Object?>()
          : const <String, Object?>{},
      tokenLimit: limit is int && limit > 0 ? limit : defaultTokenLimit,
    );
  }

  static const int defaultTokenLimit = 1500;

  final String source;
  final Map<String, Object?> filter;
  final int tokenLimit;

  Json toJson() => {
    'source': source,
    'filter': filter,
    'token_limit': tokenLimit,
  };

  ContextSourceRef copyWith({Map<String, Object?>? filter, int? tokenLimit}) =>
      ContextSourceRef(
        source: source,
        filter: filter ?? this.filter,
        tokenLimit: tokenLimit ?? this.tokenLimit,
      );

  @override
  bool operator ==(Object other) =>
      other is ContextSourceRef &&
      other.source == source &&
      other.tokenLimit == tokenLimit &&
      mapEquals(other.filter, filter);

  @override
  int get hashCode => Object.hash(source, tokenLimit, filter.length);
}

/// Пресет контекста (`ai_context_presets`).
@immutable
class ContextPreset {
  const ContextPreset({
    required this.id,
    required this.name,
    required this.sources,
    required this.sensitive,
  });

  factory ContextPreset.fromRow(Json row) => ContextPreset(
    id: row['id']! as String,
    name: row['name']! as String,
    sources: [
      for (final s in (row['sources'] as List<Object?>?) ?? const [])
        ContextSourceRef.fromJson(s),
    ],
    sensitive: row['sensitive']! as bool,
  );

  final String id;
  final String name;
  final List<ContextSourceRef> sources;

  /// «Не отправлять в облако» (spec 1.3).
  final bool sensitive;
}

/// Избранная модель (`ai_model_favorites`).
@immutable
class ModelFavorite {
  const ModelFavorite({
    required this.id,
    required this.modelId,
    required this.displayName,
    required this.position,
    required this.supportsTools,
  });

  factory ModelFavorite.fromRow(Json row) => ModelFavorite(
    id: row['id']! as String,
    modelId: row['model_id']! as String,
    displayName: row['display_name']! as String,
    position: row['position']! as int,
    supportsTools: row['supports_tools']! as bool,
  );

  final String id;
  final String modelId;
  final String displayName;
  final int position;
  final bool supportsTools;
}

/// Чат (`ai_conversations`).
@immutable
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.topic,
    this.agentId,
    this.model,
    this.contextPresetId,
    this.pinned = false,
    this.archived = false,
    this.mode = ChatMode.cloud,
    this.createdAt,
    this.updatedAt,
  });

  factory Conversation.fromRow(Json row) => Conversation(
    id: row['id']! as String,
    title: row['title']! as String,
    topic: AiTopic.parse(row['topic']),
    agentId: row['agent_id'] as String?,
    model: row['model'] as String?,
    contextPresetId: row['context_preset_id'] as String?,
    pinned: row['pinned']! as bool,
    archived: row['archived']! as bool,
    mode: ChatMode.parse(row['mode']),
    createdAt: parseStoredInstant(row['created_at']),
    updatedAt: _hlcTime(row['updated_at']),
  );

  final String id;
  final String title;
  final AiTopic topic;
  final String? agentId;
  final String? model;
  final String? contextPresetId;
  final bool pinned;
  final bool archived;
  final ChatMode mode;
  final DateTime? createdAt;

  /// Время последней правки строки (для сортировки списка).
  final DateTime? updatedAt;

  /// Прикладные колонки строки.
  Json toFields() => {
    'title': title,
    'topic': topic.wire,
    'agent_id': agentId,
    'model': model,
    'context_preset_id': contextPresetId,
    'pinned': pinned,
    'archived': archived,
    'mode': mode.name,
  };

  Conversation copyWith({
    String? title,
    AiTopic? topic,
    Object? agentId = _unset,
    Object? model = _unset,
    Object? contextPresetId = _unset,
    bool? pinned,
    bool? archived,
  }) => Conversation(
    id: id,
    title: title ?? this.title,
    topic: topic ?? this.topic,
    agentId: identical(agentId, _unset) ? this.agentId : agentId as String?,
    model: identical(model, _unset) ? this.model : model as String?,
    contextPresetId: identical(contextPresetId, _unset)
        ? this.contextPresetId
        : contextPresetId as String?,
    pinned: pinned ?? this.pinned,
    archived: archived ?? this.archived,
    mode: mode,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// Статус сообщения (spec 1.6).
enum MessageStatus {
  streaming,
  done,
  error,
  cancelled;

  static MessageStatus parse(Object? value) => MessageStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => MessageStatus.done,
  );
}

/// Роль сообщения (spec 1.6).
enum MessageRole {
  user,
  assistant,
  tool,
  system;

  static MessageRole parse(Object? value) => MessageRole.values.firstWhere(
    (r) => r.name == value,
    orElse: () => MessageRole.system,
  );
}

/// Часть сообщения (spec 1.6): текст, вызов, результат, предложение.
@immutable
sealed class MessagePart {
  const MessagePart();

  /// `null` для неизвестного типа (части новых версий протокола).
  static MessagePart? fromJson(Object? json) {
    if (json is! Map) return null;
    switch (json['type']) {
      case 'text':
        return TextPart('${json['text'] ?? ''}');
      case 'tool_call':
        final args = json['arguments'];
        return ToolCallPart(
          id: '${json['id'] ?? ''}',
          name: '${json['name'] ?? ''}',
          arguments: args is Map ? args.cast<String, Object?>() : null,
          rawArguments: json['raw_arguments'] as String?,
        );
      case 'tool_result':
        return ToolResultPart(
          toolCallId: '${json['tool_call_id'] ?? ''}',
          name: '${json['name'] ?? ''}',
          content: '${json['content'] ?? ''}',
          isError: json['is_error'] == true,
        );
      case 'proposal':
        return ProposalPart(
          proposalId: '${json['proposal_id'] ?? ''}',
          toolCallId: '${json['tool_call_id'] ?? ''}',
          tool: '${json['tool'] ?? ''}',
        );
    }
    return null;
  }

  static List<MessagePart> listFromJson(Object? json) => [
    if (json is List)
      for (final p in json) ?fromJson(p),
  ];

  Json toJson();
}

class TextPart extends MessagePart {
  const TextPart(this.text);

  final String text;

  @override
  Json toJson() => {'type': 'text', 'text': text};
}

class ToolCallPart extends MessagePart {
  const ToolCallPart({
    required this.id,
    required this.name,
    this.arguments,
    this.rawArguments,
  });

  final String id;
  final String name;

  /// Разобранные аргументы; `null` — невалидный JSON ([rawArguments]).
  final Map<String, Object?>? arguments;
  final String? rawArguments;

  @override
  Json toJson() => {
    'type': 'tool_call',
    'id': id,
    'name': name,
    'arguments': arguments,
    'raw_arguments': ?rawArguments,
  };
}

class ToolResultPart extends MessagePart {
  const ToolResultPart({
    required this.toolCallId,
    required this.name,
    required this.content,
    required this.isError,
  });

  final String toolCallId;
  final String name;
  final String content;
  final bool isError;

  @override
  Json toJson() => {
    'type': 'tool_result',
    'tool_call_id': toolCallId,
    'name': name,
    'content': content,
    'is_error': isError,
  };
}

class ProposalPart extends MessagePart {
  const ProposalPart({
    required this.proposalId,
    required this.toolCallId,
    required this.tool,
  });

  final String proposalId;
  final String toolCallId;
  final String tool;

  @override
  Json toJson() => {
    'type': 'proposal',
    'proposal_id': proposalId,
    'tool_call_id': toolCallId,
    'tool': tool,
  };
}

/// Сообщение чата (`ai_messages`).
@immutable
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.text,
    required this.parts,
    required this.status,
    this.model,
    this.agentId,
    this.promptVersion,
    this.promptTokens,
    this.completionTokens,
    this.costKopecks,
    this.latencyMs,
    this.finishReason,
    this.errorCode,
    this.createdAt,
  });

  factory ChatMessage.fromRow(Json row) => ChatMessage(
    id: row['id']! as String,
    conversationId: row['conversation_id']! as String,
    role: MessageRole.parse(row['role']),
    text: row['text']! as String,
    parts: MessagePart.listFromJson(row['parts']),
    status: MessageStatus.parse(row['status']),
    model: row['model'] as String?,
    agentId: row['agent_id'] as String?,
    promptVersion: row['prompt_version'] as int?,
    promptTokens: row['prompt_tokens'] as int?,
    completionTokens: row['completion_tokens'] as int?,
    costKopecks: row['cost_kopecks'] as int?,
    latencyMs: row['latency_ms'] as int?,
    finishReason: row['finish_reason'] as String?,
    errorCode: row['error_code'] as String?,
    createdAt: parseStoredInstant(row['created_at']),
  );

  final String id;
  final String conversationId;
  final MessageRole role;
  final String text;
  final List<MessagePart> parts;
  final MessageStatus status;
  final String? model;
  final String? agentId;
  final int? promptVersion;
  final int? promptTokens;
  final int? completionTokens;
  final int? costKopecks;
  final int? latencyMs;
  final String? finishReason;
  final String? errorCode;
  final DateTime? createdAt;

  bool get isUser => role == MessageRole.user;
}

/// Статус предложения (spec 1.7).
enum ProposalStatus {
  pending,
  approved,
  rejected,
  editedApproved;

  String get wire => switch (this) {
    pending => 'pending',
    approved => 'approved',
    rejected => 'rejected',
    editedApproved => 'edited_approved',
  };

  static ProposalStatus parse(Object? value) => ProposalStatus.values
      .firstWhere((s) => s.wire == value, orElse: () => ProposalStatus.pending);

  bool get isDecided => this != pending;
  bool get isApproved => this == approved || this == editedApproved;
}

/// Предложение инструмента (`ai_tool_proposals`).
@immutable
class ToolProposal {
  const ToolProposal({
    required this.id,
    required this.messageId,
    required this.toolCallId,
    required this.tool,
    required this.entityType,
    required this.entityId,
    required this.originalArguments,
    required this.arguments,
    required this.status,
    this.rejectReason,
    this.decidedAt,
  });

  factory ToolProposal.fromRow(Json row) => ToolProposal(
    id: row['id']! as String,
    messageId: row['message_id']! as String,
    toolCallId: row['tool_call_id']! as String,
    tool: row['tool']! as String,
    entityType: row['entity_type']! as String,
    entityId: row['entity_id']! as String,
    originalArguments: _map(row['original_arguments']),
    arguments: _map(row['arguments']),
    status: ProposalStatus.parse(row['status']),
    rejectReason: row['reject_reason'] as String?,
    decidedAt: parseStoredInstant(row['decided_at']),
  );

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};

  final String id;
  final String messageId;
  final String toolCallId;
  final String tool;
  final String entityType;

  /// Id, который клиент обязан дать создаваемой сущности (spec 1.7).
  final String entityId;
  final Map<String, Object?> originalArguments;
  final Map<String, Object?> arguments;
  final ProposalStatus status;
  final String? rejectReason;
  final DateTime? decidedAt;

  bool get isPending => status == ProposalStatus.pending;

  /// Пользователь поправил аргументы.
  bool get isEdited => !mapEquals(
    {for (final e in arguments.entries) e.key: '${e.value}'},
    {for (final e in originalArguments.entries) e.key: '${e.value}'},
  );
}
