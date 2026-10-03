import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:my_tasker/features/finance/data/biometric_authenticator.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';
import 'package:my_tasker/features/finance/data/pin_hasher.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';

import '../../../support/privacy_env.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Платформа `local_auth` по сценарию теста.
class _FakeLocalAuth extends LocalAuthPlatform {
  bool supported = true;
  List<BiometricType> enrolled = [BiometricType.fingerprint];
  bool result = true;
  bool throws = false;
  bool? lastBiometricOnly;

  @override
  Future<bool> isDeviceSupported() async {
    if (throws) throw Exception('plugin');
    return supported;
  }

  @override
  Future<bool> deviceSupportsBiometrics() async => supported;

  @override
  Future<List<BiometricType>> getEnrolledBiometrics() async {
    if (throws) throw Exception('plugin');
    return enrolled;
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    if (throws) throw Exception('plugin');
    lastBiometricOnly = options.biometricOnly;
    return result;
  }
}

void main() {
  group('PBKDF2-HMAC-SHA256', () {
    // Векторы: RFC 7914 (раздел 11) и общеизвестные векторы PBKDF2-SHA256.
    test('вектор «password/salt», 1 итерация', () {
      expect(
        _hex(
          pbkdf2HmacSha256(utf8.encode('password'), utf8.encode('salt'), 1, 32),
        ),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
    });

    test('вектор «password/salt», 2 и 4096 итераций', () {
      expect(
        _hex(
          pbkdf2HmacSha256(utf8.encode('password'), utf8.encode('salt'), 2, 32),
        ),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
      expect(
        _hex(
          pbkdf2HmacSha256(
            utf8.encode('password'),
            utf8.encode('salt'),
            4096,
            32,
          ),
        ),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
    });

    test('RFC 7914: «passwd/salt», 1 итерация, 64 байта (два блока)', () {
      expect(
        _hex(
          pbkdf2HmacSha256(utf8.encode('passwd'), utf8.encode('salt'), 1, 64),
        ),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
    });

    test('PinHasher: без изолята и в изоляте — один и тот же ключ', () async {
      const salt = [1, 2, 3, 4, 5, 6, 7, 8];
      final direct = await const PinHasher(
        iterations: 20,
        useIsolate: false,
      ).derive('2468', salt, 20);
      final isolated = await const PinHasher(iterations: 20)
          .derive('2468', salt, 20);
      expect(isolated, direct);
      expect(direct, hasLength(pinKeyBytes));
      expect(const PinHasher().iterations, defaultPinIterations);
    });

    test('PinHasher(useIsolate: true): ключ из изолята равен прямому '
        'PBKDF2 при любом числе итераций', () async {
      const salt = [9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6];
      for (final iterations in [1, 2, 50, 4096]) {
        // Число итераций подставляется в изолят, как у записи замка.
        final hasher = PinHasher(iterations: iterations);
        expect(hasher.useIsolate, isTrue);
        final isolated = await hasher.derive('135790', salt, iterations);
        final direct = pbkdf2HmacSha256(
          utf8.encode('135790'),
          salt,
          iterations,
          pinKeyBytes,
        );
        expect(isolated, direct, reason: '$iterations итераций');
        // Другой PIN и другая соль дают другой ключ.
        expect(await hasher.derive('135791', salt, iterations), isNot(direct));
        expect(
          await hasher.derive('135790', [...salt, 1], iterations),
          isNot(direct),
        );
      }
    });

    test('сравнение за постоянное время и случайная соль', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
      final a = randomPinSalt(Random.secure());
      final b = randomPinSalt(Random.secure());
      expect(a, hasLength(pinSaltBytes));
      expect(a, isNot(b));
    });
  });

  group('правила PIN и пауз', () {
    test('PIN — 4–6 цифр', () {
      expect(isValidPin('1234'), isTrue);
      expect(isValidPin('123456'), isTrue);
      expect(isValidPin('123'), isFalse);
      expect(isValidPin('1234567'), isFalse);
      expect(isValidPin('12a4'), isFalse);
      expect(isValidPin(''), isFalse);
    });

    test('пауза: нет до пятой ошибки, 30 с, затем удвоение до часа', () {
      expect(pauseAfterFailures(4), Duration.zero);
      expect(pauseAfterFailures(5), const Duration(seconds: 30));
      expect(pauseAfterFailures(6), const Duration(seconds: 60));
      expect(pauseAfterFailures(7), const Duration(seconds: 120));
      expect(pauseAfterFailures(8), const Duration(seconds: 240));
      expect(pauseAfterFailures(30), maxPause);
      expect(attemptsLeft(0), 5);
      expect(attemptsLeft(3), 2);
      expect(attemptsLeft(5), 0);
      expect(attemptsLeft(9), 0);
    });

    test('тайминг: разбор и строгое значение по умолчанию', () {
      expect(LockTiming.parse('1m'), LockTiming.minute1);
      expect(LockTiming.parse('5m'), LockTiming.minute5);
      expect(LockTiming.parse('immediately'), LockTiming.immediately);
      expect(LockTiming.parse('???'), LockTiming.immediately);
      expect(LockTiming.minute5.delay, const Duration(minutes: 5));
    });
  });

  group('LockRecord', () {
    test('круг JSON: PIN в записи нет, только соль и хеш', () {
      final record = lockRecordFor(
        testPin,
        timing: LockTiming.minute5,
        biometric: true,
        failures: 2,
        pausedUntilMs: 1234,
      );
      final raw = record.toJsonString();
      expect(raw, isNot(contains(testPin)));
      final back = LockRecord.tryParse(raw)!;
      expect(back.salt, record.salt);
      expect(back.hash, record.hash);
      expect(back.iterations, record.iterations);
      expect(back.pinLength, 4);
      expect(back.timing, LockTiming.minute5);
      expect(back.biometric, isTrue);
      expect(back.failures, 2);
      expect(back.pausedUntilMs, 1234);
      // Хеш — не PIN: ни в виде текста, ни в виде байтов.
      expect(utf8.decode(back.hash, allowMalformed: true), isNot(testPin));
      expect(back.hash, isNot(utf8.encode(testPin)));
    });

    test('повреждённая запись не разбирается', () {
      expect(LockRecord.tryParse('{not json'), isNull);
      expect(LockRecord.tryParse('{"v":1}'), isNull);
      expect(
        LockRecord.tryParse(
          lockRecordFor(testPin).copyWith(iterations: 0).toJsonString(),
        ),
        isNull,
      );
      expect(
        LockRecord.tryParse(
          lockRecordFor(testPin).copyWith(pinLength: 9).toJsonString(),
        ),
        isNull,
      );
    });

    test('copyWith сбрасывает паузу по флагу', () {
      final r = lockRecordFor(testPin, pausedUntilMs: 5, failures: 5);
      expect(r.copyWith(clearPause: true).pausedUntilMs, isNull);
      expect(r.copyWith(failures: 0).pausedUntilMs, 5);
    });
  });

  group('SecureFinancePrivacyStore', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('запись замка и флаг «скрыть суммы» кладутся в защищённое '
        'хранилище', () async {
      final store = SecureFinancePrivacyStore();
      expect(await store.readLock(), isNull);
      expect(await store.readHideAmounts(), isFalse);

      final record = lockRecordFor(testPin);
      await store.writeLock(record);
      await store.writeHideAmounts(hidden: true);

      final back = await store.readLock();
      expect(back!.hash, record.hash);
      expect(await store.readHideAmounts(), isTrue);
      const storage = FlutterSecureStorage();
      final raw = await storage.read(key: SecureFinancePrivacyStore.lockKey);
      expect(raw, isNot(contains(testPin)));

      await store.writeHideAmounts(hidden: false);
      expect(await store.readHideAmounts(), isFalse);
      await store.clearLock();
      expect(await store.readLock(), isNull);
    });

    test('повреждённая запись — ошибка чтения, а не «замка нет»; запись '
        'не удаляется до явного сброса', () async {
      FlutterSecureStorage.setMockInitialValues({
        SecureFinancePrivacyStore.lockKey: '{not json',
      });
      final store = SecureFinancePrivacyStore();
      await expectLater(store.readLock(), throwsA(isA<CorruptLockRecord>()));
      const storage = FlutterSecureStorage();
      expect(
        await storage.read(key: SecureFinancePrivacyStore.lockKey),
        '{not json',
      );
      await store.clearLock();
      expect(await store.readLock(), isNull);
    });

    test('память: то же поведение для тестов', () async {
      final store = MemoryFinancePrivacyStore();
      await store.writeLock(lockRecordFor(testPin));
      expect(store.lockWrites, 1);
      expect(await store.readLock(), isNotNull);
      await store.writeHideAmounts(hidden: true);
      expect(await store.readHideAmounts(), isTrue);
      await store.clearLock();
      expect(await store.readLock(), isNull);
      store
        ..corrupt = true
        ..readError = null;
      await expectLater(store.readLock(), throwsA(isA<CorruptLockRecord>()));
      await store.clearLock();
      expect(store.corrupt, isFalse);
      store.readError = StateError('x');
      await expectLater(store.readLock(), throwsStateError);
    });
  });

  group('LocalAuthBiometric', () {
    late _FakeLocalAuth platform;
    late LocalAuthPlatform previous;

    setUp(() {
      previous = LocalAuthPlatform.instance;
      platform = _FakeLocalAuth();
      LocalAuthPlatform.instance = platform;
    });
    tearDown(() {
      LocalAuthPlatform.instance = previous;
      debugDefaultTargetPlatformOverride = null;
    });

    test(
      'Android: доступна при настроенной биометрии; только биометрия',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final auth = LocalAuthBiometric(auth: LocalAuthentication());
        expect(await auth.isAvailable(), isTrue);
        expect(await auth.authenticate('открыть'), isTrue);
        expect(platform.lastBiometricOnly, isTrue);

        platform.enrolled = [];
        expect(await auth.isAvailable(), isFalse);
        platform.supported = false;
        expect(await auth.isAvailable(), isFalse);
        platform
          ..supported = true
          ..result = false;
        expect(await auth.authenticate('открыть'), isFalse);
      },
    );

    test('Windows: хватает «устройство умеет» (Windows Hello)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      platform.enrolled = [];
      final auth = LocalAuthBiometric();
      expect(await auth.isAvailable(), isTrue);
      expect(await auth.authenticate('открыть'), isTrue);
      expect(platform.lastBiometricOnly, isFalse);
    });

    test('другие платформы и сбой плагина — биометрии нет', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final auth = LocalAuthBiometric();
      expect(await auth.isAvailable(), isFalse);
      expect(await auth.authenticate('открыть'), isFalse);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      platform.throws = true;
      expect(await auth.isAvailable(), isFalse);
      expect(await auth.authenticate('открыть'), isFalse);
    });
  });
}
