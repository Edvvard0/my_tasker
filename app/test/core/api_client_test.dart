import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/auth/auth_api.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/network/pinned_http_client.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_remote.dart';

import '../support/app_env.dart';
import '../support/fake_adapter.dart';

class _Tokens implements AccessTokenProvider {
  String? token = 't1';
  int refreshes = 0;
  String? next = 't2';
  final revoked = <String>[];

  @override
  Future<String?> currentAccessToken() async => token;

  @override
  Future<String?> refreshAfterUnauthorized(String? usedToken) async {
    refreshes++;
    token = next;
    return next;
  }

  @override
  Future<void> onDeviceRevoked(String code) async => revoked.add(code);
}

ApiClient _client(
  HttpClientAdapter adapter, {
  AccessTokenProvider? tokens,
  PinObserver? observer,
}) => ApiClient(
  dio: ApiClient.createDio(baseUrl: Uri.parse('http://x'), adapter: adapter),
  schemaVersion: 7,
  tokens: tokens,
  observer: observer,
);

class _Recording implements HttpClientAdapter {
  _Recording(this.handler);

  final ResponseBody Function(RequestOptions o) handler;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(
  int status,
  Object? body, {
  Map<String, List<String>>? headers,
}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
    ...?headers,
  },
);

void main() {
  group('ApiClient', () {
    test('заголовки протокола и Bearer', () async {
      final adapter = _Recording((_) => _json(200, {'ok': true}));
      final tokens = _Tokens();
      final result = await _client(adapter, tokens: tokens).getJson('/p');
      expect(result, {'ok': true});
      final h = adapter.seen.single.headers;
      expect(h['X-Client-Schema-Version'], '7');
      expect(h['Authorization'], 'Bearer t1');
    });

    test('auth: false — без токена', () async {
      final adapter = _Recording((_) => _json(200, {}));
      await _client(
        adapter,
        tokens: _Tokens(),
      ).postJson('/p', auth: false, body: {'a': 1});
      expect(adapter.seen.single.headers.containsKey('Authorization'), isFalse);
    });

    test('нет токена: 401 not_authenticated без запроса', () async {
      final adapter = _Recording((_) => _json(200, {}));
      final tokens = _Tokens()..token = null;
      await expectLater(
        _client(adapter, tokens: tokens).getJson('/p'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'not_authenticated',
          ),
        ),
      );
      expect(adapter.seen, isEmpty);
    });

    test('стандартная ошибка: code, message, details, статус', () async {
      final adapter = _Recording(
        (_) => _json(422, {
          'error': {
            'code': 'validation_error',
            'message': 'bad',
            'details': {'field': 'x'},
          },
        }),
      );
      await expectLater(
        _client(adapter).getJson('/p'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.status, 'status', 422)
              .having((e) => e.code, 'code', 'validation_error')
              .having((e) => e.message, 'message', 'bad')
              .having((e) => e.details, 'details', {'field': 'x'})
              .having((e) => e.isServerError, 'server', isFalse),
        ),
      );
    });

    test('ответ не JSON (прокси): код пустой, статус сохраняется', () async {
      final adapter = _Recording((_) => ResponseBody.fromString('<html>', 502));
      await expectLater(
        _client(adapter).getJson('/p'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', isNull)
              .having((e) => e.isServerError, 'server', isTrue),
        ),
      );
    });

    test('Retry-After из заголовка и из details', () async {
      final header = _Recording(
        (_) => _json(
          429,
          {
            'error': {'code': 'too_many_attempts', 'message': 'x'},
          },
          headers: {
            'retry-after': ['45'],
          },
        ),
      );
      await expectLater(
        _client(header).getJson('/p'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.retryAfter,
            'r',
            const Duration(seconds: 45),
          ),
        ),
      );
      final details = _Recording(
        (_) => _json(429, {
          'error': {
            'code': 'too_many_attempts',
            'message': 'x',
            'details': {'retry_after_seconds': 12},
          },
        }),
      );
      await expectLater(
        _client(details).getJson('/p'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.retryAfter,
            'r',
            const Duration(seconds: 12),
          ),
        ),
      );
    });

    test('204 и пустое тело', () async {
      final adapter = _Recording((_) => ResponseBody.fromString('', 204));
      final client = _client(adapter);
      await client.send('POST', '/x');
      expect(await client.getJson('/p'), isEmpty);
    });

    test('некорректный JSON в успешном ответе — malformed', () async {
      final adapter = _Recording((_) => ResponseBody.fromString('{oops', 200));
      await expectLater(
        _client(adapter).getJson('/p'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.malformed,
          ),
        ),
      );
    });

    test('401 token_expired: refresh и один повтор с новым токеном', () async {
      var calls = 0;
      final adapter = _Recording((o) {
        calls++;
        return calls == 1
            ? _json(401, {
                'error': {'code': 'token_expired', 'message': 'x'},
              })
            : _json(200, {'ok': o.headers['Authorization']});
      });
      final tokens = _Tokens();
      final result = await _client(adapter, tokens: tokens).getJson('/p');
      expect(result, {'ok': 'Bearer t2'});
      expect(tokens.refreshes, 1);
    });

    test(
      'после refresh снова 401: без бесконечного цикла, сообщается об отзыве',
      () async {
        final adapter = _Recording(
          (_) => _json(401, {
            'error': {'code': 'device_revoked', 'message': 'x'},
          }),
        );
        final tokens = _Tokens();
        await expectLater(
          _client(adapter, tokens: tokens).getJson('/p'),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'device_revoked'),
          ),
        );
        expect(tokens.refreshes, 0);
        expect(tokens.revoked, ['device_revoked']);
        final again = _Recording(
          (_) => _json(401, {
            'error': {'code': 'token_expired', 'message': 'x'},
          }),
        );
        final t2 = _Tokens();
        await expectLater(
          _client(again, tokens: t2).getJson('/p'),
          throwsA(isA<ApiException>()),
        );
        expect(t2.refreshes, 1);
        expect(again.seen, hasLength(2));
      },
    );

    test('refresh не удался (сессия завершена): исходная 401', () async {
      final adapter = _Recording(
        (_) => _json(401, {
          'error': {'code': 'token_expired', 'message': 'x'},
        }),
      );
      final tokens = _Tokens()..next = null;
      await expectLater(
        _client(adapter, tokens: tokens).getJson('/p'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'token_expired'),
        ),
      );
      expect(adapter.seen, hasLength(1));
    });

    test(
      'сетевые сбои: network; несовпадение сертификата — certMismatch',
      () async {
        final plain = FakeAdapter(const {}, error: connectionError);
        await expectLater(
          _client(plain).getJson('/p'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.kind,
              'kind',
              ApiErrorKind.network,
            ),
          ),
        );
        final observer = PinObserver();
        final pinned = FakeAdapter(
          const {},
          error: connectionError,
          beforeError: () => observer.mismatchDetected = true,
        );
        await expectLater(
          _client(pinned, observer: observer).getJson('/p'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.kind, 'kind', ApiErrorKind.certMismatch)
                .having((e) => e.isNetwork, 'network', isTrue),
          ),
        );
      },
    );

    test('отмена запроса — сетевая ошибка', () async {
      final adapter = FakeAdapter(
        const {},
        error: (o) =>
            DioException.requestCancelled(requestOptions: o, reason: 'x'),
      );
      await expectLater(
        _client(adapter).getJson('/p'),
        throwsA(
          isA<ApiException>().having((e) => e.isNetwork, 'network', isTrue),
        ),
      );
    });

    test('openStream отдаёт байты; ошибочный статус — ApiException', () async {
      final ok = _Recording(
        (_) => ResponseBody(
          Stream.value(Uint8List.fromList(utf8.encode('hello'))),
          200,
        ),
      );
      final bytes = await (await _client(
        ok,
        tokens: _Tokens(),
      ).openStream('/events')).toList();
      expect(utf8.decode(bytes.expand((b) => b).toList()), 'hello');
      expect(ok.seen.single.headers['Accept'], 'text/event-stream');
      final bad = _Recording(
        (_) => ResponseBody.fromString(
          jsonEncode({
            'error': {'code': 'client_too_old', 'message': 'x'},
          }),
          426,
        ),
      );
      await expectLater(
        _client(bad, tokens: _Tokens()).openStream('/events'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 426)),
      );
      final revoked = _Recording(
        (_) => ResponseBody.fromString(
          jsonEncode({
            'error': {'code': 'device_revoked', 'message': 'x'},
          }),
          401,
        ),
      );
      final tokens = _Tokens();
      await expectLater(
        _client(revoked, tokens: tokens).openStream('/events'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'device_revoked'),
        ),
      );
      expect(tokens.revoked, ['device_revoked']);
    });

    test('describeApiError не раскрывает тела', () {
      expect(
        describeApiError(
          const ApiException(kind: ApiErrorKind.http, status: 500, code: 'x'),
        ),
        'http 500 x',
      );
      expect(const ApiException.network().toString(), contains('network'));
    });
  });

  group('AuthApi', () {
    late AppEnv env;
    setUp(() async => env = await AppEnv.create(signedIn: true));
    tearDown(() => env.dispose());

    test('devices: список, текущее и отозванные', () async {
      final api = env.container.read(authApiProvider)!;
      final list = await api.devices();
      expect(list.single.isCurrent, isTrue);
      await api.revokeDevice(list.single.id);
      // отозванное текущее устройство: 401 device_revoked и выход
      await expectLater(api.devices(), throwsA(isA<ApiException>()));
    });

    test('revokeDevice: 404 device_not_found', () async {
      final api = env.container.read(authApiProvider)!;
      await expectLater(
        api.revokeDevice('0195f2a0-0000-7000-8000-00000000000a'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'device_not_found'),
        ),
      );
    });

    test('devices: некорректный ответ — malformed', () async {
      final api = AuthApi(
        _client(_Recording((_) => _json(200, {'devices': 5}))),
      );
      await expectLater(
        api.devices(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.malformed,
          ),
        ),
      );
      final login = AuthApi(_client(_Recording((_) => _json(200, {'x': 1}))));
      await expectLater(
        login.refresh('r'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.malformed,
          ),
        ),
      );
    });
  });

  group('HttpSyncRemote', () {
    late AppEnv env;
    late HttpSyncRemote remote;
    setUp(() async {
      env = await AppEnv.create(signedIn: true);
      remote = env.container.read(syncRemoteProvider) as HttpSyncRemote;
    });
    tearDown(() => env.dispose());

    test('push и pull по HTTP: те же формы, что в spec 3.3 и 3.6', () async {
      final store = env.container.read(syncStoreProvider);
      await store.create('notes', '01a0f213-ebad-7800-82c5-bb2026900f15', {
        'title': 'x',
      });
      final batch = await store.takeBatch();
      final pushed = await remote.push([for (final o in batch) o.toWire()]);
      expect(pushed.results.single.applied, isTrue);
      expect(pushed.headVersion, 1);
      final page = await remote.pull(since: 0, limit: 10);
      expect(page.changes.single.table, 'notes');
      expect(page.nextSince, 1);
      expect(page.hasMore, isFalse);
      final conflicts = await remote.conflicts(reverted: 'false', limit: 5);
      expect(conflicts.conflicts, isEmpty);
      await expectLater(
        remote.revert('nope'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'conflict_not_found',
          ),
        ),
      );
      expect(env.backend.requests, contains('GET /sync/pull'));
    });

    test('без настроенного сервера — notConfigured', () async {
      final none = HttpSyncRemote(() => null);
      await expectLater(
        none.pull(since: 0, limit: 1),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.notConfigured,
          ),
        ),
      );
    });

    test('ответ неверной формы — malformed', () async {
      final bad = HttpSyncRemote(
        () => _client(_Recording((_) => _json(200, {'changes': 1}))),
      );
      await expectLater(
        bad.pull(since: 0, limit: 1),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.malformed,
          ),
        ),
      );
      await expectLater(bad.push([]), throwsA(isA<ApiException>()));
      await expectLater(bad.conflicts(), throwsA(isA<ApiException>()));
      await expectLater(bad.revert('x'), throwsA(isA<ApiException>()));
    });
  });

  group('модели ответов', () {
    test('PullPage/PushResponse/SyncConflict разбирают все форматы дат', () {
      final page = PullPage.fromJson(const {
        'changes': [
          {
            'table': 't',
            'id': 'i',
            'server_version': 3,
            'row': {'id': 'i'},
          },
        ],
        'next_since': 3,
        'has_more': true,
        'head_version': 9,
        'purge_watermark': 2,
      });
      expect(page.hasMore, isTrue);
      expect(page.purgeWatermark, 2);
      final conflict = SyncConflict.fromJson(const {
        'id': 'c',
        'created_at': '2026-10-01T10:00:00Z',
        'table': 't',
        'row_id': 'r',
        'field': 'deleted_at',
        'kind': 'parent_deleted',
        'losing_value': null,
        'winning_value': {'deleted_at': 'x'},
        'reverted_at': '2026-10-01T10:00:00.123456Z',
      });
      expect(conflict.canRevert, isFalse);
      expect(conflict.isReverted, isTrue);
      expect(ConflictKind.parse('weird'), ConflictKind.unknown);
      const s = OutboxSummary(pending: 1, inFlight: 2, rejected: 3);
      expect(s.unsent, 3);
      expect(s, const OutboxSummary(pending: 1, inFlight: 2, rejected: 3));
      expect(
        s.hashCode,
        const OutboxSummary(pending: 1, inFlight: 2, rejected: 3).hashCode,
      );
    });
  });
}
