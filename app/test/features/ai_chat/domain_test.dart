import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_errors.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_format.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/ai_chat/domain/history_builder.dart';
import 'package:my_tasker/features/ai_chat/domain/proposal_mapping.dart';
import 'package:my_tasker/features/ai_chat/presentation/markdown_text.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:timezone/timezone.dart' as tz;

ChatMessage _msg(
  String id,
  MessageRole role,
  String text, {
  List<MessagePart> parts = const [],
  MessageStatus status = MessageStatus.done,
}) => ChatMessage(
  id: id,
  conversationId: 'c',
  role: role,
  text: text,
  parts: parts.isEmpty && text.isNotEmpty ? [TextPart(text)] : parts,
  status: status,
);

ToolProposal _proposal(
  ProposalStatus status, {
  String? reason,
  Map<String, Object?>? arguments,
}) => ToolProposal(
  id: 'p1',
  messageId: 'm',
  toolCallId: 'call_2',
  tool: 'create_task',
  entityType: 'task',
  entityId: 'e1',
  originalArguments: const {'title': 'Оплатить домен'},
  arguments: arguments ?? const {'title': 'Оплатить домен'},
  status: status,
  rejectReason: reason,
);

void main() {
  group('форматирование расхода (копейки -> рубли)', () {
    test('formatCost: целые копейки без double', () {
      // Разряды и знак валюты отделяются неразрывными пробелами.
      String nb(String s) => s.replaceAll(' ', '\u00A0');
      expect(formatCost(0), nb('0 ₽'));
      expect(formatCost(5), nb('0,05 ₽'));
      expect(formatCost(100), nb('1 ₽'));
      expect(formatCost(1234), nb('12,34 ₽'));
      expect(formatCost(123456), nb('1 234,56 ₽'));
      expect(formatCost(5000000), nb('50 000 ₽'));
    });

    test('rublesInput: значение для поля лимита', () {
      expect(rublesInput(50000), '500');
      expect(rublesInput(1250), '12,50');
      expect(rublesInput(5), '0,05');
      expect(rublesInput(0), '0');
    });

    test('formatCount и formatTokens', () {
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(12345), '12 345');
      expect(formatCount(-1234567), '-1 234 567');
      expect(formatTokens(4200), '≈ 4 200 ток.');
    });

    test('месяцы: подпись, сдвиг, ключ периода', () {
      expect(monthLabel('2026-10'), 'октябрь 2026');
      expect(monthLabel('2026-01'), 'январь 2026');
      expect(monthLabel('oops'), 'oops');
      expect(shiftMonth('2026-01', -1), '2025-12');
      expect(shiftMonth('2026-12', 1), '2027-01');
      expect(shiftMonth('2026-10', 0), '2026-10');
      expect(monthOf(DateTime.utc(2026, 3, 9)), '2026-03');
    });

    test('границы месяца биллинга: Москва UTC+3', () {
      // 30 сентября 21:30 UTC уже 1 октября по Москве.
      expect(billingMonth(DateTime.utc(2026, 9, 30, 21, 30)), '2026-10');
      expect(billingMonth(DateTime.utc(2026, 9, 30, 20, 59)), '2026-09');
    });
  });

  group('расход и каталог из JSON', () {
    test('UsageSummary: лимит, доля, предупреждение 80 %', () {
      final u = UsageSummary.fromJson(const {
        'month': '2026-10',
        'limit_kopecks': 50000,
        'spent_kopecks': 41000,
        'remaining_kopecks': 9000,
        'requests': 12,
        'prompt_tokens': 40000,
        'completion_tokens': 9000,
        'by_model': [
          {
            'model': 'openai/gpt-4o',
            'requests': 12,
            'prompt_tokens': 40000,
            'completion_tokens': 9000,
            'cost_kopecks': 41000,
          },
        ],
      });
      expect(u.limitShare, closeTo(0.82, 1e-9));
      expect(u.nearLimit, isTrue);
      expect(u.exceeded, isFalse);
      expect(u.byModel.single.costKopecks, 41000);
    });

    test('без лимита: доли нет; нулевой лимит блокирует всё', () {
      final none = UsageSummary.fromJson(const {
        'month': '2026-10',
        'limit_kopecks': null,
        'spent_kopecks': 100,
        'remaining_kopecks': null,
        'requests': 1,
        'prompt_tokens': 1,
        'completion_tokens': 1,
        'by_model': <Object?>[],
      });
      expect(none.limitShare, isNull);
      expect(none.nearLimit, isFalse);
      const zero = UsageSummary(
        month: '2026-10',
        spentKopecks: 0,
        requests: 0,
        promptTokens: 0,
        completionTokens: 0,
        limitKopecks: 0,
      );
      expect(zero.limitShare, 1);
      expect(zero.exceeded, isTrue);
    });

    test('каталог моделей: цены и признак инструментов', () {
      final c = ModelCatalog.fromJson(const {
        'models': [
          {
            'id': 'openai/gpt-4o',
            'name': 'GPT-4o',
            'context_length': 128000,
            'max_completion_tokens': 16384,
            'supports_tools': true,
            'price_input_kopecks_per_mtok': 25000,
            'price_output_kopecks_per_mtok': null,
          },
        ],
        'stale': true,
      });
      expect(c.stale, isTrue);
      expect(c.byId('openai/gpt-4o')!.priceInputKopecksPerMtok, 25000);
      expect(c.byId('openai/gpt-4o')!.priceOutputKopecksPerMtok, isNull);
      expect(c.byId('nope'), isNull);
      expect(c.byId(null), isNull);
    });

    test('тело запроса completion: params только если заданы', () {
      const base = CompletionRequest(
        conversationId: 'c',
        assistantMessageId: 'a',
        model: 'm',
        messages: [],
        contextText: 'ctx',
        timezone: 'UTC',
        presetId: 'p',
        containsSensitive: true,
        tools: ['get_tasks'],
        temperature: 0.5,
        maxTokens: 100,
      );
      final json = base.toJson();
      expect(json['params'], {'temperature': 0.5, 'max_tokens': 100});
      expect(json['tools'], ['get_tasks']);
      expect(json['context'], {
        'text': 'ctx',
        'preset_id': 'p',
        'contains_sensitive': true,
      });
    });
  });

  group('сбои запроса ИИ -> понятные сообщения', () {
    test('нет сети -> offline (не критично, повторить можно)', () {
      final f = ChatFailure.fromApi(const ApiException.network('x'));
      expect(f.code, 'offline');
      expect(f.isOffline, isTrue);
      expect(f.retryable, isTrue);
      expect(f.critical, isFalse);
      expect(f.message, contains('Нет сети'));
    });

    test('limit_exceeded: суммы из details, красный', () {
      final f = ChatFailure.fromApi(
        const ApiException(
          kind: ApiErrorKind.http,
          status: 402,
          code: 'limit_exceeded',
          details: {
            'limit_kopecks': 50000,
            'spent_kopecks': 51234,
            'month': '2026-10',
          },
        ),
      );
      expect(f.critical, isTrue);
      expect(f.retryable, isFalse);
      expect(f.message, contains('512,34\u00A0₽'));
      expect(f.message, contains('500\u00A0₽'));
    });

    test('коды раздела 8: текст есть у каждого, ключ не нужен для вывода', () {
      for (final code in [
        'limit_exceeded',
        'sensitive_context_forbidden',
        'model_not_found',
        'conversation_not_found',
        'agent_not_found',
        'message_exists',
        'validation_error',
        'unknown_tool',
        'ai_not_configured',
        'upstream_timeout',
        'upstream_error',
        'upstream_rate_limited',
        'upstream_payment_required',
        'upstream_rejected',
        'tool_loop_limit',
        'persist_failed',
        'internal_error',
        'no_model',
        'sync_failed',
        'connection_lost',
        'not_configured',
        'что-то-новое',
      ]) {
        final f = ChatFailure.forCode(code);
        expect(f.message, isNotEmpty, reason: code);
        // Тексты — русские, без технических подробностей и секретов.
        expect(f.message, isNot(contains('Bearer')), reason: code);
        expect(RegExp('[а-яА-Я]').hasMatch(f.message), isTrue, reason: code);
      }
      expect(ChatFailure.forCode('upstream_timeout').retryable, isTrue);
      expect(ChatFailure.forCode('model_not_found').retryable, isFalse);
      expect(
        ChatFailure.forCode('sensitive_context_forbidden').critical,
        isTrue,
      );
      expect(ChatFailure.forCode('upstream_payment_required').critical, isTrue);
    });

    test('ошибка сервера 5xx без кода: повторяемая внутренняя', () {
      final f = ChatFailure.fromApi(
        const ApiException(kind: ApiErrorKind.http, status: 500),
      );
      expect(f.code, 'internal_error');
      expect(f.retryable, isTrue);
    });

    test('сервер не настроен', () {
      final f = ChatFailure.fromApi(const ApiException.notConfigured());
      expect(f.code, 'not_configured');
    });
  });

  group('история для запроса', () {
    test('user/assistant как есть; error-ответы пропускаются', () {
      final history = buildHistory([
        _msg('1', MessageRole.user, 'Привет'),
        _msg('2', MessageRole.assistant, 'Здравствуйте'),
        _msg('3', MessageRole.user, 'Ещё'),
        _msg('4', MessageRole.assistant, 'часть', status: MessageStatus.error),
        _msg('5', MessageRole.assistant, '', status: MessageStatus.cancelled),
        _msg('6', MessageRole.user, 'Повтор'),
      ], const {});
      expect(history, [
        {'role': 'user', 'content': 'Привет'},
        {'role': 'assistant', 'content': 'Здравствуйте'},
        {'role': 'user', 'content': 'Ещё'},
        {'role': 'user', 'content': 'Повтор'},
      ]);
    });

    test('отменённый ответ с текстом остаётся в истории', () {
      final history = buildHistory([
        _msg('1', MessageRole.user, 'Вопрос'),
        _msg(
          '2',
          MessageRole.assistant,
          'Частичный ответ',
          status: MessageStatus.cancelled,
        ),
      ], const {});
      expect(history.last, {'role': 'assistant', 'content': 'Частичный ответ'});
    });

    test('вызов читающего инструмента: tool_calls и сообщение tool', () {
      final history = buildHistory([
        _msg(
          '2',
          MessageRole.assistant,
          'Вот задачи',
          parts: const [
            ToolCallPart(
              id: 'call_1',
              name: 'get_tasks',
              arguments: {
                'status': ['todo'],
              },
            ),
            ToolResultPart(
              toolCallId: 'call_1',
              name: 'get_tasks',
              content: '{"count":3}',
              isError: false,
            ),
            TextPart('Вот задачи'),
          ],
        ),
      ], const {});
      expect(history, hasLength(2));
      final assistant = history.first;
      expect(assistant['content'], 'Вот задачи');
      final call = (assistant['tool_calls']! as List).single as Map;
      expect(call['id'], 'call_1');
      expect(call['type'], 'function');
      expect(jsonDecode((call['function']! as Map)['arguments']! as String), {
        'status': ['todo'],
      });
      expect(history[1], {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': '{"count":3}',
      });
    });

    ChatMessage proposalMessage() => _msg(
      '2',
      MessageRole.assistant,
      '',
      parts: const [
        ToolCallPart(
          id: 'call_2',
          name: 'create_task',
          arguments: {'title': 'Оплатить домен'},
        ),
        ProposalPart(
          proposalId: 'p1',
          toolCallId: 'call_2',
          tool: 'create_task',
        ),
      ],
    );

    test('итог для модели по решению пользователя (spec 2, п. 7)', () {
      String content(ToolProposal p) =>
          buildHistory([proposalMessage()], {'p1': p})[1]['content']! as String;
      expect(
        content(_proposal(ProposalStatus.pending)),
        'awaiting user approval',
      );
      expect(content(_proposal(ProposalStatus.approved)), 'task created: e1');
      expect(
        content(
          _proposal(
            ProposalStatus.editedApproved,
            arguments: const {'title': 'Оплатить домен', 'priority': 1},
          ),
        ),
        allOf(
          startsWith('task created: e1; final arguments: '),
          contains('"priority":1'),
        ),
      );
      expect(
        content(_proposal(ProposalStatus.rejected, reason: 'Не то время')),
        'user rejected: Не то время',
      );
      expect(content(_proposal(ProposalStatus.rejected)), 'user rejected');
    });

    test(
      'assistant с content = null при пустом тексте; без результата — заглушка',
      () {
        final history = buildHistory([
          _msg(
            '2',
            MessageRole.assistant,
            '',
            parts: const [
              ToolCallPart(id: 'x', name: 'get_events', rawArguments: '{oops'),
            ],
          ),
        ], const {});
        expect(history.first['content'], isNull);
        final call = (history.first['tool_calls']! as List).single as Map;
        expect((call['function']! as Map)['arguments'], '{oops');
        expect(history[1]['content'], 'no result');
      },
    );

    test('обрезка по бюджету: старое уходит, вызов и результат не рвутся', () {
      OpenAiMessage user(String t) => {'role': 'user', 'content': t};
      final long = 'я' * 300; // 100 токенов
      final history = <OpenAiMessage>[
        user(long),
        {'role': 'assistant', 'content': long},
        user(long),
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'c',
              'type': 'function',
              'function': {'name': 'get_tasks', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c', 'content': 'ok'},
        user('последний вопрос'),
      ];
      final trimmed = trimHistory(history, 130);
      // Последний ход всегда остаётся; вызов инструмента не отделён от
      // результата; история начинается с пользователя.
      expect(trimmed.last['content'], 'последний вопрос');
      expect(trimmed.first['role'], 'user');
      final roles = trimmed.map((m) => m['role']).toList();
      for (var i = 0; i < roles.length; i++) {
        if (roles[i] == 'tool') {
          expect(roles[i - 1], anyOf('assistant', 'tool'));
        }
      }
      expect(trimmed.length, lessThan(history.length));
    });

    test('даже при крошечном бюджете остаётся последний ход', () {
      final trimmed = trimHistory([
        {'role': 'user', 'content': 'я' * 3000},
      ], 10);
      expect(trimmed, hasLength(1));
    });

    test('не больше 400 сообщений (spec 5.1)', () {
      final history = [
        for (var i = 0; i < 500; i++) {'role': 'user', 'content': 'м$i'},
      ];
      final trimmed = trimHistory(history, 1 << 30);
      expect(trimmed, hasLength(400));
      expect(trimmed.last['content'], 'м499');
    });
  });

  group('предложение -> задача', () {
    late tz.Location moscow;
    setUpAll(() {
      ensureTimeZones();
      moscow = tz.getLocation('Europe/Moscow');
    });

    test(
      'дата и время -> момент в поясе пользователя, статус todo, source ai',
      () {
        final task = taskFromArguments(
          {
            'title': '  Подготовить смету ',
            'notes': 'Для Елены',
            'priority': 2,
            'due_date': '2026-10-01',
            'due_time': '15:00',
            'duration_minutes': 60,
          },
          entityId: 'e1',
          zone: moscow,
          projectId: 'pr',
        );
        expect(task.id, 'e1');
        expect(task.title, 'Подготовить смету');
        expect(task.status, TaskStatus.todo);
        expect(task.source, TaskSource.ai);
        expect(task.due.at, DateTime.utc(2026, 10, 1, 12));
        expect(task.due.tz, 'Europe/Moscow');
        expect(task.priority, 2);
        expect(task.durationMinutes, 60);
        expect(task.projectId, 'pr');
      },
    );

    test('только дата -> срок-дата; без даты -> inbox', () {
      final dated = taskFromArguments(
        {'title': 'A', 'due_date': '2026-10-01'},
        entityId: 'e',
        zone: moscow,
      );
      expect(dated.due.date, DateTime.utc(2026, 10));
      expect(dated.due.hasTime, isFalse);
      expect(dated.status, TaskStatus.todo);
      final none = taskFromArguments(
        {'title': 'B'},
        entityId: 'e',
        zone: moscow,
      );
      expect(none.due.isNone, isTrue);
      expect(none.status, TaskStatus.inbox);
    });

    test('теги: только допустимые, без повторов, не больше 5', () {
      expect(
        tagsFromArguments({
          'tags': [
            'работа',
            'Работа',
            'плохой тег',
            '#x',
            'a',
            'b',
            'c',
            'd',
            'e',
          ],
        }),
        ['работа', 'a', 'b', 'c', 'd'],
      );
      expect(tagsFromArguments({}), isEmpty);
      expect(projectFromArguments({'project': ' Creora '}), 'Creora');
      expect(projectFromArguments({'project': ''}), isNull);
    });

    test('проверка аргументов перед одобрением', () {
      String? p(Map<String, Object?> a) => proposalProblem(a, zone: moscow);
      expect(p({'title': 'ok'}), isNull);
      expect(p({'title': '  '}), contains('название'));
      expect(
        p({'title': 'x', 'due_date': '31.12.2026'}),
        contains('ГГГГ-ММ-ДД'),
      );
      expect(
        p({'title': 'x', 'due_date': '2026-10-01', 'due_time': '25:00'}),
        contains('ЧЧ:ММ'),
      );
      expect(p({'title': 'x', 'due_time': '10:00'}), contains('без даты'));
      expect(p({'title': 'x', 'priority': 9}), contains('P1'));
    });

    test('аргументы сравниваются по значению, порядок ключей не важен', () {
      expect(
        argumentsDiffer(
          {
            'a': 1,
            'b': ['x'],
          },
          {
            'b': ['x'],
            'a': 1,
          },
        ),
        isFalse,
      );
      expect(argumentsDiffer({'a': 1}, {'a': 2}), isTrue);
    });
  });

  group('markdown ответа', () {
    test('блоки: заголовок, список, цитата, код, таблица, абзац', () {
      final blocks = parseMarkdown(
        '## Итог\n'
        'Первая строка\nвторая\n\n'
        '- пункт 1\n* пункт 2\n1. номер\n'
        '> цитата\n'
        '```dart\nvar x = 1;\n```\n'
        '| a | b |\n|---|---|\n| 1 | 2 |\n',
      );
      expect(blocks.map((b) => b.runtimeType.toString()), [
        'MdHeading',
        'MdParagraph',
        'MdListItem',
        'MdListItem',
        'MdListItem',
        'MdQuote',
        'MdCode',
        'MdTable',
      ]);
      expect((blocks[1] as MdParagraph).text, 'Первая строка\nвторая');
      expect((blocks[4] as MdListItem).marker, '1.');
      expect((blocks[6] as MdCode).language, 'dart');
      expect((blocks[7] as MdTable).rows, [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });

    test('незакрытый блок кода (идёт стриминг) остаётся кодом', () {
      final blocks = parseMarkdown('Текст\n```\nпочти');
      expect(blocks.last, isA<MdCode>());
      expect((blocks.last as MdCode).code, 'почти');
    });
  });

  group('модели из строк', () {
    test('чат: топик и копирование', () {
      final c = Conversation.fromRow(const {
        'id': 'c',
        'title': 'T',
        'topic': 'calendar_tasks',
        'agent_id': null,
        'model': 'm',
        'context_preset_id': null,
        'pinned': true,
        'archived': false,
        'mode': 'cloud',
        'created_at': '2026-10-01T10:00:00.000Z',
        'updated_at':
            '0000001790000000-00000-01900000-0000-7000-8000-000000000001',
      });
      expect(c.topic, AiTopic.calendarTasks);
      expect(c.pinned, isTrue);
      expect(c.updatedAt, isNotNull);
      final moved = c.copyWith(agentId: 'a', model: null);
      expect(moved.agentId, 'a');
      expect(moved.model, isNull);
      expect(moved.topic, AiTopic.calendarTasks);
    });

    test('части сообщения: неизвестный тип пропускается', () {
      final parts = MessagePart.listFromJson([
        {'type': 'text', 'text': 'a'},
        {'type': 'image', 'url': 'x'},
        {
          'type': 'tool_call',
          'id': 'c',
          'name': 'n',
          'arguments': null,
          'raw_arguments': '{',
        },
        'мусор',
      ]);
      expect(parts, hasLength(2));
      expect((parts[1] as ToolCallPart).rawArguments, '{');
      expect(parts[1].toJson()['raw_arguments'], '{');
    });

    test('предложение: isEdited по значению', () {
      expect(_proposal(ProposalStatus.pending).isEdited, isFalse);
      expect(
        _proposal(
          ProposalStatus.pending,
          arguments: const {'title': 'Другое'},
        ).isEdited,
        isTrue,
      );
    });

    test(
      'идентификаторы: версия промта и избранная модель детерминированы',
      () {
        expect(promptVersionId('p', 3), promptVersionId('p', 3));
        expect(promptVersionId('p', 3), isNot(promptVersionId('p', 4)));
        expect(
          modelFavoriteId('openai/gpt-4o'),
          modelFavoriteId('openai/gpt-4o'),
        );
        expect(monthlyLimitKey, 'ai.monthly_limit_kopecks');
      },
    );

    test('заголовок чата из первых слов', () {
      expect(AiRepository.titleFrom('Короткий вопрос'), 'Короткий вопрос');
      final long = AiRepository.titleFrom(
        'Помоги подготовить подробную смету для Елены по доработке входа в бота',
      );
      expect(long.length, lessThanOrEqualTo(41));
      expect(long, endsWith('…'));
    });
  });
}
