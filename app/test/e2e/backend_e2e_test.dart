@Tags(['e2e'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/auth/token_store.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/network/api_providers.dart';
import 'package:my_tasker/core/sync/sse_client.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/settings/application/server_connection_controller.dart';
import 'package:my_tasker/features/settings/data/server_connection_repository.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';

import '../support/in_memory_opener.dart';

/// Сквозные тесты клиента против **настоящего** бэкенда.
///
/// Запуск (бэкенд и владелец созданы по `backend/README.md`):
///
/// ```bash
/// E2E_BACKEND_URL=http://127.0.0.1:8000 \
/// E2E_PASSWORD=... E2E_TOTP_SECRET=<base32 из otpauth://...> \
///   flutter test --tags e2e test/e2e
/// ```
///
/// Без `E2E_BACKEND_URL` тесты пропускаются. Каждый прогон использует
/// уникальные ключи настроек, поэтому база сервера может быть общей.
final String? _url = Platform.environment['E2E_BACKEND_URL'];
final String _password = Platform.environment['E2E_PASSWORD'] ?? '';
final String _totpSecret = Platform.environment['E2E_TOTP_SECRET'] ?? '';

String? get _skip => (_url ?? '').isEmpty
    ? 'нужен E2E_BACKEND_URL (см. описание в файле)'
    : (_password.isEmpty || _totpSecret.isEmpty)
    ? 'нужны E2E_PASSWORD и E2E_TOTP_SECRET'
    : null;

Uint8List _base32(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final clean = input.toUpperCase().replaceAll(RegExp('[ =]'), '');
  var bits = 0;
  var value = 0;
  final out = <int>[];
  for (final ch in clean.split('')) {
    value = (value << 5) | alphabet.indexOf(ch);
    bits += 5;
    if (bits >= 8) {
      out.add((value >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
  }
  return Uint8List.fromList(out);
}

/// TOTP по RFC 6238 (SHA-1, 6 цифр, шаг 30 с) для шага [step].
String _totp(String secret, int step) {
  final counter = ByteData(8)..setUint64(0, step);
  final hash = Hmac(
    sha1,
    _base32(secret),
  ).convert(counter.buffer.asUint8List()).bytes;
  final offset = hash.last & 0x0F;
  final binary =
      ((hash[offset] & 0x7F) << 24) |
      (hash[offset + 1] << 16) |
      (hash[offset + 2] << 8) |
      hash[offset + 3];
  return (binary % 1000000).toString().padLeft(6, '0');
}

/// Шаги TOTP, которые уже использовал этот процесс: сервер не принимает
/// один шаг дважды.
final Set<int> _usedSteps = {};

class _Client {
  _Client(this.name, this.container);

  final String name;
  final ProviderContainer container;

  AuthController get auth => container.read(authControllerProvider.notifier);
  UserSettingsRepository get settings =>
      container.read(userSettingsRepositoryProvider);
  SyncEngine get engine => container.read(syncEngineProvider);

  /// Один цикл; повторяет, пока очередь не пуста и сервер не «догнан».
  Future<void> sync() async {
    for (var i = 0; i < 3; i++) {
      final outcome = await engine.runCycle();
      expect(
        outcome,
        SyncOutcome.success,
        reason: '$name: ${engine.state.failure?.message}',
      );
    }
  }

  Future<void> login() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final base = now ~/ 30;
      for (final step in [base, base - 1, base + 1]) {
        if (_usedSteps.contains(step)) continue;
        _usedSteps.add(step);
        try {
          await auth.login(
            password: _password,
            totpCode: _totp(_totpSecret, step),
            device: DeviceInfo(
              name: name,
              platform: DevicePlatform.linux,
              appVersion: '0.0.0-e2e',
            ),
          );
          return;
        } on ApiException catch (e) {
          if (e.code != 'invalid_credentials') rethrow;
        }
      }
      // все шаги окна заняты: ждём следующий
      await Future<void>.delayed(Duration(seconds: 31 - now % 30));
    }
    fail('$name: не удалось войти');
  }
}

Future<_Client> _newClient(String name) async {
  final container = ProviderContainer(
    overrides: [
      databaseOpenerProvider.overrideWithValue(InMemoryDatabaseOpener()),
      appConfigProvider.overrideWithValue(
        const AppConfig(allowInsecureLocalhost: true),
      ),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      syncAutostartProvider.overrideWithValue(false),
    ],
  );
  await container
      .read(serverConnectionRepositoryProvider)
      .save(ServerConnectionSettings(url: _url));
  container.invalidate(serverConnectionSettingsProvider);
  return _Client(name, container);
}

void main() {
  // flutter_test подменяет HttpClient заглушкой (всегда 400): нужна настоящая сеть.
  setUpAll(() => HttpOverrides.global = null);

  final run =
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${Random().nextInt(9999)}';
  String key(String suffix) => 'e2e.$run.$suffix';

  // Сервер не принимает один шаг TOTP дважды, поэтому три устройства входят
  // один раз на весь файл.
  late _Client phone;
  late _Client pc;
  late _Client tablet;

  setUpAll(() async {
    if (_skip != null) return;
    phone = await _newClient('e2e phone');
    pc = await _newClient('e2e pc');
    tablet = await _newClient('e2e tablet');
    for (final c in [phone, pc, tablet]) {
      await c.container.read(serverConnectionSettingsProvider.future);
      await c.login();
    }
  });
  tearDownAll(() {
    if (_skip != null) return;
    for (final c in [phone, pc, tablet]) {
      c.container.dispose();
    }
  });

  group('клиент против настоящего бэкенда', () {
    test(
      'вход, две копии клиента, сходимость правок, конфликт и «Вернуть моё»',
      () async {
        expect(phone.container.read(authControllerProvider), isA<SignedIn>());
        expect(pc.container.read(authControllerProvider), isA<SignedIn>());

        // 1. Создание на телефоне доезжает до ПК (значения любого JSON-типа).
        await phone.settings.set(key('a'), 1);
        await phone.settings.set(key('b'), {
          'x': [1, 2],
          'ключ': 'значение',
        });
        await phone.sync();
        await pc.sync();
        expect(await pc.settings.read(key('a')), 1);
        expect(await pc.settings.read(key('b')), {
          'x': [1, 2],
          'ключ': 'значение',
        });

        // 2. Одновременная правка одного поля: побеждает более поздняя.
        await phone.settings.set(key('a'), 'phone');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await pc.settings.set(key('a'), 'pc');
        await phone.sync();
        await pc.sync();
        await phone.sync();
        expect(await pc.settings.read(key('a')), 'pc');
        expect(await phone.settings.read(key('a')), 'pc');

        // Проигравшее значение — в журнале конфликтов; «Вернуть моё» его возвращает.
        final remote = phone.container.read(syncRemoteProvider);
        final page = await remote.conflicts(reverted: 'false', limit: 200);
        final conflict = page.conflicts.firstWhere(
          (c) => c.table == 'user_settings' && c.losingValue == 'phone',
        );
        expect(conflict.kind, ConflictKind.field);
        final result = await remote.revert(conflict.id);
        await phone.container
            .read(syncStoreProvider)
            .applyChange(result.change);
        expect(await phone.settings.read(key('a')), 'phone');
        await phone.sync();
        await pc.sync();
        expect(await pc.settings.read(key('a')), 'phone');

        // 3. Удаление на ПК — в корзине телефона; восстановление на телефоне.
        await pc.settings.remove(key('b'));
        await pc.sync();
        await phone.sync();
        expect(await phone.settings.read(key('b')), isNull);
        final trash = await phone.container
            .read(syncStoreProvider)
            .trashItems();
        expect(trash.map((t) => t.title), contains(key('b')));
        await phone.settings.set(key('b'), {'back': true});
        await phone.sync();
        await pc.sync();
        expect(await pc.settings.read(key('b')), {'back': true});

        // 4. Работа офлайн: правки копятся, потом всё уходит одной пачкой.
        await pc.settings.set(key('c1'), 1);
        await pc.settings.set(key('c2'), 2);
        await pc.settings.set(key('c3'), 3);
        await pc.sync();
        await phone.sync();
        expect(await phone.settings.readAll(), containsPair(key('c3'), 3));

        // 5. Итог: обе копии совпадают с сервером по всем настройкам этого прогона.
        final a = await phone.settings.readAll();
        final b = await pc.settings.readAll();
        Map<String, Object?> mine(Map<String, Object?> m) => {
          for (final e in m.entries)
            if (e.key.startsWith('e2e.$run.')) e.key: e.value,
        };
        expect(mine(a), mine(b));
        expect(await phone.container.read(syncStoreProvider).outbox(), isEmpty);
        expect(await pc.container.read(syncStoreProvider).outbox(), isEmpty);
      },
    );

    test('SSE: другой клиент узнаёт об изменениях без опроса', () async {
      final api = pc.container.read(apiClientProvider)!;
      final client = SseClient(connect: () => api.openStream('/events'));
      final signals = <SseSignal>[];
      final sub = client.signals.listen(signals.add);
      client.start();
      addTearDown(() async {
        await sub.cancel();
        await client.dispose();
      });
      Future<void> until(bool Function() test) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!test()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('не дождались события SSE');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }

      await until(() => signals.any((s) => s.kind == SseSignalKind.hello));
      await phone.settings.set(key('sse'), 'ping');
      await phone.sync();
      await until(() => signals.any((s) => s.kind == SseSignalKind.changes));
      final head = signals
          .lastWhere((s) => s.kind == SseSignalKind.changes)
          .headVersion!;
      expect(head, greaterThan(0));
      await pc.sync();
      expect(await pc.settings.read(key('sse')), 'ping');
      expect(
        await pc.container.read(syncStoreProvider).cursor(),
        greaterThanOrEqualTo(head),
      );
    });

    test('устройства: список, отзыв чужого, выход', () async {
      final api = phone.container.read(authApiProvider)!;
      final devices = await api.devices();
      expect(
        devices.where((d) => d.name.startsWith('e2e ') && d.isCurrent),
        hasLength(1),
      );
      final tabletId =
          (tablet.container.read(authControllerProvider) as SignedIn).deviceId;
      expect(devices.map((d) => d.id), contains(tabletId));

      await api.revokeDevice(tabletId);
      await expectLater(
        tablet.engine.runCycle(),
        completion(SyncOutcome.authRequired),
      );
      final state = tablet.container.read(authControllerProvider);
      expect(state, isA<SignedOut>());
      expect((state as SignedOut).reason, SignOutReason.revoked);

      await phone.auth.logout();
      expect(phone.container.read(authControllerProvider), isA<SignedOut>());
    });

    test('неверный пароль: invalid_credentials', () async {
      final client = await _newClient('e2e bad');
      addTearDown(client.container.dispose);
      await client.container.read(serverConnectionSettingsProvider.future);
      await expectLater(
        client.auth.login(
          password: 'definitely-wrong-password',
          totpCode: '000000',
          device: const DeviceInfo(
            name: 'e2e bad',
            platform: DevicePlatform.linux,
          ),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'invalid_credentials',
          ),
        ),
      );
    });
  }, skip: _skip);
}
