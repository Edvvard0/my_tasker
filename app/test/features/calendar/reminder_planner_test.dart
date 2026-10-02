import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_planner.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_scheduler.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/fake_reminder_scheduler.dart';

final _now = DateTime.utc(2026, 10, 5, 6); // 09:00 по Москве

EventEntity _timed(
  String id,
  String start, {
  String end = '',
  String tz = 'Europe/Moscow',
  String? rrule,
  List<int>? reminders,
  String title = 'Событие',
}) => EventEntity(
  id: id,
  calendarId: 'c',
  title: title,
  allDay: false,
  startAt: parseInstant(start),
  endAt: parseInstant(end.isEmpty ? start : end),
  tz: tz,
  rrule: rrule,
  reminders: reminders,
);

EventEntity _allDay(
  String id,
  String date, {
  List<int>? reminders,
  String? rrule,
}) => EventEntity(
  id: id,
  calendarId: 'c',
  title: 'Весь день',
  allDay: true,
  startDate: parseDate(date),
  endDate: parseDate(date),
  reminders: reminders,
  rrule: rrule,
);

ReminderInput _input({
  List<EventEntity> events = const [],
  List<EventOverride> overrides = const [],
  List<TaskEntity> tasks = const [],
  List<TaskCompletion> completions = const [],
  String tz = 'Europe/Moscow',
  int allDay = 540,
  DateTime? now,
}) => ReminderInput(
  now: now ?? _now,
  zone: requireLocation(tz),
  allDayMinutes: allDay,
  events: events,
  overrides: overrides,
  tasks: tasks,
  completions: completions,
);

List<String> _times(List<PlannedReminder> r) => [
  for (final x in r) formatInstant(x.fireAt),
];

void main() {
  ensureTimeZones();

  group('события с временем', () {
    test('минуты «до начала»: в момент, за 10 минут, за сутки', () {
      final plan = planReminders(
        _input(
          events: [
            _timed(
              'e',
              '2026-10-06T12:00:00Z',
              reminders: [0, 10, 1440],
              title: 'Созвон',
            ),
          ],
        ),
      );
      expect(_times(plan), [
        '2026-10-05T12:00:00Z',
        '2026-10-06T11:50:00Z',
        '2026-10-06T12:00:00Z',
      ]);
      expect(plan.first.title, 'Созвон');
      expect(plan.first.body, 'Через 1 день · 15:00');
      expect(plan[1].body, 'Через 10 мин · 15:00');
      expect(plan.last.body, 'Сейчас · 15:00');
      expect(plan.last.payload, 'event:e|2026-10-06T12:00:00Z');
    });

    test('прошедшие и дальше горизонта не планируются', () {
      final plan = planReminders(
        _input(
          events: [
            _timed('a', '2026-10-05T05:00:00Z', reminders: [0]),
            _timed('b', '2026-10-05T06:00:00Z', reminders: [0]),
            _timed('c', '2026-10-19T06:00:00Z', reminders: [0]),
            _timed('d', '2026-10-19T06:00:01Z', reminders: [0]),
            _timed('n', '2026-10-06T06:00:00Z'),
            _timed('z', '2026-10-06T06:00:00Z', reminders: []),
          ],
        ),
      );
      expect(_times(plan), ['2026-10-05T06:00:00Z', '2026-10-19T06:00:00Z']);
    });

    test('переход через полночь: напоминание за 10 минут до 00:05', () {
      // 00:05 по Москве 6 октября = 21:05 UTC 5 октября.
      final plan = planReminders(
        _input(
          now: DateTime.utc(2026, 10, 5, 20),
          events: [
            _timed('e', '2026-10-05T21:05:00Z', reminders: [10]),
          ],
        ),
      );
      expect(_times(plan), ['2026-10-05T20:55:00Z']);
    });

    test('повторяющаяся серия: по одному на экземпляр', () {
      final plan = planReminders(
        _input(
          events: [
            _timed(
              'e',
              '2026-10-05T07:00:00Z',
              rrule: 'FREQ=DAILY',
              reminders: [30],
            ),
          ],
        ),
      );
      expect(plan, hasLength(14));
      expect(_times(plan).first, '2026-10-05T06:30:00Z');
      expect(_times(plan).last, '2026-10-18T06:30:00Z');
    });

    test('переход на летнее время: 09:30 по Берлину остаётся 09:30', () {
      final plan = planReminders(
        _input(
          now: DateTime.utc(2026, 3, 27),
          tz: 'Europe/Berlin',
          events: [
            _timed(
              'e',
              '2026-03-20T08:30:00Z',
              tz: 'Europe/Berlin',
              rrule: 'FREQ=WEEKLY',
              reminders: [0],
            ),
          ],
        ),
      );
      expect(_times(plan), ['2026-03-27T08:30:00Z', '2026-04-03T07:30:00Z']);
    });

    test('переопределения: свои напоминания, [] отключает, отмена', () {
      const key1 = '2026-10-06T07:00:00Z';
      const key2 = '2026-10-07T07:00:00Z';
      const key3 = '2026-10-08T07:00:00Z';
      final event = _timed(
        'e',
        '2026-10-05T07:00:00Z',
        rrule: 'FREQ=DAILY;COUNT=5',
        reminders: [0],
      );
      final plan = planReminders(
        _input(
          events: [event],
          overrides: const [
            EventOverride(
              id: '1',
              eventId: 'e',
              originalStart: key1,
              cancelled: false,
              reminders: [60],
            ),
            EventOverride(
              id: '2',
              eventId: 'e',
              originalStart: key2,
              cancelled: false,
              reminders: [],
            ),
            EventOverride(
              id: '3',
              eventId: 'e',
              originalStart: key3,
              cancelled: true,
            ),
          ],
        ),
      );
      expect(_times(plan), [
        '2026-10-05T07:00:00Z',
        '2026-10-06T06:00:00Z',
        '2026-10-09T07:00:00Z',
      ]);
    });

    test('перенесённый экземпляр напоминает о новом времени', () {
      final plan = planReminders(
        _input(
          events: [
            _timed(
              'e',
              '2026-10-05T07:00:00Z',
              rrule: 'FREQ=DAILY;COUNT=2',
              reminders: [0],
            ),
          ],
          overrides: [
            EventOverride(
              id: '1',
              eventId: 'e',
              originalStart: '2026-10-06T07:00:00Z',
              cancelled: false,
              startAt: DateTime.utc(2026, 10, 6, 15),
              endAt: DateTime.utc(2026, 10, 6, 16),
            ),
          ],
        ),
      );
      expect(_times(plan), ['2026-10-05T07:00:00Z', '2026-10-06T15:00:00Z']);
    });
  });

  group('события на весь день', () {
    test('[0] — в 9:00 в этот день, [900] — в 18:00 накануне', () {
      final plan = planReminders(
        _input(
          events: [
            _allDay('e', '2026-10-08', reminders: [0, 900]),
          ],
        ),
      );
      expect(_times(plan), ['2026-10-07T15:00:00Z', '2026-10-08T06:00:00Z']);
      expect(plan.last.body, 'Сегодня, весь день');
      expect(plan.first.body, 'Через 15 ч · весь день');
    });

    test('смена часового пояса сдвигает напоминание', () {
      final events = [
        _allDay('e', '2026-10-08', reminders: [0]),
      ];
      final moscow = planReminders(_input(events: events));
      final vladivostok = planReminders(
        _input(events: events, tz: 'Asia/Vladivostok'),
      );
      expect(_times(moscow), ['2026-10-08T06:00:00Z']);
      expect(_times(vladivostok), ['2026-10-07T23:00:00Z']);
      final tokyo = planReminders(_input(events: events, tz: 'Asia/Tokyo'));
      expect(_times(tokyo), ['2026-10-08T00:00:00Z']);
    });

    test('время напоминаний настраивается', () {
      final plan = planReminders(
        _input(
          allDay: 8 * 60 + 30,
          events: [
            _allDay('e', '2026-10-08', reminders: [0]),
          ],
        ),
      );
      expect(_times(plan), ['2026-10-08T05:30:00Z']);
    });

    test('ежегодное событие «весь день»', () {
      final plan = planReminders(
        _input(
          now: DateTime.utc(2026, 12),
          events: [
            _allDay('e', '2020-12-05', reminders: [0], rrule: 'FREQ=YEARLY'),
          ],
        ),
      );
      expect(_times(plan), ['2026-12-05T06:00:00Z']);
    });
  });

  group('задачи', () {
    TaskEntity task(
      String id, {
      TaskDue due = const TaskDue.none(),
      TaskStatus status = TaskStatus.todo,
      List<int>? reminders = const [0],
      String? rrule,
      RecurrenceMode? mode,
      DateTime? archivedAt,
    }) => TaskEntity(
      id: id,
      title: 'Задача',
      status: status,
      due: due,
      reminders: reminders,
      rrule: rrule,
      recurrenceMode: mode,
      archivedAt: archivedAt,
    );

    test('со временем и с датой', () {
      final plan = planReminders(
        _input(
          tasks: [
            task(
              'a',
              due: TaskDue.at(DateTime.utc(2026, 10, 6, 9), 'Europe/Moscow'),
            ),
            task('b', due: TaskDue.date(DateTime.utc(2026, 10, 7))),
          ],
        ),
      );
      expect(_times(plan), ['2026-10-06T09:00:00Z', '2026-10-07T06:00:00Z']);
      expect(plan.first.payload, 'task:a');
      expect(plan.first.body, 'Сейчас · 12:00');
    });

    test('выполненные, отменённые, архивные и без срока молчат', () {
      final due = TaskDue.date(DateTime.utc(2026, 10, 7));
      final plan = planReminders(
        _input(
          tasks: [
            task('a', due: due, status: TaskStatus.done),
            task('b', due: due, status: TaskStatus.cancelled),
            task('c', due: due, archivedAt: _now),
            task('d'),
            task('e', due: due, reminders: null),
            task('f', due: due, reminders: const []),
          ],
        ),
      );
      expect(plan, isEmpty);
    });

    test('schedule: отмеченный экземпляр молчит, остальные напоминают', () {
      final plan = planReminders(
        _input(
          tasks: [
            task(
              't',
              due: TaskDue.date(DateTime.utc(2026, 10, 5)),
              rrule: 'FREQ=DAILY;COUNT=3',
              mode: RecurrenceMode.schedule,
            ),
          ],
          completions: [
            TaskCompletion(
              id: 'x',
              taskId: 't',
              instanceDate: '2026-10-06',
              skipped: false,
              completedAt: _now,
            ),
          ],
        ),
      );
      expect(_times(plan), ['2026-10-05T06:00:00Z', '2026-10-07T06:00:00Z']);
    });

    test('after_completion: одно напоминание на текущий срок', () {
      final plan = planReminders(
        _input(
          tasks: [
            task(
              't',
              due: TaskDue.date(DateTime.utc(2026, 10, 9)),
              rrule: 'FREQ=DAILY;INTERVAL=3',
              mode: RecurrenceMode.afterCompletion,
            ),
          ],
        ),
      );
      expect(_times(plan), ['2026-10-09T06:00:00Z']);
    });
  });

  group('общие правила', () {
    test('порядок по времени, предел числа, стабильные уникальные id', () {
      final events = [
        for (var i = 0; i < 100; i++)
          _timed(
            'e$i',
            '2026-10-${(6 + i % 5).toString().padLeft(2, '0')}'
                'T${(10 + i % 8).toString().padLeft(2, '0')}:00:00Z',
            reminders: [0],
          ),
      ];
      final plan = planReminders(_input(events: events));
      expect(plan, hasLength(reminderLimit));
      final sorted = [...plan]
        ..sort((a, b) {
          final c = a.fireAt.compareTo(b.fireAt);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
      expect(plan, sorted);
      expect({for (final r in plan) r.id}, hasLength(reminderLimit));
      expect(planReminders(_input(events: events)), plan);
      expect(planReminders(_input(events: events), limit: 5), hasLength(5));
    });

    test('любая правка меняет id (старое отменяется, новое планируется)', () {
      PlannedReminder one(String title, String start) => planReminders(
        _input(
          events: [
            _timed('e', start, reminders: [0], title: title),
          ],
        ),
      ).single;
      final base = one('A', '2026-10-06T07:00:00Z');
      expect(one('B', '2026-10-06T07:00:00Z').id, isNot(base.id));
      expect(one('A', '2026-10-06T08:00:00Z').id, isNot(base.id));
      expect(one('A', '2026-10-06T07:00:00Z').id, base.id);
      expect(base.id, isNonNegative);
      expect(base.id, lessThan(1 << 31));
    });

    test('события с неполными данными пропускаются', () {
      const bad = EventEntity(
        id: 'x',
        calendarId: 'c',
        title: 'X',
        allDay: false,
        reminders: [0],
      );
      expect(planReminders(_input(events: [bad])), isEmpty);
    });
  });

  group('reconcileReminders', () {
    PlannedReminder r(int id) => PlannedReminder(
      id: id,
      fireAt: _now,
      title: 't',
      body: 'b',
      payload: 'p',
    );

    test('отменяет лишнее и планирует недостающее', () async {
      final scheduler = FakeReminderScheduler();
      await scheduler.schedule(r(1));
      await scheduler.schedule(r(2));
      scheduler.log.clear();
      final result = await reconcileReminders(scheduler, [r(2), r(3)]);
      expect((result.cancelled, result.scheduled), (1, 1));
      expect(scheduler.scheduled.keys, {2, 3});
      expect(scheduler.log, ['-1', '+3']);
      final again = await reconcileReminders(scheduler, [r(2), r(3)]);
      expect((again.cancelled, again.scheduled), (0, 0));
    });
  });

  group('TimerReminderScheduler', () {
    test('показывает в срок, отмена и cancelAll', () {
      fakeAsync((async) {
        final shower = FakeShower();
        var now = DateTime.utc(2026, 10, 5, 6);
        final scheduler = TimerReminderScheduler(
          shower: shower,
          now: () => now.add(async.elapsed),
        );
        PlannedReminder at(int id, Duration after) => PlannedReminder(
          id: id,
          fireAt: now.add(after),
          title: 'T$id',
          body: 'b',
          payload: 'p',
        );
        unawaited(scheduler.schedule(at(1, const Duration(minutes: 10))));
        unawaited(scheduler.schedule(at(2, const Duration(minutes: 20))));
        unawaited(scheduler.schedule(at(3, const Duration(minutes: 30))));
        unawaited(scheduler.schedule(at(4, const Duration(days: 40))));
        async.flushMicrotasks();
        Set<int>? pending;
        unawaited(scheduler.pendingIds().then((v) => pending = v));
        async.flushMicrotasks();
        expect(pending, {1, 2, 3});
        unawaited(scheduler.cancel(2));
        async.elapse(const Duration(minutes: 15));
        expect(shower.shown.map((s) => s.id), [1]);
        unawaited(scheduler.cancelAll());
        async.elapse(const Duration(hours: 2));
        expect(shower.shown, hasLength(1));
        // Просроченное срабатывает сразу.
        unawaited(scheduler.schedule(at(5, const Duration(minutes: -1))));
        async.elapse(Duration.zero);
        expect(shower.shown.map((s) => s.id), [1, 5]);
        ReminderPermission? permission;
        unawaited(scheduler.permission().then((v) => permission = v));
        unawaited(scheduler.requestPermission());
        async.flushMicrotasks();
        expect(permission, ReminderPermission.notRequired);
        now = now.add(const Duration(hours: 3));
      });
    });
  });

  test('NoReminderScheduler ничего не делает', () async {
    final s = NoReminderScheduler();
    await s.schedule(
      PlannedReminder(id: 1, fireAt: _now, title: '', body: '', payload: ''),
    );
    await s.cancel(1);
    await s.cancelAll();
    expect(await s.pendingIds(), isEmpty);
    expect(await s.permission(), ReminderPermission.notRequired);
    expect(await s.requestPermission(), ReminderPermission.notRequired);
  });
}
