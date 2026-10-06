import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/network/api_providers.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';

/// Ответ `GET /monitoring/pulse`: `304` (снимок не изменился) либо новый
/// снимок с его `ETag`.
class PulseFetch {
  const PulseFetch.notModified() : snapshot = null, etag = null, raw = null;
  const PulseFetch.fresh(
    PulseSnapshot this.snapshot,
    this.etag,
    Map<String, Object?> this.raw,
  );

  bool get isNotModified => snapshot == null;

  final PulseSnapshot? snapshot;
  final String? etag;

  /// Тело ответа как есть (для офлайн-кэша).
  final Map<String, Object?>? raw;
}

/// Эндпоинты «Пульса» глазами клиента (spec `stage9_monitoring.md`, раздел 8).
/// Токен Telegram и chat id клиенту не известны: он видит только «настроено
/// или нет» и коды ошибок.
abstract interface class MonitoringApi {
  /// `GET /monitoring/pulse` с `If-None-Match` ([etag]).
  Future<PulseFetch> pulse({String? etag});

  /// `POST /monitoring/refresh` — «Проверить сейчас»: новый снимок.
  Future<PulseFetch> refresh();

  /// `GET /monitoring/incidents`: страница, новые первыми; следующая —
  /// по курсору из пары `before` + `before_id`.
  Future<IncidentPage> incidents({
    int limit = 50,
    IncidentCursor? cursor,
    String? serviceId,
  });

  /// `GET /monitoring/self-check`.
  Future<SelfCheck> selfCheck();

  /// `POST /monitoring/telegram/test`: не чаще раза в 10 секунд.
  Future<TelegramTestResult> telegramTest();
}

/// [MonitoringApi] поверх [ApiClient]: закреплённый сертификат, токен доступа
/// и его обновление — как у остальных запросов.
class HttpMonitoringApi implements MonitoringApi {
  HttpMonitoringApi(this._client);

  final Future<ApiClient?> Function() _client;

  Future<ApiClient> _need() async {
    final client = await _client();
    if (client == null) throw const ApiException.notConfigured();
    return client;
  }

  @override
  Future<PulseFetch> pulse({String? etag}) async {
    final client = await _need();
    final result = await client.getJsonConditional(
      '/monitoring/pulse',
      etag: etag,
    );
    if (result.notModified) return const PulseFetch.notModified();
    final body = result.body;
    if (body == null || body.isEmpty) throw _emptySnapshot();
    return PulseFetch.fresh(PulseSnapshot.fromJson(body), result.etag, body);
  }

  @override
  Future<PulseFetch> refresh() async {
    final client = await _need();
    final body = await client.postJson('/monitoring/refresh');
    if (body.isEmpty) throw _emptySnapshot();
    return PulseFetch.fresh(PulseSnapshot.fromJson(body), null, body);
  }

  @override
  Future<IncidentPage> incidents({
    int limit = 50,
    IncidentCursor? cursor,
    String? serviceId,
  }) async {
    final client = await _need();
    final json = await client.getJson(
      '/monitoring/incidents',
      query: {
        'limit': limit,
        'before': ?cursor?.before,
        'before_id': ?cursor?.beforeId,
        'service_id': ?serviceId,
      },
    );
    return IncidentPage.fromJson(json);
  }

  @override
  Future<SelfCheck> selfCheck() async {
    final client = await _need();
    return SelfCheck.fromJson(await client.getJson('/monitoring/self-check'));
  }

  @override
  Future<TelegramTestResult> telegramTest() async {
    final client = await _need();
    return TelegramTestResult.fromJson(
      await client.postJson('/monitoring/telegram/test'),
    );
  }
}

/// `200` без тела — не снимок: его нельзя показывать и класть в кэш.
ApiException _emptySnapshot() =>
    const ApiException(kind: ApiErrorKind.malformed, status: 200);

final Provider<MonitoringApi> monitoringApiProvider = Provider<MonitoringApi>(
  (ref) => HttpMonitoringApi(ref.read(apiClientResolverProvider)),
);

/// Понятное сообщение об ошибке запроса к «Пульсу».
String monitoringErrorText(Object error) {
  if (error is ApiException) {
    if (error.isNetwork) return 'Нет связи с сервером.';
    if (error.kind == ApiErrorKind.notConfigured) {
      return 'Сервер не настроен: укажите адрес в настройках.';
    }
    final code = error.code;
    if (error.status == 429 || code == 'rate_limited') {
      final wait = error.retryAfter;
      return wait == null
          ? 'Слишком часто. Повторите чуть позже.'
          : 'Слишком часто. Повторите через ${wait.inSeconds} с.';
    }
    return switch (code) {
      'monitoring_not_configured' =>
        'Мониторинг на сервере не настроен: нет движка проверок.',
      'token_expired' ||
      'invalid_token' ||
      'not_authenticated' => 'Нужно войти заново.',
      _ =>
        error.isServerError
            ? 'Сервер ответил ошибкой. Повторите позже.'
            : 'Не удалось получить данные. Повторите позже.',
    };
  }
  return 'Не удалось получить данные. Повторите позже.';
}
