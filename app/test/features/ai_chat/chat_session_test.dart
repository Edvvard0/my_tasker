import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/application/chat_context.dart';
import 'package:my_tasker/features/ai_chat/application/chat_session.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/data/proposal_service.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/ai_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';

class _FinanceSource extends ContextSource {
  const _FinanceSource();

  @override
  String get id => 'finance';

  @override
  String get label => 'Финансы';

  @override
  String get description => 'Счета';

  @override
  bool get sensitive => true;

  @override
  List<ContextFilterField> get filters => const [];

  @override
  Map<String, Object?> get defaultFilter => const {};

  @override
  String summary(Map<String, Object?> filter) => 'все';

  @override
  Future<List<String>> lines(
    ContextEnv env,
    Map<String, Object?> filter,
  ) async => ['- Счёт'];
}

void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late AiDevice device;
  late AiDevice serverDev;
  late AiRepository repo;
  late FakeAiApi api;
  final convId = uuid7();
  final draft = Conversation(
    id: convId,
    title: '',
    topic: AiTopic.general,
    model: 'openai/gpt-4o',
  );

  ChatSessionNotifier session() =>
      device.container.read(chatSessionProvider(convId).notifier);
  ChatSessionState state() =>
      device.container.read(chatSessionProvider(convId));

  /// Ответ «как сервер»: чат обязан быть на сервере до запроса (spec 1.5).
  Stream<ChatEvent> serverLike(
    CompletionRequest req,
    Stream<ChatEvent> Function(String assistantId) script,
  ) {
    if (!server.snapshot('ai_conversations').containsKey(req.conversationId)) {
      return Stream.error(httpError(404, 'conversation_not_found'));
    }
    return script(req.assistantMessageId);
  }

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = aiServer(clock);
    api = FakeAiApi();
    device = await AiDevice.create(
      server,
      clock: clock,
      api: api,
      overrides: [
        contextSourcesProvider.overrideWithValue(const [
          TasksContextSource(),
          EventsContextSource(),
          _FinanceSource(),
        ]),
      ],
    );
    serverDev = await AiDevice.create(server, clock: clock);
    repo = device.container.read(aiRepositoryProvider);
  });
  tearDown(() async {
    device.dispose();
    serverDev.dispose();
    await server.dispose();
  });

  /// «Сервер» сохраняет ответ ассистента (строка приходит обычным pull).
  Future<void> serverSaves(
    String assistantId, {
    String text = 'Готово',
    List<Map<String, Object?>> parts = const [],
    String status = 'done',
    String? finishReason = 'stop',
  }) async {
    await serverDev.sync(); // забрать чат и сообщения
    await serverDev.container.read(syncStoreProvider).create(
      'ai_messages',
      assistantId,
      {
        'conversation_id': convId,
        'role': 'assistant',
        'text': text,
        'parts': parts.isEmpty
            ? [
                {'type': 'text', 'text': text},
              ]
            : parts,
        'status': status,
        'model': 'openai/gpt-4o',
        'prompt_tokens': 100,
        'completion_tokens': 20,
        'cost_kopecks': 12,
        'finish_reason': finishReason,
      },
    );
    await serverDev.sync();
  }

  group('успешный ответ', () {
    test('чат уходит на сервер раньше запроса, дельты складываются, строка приходит pull', () async {
      api.onCompletion = (req) => serverLike(req, (id) async* {
        yield ChatStart(messageId: id, model: req.model);
        yield const ChatDelta('Привет, ');
        yield const ChatDelta('мир');
        yield const ChatUsage(
          promptTokens: 100,
          completionTokens: 20,
          costKopecks: 12,
        );
        await serverSaves(id, text: 'Привет, мир');
        yield ChatDone(
          messageId: id,
          finishReason: 'stop',
          promptTokens: 100,
          completionTokens: 20,
          costKopecks: 12,
        );
      });

      final accepted = await session().send('Привет', conversation: draft);
      expect(accepted, isTrue);
      expect(state().busy, isTrue);
      await session().whenSettled();

      final s = state();
      expect(s.phase, StreamPhase.done);
      expect(s.text, 'Привет, мир');
      expect(s.costKopecks, 12);
      expect(s.promptTokens, 100);
      expect(s.failure, isNull);

      final request = api.requests.single;
      expect(request.conversationId, convId);
      expect(isUuid7(request.assistantMessageId), isTrue);
      expect(request.model, 'openai/gpt-4o');
      expect(request.timezone, 'Europe/Moscow');
      expect(request.messages, [
        {'role': 'user', 'content': 'Привет'},
      ]);
      expect(request.contextText, isEmpty);
      expect(request.containsSensitive, isFalse);
      expect(request.presetId, isNull);

      // Сообщение пользователя и чат на сервере; ответ пришёл pull-ом.
      expect(server.snapshot('ai_conversations'), contains(convId));
      final messages = await repo.messagesOf(convId);
      expect(messages.map((m) => (m.role, m.text)), [
        (MessageRole.user, 'Привет'),
        (MessageRole.assistant, 'Привет, мир'),
      ]);
      expect(messages.last.id, s.assistantMessageId, reason: 'дубля нет');
      expect((await repo.getConversation(convId))!.title, 'Привет');
    });

    test('шаги инструментов и предложения отражаются в состоянии', () async {
      final gate = StreamController<ChatEvent>();
      api.onCompletion = (req) => serverLike(req, (id) => gate.stream);
      await session().send('Что у меня на неделе?', conversation: draft);
      // Дождаться, пока запрос уйдёт.
      while (api.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      gate
        ..add(const ChatStart(messageId: 'm'))
        ..add(
          const ChatToolCall(
            id: 'c1',
            name: 'get_tasks',
            arguments: {
              'status': ['todo'],
            },
          ),
        );
      await Future<void>.delayed(Duration.zero);
      expect(state().steps.single.running, isTrue);
      gate
        ..add(
          const ChatToolResult(
            toolCallId: 'c1',
            name: 'get_tasks',
            isError: false,
            preview: '{"count":3}',
          ),
        )
        ..add(const ChatToolCall(id: 'c2', name: 'create_task'))
        ..add(
          const ChatProposal(
            proposalId: 'p',
            toolCallId: 'c2',
            tool: 'create_task',
            entityType: 'task',
            entityId: 'e',
            arguments: {'title': 'x'},
          ),
        );
      await Future<void>.delayed(Duration.zero);
      final s = state();
      expect(s.steps.map((e) => (e.name, e.running)), [
        ('get_tasks', false),
        ('create_task', false),
      ]);
      expect(s.steps.first.preview, '{"count":3}');
      expect(s.proposalCount, 1);
      expect(s.phase, StreamPhase.streaming);
      await gate.close();
      await session().whenSettled();
      // Поток закрылся без done: обрыв.
      expect(state().failure!.code, 'connection_lost');
    });

    test('двойное нажатие «отправить»: одно сообщение и один запрос', () async {
      final gate = StreamController<ChatEvent>();
      api.onCompletion = (req) => serverLike(req, (id) => gate.stream);
      final results = await Future.wait([
        session().send('Привет', conversation: draft),
        session().send('Привет', conversation: draft),
      ]);
      expect(results.where((r) => r), hasLength(1));
      expect(await repo.messagesOf(convId), hasLength(1));
      // Пока ответ идёт, новая отправка отклоняется.
      expect(await session().send('Ещё', conversation: draft), isFalse);
      await gate.close();
      await session().whenSettled();
      expect(api.requests, hasLength(1));
    });
  });

  group('сбои', () {
    test(
      'нет сети: сообщение сохранено, запроса нет, повтор после сети',
      () async {
        device.faults.offline = true;
        api.onCompletion = (req) =>
            serverLike(req, (id) => eventsStream(okAnswer(id, ['Ок'])));
        final accepted = await session().send('Привет', conversation: draft);
        expect(accepted, isTrue);
        await session().whenSettled();
        expect(state().phase, StreamPhase.failed);
        expect(state().failure!.code, 'offline');
        expect(state().failure!.retryable, isTrue);
        expect(
          api.requests,
          isEmpty,
          reason: 'без чата на сервере запрос не идёт',
        );
        expect(await repo.messagesOf(convId), hasLength(1));

        device.faults.offline = false;
        await session().retry(conversation: draft);
        await session().whenSettled();
        expect(state().phase, StreamPhase.done);
        expect(api.requests.single.messages, [
          {'role': 'user', 'content': 'Привет'},
        ]);
        expect(
          await repo.messagesOf(convId),
          hasLength(1),
          reason: 'повтор не дублирует сообщение',
        );
        expect(server.snapshot('ai_conversations'), contains(convId));
      },
    );

    test('limit_exceeded до начала потока: суммы в сообщении, не критичный повтор не предлагается', () async {
      api.onCompletion = (req) => Stream.error(
        httpError(
          402,
          'limit_exceeded',
          details: {
            'limit_kopecks': 50000,
            'spent_kopecks': 50100,
            'month': '2026-10',
          },
        ),
      );
      await session().send('Привет', conversation: draft);
      await session().whenSettled();
      final f = state().failure!;
      expect(f.code, 'limit_exceeded');
      expect(f.critical, isTrue);
      expect(f.retryable, isFalse);
      expect(f.message, contains('501 ₽'));
      expect(state().text, isEmpty);
    });

    test('model_not_found и sensitive_context_forbidden с сервера', () async {
      api.onCompletion = (req) =>
          Stream.error(httpError(404, 'model_not_found'));
      await session().send('Привет', conversation: draft);
      await session().whenSettled();
      expect(state().failure!.code, 'model_not_found');
      expect(state().failure!.message, contains('модель'));

      api.onCompletion = (req) =>
          Stream.error(httpError(403, 'sensitive_context_forbidden'));
      await session().retry(conversation: draft);
      await session().whenSettled();
      expect(state().failure!.code, 'sensitive_context_forbidden');
    });

    test('conversation_not_found: понятное сообщение и повтор', () async {
      api.onCompletion = (req) =>
          Stream.error(httpError(404, 'conversation_not_found'));
      await session().send('Привет', conversation: draft);
      await session().whenSettled();
      expect(state().failure!.code, 'conversation_not_found');
      expect(state().failure!.retryable, isTrue);
    });

    test('ошибка потока upstream_error: частичный текст сохраняется', () async {
      api.onCompletion = (req) => serverLike(
        req,
        (id) => eventsStream([
          ChatStart(messageId: id),
          const ChatDelta('Частичный '),
          const ChatDelta('ответ'),
          ChatError(
            code: 'upstream_error',
            message: 'boom',
            retryable: true,
            messageId: id,
          ),
        ]),
      );
      await session().send('Привет', conversation: draft);
      await session().whenSettled();
      expect(state().phase, StreamPhase.failed);
      expect(state().text, 'Частичный ответ');
      expect(state().failure!.code, 'upstream_error');
      expect(state().failure!.retryable, isTrue);
      expect(state().failure!.message, isNot(contains('boom')));
    });

    test(
      'upstream_timeout и limit_exceeded посреди цикла приходят событием',
      () async {
        for (final (code, retryable) in [
          ('upstream_timeout', true),
          ('limit_exceeded', false),
        ]) {
          api.onCompletion = (req) => serverLike(
            req,
            (id) => eventsStream([
              ChatStart(messageId: id),
              ChatError(
                code: code,
                message: '',
                retryable: retryable,
                messageId: id,
              ),
            ]),
          );
          await session().retry(conversation: draft);
          await session().whenSettled();
          expect(state().failure!.code, code);
          expect(state().failure!.retryable, retryable);
        }
      },
    );

    test(
      'обрыв без done: строки нет — предложение повторить с новым id',
      () async {
        api.onCompletion = (req) => serverLike(
          req,
          (id) => eventsStream([
            ChatStart(messageId: id),
            const ChatDelta('Начало'),
          ]),
        );
        await session().send('Привет', conversation: draft);
        await session().whenSettled();
        final first = state();
        expect(first.failure!.code, 'connection_lost');
        expect(first.text, 'Начало');
        expect(first.failure!.retryable, isTrue);

        api.onCompletion = (req) =>
            serverLike(req, (id) => eventsStream(okAnswer(id, ['Целиком'])));
        await session().retry(conversation: draft);
        await session().whenSettled();
        expect(api.requests, hasLength(2));
        expect(
          api.requests.last.assistantMessageId,
          isNot(api.requests.first.assistantMessageId),
        );
        expect(state().phase, StreamPhase.done);
      },
    );

    test(
      'обрыв, но сервер сохранил частичный ответ: повторять не нужно',
      () async {
        api.onCompletion = (req) => serverLike(req, (id) async* {
          yield ChatStart(messageId: id);
          yield const ChatDelta('Начало');
          await serverSaves(id, text: 'Начало', status: 'cancelled');
        });
        await session().send('Привет', conversation: draft);
        await session().whenSettled();
        expect(state().failure, isNull);
        expect(state().phase, StreamPhase.done);
        final saved = (await repo.messagesOf(convId)).last;
        expect(saved.status, MessageStatus.cancelled);
        expect(saved.id, state().assistantMessageId);
      },
    );

    test('сбой запроса, брошенный синхронно, тоже становится сбоем', () async {
      api.onCompletion = (req) => throw httpError(503, 'ai_not_configured');
      await session().send('Привет', conversation: draft);
      await session().whenSettled();
      expect(state().phase, StreamPhase.failed);
    });
  });

  group('защита и условия отправки', () {
    test('нет модели: сообщение не сохраняется, запроса нет', () async {
      final accepted = await session().send(
        'Привет',
        conversation: draft.copyWith(model: null),
      );
      expect(accepted, isFalse);
      expect(state().failure!.code, 'no_model');
      expect(await repo.messagesOf(convId), isEmpty);
      expect(api.requests, isEmpty);
    });

    test('пресет «не отправлять в облако»: запрос не уходит', () async {
      final presetId = await repo.createPreset('Личное', const [
        ContextSourceRef(source: 'tasks'),
      ], sensitive: true);
      final preset = (await repo.getPreset(presetId))!;
      device.container
          .read(chatContextProvider(convId).notifier)
          .applyPreset(preset);
      final accepted = await session().send('Привет', conversation: draft);
      expect(accepted, isFalse);
      expect(state().failure!.code, 'sensitive_context_forbidden');
      expect(state().failure!.critical, isTrue);
      expect(api.requests, isEmpty);
      expect(await repo.messagesOf(convId), isEmpty);
      expect(server.snapshot('ai_conversations'), isEmpty);
    });

    test('чувствительный источник в выборе блокирует облачный чат', () async {
      final notifier = device.container.read(
        chatContextProvider(convId).notifier,
      )..toggle('finance', const ContextSourceRef(source: 'finance'));
      expect(await session().send('Привет', conversation: draft), isFalse);
      expect(state().failure!.code, 'sensitive_context_forbidden');
      expect(api.requests, isEmpty);
      // Убрали источник — отправка проходит.
      notifier.toggle('finance', const ContextSourceRef(source: 'finance'));
      api.onCompletion = (req) =>
          serverLike(req, (id) => eventsStream(okAnswer(id, ['Ок'])));
      expect(await session().send('Привет', conversation: draft), isTrue);
      await session().whenSettled();
      expect(api.requests, hasLength(1));
    });

    test(
      'контекст чата уходит текстом запроса; пресет записывается в чат',
      () async {
        final tasks = device.container.read(taskRepositoryProvider);
        await tasks.createTask(
          TaskEntity(
            id: tasks.newTaskId(),
            title: 'Оплатить домен',
            status: TaskStatus.todo,
            due: TaskDue.date(DateTime.utc(2026, 10, 5)),
          ),
        );
        final presetId = await repo.createPreset('Задачи', const [
          ContextSourceRef(source: 'tasks'),
        ], sensitive: false);
        final preset = (await repo.getPreset(presetId))!;
        device.container
            .read(chatContextProvider(convId).notifier)
            .applyPreset(preset);
        api.onCompletion = (req) =>
            serverLike(req, (id) => eventsStream(okAnswer(id, ['Ок'])));
        await session().send('Что срочно?', conversation: draft);
        await session().whenSettled();
        final request = api.requests.single;
        expect(request.contextText, contains('Оплатить домен'));
        expect(request.presetId, presetId);
        expect(request.containsSensitive, isFalse);
        expect((await repo.getConversation(convId))!.contextPresetId, presetId);
      },
    );
  });

  group('отмена', () {
    test('закрывает подписку, зовёт cancel, оставляет частичный текст', () async {
      final gate = StreamController<ChatEvent>();
      api.onCompletion = (req) => serverLike(req, (id) => gate.stream);
      await session().send('Расскажи длинно', conversation: draft);
      while (api.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      gate
        ..add(const ChatStart(messageId: 'm'))
        ..add(const ChatDelta('Начало длинного '));
      await Future<void>.delayed(Duration.zero);
      expect(gate.hasListener, isTrue);
      expect(state().busy, isTrue);

      final assistantId = state().assistantMessageId!;
      await session().cancel();

      expect(gate.hasListener, isFalse, reason: 'поток остановлен');
      expect(api.cancelled, [assistantId]);
      expect(state().phase, StreamPhase.cancelled);
      expect(state().text, 'Начало длинного ');
      expect(state().busy, isFalse);
      await session().whenSettled();

      // Сервер сохранил `cancelled`: строка приходит pull-ом и заменяет живое.
      await serverSaves(
        assistantId,
        text: 'Начало длинного ',
        status: 'cancelled',
      );
      await device.sync();
      final saved = (await repo.messagesOf(convId)).last;
      expect(saved.id, assistantId);
      expect(saved.status, MessageStatus.cancelled);
      expect(saved.text, 'Начало длинного ');
      await gate.close();

      // После отмены можно задать следующий вопрос.
      api.onCompletion = (req) =>
          serverLike(req, (id) => eventsStream(okAnswer(id, ['Ок'])));
      expect(await session().send('Дальше', conversation: draft), isTrue);
      await session().whenSettled();
      // Частичный ответ остаётся в истории следующего запроса.
      expect(api.requests.last.messages.map((m) => m['role']), [
        'user',
        'assistant',
        'user',
      ]);
    });

    test('сбой явного cancel не ломает отмену', () async {
      final gate = StreamController<ChatEvent>();
      api
        ..onCompletion = ((req) => serverLike(req, (id) => gate.stream))
        ..cancelError = const ApiException.network('x');
      await session().send('Привет', conversation: draft);
      while (api.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      gate.add(const ChatDelta('часть'));
      await Future<void>.delayed(Duration.zero);
      await session().cancel();
      expect(state().phase, StreamPhase.cancelled);
      await gate.close();
    });

    test('отмена без идущего ответа ничего не делает', () async {
      await session().cancel();
      expect(state().phase, StreamPhase.idle);
      expect(api.cancelled, isEmpty);
    });
  });

  group('история для следующего запроса', () {
    test(
      'результат одобренного предложения уходит модели (task created)',
      () async {
        const proposalId = '01900000-0000-7000-8000-0000000000e1';
        const entityId = '01900000-0000-7000-8000-0000000000f1';
        api.onCompletion = (req) => serverLike(req, (id) async* {
          yield ChatStart(messageId: id);
          yield const ChatDelta('Предлагаю задачу');
          await serverSaves(
            id,
            text: 'Предлагаю задачу',
            finishReason: 'awaiting_approval',
            parts: [
              {'type': 'text', 'text': 'Предлагаю задачу'},
              {
                'type': 'tool_call',
                'id': 'call_9',
                'name': 'create_task',
                'arguments': {'title': 'Оплатить домен'},
              },
              {
                'type': 'proposal',
                'proposal_id': proposalId,
                'tool_call_id': 'call_9',
                'tool': 'create_task',
              },
            ],
          );
          await serverDev.container.read(syncStoreProvider).create(
            'ai_tool_proposals',
            proposalId,
            {
              'message_id': id,
              'tool_call_id': 'call_9',
              'tool': 'create_task',
              'entity_type': 'task',
              'entity_id': entityId,
              'original_arguments': {'title': 'Оплатить домен'},
              'arguments': {'title': 'Оплатить домен'},
              'status': 'pending',
              'reject_reason': null,
              'decided_at': null,
            },
          );
          await serverDev.sync();
          yield ChatDone(
            messageId: id,
            finishReason: 'awaiting_approval',
            promptTokens: 1,
            completionTokens: 1,
            costKopecks: 1,
          );
        });
        await session().send(
          'Создай задачу: оплатить домен',
          conversation: draft,
        );
        await session().whenSettled();

        final proposals = await repo.proposalsOf(convId);
        expect(proposals[proposalId]!.status, ProposalStatus.pending);

        // Пока ждём решения: модель видит «awaiting user approval».
        api.onCompletion = (req) =>
            serverLike(req, (id) => eventsStream(okAnswer(id, ['Ок'])));
        await session().send('Подожду', conversation: draft);
        await session().whenSettled();
        String toolContent() =>
            api.requests.last.messages.firstWhere(
                  (m) => m['role'] == 'tool',
                )['content']!
                as String;
        expect(toolContent(), 'awaiting user approval');

        // После одобрения: «task created: <entity_id>».
        await device.container
            .read(proposalServiceProvider)
            .approve(proposalId);
        await session().send('Спасибо', conversation: draft);
        await session().whenSettled();
        expect(toolContent(), 'task created: $entityId');
        final assistant = api.requests.last.messages.firstWhere(
          (m) => m['role'] == 'assistant' && m['tool_calls'] != null,
        );
        final call = (assistant['tool_calls']! as List).single as Map;
        expect(call['id'], 'call_9');
        expect((call['function']! as Map)['name'], 'create_task');
      },
    );
  });
}
