import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/certificate_fingerprint.dart';
import 'package:my_tasker/core/network/connection_checker.dart';
import 'package:my_tasker/core/network/server_api.dart';
import 'package:my_tasker/core/network/trust_on_first_use.dart';
import 'package:my_tasker/core/widgets/app_text_field.dart';
import 'package:my_tasker/features/settings/data/server_connection_repository.dart';
import 'package:my_tasker/features/shell/app_router.dart';

import '../support/fake_checker.dart';
import '../support/pem.dart';
import '../support/pump_app.dart';

const _url = 'https://203.0.113.10';

Finder get _urlField => find.byKey(const Key('server-url-field'));
Finder get _check => find.byKey(const Key('check-button'));
Finder get _save => find.byKey(const Key('save-button'));
Finder get _fetch => find.byKey(const Key('fetch-ca-button'));
Finder get _confirm => find.byKey(const Key('confirm-ca-button'));
Finder get _status => find.byKey(const Key('connection-status'));

Finder _inStatus(String text) =>
    find.descendant(of: _status, matching: find.textContaining(text));

FetchedRootCa _ca([int salt = 0xAB]) =>
    FetchedRootCa(pem: fakePem(salt), fingerprint: fakeFingerprint(salt));

void main() {
  const route = '/settings/server';

  Future<void> enterUrl(WidgetTester tester, [String url = _url]) async {
    await tester.enterText(_urlField, url);
    await tester.pump();
  }

  /// Закрепляет [ca]: адрес -> получить -> подтвердить.
  Future<void> pin(WidgetTester tester, {String url = _url}) async {
    await enterUrl(tester, url);
    await tester.tap(_fetch);
    await tester.pumpAndSettle();
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
  }

  group('первая настройка: получение сертификата (TOFU)', () {
    testWidgets('пусто: «Сервер не настроен», проверка без УЦ отклоняется', (
      tester,
    ) async {
      final checker = FakeConnectionChecker(
        const ConnectionResult(
          ConnectionOutcome.invalidSettings,
          caInvalid: true,
        ),
      );
      await pumpApp(tester, location: route, checker: checker);
      expect(_inStatus('Сервер не настроен'), findsOneWidget);

      await enterUrl(tester);
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(checker.calls.single.caPem, isNull);
      expect(_inStatus('Сначала закрепи сертификат'), findsOneWidget);
    });

    testWidgets('получение: индикатор, затем отпечаток на подтверждение', (
      tester,
    ) async {
      final gate = Completer<FetchedRootCa>();
      Uri? requested;
      await pumpApp(
        tester,
        location: route,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((uri) {
            requested = uri;
            return gate.future;
          }),
        ],
      );
      await enterUrl(tester);
      await tester.tap(_fetch);
      await tester.pump();
      expect(_inStatus('Запрашиваем корневой сертификат'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(_fetch).onPressed, isNull);

      final ca = _ca();
      gate.complete(ca);
      await tester.pumpAndSettle();

      expect(requested.toString(), _url);
      expect(_inStatus('СВЕРЬ ОТПЕЧАТОК'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('ca-fingerprint')))
            .data,
        CertificateFingerprint.format(ca.fingerprint),
      );
      expect(_confirm, findsOneWidget);
      expect(find.byKey(const Key('cancel-ca-button')), findsOneWidget);
    });

    testWidgets('до подтверждения в БД ничего не сохраняется', (tester) async {
      final container = await pumpApp(
        tester,
        location: route,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async => _ca()),
        ],
      );
      await enterUrl(tester);
      await tester.tap(_fetch);
      await tester.pumpAndSettle();
      final saved = await tester.runAsync(
        () => container.read(serverConnectionRepositoryProvider).load(),
      );
      expect(saved!.caPem, isNull);
      expect(saved.isConfigured, isFalse);
    });

    testWidgets('«Отмена» отбрасывает сертификат', (tester) async {
      await pumpApp(
        tester,
        location: route,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async => _ca()),
        ],
      );
      await enterUrl(tester);
      await tester.tap(_fetch);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cancel-ca-button')));
      await tester.pumpAndSettle();
      expect(_confirm, findsNothing);
      expect(_inStatus('Сервер не настроен'), findsOneWidget);
    });

    testWidgets('новый запрос и «Отмена» не сбрасывают уже закреплённый УЦ', (
      tester,
    ) async {
      final checker = FakeConnectionChecker(
        const ConnectionResult(ConnectionOutcome.ok),
      );
      var salt = 0x01;
      await pumpApp(
        tester,
        location: route,
        checker: checker,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async => _ca(salt)),
        ],
      );
      await pin(tester);
      expect(_inStatus('СЕРТИФИКАТ ЗАКРЕПЛЁН'), findsOneWidget);

      // Второй запрос отдаёт другой сертификат; пользователь отказывается.
      salt = 0x02;
      await tester.tap(_fetch);
      await tester.pumpAndSettle();
      expect(_inStatus('СВЕРЬ ОТПЕЧАТОК'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cancel-ca-button')));
      await tester.pumpAndSettle();

      expect(_inStatus('СЕРТИФИКАТ ЗАКРЕПЛЁН'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('pinned-fingerprint')))
            .data,
        CertificateFingerprint.format(fakeFingerprint(0x01)),
      );
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(checker.calls.single.caPem, fakePem(0x01));
    });

    testWidgets('подтверждение: PEM и адрес сохраняются, «закреплён»', (
      tester,
    ) async {
      final container = await pumpApp(
        tester,
        location: route,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async => _ca()),
        ],
      );
      await pin(tester, url: '  https://203.0.113.10/ ');

      expect(find.text('Сертификат сервера закреплён'), findsOneWidget);
      expect(_inStatus('СЕРТИФИКАТ ЗАКРЕПЛЁН'), findsOneWidget);
      expect(find.byKey(const Key('pinned-fingerprint')), findsOneWidget);
      final saved = await tester.runAsync(
        () => container.read(serverConnectionRepositoryProvider).load(),
      );
      expect(saved!.url, _url);
      expect(saved.caPem, _ca().pem);
    });

    testWidgets('«Проверить соединение» использует закреплённый PEM', (
      tester,
    ) async {
      final checker = FakeConnectionChecker(
        const ConnectionResult(
          ConnectionOutcome.ok,
          serverVersion: ServerVersion(
            appVersion: '0.1.0',
            apiSchemaVersion: 1,
            minClientSchemaVersion: 1,
          ),
        ),
      );
      await pumpApp(
        tester,
        location: route,
        checker: checker,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async => _ca()),
        ],
      );
      await pin(tester);
      await tester.tap(_check);
      await tester.pumpAndSettle();

      expect(_inStatus('СОЕДИНЕНИЕ УСТАНОВЛЕНО'), findsOneWidget);
      expect(_inStatus('версия 0.1.0'), findsOneWidget);
      expect(checker.calls.single.url, _url);
      expect(checker.calls.single.caPem, _ca().pem);
    });

    testWidgets('смена адреса сбрасывает закреплённый УЦ', (tester) async {
      final checker = FakeConnectionChecker(
        const ConnectionResult(ConnectionOutcome.ok),
      );
      await pumpApp(
        tester,
        location: route,
        checker: checker,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async => _ca()),
        ],
      );
      await pin(tester);
      expect(_inStatus('СЕРТИФИКАТ ЗАКРЕПЛЁН'), findsOneWidget);

      await enterUrl(tester, 'https://203.0.113.11');
      expect(_inStatus('СЕРТИФИКАТ ЗАКРЕПЛЁН'), findsNothing);
      expect(_inStatus('НЕ ЗАКРЕПЛЁН'), findsOneWidget);

      // Проверка нового адреса идёт без старого УЦ.
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(checker.calls.single.caPem, isNull);

      // Возврат к прежнему адресу УЦ не воскрешает.
      await enterUrl(tester);
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(checker.calls.last.caPem, isNull);
    });

    testWidgets('смена адреса во время подтверждения отбрасывает сертификат', (
      tester,
    ) async {
      await pumpApp(
        tester,
        location: route,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async => _ca()),
        ],
      );
      await enterUrl(tester);
      await tester.tap(_fetch);
      await tester.pumpAndSettle();
      expect(_confirm, findsOneWidget);
      await enterUrl(tester, 'https://203.0.113.99');
      expect(_confirm, findsNothing);
    });

    testWidgets('«Сохранить адрес» сбрасывает УЦ при другом адресе', (
      tester,
    ) async {
      final container = await pumpApp(
        tester,
        location: route,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async => _ca()),
        ],
      );
      await pin(tester);
      await enterUrl(tester, 'https://203.0.113.11');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      final saved = await tester.runAsync(
        () => container.read(serverConnectionRepositoryProvider).load(),
      );
      expect(saved!.url, 'https://203.0.113.11');
      expect(saved.caPem, isNull);
    });

    testWidgets('«Сохранить адрес» сохраняет и УЦ при том же адресе', (
      tester,
    ) async {
      final container = await pumpApp(
        tester,
        location: route,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async => _ca()),
        ],
      );
      await pin(tester);
      await tester.tap(_save);
      await tester.pumpAndSettle();
      final saved = await tester.runAsync(
        () => container.read(serverConnectionRepositoryProvider).load(),
      );
      expect(saved!.caPem, _ca().pem);
    });

    testWidgets('неканонический PEM из БД не считается закреплённым', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final bad =
          fakePem() +
          fakePem(0x09).replaceAll('CERTIFICATE', 'X509 CERTIFICATE');
      await tester.runAsync(
        () => container
            .read(serverConnectionRepositoryProvider)
            .save(ServerConnectionSettings(url: _url, caPem: bad)),
      );
      container.read(routerProvider).go(route);
      await tester.pumpAndSettle();
      expect(_inStatus('СЕРТИФИКАТ ЗАКРЕПЛЁН'), findsNothing);
      expect(find.byKey(const Key('pinned-fingerprint')), findsNothing);
    });

    testWidgets('сохранённые адрес и УЦ подставляются при открытии', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await tester.runAsync(
        () => container
            .read(serverConnectionRepositoryProvider)
            .save(ServerConnectionSettings(url: _url, caPem: fakePem())),
      );
      container.read(routerProvider).go(route);
      await tester.pumpAndSettle();

      expect(tester.widget<AppTextField>(_urlField).controller.text, _url);
      expect(_inStatus('СЕРТИФИКАТ ЗАКРЕПЛЁН'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('pinned-fingerprint')))
            .data,
        CertificateFingerprint.format(fakeFingerprint()),
      );
    });
  });

  group('ошибки получения сертификата', () {
    Future<void> failWith(WidgetTester tester, RootCaFetchError e) async {
      await pumpApp(
        tester,
        location: route,
        overrides: [
          rootCaFetcherProvider.overrideWithValue(
            (_) async => throw RootCaFetchException(e),
          ),
        ],
      );
      await enterUrl(tester);
      await tester.tap(_fetch);
      await tester.pumpAndSettle();
    }

    testWidgets('сервер недоступен', (tester) async {
      await failWith(tester, RootCaFetchError.unreachable);
      expect(_inStatus('СЕРВЕР НЕДОСТУПЕН'), findsOneWidget);
      expect(_confirm, findsNothing);
    });

    testWidgets('нет сертификата (404)', (tester) async {
      await failWith(tester, RootCaFetchError.badResponse);
      expect(_inStatus('НЕТ СЕРТИФИКАТА'), findsOneWidget);
    });

    testWidgets('в ответе не сертификат', (tester) async {
      await failWith(tester, RootCaFetchError.invalidCertificate);
      expect(_inStatus('СЕРТИФИКАТ НЕ РАЗОБРАН'), findsOneWidget);
    });

    testWidgets('некорректный адрес: ошибка под полем, сеть не вызывается', (
      tester,
    ) async {
      var called = false;
      await pumpApp(
        tester,
        location: route,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async {
            called = true;
            return _ca();
          }),
        ],
      );
      await enterUrl(tester, 'http://203.0.113.10');
      await tester.tap(_fetch);
      await tester.pumpAndSettle();
      expect(find.textContaining('Нужен https'), findsOneWidget);
      expect(called, isFalse);

      await enterUrl(tester, '');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('Введи адрес сервера'), findsOneWidget);
    });
  });

  group('ручной ввод PEM', () {
    testWidgets('вставка PEM -> отпечаток -> подтверждение', (tester) async {
      final container = await pumpApp(tester, location: route);
      await enterUrl(tester);
      await tester.tap(find.byKey(const Key('manual-pem-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Скрыть ввод PEM'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('pem-field')), fakePem());
      await tester.tap(find.byKey(const Key('use-pem-button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('ca-fingerprint')))
            .data,
        CertificateFingerprint.format(fakeFingerprint()),
      );

      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      final saved = await tester.runAsync(
        () => container.read(serverConnectionRepositoryProvider).load(),
      );
      expect(saved!.caPem!.trim(), fakePem().trim());

      await tester.tap(find.byKey(const Key('manual-pem-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pem-field')), findsNothing);
    });

    testWidgets('файл с двумя сертификатами и чужие метки отвергаются', (
      tester,
    ) async {
      await pumpApp(tester, location: route);
      await enterUrl(tester);
      await tester.tap(find.byKey(const Key('manual-pem-toggle')));
      await tester.pumpAndSettle();
      final evil = fakePem(0x09).replaceAll('CERTIFICATE', 'X509 CERTIFICATE');
      for (final text in [fakePem() + evil, fakePem() + fakePem(0x09), evil]) {
        await tester.enterText(find.byKey(const Key('pem-field')), text);
        await tester.ensureVisible(find.byKey(const Key('use-pem-button')));
        await tester.tap(find.byKey(const Key('use-pem-button')));
        await tester.pumpAndSettle();
        expect(find.textContaining('в формате PEM'), findsOneWidget);
        expect(_confirm, findsNothing);
      }
    });

    testWidgets('CRLF при вставке: сохраняется каноническая запись', (
      tester,
    ) async {
      final container = await pumpApp(tester, location: route);
      await enterUrl(tester);
      await tester.tap(find.byKey(const Key('manual-pem-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pem-field')),
        fakePem().replaceAll('\n', '\r\n'),
      );
      await tester.tap(find.byKey(const Key('use-pem-button')));
      await tester.pumpAndSettle();
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      final saved = await tester.runAsync(
        () => container.read(serverConnectionRepositoryProvider).load(),
      );
      expect(saved!.caPem, fakePem());
    });

    testWidgets('мусор вместо PEM и пустой адрес — ошибки', (tester) async {
      await pumpApp(tester, location: route);
      await tester.tap(find.byKey(const Key('manual-pem-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('use-pem-button')));
      await tester.pumpAndSettle();
      expect(find.text('Введи адрес сервера'), findsOneWidget);

      await enterUrl(tester);
      await tester.enterText(find.byKey(const Key('pem-field')), 'oops');
      await tester.tap(find.byKey(const Key('use-pem-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('в формате PEM'), findsOneWidget);
      expect(_confirm, findsNothing);
    });
  });

  group('проверка соединения: состояния', () {
    Future<FakeConnectionChecker> pinned(
      WidgetTester tester,
      ConnectionResult result, {
      Completer<void>? gate,
      Size size = phoneSize,
    }) async {
      final checker = FakeConnectionChecker(result, gate: gate);
      await pumpApp(
        tester,
        size: size,
        location: route,
        checker: checker,
        overrides: [
          rootCaFetcherProvider.overrideWithValue((_) async => _ca()),
        ],
      );
      await pin(tester);
      return checker;
    }

    testWidgets('идёт проверка: спиннер, кнопки заблокированы', (tester) async {
      final gate = Completer<void>();
      await pinned(
        tester,
        const ConnectionResult(ConnectionOutcome.ok),
        gate: gate,
      );
      await tester.tap(_check);
      await tester.pump();
      expect(find.byKey(const Key('check-progress')), findsOneWidget);
      expect(_inStatus('Обращаемся к серверу'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(_check).onPressed, isNull);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('check-progress')), findsNothing);
    });

    testWidgets('успех без версии и с устаревшим клиентом', (tester) async {
      final checker = await pinned(
        tester,
        const ConnectionResult(ConnectionOutcome.ok),
      );
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(_inStatus('Сервер отвечает.'), findsOneWidget);
      checker.result = const ConnectionResult(
        ConnectionOutcome.ok,
        clientOutdated: true,
      );
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(_inStatus('более новую версию приложения'), findsOneWidget);
    });

    testWidgets('недоступен, не готов, сертификат не совпал, неверный адрес', (
      tester,
    ) async {
      final checker = await pinned(
        tester,
        const ConnectionResult(ConnectionOutcome.unreachable),
      );
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(_inStatus('СЕРВЕР НЕДОСТУПЕН'), findsOneWidget);

      checker.result = const ConnectionResult(ConnectionOutcome.notReady);
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(_inStatus('СЕРВЕР НЕ ГОТОВ'), findsOneWidget);

      checker.result = const ConnectionResult(ConnectionOutcome.certMismatch);
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(_inStatus('СЕРТИФИКАТ НЕ СОВПАЛ'), findsOneWidget);
      expect(_inStatus('не закреплённым'), findsOneWidget);

      checker.result = const ConnectionResult(
        ConnectionOutcome.invalidSettings,
      );
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(_inStatus('Исправь адрес'), findsOneWidget);
    });

    testWidgets('десктоп 1440×900: закрепление и проверка', (tester) async {
      await pinned(
        tester,
        const ConnectionResult(ConnectionOutcome.ok),
        size: desktopSize,
      );
      await tester.tap(_check);
      await tester.pumpAndSettle();
      expect(_inStatus('СОЕДИНЕНИЕ УСТАНОВЛЕНО'), findsOneWidget);
    });

    testWidgets('стрелка «Назад» ведёт в «Настройки»', (tester) async {
      await pumpApp(tester, location: route);
      expect(find.text('Настройки ›'), findsOneWidget);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-server')), findsOneWidget);
    });
  });
}
