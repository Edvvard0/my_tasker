import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';
import 'package:my_tasker/features/study/data/study_reminders.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../support/calendar_env.dart';
import '../../support/fake_reminder_scheduler.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';
import '../../support/study_env.dart';

const _sem = 'sem';

ScheduleInput _input({
  List<ClassSlot>? slots,
  List<DayRule> rules = const [],
  List<ClassOverride> overrides = const [],
  Map<String, String> holidays = const {},
  bool archived = false,
}) => ScheduleInput(
  semesters: [
    Semester(
      id: _sem,
      name: 'Осень',
      startDate: '2026-09-01',
      endDate: '2026-12-31',
      week1Start: '2026-08-31',
      archived: archived,
    ),
  ],
  subjects: const [
    Subject(
      id: 'math',
      semesterId: _sem,
      name: 'Матан',
      building: '1',
      room: '28',
    ),
  ],
  bells: const [
    Bell(semesterId: _sem, number: 1, startTime: '08:30', endTime: '10:00'),
    Bell(semesterId: _sem, number: 2, startTime: '10:10', endTime: '11:40'),
  ],
  slots:
      slots ??
      const [
        ClassSlot(
          id: 'mon',
          semesterId: _sem,
          subjectId: 'math',
          weekday: 1,
          number: 1,
          kind: LessonKind.lecture,
        ),
      ],
  dayRules: rules,
  overrides: overrides,
  holidays: holidays,
);

void main() {
  ensureTimeZones();
  final moscow = requireLocation('Europe/Moscow');
  // Понедельник 5 октября 2026, 09:00 по Москве (занятие 08:30–10:00 идёт).
  final now = DateTime.utc(2026, 10, 5, 6);

  List<String> plan(
    ScheduleInput input, {
    List<AttendanceMark> marks = const [],
    DateTime? at,
    int days = 14,
  }) => [
    for (final r in planStudyReminders(
      input: input,
      marks: marks,
      now: at ?? now,
      zone: moscow,
      horizonDays: days,
    ))
      '${formatInstant(r.fireAt)} ${r.body}',
  ];

  group('планировщик «Был на паре?»', () {
    test('после конца каждого занятия; текст и нажатие', () {
      final reminders = planStudyReminders(
        input: _input(),
        marks: const [],
        now: now,
        zone: moscow,
        horizonDays: 8,
      );
      expect(reminders.map((r) => formatInstant(r.fireAt)), [
        '2026-10-05T07:00:00Z',
        '2026-10-12T07:00:00Z',
      ]);
      final first = reminders.first;
      expect(first.title, 'Был на паре?');
      expect(first.body, '«Матан» · 08:30–10:00 · к1 28');
      expect(first.payload, 'study:mon|2026-10-05');
      expect(first.payload, studyReminderPayload('mon', '2026-10-05'));
    });

    test('горизонт 14 дней и предел числа', () {
      // 14 суток от «сейчас»: 19 октября 10:00 по Москве уже за горизонтом.
      expect(plan(_input()), [
        '2026-10-05T07:00:00Z «Матан» · 08:30–10:00 · к1 28',
        '2026-10-12T07:00:00Z «Матан» · 08:30–10:00 · к1 28',
      ]);
      expect(plan(_input(), days: 15), hasLength(3));
      final many = planStudyReminders(
        input: _input(
          slots: [
            for (var d = 1; d <= 7; d++)
              ClassSlot(
                id: 's$d',
                semesterId: _sem,
                subjectId: 'math',
                weekday: d,
                number: 1,
                kind: LessonKind.lecture,
              ),
          ],
        ),
        marks: const [],
        now: now,
        zone: moscow,
        limit: 5,
      );
      expect(many, hasLength(5));
      final times = many.map((r) => r.fireAt).toList();
      expect([...times]..sort(), times);
    });

    test('уже закончившееся занятие сегодня не напоминает', () {
      expect(
        plan(_input(), at: DateTime.utc(2026, 10, 5, 8)).first,
        startsWith('2026-10-12'),
      );
    });

    test('отмеченное занятие не напоминает; отметка снимает напоминание', () {
      const mark = AttendanceMark(
        slotId: 'mon',
        date: '2026-10-05',
        status: AttendanceStatus.present,
      );
      expect(
        plan(_input(), marks: const [mark]).first,
        startsWith('2026-10-12'),
      );
      expect(plan(_input()).first, startsWith('2026-10-05'));
    });

    test('отменённая изменением и перенесённая пара: вопроса нет в исходный '
        'день; перенесённая — в день переноса в новое время', () {
      final cancelled = plan(
        _input(
          overrides: const [
            ClassOverride(
              id: 'o1',
              slotId: 'mon',
              date: '2026-10-05',
              action: OverrideAction.cancel,
            ),
          ],
        ),
      );
      expect(cancelled.first, startsWith('2026-10-12'));
      final moved = plan(
        _input(
          overrides: const [
            ClassOverride(
              id: 'o1',
              slotId: 'mon',
              date: '2026-10-05',
              action: OverrideAction.move,
              newDate: '2026-10-07',
              startTime: '14:00',
              endTime: '15:30',
            ),
          ],
        ),
      );
      expect(moved.first, startsWith('2026-10-07T12:30:00Z'));
      // Отметка по исходной дате гасит напоминание и у перенесённой.
      final marked = plan(
        _input(
          overrides: const [
            ClassOverride(
              id: 'o1',
              slotId: 'mon',
              date: '2026-10-05',
              action: OverrideAction.move,
              newDate: '2026-10-07',
            ),
          ],
        ),
        marks: const [
          AttendanceMark(
            slotId: 'mon',
            date: '2026-10-05',
            status: AttendanceStatus.absent,
          ),
        ],
      );
      expect(marked.first, startsWith('2026-10-12'));
    });

    test('праздник: напоминания нет', () {
      final reminders = plan(
        _input(holidays: const {'2026-10-12': 'Праздник'}),
        days: 15,
      );
      expect(reminders, hasLength(2));
      expect(reminders.map((r) => r.substring(0, 10)), [
        '2026-10-05',
        '2026-10-19',
      ]);
    });

    test('особый день: пары скрыты — вопроса нет; занятия особого дня не '
        'отмечаются', () {
      const rule = DayRule(
        id: 'r1',
        semesterId: _sem,
        weekday: 1,
        title: 'Олимпиада',
        hideRegular: true,
        items: [
          RuleItem(
            key: 'i1',
            title: 'Занятие',
            kind: LessonKind.other,
            number: 1,
          ),
        ],
      );
      expect(plan(_input(rules: const [rule])), isEmpty);
      // Обычные пары не скрыты: вопрос только про пару, не про занятие дня.
      const open = DayRule(
        id: 'r1',
        semesterId: _sem,
        weekday: 1,
        title: 'Олимпиада',
        items: [
          RuleItem(
            key: 'i1',
            title: 'Занятие',
            kind: LessonKind.other,
            number: 2,
          ),
        ],
      );
      final reminders = plan(_input(rules: const [open]), days: 1);
      expect(reminders, hasLength(1));
      expect(reminders.single, contains('«Матан»'));
    });

    test('занятие без времени и архивный семестр', () {
      expect(
        plan(
          _input(
            slots: const [
              ClassSlot(
                id: 'x',
                semesterId: _sem,
                title: 'Кружок',
                weekday: 1,
                number: 9,
                kind: LessonKind.other,
              ),
            ],
          ),
        ),
        isEmpty,
      );
      expect(plan(_input(archived: true)), isEmpty);
    });

    test('своё время пары и пара без аудитории', () {
      final reminders = plan(
        _input(
          slots: const [
            ClassSlot(
              id: 'own',
              semesterId: _sem,
              title: 'Кружок',
              weekday: 1,
              startTime: '17:00',
              endTime: '18:30',
              kind: LessonKind.other,
            ),
          ],
        ),
      );
      expect(reminders.first, '2026-10-05T15:30:00Z «Кружок» · 17:00–18:30');
    });
  });

  group('источник в общем планировщике напоминаний', () {
    late ManualClock clock;
    late FakeSyncServer server;
    late StudyDevice phone;
    late FakeReminderScheduler scheduler;
    late ReminderService service;
    late String slotId;
    late tz.Location zone;

    setUp(() async {
      clock = ManualClock(now.millisecondsSinceEpoch);
      server = appServer(clock);
      zone = moscow;
      phone = await StudyDevice.create(server, clock: clock);
      scheduler = FakeReminderScheduler();
      final sem = phone.study.newId();
      await phone.study.createSemester(
        Semester(
          id: sem,
          name: 'Осень',
          startDate: '2026-09-01',
          endDate: '2026-12-31',
          week1Start: '2026-08-31',
        ),
      );
      final subj = phone.study.newId();
      await phone.study.createSubject(
        Subject(id: subj, semesterId: sem, name: 'Матан'),
      );
      await phone.study.saveBell(
        semesterId: sem,
        number: 1,
        startTime: '08:30',
        endTime: '10:00',
      );
      slotId = phone.study.newId();
      await phone.study.createSlot(
        ClassSlot(
          id: slotId,
          semesterId: sem,
          subjectId: subj,
          weekday: 1,
          number: 1,
          kind: LessonKind.lecture,
        ),
      );
      service = ReminderService(
        store: phone.device.store,
        scheduler: scheduler,
        settings: CalendarSettingsRepository(
          UserSettingsRepository(phone.device.store),
        ),
        zone: () => zone,
        now: () => clock.now,
        debounce: Duration.zero,
        refreshEvery: null,
        extraSources: [
          StudyReminderSource(
            store: phone.device.store,
            holidays: HolidayCalendar.empty,
          ),
        ],
      );
    });
    tearDown(() async {
      await service.stop();
      await phone.close();
      await server.dispose();
    });

    Future<void> settle(bool Function() until) async {
      for (var i = 0; i < 300 && !until(); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(until(), isTrue, reason: 'условие не наступило');
    }

    test('планируется вместе с событиями, не отменяется их пересчётом, '
        'снимается отметкой', () async {
      final calendars = phone.device.store;
      expect(calendars, isNotNull);
      await service.start();
      expect(scheduler.sorted.map((r) => r.title).toSet(), {'Был на паре?'});
      expect(scheduler.sorted.first.payload, startsWith('study:$slotId|'));
      final before = scheduler.scheduled.length;

      // Событие с напоминанием: общий пересчёт не трогает «Был на паре?».
      final personal = systemCalendarId('personal');
      await phone.device.store.create('calendars', personal, {
        'name': 'Личное',
        'color': null,
        'kind': 'system',
        'system_key': 'personal',
        'visible': true,
        'position': 0,
      });
      await phone.device.store.create('events', _uuid(1), {
        'calendar_id': personal,
        'title': 'Событие',
        'description': null,
        'location': null,
        'all_day': false,
        'start_at': '2026-10-06T07:00:00Z',
        'end_at': '2026-10-06T08:00:00Z',
        'tz': 'Europe/Moscow',
        'start_date': null,
        'end_date': null,
        'rrule': null,
        'reminders': [0],
        'source': 'manual',
      });
      await settle(() => scheduler.scheduled.length == before + 1);
      expect(
        scheduler.sorted.where((r) => r.title == 'Был на паре?'),
        hasLength(before),
      );

      // Отметка снимает ближайшее напоминание.
      await phone.study.mark(slotId, '2026-10-05', AttendanceStatus.present);
      await settle(() => scheduler.scheduled.length == before);
      expect(
        scheduler.sorted.where((r) => r.title == 'Был на паре?').first.payload,
        'study:$slotId|2026-10-12',
      );
    });

    test('архив семестра убирает напоминания', () async {
      await service.start();
      expect(scheduler.scheduled, isNotEmpty);
      final sem =
          (await phone.device.store.visibleRows('study_semesters'))
                  .single['id']!
              as String;
      await phone.study.setSemesterArchived(sem, archived: true);
      await settle(() => scheduler.scheduled.isEmpty);
    });
  });
}

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';
