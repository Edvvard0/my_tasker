import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sse_client.dart';

/// События потока `POST /ai/chat/completions` (spec 5.3).
@immutable
sealed class ChatEvent {
  const ChatEvent();

  /// Кадр SSE -> событие. `null` для `ping` и неизвестных событий (их
  /// добавят следующие версии протокола): клиент их пропускает. Кадр с
  /// неразборчивым JSON тоже пропускается — поток от этого не ломается.
  static ChatEvent? fromFrame(SseEvent frame) {
    final Object? decoded;
    try {
      decoded = jsonDecode(frame.data);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final d = decoded.cast<String, Object?>();
    switch (frame.event) {
      case 'start':
        return ChatStart(
          messageId: '${d['message_id'] ?? ''}',
          model: d['model'] as String?,
          agentId: d['agent_id'] as String?,
          promptVersion: d['prompt_version'] as int?,
          toolsEnabled: d['tools_enabled'] != false,
        );
      case 'delta':
        return ChatDelta('${d['text'] ?? ''}');
      case 'tool_call':
        final args = d['arguments'];
        return ChatToolCall(
          id: '${d['id'] ?? ''}',
          name: '${d['name'] ?? ''}',
          arguments: args is Map ? args.cast<String, Object?>() : null,
        );
      case 'tool_result':
        return ChatToolResult(
          toolCallId: '${d['tool_call_id'] ?? ''}',
          name: '${d['name'] ?? ''}',
          isError: d['is_error'] == true,
          preview: '${d['preview'] ?? ''}',
        );
      case 'proposal':
        final args = d['arguments'];
        return ChatProposal(
          proposalId: '${d['proposal_id'] ?? ''}',
          toolCallId: '${d['tool_call_id'] ?? ''}',
          tool: '${d['tool'] ?? ''}',
          entityType: '${d['entity_type'] ?? ''}',
          entityId: '${d['entity_id'] ?? ''}',
          arguments: args is Map
              ? args.cast<String, Object?>()
              : const <String, Object?>{},
        );
      case 'usage':
        return ChatUsage(
          promptTokens: _int(d['prompt_tokens']),
          completionTokens: _int(d['completion_tokens']),
          costKopecks: _int(d['cost_kopecks']),
        );
      case 'done':
        return ChatDone(
          messageId: '${d['message_id'] ?? ''}',
          finishReason: d['finish_reason'] as String?,
          promptTokens: _int(d['prompt_tokens']),
          completionTokens: _int(d['completion_tokens']),
          costKopecks: _int(d['cost_kopecks']),
        );
      case 'error':
        return ChatError(
          code: '${d['code'] ?? 'internal_error'}',
          message: '${d['message'] ?? ''}',
          retryable: d['retryable'] == true,
          messageId: d['message_id'] as String?,
        );
    }
    return null;
  }

  static int _int(Object? v) => v is int ? v : 0;
}

class ChatStart extends ChatEvent {
  const ChatStart({
    required this.messageId,
    this.model,
    this.agentId,
    this.promptVersion,
    this.toolsEnabled = true,
  });

  final String messageId;
  final String? model;
  final String? agentId;
  final int? promptVersion;
  final bool toolsEnabled;
}

class ChatDelta extends ChatEvent {
  const ChatDelta(this.text);

  final String text;
}

class ChatToolCall extends ChatEvent {
  const ChatToolCall({required this.id, required this.name, this.arguments});

  final String id;
  final String name;
  final Map<String, Object?>? arguments;
}

class ChatToolResult extends ChatEvent {
  const ChatToolResult({
    required this.toolCallId,
    required this.name,
    required this.isError,
    required this.preview,
  });

  final String toolCallId;
  final String name;
  final bool isError;
  final String preview;
}

class ChatProposal extends ChatEvent {
  const ChatProposal({
    required this.proposalId,
    required this.toolCallId,
    required this.tool,
    required this.entityType,
    required this.entityId,
    required this.arguments,
  });

  final String proposalId;
  final String toolCallId;
  final String tool;
  final String entityType;
  final String entityId;
  final Map<String, Object?> arguments;
}

class ChatUsage extends ChatEvent {
  const ChatUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.costKopecks,
  });

  final int promptTokens;
  final int completionTokens;
  final int costKopecks;
}

class ChatDone extends ChatEvent {
  const ChatDone({
    required this.messageId,
    required this.promptTokens,
    required this.completionTokens,
    required this.costKopecks,
    this.finishReason,
  });

  final String messageId;
  final String? finishReason;
  final int promptTokens;
  final int completionTokens;
  final int costKopecks;
}

class ChatError extends ChatEvent {
  const ChatError({
    required this.code,
    required this.message,
    required this.retryable,
    this.messageId,
  });

  final String code;
  final String message;
  final bool retryable;
  final String? messageId;
}

/// Тело запроса `POST /ai/chat/completions` (spec 5.1).
@immutable
class CompletionRequest {
  const CompletionRequest({
    required this.conversationId,
    required this.assistantMessageId,
    required this.model,
    required this.messages,
    required this.contextText,
    required this.timezone,
    this.agentId,
    this.presetId,
    this.containsSensitive = false,
    this.sensitiveToolsConsent = false,
    this.tools,
    this.temperature,
    this.maxTokens,
  });

  final String conversationId;
  final String assistantMessageId;
  final String model;
  final String? agentId;
  final String contextText;
  final String? presetId;
  final bool containsSensitive;

  /// Явное согласие пользователя на финансовые инструменты агента (облако
  /// получит балансы, долги и цели). Без согласия поле в запрос не попадает
  /// и сервер исключает такие инструменты.
  final bool sensitiveToolsConsent;

  /// История в формате OpenAI без `system`.
  final List<Map<String, Object?>> messages;

  /// `null` — инструменты профиля (spec 5.1).
  final List<String>? tools;
  final String timezone;
  final double? temperature;
  final int? maxTokens;

  Json toJson() => {
    'conversation_id': conversationId,
    'assistant_message_id': assistantMessageId,
    'model': model,
    'agent_id': agentId,
    'context': {
      'text': contextText,
      'preset_id': presetId,
      'contains_sensitive': containsSensitive,
    },
    'messages': messages,
    'tools': tools,
    if (sensitiveToolsConsent) 'sensitive_tools_consent': true,
    'timezone': timezone,
    if (temperature != null || maxTokens != null)
      'params': {'temperature': ?temperature, 'max_tokens': ?maxTokens},
  };
}

/// Модель из каталога `GET /ai/models` (spec 4).
@immutable
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.name,
    required this.supportsTools,
    this.contextLength,
    this.maxCompletionTokens,
    this.priceInputKopecksPerMtok,
    this.priceOutputKopecksPerMtok,
  });

  factory ModelInfo.fromJson(Json json) => ModelInfo(
    id: json['id']! as String,
    name: (json['name'] as String?) ?? json['id']! as String,
    supportsTools: json['supports_tools'] == true,
    contextLength: json['context_length'] as int?,
    maxCompletionTokens: json['max_completion_tokens'] as int?,
    priceInputKopecksPerMtok: json['price_input_kopecks_per_mtok'] as int?,
    priceOutputKopecksPerMtok: json['price_output_kopecks_per_mtok'] as int?,
  );

  final String id;
  final String name;
  final bool supportsTools;
  final int? contextLength;
  final int? maxCompletionTokens;
  final int? priceInputKopecksPerMtok;
  final int? priceOutputKopecksPerMtok;
}

/// Каталог моделей.
@immutable
class ModelCatalog {
  const ModelCatalog({required this.models, this.stale = false});

  factory ModelCatalog.fromJson(Json json) => ModelCatalog(
    models: [
      for (final m in (json['models'] as List<Object?>?) ?? const [])
        ModelInfo.fromJson((m! as Map).cast<String, Object?>()),
    ],
    stale: json['stale'] == true,
  );

  final List<ModelInfo> models;

  /// Сервер отдал устаревший кэш (обновить не удалось).
  final bool stale;

  ModelInfo? byId(String? id) {
    if (id == null) return null;
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }
}

/// Расход по модели.
@immutable
class ModelUsage {
  const ModelUsage({
    required this.model,
    required this.requests,
    required this.promptTokens,
    required this.completionTokens,
    required this.costKopecks,
  });

  factory ModelUsage.fromJson(Json json) => ModelUsage(
    model: json['model']! as String,
    requests: json['requests']! as int,
    promptTokens: json['prompt_tokens']! as int,
    completionTokens: json['completion_tokens']! as int,
    costKopecks: json['cost_kopecks']! as int,
  );

  final String model;
  final int requests;
  final int promptTokens;
  final int completionTokens;
  final int costKopecks;
}

/// Расход и лимит за месяц (`GET /ai/usage`, spec 5.5).
@immutable
class UsageSummary {
  const UsageSummary({
    required this.month,
    required this.spentKopecks,
    required this.requests,
    required this.promptTokens,
    required this.completionTokens,
    this.limitKopecks,
    this.remainingKopecks,
    this.byModel = const [],
  });

  factory UsageSummary.fromJson(Json json) => UsageSummary(
    month: json['month']! as String,
    limitKopecks: json['limit_kopecks'] as int?,
    spentKopecks: json['spent_kopecks']! as int,
    remainingKopecks: json['remaining_kopecks'] as int?,
    requests: json['requests']! as int,
    promptTokens: json['prompt_tokens']! as int,
    completionTokens: json['completion_tokens']! as int,
    byModel: [
      for (final m in (json['by_model'] as List<Object?>?) ?? const [])
        ModelUsage.fromJson((m! as Map).cast<String, Object?>()),
    ],
  );

  /// `YYYY-MM`.
  final String month;

  /// `null` — лимита нет.
  final int? limitKopecks;
  final int spentKopecks;
  final int? remainingKopecks;
  final int requests;
  final int promptTokens;
  final int completionTokens;
  final List<ModelUsage> byModel;

  /// Доля лимита, `null` без лимита; для нулевого лимита — 1.
  double? get limitShare {
    final limit = limitKopecks;
    if (limit == null) return null;
    if (limit == 0) return 1;
    return spentKopecks / limit;
  }

  /// Расход дошёл до порога предупреждения (80 %).
  bool get nearLimit => (limitShare ?? 0) >= 0.8;

  bool get exceeded => limitKopecks != null && spentKopecks >= limitKopecks!;
}

/// Ответ `POST /ai/bootstrap`: предустановленные профили.
@immutable
class AiBootstrap {
  const AiBootstrap({required this.agentIds});

  factory AiBootstrap.fromJson(Json json) => AiBootstrap(
    agentIds: [
      for (final a in (json['agents'] as List<Object?>?) ?? const [])
        (a! as Map)['id']! as String,
    ],
  );

  final List<String> agentIds;
}
