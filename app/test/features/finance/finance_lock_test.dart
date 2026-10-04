import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/biometric.dart';
import 'package:my_tasker/features/finance/data/pin_lock_service.dart';
import 'package:my_tasker/features/finance/data/secret_store.dart';

import '../../support/finance_env.dart';

/// Служба PIN с малым числом итераций: тесты не ждут настоящего хеширования.
PinLockService _service(
  MemorySecretStore store, {
  DateTime Function()? now,
  int iterations = 5,
}) => PinLockService(store, iterations: iterations, now: now);

void main() {
  group('PinLockService: PIN хранится как соль и хеш', () {
    late MemorySecretStore store;
    late DateTime now;
    late PinLockService service;

    setUp(() {
      store = MemorySecretStore();
      now = DateTime.utc(2026, 10, 5, 9);
      service = _service(store, now: () => now);
    });

    test('в хранилище нет PIN в открытом виде; соль случайная', () async {
      await service.setPin('4821');
      final raw = store.values[PinLockService.pinKey]!;
      expect(raw, isNot(contains('4821')));
      final record = jsonDecode(raw) as Map<String, Object?>;
      expect(record.keys, containsAll(['v', 'iterations', 'salt', 'hash']));
      expect(base64Decode(record['salt']! as String), hasLength(16));
      expect(base64Decode(record['hash']! as String), hasLength(32));
      // Тот же PIN, другая соль — другой хеш.
      final other = MemorySecretStore();
      await _service(other).setPin('4821');
      final otherRecord = jsonDecode(
        other.values[PinLockService.pinKey]!,
      ) as Map<String, Object?>;
      expect(otherRecord['salt'], isNot(record['salt']));
      expect(otherRecord['hash'], isNot(record['hash']));
      expect(await service.isConfigured(), isTrue);
    });

    test('верный PIN принят, неверный отклонён', () async {
      await service.setPin('4821');
      expect(await service.verify('4821'), isA<PinAccepted>());
      final bad = await service.verify('0000');
      expect(bad, isA<PinRejected>());
      expect((bad as PinRejected).failures, 1);
      expect(bad.blockedUntil, isNull);
      expect(await service.verify('4821'), isA<PinAccepted>());
    });

    test('без PIN проверка проходит (замок выключен)', () async {
      expect(await service.isConfigured(), isFalse);
      expect(await service.verify('1'), isA<PinAccepted>());
    });

    test('после пяти ошибок — блокировка 30 с; растёт вдвое; верный PIN '
        'не помогает, пока блокировка идёт', () async {
      await service.setPin('4821');
      for (var i = 1; i <= 4; i++) {
        final r = await service.verify('0000') as PinRejected;
        expect(r.failures, i);
        expect(r.blockedUntil, isNull);
      }
      final fifth = await service.verify('0000') as PinRejected;
      expect(fifth.failures, 5);
      expect(fifth.blockedUntil, now.add(const Duration(seconds: 30)));
      final blocked = await service.verify('4821');
      expect(blocked, isA<PinBlocked>());
      expect((blocked as PinBlocked).until, fifth.blockedUntil);
      expect(await service.blockedUntil(), fifth.blockedUntil);

      // Блокировка кончилась: верный PIN принимается и всё сбрасывается.
      now = now.add(const Duration(seconds: 31));
      expect(await service.blockedUntil(), isNull);
      final sixth = await service.verify('0000') as PinRejected;
      expect(sixth.failures, 6);
      expect(sixth.blockedUntil, now.add(const Duration(seconds: 60)));
      now = now.add(const Duration(minutes: 2));
      expect(await service.verify('4821'), isA<PinAccepted>());
      final again = await service.verify('0000') as PinRejected;
      expect(again.failures, 1);
    });

    test('блокировка не длиннее 15 минут', () async {
      await service.setPin('4821');
      PinRejected? last;
      for (var i = 0; i < 20; i++) {
        now = now.add(const Duration(hours: 1));
        last = await service.verify('0000') as PinRejected;
      }
      expect(last!.blockedUntil!.difference(now), const Duration(minutes: 15));
    });

    test(
      'счётчик переживает «перезапуск»: новая служба на том же хранилище',
      () async {
        await service.setPin('4821');
        for (var i = 0; i < 5; i++) {
          await service.verify('0000');
        }
        final restarted = _service(store, now: () => now);
        expect(await restarted.verify('4821'), isA<PinBlocked>());
      },
    );

    test('допустимый PIN: 4–8 цифр', () {
      expect(PinLockService.problem('1234'), isNull);
      expect(PinLockService.problem('12345678'), isNull);
      expect(PinLockService.problem('123'), contains('от 4 до 8'));
      expect(PinLockService.problem('123456789'), contains('от 4 до 8'));
      expect(PinLockService.problem('12a4'), contains('цифры'));
      expect(PinLockService.problem(''), isNotNull);
    });

    test(
      'setPin с плохим PIN — FormatException; clear снимает замок',
      () async {
        await expectLater(service.setPin('12'), throwsFormatException);
        await service.setPin('4821');
        await service.verify('0000');
        await service.clear();
        expect(await service.isConfigured(), isFalse);
        expect(store.values, isEmpty);
      },
    );

    test('повреждённый счётчик попыток читается как «нет ошибок»', () async {
      await service.setPin('4821');
      store.values[PinLockService.attemptsKey] = '{не json';
      expect(await service.verify('4821'), isA<PinAccepted>());
    });
  });

  group('замок раздела в приложении', () {
    late MemorySecretStore store;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      String? pin,
      FakeBiometric? biometric,
      bool biometricWanted = false,
      bool seed = false,
    }) async {
      store = MemorySecretStore();
      if (pin != null) {
        await tester.runAsync(() => _service(store).setPin(pin));
      }
      return await pumpFinance(
        tester,
        seed: seed,
        secretStore: store,
        overrides: [
          pinLockServiceProvider.overrideWith(
            (ref) => PinLockService(
              ref.watch(secretStoreProvider),
              iterations: 5,
              now: ref.watch(clockProvider),
            ),
          ),
          if (biometric != null) biometricProvider.overrideWithValue(biometric),
        ],
        seedWith: biometricWanted
            ? (container) => container
                  .read(localSettingsRepositoryProvider)
                  .write(biometricSettingKey, '1')
            : null,
      );
    }

    testWidgets('без PIN раздел открыт', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);
      expect(find.byKey(const Key('finance-lock')), findsNothing);
    });

    testWidgets('с PIN: закрыто; неверный PIN — ошибка; верный — открыто', (
      tester,
    ) async {
      await pump(tester, pin: '4821');
      expect(find.byKey(const Key('finance-lock')), findsOneWidget);
      expect(find.byKey(const Key('finance-overview')), findsNothing);
      expect(find.text('Раздел закрыт'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('lock-pin')), '1111');
      await tester.tap(find.byKey(const Key('lock-submit')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lock-error')), findsOneWidget);
      expect(find.text('Неверный PIN'), findsOneWidget);
      expect(find.byKey(const Key('finance-overview')), findsNothing);

      await tester.enterText(find.byKey(const Key('lock-pin')), '4821');
      await tester.tap(find.byKey(const Key('lock-submit')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);
      expect(find.byKey(const Key('finance-lock')), findsNothing);
    });

    testWidgets('пять ошибок подряд блокируют ввод', (tester) async {
      final container = await pump(tester, pin: '4821');
      for (var i = 0; i < 5; i++) {
        await tester.enterText(find.byKey(const Key('lock-pin')), '0000');
        await tester.tap(find.byKey(const Key('lock-submit')));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const Key('lock-blocked')), findsOneWidget);
      expect(find.textContaining('Слишком много попыток'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('lock-submit')),
      );
      expect(button.onPressed, isNull);
      expect(container.read(financeLockProvider).failures, 5);
      expect(container.read(financeLockProvider).blockedUntil, isNotNull);
    });

    testWidgets('уход приложения в фон закрывает раздел снова', (tester) async {
      await pump(tester, pin: '4821');
      await tester.enterText(find.byKey(const Key('lock-pin')), '4821');
      await tester.tap(find.byKey(const Key('lock-submit')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);

      // Приложение ушло в фон и вернулось: раздел закрыт.
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-lock')), findsOneWidget);
      expect(find.byKey(const Key('finance-overview')), findsNothing);
    });

    testWidgets('без PIN уход в фон раздел не закрывает', (tester) async {
      await pump(tester);
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);
    });

    testWidgets('биометрия: кнопка открывает раздел; отказ — сообщение', (
      tester,
    ) async {
      final fake = FakeBiometric(succeeds: false);
      await pump(tester, pin: '4821', biometric: fake, biometricWanted: true);
      expect(find.byKey(const Key('lock-biometric')), findsOneWidget);
      await tester.tap(find.byKey(const Key('lock-biometric')));
      await tester.pumpAndSettle();
      expect(fake.calls, 1);
      expect(find.text('Не удалось подтвердить'), findsOneWidget);
      expect(find.byKey(const Key('finance-overview')), findsNothing);

      fake.succeeds = true;
      await tester.tap(find.byKey(const Key('lock-biometric')));
      await tester.pumpAndSettle();
      expect(fake.calls, 2);
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);
    });

    testWidgets('биометрия не включена или недоступна — кнопки нет', (
      tester,
    ) async {
      await pump(tester, pin: '4821', biometric: FakeBiometric());
      expect(find.byKey(const Key('lock-biometric')), findsNothing);
    });

    testWidgets('без биометрии на устройстве (по умолчанию) — только PIN', (
      tester,
    ) async {
      final container = await pump(tester, pin: '4821', biometricWanted: true);
      expect(container.read(biometricProvider), isA<UnavailableBiometric>());
      expect(await container.read(biometricProvider).isAvailable(), isFalse);
      expect(
        await container.read(biometricProvider).authenticate(reason: 'x'),
        isFalse,
      );
      expect(find.byKey(const Key('lock-biometric')), findsNothing);
      expect(
        await container
            .read(financeLockProvider.notifier)
            .unlockWithBiometric(),
        isFalse,
      );
    });

    testWidgets('защищённое хранилище недоступно: раздел закрыт, есть '
        '«Повторить»', (tester) async {
      store = MemorySecretStore()..failReads = true;
      await pumpFinance(tester, secretStore: store);
      expect(find.byKey(const Key('finance-lock')), findsOneWidget);
      expect(find.byKey(const Key('finance-overview')), findsNothing);
      expect(find.textContaining('защищённое хранилище'), findsOneWidget);
      expect(find.byKey(const Key('lock-pin')), findsNothing);

      store.failReads = false;
      await tester.tap(find.byKey(const Key('lock-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);
    });

    testWidgets('настройки: включить PIN (ошибки ввода, успех, хеш в '
        'хранилище), сменить, отключить', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'finance-privacy');
      await tapKey(tester, 'privacy-enable');

      // Короткий PIN и несовпадение.
      await tester.enterText(find.byKey(const Key('privacy-new')), '12');
      await tester.enterText(find.byKey(const Key('privacy-repeat')), '12');
      await tapKey(tester, 'privacy-apply');
      expect(find.text('PIN — от 4 до 8 цифр'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('privacy-new')), '4821');
      await tester.enterText(find.byKey(const Key('privacy-repeat')), '4822');
      await tapKey(tester, 'privacy-apply');
      expect(find.text('PIN-коды не совпадают'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('privacy-repeat')), '4821');
      await tester.tap(find.byKey(const Key('privacy-apply')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(container.read(financeLockProvider).hasPin, isTrue);
      expect(container.read(financeLockProvider).locked, isFalse);
      expect(store.values[PinLockService.pinKey], isNot(contains('4821')));
      expect(find.byKey(const Key('privacy-change')), findsOneWidget);
      expect(find.byKey(const Key('privacy-biometric')), findsNothing);

      // Смена PIN: неверный текущий — ошибка.
      await tapKey(tester, 'privacy-change');
      await tester.enterText(find.byKey(const Key('privacy-current')), '0000');
      await tester.enterText(find.byKey(const Key('privacy-new')), '9999');
      await tester.enterText(find.byKey(const Key('privacy-repeat')), '9999');
      await tester.tap(find.byKey(const Key('privacy-apply')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('Неверный текущий PIN'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('privacy-current')), '4821');
      await tester.tap(find.byKey(const Key('privacy-apply')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('privacy-disable')), findsOneWidget);
      expect(
        await tester.runAsync(
          () => container.read(pinLockServiceProvider).verify('9999'),
        ),
        isA<PinAccepted>(),
      );

      // Отключение замка.
      await tapKey(tester, 'privacy-disable');
      await tester.enterText(find.byKey(const Key('privacy-current')), '9999');
      await tester.tap(find.byKey(const Key('privacy-apply')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(container.read(financeLockProvider).hasPin, isFalse);
      expect(store.values.containsKey(PinLockService.pinKey), isFalse);
      expect(find.byKey(const Key('privacy-enable')), findsOneWidget);
    });

    testWidgets('«Закрыть раздел сейчас» из настроек', (tester) async {
      final container = await pump(tester, pin: '4821');
      await tester.enterText(find.byKey(const Key('lock-pin')), '4821');
      await tester.tap(find.byKey(const Key('lock-submit')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      await tapKey(tester, 'finance-privacy');
      await tapKey(tester, 'privacy-lock-now');
      expect(container.read(financeLockProvider).locked, isTrue);
      expect(find.byKey(const Key('finance-lock')), findsOneWidget);
    });

    testWidgets('биометрию можно включить, если она доступна', (tester) async {
      final container = await pump(
        tester,
        pin: '4821',
        biometric: FakeBiometric(),
      );
      await tester.enterText(find.byKey(const Key('lock-pin')), '4821');
      await tester.tap(find.byKey(const Key('lock-submit')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      await tapKey(tester, 'finance-privacy');
      expect(find.byKey(const Key('privacy-biometric')), findsOneWidget);
      await tapKey(tester, 'privacy-biometric');
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(container.read(financeLockProvider).biometric, isTrue);
      expect(
        await tester.runAsync(
          () => container
              .read(localSettingsRepositoryProvider)
              .read(biometricSettingKey),
        ),
        '1',
      );
    });
  });

  group('«скрыть суммы»', () {
    testWidgets('переключатель маскирует суммы, настройка сохраняется на '
        'устройстве', (tester) async {
      final container = await pumpFinance(tester, seed: true);
      expect(find.text(nb('361 000 ₽')), findsWidgets);
      await tapKey(tester, 'finance-hide-amounts');
      expect(container.read(hideAmountsProvider), isTrue);
      expect(find.text(nb('361 000 ₽')), findsNothing);
      expect(find.text(AmountFormat.mask), findsWidgets);
      expect(
        await tester.runAsync(
          () => container
              .read(localSettingsRepositoryProvider)
              .read(hideAmountsSettingKey),
        ),
        '1',
      );
      await tapKey(tester, 'finance-hide-amounts');
      expect(find.text(nb('361 000 ₽')), findsWidgets);
      expect(
        await tester.runAsync(
          () => container
              .read(localSettingsRepositoryProvider)
              .read(hideAmountsSettingKey),
        ),
        '0',
      );
    });

    testWidgets('сохранённый режим подхватывается при запуске', (tester) async {
      await pumpFinance(
        tester,
        seed: true,
        seedWith: (c) => c
            .read(localSettingsRepositoryProvider)
            .write(hideAmountsSettingKey, '1'),
      );
      // Подхват идёт асинхронно из БД.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text(nb('361 000 ₽')), findsNothing);
      expect(find.text(AmountFormat.mask), findsWidgets);
    });

    testWidgets('переключатель в настройках приватности', (tester) async {
      final container = await pumpFinance(tester, seed: true);
      await tapKey(tester, 'finance-privacy');
      await tapKey(tester, 'privacy-hide');
      expect(container.read(hideAmountsProvider), isTrue);
    });
  });
}
