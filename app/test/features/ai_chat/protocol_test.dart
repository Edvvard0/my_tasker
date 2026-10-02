import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sse_client.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';

import '../../support/fake_ai_server.dart';

CompletionRequest _request({
  String id = '01900000-0000-7000-8000-000000000001',
}) => CompletionRequest(
  conversationId: '01900000-0000-7000-8000-0000000000c1',
  assistantMessageId: id,
  model: 'openai/gpt-4o',
  messages: const [
    {'role': 'user', 'content': 'Привет'},
  ],
  contextText: '',
  timezone: 'Europe/Moscow',
);

/// Поток сервера из контракта: старт, текст на русском (с эмодзи), вызов
/// инструмента, предложение, расход, завершение.
String _fullStream(String id) =>
    sseFrame('start', {
      'message_id': id,
      'model': 'openai/gpt-4o',
      'agent_id': null,
      'prompt_version': 3,
      'tools_enabled': true,
    }) +
    sseFrame('ping', {}) +
    sseFrame('delta', {'text': 'Привет, '}) +
    sseFrame('delta', {'text': 'мир ✓ 🙂'}) +
    sseFrame('tool_call', {
      'id': 'call_1',
      'name': 'get_tasks',
      'arguments': {
        'status': ['todo'],
      },
    }) +
    sseFrame('tool_result', {
      'tool_call_id': 'call_1',
      'name': 'get_tasks',
      'is_error': false,
      'preview': '{"count":3}',
    }) +
    sseFrame('future_event', {'x': 1}) +
    sseFrame('proposal', {
      'proposal_id': 'p1',
      'tool_call_id': 'call_2',
      'tool': 'create_task',
      'entity_type': 'task',
      'entity_id': 'e1',
      'arguments': {'title': 'Оплатить домен'},
    }) +
    sseFrame('usage', {
      'prompt_tokens': 100,
      'completion_tokens': 20,
      'cost_kopecks': 12,
    }) +
    sseFrame('done', {
      'message_id': id,
      'status': 'done',
      'finish_reason': 'awaiting_approval',
      'prompt_tokens': 100,
      'completion_tokens': 20,
      'cost_kopecks': 12,
    });

Future<List<ChatEvent>> _parse(Stream<List<int>> bytes) async => [
  await for (final f in parseSse(bytes)) ?ChatEvent.fromFrame(f),
];

void main() {
  const id = '01900000-0000-7000-8000-000000000001';

  group('разбор кадров ChatEvent', () {
    test('каждое событие потока разбирается в свой тип', () async {
      final events = await _parse(Stream.value(utf8.encode(_fullStream(id))));
      expect(events.map((e) => e.runtimeType.toString()), [
        'ChatStart',
        'ChatDelta',
        'ChatDelta',
        'ChatToolCall',
        'ChatToolResult',
        'ChatProposal',
        'ChatUsage',
        'ChatDone',
      ]);
      final start = events.first as ChatStart;
      expect(start.messageId, id);
      expect(start.promptVersion, 3);
      expect(start.toolsEnabled, isTrue);
      expect((events[2] as ChatDelta).text, 'мир ✓ 🙂');
      final call = events[3] as ChatToolCall;
      expect(call.name, 'get_tasks');
      expect(call.arguments, {
        'status': ['todo'],
      });
      expect((events[4] as ChatToolResult).preview, '{"count":3}');
      final proposal = events[5] as ChatProposal;
      expect(proposal.entityId, 'e1');
      expect(proposal.arguments['title'], 'Оплатить домен');
      final done = events.last as ChatDone;
      expect(done.finishReason, 'awaiting_approval');
      expect(done.costKopecks, 12);
    });

    test('вызов с невалидным JSON: arguments = null', () {
      final e = ChatEvent.fromFrame(
        const SseEvent(
          'tool_call',
          '{"id":"c","name":"create_task","arguments":null}',
        ),
      );
      expect((e! as ChatToolCall).arguments, isNull);
    });

    test('ошибка потока: код, retryable, message_id', () {
      final e = ChatEvent.fromFrame(
        SseEvent(
          'error',
          jsonEncode({
            'code': 'upstream_timeout',
            'message': 'x',
            'retryable': true,
            'message_id': id,
          }),
        ),
      );
      final err = e! as ChatError;
      expect(err.code, 'upstream_timeout');
      expect(err.retryable, isTrue);
      expect(err.messageId, id);
    });

    test('ping, неизвестные события и неразборчивый JSON пропускаются', () {
      expect(ChatEvent.fromFrame(const SseEvent('ping', '{}')), isNull);
      expect(ChatEvent.fromFrame(const SseEvent('weird', '{}')), isNull);
      expect(ChatEvent.fromFrame(const SseEvent('delta', '{oops')), isNull);
      expect(ChatEvent.fromFrame(const SseEvent('delta', '[1]')), isNull);
    });

    test('tools_enabled = false разбирается', () {
      final e = ChatEvent.fromFrame(
        const SseEvent('start', '{"message_id":"m","tools_enabled":false}'),
      );
      expect((e! as ChatStart).toolsEnabled, isFalse);
    });
  });

  group('потоковая доставка по частям', () {
    final bytes = utf8.encode(_fullStream(id));

    Future<List<ChatEvent>> chunked(int Function(int) size) {
      final chunks = <List<int>>[];
      var i = 0;
      var n = 0;
      while (i < bytes.length) {
        final end = min(bytes.length, i + size(n++));
        chunks.add(bytes.sublist(i, end));
        i = end;
      }
      return _parse(Stream.fromIterable(chunks));
    }

    test(
      'по одному байту: кириллица и эмодзи рвутся посреди символа',
      () async {
        final whole = await _parse(Stream.value(bytes));
        final split = await chunked((_) => 1);
        expect(split.length, whole.length);
        expect(
          [for (final e in split.whereType<ChatDelta>()) e.text].join(),
          'Привет, мир ✓ 🙂',
        );
      },
    );

    test('случайные размеры кусков дают те же события', () async {
      final whole = await _parse(Stream.value(bytes));
      final wholeDeltas = whole.whereType<ChatDelta>().map((e) => e.text);
      for (var seed = 0; seed < 25; seed++) {
        final rnd = Random(seed);
        final split = await chunked((_) => 1 + rnd.nextInt(17));
        expect(split.whereType<ChatDelta>().map((e) => e.text), wholeDeltas);
        expect(split.last, isA<ChatDone>());
      }
    });

    test('CRLF вместо LF', () async {
      final crlf = utf8.encode(_fullStream(id).replaceAll('\n', '\r\n'));
      final events = await _parse(Stream.value(crlf));
      expect(events.last, isA<ChatDone>());
    });

    test('поток без done: события есть, завершения нет', () async {
      final cut = bytes.sublist(0, bytes.length - 40);
      final events = await _parse(Stream.value(cut));
      expect(events.whereType<ChatDone>(), isEmpty);
      expect(events.whereType<ChatDelta>(), isNotEmpty);
    });
  });

  group('HTTP-клиент против поддельного сервера', () {
    late FakeAiServer server;

    // flutter_test подменяет HttpClient заглушкой с ответом 400.
    setUpAll(() => HttpOverrides.global = null);
    setUp(() async => server = await FakeAiServer.start());
    tearDown(() => server.close());

    test('успешный ответ по 3 байта: все события, тело и заголовки', () async {
      server.onCompletion = (res) async {
        startSse(res);
        await writeChunked(res, utf8.encode(_fullStream(id)));
        await res.close();
      };
      final events = await server.client().completions(_request()).toList();
      expect(events.first, isA<ChatStart>());
      expect(events.last, isA<ChatDone>());
      expect(events.whereType<ChatToolResult>(), hasLength(1));
      expect(events.whereType<ChatProposal>(), hasLength(1));
      expect(
        [for (final e in events.whereType<ChatDelta>()) e.text].join(),
        'Привет, мир ✓ 🙂',
      );

      final body = server.bodies.single;
      expect(body['conversation_id'], '01900000-0000-7000-8000-0000000000c1');
      expect(body['assistant_message_id'], id);
      expect(body['model'], 'openai/gpt-4o');
      expect(body['timezone'], 'Europe/Moscow');
      expect(body['tools'], isNull);
      expect(body.containsKey('params'), isFalse);
      expect(body['context'], {
        'text': '',
        'preset_id': null,
        'contains_sensitive': false,
      });
      final messages = body['messages']! as List;
      expect(messages, [
        {'role': 'user', 'content': 'Привет'},
      ]);
      expect(server.headers.single.value('x-client-schema-version'), '7');
      expect(server.headers.single.value('accept'), 'text/event-stream');
    });

    for (final (status, code) in [
      (402, 'limit_exceeded'),
      (403, 'sensitive_context_forbidden'),
      (404, 'model_not_found'),
      (404, 'conversation_not_found'),
      (503, 'ai_not_configured'),
    ]) {
      test('HTTP $status $code до начала потока -> ApiException', () async {
        server.onCompletion = (res) async {
          res
            ..statusCode = status
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'error': {
                  'code': code,
                  'message': 'm',
                  'details': {'limit_kopecks': 500, 'spent_kopecks': 512},
                },
              }),
            );
          await res.close();
        };
        final stream = server.client().completions(_request());
        await expectLater(
          stream.toList(),
          throwsA(
            isA<ApiException>()
                .having((e) => e.status, 'status', status)
                .having((e) => e.code, 'code', code)
                .having((e) => e.details['limit_kopecks'], 'details', 500),
          ),
        );
      });
    }

    test('ошибка посреди потока приходит событием error', () async {
      server.onCompletion = (res) async {
        startSse(res);
        res
          ..write(sseFrame('start', {'message_id': id, 'model': 'm'}))
          ..write(sseFrame('delta', {'text': 'Частичный '}))
          ..write(
            sseFrame('error', {
              'code': 'upstream_error',
              'message': 'boom',
              'retryable': true,
              'message_id': id,
            }),
          );
        await res.close();
      };
      final events = await server.client().completions(_request()).toList();
      expect(events.last, isA<ChatError>());
      expect((events.last as ChatError).code, 'upstream_error');
      expect(events.whereType<ChatDone>(), isEmpty);
    });

    test('обрыв соединения посреди потока: done не приходит', () async {
      server.onCompletion = (res) async {
        // Настоящий обрыв: заголовки и первые куски кадрами chunked, затем
        // сокет уничтожается без завершающего куска.
        final socket = await res.detachSocket(writeHeaders: false);
        void chunk(String text) {
          final data = utf8.encode(text);
          socket
            ..write('${data.length.toRadixString(16)}\r\n')
            ..add(data)
            ..write('\r\n');
        }

        socket.write(
          'HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n'
          'transfer-encoding: chunked\r\n\r\n',
        );
        chunk(sseFrame('start', {'message_id': id, 'model': 'm'}));
        chunk(sseFrame('delta', {'text': 'Начало'}));
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        socket.destroy();
      };
      final events = <ChatEvent>[];
      Object? error;
      try {
        await server.client().completions(_request()).forEach(events.add);
      } on Object catch (e) {
        error = e;
      }
      expect(events.whereType<ChatDelta>().map((e) => e.text), ['Начало']);
      expect(events.whereType<ChatDone>(), isEmpty);
      // Клиент отличает обрыв по отсутствию `done`: ошибка потока либо
      // тихое закрытие — оба случая допустимы.
      expect(error, anyOf(isNull, isA<Object>()));
    });

    test('отмена: подписка снята, явный cancel останавливает сервер', () async {
      var handlerDone = false;
      server.onCompletion = (res) async {
        startSse(res);
        res.write(sseFrame('start', {'message_id': id, 'model': 'm'}));
        var n = 0;
        // Сервер пишет, пока не придёт явная отмена.
        while (!server.cancelled.isCompleted && n++ < 400) {
          res.write(sseFrame('delta', {'text': 'слово $n '}));
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await res.close();
        handlerDone = true;
      };
      final api = server.client();
      final first = Completer<void>();
      var afterCancel = 0;
      var cancelledLocally = false;
      final sub = api.completions(_request()).listen((e) {
        if (cancelledLocally) afterCancel++;
        if (e is ChatDelta && !first.isCompleted) first.complete();
      });
      await first.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      cancelledLocally = true;
      expect(await api.cancel(id), isTrue);
      await server.cancelled.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(afterCancel, 0, reason: 'после отмены события не доставляются');
      expect(handlerDone, isTrue, reason: 'сервер завершил ответ');
      expect(server.cancelRequests, [id]);
    });

    test('явная отмена: POST /ai/chat/{id}/cancel', () async {
      expect(await server.client().cancel(id), isTrue);
      expect(server.cancelRequests, [id]);
    });
  });
}
