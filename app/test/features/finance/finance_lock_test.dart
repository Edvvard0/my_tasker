import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/biometric.dart';
import 'package:my_tasker/features/finance/data/pin_lock_service.dart';
import 'package:my_tasker/features/finance/data/screen_security.dart';
import 'package:my_tasker/features/finance/data/secret_store.dart';

import '../../support/finance_env.dart';
import '../../support/in_memory_opener.dart';

/// Служба PIN с малым числом итераций: тесты не ждут настоящего хеширования.
///
/// Монотонные часы выводятся из того же поддельного времени, чтобы они шли
/// вместе с ним (отдельные тесты разводят их нарочно).
PinLockService _service(
  MemorySecretStore store, {
  DateTime Function()? now,
  Duration Function()? monotonic,
  int iterations = 5,
}) => PinLockService(
  store,
  iterations: iterations,
  now: now,
  monotonic:
      monotonic ??
      (now == null ? null : () => now().difference(DateTime.utc(2000))),
);

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

    test('монотонные часы: перевод системных часов вперёд блокировку не '
        'снимает; монотонное время — снимает', () async {
      var elapsed = Duration.zero;
      final guarded = _service(store, now: () => now, monotonic: () => elapsed);
      await guarded.setPin('4821');
      for (var i = 0; i < 5; i++) {
        await guarded.verify('0000');
      }
      expect(await guarded.blockedUntil(), isNotNull);

      // Пользователь перевёл часы на сутки вперёд, монотонные не двинулись.
      now = now.add(const Duration(days: 1));
      final until = await guarded.blockedUntil();
      expect(until, isNotNull, reason: 'блокировка держится по монотонным');
      expect(await guarded.verify('4821'), isA<PinBlocked>());

      // Монотонное время дошло до конца блокировки.
      elapsed += const Duration(seconds: 31);
      expect(await guarded.blockedUntil(), isNull);
      expect(await guarded.verify('4821'), isA<PinAccepted>());
    });

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
              monotonic: () =>
                  ref.read(clockProvider)().difference(DateTime.utc(2000)),
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

  group('замок раздела: путь «Забыл PIN», окна, таймер, защита экрана', () {
    late MemorySecretStore store;
    var current = financeNow;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      String? pin,
      FakeBiometric? biometric,
      bool biometricWanted = false,
      bool seed = false,
      FakeScreenSecurity? screen,
      MemorySecretStore? withStore,
    }) async {
      current = financeNow;
      store = withStore ?? MemorySecretStore();
      if (pin != null) {
        await tester.runAsync(() => _service(store).setPin(pin));
      }
      return await pumpFinance(
        tester,
        seed: seed,
        secretStore: store,
        clock: () => current,
        overrides: [
          if (screen != null) screenSecurityProvider.overrideWithValue(screen),
          pinLockServiceProvider.overrideWith(
            (ref) => PinLockService(
              ref.watch(secretStoreProvider),
              iterations: 5,
              now: () => current,
              monotonic: () => current.difference(DateTime.utc(2000)),
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

    Future<void> enter(WidgetTester tester, String pin) async {
      await tester.enterText(find.byKey(const Key('lock-pin')), pin);
      await tester.tap(find.byKey(const Key('lock-submit')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }

    testWidgets('экран замка оживает по окончании блокировки без нажатий', (
      tester,
    ) async {
      await pump(tester, pin: '4821');
      for (var i = 0; i < 5; i++) {
        await enter(tester, '0000');
      }
      expect(find.byKey(const Key('lock-blocked')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('lock-submit')))
            .onPressed,
        isNull,
      );

      // Блокировка кончилась (часы ушли на 31 с); экран перерисуется сам.
      current = current.add(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const Key('lock-blocked')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('lock-submit')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('биометрия не обходит блокировку после неверных PIN', (
      tester,
    ) async {
      final fake = FakeBiometric();
      final container = await pump(
        tester,
        pin: '4821',
        biometric: fake,
        biometricWanted: true,
      );
      for (var i = 0; i < 5; i++) {
        await enter(tester, '0000');
      }
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('lock-biometric')))
            .onPressed,
        isNull,
      );
      final ok = await tester.runAsync(
        () =>
            container.read(financeLockProvider.notifier).unlockWithBiometric(),
      );
      expect(ok, isFalse);
      expect(fake.calls, 0);
      expect(container.read(financeLockProvider).locked, isTrue);

      // Блокировка прошла: биометрия работает.
      current = current.add(const Duration(minutes: 1));
      final after = await tester.runAsync(
        () =>
            container.read(financeLockProvider.notifier).unlockWithBiometric(),
      );
      expect(after, isTrue);
      expect(fake.calls, 1);
    });

    testWidgets('«Забыл PIN»: подтверждение, замок снят, данные на месте', (
      tester,
    ) async {
      final container = await pump(tester, pin: '4821', seed: true);
      expect(find.byKey(const Key('finance-lock')), findsOneWidget);
      await tapKey(tester, 'lock-forgot');
      // Отмена в диалоге: замок остаётся.
      await tapKey(tester, 'confirm-cancel');
      expect(find.byKey(const Key('finance-lock')), findsOneWidget);
      expect(store.values.containsKey(PinLockService.pinKey), isTrue);

      await tapKey(tester, 'lock-forgot');
      expect(find.text('Сбросить замок раздела?'), findsOneWidget);
      await tapKey(tester, 'confirm-ok');
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);
      expect(store.values, isEmpty, reason: 'PIN и счётчик удалены');
      expect(container.read(financeLockProvider).hasPin, isFalse);
      // Данные раздела не удалены.
      expect(find.text(nb('361 000 ₽')), findsWidgets);
    });

    testWidgets('«Забыл PIN» при биометрии: сначала подтверждение владельца', (
      tester,
    ) async {
      final fake = FakeBiometric(succeeds: false);
      final container = await pump(tester, pin: '4821', biometric: fake);
      await tapKey(tester, 'lock-forgot');
      await tapKey(tester, 'confirm-ok');
      expect(fake.calls, 1);
      expect(find.byKey(const Key('finance-lock')), findsOneWidget);
      expect(find.text('Не удалось подтвердить'), findsOneWidget);
      expect(container.read(financeLockProvider).hasPin, isTrue);

      fake.succeeds = true;
      await tapKey(tester, 'lock-forgot');
      await tapKey(tester, 'confirm-ok');
      expect(fake.calls, 2);
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);
    });

    testWidgets('нечитаемое хранилище: «Сбросить замок» открывает раздел', (
      tester,
    ) async {
      final broken = MemorySecretStore()..failReads = true;
      final container = await pump(tester, withStore: broken);
      expect(find.byKey(const Key('finance-lock')), findsOneWidget);
      await tapKey(tester, 'lock-reset');
      await tapKey(tester, 'confirm-ok');
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);
      expect(container.read(financeLockProvider).error, isNull);
      expect(container.read(financeLockProvider).hasPin, isFalse);
    });

    testWidgets('хранилище не чистится: метка сброса, затем доделывается', (
      tester,
    ) async {
      final broken = MemorySecretStore()
        ..failReads = true
        ..failDeletes = true;
      final container = await pump(tester, withStore: broken);
      await tapKey(tester, 'lock-reset');
      await tapKey(tester, 'confirm-ok');
      expect(find.byKey(const Key('finance-overview')), findsOneWidget);
      final settings = container.read(localSettingsRepositoryProvider);
      expect(
        await tester.runAsync(() => settings.read(lockResetPendingKey)),
        '1',
      );

      // Повторное чтение состояния (новый запуск): хранилище всё ещё
      // нечитаемо, но замок не возвращается.
      await tester.runAsync(
        () => container.read(financeLockProvider.notifier).load(),
      );
      expect(container.read(financeLockProvider).locked, isFalse);
      expect(container.read(financeLockProvider).error, isNull);

      // Хранилище починилось: метка снята, хранилище очищено.
      broken
        ..failReads = false
        ..failDeletes = false
        ..values[PinLockService.pinKey] = '{}';
      await tester.runAsync(
        () => container.read(financeLockProvider.notifier).load(),
      );
      expect(container.read(financeLockProvider).hasPin, isFalse);
      expect(broken.values, isEmpty);
      expect(
        await tester.runAsync(() => settings.read(lockResetPendingKey)),
        isNull,
      );
    });

    testWidgets('закрытие замка закрывает листы поверх раздела', (
      tester,
    ) async {
      final container = await pump(tester, pin: '4821');
      await enter(tester, '4821');
      await tapKey(tester, 'finance-privacy');
      expect(find.byKey(const Key('privacy-lock-now')), findsOneWidget);

      container.read(financeLockProvider.notifier).lock();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('privacy-lock-now')), findsNothing);
      expect(find.byKey(const Key('finance-lock')), findsOneWidget);

      // То же при уходе приложения в фон, с диалогом поверх раздела.
      await enter(tester, '4821');
      unawaited(
        showDialog<void>(
          context: tester.element(find.byKey(const Key('finance-overview'))),
          builder: (_) => const AlertDialog(
            key: Key('test-dialog'),
            title: Text('Форма сверки'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('test-dialog')), findsOneWidget);
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('test-dialog')), findsNothing);
      expect(find.byKey(const Key('finance-lock')), findsOneWidget);
    });

    testWidgets('FLAG_SECURE: включён, пока раздел открыт', (tester) async {
      final screen = FakeScreenSecurity();
      final container = await pump(tester, pin: '4821', screen: screen);
      expect(screen.secure, isFalse, reason: 'раздел закрыт замком');
      await enter(tester, '4821');
      await tester.pump();
      expect(screen.secure, isTrue);
      expect(container.read(secureScreenProvider), isNotEmpty);

      container.read(financeLockProvider.notifier).lock();
      await tester.pumpAndSettle();
      expect(screen.secure, isFalse);
      expect(container.read(secureScreenProvider), isEmpty);
    });

    testWidgets('FLAG_SECURE: «скрыть суммы» держит защиту и без раздела', (
      tester,
    ) async {
      final screen = FakeScreenSecurity();
      final container = await pump(tester, pin: '4821', screen: screen);
      await tester.runAsync(
        () => container.read(hideAmountsProvider.notifier).set(hidden: true),
      );
      expect(screen.secure, isTrue);
      expect(
        container.read(secureScreenProvider),
        contains(secureReasonHideAmounts),
      );
      await tester.runAsync(
        () => container.read(hideAmountsProvider.notifier).set(hidden: false),
      );
      expect(screen.secure, isFalse);
    });
  });

  group('«скрыть суммы» до загрузки настройки', () {
    test('считаются скрытыми, пока настройка не прочитана', () async {
      final container = ProviderContainer(
        overrides: [
          databaseOpenerProvider.overrideWithValue(InMemoryDatabaseOpener()),
          screenSecurityProvider.overrideWithValue(FakeScreenSecurity()),
        ],
      );
      addTearDown(container.dispose);
      // Первый кадр до чтения БД: суммы скрыты.
      expect(container.read(hideAmountsProvider), isTrue);
      expect(container.read(amountFormatProvider).hidden, isTrue);
      expect(container.read(amountFormatProvider).full(100), AmountFormat.mask);
      // Настройки нет — после загрузки суммы видны.
      await pumpEventQueue(times: 200);
      expect(container.read(hideAmountsProvider), isFalse);
    });

    test('сохранённое «скрыть» остаётся скрытым', () async {
      final container = ProviderContainer(
        overrides: [
          databaseOpenerProvider.overrideWithValue(InMemoryDatabaseOpener()),
          screenSecurityProvider.overrideWithValue(FakeScreenSecurity()),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(localSettingsRepositoryProvider)
          .write(hideAmountsSettingKey, '1');
      expect(container.read(hideAmountsProvider), isTrue);
      await pumpEventQueue(times: 200);
      expect(container.read(hideAmountsProvider), isTrue);
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
