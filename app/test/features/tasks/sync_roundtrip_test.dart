import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Таблицы календаря и задач через общий клиентский стек синхронизации и
/// фейковый сервер: «сделал офлайн — появилась сеть — данные на втором
/// устройстве».
void main() {
  ensureTimeZones();
  late ManualClock clock;
  late FakeSyncServer server;
  late CalendarDevice phone;
  late CalendarDevice pc;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    String next() => _uuid(1000 + ++counter);
    phone = await CalendarDevice.create(server, clock: clock, newId: next);
    pc = await CalendarDevice.create(server, clock: clock, newId: next);
  });
  tearDown(() async {
    await phone.close();
    await pc.close();
    await server.dispose();
  });

  final personal = systemCalendarId('personal');

  test('системные календари и теги с двух устройств не дублируются', () async {
    await phone.calendars.ensureSystemCalendars();
    await pc.calendars.ensureSystemCalendars();
    await phone.tasks.createTask(
      TaskEntity(id: _uuid(1), title: 'A', status: TaskStatus.todo),
    );
    await pc.tasks.createTask(
      TaskEntity(id: _uuid(2), title: 'B', status: TaskStatus.todo),
    );
    await phone.tasks.setTaskTags(_uuid(1), ['Работа']);
    await pc.tasks.setTaskTags(_uuid(2), ['работа']);
    for (var i = 0; i < 3; i++) {
      expect(await phone.device.sync(), SyncOutcome.success);
      expect(await pc.device.sync(), SyncOutcome.success);
    }
    expect(server.snapshot('calendars').keys, hasLength(5));
    expect(server.snapshot('tags').keys, {tagId('работа')});
    expect(await phone.calendars.layers(), hasLength(5));
    expect(await pc.tasks.tags(), hasLength(1));
    expect(server.snapshot('task_tags'), hasLength(2));
  });

  test('офлайн: событие, серия с исключением и задача доезжают', () async {
    phone.device.remote.faults.offline = true;
    await phone.calendars.ensureSystemCalendars();
    final eventId = _uuid(10);
    final event = EventEntity(
      id: eventId,
      calendarId: personal,
      title: 'Пара',
      allDay: false,
      startAt: DateTime.utc(2026, 10, 6, 7),
      endAt: DateTime.utc(2026, 10, 6, 8),
      tz: 'Europe/Moscow',
      rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU',
      reminders: const [10],
    );
    await phone.calendars.createEvent(event);
    await phone.calendars.cancelInstance(event, '2026-10-20T07:00:00Z');
    await phone.tasks.createTask(
      TaskEntity(
        id: _uuid(11),
        title: 'Сдать',
        status: TaskStatus.todo,
        due: TaskDue.date(DateTime.utc(2026, 10, 9)),
        priority: 1,
      ),
    );
    await phone.tasks.addSubtask(_uuid(11), 'Пункт');
    expect(await phone.device.sync(), SyncOutcome.offline);
    phone.device.remote.faults.offline = false;
    expect(await phone.device.sync(), SyncOutcome.success);
    expect(await pc.device.sync(), SyncOutcome.success);

    final got = (await pc.calendars.getEvent(eventId))!;
    expect(got.rrule, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU');
    expect(got.reminders, [10]);
    expect(got.startAt, DateTime.utc(2026, 10, 6, 7));
    final overrides = await pc.calendars.overridesOf(eventId);
    expect(overrides.single.cancelled, isTrue);
    expect(
      overrides.single.id,
      eventOverrideId(eventId, '2026-10-20T07:00:00Z'),
    );
    expect((await pc.tasks.getTask(_uuid(11)))!.priority, 1);
    expect(await pc.tasks.subtasksOf(_uuid(11)), hasLength(1));
  });

  test('правки разных полей одной задачи с двух устройств сливаются', () async {
    await phone.calendars.ensureSystemCalendars();
    await phone.tasks.createTask(
      TaskEntity(id: _uuid(1), title: 'Задача', status: TaskStatus.todo),
    );
    await phone.device.sync();
    await pc.device.sync();
    clock.advance(const Duration(minutes: 5));
    await phone.tasks.updateTask(
      (await phone.tasks.getTask(_uuid(1)))!.copyWith(priority: 2),
    );
    await pc.tasks.setStatus(_uuid(1), TaskStatus.done);
    for (var i = 0; i < 2; i++) {
      await phone.device.sync();
      await pc.device.sync();
    }
    final t = (await phone.tasks.getTask(_uuid(1)))!;
    expect(t.priority, 2);
    expect(t.status, TaskStatus.done);
    expect(t.completedAt, isNotNull);
  });

  test('удаление календаря каскадом скрывает события на втором', () async {
    await phone.calendars.ensureSystemCalendars();
    final layer = await phone.calendars.createLayer(name: 'Спорт');
    await phone.calendars.createEvent(
      EventEntity(
        id: _uuid(20),
        calendarId: layer,
        title: 'Бег',
        allDay: true,
        startDate: DateTime.utc(2026, 10, 7),
        endDate: DateTime.utc(2026, 10, 7),
      ),
    );
    await phone.device.sync();
    await pc.device.sync();
    expect(await pc.calendars.eventCount(layer), 1);
    await phone.calendars.deleteLayer(layer);
    await phone.device.sync();
    await pc.device.sync();
    expect(await pc.calendars.eventCount(layer), 0);
    expect(formatDate(DateTime.utc(2026, 10, 7)), '2026-10-07');
  });
}
