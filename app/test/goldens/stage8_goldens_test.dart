import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';

import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../support/sleep_env.dart';
import '../support/study_env.dart' show seedStudyDemo;

/// Golden-тесты Этапа 8 (только ключевые экраны, 04, 2.4): «Сон», «Утренний
/// план» и «Вечерний чек-ин» на демо-данных (понедельник, 5 октября 2026).
/// Эталоны — `files/sleep_*.png`; обновление:
/// `flutter test --update-goldens test/goldens`.
/// Длинный телефонный экран: на снимке виден весь список, а не первый экран.
const Size _tall = Size(390, 1250);

Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

void main() {
  group('Сон', () {
    testWidgets('телефон', (tester) async {
      await pumpSleep(
        tester,
        size: _tall,
        now: sleepEvening,
        seedWith: seedSleepDemo,
      );
      expect(find.byKey(const Key('sleep-hero')), findsOneWidget);
      await _shot(tester, 'sleep_overview_phone');
    });

    testWidgets('десктоп', (tester) async {
      await pumpSleep(
        tester,
        size: desktopSize,
        now: sleepEvening,
        seedWith: seedSleepDemo,
      );
      await _shot(tester, 'sleep_overview_desktop');
    });
  });

  group('Утренний план', () {
    testWidgets('телефон', (tester) async {
      await pumpSleep(
        tester,
        size: _tall,
        location: '/sleep/morning',
        seedWith: (c) async {
          await seedSleepDemo(c);
          await seedTask(
            c,
            'Сдать отчёт по проекту',
            date: '2026-10-05',
            priority: 1,
          );
          await seedTask(c, 'Оплатить хостинг', date: '2026-10-03');
          await seedTask(c, 'Купить билеты', date: '2026-10-05');
          await seedStudyDemo(c);
          final calendars = c.read(calendarRepositoryProvider);
          await calendars.ensureSystemCalendars();
          await calendars.createEvent(
            EventEntity(
              id: c.read(taskRepositoryProvider).newTaskId(),
              calendarId: systemCalendarId('personal'),
              title: 'Созвон с заказчиком',
              allDay: false,
              startAt: DateTime.utc(2026, 10, 5, 11),
              endAt: DateTime.utc(2026, 10, 5, 12),
              tz: 'Europe/Moscow',
              location: 'Zoom',
            ),
          );
        },
      );
      expect(find.byKey(const Key('morning-plan')), findsOneWidget);
      await _shot(tester, 'sleep_morning_plan_phone');
    });
  });

  group('Вечерний чек-ин', () {
    testWidgets('телефон', (tester) async {
      await pumpSleep(
        tester,
        size: _tall,
        location: '/sleep/evening',
        now: sleepEvening,
        seedWith: (c) async {
          await seedSleepDemo(c);
          await seedTask(
            c,
            'Отчёт по проекту',
            date: '2026-10-05',
            status: TaskStatus.done,
          );
          await seedTask(
            c,
            'Купить билеты',
            date: '2026-10-05',
            status: TaskStatus.done,
          );
          await seedTask(
            c,
            'Подготовить презентацию',
            date: '2026-10-05',
            priority: 2,
          );
          await seedTask(c, 'Ответить на письма', date: '2026-10-05');
        },
      );
      expect(find.byKey(const Key('evening-checkin')), findsOneWidget);
      await _shot(tester, 'sleep_evening_checkin_phone');
    });
  });
}
