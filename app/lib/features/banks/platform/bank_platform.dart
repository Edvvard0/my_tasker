import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';

/// Тонкая платформенная прослойка Банков (spec `stage6_banks.md`, 2):
/// слушатель уведомлений Android и системные настройки доступа. Вся логика
/// (разбор, дедупликация, черновики) — в Dart за этим интерфейсом и
/// покрыта тестами на поддельной платформе. Реализации:
/// `createPlatformBankPlatform` (Android, Kotlin `NotificationListenerService`),
/// [NoBankPlatform] — Windows и тесты.
abstract interface class BankPlatform {
  /// Есть ли слушатель уведомлений на этой платформе (только Android).
  bool get isSupported;

  /// Белый список пакетов банков: слушатель отдаёт только их.
  Future<void> setWatchedPackages(List<String> packages);

  /// Выдано ли приложению «Доступ к уведомлениям».
  Future<bool> isListenerEnabled();

  /// Открывает системный экран «Доступ к уведомлениям».
  Future<void> openListenerSettings();

  /// Исключено ли приложение из оптимизации батареи.
  Future<bool> isIgnoringBatteryOptimizations();

  /// Открывает системные настройки оптимизации батареи.
  Future<void> openBatterySettings();

  /// Забирает накопленные уведомления: слушатель мог получить их, пока
  /// приложение не было запущено. Очередь на устройстве **не очищается**,
  /// пока пачка не подтверждена [acknowledge]: если приложение упадёт или
  /// обработка прервётся, следующий [drain] отдаст те же уведомления снова
  /// (повторы отсекает отпечаток).
  Future<List<RawNotification>> drain();

  /// Пачка, полученная последним [drain], обработана: её можно удалить с
  /// устройства.
  Future<void> acknowledge();

  /// Сигнал «пришли новые уведомления» (затем вызывается [drain]).
  Stream<void> get wakeups;
}

/// Платформа без слушателя (Windows, тесты).
class NoBankPlatform implements BankPlatform {
  const NoBankPlatform();

  @override
  bool get isSupported => false;

  @override
  Future<void> setWatchedPackages(List<String> packages) async {}

  @override
  Future<bool> isListenerEnabled() async => false;

  @override
  Future<void> openListenerSettings() async {}

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => false;

  @override
  Future<void> openBatterySettings() async {}

  @override
  Future<List<RawNotification>> drain() async => const [];

  @override
  Future<void> acknowledge() async {}

  @override
  Stream<void> get wakeups => const Stream<void>.empty();
}

/// Платформа Банков; `main.dart` подставляет Android-реализацию.
final bankPlatformProvider = Provider<BankPlatform>(
  (ref) => const NoBankPlatform(),
);
