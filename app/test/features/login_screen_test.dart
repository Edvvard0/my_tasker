import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/auth/device_info_source.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/features/auth/presentation/login_error_text.dart';

import '../support/fake_server/fake_backend.dart';
import '../support/fake_server/fake_sync_server.dart';
import '../support/manual_clock.dart';
import '../support/pump_app.dart';
import '../support/sync_env.dart';

const _url = 'http://localhost:8000';

Finder get _password => find.byKey(const Key('login-password'));
Finder get _code => find.byKey(const Key('login-code'));
Finder get _device => find.byKey(const Key('login-device'));
Finder get _submit => find.byKey(const Key('login-submit'));

void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late FakeBackend backend;

  setUp(() {
    clock = ManualClock();
    server = FakeSyncServer(registry: testRegistry(), nowMs: clock.call);
    backend = FakeBackend(server: server, now: () => clock.now);
  });
  tearDown(() => server.dispose());

  Future<ProviderContainer> open(
    WidgetTester tester, {
    Size size = phoneSize,
    bool configured = true,
  }) => pumpApp(
    tester,
    size: size,
    signedIn: false,
    gated: true,
    backend: backend,
    serverUrl: configured ? _url : null,
    overrides: [
      deviceInfoSourceProvider.overrideWithValue(
        const DeviceInfoSource(
          defaultName: 'Galaxy A55',
          platform: DevicePlatform.android,
        ),
      ),
    ],
  );

  Future<void> fill(
    WidgetTester tester, {
    String password = 'correct-password',
    String code = '123456',
  }) async {
    await tester.enterText(_password, password);
    await tester.enterText(_code, code);
    await tester.pump();
  }

  group('доступ', () {
    testWidgets('без входа любой экран ведёт на «Вход»', (tester) async {
      await open(tester);
      expect(find.text('Вход'), findsWidgets);
      expect(_submit, findsOneWidget);
      expect(find.byKey(const Key('floating-tab-bar')), findsNothing);
    });

    testWidgets('сервер не настроен: пустое состояние и переход к настройке', (
      tester,
    ) async {
      await open(tester, configured: false);
      expect(find.text('Сервер не настроен'), findsOneWidget);
      expect(_submit, findsNothing);
      await tester.tap(find.byKey(const Key('login-setup-server')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('server-url-field')), findsOneWidget);
      // из настройки без входа — назад на «Вход»
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.text('Сервер не настроен'), findsOneWidget);
    });

    testWidgets('форма: адрес сервера, поля и платформа', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('login-server-url')), findsOneWidget);
      expect(find.text(_url), findsOneWidget);
      expect(find.text('Платформа: Android'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: _device, matching: find.byType(TextField)),
            )
            .controller!
            .text,
        'Galaxy A55',
      );
      await tester.tap(find.byKey(const Key('login-change-server')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('server-url-field')), findsOneWidget);
    });
  });

  group('проверка полей', () {
    testWidgets('пустые поля: подсказки, запросов нет', (tester) async {
      await open(tester);
      await tester.tap(_submit);
      await tester.pump();
      expect(find.text('Введи пароль'), findsOneWidget);
      expect(
        find.text('Введи 6 цифр из приложения-аутентификатора'),
        findsOneWidget,
      );
      expect(backend.loginCalls, 0);
    });

    testWidgets('код только из цифр и не длиннее шести', (tester) async {
      await open(tester);
      await tester.enterText(_code, '12ab3456789');
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: _code, matching: find.byType(TextField)),
            )
            .controller!
            .text,
        '123456',
      );
    });

    testWidgets('пустое название устройства', (tester) async {
      await open(tester);
      await tester.enterText(_device, '   ');
      await fill(tester);
      await tester.tap(_submit);
      await tester.pump();
      expect(find.text('Название — от 1 до 64 символов'), findsOneWidget);
    });

    testWidgets('пароль можно показать', (tester) async {
      await open(tester);
      TextField field() => tester.widget<TextField>(
        find.descendant(of: _password, matching: find.byType(TextField)),
      );
      expect(field().obscureText, isTrue);
      await tester.tap(find.byKey(const Key('login-toggle-password')));
      await tester.pump();
      expect(field().obscureText, isFalse);
    });
  });

  group('вход', () {
    testWidgets('успех: токены сохранены, открывается «Сегодня»', (
      tester,
    ) async {
      final container = await open(tester);
      await fill(tester);
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), isA<SignedIn>());
      expect(find.text('Здесь будет «Сегодня»'), findsOneWidget);
      expect(backend.deviceIds, hasLength(1));
    });

    testWidgets('идёт вход: кнопка неактивна, виден прогресс', (tester) async {
      backend.holdLogin = Completer<void>();
      await open(tester);
      await fill(tester);
      await tester.tap(_submit);
      await tester.pump();
      expect(find.byKey(const Key('login-progress')), findsOneWidget);
      expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
      backend.holdLogin!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-progress')), findsNothing);
    });

    testWidgets('неверные данные: ошибка, код сброшен', (tester) async {
      await open(tester);
      await fill(tester, password: 'nope');
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-error')), findsOneWidget);
      expect(
        find.text('Неверный пароль или код. Проверь оба поля.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: _code, matching: find.byType(TextField)),
            )
            .controller!
            .text,
        isEmpty,
      );
    });

    testWidgets('слишком много попыток: время ожидания', (tester) async {
      await open(tester);
      for (var i = 0; i < 6; i++) {
        await fill(tester, password: 'nope');
        await tester.tap(_submit);
        await tester.pumpAndSettle();
      }
      expect(
        find.textContaining('Слишком много попыток. Повтори через 30 секунд'),
        findsOneWidget,
      );
    });

    testWidgets('офлайн: понятный текст про сеть', (tester) async {
      backend.failNext('/auth/login');
      await open(tester);
      await fill(tester);
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(find.text('НЕТ СЕТИ'), findsOneWidget);
      expect(
        find.text('Нет соединения с сервером. Проверь сеть и адрес сервера.'),
        findsOneWidget,
      );
      // повторная попытка проходит
      await fill(tester);
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(find.text('Здесь будет «Сегодня»'), findsOneWidget);
    });

    testWidgets('приложение устарело: 426', (tester) async {
      backend.minClientSchema = 9;
      await open(tester);
      await fill(tester);
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Нужно обновить приложение: сервер требует более новую версию.',
        ),
        findsOneWidget,
      );
    });
  });

  group('после выхода', () {
    testWidgets('устройство отозвано: экран входа с пояснением', (
      tester,
    ) async {
      final container = await pumpApp(
        tester,
        gated: true,
        backend: backend,
        serverUrl: _url,
      );
      expect(find.text('Здесь будет «Сегодня»'), findsOneWidget);
      await container
          .read(authControllerProvider.notifier)
          .onDeviceRevoked('device_revoked');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-reason')), findsOneWidget);
      expect(find.text('УСТРОЙСТВО ОТОЗВАНО'), findsOneWidget);
      expect(_submit, findsOneWidget);
    });

    testWidgets('тексты других причин', (tester) async {
      final container = await pumpApp(
        tester,
        gated: true,
        backend: backend,
        serverUrl: _url,
      );
      final auth = container.read(authControllerProvider.notifier);
      await auth.onDeviceRevoked('refresh_reuse_detected');
      await tester.pumpAndSettle();
      expect(find.text('СЕССИЯ ЗАВЕРШЕНА'), findsOneWidget);
    });
  });

  group('тексты ошибок', () {
    test('по кодам и видам', () {
      String t(ApiException e) => loginErrorText(e);
      expect(t(const ApiException.network()), contains('Нет соединения'));
      expect(
        t(const ApiException(kind: ApiErrorKind.certMismatch)),
        contains('Сертификат'),
      );
      expect(t(const ApiException.notConfigured()), contains('не настроен'));
      expect(
        t(
          const ApiException(
            kind: ApiErrorKind.http,
            status: 422,
            code: 'validation_error',
          ),
        ),
        'Проверь введённые данные.',
      );
      expect(
        t(const ApiException(kind: ApiErrorKind.http, status: 503)),
        contains('недоступен'),
      );
      expect(
        t(const ApiException(kind: ApiErrorKind.http, status: 400, code: 'x')),
        'Не удалось войти. Попробуй ещё раз.',
      );
      expect(
        t(
          const ApiException(
            kind: ApiErrorKind.http,
            status: 429,
            code: 'too_many_attempts',
          ),
        ),
        contains('Подожди'),
      );
      expect(
        t(
          const ApiException(
            kind: ApiErrorKind.http,
            status: 429,
            code: 'too_many_attempts',
            retryAfter: Duration(minutes: 5),
          ),
        ),
        'Слишком много попыток. Повтори через 5 минут.',
      );
      expect(
        t(
          const ApiException(
            kind: ApiErrorKind.http,
            status: 429,
            code: 'too_many_attempts',
            retryAfter: Duration(seconds: 1),
          ),
        ),
        contains('1 секунду'),
      );
    });

    test('DeviceInfoSource.system заполнен', () {
      final info = DeviceInfoSource.system();
      expect(info.defaultName, isNotEmpty);
      expect(info.defaultName.length, lessThanOrEqualTo(64));
      expect(info.platformLabel, isNotEmpty);
      for (final p in DevicePlatform.values) {
        expect(
          DeviceInfoSource(defaultName: 'x', platform: p).platformLabel,
          isNotEmpty,
        );
      }
    });
  });
}
