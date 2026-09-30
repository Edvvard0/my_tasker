import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Ответ фейкового HTTP-адаптера: статус + JSON, либо ошибка.
class FakeResponse {
  const FakeResponse(this.status, [this.body]);

  final int status;
  final Object? body;
}

/// Адаптер Dio для тестов: отвечает по маршруту (`GET /path`) или бросает
/// [DioException] (например, имитируя обрыв соединения).
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.routes, {this.error, this.beforeError});

  final Map<String, FakeResponse> routes;

  /// Если задан — любой запрос завершается этой ошибкой.
  final DioException Function(RequestOptions)? error;

  /// Хук перед выбросом ошибки (например, отметить mismatch в PinObserver).
  final void Function()? beforeError;

  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add('${options.method} ${options.path}');
    if (error != null) {
      beforeError?.call();
      throw error!(options);
    }
    final route = routes['${options.method} ${options.path}'];
    if (route == null) return ResponseBody.fromString('not found', 404);
    return ResponseBody.fromString(
      route.body == null ? '' : jsonEncode(route.body),
      route.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Стандартная ошибка соединения.
DioException connectionError(RequestOptions o) =>
    DioException.connectionError(requestOptions: o, reason: 'test');
