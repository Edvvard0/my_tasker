import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sse_client.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';

/// Эндпоинты ИИ глазами клиента (spec 3). Реализации: HTTP
/// ([HttpAiApi]) и поддельный сервер в тестах.
abstract interface class AiApi {
  /// `POST /ai/bootstrap`: идемпотентно заводит предустановленных агентов.
  Future<AiBootstrap> bootstrap();

  /// `POST /ai/agents/{seed_key}/reset`: строки в формате `pull`.
  Future<List<SyncChange>> resetAgent(String seedKey);

  /// `GET /ai/models`.
  Future<ModelCatalog> models({bool refresh = false});

  /// `GET /ai/usage`.
  Future<UsageSummary> usage({String? month});

  /// `POST /ai/chat/completions`: поток событий ответа. Отмена подписки
  /// закрывает соединение (spec 5.6). Ошибки до начала потока — [ApiException]
  /// с кодом из раздела 8.
  Stream<ChatEvent> completions(CompletionRequest request);

  /// `POST /ai/chat/{message_id}/cancel`: явная отмена; `false`, если
  /// такого идущего ответа нет.
  Future<bool> cancel(String messageId);
}

/// [AiApi] поверх [ApiClient]: закреплённый сертификат, токен доступа и
/// обновление токена — как у остальных запросов.
class HttpAiApi implements AiApi {
  HttpAiApi(this._client);

  final Future<ApiClient?> Function() _client;

  Future<ApiClient> get _api async {
    final client = await _client();
    if (client == null) throw const ApiException.notConfigured();
    return client;
  }

  T _parse<T>(T Function() parse) {
    try {
      return parse();
    } on Object {
      throw const ApiException(kind: ApiErrorKind.malformed);
    }
  }

  @override
  Future<AiBootstrap> bootstrap() async {
    final json = await (await _api).postJson('/ai/bootstrap');
    final parsed = _parse(() => AiBootstrap.fromJson(json));
    return parsed;
  }

  @override
  Future<List<SyncChange>> resetAgent(String seedKey) async {
    final json = await (await _api).postJson('/ai/agents/$seedKey/reset');
    final parsed = _parse(
      () => [
        for (final c in json['changes']! as List<Object?>)
          SyncChange.fromJson((c! as Map).cast<String, Object?>()),
      ],
    );
    return parsed;
  }

  @override
  Future<ModelCatalog> models({bool refresh = false}) async {
    final json = await (await _api).getJson(
      '/ai/models',
      query: {if (refresh) 'refresh': true},
    );
    final parsed = _parse(() => ModelCatalog.fromJson(json));
    return parsed;
  }

  @override
  Future<UsageSummary> usage({String? month}) async {
    final json = await (await _api).getJson(
      '/ai/usage',
      query: {'month': ?month},
    );
    final parsed = _parse(() => UsageSummary.fromJson(json));
    return parsed;
  }

  @override
  Stream<ChatEvent> completions(CompletionRequest request) async* {
    final token = CancelToken();
    var finished = false;
    try {
      final bytes = await (await _api).openPostStream(
        '/ai/chat/completions',
        request.toJson(),
        cancelToken: token,
      );
      await for (final frame in parseSse(bytes)) {
        final event = ChatEvent.fromFrame(frame);
        if (event != null) yield event;
      }
      finished = true;
    } finally {
      // Подписку отменили (или поток упал): просим Dio оборвать запрос.
      // После получения заголовков `abort()` соединение не закрывает, поэтому
      // ответ на сервере останавливает явный `cancel` (spec 5.6).
      if (!finished) token.cancel('closed by client');
    }
  }

  @override
  Future<bool> cancel(String messageId) async {
    final json = await (await _api).postJson('/ai/chat/$messageId/cancel');
    return json['cancelled'] == true;
  }
}
