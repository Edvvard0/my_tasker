import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/reminders/headless_reminders.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../support/calendar_env.dart';
import '../../support/fake_reminder_scheduler.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Даёт циклу событий отработать (потоки БД, склейка правок): без ожидания
/// реального времени — только повороты цикла, пока не выполнено [until].
Future<void> _settle(bool Function() until) async {
  for (var i = 0; i < 200 && !until(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(until(), isTrue, reason: 'условие не наступило');
}

/// Ждёт очередного пересчёта сервиса.
Future<void> _nextReplan(ReminderService service, int before) =>
    _settle(() => service.replans > before);

void main() {
  ensureTimeZones();
  late ManualClock clock;
  late FakeSyncServer server;
  late CalendarDevice phone;
  late FakeReminderScheduler scheduler;
  late ReminderService service;
  late tz.Location zone;
  final personal = systemCalendarId('personal');

  ReminderService makeService({
    Duration? refreshEvery,
    PeriodicTimerFactory? periodic,
  }) => ReminderService(
    store: phone.device.store,
    scheduler: scheduler,
    settings: CalendarSettingsRepository(
      UserSettingsRepository(phone.device.store),
    ),
    zone: () => zone,
    now: () => clock.now,
    debounce: Duration.zero,
    refreshEvery: refreshEvery,
    periodicTimer: periodic ?? Timer.periodic,
  );

  ReminderService makeServiceWith(List<ExtraReminderSource> sources) =>
      ReminderService(
        store: phone.device.store,
        scheduler: scheduler,
        settings: CalendarSettingsRepository(
          UserSettingsRepository(phone.device.store),
        ),
        zone: () => zone,
        now: () => clock.now,
        debounce: Duration.zero,
        refreshEvery: null,
        extraSources: sources,
      );

  EventEntity event(int n, String start, {List<int> reminders = const [0]}) =>
      EventEntity(
        id: _uuid(n),
        calendarId: personal,
        title: 'Событие $n',
        allDay: false,
        startAt: parseInstant(start),
        endAt: parseInstant(start)!.add(const Duration(hours: 1)),
        tz: 'Europe/Moscow',
        reminders: reminders,
      );

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 6).millisecondsSinceEpoch);
    server = appServer(clock);
    zone = requireLocation('Europe/Moscow');
    phone = await CalendarDevice.create(server, clock: clock);
    await phone.calendars.ensureSystemCalendars();
    scheduler = FakeReminderScheduler();
    service = makeService();
  });
  tearDown(() async {
    await service.stop();
    await phone.close();
    await server.dispose();
  });

  test('старт планирует существующее', () async {
    await phone.calendars.createEvent(event(1, '2026-10-06T07:00:00Z'));
    await service.start();
    expect(scheduler.sorted.map((r) => formatInstant(r.fireAt)), [
      '2026-10-06T07:00:00Z',
    ]);
    expect(service.replans, 1);
  });

  test(
    'правка события пересчитывает: старое отменяется, новое планируется',
    () async {
      await phone.calendars.createEvent(event(1, '2026-10-06T07:00:00Z'));
      await service.start();
      final before = scheduler.scheduled.keys.single;
      final e = (await phone.calendars.getEvent(_uuid(1)))!;
      await phone.calendars.updateEvent(
        e.copyWith(
          startAt: DateTime.utc(2026, 10, 6, 9),
          endAt: DateTime.utc(2026, 10, 6, 10),
        ),
      );
      await _settle(
        () =>
            scheduler.scheduled.length == 1 &&
            scheduler.scheduled.keys.single != before,
      );
      expect(scheduler.scheduled.keys.single, isNot(before));
      expect(
        formatInstant(scheduler.sorted.single.fireAt),
        '2026-10-06T09:00:00Z',
      );
    },
  );

  test('удаление и выполнение снимают напоминания', () async {
    await phone.calendars.createEvent(event(1, '2026-10-06T07:00:00Z'));
    await phone.tasks.createTask(
      TaskEntity(
        id: _uuid(2),
        title: 'Сдать',
        status: TaskStatus.todo,
        due: TaskDue.date(DateTime.utc(2026, 10, 8)),
        reminders: const [0],
      ),
    );
    await service.start();
    expect(scheduler.scheduled, hasLength(2));
    await phone.tasks.setStatus(_uuid(2), TaskStatus.done);
    await _settle(() => scheduler.scheduled.length == 1);
    await phone.calendars.deleteEvent(_uuid(1));
    await _settle(() => scheduler.scheduled.isEmpty);
    await phone.calendars.restoreEvent(_uuid(1));
    await _settle(() => scheduler.scheduled.length == 1);
  });

  test(
    'после синхронизации: событие с другого устройства планируется',
    () async {
      final pc = await CalendarDevice.create(server, clock: clock);
      await pc.calendars.ensureSystemCalendars();
      await pc.calendars.createEvent(event(3, '2026-10-07T07:00:00Z'));
      await pc.device.sync();
      await service.start();
      expect(scheduler.scheduled, isEmpty);
      await phone.device.sync();
      await _settle(() => scheduler.scheduled.length == 1);
      await pc.close();
    },
  );

  test('смена часового пояса пересчитывает «весь день»', () async {
    await phone.calendars.createEvent(
      EventEntity(
        id: _uuid(4),
        calendarId: personal,
        title: 'Весь день',
        allDay: true,
        startDate: DateTime.utc(2026, 10, 8),
        endDate: DateTime.utc(2026, 10, 8),
        reminders: const [0],
      ),
    );
    await service.start();
    expect(
      formatInstant(scheduler.sorted.single.fireAt),
      '2026-10-08T06:00:00Z',
    );
    zone = requireLocation('Asia/Vladivostok');
    await service.onTimeZoneChanged();
    expect(scheduler.scheduled, hasLength(1));
    expect(
      formatInstant(scheduler.sorted.single.fireAt),
      '2026-10-07T23:00:00Z',
    );
  });

  test('настройка времени напоминаний «весь день» пересчитывает', () async {
    await phone.calendars.createEvent(
      EventEntity(
        id: _uuid(4),
        calendarId: personal,
        title: 'Весь день',
        allDay: true,
        startDate: DateTime.utc(2026, 10, 8),
        endDate: DateTime.utc(2026, 10, 8),
        reminders: const [0],
      ),
    );
    await service.start();
    await CalendarSettingsRepository(UserSettingsRepository(phone.device.store))
        .writeAllDayReminderTime('20:00');
    await _settle(
      () =>
          scheduler.scheduled.length == 1 &&
          formatInstant(scheduler.sorted.single.fireAt) ==
              '2026-10-08T17:00:00Z',
    );
    expect(
      formatInstant(scheduler.sorted.single.fireAt),
      '2026-10-08T17:00:00Z',
    );
  });

  test('перезагрузка: новый экземпляр сервиса восстанавливает всё', () async {
    await phone.calendars.createEvent(event(1, '2026-10-06T07:00:00Z'));
    await phone.calendars.createEvent(
      event(2, '2026-10-06T08:00:00Z', reminders: const [0, 30]),
    );
    await service.start();
    final planned = scheduler.sorted.map((r) => r.id).toList();
    expect(planned, hasLength(3));
    // Устройство перезагрузилось: очередь системы пуста, приложение стартует.
    await service.stop();
    scheduler.scheduled.clear();
    service = makeService();
    await service.start();
    expect(scheduler.sorted.map((r) => r.id), planned);
  });

  test('ход времени: старые не повторяются, горизонт сдвигается', () async {
    await phone.calendars.createEvent(event(1, '2026-10-06T07:00:00Z'));
    await phone.calendars.createEvent(event(2, '2026-10-25T07:00:00Z'));
    await service.start();
    expect(scheduler.scheduled, hasLength(1));
    clock.advance(const Duration(days: 12));
    await service.onResumed();
    expect(scheduler.sorted.map((r) => formatInstant(r.fireAt)), [
      '2026-10-25T07:00:00Z',
    ]);
  });

  test('периодический пересчёт по таймеру', () async {
    await service.stop();
    Duration? period;
    late void Function(Timer) tick;
    service = makeService(
      refreshEvery: const Duration(hours: 6),
      periodic: (p, callback) {
        period = p;
        tick = callback;
        return Timer(const Duration(days: 365), () {});
      },
    );
    await service.start();
    expect(period, const Duration(hours: 6));
    final first = service.replans;
    tick(Timer(Duration.zero, () {}));
    await _nextReplan(service, first);
    expect(service.replans, greaterThan(first));
  });

  test('одновременные пересчёты склеиваются без гонок', () async {
    await phone.calendars.createEvent(event(1, '2026-10-06T07:00:00Z'));
    await service.start();
    await Future.wait([service.replan(), service.replan(), service.replan()]);
    expect(scheduler.scheduled, hasLength(1));
  });

  test('разрешения: запрос через планировщик', () async {
    scheduler.state = ReminderPermission.notificationsDenied;
    expect(
      await scheduler.permission(),
      ReminderPermission.notificationsDenied,
    );
    expect(await scheduler.requestPermission(), ReminderPermission.granted);
    expect(scheduler.permissionRequests, 1);
  });

  test('фоновый хук: после синхронизации без приложения напоминания '
      'пересчитываются по свежим данным', () async {
    // Данные с другого устройства уже в локальной БД (после pull).
    await phone.calendars.createEvent(event(1, '2026-10-06T07:00:00Z'));
    final container = ProviderContainer(
      overrides: [
        syncStoreProvider.overrideWithValue(phone.device.store),
        reminderSchedulerProvider.overrideWithValue(scheduler),
        clockProvider.overrideWithValue(() => clock.now),
        deviceTimeZoneSourceProvider.overrideWithValue(
          const FixedTimeZoneSource('Europe/Moscow'),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(scheduler.scheduled, isEmpty);
    await replanRemindersAfterSync(container);
    // Напоминания «Сна» (Этап 8) идут тем же планировщиком: отдельно.
    List<String> events() => [
      for (final r in scheduler.sorted)
        if (!r.payload.startsWith('sleep:')) formatInstant(r.fireAt),
    ];
    expect(
      scheduler.sorted.where((r) => r.payload.startsWith('sleep:')),
      isNotEmpty,
    );
    expect(events(), ['2026-10-06T07:00:00Z']);
    // Прошло время (горизонт 14 дней сдвинулся): новое событие из будущего
    // попадает в окно только благодаря повторному фоновому пересчёту.
    await phone.calendars.createEvent(event(2, '2026-10-25T07:00:00Z'));
    await replanRemindersAfterSync(container);
    expect(events(), hasLength(1), reason: '25.10 вне горизонта');
    clock.advance(const Duration(days: 12));
    await replanRemindersAfterSync(container);
    expect(events(), ['2026-10-25T07:00:00Z']);
  });

  test(
    'смена разрешения «точные будильники»: всё регистрируется заново',
    () async {
      scheduler.state = ReminderPermission.exactAlarmsDenied;
      await phone.calendars.createEvent(event(1, '2026-10-06T07:00:00Z'));
      await service.start();
      final id = scheduler.scheduled.keys.single;
      scheduler.log.clear();
      // Без изменения разрешений возврат в приложение ничего не перепланирует.
      await service.onResumed();
      expect(scheduler.log, isEmpty);
      // Пользователь выдал точные будильники в системных настройках.
      scheduler.state = ReminderPermission.granted;
      await service.onResumed();
      expect(scheduler.log, ['clear', '+$id']);
      expect(scheduler.scheduled.keys.single, id);
    },
  );

  test('сбой одного дополнительного источника не обрывает пересчёт '
      'календаря и остальных источников', () async {
    await phone.calendars.createEvent(event(1, '2026-10-06T07:00:00Z'));
    final good = _FakeSource(
      () async => [
        PlannedReminder(
          id: 77,
          fireAt: DateTime.utc(2026, 10, 7, 7),
          title: 'Другой источник',
          body: '',
          payload: 'sleep:morning|2026-10-07',
        ),
      ],
    );
    final broken = _FakeSource(() async => throw StateError('сбой'));
    final withBroken = makeServiceWith([broken, good]);
    addTearDown(withBroken.stop);
    await withBroken.start();
    expect(broken.calls, 1);
    expect(good.calls, 1);
    expect(scheduler.sorted.map((r) => r.title), contains('Другой источник'));
    expect(
      scheduler.sorted.map((r) => formatInstant(r.fireAt)),
      contains('2026-10-06T07:00:00Z'),
    );
  });
}

class _FakeSource implements ExtraReminderSource {
  _FakeSource(this._plan);

  final Future<List<PlannedReminder>> Function() _plan;
  int calls = 0;

  @override
  List<String> get tables => const [];

  @override
  Future<List<PlannedReminder>> plan(DateTime now, tz.Location zone) {
    calls++;
    return _plan();
  }
}
