import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_taps.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';
import 'package:my_tasker/features/sleep/data/sleep_reminders.dart';
import 'package:my_tasker/features/sleep/data/sleep_settings.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_reminder_scheduler.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';
import '../../support/sleep_env.dart';

const _on = SleepReminderSetting(enabled: true, time: '09:00');
const _eveningOn = SleepReminderSetting(enabled: true, time: '21:30');

void main() {
  ensureTimeZones();
  final moscow = requireLocation('Europe/Moscow');
  // Понедельник 5 октября 2026, 08:00 по Москве.
  final now = DateTime.utc(2026, 10, 5, 5);

  List<String> plan({
    SleepReminderSetting morning = _on,
    SleepReminderSetting evening = _eveningOn,
    Set<String> sleep = const {},
    Set<String> checkins = const {},
    DateTime? at,
    int days = 3,
  }) => [
    for (final r in planSleepReminders(
      morning: morning,
      evening: evening,
      sleepDates: sleep,
      checkinDates: checkins,
      now: at ?? now,
      zone: moscow,
      horizonDays: days,
    ))
      '${formatInstant(r.fireAt)} ${r.title}',
  ];

  group('планировщик напоминаний «Сна»', () {
    test('по умолчанию: 09:00 «Как спал?» и 21:30 чек-ин, каждый день', () {
      expect(plan(), [
        '2026-10-05T06:00:00Z Как спал?',
        '2026-10-05T18:30:00Z Вечерний чек-ин',
        '2026-10-06T06:00:00Z Как спал?',
        '2026-10-06T18:30:00Z Вечерний чек-ин',
        '2026-10-07T06:00:00Z Как спал?',
        '2026-10-07T18:30:00Z Вечерний чек-ин',
      ]);
      expect(defaultMorningTime, '09:00');
      expect(defaultEveningTime, '21:30');
    });

    test('сон за сегодня записан — утреннего на сегодня нет; чек-ин готов — '
        'вечернего нет', () {
      expect(plan(sleep: {'2026-10-05'}, checkins: {'2026-10-05'}, days: 2), [
        '2026-10-06T06:00:00Z Как спал?',
        '2026-10-06T18:30:00Z Вечерний чек-ин',
      ]);
    });

    test('прошедшее время не планируется', () {
      expect(plan(at: DateTime.utc(2026, 10, 5, 12), days: 1), [
        '2026-10-05T18:30:00Z Вечерний чек-ин',
      ]);
      expect(plan(at: DateTime.utc(2026, 10, 5, 20), days: 1), isEmpty);
    });

    test('выключенные не планируются; время настраивается', () {
      expect(
        plan(
          morning: const SleepReminderSetting(enabled: false, time: '09:00'),
          days: 1,
        ),
        ['2026-10-05T18:30:00Z Вечерний чек-ин'],
      );
      expect(
        plan(
          evening: const SleepReminderSetting(enabled: false, time: '21:30'),
          morning: const SleepReminderSetting(enabled: true, time: '08:15'),
          days: 2,
        ),
        ['2026-10-05T05:15:00Z Как спал?', '2026-10-06T05:15:00Z Как спал?'],
      );
    });

    test('текст, нажатие и стабильные id', () {
      final list = planSleepReminders(
        morning: _on,
        evening: _eveningOn,
        sleepDates: const {},
        checkinDates: const {},
        now: now,
        zone: moscow,
        horizonDays: 1,
      );
      expect(list.first.payload, 'sleep:morning|2026-10-05');
      expect(
        list.first.payload,
        sleepReminderPayload(SleepReminderKind.morning, '2026-10-05'),
      );
      expect(list.last.payload, 'sleep:evening|2026-10-05');
      expect(list.first.id, isNot(list.last.id));
      final again = planSleepReminders(
        morning: _on,
        evening: _eveningOn,
        sleepDates: const {},
        checkinDates: const {},
        now: now,
        zone: moscow,
        horizonDays: 1,
      );
      expect([for (final r in again) r.id], [for (final r in list) r.id]);
    });

    test('перевод часов: 09:00 остаётся 09:00 на стене', () {
      // Европа/Берлин: конец лета 25 октября 2026.
      final berlin = requireLocation('Europe/Berlin');
      final list = planSleepReminders(
        morning: _on,
        evening: _eveningOn,
        sleepDates: const {},
        checkinDates: const {},
        now: DateTime.utc(2026, 10, 24, 5),
        zone: berlin,
        horizonDays: 3,
      );
      final morning = [
        for (final r in list)
          if (r.title == 'Как спал?') r,
      ];
      expect(
        [for (final r in morning) formatInstant(r.fireAt)],
        [
          '2026-10-24T07:00:00Z',
          '2026-10-25T08:00:00Z',
          '2026-10-26T08:00:00Z',
        ],
      );
    });
  });

  group('нажатие на напоминание', () {
    test('разбор payload', () {
      expect(
        parseReminderPayload('sleep:morning|2026-10-05'),
        const SleepTarget(SleepReminderKind.morning, '2026-10-05'),
      );
      expect(
        parseReminderPayload('sleep:evening|2026-10-05'),
        const SleepTarget(SleepReminderKind.evening, '2026-10-05'),
      );
      expect(parseReminderPayload('sleep:night|2026-10-05'), isNull);
      expect(parseReminderPayload('sleep:morning|'), isNull);
      expect(parseReminderPayload('sleep:morning'), isNull);
      expect(
        const SleepTarget(SleepReminderKind.morning, 'd').hashCode,
        const SleepTarget(SleepReminderKind.morning, 'd').hashCode,
      );
    });
  });

  group('настройки напоминаний', () {
    late ManualClock clock;
    late FakeSyncServer server;
    late SleepDevice dev;
    late SleepSettingsRepository settings;

    setUp(() async {
      clock = ManualClock(now.millisecondsSinceEpoch);
      server = appServer(clock);
      dev = await SleepDevice.create(server, clock: clock);
      settings = SleepSettingsRepository(
        UserSettingsRepository(dev.device.store),
      );
    });
    tearDown(() async {
      await dev.close();
      await server.dispose();
    });

    test('значения по умолчанию, запись и чтение', () async {
      expect(await settings.readMorning(), _on);
      expect(await settings.readEvening(), _eveningOn);
      await settings.writeMorning(
        const SleepReminderSetting(enabled: false, time: '08:30'),
      );
      await settings.writeEvening(
        const SleepReminderSetting(enabled: true, time: '22:00'),
      );
      expect((await settings.readMorning()).enabled, isFalse);
      expect((await settings.readMorning()).time, '08:30');
      expect((await settings.readEvening()).minutes, 22 * 60);
      expect(await settings.watchMorning().first, isNotNull);
      expect((await settings.watchEvening().first).time, '22:00');
    });

    test('мусор в настройке читается как значение по умолчанию', () async {
      final store = UserSettingsRepository(dev.device.store);
      await store.set(morningReminderKey, {'enabled': true, 'time': '99:99'});
      expect((await settings.readMorning()).time, defaultMorningTime);
      await store.set(eveningReminderKey, 'строка');
      expect(await settings.readEvening(), _eveningOn);
    });

    test('время только ЧЧ:ММ', () async {
      await expectLater(
        settings.writeMorning(
          const SleepReminderSetting(enabled: true, time: '25:00'),
        ),
        throwsA(isA<Object>()),
      );
    });

    test('значение и копия', () {
      const s = SleepReminderSetting(enabled: true, time: '09:00');
      expect(s.copyWith(enabled: false).enabled, isFalse);
      expect(s.copyWith(time: '10:00').time, '10:00');
      expect(s.toJson(), {'enabled': true, 'time': '09:00'});
      expect(s.hashCode, _on.hashCode);
      expect(parseClockMinutes('21:30'), 21 * 60 + 30);
    });

    test('источник: читает данные, пересчёт при записи сна', () async {
      final source = SleepReminderSource(
        store: dev.device.store,
        settings: settings,
      );
      expect(source.tables, contains('sleep_entries'));
      expect(source.tables, contains('evening_checkins'));
      var list = await source.plan(now, moscow);
      expect(list, hasLength(14));
      await dev.sleep.saveCheckin(
        date: '2026-10-05',
        doneTaskIds: const [],
        rating: 3,
      );
      await seedNight(dev.sleep, '2026-10-05');
      list = await source.plan(now, moscow);
      expect(list, hasLength(12));
      await settings.writeMorning(
        const SleepReminderSetting(enabled: false, time: '09:00'),
      );
      await settings.writeEvening(
        const SleepReminderSetting(enabled: false, time: '21:30'),
      );
      expect(await source.plan(now, moscow), isEmpty);
    });

    test('общий планировщик напоминаний отдаёт уведомления «Сна»', () async {
      final scheduler = FakeReminderScheduler();
      final service = ReminderService(
        store: dev.device.store,
        scheduler: scheduler,
        settings: CalendarSettingsRepository(
          UserSettingsRepository(dev.device.store),
        ),
        zone: () => moscow,
        now: () => now,
        refreshEvery: null,
        extraSources: [
          SleepReminderSource(store: dev.device.store, settings: settings),
        ],
      );
      await service.replan();
      expect(scheduler.sorted.map((r) => r.title).toSet(), {
        'Как спал?',
        'Вечерний чек-ин',
      });
      expect(scheduler.sorted.first.payload, 'sleep:morning|2026-10-05');
      // Запись сна отменяет утреннее уведомление этого дня.
      await seedNight(dev.sleep, '2026-10-05');
      await service.replan();
      expect(
        scheduler.sorted.where((r) => r.payload == 'sleep:morning|2026-10-05'),
        isEmpty,
      );
      expect(parseDate('2026-10-05'), isNotNull);
    });
  });
}
