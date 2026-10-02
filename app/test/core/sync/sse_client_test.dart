import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sse_client.dart';

Stream<List<int>> _chunks(List<String> parts) =>
    Stream.fromIterable(parts.map(utf8.encode));

Future<List<(String, String)>> _parse(List<String> parts) async => [
  await for (final e in parseSse(_chunks(parts))) (e.event, e.data),
];

/// Управляемый «сервер» SSE: каждое подключение — свой поток.
class _Wire {
  final List<StreamController<List<int>>> streams = [];
  final List<Duration> connectTimes = [];
  Exception? failWith;
  late FakeAsync async;

  Future<Stream<List<int>>> connect() async {
    connectTimes.add(async.elapsed);
    final error = failWith;
    if (error != null) throw error;
    final c = StreamController<List<int>>();
    streams.add(c);
    return c.stream;
  }

  void send(int index, String text) => streams[index].add(utf8.encode(text));
}

class _FixedRandom implements Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => value > 0.5;

  @override
  int nextInt(int max) => (value * max).floor();
}

void main() {
  group('parseSse', () {
    test('события, комментарии, retry и неизвестные поля', () async {
      expect(
        await _parse([
          'retry: 3000\n\n',
          ': comment\n',
          'event: hello\ndata: {"head_version":1}\n\n',
          'event: ping\ndata: {}\n\n',
          'data: no event name\n\n',
        ]),
        [
          ('hello', '{"head_version":1}'),
          ('ping', '{}'),
          ('message', 'no event name'),
        ],
      );
    });

    test('граница чанка посреди строки и посреди символа UTF-8', () async {
      final bytes = utf8.encode('event: x\ndata: привет\n\n');
      final events = await parseSse(
        Stream.fromIterable([bytes.sublist(0, 14), bytes.sublist(14)]),
      ).toList();
      expect(events.single.data, 'привет');
      expect(events.single.event, 'x');
    });

    test('CRLF, одиночный CR и CR на границе чанков', () async {
      expect(
        await _parse(['event: a\r\ndata: 1\r\n\r\n', 'event: b\rdata: 2\r\r']),
        [('a', '1'), ('b', '2')],
      );
      expect(await _parse(['event: c\r', '\ndata: 3\r', '\n\r', '\n']), [
        ('c', '3'),
      ]);
    });

    test('несколько data склеиваются переводом строки; пустое событие '
        'пропускается', () async {
      expect(await _parse(['data: a\ndata: b\n\n', '\n\n']), [
        ('message', 'a\nb'),
      ]);
      expect(await _parse(['data\n\n']), [('message', '')]);
    });

    test('оборванное событие (без пустой строки) не выдаётся', () async {
      expect(await _parse(['event: a\ndata: 1\n']), isEmpty);
    });
  });

  group('SseClient', () {
    test('hello и changes становятся сигналами, ping игнорируется', () {
      fakeAsync((async) {
        final wire = _Wire()..async = async;
        final client = SseClient(connect: wire.connect);
        final signals = <SseSignal>[];
        client.signals.listen(signals.add);
        client.start();
        async.flushMicrotasks();
        expect(client.isConnected, isTrue);
        expect(client.isRunning, isTrue);
        wire
          ..send(0, 'event: hello\ndata: {"head_version": 5}\n\n')
          ..send(0, 'event: ping\ndata: {}\n\n')
          ..send(0, 'event: changes\ndata: {"head_version": 9}\n\n')
          ..send(0, 'event: changes\ndata: not json\n\n')
          ..send(0, 'event: unknown\ndata: {}\n\n');
        async.flushMicrotasks();
        expect(signals.map((s) => (s.kind, s.headVersion)), [
          (SseSignalKind.hello, 5),
          (SseSignalKind.changes, 9),
          (SseSignalKind.changes, null),
        ]);
        client.start(); // повторный запуск ничего не делает
        expect(wire.streams, hasLength(1));
        unawaited(client.stop());
        async.flushMicrotasks();
        expect(client.isConnected, isFalse);
        expect(client.isRunning, isFalse);
      });
    });

    test(
      'обрыв: переподключение с backoff 1, 2, 4 … 60 с; hello сбрасывает',
      () {
        fakeAsync((async) {
          final wire = _Wire()
            ..async = async
            ..failWith = const ApiException.network();
          final client = SseClient(connect: wire.connect, jitter: 0)..start();
          async.elapse(const Duration(seconds: 200));
          // попытки в 0, 1, 3, 7, 15, 31, 63, 123, 183 секунды
          expect(wire.connectTimes.map((d) => d.inSeconds), [
            0,
            1,
            3,
            7,
            15,
            31,
            63,
            123,
            183,
          ]);
          // сервер вернулся: подключились, получили hello, поток оборвался
          wire.failWith = null;
          async.elapse(const Duration(seconds: 60));
          expect(wire.connectTimes.last.inSeconds, 243);
          final last = wire.streams.length - 1;
          wire.send(last, 'event: hello\ndata: {"head_version": 1}\n\n');
          async.flushMicrotasks();
          wire.failWith = const ApiException.network();
          unawaited(wire.streams[last].close());
          async.elapse(Duration.zero);
          final closedAt = async.elapsed;
          async.elapse(const Duration(seconds: 12));
          // после hello пауза снова 1 с (а не накопленные 60): 1, 2, 4 …
          final after = wire.connectTimes.skip(10).toList();
          expect(after.length, greaterThanOrEqualTo(3));
          expect(
            after[0] - closedAt,
            lessThanOrEqualTo(const Duration(seconds: 2)),
          );
          expect(after[1] - after[0], const Duration(seconds: 2));
          expect(after[2] - after[1], const Duration(seconds: 4));
          unawaited(client.stop());
          async.flushMicrotasks();
        });
      },
    );

    test('60 секунд тишины: соединение считается мёртвым, переподключение', () {
      fakeAsync((async) {
        final wire = _Wire()..async = async;
        final client = SseClient(connect: wire.connect)..start();
        async.flushMicrotasks();
        wire.send(0, 'event: ping\ndata: {}\n\n');
        async.elapse(const Duration(seconds: 59));
        expect(wire.streams, hasLength(1));
        wire.send(0, 'event: ping\ndata: {}\n\n'); // сторож перезапускается
        async.elapse(const Duration(seconds: 59));
        expect(wire.streams, hasLength(1));
        async
          ..elapse(const Duration(seconds: 2)) // тишина > 60 с
          ..elapse(const Duration(seconds: 2));
        expect(wire.streams.length, greaterThanOrEqualTo(2));
        unawaited(client.stop());
        async.flushMicrotasks();
      });
    });

    test('revoked: сигнал и остановка без переподключения', () {
      fakeAsync((async) {
        final wire = _Wire()..async = async;
        final client = SseClient(connect: wire.connect);
        final signals = <SseSignalKind>[];
        client.signals.listen((s) => signals.add(s.kind));
        client.start();
        async.flushMicrotasks();
        wire.send(0, 'event: revoked\ndata: {}\n\n');
        async.elapse(const Duration(minutes: 5));
        expect(signals, [SseSignalKind.revoked]);
        expect(wire.streams, hasLength(1));
        expect(client.isRunning, isFalse);
        // можно запустить снова (после нового входа)
        client.start();
        async.flushMicrotasks();
        expect(wire.streams, hasLength(2));
        unawaited(client.stop());
        async.flushMicrotasks();
      });
    });

    test('401 и 426 при подключении останавливают клиент', () {
      fakeAsync((async) {
        for (final status in [401, 426]) {
          final wire = _Wire()
            ..async = async
            ..failWith = ApiException(kind: ApiErrorKind.http, status: status);
          final client = SseClient(connect: wire.connect)..start();
          async.elapse(const Duration(minutes: 5));
          expect(wire.connectTimes, hasLength(1));
          expect(client.isRunning, isFalse);
        }
      });
    });

    test('ошибка в потоке — переподключение; stop во время паузы', () {
      fakeAsync((async) {
        final wire = _Wire()..async = async;
        final client = SseClient(connect: wire.connect)..start();
        async.flushMicrotasks();
        wire.streams[0].addError(StateError('boom'));
        async.elapse(const Duration(seconds: 3));
        expect(wire.streams.length, greaterThanOrEqualTo(2));
        unawaited(wire.streams.last.close());
        async.flushMicrotasks();
        unawaited(client.stop()); // во время паузы перед повтором
        async.elapse(const Duration(minutes: 2));
        expect(wire.streams.length, lessThanOrEqualTo(3));
        expect(client.isRunning, isFalse);
      });
    });

    test('jitter сокращает паузу до backoff * (1 - jitter), не длиннее '
        'backoff', () {
      fakeAsync((async) {
        // Random, всегда возвращающий максимум разброса.
        final wire = _Wire()
          ..async = async
          ..failWith = const ApiException.network();
        final client = SseClient(
          connect: wire.connect,
          jitter: 0.5,
          random: _FixedRandom(0.999999),
        )..start();
        async.elapse(const Duration(seconds: 10));
        // паузы ≈ 0,5 с, ≈ 1 с, ≈ 2 с … вместо 1, 2, 4: попыток больше
        expect(wire.connectTimes.length, greaterThan(4));
        for (var i = 1; i < wire.connectTimes.length; i++) {
          final pause = wire.connectTimes[i] - wire.connectTimes[i - 1];
          final backoff = Duration(seconds: 1 << (i - 1));
          expect(pause, lessThanOrEqualTo(backoff));
          if (backoff < const Duration(seconds: 60)) {
            expect(
              pause.inMilliseconds,
              greaterThan(backoff.inMilliseconds / 2 - 5),
            );
          }
        }
        unawaited(client.stop());
        async.flushMicrotasks();
      });
    });

    test('nudge (сеть вернулась) обрывает паузу и сбрасывает backoff', () {
      fakeAsync((async) {
        final wire = _Wire()
          ..async = async
          ..failWith = const ApiException.network();
        final client = SseClient(connect: wire.connect, jitter: 0)..start();
        async.elapse(const Duration(seconds: 40)); // паузы выросли до 16 с
        final before = wire.connectTimes.length;
        wire.failWith = null;
        client.nudge();
        async.flushMicrotasks();
        expect(wire.connectTimes.length, before + 1);
        expect(client.isConnected, isTrue);
        // соединение живо: nudge ничего не делает и не ломает backoff
        client.nudge();
        async.flushMicrotasks();
        expect(wire.connectTimes.length, before + 1);
        // после обрыва пауза снова минимальная (1 с), а не 32
        wire.failWith = const ApiException.network();
        unawaited(wire.streams.last.close());
        async.elapse(const Duration(milliseconds: 1100));
        expect(wire.connectTimes.length, before + 2);
        unawaited(client.stop());
        async.flushMicrotasks();
      });
    });

    test('stop во время подключения: полученный поток отменяется', () {
      fakeAsync((async) {
        final gate = Completer<Stream<List<int>>>();
        var cancelled = false;
        final controller = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        );
        final client = SseClient(connect: () => gate.future)..start();
        async.flushMicrotasks();
        unawaited(client.stop());
        gate.complete(controller.stream); // ответ пришёл уже после stop
        async.flushMicrotasks();
        expect(cancelled, isTrue);
        expect(client.isConnected, isFalse);
        expect(client.isRunning, isFalse);
      });
    });

    test('dispose закрывает поток сигналов', () {
      fakeAsync((async) {
        final wire = _Wire()..async = async;
        final client = SseClient(connect: wire.connect)..start();
        async.flushMicrotasks();
        var done = false;
        client.signals.listen((_) {}, onDone: () => done = true);
        unawaited(client.dispose());
        async.flushMicrotasks();
        expect(done, isTrue);
      });
    });
  });
}
