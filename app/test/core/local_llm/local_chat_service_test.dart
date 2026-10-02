import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/local_llm/local_chat_service.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';
import 'package:my_tasker/core/local_llm/local_prompts.dart';
import 'package:my_tasker/core/local_llm/model_catalog.dart';
import 'package:my_tasker/core/local_llm/token_budget.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/data/proposal_service.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/ai_env.dart';
import '../../support/fake_llm.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';

const _conv = '01900000-0000-7000-8000-0000000000c1';

const Map<String, Object?> _args = {
  'title': 'Купить молоко',
  'due_date': '2026-10-06',
  'due_time': '09:00',
  'priority': 2,
  'tags': ['дом'],
};

/// Устройство с локальным чатом поверх настоящего движка синхронизации.
class _Dev {
  _Dev(this.device, this.clock)
    : store = device.container.read(syncStoreProvider),
      repo = device.container.read(aiRepositoryProvider),
      proposals = device.container.read(proposalServiceProvider),
      tasks = device.container.read(taskRepositoryProvider) {
    service = LocalChatService(
      engine: engine,
      store: store,
      repository: repo,
      ensureModelLoaded: (id) async {
        loadCalls++;
        if (loadError != null) throw loadError!;
        engine.markLoaded();
      },
      onBusyChanged: ({required busy}) => busyLog.add(busy),
      contextText: (_) async => 'КОНТЕКСТ ПРИЛОЖЕНИЯ',
      zone: () => requireLocation('Europe/Moscow'),
      now: () => clock.now,
    );
  }

  final AiDevice device;
  final ManualClock clock;
  final SyncStore store;
  final AiRepository repo;
  final ProposalService proposals;
  final TaskRepository tasks;
  final FakeLlmEngine engine = FakeLlmEngine();
  late final LocalChatService service;
  final List<bool> busyLog = [];
  int loadCalls = 0;
  Exception? loadError;

  Future<void> createConversation({ChatMode mode = ChatMode.local}) =>
      repo.ensureConversation(
        Conversation(
          id: _conv,
          title: '',
          topic: AiTopic.general,
          mode: mode,
          model: mode == ChatMode.local ? gemma4E2b.wireModelId : null,
        ),
      );

  /// Пользователь пишет, модель отвечает; возвращает события.
  Future<List<LocalChatEvent>> ask(String text, {bool tools = true}) async {
    final id = await repo.addUserMessage(_conv, text);
    return await service
        .reply(conversationId: _conv, userMessageId: id, allowCreateTask: tools)
        .toList();
  }

  Future<List<ChatMessage>> messages() => repo.messagesOf(_conv);

  Future<ChatMessage> lastAssistant() async =>
      (await messages()).lastWhere((m) => m.role == MessageRole.assistant);

  Future<Map<String, ToolProposal>> proposalMap() => repo.proposalsOf(_conv);

  Future<int> taskCount(String id) async =>
      await store.getRow('tasks', id) == null ? 0 : 1;

  Future<int> rejectedOps() async => (await store.outboxSummary()).rejected;
}

void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late _Dev phone;
  late _Dev pc;

  setUp(() async {
    ensureTimeZones();
    clock = ManualClock(DateTime.utc(2026, 10, 5, 7).millisecondsSinceEpoch);
    server = aiServer(clock);
    phone = _Dev(await AiDevice.create(server, clock: clock), clock);
    pc = _Dev(await AiDevice.create(server, clock: clock), clock);
    await phone.createConversation();
  });

  tearDown(() async {
    phone.device.dispose();
    pc.device.dispose();
    await server.dispose();
  });

  group('обычный ответ', () {
    test('поток дельт, сообщение записано с нулевой стоимостью', () async {
      phone.engine.replies.add(
        FakeReply([
          'Сегодня ',
          'три задачи.',
        ], stats: const LlmRuntimeStats(outputTokens: 7)),
      );
      final events = await phone.ask('Что у меня сегодня?');

      // Модель ещё не в памяти: сначала «загружаю», затем старт ответа.
      expect(events.first, isA<LocalChatLoadingModel>());
      expect(events[1], isA<LocalChatStarted>());
      final deltas = events.whereType<LocalChatDelta>().toList();
      expect(deltas.map((d) => d.delta), ['Сегодня ', 'три задачи.']);
      expect(deltas.last.visibleText, 'Сегодня три задачи.');
      expect(deltas.last.draftingTool, isFalse);
      final done = events.last as LocalChatFinished;
      expect(done.status, MessageStatus.done);
      expect(done.text, 'Сегодня три задачи.');
      expect(done.hasProposal, isFalse);

      final message = await phone.lastAssistant();
      expect(message.id, events.whereType<LocalChatStarted>().single.messageId);
      expect(message.text, 'Сегодня три задачи.');
      expect(message.status, MessageStatus.done);
      expect(message.model, 'local/gemma-4-e2b-it');
      expect(message.costKopecks, 0);
      expect(message.completionTokens, 7);
      expect(message.promptTokens, greaterThan(0));
      expect(message.finishReason, 'stop');
      expect(message.errorCode, isNull);
      expect(message.parts.single, isA<TextPart>());
      expect(phone.loadCalls, 1);
    });

    test(
      'запрос к модели: система с «сейчас», правилами и контекстом',
      () async {
        await phone.ask('Привет');
        final turns = phone.engine.requests.single;
        expect(turns.first.role, LlmRole.system);
        expect(
          turns.first.text,
          contains('Сейчас: 2026-10-05, понедельник, 10:00'),
        );
        expect(turns.first.text, contains('create_task'));
        expect(turns.first.text, contains('КОНТЕКСТ ПРИЛОЖЕНИЯ'));
        expect(turns.last, const LlmTurn.user('Привет'));
        expect(phone.engine.paramsSeen.single.maxOutputTokens, 512);
      },
    );

    test('история беседы идёт в запрос, текущий вопрос — последним', () async {
      phone.engine.replies.addAll([
        FakeReply(['Первый ответ']),
        FakeReply(['Второй ответ']),
      ]);
      await phone.ask('Первый вопрос');
      await phone.ask('Второй вопрос');
      final turns = phone.engine.requests.last;
      expect(
        [for (final t in turns.skip(1)) (t.role, t.text)],
        [
          (LlmRole.user, 'Первый вопрос'),
          (LlmRole.model, 'Первый ответ'),
          (LlmRole.user, 'Второй вопрос'),
        ],
      );
    });

    test('бюджет токенов: старая история вытесняется', () async {
      for (var i = 0; i < 6; i++) {
        phone.engine.replies.add(FakeReply(['ответ ${'я' * 80} $i']));
      }
      const tight = TokenBudget(
        contextTokens: 900,
        reserveOutputTokens: 100,
        safetyTokens: 0,
      );
      for (var i = 0; i < 6; i++) {
        final id = await phone.repo.addUserMessage(
          _conv,
          'вопрос $i ${'я' * 80}',
        );
        final events = await phone.service
            .reply(conversationId: _conv, userMessageId: id, budget: tight)
            .toList();
        if (i == 5) {
          final started = events.first as LocalChatStarted;
          expect(started.droppedHistoryTurns, greaterThan(0));
          expect(
            started.estimatedInputTokens,
            lessThanOrEqualTo(tight.inputBudget),
          );
        }
      }
    });

    test(
      'промт агента подставляется, версия промта пишется в сообщение',
      () async {
        const agent = AgentProfile(
          id: '01900000-0000-7000-8000-0000000000a1',
          name: 'Работа',
          topic: AiTopic.work,
          systemPrompt: 'Ты помощник по работе.',
          promptVersion: 3,
          position: 0,
        );
        final id = await phone.repo.addUserMessage(_conv, 'Привет');
        await phone.service
            .reply(conversationId: _conv, userMessageId: id, agent: agent)
            .toList();
        expect(
          phone.engine.requests.single.first.text,
          startsWith('Ты помощник по работе.'),
        );
        final message = await phone.lastAssistant();
        expect(message.agentId, agent.id);
        expect(message.promptVersion, 3);
      },
    );
  });

  group('отмена и ошибки', () {
    test('отмена посреди ответа: частичный текст, статус cancelled', () async {
      phone.engine.replies.add(FakeReply(['Начало ', 'и конец'], holdAfter: 1));
      final id = await phone.repo.addUserMessage(_conv, 'Расскажи');
      final events = <LocalChatEvent>[];
      final done = Completer<void>();
      phone.service.reply(conversationId: _conv, userMessageId: id).listen((
        e,
      ) async {
        events.add(e);
        if (e is LocalChatDelta) await phone.service.cancel();
      }, onDone: done.complete);
      await done.future;

      final finished = events.last as LocalChatFinished;
      expect(finished.status, MessageStatus.cancelled);
      expect(finished.text, 'Начало ');
      final message = await phone.lastAssistant();
      expect(message.status, MessageStatus.cancelled);
      expect(message.text, 'Начало ');
      expect(phone.engine.cancels, 1);
      expect(phone.service.isGenerating, isFalse);
    });

    test('медленный первый токен: отмена до первого токена', () async {
      phone.engine.replies.add(FakeReply(['Поздно'], holdAfter: 0));
      final id = await phone.repo.addUserMessage(_conv, 'Эй');
      final events = <LocalChatEvent>[];
      final done = Completer<void>();
      phone.service.reply(conversationId: _conv, userMessageId: id).listen((
        e,
      ) async {
        events.add(e);
        if (e is LocalChatStarted) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await phone.service.cancel();
        }
      }, onDone: done.complete);
      await done.future;
      final finished = events.last as LocalChatFinished;
      expect(finished.status, MessageStatus.cancelled);
      expect(finished.text, isEmpty);
    });

    test(
      'отписка от потока останавливает модель и сохраняет частичный ответ',
      () async {
        phone.engine.replies.add(FakeReply(['Часть ', 'ещё'], holdAfter: 1));
        final id = await phone.repo.addUserMessage(_conv, 'Эй');
        final seen = Completer<void>();
        late StreamSubscription<LocalChatEvent> sub;
        sub = phone.service
            .reply(conversationId: _conv, userMessageId: id)
            .listen((e) {
              if (e is LocalChatDelta && !seen.isCompleted) seen.complete();
            });
        await seen.future;
        await sub.cancel();
        final message = await phone.lastAssistant();
        expect(message.status, MessageStatus.cancelled);
        expect(message.text, 'Часть ');
        expect(phone.service.isGenerating, isFalse);
      },
    );

    test(
      'обрыв движка посреди ответа: ошибка записана, текст сохранён',
      () async {
        phone.engine.replies.add(
          FakeReply(
            ['Полови', 'на'],
            failAfter: 1,
            failWith: const LocalLlmException(
              LocalLlmErrorKind.generationFailed,
              'сбой рантайма',
            ),
          ),
        );
        final events = await phone.ask('Скажи');
        final finished = events.last as LocalChatFinished;
        expect(finished.status, MessageStatus.error);
        expect(finished.errorCode, 'local_generationFailed');
        expect(finished.errorMessage, 'сбой рантайма');
        expect(finished.messageId, isNotNull);
        final message = await phone.lastAssistant();
        expect(message.status, MessageStatus.error);
        expect(message.text, 'Полови');
        expect(message.errorCode, 'local_generationFailed');
        expect(localErrorText(message.errorCode), isNotNull);
        expect(localErrorText('rate_limited'), isNull);
      },
    );

    test('исключение не из движка тоже становится ошибкой ответа', () async {
      phone.engine.replies.add(
        FakeReply(['а'], failAfter: 0, failWith: StateError('внезапно')),
      );
      final finished = (await phone.ask('Скажи')).last as LocalChatFinished;
      expect(finished.errorCode, 'local_generationFailed');
    });

    test(
      'модель не загрузилась (память): ошибка записана, запроса к ней нет',
      () async {
        phone.loadError = const LocalLlmException(
          LocalLlmErrorKind.outOfMemory,
          'Не хватило памяти',
        );
        final events = await phone.ask('Привет');
        final finished = events.last as LocalChatFinished;
        expect(finished.errorCode, 'local_outOfMemory');
        expect(events.whereType<LocalChatStarted>(), isEmpty);
        expect(phone.engine.requests, isEmpty);
        expect((await phone.lastAssistant()).status, MessageStatus.error);
      },
    );

    test(
      'второй ответ во время первого: «занято», ничего не записано',
      () async {
        phone.engine.replies.add(FakeReply(['а', 'б'], holdAfter: 1));
        final id = await phone.repo.addUserMessage(_conv, 'Первый');
        final first = <LocalChatEvent>[];
        final firstDone = Completer<void>();
        phone.service
            .reply(conversationId: _conv, userMessageId: id)
            .listen(first.add, onDone: firstDone.complete);
        while (first.whereType<LocalChatDelta>().isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final secondId = await phone.repo.addUserMessage(_conv, 'Второй');
        final second = await phone.service
            .reply(conversationId: _conv, userMessageId: secondId)
            .toList();
        expect(second.single, isA<LocalChatFinished>());
        expect((second.single as LocalChatFinished).errorCode, 'local_busy');
        expect((second.single as LocalChatFinished).messageId, isNull);

        phone.engine.release();
        await firstDone.future;
        expect(
          (await phone.messages())
              .where((m) => m.role == MessageRole.assistant)
              .length,
          1,
        );
      },
    );

    test('беседа не найдена: ошибка без записи', () async {
      final events = await phone.service
          .reply(conversationId: _conv, userMessageId: 'нет-такого')
          .toList();
      final finished = events.last as LocalChatFinished;
      expect(finished.status, MessageStatus.error);
    });
  });

  group('создание задачи офлайн', () {
    test(
      'валидный JSON -> сообщение с карточкой и предложение pending',
      () async {
        phone.engine.replies.add(FakeReply.task(_args, lead: 'Хорошо.'));
        final events = await phone.ask('Купить молоко завтра в 9 утра');

        expect(
          events.whereType<LocalChatDelta>().last.draftingTool,
          isTrue,
          reason: 'сырой JSON не показываем, идёт «формирую задачу»',
        );
        expect(events.whereType<LocalChatDelta>().last.visibleText, 'Хорошо.');
        final finished = events.last as LocalChatFinished;
        expect(finished.finishReason, 'awaiting_approval');
        expect(finished.text, 'Хорошо.');

        final message = await phone.lastAssistant();
        expect(message.finishReason, 'awaiting_approval');
        expect(message.parts.whereType<TextPart>().single.text, 'Хорошо.');
        final call = message.parts.whereType<ToolCallPart>().single;
        expect(call.name, 'create_task');
        expect(call.arguments, _args);
        final link = message.parts.whereType<ProposalPart>().single;
        expect(link.toolCallId, call.id);

        final proposal = (await phone.proposalMap())[link.proposalId]!;
        expect(proposal.status, ProposalStatus.pending);
        expect(proposal.tool, 'create_task');
        expect(proposal.entityType, 'task');
        expect(proposal.messageId, message.id);
        expect(proposal.arguments, _args);
        expect(proposal.originalArguments, _args);
        expect(proposal.decidedAt, isNull);
        expect(
          proposal.entityId,
          matches(RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-7')),
        );
        expect(proposal.entityId, isNot(link.proposalId));
        // Задача появится только после одобрения.
        expect(await phone.taskCount(proposal.entityId), 0);
      },
    );

    test('без текста рядом: фраза над карточкой по названию', () async {
      phone.engine.replies.add(FakeReply.task({'title': 'Позвонить'}));
      final finished = (await phone.ask('Позвони')).last as LocalChatFinished;
      expect(finished.text, 'Предлагаю создать задачу «Позвонить».');
    });

    test('одобрение создаёт ровно одну задачу с entity_id', () async {
      phone.engine.replies.add(FakeReply.task(_args));
      final finished = (await phone.ask('Молоко')).last as LocalChatFinished;
      final proposal = (await phone.proposalMap())[finished.proposalId]!;

      final outcome = await phone.proposals.approve(proposal.id);
      expect(outcome, ApprovalOutcome.created);
      // Двойное нажатие и повтор: новых задач нет.
      expect(
        await phone.proposals.approve(proposal.id),
        ApprovalOutcome.alreadyDecided,
      );

      final task = TaskEntity.fromRow(
        (await phone.store.getRow('tasks', proposal.entityId))!,
      );
      expect(task.id, proposal.entityId);
      expect(task.title, 'Купить молоко');
      expect(task.source, TaskSource.ai);
      expect(task.priority, 2);
      final tasksOps = (await phone.store.outbox()).where(
        (o) => o.table == 'tasks' && o.rowId == proposal.entityId,
      );
      expect(tasksOps.length, 1);

      final after = (await phone.proposalMap())[proposal.id]!;
      expect(after.status, ProposalStatus.approved);
    });

    test('одобрение с двух устройств: одна задача', () async {
      phone.engine.replies.add(FakeReply.task(_args));
      final finished = (await phone.ask('Молоко')).last as LocalChatFinished;
      final proposalId = finished.proposalId!;
      await phone.device.sync();
      await pc.device.sync();
      final entity = (await phone.proposalMap())[proposalId]!.entityId;

      // Оба нажали «одобрить», пока друг друга не видели.
      await phone.proposals.approve(proposalId);
      final second = await pc.proposals.approve(proposalId);
      expect(second, ApprovalOutcome.created);
      await phone.device.sync();
      await pc.device.sync();
      await phone.device.sync();

      for (final dev in [phone, pc]) {
        final rows = await dev.store.visibleRows('tasks');
        expect(rows.where((r) => r['id'] == entity).length, 1);
        expect(rows.length, 1);
      }
      expect(await phone.rejectedOps(), 0);
      expect(await pc.rejectedOps(), 0);
    });

    test('невалидный JSON -> один повтор с подсказкой -> карточка', () async {
      phone.engine.replies.addAll([
        FakeReply.truncatedJson(),
        FakeReply.task(_args),
      ]);
      final events = await phone.ask('Купить молоко');

      final retry = events.whereType<LocalChatRetrying>().single;
      expect(retry.problems.single, contains('оборван'));
      expect(phone.engine.requests.length, 2);
      final second = phone.engine.requests[1];
      expect(second[second.length - 2].role, LlmRole.model);
      expect(second.last.role, LlmRole.user);
      expect(second.last.text, contains('Твой ответ не подошёл'));
      expect(second.last.text, contains('оборван'));
      expect((events.last as LocalChatFinished).hasProposal, isTrue);
      expect((await phone.proposalMap()).length, 1);
      final message = await phone.lastAssistant();
      expect(message.completionTokens, greaterThan(0));
    });

    test('схема нарушена -> повтор -> снова мусор: обычный текст без карточки', () async {
      phone.engine.replies.addAll([
        FakeReply(['{"tool":"create_task","arguments":{"priority":9}}']),
        FakeReply([
          'Вот что получилось: {"tool":"create_task","arguments":{"title":""}}',
        ]),
      ]);
      final events = await phone.ask('Сделай что-нибудь');

      expect(events.whereType<LocalChatRetrying>().length, 1);
      expect(phone.engine.requests.length, 2, reason: 'повтор только один');
      final finished = events.last as LocalChatFinished;
      expect(finished.hasProposal, isFalse);
      expect(finished.text, 'Вот что получилось:');
      expect(await phone.proposalMap(), isEmpty);
      final message = await phone.lastAssistant();
      expect(message.parts.single, isA<TextPart>());
      expect(message.finishReason, 'stop');
    });

    test('мусор без текста -> понятное сообщение вместо JSON', () async {
      phone.engine.replies.addAll([
        FakeReply.truncatedJson(),
        FakeReply.truncatedJson(),
      ]);
      final finished = (await phone.ask('Сделай')).last as LocalChatFinished;
      expect(finished.text, createTaskFailedText);
      expect(finished.hasProposal, isFalse);
    });

    test('инструмент выключен: JSON остаётся обычным текстом', () async {
      phone.engine.replies.add(FakeReply.task(_args));
      final events = await phone.ask('Молоко', tools: false);
      expect(events.whereType<LocalChatRetrying>(), isEmpty);
      expect((events.last as LocalChatFinished).hasProposal, isFalse);
      expect(
        phone.engine.requests.single.first.text,
        isNot(contains('create_task')),
      );
      expect(events.whereType<LocalChatDelta>().last.draftingTool, isFalse);
    });

    test('прошлое решение по карточке возвращается модели в истории', () async {
      phone.engine.replies.addAll([
        FakeReply.task(_args),
        FakeReply(['Готово']),
      ]);
      final finished = (await phone.ask('Молоко')).last as LocalChatFinished;
      await phone.proposals.approve(finished.proposalId!);
      await phone.ask('Спасибо');

      final turns = phone.engine.requests.last;
      final model = turns.firstWhere((t) => t.role == LlmRole.model);
      expect(model.text, contains('"tool":"create_task"'));
      expect(model.text, contains('Купить молоко'));
      final result = turns.where((t) => t.role == LlmRole.user).toList()[1];
      expect(result.text, contains('task created'));
      expect(result.text, contains('Спасибо'));
    });
  });

  group('синхронизация локальной беседы', () {
    test(
      'беседа, сообщения и предложение доезжают до второго устройства',
      () async {
        phone.engine.replies.addAll([
          FakeReply(['Сегодня три задачи.']),
          FakeReply.task(_args, lead: 'Предлагаю.'),
        ]);
        await phone.ask('Что сегодня?');
        final task =
            (await phone.ask('Купить молоко')).last as LocalChatFinished;

        await phone.device.sync();
        await pc.device.sync();
        expect(
          await phone.rejectedOps(),
          0,
          reason: 'сервер принял строки клиента',
        );

        final conversation = (await pc.repo.getConversation(_conv))!;
        expect(conversation.mode, ChatMode.local);
        expect(conversation.model, 'local/gemma-4-e2b-it');
        final messages = await pc.messages();
        expect(
          [for (final m in messages) m.role],
          [
            MessageRole.user,
            MessageRole.assistant,
            MessageRole.user,
            MessageRole.assistant,
          ],
        );
        expect(messages[1].text, 'Сегодня три задачи.');
        expect(messages[1].costKopecks, 0);
        final proposals = await pc.proposalMap();
        expect(proposals[task.proposalId]!.status, ProposalStatus.pending);

        // Второе устройство одобряет — задача и решение приезжают на первое.
        await pc.proposals.approve(task.proposalId!);
        await pc.device.sync();
        await phone.device.sync();
        final entity = proposals[task.proposalId]!.entityId;
        expect(await phone.taskCount(entity), 1);
        expect(
          (await phone.proposalMap())[task.proposalId]!.status,
          ProposalStatus.approved,
        );
      },
    );

    test(
      'переключение режима: local задаёт модель, cloud её сбрасывает',
      () async {
        await phone.createConversation(mode: ChatMode.cloud);
        var c = (await phone.repo.getConversation(_conv))!;
        expect(c.mode, ChatMode.local, reason: 'беседа уже была создана');

        await phone.service.switchMode(_conv, ChatMode.cloud);
        c = (await phone.repo.getConversation(_conv))!;
        expect(c.mode, ChatMode.cloud);
        expect(
          c.model,
          isNull,
          reason: 'локальную модель в облако не отправить',
        );

        await phone.service.switchMode(_conv, ChatMode.local);
        c = (await phone.repo.getConversation(_conv))!;
        expect(c.mode, ChatMode.local);
        expect(c.model, 'local/gemma-4-e2b-it');

        // Повтор без изменений не плодит операций.
        final before = (await phone.store.outbox()).length;
        await phone.service.switchMode(_conv, ChatMode.local);
        expect((await phone.store.outbox()).length, before);

        // Облачную модель можно задать явно.
        await phone.service.switchMode(
          _conv,
          ChatMode.cloud,
          model: 'openai/gpt-4o',
        );
        expect(
          (await phone.repo.getConversation(_conv))!.model,
          'openai/gpt-4o',
        );
        await phone.service.switchMode('нет-беседы', ChatMode.cloud);
      },
    );
  });

  group('история -> реплики', () {
    test(
      'вызов инструмента остаётся JSON-ом, результат — репликой пользователя',
      () {
        final turns = historyToTurns([
          {'role': 'user', 'content': 'Создай'},
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'c1',
                'type': 'function',
                'function': {
                  'name': 'create_task',
                  'arguments': '{"title":"Т"}',
                },
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'c1',
            'content': 'awaiting user approval',
          },
          {'role': 'user', 'content': 'Ну что?'},
        ]);
        expect(turns.map((t) => t.role), [
          LlmRole.user,
          LlmRole.model,
          LlmRole.user,
        ]);
        expect(
          turns[1].text,
          '{"tool":"create_task","arguments":{"title":"Т"}}',
        );
        expect(turns[2].text, contains('awaiting user approval'));
        expect(turns[2].text, contains('Ну что?'));
      },
    );

    test('невалидные аргументы вызова не ломают историю', () {
      final turns = historyToTurns([
        {
          'role': 'assistant',
          'content': 'Текст',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {'name': 'create_task', 'arguments': '{oops'},
            },
          ],
        },
      ]);
      expect(turns.single.text, contains('Текст'));
      expect(turns.single.text, contains('"arguments":{}'));
    });
  });
}
