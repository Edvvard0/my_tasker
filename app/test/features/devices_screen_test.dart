import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/devices/devices_providers.dart';
import 'package:my_tasker/features/shell/app_router.dart';

import '../support/fake_server/fake_backend.dart';
import '../support/fake_server/fake_sync_server.dart';
import '../support/manual_clock.dart';
import '../support/pump_app.dart';
import '../support/sync_env.dart';
import '../support/ui_helpers.dart';

final _now = DateTime.utc(2026, 10, 1, 12);

RegisteredDevice _device(
  String id,
  String name, {
  DevicePlatform platform = DevicePlatform.android,
  bool current = false,
  DateTime? revoked,
  Duration seen = const Duration(minutes: 5),
}) => RegisteredDevice(
  id: id,
  name: name,
  platform: platform,
  appVersion: '0.3.1',
  createdAt: _now.subtract(const Duration(days: 20)),
  lastSeenAt: _now.subtract(seen),
  revokedAt: revoked,
  isCurrent: current,
);

void main() {
  const route = '/settings/devices';

  group('состояния списка', () {
    testWidgets('загрузка: скелетон', (tester) async {
      final gate = Completer<List<RegisteredDevice>>();
      await pumpApp(
        tester,
        location: route,
        now: _now,
        overrides: [devicesProvider.overrideWith((ref) => gate.future)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
      expect(find.byKey(const Key('devices-list')), findsNothing);
      gate.complete([]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('list-skeleton')), findsNothing);
    });

    testWidgets('данные: текущее помечено, у чужих есть «Отозвать»', (
      tester,
    ) async {
      await pumpApp(
        tester,
        location: route,
        now: _now,
        overrides: [
          devicesProvider.overrideWith(
            (ref) async => [
              _device('a', 'Galaxy A55', current: true),
              _device(
                'b',
                'Рабочий ПК',
                platform: DevicePlatform.windows,
                seen: const Duration(days: 2),
              ),
              _device(
                'c',
                'Старый телефон',
                revoked: _now.subtract(const Duration(hours: 3)),
              ),
            ],
          ),
        ],
      );
      expect(find.text('Galaxy A55'), findsOneWidget);
      expect(find.text('ЭТО УСТРОЙСТВО'), findsOneWidget);
      expect(find.text('Android · 0.3.1'), findsNWidgets(2));
      expect(find.text('Windows · 0.3.1'), findsOneWidget);
      expect(find.text('Активно сейчас'), findsOneWidget);
      expect(find.textContaining('Заходило 29 сент.'), findsOneWidget);
      expect(find.text('ОТОЗВАНО'), findsOneWidget);
      expect(find.byKey(const Key('revoke-a')), findsNothing);
      expect(find.byKey(const Key('revoke-b')), findsOneWidget);
      expect(find.byKey(const Key('revoke-c')), findsNothing);
      expect(find.textContaining('Отозвано '), findsOneWidget);
    });

    testWidgets('пусто', (tester) async {
      await pumpApp(
        tester,
        location: route,
        overrides: [devicesProvider.overrideWith((ref) async => [])],
      );
      expect(find.text('Устройств нет'), findsOneWidget);
    });

    testWidgets('ошибка сервера: «Повторить» перечитывает список', (
      tester,
    ) async {
      var calls = 0;
      await pumpApp(
        tester,
        location: route,
        overrides: [
          devicesProvider.overrideWith((ref) async {
            calls++;
            if (calls == 1) {
              throw const ApiException(kind: ApiErrorKind.http, status: 500);
            }
            return [_device('a', 'Galaxy A55', current: true)];
          }),
        ],
      );
      expect(find.byKey(const Key('devices-error')), findsOneWidget);
      expect(
        find.text('Не удалось получить список устройств. Попробуй ещё раз.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('devices-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('devices-error')), findsNothing);
      expect(find.text('Galaxy A55'), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('офлайн: отдельное сообщение', (tester) async {
      await pumpApp(
        tester,
        location: route,
        overrides: [
          devicesProvider.overrideWith(
            (ref) async => throw const ApiException.network(),
          ),
        ],
      );
      expect(find.byKey(const Key('devices-offline')), findsOneWidget);
      expect(find.textContaining('связи с ним нет'), findsOneWidget);
    });

    testWidgets('переключатель отозванных', (tester) async {
      final requested = <bool>[];
      await pumpApp(
        tester,
        location: route,
        overrides: [
          devicesProvider.overrideWith((ref) async {
            requested.add(ref.watch(showRevokedDevicesProvider));
            return [_device('a', 'Galaxy A55', current: true)];
          }),
        ],
      );
      await tester.tap(find.byKey(const Key('devices-show-revoked')));
      await tester.pumpAndSettle();
      expect(requested, [false, true]);
    });
  });

  group('действия с сервером', () {
    late ManualClock clock;
    late FakeSyncServer server;
    late FakeBackend backend;
    late ProviderContainer container;

    setUp(() {
      clock = ManualClock();
      server = FakeSyncServer(registry: testRegistry(), nowMs: clock.call);
      backend = FakeBackend(server: server, now: () => clock.now);
    });
    tearDown(() => server.dispose());

    Future<void> open(WidgetTester tester) async {
      container = await pumpApp(
        tester,
        gated: true,
        signedIn: false,
        backend: backend,
        serverUrl: 'http://localhost:8000',
      );
      await tester.runAsync(() async {
        await container
            .read(authControllerProvider.notifier)
            .login(
              password: backend.password,
              totpCode: backend.totpCode,
              device: const DeviceInfo(
                name: 'Galaxy A55',
                platform: DevicePlatform.android,
              ),
            );
        await loginOtherDevice(backend);
      });
      container.read(routerProvider).go(route);
      await tester.pumpAndSettle();
    }

    testWidgets('настоящий список с сервера', (tester) async {
      await open(tester);
      expect(find.text('Galaxy A55'), findsOneWidget);
      expect(find.text('Рабочий ПК'), findsOneWidget);
      expect(find.text('ЭТО УСТРОЙСТВО'), findsOneWidget);
    });

    testWidgets('отзыв: подтверждение называет устройство, потом список '
        'обновляется', (tester) async {
      await open(tester);
      final other = backend.deviceIds.last;
      await tester.tap(find.byKey(Key('revoke-$other')));
      await tester.pumpAndSettle();
      expect(find.text('Отозвать «Рабочий ПК»?'), findsOneWidget);
      expect(find.textContaining('сразу выйдет из аккаунта'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(find.text('Устройство «Рабочий ПК» отозвано'), findsOneWidget);
      expect(find.text('Рабочий ПК'), findsNothing);
      expect(backend.requests, contains('DELETE /auth/devices/$other'));
    });

    testWidgets('отмена подтверждения ничего не отзывает', (tester) async {
      await open(tester);
      final other = backend.deviceIds.last;
      await tester.tap(find.byKey(Key('revoke-$other')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('Рабочий ПК'), findsOneWidget);
      expect(backend.requests.where((r) => r.startsWith('DELETE')), isEmpty);
    });

    testWidgets('устройства уже нет: сообщение и обновление списка', (
      tester,
    ) async {
      await open(tester);
      final other = backend.deviceIds.last;
      await tester.tap(find.byKey(Key('revoke-$other')));
      await tester.pumpAndSettle();
      backend.failNext('/auth/devices/', afterProcessing: true);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      // ответ потерялся: сообщение про сеть
      expect(find.text('Не удалось отозвать: нет соединения'), findsOneWidget);
    });

    testWidgets('выход: подтверждение с числом неотправленного, затем вход', (
      tester,
    ) async {
      await open(tester);
      await tester.runAsync(
        () => container.read(syncStoreProvider).create(
          'user_settings',
          '0195f2a0-0000-7000-8000-00000000000a',
          {'key': 'a', 'value': 1},
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('devices-logout')));
      await tester.tap(find.byKey(const Key('devices-logout')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Не отправлено на сервер: 1'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), isA<SignedOut>());
      expect(find.byKey(const Key('login-submit')), findsOneWidget);
    });

    testWidgets('выход без неотправленного: спокойный текст', (tester) async {
      await open(tester);
      await tester.ensureVisible(find.byKey(const Key('devices-logout')));
      await tester.tap(find.byKey(const Key('devices-logout')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Данные на устройстве останутся'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), isA<SignedIn>());
    });

    testWidgets('текущее устройство отозвали в другом месте: экран входа', (
      tester,
    ) async {
      await open(tester);
      backend.revokeDevice(backend.deviceIds.first);
      container.invalidate(devicesProvider);
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), isA<SignedOut>());
      expect(find.byKey(const Key('login-submit')), findsOneWidget);
    });
  });
}
