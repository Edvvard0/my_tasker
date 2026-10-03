import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/data/biometric_authenticator.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';
import 'package:my_tasker/features/finance/data/pin_hasher.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';

/// Поддельный PIN для тестов (настоящих PIN в репозитории нет).
const String testPin = '2468';
const String testPinOther = '1357';

/// Дешёвый вариант PBKDF2 без изолята: тесты не ждут 150 000 итераций.
const PinHasher fastPinHasher = PinHasher(iterations: 50, useIsolate: false);

/// Биометрия по сценарию теста.
class FakeBiometric implements BiometricAuthenticator {
  FakeBiometric({this.available = false, this.result = true});

  bool available;
  bool result;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return result;
  }
}

/// Запись замка с PIN [pin] (дешёвый хеш), как её пишет контроллер.
LockRecord lockRecordFor(
  String pin, {
  LockTiming timing = LockTiming.immediately,
  bool biometric = false,
  int failures = 0,
  int? pausedUntilMs,
}) {
  const salt = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
  final hash = pbkdf2HmacSha256(
    utf8.encode(pin),
    salt,
    fastPinHasher.iterations,
    pinKeyBytes,
  );
  return LockRecord(
    salt: salt,
    hash: hash,
    iterations: fastPinHasher.iterations,
    pinLength: pin.length,
    timing: timing,
    biometric: biometric,
    failures: failures,
    pausedUntilMs: pausedUntilMs,
  );
}

/// Подмены приватности для тестов: память вместо защищённого хранилища,
/// быстрый хеш, поддельная биометрия.
List<Override> privacyOverrides({
  MemoryFinancePrivacyStore? store,
  FakeBiometric? biometric,
}) => [
  financePrivacyStoreProvider.overrideWithValue(
    store ?? MemoryFinancePrivacyStore(),
  ),
  pinHasherProvider.overrideWithValue(fastPinHasher),
  biometricAuthenticatorProvider.overrideWithValue(
    biometric ?? FakeBiometric(),
  ),
];

/// Хранилище с включённым замком (PIN [testPin]).
MemoryFinancePrivacyStore lockedStore({
  LockTiming timing = LockTiming.immediately,
  bool biometric = false,
  bool hidden = false,
}) => MemoryFinancePrivacyStore(
  record: lockRecordFor(testPin, timing: timing, biometric: biometric),
  hidden: hidden,
);

/// Нажимает цифры на клавиатуре PIN и даёт проверке завершиться.
Future<void> enterPin(WidgetTester tester, String pin) async {
  for (final digit in pin.split('')) {
    await tester.tap(find.byKey(Key('pin-key-$digit')));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// Текст сообщения под точками PIN.
String pinMessage(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('pin-message'))).data!;
