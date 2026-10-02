import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/features/ai_chat/data/ai_api.dart';

/// Кадр SSE по контракту Этапа 3 (5.3).
String sseFrame(String event, Map<String, Object?> data) =>
    'event: $event\ndata: ${jsonEncode(data)}\n\n';

/// Настоящий HTTP-сервер на эфемерном порту, который отвечает как
/// `/ai/chat/completions`: поток SSE кусками, HTTP-ошибки, обрыв
/// соединения, ожидание отмены клиентом.
class FakeAiServer {
  FakeAiServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<FakeAiServer> start() async =>
      FakeAiServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  /// Как отвечать на очередной `POST /ai/chat/completions`.
  Future<void> Function(HttpResponse response)? onCompletion;

  final List<Map<String, Object?>> bodies = [];
  final List<HttpHeaders> headers = [];
  final List<String> cancelRequests = [];

  /// Пришёл явный `POST /ai/chat/{id}/cancel`.
  final Completer<void> cancelled = Completer<void>();

  /// Клиент закрыл соединение, пока сервер ещё писал.
  final Completer<void> clientClosed = Completer<void>();

  Uri get baseUrl => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method == 'POST' && path == '/ai/chat/completions') {
      final text = await utf8.decoder.bind(request).join();
      bodies.add((jsonDecode(text) as Map).cast<String, Object?>());
      headers.add(request.headers);
      final response = request.response;
      unawaited(
        response.done.then<void>(
          (_) {},
          onError: (Object _) {
            if (!clientClosed.isCompleted) clientClosed.complete();
          },
        ),
      );
      try {
        await onCompletion!(response);
      } on Object {
        // Клиент ушёл посреди записи: это ожидаемо.
      }
      return;
    }
    if (request.method == 'POST' && path.endsWith('/cancel')) {
      cancelRequests.add(path.split('/')[3]);
      if (!cancelled.isCompleted) cancelled.complete();
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"cancelled": true}');
      await request.response.close();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);

  /// Клиент API на этот сервер.
  HttpAiApi client() {
    final api = ApiClient(
      dio: ApiClient.createDio(
        baseUrl: baseUrl,
        adapter: IOHttpClientAdapter(),
      ),
      schemaVersion: 7,
    );
    return HttpAiApi(() async => api);
  }
}

/// Открывает поток SSE: статус 200 и нужные заголовки.
void startSse(HttpResponse response) {
  response
    ..statusCode = 200
    ..headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    )
    ..headers.set('Cache-Control', 'no-cache')
    ..bufferOutput = false;
}

/// Пишет [bytes] кусками по [size] байт (рвёт многобайтные символы).
Future<void> writeChunked(
  HttpResponse response,
  List<int> bytes, {
  int size = 3,
}) async {
  for (var i = 0; i < bytes.length; i += size) {
    response.add(
      bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
    );
    await response.flush();
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
