import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart';
import 'package:my_tasker/features/calendar/data/event_moves.dart';
import 'package:my_tasker/features/calendar/data/week_cycle_actions.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/domain/recurrence_scope.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';

import '../../support/calendar_env.dart';
import '../../support/manual_clock.dart';

final String _personal = systemCalendarId('personal');

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

EventEntity _timed(
  String id, {
  String? rrule,
  String start = '2026-10-05T07:00:00Z', // пн 10:00 МСК
  String end = '2026-10-05T08:00:00Z',
}) => EventEntity(
  id: id,
  calendarId: _personal,
  title: 'Пара',
  allDay: false,
  startAt: parseInstant(start),
  endAt: parseInstant(end),
  tz: 'Europe/Moscow',
  rrule: rrule,
);

void main() {
  ensureTimeZones();
  final zone = requireLocation('Europe/Moscow');
  late CalendarDevice d;
  late CalendarRepository repo;
  late CalendarSettingsRepository settings;
  late WeekCycleActions actions;
  late EventMoves moves;
  var counter = 0;

  setUp(() async {
    final clock = ManualClock();
    counter = 0;
    d = await CalendarDevice.create(
      appServer(clock),
      clock: clock,
      newId: () => _uuid(100 + ++counter),
    );
    repo = d.calendars;
    await repo.ensureSystemCalendars();
    settings = CalendarSettingsRepository(
      UserSettingsRepository(d.device.store),
    );
    actions = WeekCycleActions(
      store: d.device.store,
      calendars: repo,
      settings: settings,
    );
    moves = EventMoves(repo);
  });
  tearDown(() => d.close());

  group('пропуск недели', () {
    test('отменяет экземпляры серий недели; «Отменить» возвращает', () async {
      await repo.createEvent(
        _timed(_uuid(1), rrule: 'FREQ=WEEKLY;BYDAY=MO,WE'),
      );
      await repo.createEvent(
        EventEntity(
          id: _uuid(2),
          calendarId: _personal,
          title: 'Каникулы',
          allDay: true,
          startDate: DateTime.utc(2026, 10, 5),
          endDate: DateTime.utc(2026, 10, 5),
          rrule: 'FREQ=WEEKLY',
        ),
      );
      await repo.createEvent(_timed(_uuid(3))); // одиночное — не трогаем
      final skipped = await actions.skipWeek(DateTime.utc(2026, 10, 12), zone);
      expect(skipped, hasLength(3));
      expect((await repo.overridesOf(_uuid(1))).where((o) => o.cancelled), [
        isA<EventOverride>(),
        isA<EventOverride>(),
      ]);
      // повтор не создаёт дублей
      expect(await actions.skipWeek(DateTime.utc(2026, 10, 12), zone), isEmpty);
      await actions.undoSkipWeek(skipped);
      expect(
        (await repo.overridesOf(_uuid(1))).where((o) => o.cancelled),
        <EventOverride>[],
      );
      // событие уже удалено — undo его пропускает
      await actions.undoSkipWeek([(eventId: _uuid(99), key: 'x')]);
    });
  });

  group('сдвиг чётности', () {
    test('без цикла — ошибка', () async {
      await expectLater(
        actions.shiftParity(DateTime.utc(2026, 10, 12)),
        throwsA(isA<ValidationError>()),
      );
    });

    test('разрезает серии цикла и пишет сдвиг', () async {
      await settings.writeWeekCycle(
        WeekCycle(length: 2, week1Start: DateTime.utc(2026, 9, 28)),
      );
      await repo.createEvent(
        _timed(_uuid(1), rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO'),
      );
      await repo.createEvent(
        EventEntity(
          id: _uuid(2),
          calendarId: _personal,
          title: 'День',
          allDay: true,
          startDate: DateTime.utc(2026, 10, 5),
          endDate: DateTime.utc(2026, 10, 5),
          rrule: 'FREQ=WEEKLY;INTERVAL=2',
        ),
      );
      await repo.createEvent(
        _timed(_uuid(3), rrule: 'FREQ=WEEKLY;BYDAY=MO'), // без чередования
      );
      final shifted = await actions.shiftParity(DateTime.utc(2026, 10, 12));
      expect(shifted, 2);
      final cycle = (await settings.readWeekCycle())!;
      expect(cycle.shifts, hasLength(1));
      final all = await d.device.store.visibleRows('events');
      expect(all.length, 5); // 3 исходных + 2 новых хвоста
    });

    test('серия, кончающаяся до сдвига, не затрагивается', () async {
      await settings.writeWeekCycle(
        WeekCycle(length: 2, week1Start: DateTime.utc(2026, 9, 28)),
      );
      await repo.createEvent(
        _timed(_uuid(1), rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;COUNT=1'),
      );
      expect(await actions.shiftParity(DateTime.utc(2026, 10, 19)), 0);
    });

    test('серия с UNTIL: хвост, не помещающийся, просто удаляется', () async {
      await settings.writeWeekCycle(
        WeekCycle(length: 2, week1Start: DateTime.utc(2026, 9, 28)),
      );
      await repo.createEvent(
        _timed(
          _uuid(1),
          rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;UNTIL=20261019T235959Z',
        ),
      );
      expect(await actions.shiftParity(DateTime.utc(2026, 10, 12)), 1);
    });
  });

  group('перенос перетаскиванием', () {
    // Новое событие (хвост разреза): строка, которой нет среди [known].
    Future<EventEntity> tailOf(Set<String> known) async {
      final rows = await d.device.store.visibleRows('events');
      final id = rows
          .map((r) => r['id']! as String)
          .firstWhere((x) => !known.contains(x));
      return (await repo.getEvent(id))!;
    }

    final newStart = DateTime.utc(2026, 10, 6, 9); // вт 12:00 МСК
    final newEnd = DateTime.utc(2026, 10, 6, 10);
    const key = '2026-10-12T07:00:00Z';

    test('весь день — ошибка', () async {
      final e = EventEntity(
        id: _uuid(1),
        calendarId: _personal,
        title: 'x',
        allDay: true,
        startDate: DateTime.utc(2026, 10, 5),
        endDate: DateTime.utc(2026, 10, 5),
      );
      await expectLater(
        moves.move(e, key: 'k', newStart: newStart, newEnd: newEnd),
        throwsA(isA<ValidationError>()),
      );
    });

    test('одиночное событие сдвигается', () async {
      final e = _timed(_uuid(1));
      await repo.createEvent(e);
      await moves.move(e, key: 'k', newStart: newStart, newEnd: newEnd);
      final got = (await repo.getEvent(e.id))!;
      expect(got.startAt, newStart);
      expect(got.endAt, newEnd);
    });

    test('неизвестный экземпляр серии — ошибка', () async {
      final e = _timed(_uuid(1), rrule: 'FREQ=WEEKLY');
      await repo.createEvent(e);
      await expectLater(
        moves.move(e, key: 'bogus', newStart: newStart, newEnd: newEnd),
        throwsA(isA<ValidationError>()),
      );
    });

    test('только это: переопределение с сохранением полей', () async {
      final e = _timed(_uuid(1), rrule: 'FREQ=WEEKLY');
      await repo.createEvent(e);
      await repo.overrideInstance(
        e,
        key,
        const InstanceChange(title: 'Особая'),
      );
      await moves.move(
        e,
        key: key,
        newStart: newStart,
        newEnd: newEnd,
        scope: RecurrenceScope.only,
      );
      final o = (await repo.overridesOf(e.id)).single;
      expect(o.title, 'Особая');
      expect(o.startAt, newStart);
    });

    test('это и следующие: серия разрезается', () async {
      final e = _timed(_uuid(1), rrule: 'FREQ=WEEKLY');
      await repo.createEvent(e);
      await moves.move(
        e,
        key: key,
        newStart: newStart,
        newEnd: newEnd,
        scope: RecurrenceScope.following,
      );
      expect((await d.device.store.visibleRows('events')).length, 2);
    });

    test('все: сдвиг мастера и BYDAY на разницу дней', () async {
      final e = _timed(_uuid(1), rrule: 'FREQ=WEEKLY;BYDAY=MO,WE');
      await repo.createEvent(e);
      // экземпляр понедельника 12.10 переносим на вторник 13.10 12:00
      await moves.move(
        e,
        key: key,
        newStart: DateTime.utc(2026, 10, 13, 9),
        newEnd: DateTime.utc(2026, 10, 13, 10),
      );
      final got = (await repo.getEvent(e.id))!;
      expect(got.rrule, contains('BYDAY=TU,TH'));
      expect(utcToWall(zone, got.startAt!).hour, 12);
      expect(utcToWall(zone, got.startAt!).day, 6);
      expect(got.endAt!.difference(got.startAt!), const Duration(hours: 1));
    });

    test(
      'это и следующие: BYDAY=TU,TH, четверг -> пятница даёт TU,FR',
      () async {
        // пн 05.10 10:00 МСК старт; серия вт/чт, начало серии — вт 06.10
        final e = _timed(
          _uuid(1),
          rrule: 'FREQ=WEEKLY;BYDAY=TU,TH',
          start: '2026-10-06T07:00:00Z',
          end: '2026-10-06T08:00:00Z',
        );
        await repo.createEvent(e);
        // экземпляр четверга 15.10 -> пятница 16.10 в 10:00
        await moves.move(
          e,
          key: '2026-10-15T07:00:00Z',
          newStart: DateTime.utc(2026, 10, 16, 7),
          newEnd: DateTime.utc(2026, 10, 16, 8),
          scope: RecurrenceScope.following,
        );
        final rows = await d.device.store.visibleRows('events');
        expect(rows, hasLength(2));
        final tail = await tailOf({e.id});
        expect(tail.rrule, 'FREQ=WEEKLY;BYDAY=TU,FR');
        expect(tail.startAt, DateTime.utc(2026, 10, 16, 7));
        expect((await repo.getEvent(e.id))!.rrule, contains('UNTIL='));
      },
    );

    test('это и следующие: BYMONTHDAY переезжает на новое число', () async {
      final e = _timed(
        _uuid(1),
        rrule: 'FREQ=MONTHLY;BYMONTHDAY=15',
        start: '2026-09-15T07:00:00Z',
        end: '2026-09-15T08:00:00Z',
      );
      await repo.createEvent(e);
      await moves.move(
        e,
        key: '2026-10-15T07:00:00Z',
        newStart: DateTime.utc(2026, 10, 17, 7),
        newEnd: DateTime.utc(2026, 10, 17, 8),
        scope: RecurrenceScope.following,
      );
      final tail = await tailOf({e.id});
      expect(tail.rrule, 'FREQ=MONTHLY;BYMONTHDAY=17');
    });

    test('это и следующие: -1FR и порядковый номер', () async {
      final last = _timed(
        _uuid(1),
        rrule: 'FREQ=MONTHLY;BYDAY=-1FR',
        start: '2026-09-25T07:00:00Z',
        end: '2026-09-25T08:00:00Z',
      );
      await repo.createEvent(last);
      // последняя пятница октября 30.10 -> последний четверг 29.10
      await moves.move(
        last,
        key: '2026-10-30T07:00:00Z',
        newStart: DateTime.utc(2026, 10, 29, 7),
        newEnd: DateTime.utc(2026, 10, 29, 8),
        scope: RecurrenceScope.following,
      );
      final tail = await tailOf({last.id});
      expect(tail.rrule, 'FREQ=MONTHLY;BYDAY=-1TH');

      final second = _timed(
        _uuid(2),
        rrule: 'FREQ=MONTHLY;BYDAY=2TU',
        start: '2026-09-08T07:00:00Z',
        end: '2026-09-08T08:00:00Z',
      );
      await repo.createEvent(second);
      // 2-й вторник октября 13.10 -> 3-я среда 21.10 (3WE)
      await moves.move(
        second,
        key: '2026-10-13T07:00:00Z',
        newStart: DateTime.utc(2026, 10, 21, 7),
        newEnd: DateTime.utc(2026, 10, 21, 8),
        scope: RecurrenceScope.following,
      );
      final tail2 = await tailOf({second.id, last.id, tail.id});
      expect(tail2.rrule, 'FREQ=MONTHLY;BYDAY=3WE');
    });

    test('все: BYMONTHDAY сдвигается вместе с началом серии', () async {
      final e = _timed(
        _uuid(1),
        rrule: 'FREQ=MONTHLY;BYMONTHDAY=15',
        start: '2026-09-15T07:00:00Z',
        end: '2026-09-15T08:00:00Z',
      );
      await repo.createEvent(e);
      await moves.move(
        e,
        key: '2026-10-15T07:00:00Z',
        newStart: DateTime.utc(2026, 10, 16, 7),
        newEnd: DateTime.utc(2026, 10, 16, 8),
      );
      final got = (await repo.getEvent(e.id))!;
      expect(got.rrule, 'FREQ=MONTHLY;BYMONTHDAY=16');
      expect(got.startAt, DateTime.utc(2026, 9, 16, 7));
    });

    test('разрез: начало хвоста не подходит под правило — ошибка', () async {
      final e = _timed(
        _uuid(1),
        rrule: 'FREQ=WEEKLY;BYDAY=TU',
        start: '2026-10-06T07:00:00Z',
        end: '2026-10-06T08:00:00Z',
      );
      await repo.createEvent(e);
      await expectLater(
        repo.splitFollowing(
          e,
          '2026-10-13T07:00:00Z',
          e.copyWith(
            startAt: DateTime.utc(
              2026,
              10,
              16,
              7,
            ), // пятница, правило — вторник
            endAt: DateTime.utc(2026, 10, 16, 8),
          ),
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(await d.device.store.visibleRows('events'), hasLength(1));
    });

    test('все: тот же день — правило не меняется', () async {
      final e = _timed(_uuid(1), rrule: 'FREQ=DAILY');
      await repo.createEvent(e);
      await moves.move(
        e,
        key: '2026-10-07T07:00:00Z',
        newStart: DateTime.utc(2026, 10, 7, 8),
        newEnd: DateTime.utc(2026, 10, 7, 9),
      );
      final got = (await repo.getEvent(e.id))!;
      expect(got.rrule, 'FREQ=DAILY');
      expect(got.startAt, DateTime.utc(2026, 10, 5, 8));
    });
  });
}
