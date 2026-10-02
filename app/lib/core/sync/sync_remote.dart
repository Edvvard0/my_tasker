import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_models.dart';

/// Сервер синхронизации глазами клиента (spec 3). Реализации: HTTP-клиент
/// ([HttpSyncRemote]) и фейковый сервер в тестах.
abstract interface class SyncRemote {
  /// `POST /sync/push`.
  Future<PushResponse> push(List<Json> ops);

  /// `GET /sync/pull`.
  Future<PullPage> pull({required int since, required int limit});

  /// `GET /sync/conflicts`.
  Future<ConflictsPage> conflicts({
    String reverted = 'all',
    int limit = 50,
    String? before,
  });

  /// `POST /sync/conflicts/{id}/revert` («Вернуть моё»).
  Future<RevertResult> revert(String conflictId);
}

/// [SyncRemote] поверх [ApiClient]. Функция-источник возвращает клиент для
/// текущих настроек сервера (дождавшись их загрузки) или `null`, если сервер
/// не настроен.
class HttpSyncRemote implements SyncRemote {
  HttpSyncRemote(this._client);

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
  Future<PushResponse> push(List<Json> ops) async {
    final json = await (await _api).postJson('/sync/push', body: {'ops': ops});
    final parsed = _parse(() => PushResponse.fromJson(json));
    return parsed;
  }

  @override
  Future<PullPage> pull({required int since, required int limit}) async {
    final json = await (await _api).getJson(
      '/sync/pull',
      query: {'since': since, 'limit': limit},
    );
    final parsed = _parse(() => PullPage.fromJson(json));
    return parsed;
  }

  @override
  Future<ConflictsPage> conflicts({
    String reverted = 'all',
    int limit = 50,
    String? before,
  }) async {
    final json = await (await _api).getJson(
      '/sync/conflicts',
      query: {'reverted': reverted, 'limit': limit, 'before': ?before},
    );
    final parsed = _parse(() => ConflictsPage.fromJson(json));
    return parsed;
  }

  @override
  Future<RevertResult> revert(String conflictId) async {
    final json = await (await _api).postJson(
      '/sync/conflicts/$conflictId/revert',
    );
    final parsed = _parse(() => RevertResult.fromJson(json));
    return parsed;
  }
}
