import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import 'pump_app.dart';

/// «Сейчас» для экранов Этапа 2: среда, 30 сентября 2026, 11:40 по Москве
/// (как в макетах дизайн-системы).
final DateTime demoNow = DateTime.utc(2026, 9, 30, 8, 40);

/// Запускает приложение с зафиксированными временем и часовым поясом
/// (Europe/Moscow) и, при [seed], с демонстрационными данными.
Future<ProviderContainer> pumpStage2(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/today',
  DateTime? now,
  bool seed = false,
  Future<void> Function(ProviderContainer container)? seedWith,
  List<Override> overrides = const [],
}) async {
  final container = await pumpApp(
    tester,
    size: size,
    location: location,
    now: now ?? demoNow,
    settle: false,
    overrides: [
      deviceTimeZoneSourceProvider.overrideWithValue(
        const FixedTimeZoneSource('Europe/Moscow'),
      ),
      ...overrides,
    ],
  );
  await tester.runAsync(() async {
    await container.read(calendarRepositoryProvider).ensureSystemCalendars();
    if (seed) await seedDemo(container);
    if (seedWith != null) await seedWith(container);
  });
  await tester.pumpAndSettle();
  return container;
}

DateTime _at(String iso) => DateTime.parse('${iso}Z');

/// Демонстрационная неделя: пары по чётным/нечётным неделям, созвон,
/// задачи с приоритетами, просрочка, подзадачи, бэклог.
Future<void> seedDemo(ProviderContainer container) async {
  final calendars = container.read(calendarRepositoryProvider);
  final tasks = container.read(taskRepositoryProvider);
  final settings = container.read(calendarSettingsRepositoryProvider);
  final personal = systemCalendarId('personal');
  final work = systemCalendarId('work');
  final study = systemCalendarId('study');

  // Цикл недель: 28 сентября — нечётная неделя.
  await settings.writeWeekCycle(
    WeekCycle(length: 2, week1Start: DateTime.utc(2026, 9, 14)),
  );

  EventEntity event(
    String title,
    String calendar,
    String startUtc,
    String endUtc, {
    String? rrule,
    String? location,
    List<int>? reminders,
  }) => EventEntity(
    id: calendars.newEventId(),
    calendarId: calendar,
    title: title,
    allDay: false,
    startAt: _at(startUtc),
    endAt: _at(endUtc),
    tz: 'Europe/Moscow',
    rrule: rrule,
    location: location,
    reminders: reminders,
  );

  // Пары по нечётным неделям: вторник и четверг (10:40–12:10 МСК).
  await calendars.createEvent(
    event(
      'Матанализ',
      study,
      '2026-09-29T07:40:00',
      '2026-09-29T09:10:00',
      rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH',
      location: 'ауд. 305',
    ),
  );
  await calendars.createEvent(
    event(
      'Английский',
      study,
      '2026-09-28T06:00:00',
      '2026-09-28T07:30:00',
      rrule: 'FREQ=WEEKLY;BYDAY=MO,FR',
      location: 'ауд. 112',
    ),
  );
  await calendars.createEvent(
    event(
      'Созвон Creora',
      work,
      '2026-09-30T12:00:00',
      '2026-09-30T13:00:00',
      location: 'Zoom',
      reminders: const [10],
    ),
  );
  await calendars.createEvent(
    event(
      'Спринт: планирование',
      work,
      '2026-10-02T07:00:00',
      '2026-10-02T08:30:00',
    ),
  );
  await calendars.createEvent(
    event('Тренировка', personal, '2026-09-30T15:00:00', '2026-09-30T16:00:00'),
  );
  await calendars.createEvent(
    EventEntity(
      id: calendars.newEventId(),
      calendarId: personal,
      title: 'День рождения Ромы',
      allDay: true,
      startDate: DateTime.utc(2026, 10, 3),
      endDate: DateTime.utc(2026, 10, 3),
    ),
  );

  final projectBot = await tasks.createProject('Бот разборов ИИ');
  final projectCreora = await tasks.createProject('Creora');

  Future<String> task(
    String title, {
    TaskDue due = const TaskDue.none(),
    int? priority,
    String? projectId,
    TaskStatus? status,
    int? duration,
  }) async {
    final id = tasks.newTaskId();
    await tasks.createTask(
      TaskEntity(
        id: id,
        title: title,
        status: status ?? (due.isNone ? TaskStatus.inbox : TaskStatus.todo),
        due: due,
        priority: priority,
        projectId: projectId,
        durationMinutes: duration,
      ),
    );
    return id;
  }

  await task(
    'Оплатить домен',
    due: TaskDue.date(DateTime.utc(2026, 9, 29)),
    priority: 1,
  );
  await task(
    'Ответить Эмиру',
    due: TaskDue.date(DateTime.utc(2026, 9, 27)),
    priority: 3,
  );
  final login = await task(
    'Доработать вход в бот',
    due: TaskDue.at(_at('2026-09-30T11:00:00'), 'Europe/Moscow'),
    priority: 2,
    projectId: projectBot,
    duration: 60,
  );
  for (final s in ['Форма входа', 'Токены', 'Тесты', 'Ревью', 'Релиз']) {
    final id = await tasks.addSubtask(login, s);
    if (s == 'Форма входа' || s == 'Токены') {
      await tasks.setSubtaskDone(id, done: true);
    }
  }
  await task(
    'Смета для Елены',
    due: TaskDue.date(DateTime.utc(2026, 9, 30)),
    projectId: projectCreora,
  );
  await task(
    'Созвон с Ромой',
    due: TaskDue.at(_at('2026-10-01T12:00:00'), 'Europe/Moscow'),
    priority: 4,
  );
  for (final t in [
    'Купить кроссовки',
    'Разобрать почту',
    'Записаться к врачу',
    'Продлить сертификат',
    'Идея: виджет расписания',
  ]) {
    await task(t, projectId: t == 'Продлить сертификат' ? projectCreora : null);
  }
  final done = await task(
    'Отправить счёт',
    due: TaskDue.date(DateTime.utc(2026, 9, 30)),
  );
  await tasks.setStatus(done, TaskStatus.done);
}

/// Часовой пояс для проверки дат в тестах.
DateTime moscow(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime.utc(y, m, d, h - 3, min);

/// Строка `YYYY-MM-DD`.
String ymd(DateTime d) => formatDate(d);

/// Событие с временем в UTC (`2026-09-30T12:00:00`), поясом Москвы.
Future<EventEntity> addEvent(
  ProviderContainer container, {
  required String title,
  required String startUtc,
  required String endUtc,
  String calendar = 'personal',
  String? rrule,
  String? location,
  List<int>? reminders,
}) async {
  final repo = container.read(calendarRepositoryProvider);
  final event = EventEntity(
    id: repo.newEventId(),
    calendarId: systemCalendarId(calendar),
    title: title,
    allDay: false,
    startAt: _at(startUtc),
    endAt: _at(endUtc),
    tz: 'Europe/Moscow',
    rrule: rrule,
    location: location,
    reminders: reminders,
  );
  await repo.createEvent(event);
  return event;
}

/// Событие «весь день».
Future<EventEntity> addAllDayEvent(
  ProviderContainer container, {
  required String title,
  required DateTime date,
  DateTime? endDate,
  String calendar = 'personal',
  String? rrule,
}) async {
  final repo = container.read(calendarRepositoryProvider);
  final event = EventEntity(
    id: repo.newEventId(),
    calendarId: systemCalendarId(calendar),
    title: title,
    allDay: true,
    startDate: date,
    endDate: endDate ?? date,
    rrule: rrule,
  );
  await repo.createEvent(event);
  return event;
}

/// Задача.
Future<TaskEntity> addTask(
  ProviderContainer container, {
  required String title,
  TaskDue due = const TaskDue.none(),
  int? priority,
  TaskStatus? status,
  String? rrule,
  RecurrenceMode? mode,
  int? duration,
  List<int>? reminders,
}) async {
  final repo = container.read(taskRepositoryProvider);
  final task = TaskEntity(
    id: repo.newTaskId(),
    title: title,
    status: status ?? (due.isNone ? TaskStatus.inbox : TaskStatus.todo),
    due: due,
    priority: priority,
    rrule: rrule,
    recurrenceMode: mode,
    durationMinutes: duration,
    reminders: reminders,
  );
  await repo.createTask(task);
  return task;
}

/// Момент в UTC из строки без `Z`.
DateTime utc(String iso) => _at(iso);
