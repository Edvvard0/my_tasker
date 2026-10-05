import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/sleep/data/sleep_repository.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import 'calendar_env.dart' show appRegistry;
import 'fake_server/fake_sync_server.dart';
import 'manual_clock.dart';
import 'pump_app.dart';
import 'sync_env.dart';

export 'pump_app.dart' show desktopSize, expandedSize, mediumSize, phoneSize;
export 'work_env.dart' show goTo, locationOf, tapKey;

/// «Сейчас» для экранов «Сна» по умолчанию: понедельник, 5 октября 2026,
/// 08:00 по Москве (утро, сон ещё не записан).
final DateTime sleepMorning = DateTime.utc(2026, 10, 5, 5);

/// Вечер того же дня: 20:30 по Москве.
final DateTime sleepEvening = DateTime.utc(2026, 10, 5, 17, 30);

/// Устройство в тесте: репозитории «Сна» и задач поверх [TestDevice] (тесты
/// синхронизации и переноса без интерфейса).
class SleepDevice {
  SleepDevice(this.device, {String Function()? newId})
    : tasks = TaskRepository(
        device.store,
        newId: newId,
        now: () => device.clock.now,
      ) {
    sleep = SleepRepository(
      device.store,
      tasks: tasks,
      now: () => device.clock.now,
    );
  }

  static Future<SleepDevice> create(
    FakeSyncServer server, {
    ManualClock? clock,
    String Function()? newId,
  }) async => SleepDevice(
    await TestDevice.create(server, clock: clock, registry: appRegistry()),
    newId: newId,
  );

  final TestDevice device;
  final TaskRepository tasks;
  late final SleepRepository sleep;

  Future<void> close() => device.close();
}

/// Ночь [date] (день пробуждения по Москве): отбой в 23:40 накануне, подъём
/// в [wake] (`ЧЧ:ММ`).
Future<String> seedNight(
  SleepRepository repo,
  String date, {
  String bed = '23:40',
  String wake = '07:10',
  int? quality,
}) {
  final d = parseDate(date)!;
  final moscow = requireLocation('Europe/Moscow');
  int h(String t) => int.parse(t.substring(0, 2));
  int m(String t) => int.parse(t.substring(3));
  final wakeAt = wallToUtc(moscow, d.year, d.month, d.day, h(wake), m(wake));
  final bedDay = h(bed) < 12 ? d : addDays(d, -1);
  final bedAt = wallToUtc(
    moscow,
    bedDay.year,
    bedDay.month,
    bedDay.day,
    h(bed),
    m(bed),
  );
  return repo.saveSleep(
    bedAt: bedAt,
    wakeAt: wakeAt,
    wakeTz: 'Europe/Moscow',
    quality: quality,
  );
}

/// Запускает приложение на экране [location] с зафиксированным временем и
/// поясом Москвы; [seedWith] наполняет данными.
Future<ProviderContainer> pumpSleep(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/sleep',
  DateTime? now,
  Future<void> Function(ProviderContainer container)? seedWith,
  List<Override> overrides = const [],
}) async {
  final container = await pumpApp(
    tester,
    size: size,
    location: location,
    now: now ?? sleepMorning,
    settle: false,
    overrides: [
      deviceTimeZoneSourceProvider.overrideWithValue(
        const FixedTimeZoneSource('Europe/Moscow'),
      ),
      holidayCalendarProvider.overrideWith((ref) => HolidayCalendar.empty()),
      ...overrides,
    ],
  );
  if (seedWith != null) await tester.runAsync(() => seedWith(container));
  await tester.pumpAndSettle();
  return container;
}

/// Задача со сроком-датой.
Future<String> seedTask(
  ProviderContainer c,
  String title, {
  String? date,
  TaskStatus status = TaskStatus.todo,
  int? priority,
}) async {
  final repo = c.read(taskRepositoryProvider);
  final id = repo.newTaskId();
  await repo.createTask(
    TaskEntity(
      id: id,
      title: title,
      status: status,
      priority: priority,
      due: date == null ? const TaskDue.none() : TaskDue.date(parseDate(date)!),
    ),
  );
  return id;
}

/// Даёт завершиться чтению из БД (оно идёт в реальном времени) и дорисовывает.
Future<void> settleDb(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
  );
  await tester.pumpAndSettle();
}

/// Демо «Сна»: месяц ночей (последняя — этой ночью), задачи недели для
/// связи сна с задачами, утренние планы и чек-ины последних дней.
Future<void> seedSleepDemo(ProviderContainer c) async {
  final repo = c.read(sleepRepositoryProvider);
  const nights = <(String, String, String, int?)>[
    ('2026-09-06', '23:50', '07:20', null),
    ('2026-09-07', '00:40', '07:00', 3),
    ('2026-09-08', '23:30', '07:10', null),
    ('2026-09-09', '23:10', '06:50', 4),
    ('2026-09-11', '00:20', '07:40', null),
    ('2026-09-12', '01:10', '09:00', 5),
    ('2026-09-13', '23:40', '07:30', null),
    ('2026-09-15', '23:20', '07:00', null),
    ('2026-09-16', '00:10', '06:40', 3),
    ('2026-09-17', '23:50', '07:10', null),
    ('2026-09-18', '23:30', '07:05', null),
    ('2026-09-19', '01:30', '08:30', null),
    ('2026-09-20', '00:00', '08:00', 4),
    ('2026-09-22', '23:40', '07:10', null),
    ('2026-09-23', '23:50', '07:00', null),
    ('2026-09-24', '01:00', '06:30', 2),
    ('2026-09-25', '23:30', '07:15', null),
    ('2026-09-26', '00:30', '08:10', null),
    ('2026-09-27', '23:45', '07:30', null),
    ('2026-09-28', '23:20', '07:00', 4),
    ('2026-09-29', '23:40', '07:10', null),
    ('2026-09-30', '01:20', '06:50', null),
    ('2026-10-01', '23:35', '07:05', 4),
    ('2026-10-02', '02:00', '07:00', 2),
    ('2026-10-03', '00:15', '08:15', null),
    ('2026-10-04', '02:30', '07:00', 3),
    ('2026-10-05', '23:40', '07:10', 4),
  ];
  for (final (date, bed, wake, q) in nights) {
    await seedNight(repo, date, bed: bed, wake: wake, quality: q);
  }
  // Задачи недели: после короткого сна (2-е, 4-е) закрыто меньше.
  for (final (date, title, done) in const [
    ('2026-10-01', 'Отчёт по проекту', true),
    ('2026-10-01', 'Созвон с заказчиком', true),
    ('2026-10-02', 'Правки в вёрстке', false),
    ('2026-10-02', 'Счёт клиенту', true),
    ('2026-10-03', 'Лабораторная работа', true),
    ('2026-10-04', 'Доклад по физике', false),
    ('2026-10-04', 'Тесты для API', false),
  ]) {
    await seedTask(
      c,
      title,
      date: date,
      status: done ? TaskStatus.done : TaskStatus.todo,
    );
  }
  for (final d in ['2026-10-03', '2026-10-04']) {
    await repo.savePlan(date: d, taskIds: const []);
  }
  await repo.saveCheckin(date: '2026-10-04', doneTaskIds: const [], rating: 3);
  await repo.savePlan(date: '2026-10-02', taskIds: const []);
  await repo.saveCheckin(date: '2026-10-02', doneTaskIds: const [], rating: 4);
  await repo.saveCheckin(date: '2026-10-03', doneTaskIds: const [], rating: 4);
}
