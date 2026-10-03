import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';

/// Хранилище приватности «Финансов»: запись замка (соль и хеш PIN, тайминг,
/// биометрия, счётчик неверных попыток) и флаг «скрыть суммы».
///
/// Лежит там же, где ключ БД и токены, — в защищённом хранилище ОС (Android
/// Keystore, Windows DPAPI). В БД и в синхронизацию это не попадает.
abstract interface class FinancePrivacyStore {
  /// Запись замка или `null`, если замка нет. Бросает [CorruptLockRecord],
  /// если запись есть, но повреждена; любое другое исключение — хранилище
  /// недоступно (запись при этом не удаляется).
  Future<LockRecord?> readLock();

  Future<void> writeLock(LockRecord record);

  Future<void> clearLock();

  Future<bool> readHideAmounts();

  Future<void> writeHideAmounts({required bool hidden});
}

/// Реализация на `flutter_secure_storage`.
class SecureFinancePrivacyStore implements FinancePrivacyStore {
  SecureFinancePrivacyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const lockKey = 'finance_lock_v1'; // gitleaks:allow
  static const hideKey = 'finance_hide_amounts_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<LockRecord?> readLock() async {
    final raw = await _storage.read(key: lockKey);
    if (raw == null) return null;
    final record = LockRecord.tryParse(raw);
    // Повреждённая запись — не «замка нет»: иначе порча хранилища отключала
    // бы замок. Запись не трогаем; замок остаётся закрытым, пока
    // пользователь явно не сбросит его (`clearLock`).
    if (record == null) throw const CorruptLockRecord();
    return record;
  }

  @override
  Future<void> writeLock(LockRecord record) =>
      _storage.write(key: lockKey, value: record.toJsonString());

  @override
  Future<void> clearLock() => _storage.delete(key: lockKey);

  @override
  Future<bool> readHideAmounts() async =>
      await _storage.read(key: hideKey) == '1';

  @override
  Future<void> writeHideAmounts({required bool hidden}) =>
      _storage.write(key: hideKey, value: hidden ? '1' : '0');
}

/// Хранилище в памяти (тесты).
class MemoryFinancePrivacyStore implements FinancePrivacyStore {
  MemoryFinancePrivacyStore({
    this.record,
    this.hidden = false,
    this.corrupt = false,
  });

  LockRecord? record;
  bool hidden;
  int lockWrites = 0;
  int lockClears = 0;

  /// В хранилище лежит неразбираемая запись замка.
  bool corrupt;

  /// Чтение записи замка падает с этой ошибкой (хранилище недоступно).
  Object? readError;

  @override
  Future<LockRecord?> readLock() {
    final error = readError;
    if (error != null) return Future<LockRecord?>.error(error);
    if (corrupt) return Future<LockRecord?>.error(const CorruptLockRecord());
    return Future.value(record);
  }

  @override
  Future<void> writeLock(LockRecord value) async {
    lockWrites++;
    record = value;
  }

  @override
  Future<void> clearLock() async {
    lockClears++;
    record = null;
    corrupt = false;
  }

  @override
  Future<bool> readHideAmounts() async => hidden;

  @override
  Future<void> writeHideAmounts({required bool hidden}) async =>
      this.hidden = hidden;
}
