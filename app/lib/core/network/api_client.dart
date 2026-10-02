import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/network/pinned_http_client.dart';

/// Причина сбоя запроса.
enum ApiErrorKind {
  /// Сервер вернул ошибку в стандартной форме (`error.code`).
  http,

  /// Нет соединения, таймаут, обрыв.
  network,

  /// Сервер предъявил сертификат не от закреплённого УЦ.
  certMismatch,

  /// Ответ не разобран (не JSON, нет нужных полей).
  malformed,

  /// Адрес сервера не настроен.
  notConfigured,
}

/// Ошибка обращения к серверу. Клиент ветвится **только по [code]**
/// (spec 0); [message] — справочный английский текст сервера.
class ApiException implements Exception {
  const ApiException({
    required this.kind,
    this.status,
    this.code,
    this.message,
    this.details = const {},
    this.retryAfter,
  });

  const ApiException.network([String? message])
    : this(kind: ApiErrorKind.network, message: message);

  const ApiException.notConfigured()
    : this(kind: ApiErrorKind.notConfigured, code: 'not_configured');

  final ApiErrorKind kind;
  final int? status;
  final String? code;
  final String? message;
  final Map<String, Object?> details;

  /// Пауза перед повтором (`429`).
  final Duration? retryAfter;

  bool get isNetwork =>
      kind == ApiErrorKind.network || kind == ApiErrorKind.certMismatch;

  bool get isServerError => status != null && status! >= 500;

  @override
  String toString() => 'ApiException($kind, status: $status, code: $code)';
}

/// Источник токена доступа для [ApiClient]. Реализует сессия входа.
abstract interface class AccessTokenProvider {
  /// Текущий токен; просроченный обновляется заранее. `null` — вход не
  /// выполнен.
  Future<String?> currentAccessToken();

  /// После `401`: обновляет токены **один раз** для всех параллельных
  /// запросов ([usedToken] — токен, с которым запрос не прошёл). Возвращает
  /// новый токен или `null`, если сессия завершена.
  Future<String?> refreshAfterUnauthorized(String? usedToken);

  /// Сервер сообщил, что устройство отозвано.
  Future<void> onDeviceRevoked(String code);
}

/// Коды `401`, после которых имеет смысл обновить токен и повторить запрос.
const Set<String> _refreshableCodes = {
  'token_expired',
  'invalid_token',
  'not_authenticated',
};

/// HTTP-клиент API: заголовки протокола, разбор ошибок, обновление токена
/// при `401` (один повтор), нормализация сетевых сбоев.
class ApiClient {
  ApiClient({
    required this._dio,
    required this.schemaVersion,
    this.tokens,
    this.observer,
  });

  final Dio _dio;

  /// `X-Client-Schema-Version` (spec 0).
  final int schemaVersion;
  final AccessTokenProvider? tokens;
  final PinObserver? observer;

  /// Создаёт Dio с валидатором «принимаем любой статус»: разбор в клиенте.
  static Dio createDio({
    required Uri baseUrl,
    required HttpClientAdapter adapter,
    Duration connectTimeout = const Duration(seconds: 10),
    Duration receiveTimeout = const Duration(seconds: 30),
  }) => Dio(
    BaseOptions(
      baseUrl: baseUrl.toString(),
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: receiveTimeout,
      validateStatus: (_) => true,
      responseType: ResponseType.plain,
    ),
  )..httpClientAdapter = adapter;

  Future<Map<String, Object?>> getJson(
    String path, {
    Map<String, Object?>? query,
    bool auth = true,
  }) => _json('GET', path, query: query, auth: auth);

  Future<Map<String, Object?>> postJson(
    String path, {
    Object? body,
    bool auth = true,
  }) => _json('POST', path, body: body, auth: auth);

  /// `DELETE` / `POST` без тела в ответе (`204`).
  Future<void> send(String method, String path, {bool auth = true}) async {
    await _request(method, path, auth: auth);
  }

  /// Долгоживущий ответ (SSE): поток байтов тела. Ошибочные статусы
  /// превращаются в [ApiException] после чтения короткого тела.
  Future<Stream<List<int>>> openStream(String path) async {
    final response = await _request(
      'GET',
      path,
      stream: true,
      headers: {'Accept': 'text/event-stream', 'Cache-Control': 'no-cache'},
    );
    final body = response.data! as ResponseBody;
    return body.stream;
  }

  /// `POST` с потоковым ответом (SSE ответа ИИ, Этап 3): тело запроса —
  /// JSON, ответ — поток байтов. Обрыв соединения (отмена ответа) —
  /// `cancelToken.cancel()`: простая отмена подписки на поток соединение
  /// не закрывает.
  Future<Stream<List<int>>> openPostStream(
    String path,
    Object body, {
    CancelToken? cancelToken,
  }) async {
    final response = await _request(
      'POST',
      path,
      body: body,
      stream: true,
      cancelToken: cancelToken,
      headers: {'Accept': 'text/event-stream', 'Cache-Control': 'no-cache'},
    );
    final data = response.data! as ResponseBody;
    return data.stream;
  }

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? body,
    bool auth = true,
  }) async {
    final response = await _request(
      method,
      path,
      query: query,
      body: body,
      auth: auth,
    );
    final data = response.data;
    if (data is Map) return data.cast<String, Object?>();
    if (data is! String || data.isEmpty) return const {};
    try {
      return (jsonDecode(data) as Map).cast<String, Object?>();
    } on Object {
      throw ApiException(
        kind: ApiErrorKind.malformed,
        status: response.statusCode,
      );
    }
  }

  Future<Response<Object?>> _request(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? body,
    bool auth = true,
    bool stream = false,
    Map<String, Object?> headers = const {},
    CancelToken? cancelToken,
  }) async {
    var token = auth ? await tokens?.currentAccessToken() : null;
    if (auth && token == null && tokens != null) {
      throw const ApiException(
        kind: ApiErrorKind.http,
        status: 401,
        code: 'not_authenticated',
      );
    }
    var response = await _raw(
      method,
      path,
      query: query,
      body: body,
      token: token,
      stream: stream,
      headers: headers,
      cancelToken: cancelToken,
    );
    ApiException? error;
    if (auth && response.statusCode == 401 && tokens != null) {
      error = await _error(response);
      if (_refreshableCodes.contains(error.code)) {
        final fresh = await tokens!.refreshAfterUnauthorized(token);
        if (fresh == null) throw error;
        token = fresh;
        error = null;
        response = await _raw(
          method,
          path,
          query: query,
          body: body,
          token: token,
          stream: stream,
          headers: headers,
          cancelToken: cancelToken,
        );
      }
    }
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return response;
    error ??= await _error(response);
    if (status == 401 && auth && tokens != null) {
      await tokens!.onDeviceRevoked(error.code ?? 'unauthorized');
    }
    throw error;
  }

  Future<Response<Object?>> _raw(
    String method,
    String path, {
    required String? token,
    Map<String, Object?>? query,
    Object? body,
    bool stream = false,
    Map<String, Object?> headers = const {},
    CancelToken? cancelToken,
  }) async {
    try {
      return await _dio.request<Object?>(
        path,
        data: body,
        queryParameters: query,
        cancelToken: cancelToken,
        options: Options(
          method: method,
          responseType: stream ? ResponseType.stream : ResponseType.plain,
          receiveTimeout: stream ? Duration.zero : null,
          contentType: body == null ? null : Headers.jsonContentType,
          headers: {
            'X-Client-Schema-Version': '$schemaVersion',
            'Authorization': ?(token == null ? null : 'Bearer $token'),
            ...headers,
          },
        ),
      );
    } on DioException catch (e) {
      throw switch (e.type) {
        DioExceptionType.cancel => const ApiException.network('cancelled'),
        _ =>
          (observer?.mismatchDetected ?? false)
              ? const ApiException(kind: ApiErrorKind.certMismatch)
              : ApiException.network(e.type.name),
      };
    }
  }

  /// Разбирает тело ошибки стандартной формы (spec 0).
  Future<ApiException> _error(Response<Object?> response) async {
    final status = response.statusCode;
    String? code;
    String? message;
    var details = <String, Object?>{};
    final data = response.data;
    Object? decoded;
    if (data is Map) {
      decoded = data;
    } else if (data is String && data.isNotEmpty) {
      decoded = _tryDecode(data);
    } else if (data is ResponseBody) {
      final bytes = <int>[];
      await for (final chunk in data.stream) {
        bytes.addAll(chunk);
        if (bytes.length > 64 * 1024) break;
      }
      decoded = _tryDecode(utf8.decode(bytes, allowMalformed: true));
    }
    final error = decoded is Map ? decoded['error'] : null;
    if (error is Map) {
      code = error['code'] as String?;
      message = error['message'] as String?;
      final d = error['details'];
      if (d is Map) details = d.cast<String, Object?>();
    }
    final retryHeader = int.tryParse(
      response.headers.value('retry-after') ?? '',
    );
    final retrySeconds =
        retryHeader ?? (details['retry_after_seconds'] as int?);
    return ApiException(
      kind: ApiErrorKind.http,
      status: status,
      code: code,
      message: message,
      details: details,
      retryAfter: retrySeconds == null ? null : Duration(seconds: retrySeconds),
    );
  }

  static Object? _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } on Object {
      return null; // не JSON (прокси, HTML): код остаётся пустым
    }
  }

  void close() => _dio.close(force: true);
}

/// Печатает ошибку без данных запроса (для журналов и экрана статуса).
@visibleForTesting
String describeApiError(ApiException e) =>
    '${e.kind.name}${e.status == null ? '' : ' ${e.status}'}'
    '${e.code == null ? '' : ' ${e.code}'}';
