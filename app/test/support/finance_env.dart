import 'package:my_tasker/features/finance/data/finance_repository.dart';

import 'calendar_env.dart';
import 'fake_server/fake_sync_server.dart';
import 'manual_clock.dart';
import 'sync_env.dart';

/// UUIDv7-подобный id для тестов.
String uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Устройство с репозиторием Финансов поверх [TestDevice] (реестр
/// приложения: настоящие таблицы этапа 5).
class FinanceDevice {
  FinanceDevice(this.device, {String Function()? newId})
    : finance = FinanceRepository(
        device.store,
        newId: newId,
        now: () => device.clock.now,
      );

  static Future<FinanceDevice> create(
    FakeSyncServer server, {
    ManualClock? clock,
    String Function()? newId,
  }) async => FinanceDevice(
    await TestDevice.create(server, clock: clock, registry: appRegistry()),
    newId: newId,
  );

  final TestDevice device;
  final FinanceRepository finance;

  Future<void> close() => device.close();
}
