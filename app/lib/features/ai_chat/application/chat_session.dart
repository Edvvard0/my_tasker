import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/application/chat_context.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_errors.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/ai_chat/domain/history_builder.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';

/// Фаза ответа в чате.
enum StreamPhase {
  idle,

  /// Отправка чата на сервер и сборка запроса.
  preparing,

  /// Соединение открыто, идут события.
  streaming,

  /// `done`: ответ завершён (строка придёт синхронизацией).
  done,

  /// Остановлен пользователем.
  cancelled,

  /// Сбой: [ChatSessionState.failure].
  failed,
}

/// Шаг ответа (вызов инструмента) в живом сообщении.
@immutable
class LiveStep {
  const LiveStep({
    required this.id,
    required this.name,
    this.running = true,
    this.isError = false,
    this.preview = '',
  });

  final String id;
  final String name;
  final bool running;
  final bool isError;
  final String preview;

  LiveStep copyWith({bool? running, bool? isError, String? preview}) =>
      LiveStep(
        id: id,
        name: name,
        running: running ?? this.running,
        isError: isError ?? this.isError,
        preview: preview ?? this.preview,
      );
}

/// Состояние идущего (или только что завершённого) ответа чата.
@immutable
class ChatSessionState {
  const ChatSessionState({
    this.phase = StreamPhase.idle,
    this.assistantMessageId,
    this.text = '',
    this.steps = const [],
    this.proposalCount = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.costKopecks = 0,
    this.finishReason,
    this.failure,
  });

  final StreamPhase phase;

  /// Id будущего сообщения ассистента (по нему живое сообщение заменяется
  /// строкой из БД).
  final String? assistantMessageId;
  final String text;
  final List<LiveStep> steps;

  /// Сколько предложений создал сервер (карточки появятся после синхронизации).
  final int proposalCount;
  final int promptTokens;
  final int completionTokens;
  final int costKopecks;
  final String? finishReason;
  final ChatFailure? failure;

  bool get busy =>
      phase == StreamPhase.preparing || phase == StreamPhase.streaming;

  /// Есть что показать в живом сообщении.
  bool get hasLive => phase != StreamPhase.idle && assistantMessageId != null;

  ChatSessionState copyWith({
    StreamPhase? phase,
    String? assistantMessageId,
    String? text,
    List<LiveStep>? steps,
    int? proposalCount,
    int? promptTokens,
    int? completionTokens,
    int? costKopecks,
    String? finishReason,
    ChatFailure? failure,
  }) => ChatSessionState(
    phase: phase ?? this.phase,
    assistantMessageId: assistantMessageId ?? this.assistantMessageId,
    text: text ?? this.text,
    steps: steps ?? this.steps,
    proposalCount: proposalCount ?? this.proposalCount,
    promptTokens: promptTokens ?? this.promptTokens,
    completionTokens: completionTokens ?? this.completionTokens,
    costKopecks: costKopecks ?? this.costKopecks,
    finishReason: finishReason ?? this.finishReason,
    failure: failure ?? this.failure,
  );
}

/// Запуск ответа ИИ в одном чате: отправка чата на сервер, запрос с
/// потоком, отмена и разбор сбоев (spec Этапа 3, 5).
///
/// Живёт, пока живо приложение: уход с экрана чата не обрывает ответ.
class ChatSessionNotifier extends Notifier<ChatSessionState> {
  ChatSessionNotifier(this.conversationId);

  final String conversationId;

  StreamSubscription<ChatEvent>? _sub;
  Future<void>? _running;
  Completer<void>? _finished;
  bool _starting = false;
  bool _cancelRequested = false;
  bool _terminal = false;

  @override
  ChatSessionState build() {
    ref.onDispose(() => unawaited(_sub?.cancel()));
    return const ChatSessionState();
  }

  /// Отправляет сообщение пользователя и запускает ответ. Возвращает
  /// `false`, если сообщение не принято и не сохранено (нет модели,
  /// чувствительный контекст, уже идёт ответ): интерфейс оставляет текст
  /// в поле ввода. `true` — сообщение сохранено, ответ запрошен; ход ответа
  /// виден в состоянии, завершение — [whenSettled].
  Future<bool> send(
    String text, {
    required Conversation conversation,
    bool sensitiveToolsConsent = false,
  }) async {
    if (state.busy || _starting) return false;
    final clean = text.trim();
    if (clean.isEmpty) return false;
    _starting = true;
    try {
      final prepared = await _prepare(
        conversation,
        sensitiveToolsConsent: sensitiveToolsConsent,
      );
      if (prepared == null) return false;
      await _persist(prepared.conversation);
      await ref
          .read(aiRepositoryProvider)
          .addUserMessage(conversationId, clean);
      _start(prepared);
      return true;
    } finally {
      _starting = false;
    }
  }

  /// Повторяет запрос по уже сохранённой истории (после сбоя): новый
  /// `assistant_message_id`.
  Future<void> retry({
    required Conversation conversation,
    bool sensitiveToolsConsent = false,
  }) async {
    if (state.busy || _starting) return;
    _starting = true;
    try {
      final prepared = await _prepare(
        conversation,
        sensitiveToolsConsent: sensitiveToolsConsent,
      );
      if (prepared == null) return;
      await _persist(prepared.conversation);
      _start(prepared);
    } finally {
      _starting = false;
    }
  }

  /// Завершается, когда идущий ответ закончен, отменён или оборван.
  Future<void> whenSettled() => _running ?? Future<void>.value();

  void _start(_Prepared prepared) {
    // Состояние «готовлю» выставляется сразу: до первого await повторная
    // отправка уже невозможна (двойное нажатие).
    state = ChatSessionState(
      phase: StreamPhase.preparing,
      assistantMessageId: ref.read(aiRepositoryProvider).newId(),
    );
    _running = _request(prepared);
  }

  /// Останавливает ответ: закрывает соединение (сервер прервёт запрос к
  /// провайдеру и сохранит накопленное как `cancelled`), явно зовёт
  /// `cancel` и запускает синхронизацию, чтобы получить строку.
  Future<void> cancel() async {
    if (!state.busy) return;
    _cancelRequested = true;
    final id = state.assistantMessageId;
    final sub = _sub;
    _sub = null;
    state = state.copyWith(phase: StreamPhase.cancelled);
    _complete();
    // Не ждём завершения отмены подписки: у части потоков оно наступает
    // только с закрытием источника, а серверу отмена нужна сразу.
    if (sub != null) unawaited(sub.cancel());
    if (id != null) {
      try {
        await ref.read(aiApiProvider).cancel(id);
      } on Object {
        // Соединение уже закрыто: сервер отменит ответ и без вызова.
      }
    }
    await _syncQuietly();
  }

  // ---- внутреннее ----------------------------------------------------------

  /// Черновик становится строкой чата; выбранный пресет контекста
  /// записывается в чат (его проверяет и сервер).
  Future<void> _persist(Conversation conversation) async {
    final repo = ref.read(aiRepositoryProvider);
    await repo.ensureConversation(conversation);
    final saved = await repo.getConversation(conversation.id);
    if (saved != null &&
        saved.contextPresetId != conversation.contextPresetId) {
      await repo.setContextPreset(
        conversation.id,
        conversation.contextPresetId,
      );
    }
  }

  Future<_Prepared?> _prepare(
    Conversation conversation, {
    required bool sensitiveToolsConsent,
  }) async {
    final model = conversation.model;
    if (model == null || model.isEmpty) {
      _fail(ChatFailure.forCode('no_model'));
      return null;
    }
    final selection = await _selection();
    final repo = ref.read(aiRepositoryProvider);
    final preset = selection.presetId == null
        ? null
        : await repo.getPreset(selection.presetId!);
    final builder = ref.read(contextBuilderProvider);
    final sensitive =
        (preset?.sensitive ?? false) || builder.isSensitive(selection.sources);
    if (sensitive) {
      _fail(ChatFailure.forCode('sensitive_context_forbidden'));
      return null;
    }
    final package = await builder.build(
      selection.sources,
      ref.read(contextEnvProvider)(),
    );
    return _Prepared(
      conversation.copyWith(contextPresetId: selection.presetId),
      package,
      selection.presetId,
      sensitiveToolsConsent: sensitiveToolsConsent,
    );
  }

  Future<ChatContextSelection> _selection() async {
    final notifier = ref.read(chatContextProvider(conversationId).notifier);
    await notifier.ready;
    final selection = ref.read(chatContextProvider(conversationId));
    return selection;
  }

  void _fail(ChatFailure failure) {
    state = ChatSessionState(
      phase: StreamPhase.failed,
      assistantMessageId: state.assistantMessageId,
      text: state.text,
      failure: failure,
    );
  }

  void _complete() {
    final done = _finished;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> _request(_Prepared prepared) async {
    final assistantId = state.assistantMessageId!;
    _cancelRequested = false;
    _terminal = false;
    final failure = await _ensureSynced();
    if (_cancelRequested) return;
    if (failure != null) return _fail(failure);

    final CompletionRequest request;
    try {
      request = await _buildRequest(prepared, assistantId);
    } on Object {
      return _fail(ChatFailure.forCode('internal_error', retryable: true));
    }
    if (_cancelRequested) return;

    final finished = _finished = Completer<void>();
    var started = false;
    void onError(Object error) {
      if (error is ApiException && !started) {
        _fail(ChatFailure.fromApi(error));
      } else if (!_terminal) {
        _fail(ChatFailure.forCode('connection_lost'));
      }
      _terminal = true;
      _complete();
    }

    try {
      _sub = ref
          .read(aiApiProvider)
          .completions(request)
          .listen(
            (event) {
              started = true;
              _onEvent(event);
            },
            onError: onError,
            onDone: () {
              if (!_terminal && !_cancelRequested) {
                _terminal = true;
                _fail(ChatFailure.forCode('connection_lost'));
              }
              _complete();
            },
            cancelOnError: true,
          );
    } on Object catch (error) {
      onError(error);
    }
    await finished.future;
    _sub = null;
    if (_cancelRequested) return;
    await _afterStream();
  }

  /// Чат должен быть на сервере до первого запроса (spec 1.5, 5.2:
  /// иначе `404 conversation_not_found`): цикл синхронизации и проверка,
  /// что операции чата ушли.
  Future<ChatFailure?> _ensureSynced() async {
    final engine = ref.read(syncEngineProvider);
    final store = ref.read(syncStoreProvider);
    for (var attempt = 0; attempt < 2; attempt++) {
      final outcome = await engine.runCycle();
      switch (outcome) {
        case SyncOutcome.success:
          break;
        case SyncOutcome.offline:
          return ChatFailure.forCode('offline', retryable: true);
        case SyncOutcome.notConfigured:
          return ChatFailure.forCode('not_configured');
        case SyncOutcome.failed ||
            SyncOutcome.blockedOldClient ||
            SyncOutcome.rateLimited ||
            SyncOutcome.authRequired:
          return ChatFailure.forCode('sync_failed');
      }
      final unsent = (await store.outbox()).any(
        (op) =>
            op.table == AiRepository.conversationsTable &&
            op.rowId == conversationId,
      );
      if (!unsent) return null;
    }
    return ChatFailure.forCode('sync_failed');
  }

  Future<CompletionRequest> _buildRequest(
    _Prepared prepared,
    String assistantId,
  ) async {
    final repo = ref.read(aiRepositoryProvider);
    final conversation = prepared.conversation;
    final messages = await repo.messagesOf(conversationId);
    final proposals = await repo.proposalsOf(conversationId);
    final catalog = ref.read(modelCatalogProvider).value;
    final window = catalog?.byId(conversation.model)?.contextLength ?? 32000;
    final budget = ((window * 0.7).floor() - prepared.package.tokens - 1500)
        .clamp(2000, 100000);
    final history = trimHistory(
      buildHistory(messages, proposals, forCloud: true),
      budget,
    );
    final zone = ref.read(deviceTimeZoneProvider);
    return CompletionRequest(
      conversationId: conversationId,
      assistantMessageId: assistantId,
      model: conversation.model!,
      agentId: conversation.agentId,
      messages: history,
      contextText: prepared.package.text,
      presetId: prepared.presetId,
      containsSensitive: prepared.package.containsSensitive,
      sensitiveToolsConsent: prepared.sensitiveToolsConsent,
      timezone: isIanaLocation(zone) ? zone.name : 'UTC',
    );
  }

  void _onEvent(ChatEvent event) {
    switch (event) {
      case ChatStart():
        state = state.copyWith(phase: StreamPhase.streaming);
      case ChatDelta(:final text):
        state = state.copyWith(
          phase: StreamPhase.streaming,
          text: state.text + text,
        );
      case ChatToolCall(:final id, :final name):
        state = state.copyWith(
          steps: [
            ...state.steps,
            LiveStep(id: id, name: name),
          ],
        );
      case ChatToolResult():
        state = state.copyWith(
          steps: [
            for (final s in state.steps)
              if (s.id == event.toolCallId)
                s.copyWith(
                  running: false,
                  isError: event.isError,
                  preview: event.preview,
                )
              else
                s,
          ],
        );
      case ChatProposal():
        state = state.copyWith(
          proposalCount: state.proposalCount + 1,
          steps: [
            for (final s in state.steps)
              if (s.id == event.toolCallId) s.copyWith(running: false) else s,
          ],
        );
      case ChatUsage():
        state = state.copyWith(
          promptTokens: event.promptTokens,
          completionTokens: event.completionTokens,
          costKopecks: event.costKopecks,
        );
      case ChatDone():
        _terminal = true;
        state = state.copyWith(
          phase: StreamPhase.done,
          promptTokens: event.promptTokens,
          completionTokens: event.completionTokens,
          costKopecks: event.costKopecks,
          finishReason: event.finishReason,
        );
        _complete();
      case ChatError():
        _terminal = true;
        state = state.copyWith(
          phase: StreamPhase.failed,
          failure: ChatFailure.forCode(event.code, retryable: event.retryable),
        );
        _complete();
    }
  }

  /// После завершения потока: синхронизация (строка ответа и предложения
  /// приходят обычным pull). Обрыв без `done`/`error` — ищем сообщение по
  /// `assistant_message_id`; нет его — предлагаем повторить (spec 5.4).
  Future<void> _afterStream() async {
    final lost = state.failure?.code == 'connection_lost';
    await _syncQuietly();
    if (!lost) return;
    final id = state.assistantMessageId;
    if (id != null &&
        await ref.read(aiRepositoryProvider).getMessage(id) != null) {
      // Сервер сохранил частичный ответ (`cancelled`): повторять не нужно.
      state = ChatSessionState(
        phase: StreamPhase.done,
        assistantMessageId: id,
        text: state.text,
      );
    }
  }

  Future<void> _syncQuietly() async {
    try {
      await ref.read(syncEngineProvider).runCycle();
    } on Object {
      // Сбой синхронизации виден в её индикаторе.
    }
  }
}

class _Prepared {
  const _Prepared(
    this.conversation,
    this.package,
    this.presetId, {
    required this.sensitiveToolsConsent,
  });

  final Conversation conversation;
  final ContextPackage package;
  final String? presetId;
  final bool sensitiveToolsConsent;
}

// Тип семейства Riverpod 3 недоступен из публичного API.
// ignore: specify_nonobvious_property_types
final chatSessionProvider =
    NotifierProvider.family<ChatSessionNotifier, ChatSessionState, String>(
      ChatSessionNotifier.new,
    );
