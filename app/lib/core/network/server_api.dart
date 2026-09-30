import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Ответ `GET /version`.
@immutable
class ServerVersion {
  const ServerVersion({
    required this.appVersion,
    required this.apiSchemaVersion,
    required this.minClientSchemaVersion,
  });

  factory ServerVersion.fromJson(Map<String, dynamic> json) => ServerVersion(
    appVersion: json['app_version'] as String,
    apiSchemaVersion: json['api_schema_version'] as int,
    minClientSchemaVersion: json['min_client_schema_version'] as int,
  );

  final String appVersion;
  final int apiSchemaVersion;
  final int minClientSchemaVersion;
}

/// Тонкая обёртка над Dio для эндпоинтов, нужных на этапе 0.
class ServerApi {
  ServerApi(this._dio);

  /// Создаёт Dio для [baseUrl] с заданным адаптером и короткими таймаутами.
  factory ServerApi.create({
    required Uri baseUrl,
    required HttpClientAdapter adapter,
    Duration timeout = const Duration(seconds: 6),
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl.toString(),
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        // 503 у /health/ready — штатный ответ «не готов», не исключение.
        validateStatus: (status) => status != null && status < 600,
      ),
    )..httpClientAdapter = adapter;
    return ServerApi(dio);
  }

  final Dio _dio;

  /// `GET /health/ready`: `true` при 200, `false` при 503/иных статусах.
  Future<bool> isReady() async {
    final response = await _dio.get<Object?>('/health/ready');
    return response.statusCode == 200;
  }

  /// `GET /version`.
  Future<ServerVersion> version() async {
    final response = await _dio.get<Map<String, dynamic>>('/version');
    final data = response.data;
    if (response.statusCode != 200 || data == null) {
      throw DioException.badResponse(
        statusCode: response.statusCode ?? 0,
        requestOptions: response.requestOptions,
        response: response,
      );
    }
    return ServerVersion.fromJson(data);
  }

  void close() => _dio.close(force: true);
}
