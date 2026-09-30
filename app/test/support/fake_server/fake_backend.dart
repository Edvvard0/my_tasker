import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';

import 'fake_sync_server.dart';

class _Device {
  _Device(this.id, this.name, this.platform, this.appVersion, this.createdAt);

  final String id;
  final String name;
  final String platform;
  final String? appVersion;
  final DateTime createdAt;
  DateTime? lastSeen;
  DateTime? revokedAt;
}

class _Token {
  _Token(this.deviceId, this.expires);

  final String deviceId;
  DateTime expires;
}

class _Refresh {
  _Refresh(this.deviceId, this.expires);

  final String deviceId;
  final DateTime expires;
  bool used = false;
}

class _Fault {
  _Fault(this.prefix, this.count, {required this.afterProcessing});

  final String prefix;
  int count;
  final bool afterProcessing;
}

class _SseConnection {
  _SseConnection(this.deviceId);

  final String deviceId;
  final StreamController<Uint8List> controller = StreamController<Uint8List>();
}

/// Сервер целиком (вход, устройства, синхронизация, SSE) как адаптер Dio:
/// клиентский стек — `ApiClient`, `AuthController`, `HttpSyncRemote` —
/// работает с ним так же, как с настоящим бэкендом по spec 0–6.
class FakeBackend implements HttpClientAdapter {
  FakeBackend({
    required this.server,
    required this.now,
    this.password = 'correct-password',
    this.totpCode = '123456',
    this.minClientSchema = 1,
  }) {
    _commitSub = server.commits.listen((commit) {
      for (final c in _sse.toList()) {
        if (c.deviceId != commit.origin && !c.controller.isClosed) {
          c.controller.add(_frame('changes', {'head_version': commit.head}));
        }
      }
    });
  }

  final FakeSyncServer server;
  final DateTime Function() now;
  final String password;
  final String totpCode;
  int minClientSchema;
  Duration accessTtl = const Duration(minutes: 15);
  Duration refreshTtl = const Duration(days: 90);

  final Map<String, _Device> _devices = {};
  final Map<String, _Token> _access = {};
  final Map<String, _Refresh> _refresh = {};
  final List<_Fault> _faults = [];
  final List<_SseConnection> _sse = [];
  late final StreamSubscription<Object?> _commitSub;
  int _tokenCounter = 0;
  int _failedLogins = 0;

  /// Журнал запросов вида `POST /sync/push`.
  final List<String> requests = [];
  final List<String> authHeaders = [];
  int loginCalls = 0;
  int refreshCalls = 0;

  /// Пока не завершён, ответ на `/auth/refresh` задерживается.
  Completer<void>? holdRefresh;

  /// Пока не завершён, ответ на `/auth/login` задерживается.
  Completer<void>? holdLogin;

  // ---- управление из тестов ---------------------------------------------------

  /// Следующие [count] запросов с путём на [prefix] обрываются. При
  /// [afterProcessing] сервер обработает запрос, а ответ «потеряется».
  void failNext(String prefix, {int count = 1, bool afterProcessing = false}) =>
      _faults.add(_Fault(prefix, count, afterProcessing: afterProcessing));

  void expireAccessTokens() {
    for (final t in _access.values) {
      t.expires = now().subtract(const Duration(seconds: 1));
    }
  }

  void revokeDevice(String id) {
    _devices[id]?.revokedAt = now();
    for (final c in _sse.where((c) => c.deviceId == id).toList()) {
      c.controller.add(_frame('revoked', const {}));
      unawaited(c.controller.close());
      _sse.remove(c);
    }
  }

  List<String> get deviceIds => _devices.keys.toList();

  int get sseConnections => _sse.length;

  void sendSse(String event, Map<String, Object?> data) {
    for (final c in _sse) {
      c.controller.add(_frame(event, data));
    }
  }

  void sendRaw(String text) {
    for (final c in _sse) {
      c.controller.add(Uint8List.fromList(utf8.encode(text)));
    }
  }

  void closeSseStreams() {
    for (final c in _sse.toList()) {
      unawaited(c.controller.close());
    }
    _sse.clear();
  }

  static Uint8List _frame(String event, Map<String, Object?> data) =>
      Uint8List.fromList(
        utf8.encode('event: $event\ndata: ${jsonEncode(data)}\n\n'),
      );

  // ---- HttpClientAdapter ----------------------------------------------------

  @override
  void close({bool force = false}) {
    unawaited(_commitSub.cancel());
    closeSseStreams();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.path;
    requests.add('${options.method} $path');
    authHeaders.add('${options.headers['Authorization']}');
    _Fault? fault;
    for (final f in _faults) {
      if (f.count > 0 && path.startsWith(f.prefix)) {
        f.count--;
        fault = f;
        break;
      }
    }
    if (fault != null && !fault.afterProcessing) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'injected',
      );
    }
    final response = await _dispatch(options);
    if (fault != null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'response lost',
      );
    }
    return response;
  }

  ResponseBody _json(
    int status,
    Object? body, {
    Map<String, String>? headers,
  }) => ResponseBody.fromString(
    body == null ? '' : jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      for (final e in (headers ?? {}).entries) e.key: [e.value],
    },
  );

  ResponseBody _error(
    int status,
    String code, [
    Map<String, Object?>? details,
    Map<String, String>? headers,
  ]) => _json(status, {
    'error': {'code': code, 'message': code, 'details': details ?? {}},
  }, headers: headers);

  Future<ResponseBody> _dispatch(RequestOptions o) async {
    final path = o.path;
    final method = o.method;
    if (path == '/health/ready') return _json(200, {'status': 'ok'});
    if (path == '/version') {
      return _json(200, {
        'app_version': '9.9.9',
        'api_schema_version': 1,
        'min_client_schema_version': minClientSchema,
        'server_epoch': ?server.epoch,
      });
    }
    final schema = int.tryParse('${o.headers['X-Client-Schema-Version']}');
    if (schema == null) return _error(400, 'schema_version_required');
    if (schema < minClientSchema) {
      return _error(426, 'client_too_old', {
        'min_client_schema_version': minClientSchema,
        'api_schema_version': 1,
      });
    }
    final body = o.data is Map
        ? (o.data as Map).cast<String, Object?>()
        : <String, Object?>{};
    if (method == 'POST' && path == '/auth/login') {
      await holdLogin?.future;
      return _login(body);
    }
    if (method == 'POST' && path == '/auth/refresh') {
      await holdRefresh?.future;
      return _refreshToken(body);
    }

    final auth = _authenticate(o);
    if (auth.$2 != null) return auth.$2!;
    final device = auth.$1!..lastSeen = now();

    switch ((method, path)) {
      case ('POST', '/auth/logout'):
        device.revokedAt = now();
        return ResponseBody.fromString('', 204);
      case ('GET', '/auth/devices'):
        final includeRevoked =
            '${o.queryParameters['include_revoked']}' == 'true';
        return _json(200, {
          'devices': [
            for (final d in _devices.values)
              if (includeRevoked || d.revokedAt == null)
                {
                  'id': d.id,
                  'name': d.name,
                  'platform': d.platform,
                  'app_version': d.appVersion,
                  'created_at': d.createdAt.toUtc().toIso8601String(),
                  'last_seen_at': d.lastSeen?.toUtc().toIso8601String(),
                  'last_pulled_version': server.deviceCursors[d.id],
                  'revoked_at': d.revokedAt?.toUtc().toIso8601String(),
                  'is_current': d.id == device.id,
                },
          ],
        });
      case ('GET', '/sync/pull'):
        try {
          return _json(
            200,
            server.pull(
              device.id,
              int.parse('${o.queryParameters['since']}'),
              int.parse('${o.queryParameters['limit'] ?? 500}'),
            ),
          );
        } on Object catch (e) {
          return _apiError(e);
        }
      case ('POST', '/sync/push'):
        try {
          final ops = body['ops'];
          if (ops is! List) return _error(422, 'validation_error');
          return _json(200, server.push(device.id, ops));
        } on Object catch (e) {
          return _apiError(e);
        }
      case ('GET', '/sync/conflicts'):
        return _json(
          200,
          server.conflictsPage(
            reverted: '${o.queryParameters['reverted'] ?? 'all'}',
            limit: int.parse('${o.queryParameters['limit'] ?? 50}'),
            before: o.queryParameters['before'] as String?,
          ),
        );
      case ('GET', '/events'):
        final connection = _SseConnection(device.id);
        _sse.add(connection);
        connection.controller.add(
          _frame('hello', {'head_version': server.head}),
        );
        return ResponseBody(
          connection.controller.stream,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          },
        );
    }
    final revert = RegExp(r'^/sync/conflicts/([^/]+)/revert$').firstMatch(path);
    if (method == 'POST' && revert != null) {
      try {
        return _json(200, server.revert(device.id, revert[1]!));
      } on Object catch (e) {
        return _apiError(e);
      }
    }
    final del = RegExp(r'^/auth/devices/([^/]+)$').firstMatch(path);
    if (method == 'DELETE' && del != null) {
      final target = _devices[del[1]];
      if (target == null) return _error(404, 'device_not_found');
      revokeDevice(target.id);
      return ResponseBody.fromString('', 204);
    }
    return _error(404, 'not_found');
  }

  ResponseBody _apiError(Object e) {
    if (e is ApiException) return _error(e.status!, e.code!, e.details);
    // Не ошибка API (например, обрыв связи): пробрасываем как есть.
    // ignore: only_throw_errors
    throw e;
  }

  ResponseBody _login(Map<String, Object?> body) {
    loginCalls++;
    if (_failedLogins >= 5) {
      return _error(
        429,
        'too_many_attempts',
        {'retry_after_seconds': 30},
        {'Retry-After': '30'},
      );
    }
    final device = body['device'];
    if (body['password'] != password ||
        body['totp_code'] != totpCode ||
        device is! Map) {
      _failedLogins++;
      return _error(401, 'invalid_credentials');
    }
    _failedLogins = 0;
    final id = uuid7();
    final created = _Device(
      id,
      '${device['name']}',
      '${device['platform']}',
      device['app_version'] as String?,
      now(),
    );
    _devices[id] = created;
    return _json(200, _issue(id));
  }

  Json _issue(String deviceId) {
    _tokenCounter++;
    final access = 'at-$_tokenCounter-${uuid7()}';
    final refresh = 'rt-$_tokenCounter-${uuid7()}';
    final accessExpires = now().add(accessTtl);
    final refreshExpires = now().add(refreshTtl);
    _access[access] = _Token(deviceId, accessExpires);
    _refresh[refresh] = _Refresh(deviceId, refreshExpires);
    return {
      'device_id': deviceId,
      'server_epoch': ?server.epoch,
      'token_type': 'Bearer',
      'access_token': access,
      'access_expires_at': accessExpires.toUtc().toIso8601String(),
      'refresh_token': refresh,
      'refresh_expires_at': refreshExpires.toUtc().toIso8601String(),
    };
  }

  ResponseBody _refreshToken(Map<String, Object?> body) {
    refreshCalls++;
    final token = _refresh[body['refresh_token']];
    if (token == null) return _error(401, 'invalid_refresh_token');
    final device = _devices[token.deviceId]!;
    if (device.revokedAt != null) return _error(401, 'device_revoked');
    if (token.used) {
      device.revokedAt = now();
      return _error(401, 'refresh_reuse_detected');
    }
    if (!token.expires.isAfter(now())) return _error(401, 'refresh_expired');
    token.used = true;
    return _json(200, _issue(token.deviceId));
  }

  (_Device?, ResponseBody?) _authenticate(RequestOptions o) {
    final header = '${o.headers['Authorization'] ?? ''}';
    if (!header.startsWith('Bearer ')) {
      return (null, _error(401, 'not_authenticated'));
    }
    final token = _access[header.substring(7)];
    if (token == null) return (null, _error(401, 'invalid_token'));
    final device = _devices[token.deviceId]!;
    if (device.revokedAt != null) return (null, _error(401, 'device_revoked'));
    if (!token.expires.isAfter(now())) {
      return (null, _error(401, 'token_expired'));
    }
    return (device, null);
  }
}

/// Проверка формата HLC для тестов (обёртка над клиентским кодом).
bool hlcLooksValid(String value) => isValidHlc(value);
