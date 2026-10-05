import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';

/// Слой «Учёба» календаря: занятия считаются из расписания, а не хранятся
/// событиями (spec `stage7_study.md`, раздел 0). Элемент ведёт себя как
/// событие слоя `study` (те же блоки, повестка, месяц), но нажатие
/// открывает лист занятия (отметка посещаемости, изменение), а двигать и
/// растягивать его нельзя.
@immutable
class StudyEventItem extends EventItem {
  StudyEventItem({
    required this.lesson,
    required this.date,
    required super.title,
    required super.start,
    required super.end,
    required super.allDay,
    super.location,
  }) : super(
         event: EventEntity(
           id: 'study:${lesson.key}',
           calendarId: studyLayerId,
           title: title,
           allDay: allDay,
           location: location,
           source: EventSource.study,
         ),
         key: lesson.key,
         layerKind: 'study',
         layerName: 'Учёба',
         alternating: false,
       );

  /// Занятие расписания.
  final Lesson lesson;

  /// День, в котором занятие показано (`YYYY-MM-DD`; у перенесённого —
  /// день переноса).
  final String date;
}

/// `id` системного слоя «Учёба» (spec Этапа 2, 3.1).
final String studyLayerId = systemCalendarId('study');

DateTime _wall(String date, String time) {
  final d = parseDate(date)!;
  return DateTime.utc(
    d.year,
    d.month,
    d.day,
    int.parse(time.substring(0, 2)),
    int.parse(time.substring(3)),
  );
}

/// Занятия расписания на полуоткрытом отрезке дат `[fromDate, toDate)` в
/// виде элементов календаря. Отменённые и перенесённые в другой день
/// занятия не показываются (их нет в этот день); перенесённое — в день
/// переноса. Время занятий — местное время вуза, показывается как
/// записано; занятие без времени — полосой «весь день».
List<StudyEventItem> buildStudyItems(
  StudyData data, {
  required DateTime fromDate,
  required DateTime toDate,
}) {
  final items = <StudyEventItem>[];
  final from = dateOnly(fromDate);
  final to = dateOnly(toDate);
  if (data.liveSemesters.isEmpty) return items;
  for (var day = from; day.isBefore(to); day = addDays(day, 1)) {
    final iso = formatDate(day);
    for (final l in data.dayOf(iso).lessons) {
      if (l.cancelled || l.isMovedAway) continue;
      final hasTime = l.start != null && l.end != null;
      items.add(
        StudyEventItem(
          lesson: l,
          date: iso,
          title: l.title ?? 'Занятие',
          start: hasTime ? _wall(iso, l.start!) : day,
          end: hasTime ? _wall(iso, l.end!) : day,
          allDay: !hasTime,
          location: l.roomText.isEmpty ? null : l.roomText,
        ),
      );
    }
  }
  return items;
}
