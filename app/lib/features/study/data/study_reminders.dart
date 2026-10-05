import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:timezone/timezone.dart' as tz;

/// Горизонт напоминаний «Был на паре?» (дней вперёд).
const int studyReminderHorizonDays = 14;

/// Сколько напоминаний «Был на паре?» держим запланированными.
const int studyReminderLimit = 40;

/// Куда ведёт нажатие на напоминание «Был на паре?»:
/// `study:<slot_id>|<дата по расписанию>|<дата показа>`. У перенесённой пары
/// дата показа — день переноса (занятие живёт там); без неё (старый формат
/// `study:<slot_id>|<дата по расписанию>`) считается равной дате по
/// расписанию.
String studyReminderPayload(
  String slotId,
  String scheduledDate, [
  String? shownDate,
]) => 'study:$slotId|$scheduledDate|${shownDate ?? scheduledDate}';

/// Напоминания «Был на паре?» (spec `stage7_study.md`, 3.2 и 6): после
/// окончания каждого занятия, которое можно отметить (`trackable`) и ещё
/// не отмечено. Не приходят в праздники, для отменённых и перенесённых
/// пар, в день, где правило убрало пару, и для занятий особых дней — там
/// `trackable = false` (или самого занятия нет в развёртке). Время занятий —
/// местное время вуза: конец пары переводится в момент UTC в поясе
/// устройства.
List<PlannedReminder> planStudyReminders({
  required ScheduleInput input,
  required List<AttendanceMark> marks,
  required DateTime now,
  required tz.Location zone,
  int horizonDays = studyReminderHorizonDays,
  int limit = studyReminderLimit,
}) {
  if (input.semesters.every((s) => s.archived)) return const [];
  final today = dateOnly(utcToWall(zone, now));
  final marked = {for (final m in marks) (m.slotId, m.date)};
  final end = now.add(Duration(days: horizonDays));
  final result = <PlannedReminder>[];
  for (var i = 0; i <= horizonDays; i++) {
    final day = expandDay(formatDate(addDays(today, i)), input);
    for (final lesson in day.lessons) {
      final lessonEnd = lesson.end;
      if (!lesson.trackable || lessonEnd == null || !lesson.isSlot) continue;
      if (marked.contains((lesson.slotId ?? '', lesson.scheduledDate))) {
        continue;
      }
      final date = parseDate(lesson.date)!;
      final minutes = toMinutes(lessonEnd);
      final fireAt = wallToUtc(
        zone,
        date.year,
        date.month,
        date.day,
        minutes ~/ 60,
        minutes % 60,
      );
      if (fireAt.isBefore(now) || fireAt.isAfter(end)) continue;
      final title = lesson.title ?? 'Пара';
      final parts = [
        '«$title»',
        if (lesson.start != null) '${lesson.start}–$lessonEnd' else lessonEnd,
        if (lesson.roomText.isNotEmpty) lesson.roomText,
      ];
      final body = parts.join(' · ');
      result.add(
        PlannedReminder(
          id: reminderId(
            'study|${lesson.slotId}|${lesson.scheduledDate}|'
            '${fireAt.millisecondsSinceEpoch}|$body',
          ),
          fireAt: fireAt,
          title: 'Был на паре?',
          body: body,
          payload: studyReminderPayload(
            lesson.slotId ?? '',
            lesson.scheduledDate,
            lesson.date,
          ),
        ),
      );
    }
  }
  result.sort((a, b) {
    final c = a.fireAt.compareTo(b.fireAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return result.length > limit ? result.sublist(0, limit) : result;
}

/// Источник напоминаний «Был на паре?» для общего планировщика Этапа 2.
class StudyReminderSource implements ExtraReminderSource {
  StudyReminderSource({required this.store, required this.holidays});

  final SyncStore store;

  /// Праздники РФ (встроенный файл). Источник **асинхронный**: пока файл не
  /// загружен (холодный старт, фоновый изолят WorkManager), планировать
  /// нельзя — пустой календарь дал бы «Был на паре?» в праздник. Ошибка
  /// загрузки — напоминания не планируются (лучше промолчать, чем спросить
  /// в праздник).
  final Future<HolidayCalendar> Function() holidays;

  @override
  List<String> get tables => const [
    'study_semesters',
    'study_subjects',
    'study_bells',
    'class_slots',
    'study_day_rules',
    'class_overrides',
    'study_attendance',
  ];

  @override
  Future<List<PlannedReminder>> plan(DateTime now, tz.Location zone) async {
    final HolidayCalendar calendar;
    try {
      calendar = await holidays();
    } on Object catch (error, stack) {
      developer.log(
        'Праздники не загружены: «Был на паре?» не планируется',
        name: 'study_reminders',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
    final semesters = [
      for (final r in await store.visibleRows('study_semesters'))
        Semester.fromRow(r),
    ];
    if (semesters.every((s) => s.archived)) return const [];
    final from = formatDate(dateOnly(utcToWall(zone, now)));
    final to = formatDate(
      addDays(dateOnly(utcToWall(zone, now)), studyReminderHorizonDays),
    );
    final input = ScheduleInput(
      semesters: semesters,
      subjects: [
        for (final r in await store.visibleRows('study_subjects'))
          Subject.fromRow(r),
      ],
      bells: [
        for (final r in await store.visibleRows('study_bells')) Bell.fromRow(r),
      ],
      slots: [
        for (final r in await store.visibleRows('class_slots'))
          ClassSlot.fromRow(r),
      ],
      dayRules: [
        for (final r in await store.visibleRows('study_day_rules'))
          DayRule.fromRow(r),
      ],
      overrides: [
        for (final r in await store.visibleRows('class_overrides'))
          ClassOverride.fromRow(r),
      ],
      holidays: studyHolidays(calendar, from, to),
    );
    final marks = [
      for (final r in await store.visibleRows('study_attendance'))
        AttendanceMark.fromRow(r),
    ];
    return planStudyReminders(input: input, marks: marks, now: now, zone: zone);
  }
}

final Provider<StudyReminderSource> studyReminderSourceProvider =
    Provider<StudyReminderSource>(
      (ref) => StudyReminderSource(
        store: ref.watch(syncStoreProvider),
        holidays: () => ref.read(holidayCalendarProvider.future),
      ),
    );
