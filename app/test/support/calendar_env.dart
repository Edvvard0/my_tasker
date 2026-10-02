import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sync_table.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';

import 'fake_server/fake_sync_server.dart';
import 'manual_clock.dart';
import 'sync_env.dart';

/// Реестр приложения (Этап 2 включён): настоящие таблицы календаря.
SyncRegistry appRegistry() => SyncRegistry(registeredSyncTables);

/// Сервер с реестром приложения.
FakeSyncServer appServer(ManualClock clock) =>
    FakeSyncServer(registry: appRegistry(), nowMs: clock.call);

/// Устройство с репозиториями календаря и задач поверх [TestDevice].
class CalendarDevice {
  CalendarDevice(this.device, {String Function()? newId})
    : calendars = CalendarRepository(device.store, newId: newId),
      tasks = TaskRepository(
        device.store,
        newId: newId,
        now: () => device.clock.now,
      );

  static Future<CalendarDevice> create(
    FakeSyncServer server, {
    ManualClock? clock,
    String Function()? newId,
  }) async => CalendarDevice(
    await TestDevice.create(server, clock: clock, registry: appRegistry()),
    newId: newId,
  );

  final TestDevice device;
  final CalendarRepository calendars;
  final TaskRepository tasks;

  Future<void> close() => device.close();
}
