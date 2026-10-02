import 'dart:async';
import 'dart:convert';

import 'package:my_tasker/core/local_llm/create_task_parser.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';
import 'package:my_tasker/core/local_llm/local_prompts.dart';
import 'package:my_tasker/core/local_llm/model_catalog.dart';
import 'package:my_tasker/core/local_llm/token_budget.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/history_builder.dart';
import 'package:timezone/timezone.dart' as tz;

/// События локального ответа (для интерфейса чата).
sealed class LocalChatEvent {
  const LocalChatEvent();
}

/// Модель ещё не в памяти и загружается (первый ответ после запуска или
/// выгрузки занимает заметное время): интерфейс показывает «Загружаю модель».
final class LocalChatLoadingModel extends LocalChatEvent {
  const LocalChatLoadingModel();
}

/// Ответ начат: модель загружена, запрос собран.
final class LocalChatStarted extends LocalChatEvent {
  const LocalChatStarted({
    required this.messageId,
    required this.estimatedInputTokens,
    required this.droppedHistoryTurns,
    required this.contextTrimmed,
  });

  /// Идентификатор будущего сообщения ассистента (строка появится в БД в
  /// конце ответа).
  final String messageId;
  final int estimatedInputTokens;
  final int droppedHistoryTurns;
  final bool contextTrimmed;
}

/// Очередной фрагмент ответа.
final class LocalChatDelta extends LocalChatEvent {
  const LocalChatDelta({
    required this.delta,
    required this.visibleText,
    required this.draftingTool,
  });

  /// Фрагмент, пришедший от модели.
  final String delta;

  /// Накопленный текст для показа: без сырого JSON вызова инструмента.
  final String visibleText;

  /// Модель начала писать JSON задачи: показываем «Формирую задачу…».
  final bool draftingTool;
}

/// Первый ответ не разобран, идёт единственный повтор с подсказкой.
final class LocalChatRetrying extends LocalChatEvent {
  const LocalChatRetrying(this.problems);

  final List<String> problems;
}

/// Итог ответа: сообщение (и предложение) записаны.
final class LocalChatFinished extends LocalChatEvent {
  const LocalChatFinished({
    required this.status,
    required this.text,
    this.messageId,
    this.proposalId,
    this.finishReason,
    this.errorCode,
    this.errorMessage,
  });

  /// `null`, если сообщение не записывалось (занят движок).
  final String? messageId;
  final MessageStatus status;
  final String text;

  /// Карточка задачи: идентификатор предложения.
  final String? proposalId;
  final String? finishReason;
  final String? errorCode;
  final String? errorMessage;

  bool get hasProposal => proposalId != null;
}

/// Код ошибки локального ответа в `ai_messages.error_code` (≤ 64 знаков).
String localErrorCode(LocalLlmErrorKind kind) => 'local_${kind.name}';

/// Текст ошибки по `error_code` локального ответа; `null` для чужих кодов.
String? localErrorText(String? code) => switch (code) {
  'local_unsupportedPlatform' => 'Офлайн-модель недоступна на этой платформе',
  'local_notLoaded' => 'Модель не загружена',
  'local_outOfMemory' => 'Не хватило памяти. Закройте другие приложения',
  'local_loadFailed' => 'Не удалось загрузить модель',
  'local_generationFailed' => 'Ошибка генерации ответа',
  'local_notImplemented' => 'Движок ещё не подключён',
  'local_busy' => 'Модель занята другим ответом',
  _ => null,
};

/// Реплики OpenAI-истории -> реплики локальной модели.
///
/// У Gemma нет роли `tool`: вызов инструмента остаётся в ответе модели тем
/// же JSON, каким она его писала, а его результат (решение пользователя по
/// карточке) приходит репликой пользователя. Подряд идущие реплики одной
/// роли склеиваются.
List<LlmTurn> historyToTurns(List<OpenAiMessage> history) {
  final turns = <LlmTurn>[];
  void add(LlmRole role, String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    if (turns.isNotEmpty && turns.last.role == role) {
      turns[turns.length - 1] = LlmTurn(role, '${turns.last.text}\n\n$clean');
    } else {
      turns.add(LlmTurn(role, clean));
    }
  }

  for (final m in history) {
    switch (m['role']) {
      case 'user':
        add(LlmRole.user, '${m['content'] ?? ''}');
      case 'assistant':
        final calls = m['tool_calls'];
        final buffer = StringBuffer('${m['content'] ?? ''}');
        if (calls is List) {
          for (final c in calls) {
            if (c is! Map) continue;
            final fn = c['function'];
            if (fn is! Map) continue;
            Object? args;
            try {
              args = jsonDecode('${fn['arguments']}');
            } on FormatException {
              args = <String, Object?>{};
            }
            buffer
              ..write('\n')
              ..write(jsonEncode({'tool': '${fn['name']}', 'arguments': args}));
          }
        }
        add(LlmRole.model, buffer.toString());
      case 'tool':
        add(LlmRole.user, 'Результат инструмента: ${m['content'] ?? ''}');
    }
  }
  return turns;
}

/// Сервис локального чата (решение этапа 10, пп. 4–8): собирает запрос
/// (системная часть, контекст приложения, история, вопрос) в бюджет
/// токенов, получает ответ от `LocalLlmEngine` потоком, при просьбе создать
/// задачу строго разбирает JSON (один повтор) и пишет **через движок
/// синхронизации** сообщение ассистента и предложение `create_task` с
/// `entity_id` = новый UUIDv7. Одобрение и создание задачи — прежний
/// `ProposalService` этапа 3: ровно одна задача на одобрение.
///
/// Стоимость локальных сообщений — 0 (`cost_kopecks = 0`), лимит polza.ai
/// не затрагивается.
class LocalChatService {
  LocalChatService({
    required this.engine,
    required this._store,
    required AiRepository repository,
    required this.ensureModelLoaded,
    required this.contextText,
    required this.zone,
    required this._now,
    String Function()? newId,
    this.modelSpec = gemma4E2b,
    this.onBusyChanged,
  }) : _repo = repository,
       _newId = newId ?? repository.newId;

  final LocalLlmEngine engine;
  final SyncStore _store;
  final AiRepository _repo;
  final DateTime Function() _now;
  final String Function() _newId;

  /// Загружает модель в движок, если она ещё не загружена (проверка ОЗУ,
  /// файла). Бросает [LocalLlmException].
  final Future<void> Function(String modelId) ensureModelLoaded;

  /// Данные приложения для чата (чувствительные разрешены: всё локально).
  final Future<String> Function(Conversation conversation) contextText;
  final tz.Location Function() zone;
  final LocalModelSpec modelSpec;

  /// Вызывается при начале (`true`) и конце (`false`) ответа: по нему
  /// запускается таймер выгрузки модели (`IdleUnloader`).
  final void Function({required bool busy})? onBusyChanged;

  bool _active = false;
  bool _cancelRequested = false;

  bool get isGenerating => _active;

  /// Переключает режим беседы (`ai_conversations.mode`) одной правкой.
  ///
  /// `local`: модель беседы становится локальной ([model] или модель
  /// сервиса). `cloud`: если у беседы локальная модель (`local/...`), её
  /// нельзя отправить в облако — модель сбрасывается в [model] (по
  /// умолчанию `null`: облачный чат сам подставит модель из избранного).
  Future<void> switchMode(
    String conversationId,
    ChatMode mode, {
    String? model,
  }) => _store.transaction(() async {
    final conversation = await _repo.getConversation(conversationId);
    if (conversation == null) return;
    final fields = <String, Object?>{};
    if (conversation.mode != mode) fields['mode'] = mode.name;
    if (mode == ChatMode.local) {
      final wanted = model ?? modelSpec.wireModelId;
      if (conversation.model != wanted) fields['model'] = wanted;
    } else if (model != null ||
        (conversation.model ?? '').startsWith('local/')) {
      if (conversation.model != model) fields['model'] = model;
    }
    if (fields.isEmpty) return;
    await _store.update(
      AiRepository.conversationsTable,
      conversationId,
      fields,
    );
  });

  /// Останавливает идущий ответ; частичный текст сохранится со статусом
  /// `cancelled`.
  Future<void> cancel() async {
    if (!_active) return;
    _cancelRequested = true;
    await engine.cancel();
  }

  /// Отвечает на сообщение пользователя [userMessageId] (оно уже записано,
  /// например `AiRepository.addUserMessage`). Поток завершается событием
  /// [LocalChatFinished].
  Stream<LocalChatEvent> reply({
    required String conversationId,
    required String userMessageId,
    AgentProfile? agent,
    bool allowCreateTask = true,
    TokenBudget? budget,
    LlmGenerationParams params = const LlmGenerationParams(),
  }) async* {
    if (_active) {
      yield const LocalChatFinished(
        status: MessageStatus.error,
        text: '',
        errorCode: 'local_busy',
        errorMessage: 'Модель занята другим ответом',
      );
      return;
    }
    _active = true;
    onBusyChanged?.call(busy: true);
    _cancelRequested = false;
    final started = _now();
    final messageId = _newId();
    var persisted = false;
    var settled = false;
    var visible = '';
    var promptTokens = 0;
    var completionTokens = 0;
    try {
      final conversation = await _repo.getConversation(conversationId);
      final userMessage = await _repo.getMessage(userMessageId);
      if (conversation == null || userMessage == null) {
        throw const LocalLlmException(
          LocalLlmErrorKind.generationFailed,
          'Беседа или сообщение не найдены',
        );
      }
      if (!engine.isLoaded) yield const LocalChatLoadingModel();
      await ensureModelLoaded(modelSpec.id);

      final effective =
          budget ??
          TokenBudget(
            contextTokens: engine.loadedModel?.contextTokens ?? 4096,
            reserveOutputTokens: params.maxOutputTokens,
          );
      final messages = [
        for (final m in await _repo.messagesOf(conversationId))
          if (m.id.compareTo(userMessageId) < 0) m,
      ];
      final proposals = await _repo.proposalsOf(conversationId);
      final history = historyToTurns(buildHistory(messages, proposals));
      final system = buildLocalSystemPrompt(
        nowUtc: _now().toUtc(),
        zone: zone(),
        agentPrompt: agent?.systemPrompt,
        allowCreateTask: allowCreateTask,
      );
      final prompt = effective.fit(
        system: system,
        history: history,
        userMessage: userMessage.text,
        contextText: await contextText(conversation),
      );
      promptTokens = prompt.estimatedInputTokens;
      yield LocalChatStarted(
        messageId: messageId,
        estimatedInputTokens: promptTokens,
        droppedHistoryTurns: prompt.droppedHistoryTurns,
        contextTrimmed: prompt.contextTrimmed,
      );

      // ---- генерация (+ один повтор при невалидном JSON) ---------------------
      var turns = prompt.turns;
      var raw = '';
      ToolParseResult parsed = const NoToolCall('');
      for (var attempt = 0; attempt < 2; attempt++) {
        raw = '';
        final buffer = StringBuffer();
        await for (final token in engine.generate(turns, params)) {
          buffer.write(token);
          raw = buffer.toString();
          visible = visibleTextWhileStreaming(raw);
          yield LocalChatDelta(
            delta: token,
            visibleText: visible,
            draftingTool: allowCreateTask && looksLikeToolDraft(raw),
          );
        }
        final stats = engine.lastStats;
        completionTokens += stats?.outputTokens ?? estimateLocalTokens(raw);
        if (_cancelRequested) break;
        parsed = allowCreateTask ? parseCreateTaskReply(raw) : NoToolCall(raw);
        if (parsed is! InvalidToolCall || attempt == 1) break;
        yield LocalChatRetrying(parsed.problems);
        visible = '';
        final clipped = raw.length > 800 ? raw.substring(0, 800) : raw;
        turns = [
          ...prompt.turns,
          LlmTurn.model(clipped),
          LlmTurn.user(createTaskRetryHint(parsed.problems)),
        ];
        promptTokens += estimateLocalTokens(clipped);
      }

      // ---- запись результата --------------------------------------------------
      final latency = _now().difference(started).inMilliseconds;
      if (_cancelRequested) {
        final text = visibleTextWhileStreaming(raw);
        await _writeAnswer(
          conversationId: conversationId,
          messageId: messageId,
          agent: agent,
          text: text,
          status: MessageStatus.cancelled,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          latencyMs: latency,
        );
        persisted = true;
        yield LocalChatFinished(
          messageId: messageId,
          status: MessageStatus.cancelled,
          text: text,
        );
        return;
      }
      switch (parsed) {
        case ParsedToolCall(:final arguments, :final text):
          final lead = text.isEmpty
              ? proposalLeadText('${arguments['title']}')
              : text;
          final proposalId = await _writeAnswer(
            conversationId: conversationId,
            messageId: messageId,
            agent: agent,
            text: lead,
            status: MessageStatus.done,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            latencyMs: latency,
            finishReason: 'awaiting_approval',
            proposalArguments: arguments,
          );
          persisted = true;
          yield LocalChatFinished(
            messageId: messageId,
            status: MessageStatus.done,
            text: lead,
            proposalId: proposalId,
            finishReason: 'awaiting_approval',
          );
        case InvalidToolCall(:final text):
          final shown = text.isEmpty ? createTaskFailedText : text;
          await _writeAnswer(
            conversationId: conversationId,
            messageId: messageId,
            agent: agent,
            text: shown,
            status: MessageStatus.done,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            latencyMs: latency,
            finishReason: 'stop',
          );
          persisted = true;
          yield LocalChatFinished(
            messageId: messageId,
            status: MessageStatus.done,
            text: shown,
            finishReason: 'stop',
          );
        case NoToolCall(:final text):
          final shown = text.trim();
          await _writeAnswer(
            conversationId: conversationId,
            messageId: messageId,
            agent: agent,
            text: shown,
            status: MessageStatus.done,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            latencyMs: latency,
            finishReason: 'stop',
          );
          persisted = true;
          yield LocalChatFinished(
            messageId: messageId,
            status: MessageStatus.done,
            text: shown,
            finishReason: 'stop',
          );
      }
    } on Object catch (e) {
      // Сбой движка или подготовки: ответ записывается как ошибка (как в
      // облаке), частичный текст сохраняется.
      settled = true;
      final exception = e is LocalLlmException
          ? e
          : LocalLlmException(LocalLlmErrorKind.generationFailed, '$e');
      final code = localErrorCode(exception.kind);
      String? written;
      if (!persisted) {
        try {
          await _writeAnswer(
            conversationId: conversationId,
            messageId: messageId,
            agent: agent,
            text: visible,
            status: MessageStatus.error,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            latencyMs: _now().difference(started).inMilliseconds,
            errorCode: code,
          );
          persisted = true;
          written = messageId;
        } on Object {
          // Не удалось записать — сообщаем только событием.
        }
      }
      yield LocalChatFinished(
        messageId: written,
        status: MessageStatus.error,
        text: visible,
        errorCode: code,
        errorMessage: exception.message,
      );
    } finally {
      if (!persisted && !settled) {
        // Подписчик отключился на середине ответа: останавливаем модель и
        // сохраняем частичный текст как отменённый.
        unawaited(engine.cancel());
        try {
          await _writeAnswer(
            conversationId: conversationId,
            messageId: messageId,
            agent: agent,
            text: visible,
            status: MessageStatus.cancelled,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            latencyMs: _now().difference(started).inMilliseconds,
          );
        } on Object {
          // Беседу могли удалить — записывать нечего.
        }
      }
      _active = false;
      _cancelRequested = false;
      onBusyChanged?.call(busy: false);
    }
  }

  /// Пишет сообщение ассистента (и предложение) одной транзакцией:
  /// родитель вперёд. Возвращает идентификатор предложения.
  Future<String?> _writeAnswer({
    required String conversationId,
    required String messageId,
    required AgentProfile? agent,
    required String text,
    required MessageStatus status,
    required int promptTokens,
    required int completionTokens,
    required int latencyMs,
    String? finishReason,
    String? errorCode,
    Map<String, Object?>? proposalArguments,
  }) => _store.transaction(() async {
    String? proposalId;
    final parts = <Map<String, Object?>>[
      if (text.isNotEmpty) {'type': 'text', 'text': text},
    ];
    if (proposalArguments != null) {
      proposalId = _newId();
      final callId = 'call_${messageId.replaceAll('-', '').substring(20, 28)}';
      parts
        ..add({
          'type': 'tool_call',
          'id': callId,
          'name': createTaskTool,
          'arguments': proposalArguments,
        })
        ..add({
          'type': 'proposal',
          'proposal_id': proposalId,
          'tool_call_id': callId,
          'tool': createTaskTool,
        });
    }
    await _store.create(AiRepository.messagesTable, messageId, {
      'conversation_id': conversationId,
      'role': 'assistant',
      'text': text,
      'parts': parts,
      'status': status.name,
      'model': modelSpec.wireModelId,
      'agent_id': agent?.id,
      'prompt_version': agent?.promptVersion,
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'cost_kopecks': 0,
      'latency_ms': latencyMs < 0 ? 0 : latencyMs,
      'finish_reason': finishReason,
      'error_code': errorCode,
    });
    if (proposalArguments != null) {
      final callId = parts[parts.length - 2]['id']! as String;
      await _store.create(AiRepository.proposalsTable, proposalId!, {
        'message_id': messageId,
        'tool_call_id': callId,
        'tool': createTaskTool,
        'entity_type': 'task',
        'entity_id': _newId(),
        'original_arguments': proposalArguments,
        'arguments': proposalArguments,
        'status': ProposalStatus.pending.wire,
        'reject_reason': null,
        'decided_at': null,
      });
    }
    return proposalId;
  });
}
