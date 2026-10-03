import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';
import 'package:my_tasker/features/finance/data/pin_hasher.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';

import '../../../support/manual_clock.dart';
import '../../../support/privacy_env.dart';

/// Контейнер с замком на управляемых часах.
ProviderContainer _container({
  MemoryFinancePrivacyStore? store,
  FakeBiometric? biometric,
  ManualClock? clock,
}) {
  final time = clock ?? ManualClock();
  final c = ProviderContainer(
    overrides: [
      ...privacyOverrides(store: store, biometric: biometric),
      clockProvider.overrideWithValue(() => time.now),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<FinanceLockController> _loaded(ProviderContainer c) async {
  final controller = c.read(financeLockProvider.notifier);
  await controller.ready;
  return controller;
}

void main() {
  group('включение и хранение PIN', () {
    test('в хранилище — соль и хеш, не PIN; замок включён и открыт', () async {
      final store = MemoryFinancePrivacyStore();
      final c = _container(store: store);
      final lock = await _loaded(c);
      expect(c.read(financeLockProvider).enabled, isFalse);
      expect(c.read(financeLockProvider).closed, isFalse);

      await lock.enable(testPin);

      final record = store.record!;
      expect(record.toJsonString(), isNot(contains(testPin)));
      expect(record.salt, hasLength(16));
      expect(record.hash, hasLength(32));
      expect(record.hash, isNot(testPin.codeUnits));
      expect(record.pinLength, 4);
      final state = c.read(financeLockProvider);
      expect(state.enabled, isTrue);
      expect(state.locked, isFalse);
    });

    test('изолят: запись замка и проверка PIN идут через PinHasher(useIsolate: '
        'true) и дают тот же хеш, что прямой PBKDF2', () async {
      final store = MemoryFinancePrivacyStore();
      final c = ProviderContainer(
        overrides: [
          financePrivacyStoreProvider.overrideWithValue(store),
          // Уменьшенное число итераций, но настоящий путь через изолят.
          pinHasherProvider.overrideWithValue(const PinHasher(iterations: 40)),
        ],
      );
      addTearDown(c.dispose);
      final lock = await _loaded(c);
      await lock.enable(testPin);
      final record = store.record!;
      expect(record.iterations, 40);
      expect(
        record.hash,
        pbkdf2HmacSha256(utf8.encode(testPin), record.salt, 40, pinKeyBytes),
      );
      lock.lockNow();
      expect(await lock.unlock(testPinOther), isA<PinRejected>());
      expect(await lock.unlock(testPin), isA<PinAccepted>());
      expect(c.read(financeLockProvider).closed, isFalse);
    });

    test('соль у каждой записи своя: одинаковый PIN — разные хеши', () async {
      final a = MemoryFinancePrivacyStore();
      final b = MemoryFinancePrivacyStore();
      await (await _loaded(_container(store: a))).enable(testPin);
      await (await _loaded(_container(store: b))).enable(testPin);
      expect(a.record!.salt, isNot(b.record!.salt));
      expect(a.record!.hash, isNot(b.record!.hash));
    });

    test('PIN вне 4–6 цифр не принимается', () async {
      final lock = await _loaded(_container());
      for (final bad in ['123', '1234567', '12ab', '']) {
        await expectLater(lock.enable(bad), throwsArgumentError);
      }
    });

    test(
      'холодный старт: включённый замок закрыт, потом открывается PIN',
      () async {
        final store = MemoryFinancePrivacyStore(record: lockRecordFor(testPin));
        final c = _container(store: store);
        expect(c.read(financeLockProvider).loaded, isFalse);
        expect(c.read(financeLockProvider).closed, isTrue);
        final lock = await _loaded(c);
        final state = c.read(financeLockProvider);
        expect(state.loaded, isTrue);
        expect(state.enabled, isTrue);
        expect(state.locked, isTrue);
        expect(state.closed, isTrue);

        expect(await lock.unlock(testPin), isA<PinAccepted>());
        expect(c.read(financeLockProvider).closed, isFalse);
      },
    );

    test('замок выключен: раздел открыт сразу после чтения', () async {
      final c = _container();
      await _loaded(c);
      expect(c.read(financeLockProvider).closed, isFalse);
      expect(
        await c.read(financeLockProvider.notifier).unlock('0000'),
        isA<PinAccepted>(),
      );
    });

    test('хранилище недоступно: замок НЕ выключен, раздел закрыт, запись '
        'не тронута', () async {
      final store = MemoryFinancePrivacyStore(record: lockRecordFor(testPin))
        ..readError = StateError('keystore');
      final c = _container(store: store);
      final lock = await _loaded(c);
      final state = c.read(financeLockProvider);
      expect(state.loaded, isTrue);
      expect(state.problem, LockProblem.storageUnavailable);
      expect(state.closed, isTrue);
      expect(c.read(amountsMaskedProvider), isTrue);
      expect(c.read(financeAiAccessProvider).unlocked, isFalse);
      // Запись не удалялась и не переписывалась.
      expect(store.lockClears, 0);
      expect(store.lockWrites, 0);
      expect(store.record, isNotNull);

      // Ни PIN, ни биометрия, ни «включить» раздел не открывают.
      expect(await lock.unlock(testPin), isA<PinRejected>());
      expect(c.read(financeLockProvider).closed, isTrue);
      await expectLater(lock.enable(testPin), throwsStateError);
      expect(store.lockWrites, 0);
      // Сброс разрешён только для повреждённой записи.
      await lock.resetCorruptedLock();
      expect(store.lockClears, 0);
      expect(c.read(financeLockProvider).closed, isTrue);
    });

    test('«Повторить»: хранилище ожило — прежний замок на месте', () async {
      final store = MemoryFinancePrivacyStore(record: lockRecordFor(testPin))
        ..readError = StateError('keystore');
      final c = _container(store: store);
      final lock = await _loaded(c);
      expect(c.read(financeLockProvider).problem, isNotNull);

      // Всё ещё недоступно.
      await lock.retryLoad();
      expect(
        c.read(financeLockProvider).problem,
        LockProblem.storageUnavailable,
      );

      store.readError = null;
      await lock.retryLoad();
      final state = c.read(financeLockProvider);
      expect(state.problem, isNull);
      expect(state.enabled, isTrue);
      expect(state.locked, isTrue);
      expect(state.closed, isTrue);
      expect(await lock.unlock(testPin), isA<PinAccepted>());
      expect(c.read(financeLockProvider).closed, isFalse);
    });

    test('«Повторить»: замка нет — раздел открывается', () async {
      final store = MemoryFinancePrivacyStore()..readError = StateError('x');
      final c = _container(store: store);
      final lock = await _loaded(c);
      expect(c.read(financeLockProvider).closed, isTrue);
      store.readError = null;
      await lock.retryLoad();
      expect(c.read(financeLockProvider).closed, isFalse);
      expect(c.read(financeLockProvider).enabled, isFalse);
      // Без сбоя повтор ничего не делает.
      await lock.retryLoad();
      expect(c.read(financeLockProvider).closed, isFalse);
    });

    test('повреждённая запись: замок закрыт, запись не удалена, пока нет '
        'явного сброса', () async {
      final store = MemoryFinancePrivacyStore(corrupt: true);
      final c = _container(store: store);
      final lock = await _loaded(c);
      expect(c.read(financeLockProvider).problem, LockProblem.corrupted);
      expect(c.read(financeLockProvider).closed, isTrue);
      expect(store.corrupt, isTrue);
      expect(store.lockClears, 0);
      expect(await lock.unlock(testPin), isA<PinRejected>());
      expect(c.read(financeLockProvider).closed, isTrue);
      await expectLater(lock.enable(testPin), throwsStateError);

      await lock.resetCorruptedLock();
      expect(store.corrupt, isFalse);
      expect(store.lockClears, 1);
      final state = c.read(financeLockProvider);
      expect(state.problem, isNull);
      expect(state.enabled, isFalse);
      expect(state.closed, isFalse);
      // После сброса новый PIN задаётся как обычно.
      await lock.enable(testPin);
      expect(store.record, isNotNull);
    });
  });

  group('неверные попытки и пауза', () {
    late MemoryFinancePrivacyStore store;
    late ManualClock clock;
    late ProviderContainer c;
    late FinanceLockController lock;

    setUp(() async {
      store = MemoryFinancePrivacyStore(record: lockRecordFor(testPin));
      clock = ManualClock();
      c = _container(store: store, clock: clock);
      lock = await _loaded(c);
    });

    test('до пятой ошибки — счётчик попыток, пауза не включается', () async {
      for (var i = 1; i <= 4; i++) {
        final r = await lock.unlock(testPinOther) as PinRejected;
        expect(r.attemptsLeft, 5 - i);
        expect(r.pausedUntil, isNull);
      }
      expect(c.read(financeLockProvider).failures, 4);
      expect(store.record!.failures, 4);
      expect(c.read(financeLockProvider).locked, isTrue);
    });

    test('пятая ошибка — пауза 30 с; PIN в паузу не проверяется', () async {
      for (var i = 0; i < 4; i++) {
        await lock.unlock(testPinOther);
      }
      final fifth = await lock.unlock(testPinOther) as PinRejected;
      expect(fifth.attemptsLeft, 0);
      expect(fifth.pausedUntil, clock.now.add(const Duration(seconds: 30)));

      // Даже верный PIN во время паузы отклоняется и счётчик не растёт.
      final during = await lock.unlock(testPin);
      expect(during, isA<PinPaused>());
      expect(c.read(financeLockProvider).locked, isTrue);
      expect(store.record!.failures, 5);

      clock.advance(const Duration(seconds: 29));
      expect(await lock.unlock(testPin), isA<PinPaused>());
      clock.advance(const Duration(seconds: 2));
      expect(await lock.unlock(testPin), isA<PinAccepted>());
      expect(c.read(financeLockProvider).locked, isFalse);
      // Успех обнуляет счётчик и паузу и в хранилище.
      expect(store.record!.failures, 0);
      expect(store.record!.pausedUntilMs, isNull);
      expect(c.read(financeLockProvider).pausedUntil, isNull);
    });

    test('пауза растёт: 30 с, 60 с, 120 с', () async {
      for (var i = 0; i < 5; i++) {
        await lock.unlock(testPinOther);
      }
      clock.advance(const Duration(seconds: 31));
      final sixth = await lock.unlock(testPinOther) as PinRejected;
      expect(sixth.pausedUntil, clock.now.add(const Duration(seconds: 60)));
      clock.advance(const Duration(seconds: 61));
      final seventh = await lock.unlock(testPinOther) as PinRejected;
      expect(seventh.pausedUntil, clock.now.add(const Duration(seconds: 120)));
    });

    test('пауза переживает перезапуск приложения', () async {
      for (var i = 0; i < 5; i++) {
        await lock.unlock(testPinOther);
      }
      // Новый контейнер с тем же хранилищем и теми же часами.
      final again = _container(store: store, clock: clock);
      final controller = await _loaded(again);
      expect(again.read(financeLockProvider).pausedUntil, isNotNull);
      expect(await controller.unlock(testPin), isA<PinPaused>());
      clock.advance(const Duration(seconds: 31));
      expect(await controller.unlock(testPin), isA<PinAccepted>());
    });

    test('попытка записана до проверки: обрыв посреди хеширования её не '
        'стирает', () async {
      final c = ProviderContainer(
        overrides: [
          financePrivacyStoreProvider.overrideWithValue(store),
          pinHasherProvider.overrideWithValue(_DyingHasher()),
          clockProvider.overrideWithValue(() => clock.now),
        ],
      );
      addTearDown(c.dispose);
      final dying = await _loaded(c);
      for (var i = 0; i < 5; i++) {
        await expectLater(dying.unlock(testPinOther), throwsStateError);
      }
      // Хеш ни разу не досчитался, но пять попыток и пауза уже в хранилище.
      expect(store.record!.failures, 5);
      expect(store.record!.pausedUntilMs, isNotNull);
    });

    test('verifyPin считает попытки так же, но замок не открывает', () async {
      expect(await lock.verifyPin(testPinOther), isA<PinRejected>());
      expect(store.record!.failures, 1);
      expect(await lock.verifyPin(testPin), isA<PinAccepted>());
      expect(c.read(financeLockProvider).locked, isTrue);
      expect(store.record!.failures, 0);
    });
  });

  group('смена и отключение PIN', () {
    late MemoryFinancePrivacyStore store;
    late ProviderContainer c;
    late FinanceLockController lock;

    setUp(() async {
      store = MemoryFinancePrivacyStore(
        record: lockRecordFor(
          testPin,
          timing: LockTiming.minute5,
          biometric: true,
        ),
      );
      c = _container(store: store);
      lock = await _loaded(c);
      await lock.unlock(testPin);
    });

    test('смена: нужен текущий PIN; новый действует, старый — нет', () async {
      final before = store.record!;
      expect(await lock.changePin(testPinOther, '9753'), isA<PinRejected>());
      expect(store.record!.hash, before.hash);

      expect(await lock.changePin(testPin, '9753'), isA<PinAccepted>());
      expect(store.record!.hash, isNot(before.hash));
      expect(store.record!.salt, isNot(before.salt));
      // Тайминг и биометрия сохраняются.
      expect(store.record!.timing, LockTiming.minute5);
      expect(store.record!.biometric, isTrue);
      expect(store.record!.toJsonString(), isNot(contains('9753')));

      lock.lockNow();
      expect(await lock.unlock(testPin), isA<PinRejected>());
      expect(await lock.unlock('9753'), isA<PinAccepted>());
    });

    test('смена: некорректный новый PIN — ошибка, старый остаётся', () async {
      await expectLater(lock.changePin(testPin, '12'), throwsArgumentError);
      expect(await lock.verifyPin(testPin), isA<PinAccepted>());
    });

    test('смена во время паузы отклоняется', () async {
      for (var i = 0; i < 5; i++) {
        await lock.verifyPin(testPinOther);
      }
      expect(await lock.changePin(testPin, '9753'), isA<PinPaused>());
    });

    test('отключение требует текущий PIN', () async {
      expect(await lock.disable(testPinOther), isA<PinRejected>());
      expect(c.read(financeLockProvider).enabled, isTrue);
      expect(store.record, isNotNull);

      expect(await lock.disable(testPin), isA<PinAccepted>());
      expect(c.read(financeLockProvider).enabled, isFalse);
      expect(c.read(financeLockProvider).closed, isFalse);
      expect(store.record, isNull);
    });

    test('тайминг и биометрия сохраняются', () async {
      await lock.setTiming(LockTiming.minute1);
      expect(store.record!.timing, LockTiming.minute1);
      expect(c.read(financeLockProvider).timing, LockTiming.minute1);
      await lock.setBiometric(value: false);
      expect(store.record!.biometric, isFalse);
      expect(c.read(financeLockProvider).biometric, isFalse);
    });

    test('настройки без замка ничего не делают', () async {
      final c2 = _container();
      final l2 = await _loaded(c2);
      await l2.setTiming(LockTiming.minute5);
      await l2.setBiometric(value: true);
      expect(c2.read(financeLockProvider).enabled, isFalse);
      expect(await l2.disable(testPin), isA<PinAccepted>());
      l2.lockNow();
      expect(c2.read(financeLockProvider).closed, isFalse);
    });
  });

  group('биометрия', () {
    Future<(ProviderContainer, FinanceLockController)> start(
      FakeBiometric bio, {
      bool biometric = true,
    }) async {
      final c = _container(
        store: MemoryFinancePrivacyStore(
          record: lockRecordFor(testPin, biometric: biometric),
        ),
        biometric: bio,
      );
      return (c, await _loaded(c));
    }

    test('успех открывает раздел', () async {
      final bio = FakeBiometric(available: true);
      final (c, lock) = await start(bio);
      expect(await lock.unlockWithBiometric('открыть'), isTrue);
      expect(bio.prompts, 1);
      expect(c.read(financeLockProvider).locked, isFalse);
    });

    test(
      'отказ, недоступность и выключенная настройка — раздел закрыт',
      () async {
        var (c, lock) = await start(
          FakeBiometric(available: true, result: false),
        );
        expect(await lock.unlockWithBiometric('открыть'), isFalse);
        expect(c.read(financeLockProvider).locked, isTrue);

        final off = FakeBiometric();
        (c, lock) = await start(off);
        expect(await lock.unlockWithBiometric('открыть'), isFalse);
        expect(off.prompts, 0);

        final disabled = FakeBiometric(available: true);
        (c, lock) = await start(disabled, biometric: false);
        expect(await lock.unlockWithBiometric('открыть'), isFalse);
        expect(disabled.prompts, 0);
      },
    );
  });

  group('блокировка по времени (часы и таймеры подменены)', () {
    // Контейнер внутри fakeAsync: таймеры замка — поддельные.
    void scenario(
      LockTiming timing,
      void Function(
        FakeAsync async,
        ProviderContainer c,
        FinanceLockController lock,
        ManualClock clock,
      )
      body,
    ) {
      fakeAsync((async) {
        final clock = ManualClock();
        final store = MemoryFinancePrivacyStore(
          record: lockRecordFor(testPin, timing: timing),
        );
        final c = ProviderContainer(
          overrides: [
            ...privacyOverrides(store: store),
            clockProvider.overrideWithValue(() => clock.now),
          ],
        );
        final lock = c.read(financeLockProvider.notifier);
        async.flushMicrotasks();
        unawaitedFuture(lock.unlock(testPin));
        async.flushMicrotasks();
        expect(c.read(financeLockProvider).locked, isFalse);
        body(async, c, lock, clock);
        c.dispose();
      });
    }

    void elapse(FakeAsync async, ManualClock clock, Duration d) {
      clock.advance(d);
      async.elapse(d);
    }

    bool locked(ProviderContainer c) => c.read(financeLockProvider).locked;

    test('«сразу»: ушёл из раздела — закрыто в тот же момент', () {
      scenario(LockTiming.immediately, (async, c, lock, clock) {
        lock.setSectionActive(value: true);
        expect(locked(c), isFalse);
        lock.setSectionActive(value: false);
        expect(locked(c), isTrue);
      });
    });

    test('«сразу»: свернул приложение — закрыто', () {
      scenario(LockTiming.immediately, (async, c, lock, clock) {
        lock
          ..setSectionActive(value: true)
          ..setForeground(value: false);
        expect(locked(c), isTrue);
      });
    });

    test('«через 1 мин»: закрывается ровно после минуты', () {
      scenario(LockTiming.minute1, (async, c, lock, clock) {
        lock
          ..setSectionActive(value: true)
          ..setSectionActive(value: false);
        expect(locked(c), isFalse);
        elapse(async, clock, const Duration(seconds: 59));
        expect(locked(c), isFalse);
        elapse(async, clock, const Duration(seconds: 2));
        expect(locked(c), isTrue);
      });
    });

    test('«через 5 мин»: закрывается только после пяти минут', () {
      scenario(LockTiming.minute5, (async, c, lock, clock) {
        lock
          ..setSectionActive(value: true)
          ..setSectionActive(value: false);
        elapse(async, clock, const Duration(minutes: 4, seconds: 59));
        expect(locked(c), isFalse);
        elapse(async, clock, const Duration(seconds: 2));
        expect(locked(c), isTrue);
      });
    });

    test('вернулся раньше срока — таймер снят, раздел остаётся открытым', () {
      scenario(LockTiming.minute1, (async, c, lock, clock) {
        lock
          ..setSectionActive(value: true)
          ..setSectionActive(value: false);
        elapse(async, clock, const Duration(seconds: 30));
        lock.setSectionActive(value: true);
        elapse(async, clock, const Duration(minutes: 10));
        expect(locked(c), isFalse);
      });
    });

    test('фон приложения: свернул на 30 с — открыто, на 2 мин — закрыто', () {
      scenario(LockTiming.minute1, (async, c, lock, clock) {
        lock
          ..setSectionActive(value: true)
          ..setForeground(value: false);
        elapse(async, clock, const Duration(seconds: 30));
        lock.setForeground(value: true);
        expect(locked(c), isFalse);

        lock.setForeground(value: false);
        elapse(async, clock, const Duration(minutes: 2));
        expect(locked(c), isTrue);
      });
    });

    test('таймер заснул вместе с приложением: по возвращении сверяем часы', () {
      scenario(LockTiming.minute1, (async, c, lock, clock) {
        lock
          ..setSectionActive(value: true)
          ..setForeground(value: false);
        // Часы ушли вперёд, а таймер не сработал (процесс был заморожен).
        clock.advance(const Duration(minutes: 3));
        expect(locked(c), isFalse);
        lock.setForeground(value: true);
        expect(locked(c), isTrue);
      });
    });

    test('повторные события «ушёл» и «вернулся» состояние не ломают', () {
      scenario(LockTiming.immediately, (async, c, lock, clock) {
        lock
          ..setSectionActive(value: true)
          // Пока пользователь в разделе, открыт; ушёл — закрыто.
          ..setSectionActive(value: false);
        expect(locked(c), isTrue);
        lock
          ..setForeground(value: false)
          ..setForeground(value: true);
        expect(locked(c), isTrue);
      });
    });

    test('уже закрытый замок при уходе не взводит таймер', () {
      scenario(LockTiming.minute1, (async, c, lock, clock) {
        lock
          ..lockNow()
          ..setSectionActive(value: true)
          ..setSectionActive(value: false);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('режим «скрыть суммы»', () {
    test(
      'до чтения настройки суммы скрыты; чтение и запись в хранилище',
      () async {
        final store = MemoryFinancePrivacyStore(hidden: true);
        final c = _container(store: store);
        expect(c.read(hideAmountsProvider).masked, isTrue);
        await c.read(hideAmountsProvider.notifier).ready;
        expect(c.read(hideAmountsProvider).hidden, isTrue);
        expect(c.read(hideAmountsProvider).loaded, isTrue);

        await c.read(hideAmountsProvider.notifier).toggle();
        expect(c.read(hideAmountsProvider).hidden, isFalse);
        expect(store.hidden, isFalse);
        await c.read(hideAmountsProvider.notifier).set(hidden: true);
        expect(store.hidden, isTrue);
      },
    );

    test('по умолчанию суммы видны', () async {
      final c = _container();
      await c.read(hideAmountsProvider.notifier).ready;
      expect(c.read(hideAmountsProvider).masked, isFalse);
    });

    test('сбой хранилища не мешает переключать режим', () async {
      final c = ProviderContainer(
        overrides: [
          financePrivacyStoreProvider.overrideWithValue(_BrokenStore()),
        ],
      );
      addTearDown(c.dispose);
      await c.read(hideAmountsProvider.notifier).ready;
      expect(c.read(hideAmountsProvider).hidden, isFalse);
      await c.read(hideAmountsProvider.notifier).toggle();
      expect(c.read(hideAmountsProvider).hidden, isTrue);
    });

    test('маска единая: режим «скрыть суммы» или закрытый замок', () async {
      final store = MemoryFinancePrivacyStore(record: lockRecordFor(testPin));
      final c = _container(store: store);
      await _loaded(c);
      await c.read(hideAmountsProvider.notifier).ready;
      // Замок закрыт — суммы скрыты, хотя режим выключен.
      expect(c.read(amountsMaskedProvider), isTrue);
      await c.read(financeLockProvider.notifier).unlock(testPin);
      expect(c.read(amountsMaskedProvider), isFalse);
      await c.read(hideAmountsProvider.notifier).set(hidden: true);
      expect(c.read(amountsMaskedProvider), isTrue);
    });
  });

  group('доступ ИИ к Финансам', () {
    test('замок закрыт — данных нет; открыт — зависит от «скрыть суммы» и '
        'согласия', () async {
      final store = MemoryFinancePrivacyStore(record: lockRecordFor(testPin));
      // Подписка держит автоочищаемые зависимости живыми.
      final c = _container(store: store)
        ..listen(financeAiAccessProvider, (_, _) {});
      await _loaded(c);
      await c.read(hideAmountsProvider.notifier).ready;
      expect(c.read(financeAiAccessProvider).unlocked, isFalse);

      await c.read(financeLockProvider.notifier).unlock(testPin);
      var access = c.read(financeAiAccessProvider);
      expect(access.unlocked, isTrue);
      expect(access.amounts, isTrue);

      // Включили «скрыть суммы»: суммы по умолчанию не отправляются.
      await c.read(hideAmountsProvider.notifier).set(hidden: true);
      access = c.read(financeAiAccessProvider);
      expect(access.unlocked, isTrue);
      expect(access.amounts, isFalse);

      // Явное подтверждение в превью разрешает суммы.
      c.read(financeAiAmountsConsentProvider.notifier).set(value: true);
      expect(c.read(financeAiAccessProvider).amounts, isTrue);

      // Смена режима отзывает согласие.
      await c.read(hideAmountsProvider.notifier).set(hidden: false);
      await c.read(hideAmountsProvider.notifier).set(hidden: true);
      expect(c.read(financeAiAmountsConsentProvider), isFalse);
      expect(c.read(financeAiAccessProvider).amounts, isFalse);

      // Блокировка раздела тоже отзывает согласие и закрывает данные.
      c.read(financeAiAmountsConsentProvider.notifier).set(value: true);
      c.read(financeLockProvider.notifier).lockNow();
      expect(c.read(financeAiAmountsConsentProvider), isFalse);
      expect(c.read(financeAiAccessProvider).unlocked, isFalse);
    });
  });
}

/// Нужен там, где `unawaited` из `dart:async` лишний шум.
void unawaitedFuture(Future<void> future) {}

/// Хеширование, которое обрывается (процесс убит посреди вычисления).
class _DyingHasher extends PinHasher {
  @override
  Future<List<int>> derive(String pin, List<int> salt, int iterations) =>
      Future.error(StateError('process killed'));
}

class _BrokenStore implements FinancePrivacyStore {
  @override
  Future<LockRecord?> readLock() => Future.error(StateError('keystore'));

  @override
  Future<void> writeLock(LockRecord record) =>
      Future.error(StateError('keystore'));

  @override
  Future<void> clearLock() => Future.error(StateError('keystore'));

  @override
  Future<bool> readHideAmounts() => Future.error(StateError('keystore'));

  @override
  Future<void> writeHideAmounts({required bool hidden}) =>
      Future.error(StateError('keystore'));
}
