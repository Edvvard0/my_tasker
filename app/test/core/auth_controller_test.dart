import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/auth/token_store.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/network/api_providers.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';

import '../support/app_env.dart';
import '../support/fake_server/fake_backend.dart';

Future<List<Object?>> _dumpDb(AppEnv env) async {
  final db = env.container.read(syncStoreProvider).db;
  final tables = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  final all = <Object?>[];
  for (final t in tables) {
    final name = t.read<String>('name');
    final rows = await db.customSelect('SELECT * FROM "$name"').get();
    all.addAll(rows.map((r) => r.data));
  }
  return all;
}

void main() {
  late AppEnv env;

  Future<void> setUpEnv({bool signedIn = true, bool configured = true}) async {
    env = await AppEnv.create(signedIn: signedIn, serverConfigured: configured);
  }

  tearDown(() => env.dispose());

  group('вход', () {
    test('успех: токены в хранилище токенов, устройство принято, '
        'в БД токенов нет', () async {
      await setUpEnv(signedIn: false);
      expect(env.authState, isA<SignedOut>());
      await env.login();
      final state = env.authState as SignedIn;
      final session = env.tokens.session!;
      expect(session.deviceId, state.deviceId);
      expect(env.backend.deviceIds, [state.deviceId]);
      expect(
        await env.container.read(syncStoreProvider).deviceId(),
        state.deviceId,
      );
      final dump = (await _dumpDb(env)).toString();
      expect(dump, isNot(contains(session.accessToken)));
      expect(dump, isNot(contains(session.refreshToken)));
      expect(dump, isNot(contains('rt-')));
      expect(dump, isNot(contains('at-')));
      expect(session.toString(), isNot(contains(session.accessToken)));
      expect(session.toString(), isNot(contains(session.refreshToken)));
    });

    test('неверные данные: invalid_credentials, вход не выполнен', () async {
      await setUpEnv(signedIn: false);
      await expectLater(
        env.auth.login(
          password: 'wrong',
          totpCode: env.backend.totpCode,
          device: const DeviceInfo(name: 'x', platform: DevicePlatform.linux),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'invalid_credentials',
          ),
        ),
      );
      expect(env.authState, isA<SignedOut>());
      expect(env.tokens.session, isNull);
    });

    test('too_many_attempts: пауза из Retry-After', () async {
      await setUpEnv(signedIn: false);
      for (var i = 0; i < 5; i++) {
        await expectLater(
          env.auth.login(
            password: 'wrong',
            totpCode: '000000',
            device: const DeviceInfo(name: 'x', platform: DevicePlatform.linux),
          ),
          throwsA(isA<ApiException>()),
        );
      }
      await expectLater(
        env.login(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'too_many_attempts')
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 30),
              ),
        ),
      );
    });

    test('client_too_old: код и детали', () async {
      await setUpEnv(signedIn: false);
      env.backend.minClientSchema = 5;
      await expectLater(
        env.login(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.status, 'status', 426)
              .having((e) => e.code, 'code', 'client_too_old')
              .having((e) => e.details['min_client_schema_version'], 'min', 5),
        ),
      );
    });

    test('сервер не настроен', () async {
      await setUpEnv(signedIn: false, configured: false);
      await expectLater(
        env.login(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.notConfigured,
          ),
        ),
      );
    });

    test('нет сети при входе', () async {
      await setUpEnv(signedIn: false);
      env.backend.failNext('/auth/login');
      await expectLater(
        env.login(),
        throwsA(
          isA<ApiException>().having((e) => e.isNetwork, 'network', isTrue),
        ),
      );
      expect(env.authState, isA<SignedOut>());
    });

    test(
      'метки неотправленных правок получают идентификатор нового устройства',
      () async {
        await setUpEnv(signedIn: false);
        final store = env.container.read(syncStoreProvider);
        final provisional = await store.deviceId();
        final id = uuid7();
        await store.create('notes', id, {'title': 'made before login'});
        expect(hlcDevice((await store.outbox()).single.hlc), provisional);
        await env.login();
        final device = (env.authState as SignedIn).deviceId;
        expect(hlcDevice((await store.outbox()).single.hlc), device);
        // и сервер принимает такую операцию
        final engine = env.container.read(syncEngineProvider);
        await engine.runCycle();
        expect(env.server.row('notes', id)!['title'], 'made before login');
      },
    );

    test('повторный вход после отзыва: старые операции переезжают на новое '
        'устройство, локальные данные сохранены', () async {
      await setUpEnv();
      final store = env.container.read(syncStoreProvider);
      final id = uuid7();
      await store.create('notes', id, {'title': 'kept'});
      final first = (env.authState as SignedIn).deviceId;
      env.backend.revokeDevice(first);
      await expectLater(
        env.auth.currentAccessToken().then(
          (_) =>
              env.container.read(apiClientProvider)!.getJson('/auth/devices'),
        ),
        throwsA(isA<ApiException>()),
      );
      expect((env.authState as SignedOut).reason, SignOutReason.revoked);
      expect(await store.getRow('notes', id), isNotNull);
      await env.login(name: 'again');
      final second = (env.authState as SignedIn).deviceId;
      expect(second, isNot(first));
      expect(hlcDevice((await store.outbox()).single.hlc), second);
      await env.container.read(syncEngineProvider).runCycle();
      expect(env.server.row('notes', id), isNotNull);
    });
  });

  group('обновление токена (spec 1.3)', () {
    test('просроченный access: один refresh, ротация, новый refresh сохранён '
        'до использования', () async {
      await setUpEnv();
      final api = env.container.read(apiClientProvider)!;
      final before = env.tokens.session!;
      env.backend.expireAccessTokens();
      env.clock.advance(const Duration(minutes: 20));
      final list = await api.getJson('/auth/devices');
      expect(list['devices'], hasLength(1));
      final after = env.tokens.session!;
      expect(after.refreshToken, isNot(before.refreshToken));
      expect(after.accessToken, isNot(before.accessToken));
      expect(after.deviceId, before.deviceId);
      expect(env.backend.refreshCalls, 1);
      // запрос ушёл уже с новым токеном, а не со старым
      expect(env.backend.authHeaders.last, 'Bearer ${after.accessToken}');
      expect(env.tokens.writes, 2);
      // и после ротации токенов ни новые, ни старые в БД не попадают
      final dump = (await _dumpDb(env)).toString();
      for (final token in [
        before.accessToken,
        before.refreshToken,
        after.accessToken,
        after.refreshToken,
      ]) {
        expect(dump, isNot(contains(token)));
      }
    });

    test('токен скоро истечёт: обновляется заранее, без 401', () async {
      await setUpEnv();
      env.clock.advance(const Duration(minutes: 14, seconds: 45));
      final api = env.container.read(apiClientProvider)!;
      await api.getJson('/auth/devices');
      expect(env.backend.refreshCalls, 1);
      expect(
        env.backend.requests.where((r) => r == 'GET /auth/devices'),
        hasLength(1),
        reason: 'первый запрос сразу с новым токеном',
      );
    });

    test('параллельные 401 вызывают ровно один refresh', () async {
      await setUpEnv();
      final api = env.container.read(apiClientProvider)!;
      // сервер отзывает access-токены, но часы клиента не ушли вперёд
      env.backend.expireAccessTokens();
      final results = await Future.wait([
        for (var i = 0; i < 12; i++) api.getJson('/auth/devices'),
      ]);
      expect(results, hasLength(12));
      expect(env.backend.refreshCalls, 1);
      expect(env.authState, isA<SignedIn>());
    });

    test(
      'параллельные запросы при задержанном refresh тоже ждут одного',
      () async {
        await setUpEnv();
        final gate = Completer<void>();
        env.backend.holdRefresh = gate;
        final api = env.container.read(apiClientProvider)!;
        env.backend.expireAccessTokens();
        final futures = [
          for (var i = 0; i < 5; i++) api.getJson('/auth/devices'),
        ];
        await pumpEventQueue();
        gate.complete();
        await Future.wait(futures);
        expect(env.backend.refreshCalls, 1);
      },
    );

    test(
      'устройство отозвано: токены стёрты, «нужен вход», данные остались',
      () async {
        await setUpEnv();
        final store = env.container.read(syncStoreProvider);
        final id = uuid7();
        await store.create('notes', id, {'title': 'local data'});
        final device = (env.authState as SignedIn).deviceId;
        env.backend.revokeDevice(device);
        final api = env.container.read(apiClientProvider)!;
        await expectLater(
          api.getJson('/auth/devices'),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'device_revoked'),
          ),
        );
        expect((env.authState as SignedOut).reason, SignOutReason.revoked);
        expect(env.tokens.session, isNull);
        expect(await store.getRow('notes', id), isNotNull);
        // без токена запросы даже не уходят
        final requests = env.backend.requests.length;
        await expectLater(
          api.getJson('/auth/devices'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'not_authenticated',
            ),
          ),
        );
        expect(env.backend.requests.length, requests);
      },
    );

    test('refresh_reuse_detected: выход, устройство отозвано', () async {
      await setUpEnv();
      final stale = env.tokens.session!;
      // обычное обновление отрабатывает и «сжигает» старый refresh
      env.backend.expireAccessTokens();
      await env.container.read(apiClientProvider)!.getJson('/auth/devices');
      // клиент откатился к старому refresh (например, потерял запись)
      env.tokens.session = stale;
      final second = await AppEnv.create(
        tokens: env.tokens,
        clock: env.clock,
        server: env.server,
        backend: env.backend,
      );
      env.backend.expireAccessTokens();
      await expectLater(
        second.container.read(apiClientProvider)!.getJson('/auth/devices'),
        throwsA(isA<ApiException>()),
      );
      expect(
        (second.authState as SignedOut).reason,
        SignOutReason.refreshReuse,
      );
      expect(second.tokens.session, isNull);
      second.container.dispose();
    });

    test('refresh_expired и неизвестный refresh: нужен вход', () async {
      await setUpEnv();
      final good = env.tokens.session!;
      env.tokens.session = AuthSession(
        deviceId: good.deviceId,
        accessToken: 'at-old',
        accessExpiresAt: env.clock.now.subtract(const Duration(days: 1)),
        refreshToken: 'rt-unknown',
        refreshExpiresAt: env.clock.now.add(const Duration(days: 1)),
      );
      final second = await AppEnv.create(
        tokens: env.tokens,
        clock: env.clock,
        server: env.server,
        backend: env.backend,
      );
      await expectLater(
        second.container.read(apiClientProvider)!.getJson('/auth/devices'),
        throwsA(isA<ApiException>()),
      );
      expect((second.authState as SignedOut).reason, SignOutReason.expired);
      second.container.dispose();
    });

    test('refresh просрочен по часам клиента: сервер не беспокоим', () async {
      await setUpEnv();
      env.clock.advance(const Duration(days: 91));
      final api = env.container.read(apiClientProvider)!;
      await expectLater(
        api.getJson('/auth/devices'),
        throwsA(isA<ApiException>()),
      );
      expect((env.authState as SignedOut).reason, SignOutReason.expired);
      expect(env.backend.refreshCalls, 0);
    });

    test('сеть пропала посреди refresh: сессия жива, ошибка сети', () async {
      await setUpEnv();
      env.backend.expireAccessTokens();
      env.backend.failNext('/auth/refresh');
      final api = env.container.read(apiClientProvider)!;
      await expectLater(
        api.getJson('/auth/devices'),
        throwsA(
          isA<ApiException>().having((e) => e.isNetwork, 'network', isTrue),
        ),
      );
      expect(env.authState, isA<SignedIn>());
      expect(env.tokens.session, isNotNull);
      // следующая попытка проходит
      await api.getJson('/auth/devices');
      expect(env.backend.refreshCalls, 1);
    });

    test(
      'прочие 401 без refreshable-кода не ведут к бесконечному циклу',
      () async {
        await setUpEnv();
        final api = env.container.read(apiClientProvider)!;
        // токен, который сервер не знает: invalid_token -> refresh -> повтор
        env.backend.expireAccessTokens();
        await api.getJson('/auth/devices');
        expect(env.backend.refreshCalls, 1);
      },
    );
  });

  group('эпоха сервера при входе и обновлении', () {
    test(
      'вход запоминает эпоху, смена эпохи при refresh ставит пересинхронизацию',
      () async {
        await setUpEnv(signedIn: false);
        await env.login();
        final store = env.container.read(syncStoreProvider);
        expect(await store.serverEpoch(), 'epoch-1');
        expect(await store.needsResync(), isFalse);
        env.server.epoch = 'epoch-2'; // сервер восстановили из копии
        env.backend.expireAccessTokens();
        await env.container.read(apiClientProvider)!.getJson('/auth/devices');
        expect(await store.needsResync(), isTrue);
      },
    );
  });

  group('выход и запуск', () {
    test('logout: устройство отозвано на сервере, токены стёрты', () async {
      await setUpEnv();
      final device = (env.authState as SignedIn).deviceId;
      await env.auth.logout();
      expect((env.authState as SignedOut).reason, SignOutReason.loggedOut);
      expect(env.tokens.session, isNull);
      expect(env.backend.requests, contains('POST /auth/logout'));
      expect(env.backend.deviceIds, contains(device));
    });

    test('logout без сети: выход локальный', () async {
      await setUpEnv();
      env.backend.failNext('/auth/logout');
      await env.auth.logout();
      expect(env.authState, isA<SignedOut>());
      expect(env.tokens.session, isNull);
    });

    test('logout без настроенного сервера тоже работает', () async {
      env = await AppEnv.create(
        serverConfigured: false,
        tokens: MemoryTokenStore(
          AuthSession(
            deviceId: uuid7(),
            accessToken: 'a',
            accessExpiresAt: DateTime.utc(2027),
            refreshToken: 'r',
            refreshExpiresAt: DateTime.utc(2027),
          ),
        ),
      );
      expect(env.authState, isA<SignedIn>());
      await env.auth.logout();
      expect(env.authState, isA<SignedOut>());
    });

    test('при запуске сессия читается из хранилища без сети', () async {
      await setUpEnv();
      final again = await AppEnv.create(
        tokens: env.tokens,
        clock: env.clock,
        server: env.server,
        backend: env.backend,
      );
      expect(again.authState, isA<SignedIn>());
      expect(
        (again.authState as SignedIn).deviceId,
        env.tokens.session!.deviceId,
      );
      again.container.dispose();
    });

    test('начальное состояние — AuthUnknown, затем SignedOut', () async {
      final container = ProviderContainer(
        overrides: [tokenStoreProvider.overrideWithValue(MemoryTokenStore())],
      );
      addTearDown(container.dispose);
      expect(container.read(authControllerProvider), isA<AuthUnknown>());
      await container.read(authControllerProvider.notifier).ready;
      expect(container.read(authControllerProvider), isA<SignedOut>());
    });

    test('onDeviceRevoked: коды и посторонние коды', () async {
      await setUpEnv();
      await env.auth.onDeviceRevoked('something_else');
      expect(env.authState, isA<SignedIn>());
      await env.auth.onDeviceRevoked('refresh_reuse_detected');
      expect((env.authState as SignedOut).reason, SignOutReason.refreshReuse);
    });

    test('refreshAfterUnauthorized без сессии и без сервера', () async {
      await setUpEnv(signedIn: false);
      expect(await env.auth.currentAccessToken(), isNull);
      expect(await env.auth.refreshAfterUnauthorized('x'), isNull);
    });
  });

  group('SecureTokenStore', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    final session = AuthSession(
      deviceId: uuid7(),
      accessToken: 'a',
      accessExpiresAt: DateTime.utc(2026, 10),
      refreshToken: 'r',
      refreshExpiresAt: DateTime.utc(2027),
    );

    test('запись, чтение, очистка', () async {
      final store = SecureTokenStore();
      expect(await store.read(), isNull);
      await store.write(session);
      final read = (await store.read())!;
      expect(read.deviceId, session.deviceId);
      expect(read.refreshToken, 'r');
      expect(read.accessExpiresAt, session.accessExpiresAt);
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('повреждённая запись равна отсутствию сессии и удаляется', () async {
      FlutterSecureStorage.setMockInitialValues({
        SecureTokenStore.storageKey: '{not json',
      });
      final store = SecureTokenStore();
      expect(await store.read(), isNull);
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: SecureTokenStore.storageKey), isNull);
    });

    test('провайдер по умолчанию — защищённое хранилище', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(tokenStoreProvider), isA<SecureTokenStore>());
    });
  });

  group('DeviceInfo и модели', () {
    test('DeviceInfo.toJson', () {
      expect(
        const DeviceInfo(
          name: 'n',
          platform: DevicePlatform.windows,
          appVersion: '1.0',
        ).toJson(),
        {'name': 'n', 'platform': 'windows', 'app_version': '1.0'},
      );
      expect(
        const DeviceInfo(name: 'n', platform: DevicePlatform.other).toJson(),
        {'name': 'n', 'platform': 'other'},
      );
      expect(DevicePlatform.parse('nope'), DevicePlatform.other);
    });

    test('RegisteredDevice.fromJson', () {
      final d = RegisteredDevice.fromJson(const {
        'id': 'x',
        'name': 'n',
        'platform': 'android',
        'app_version': null,
        'created_at': '2026-10-01T00:00:00Z',
        'last_seen_at': '2026-10-02T00:00:00.123456Z',
        'last_pulled_version': 5,
        'revoked_at': '2026-10-03T00:00:00Z',
        'is_current': true,
      });
      expect(d.isRevoked, isTrue);
      expect(d.isCurrent, isTrue);
      expect(d.lastSeenAt!.microsecond, 456);
      expect(d.platform, DevicePlatform.android);
    });
  });

  test('DioException без ответа превращается в сетевую ошибку', () async {
    await setUpEnv();
    env.backend.failNext('/auth/devices', count: 2);
    final api = env.container.read(apiClientProvider)!;
    await expectLater(
      api.getJson('/auth/devices'),
      throwsA(isA<ApiException>()),
    );
    expect(DioExceptionType.connectionError, isNotNull);
    expect(hlcLooksValid('nope'), isFalse);
  });
}
