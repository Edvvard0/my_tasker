import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/network/api_client.dart';

/// Событие SSE (spec 6): имя и данные одной строкой JSON.
@immutable
class SseEvent {
  const SseEvent(this.event, this.data);

  final String event;
  final String data;
}

/// Разбирает поток байтов SSE в события. Комментарии (`: ...`) и `retry:`
/// игнорируются; несколько `data:` склеиваются через перевод строки.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) {
  var buffer = '';
  var event = 'message';
  final data = <String>[];

  void dispatch(EventSink<SseEvent> sink) {
    if (data.isNotEmpty) sink.add(SseEvent(event, data.join('\n')));
    event = 'message';
    data.clear();
  }

  void handleLine(String line, EventSink<SseEvent> sink) {
    if (line.isEmpty) return dispatch(sink);
    if (line.startsWith(':')) return;
    final colon = line.indexOf(':');
    final field = colon == -1 ? line : line.substring(0, colon);
    var value = colon == -1 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.add(value);
    }
  }

  return bytes
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(
        StreamTransformer<String, SseEvent>.fromHandlers(
          handleData: (chunk, sink) {
            buffer += chunk;
            var start = 0;
            var i = 0;
            while (i < buffer.length) {
              final c = buffer[i];
              if (c == '\n') {
                handleLine(buffer.substring(start, i), sink);
                start = i + 1;
              } else if (c == '\r') {
                // «\r» в конце буфера: возможно, дальше придёт «\n».
                if (i + 1 >= buffer.length) break;
                handleLine(buffer.substring(start, i), sink);
                start = buffer[i + 1] == '\n' ? i + 2 : i + 1;
                i = start - 1;
              }
              i++;
            }
            buffer = buffer.substring(start);
          },
          handleDone: (sink) {
            // Одиночный «\r» в самом конце потока — тоже конец строки.
            if (buffer.endsWith('\r')) {
              handleLine(buffer.substring(0, buffer.length - 1), sink);
            }
            sink.close();
          },
        ),
      );
}

/// Сигнал от сервера, важный для синхронизации.
enum SseSignalKind { hello, changes, revoked }

@immutable
class SseSignal {
  const SseSignal(this.kind, [this.headVersion]);

  final SseSignalKind kind;
  final int? headVersion;
}

/// Клиент `GET /events` (spec 6): долгоживущее соединение с
/// переподключением (backoff 1 -> 60 с) и сторожем тишины (60 с без
/// единого байта — соединение считается мёртвым).
class SseClient {
  SseClient({
    required this._connect,
    this.heartbeatTimeout = const Duration(seconds: 60),
    this.minBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 60),
  });

  final Future<Stream<List<int>>> Function() _connect;
  final Duration heartbeatTimeout;
  final Duration minBackoff;
  final Duration maxBackoff;

  final StreamController<SseSignal> _signals =
      StreamController<SseSignal>.broadcast();
  Completer<void>? _stopped;
  StreamSubscription<SseEvent>? _subscription;
  bool _connected = false;
  Future<void>? _loop;

  Stream<SseSignal> get signals => _signals.stream;

  /// Соединение установлено (получен ответ `200`).
  bool get isConnected => _connected;

  bool get isRunning => _stopped != null;

  /// Запускает цикл подключения; повторный вызов ничего не делает.
  void start() {
    if (_stopped != null) return;
    final stopped = _stopped = Completer<void>();
    _loop = _run(stopped).whenComplete(() {
      if (identical(_stopped, stopped)) _stopped = null;
    });
  }

  /// Останавливает цикл и закрывает соединение.
  Future<void> stop() async {
    final stopped = _stopped;
    if (stopped == null) return;
    _stopped = null;
    if (!stopped.isCompleted) stopped.complete();
    // Не ждём завершения отмены: у оборванного соединения она может не прийти.
    unawaited(_subscription?.cancel());
    _subscription = null;
    _connected = false;
    await _loop;
  }

  Future<void> _run(Completer<void> stopped) async {
    var backoff = minBackoff;
    while (!stopped.isCompleted) {
      var receivedHello = false;
      try {
        final bytes = await _connect();
        if (stopped.isCompleted) return;
        _connected = true;
        final ended = Completer<void>();
        // Сторож тишины: любой байт (в том числе `ping`) перезапускает его.
        Timer? watchdog;
        void arm() {
          watchdog?.cancel();
          watchdog = Timer(heartbeatTimeout, () {
            if (!ended.isCompleted) ended.complete();
          });
        }

        arm();
        _subscription =
            parseSse(
              bytes.map((chunk) {
                arm();
                return chunk;
              }),
            ).listen(
              (event) {
                final signal = _signal(event);
                if (signal == null) return;
                if (signal.kind == SseSignalKind.hello) receivedHello = true;
                if (!_signals.isClosed) _signals.add(signal);
                if (signal.kind == SseSignalKind.revoked) {
                  // Сервер закрывает поток: заново не подключаемся.
                  stopped.complete();
                  if (!ended.isCompleted) ended.complete();
                }
              },
              onError: (Object _) {
                if (!ended.isCompleted) ended.complete();
              },
              onDone: () {
                if (!ended.isCompleted) ended.complete();
              },
            );
        await Future.any([ended.future, stopped.future]);
        watchdog?.cancel();
        unawaited(_subscription?.cancel());
        _subscription = null;
      } on ApiException catch (e) {
        // Отзыв, вход и версию клиента разбирает движок синхронизации.
        if (e.status == 401 || e.status == 426) return;
      } on Object {
        // Сеть, тайм-аут тишины и т. п.: переподключение с backoff.
      }
      _connected = false;
      if (stopped.isCompleted) return;
      if (receivedHello) backoff = minBackoff;
      await Future.any<void>([Future<void>.delayed(backoff), stopped.future]);
      final doubled = backoff * 2;
      backoff = doubled > maxBackoff ? maxBackoff : doubled;
    }
  }

  SseSignal? _signal(SseEvent event) {
    final head = _head(event.data);
    return switch (event.event) {
      'hello' => SseSignal(SseSignalKind.hello, head),
      'changes' => SseSignal(SseSignalKind.changes, head),
      'revoked' => const SseSignal(SseSignalKind.revoked),
      _ => null, // ping и неизвестные события
    };
  }

  int? _head(String data) {
    try {
      final json = jsonDecode(data);
      return json is Map ? json['head_version'] as int? : null;
    } on Object {
      return null;
    }
  }

  Future<void> dispose() async {
    await stop();
    await _signals.close();
  }
}
