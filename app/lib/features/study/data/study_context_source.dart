import 'package:flutter/services.dart' show rootBundle;
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';

/// «Учёба» как источник контекста для чата ИИ (агент «Учёба»): расписание
/// на период (с отменами, переносами, особыми днями и праздниками),
/// пропуски по предметам и открытые долги. Расчёты — те же чистые функции,
/// что в интерфейсе и на сервере (общие векторы).
///
/// Фильтр `period`: `day` — сегодня, `week` — 7 дней, `month` — 30 дней.
class StudyContextSource extends ContextSource {
  const StudyContextSource({this.holidays});

  /// Праздники РФ; по умолчанию — встроенный файл (Этап 2). Тесты
  /// подставляют своё.
  final Future<HolidayCalendar> Function()? holidays;

  static HolidayCalendar? _cached;

  Future<HolidayCalendar> _calendar() async {
    final custom = holidays;
    if (custom != null) return await custom();
    try {
      return _cached ??= HolidayCalendar.fromJsonString(
        await rootBundle.loadString(holidaysAssetPath),
      );
    } on Object {
      return HolidayCalendar.empty();
    }
  }

  @override
  String get id => 'study';

  @override
  String get label => 'Учёба';

  @override
  String get description =>
      'Расписание на период, пропуски по предметам и открытые долги';

  @override
  List<ContextFilterField> get filters => const [
    ContextFilterField(
      key: 'period',
      label: 'Период расписания',
      options: {'day': 'Сегодня', 'week': '7 дней', 'month': '30 дней'},
    ),
  ];

  @override
  Map<String, Object?> get defaultFilter => const {'period': 'week'};

  @override
  String summary(Map<String, Object?> filter) => switch (filter['period']) {
    'day' => 'расписание на сегодня',
    'month' => 'расписание на 30 дней',
    _ => 'расписание на 7 дней',
  };

  @override
  Future<List<String>> lines(
    ContextEnv env,
    Map<String, Object?> filter,
  ) async {
    final semesters = [
      for (final r in await env.readRows('study_semesters'))
        Semester.fromRow(r),
    ];
    if (semesters.every((s) => s.archived)) return const [];
    final subjects = [
      for (final r in await env.readRows('study_subjects')) Subject.fromRow(r),
    ];
    final today = dateOnly(utcToWall(env.zone, env.now));
    final days = switch (filter['period']) {
      'day' => 1,
      'month' => 30,
      _ => 7,
    };
    final last = addDays(today, days - 1);
    var from = semesters.first.startDate;
    var to = semesters.first.endDate;
    for (final s in semesters) {
      if (s.startDate.compareTo(from) < 0) from = s.startDate;
      if (s.endDate.compareTo(to) > 0) to = s.endDate;
    }
    final input = ScheduleInput(
      semesters: semesters,
      subjects: subjects,
      bells: [
        for (final r in await env.readRows('study_bells')) Bell.fromRow(r),
      ],
      slots: [
        for (final r in await env.readRows('class_slots')) ClassSlot.fromRow(r),
      ],
      dayRules: [
        for (final r in await env.readRows('study_day_rules'))
          DayRule.fromRow(r),
      ],
      overrides: [
        for (final r in await env.readRows('class_overrides'))
          ClassOverride.fromRow(r),
      ],
      holidays: studyHolidays(await _calendar(), from, to),
    );
    final marks = [
      for (final r in await env.readRows('study_attendance'))
        AttendanceMark.fromRow(r),
    ];
    final debts = [
      for (final r in await env.readRows('study_debts')) StudyDebt.fromRow(r),
    ];
    final todayIso = formatDate(today);
    final byId = {for (final s in subjects) s.id: s};
    final out = <String>[];

    // Открытые долги: просроченные и ближайшие первыми.
    final open = [
      for (final d in debts)
        if (d.isOpen) d,
    ]..sort(_byDue);
    for (final d in open) {
      final subject = byId[d.subjectId]?.name ?? 'предмет';
      final note = (d.note ?? '').trim();
      final parts = [
        'Долг · $subject · ${d.title} (${d.kind.label.toLowerCase()})',
        if (d.dueDate != null) 'срок ${d.dueDate}',
        if (d.isOverdue(todayIso)) 'просрочен',
        if (note.isNotEmpty) 'заметка: ${_cut(note, 200)}',
      ];
      out.add('- ${parts.join(' · ')}');
    }

    // Пропуски по предметам с занятиями.
    for (final a in attendanceSummary(todayIso, input, marks)) {
      final subject = byId[a.subjectId];
      if (subject == null) continue;
      final total = a.present + a.absent + a.cancelled + a.unmarked;
      if (total == 0) continue;
      final teacher = (subject.teacher ?? '').isEmpty
          ? ''
          : ' · преподаватель ${subject.teacher}';
      final limit = a.limit == null
          ? 'лимит не задан'
          : 'лимит ${a.limit}, ${limitStateText(a).toLowerCase()}';
      out.add(
        '- Пропуски · ${subject.name}$teacher: пропустил ${a.absent}, был '
        '${a.present}, отменено ${a.cancelled}, не отмечено ${a.unmarked} · '
        '$limit',
      );
    }

    // Расписание: дни с занятиями или особым статусом.
    for (final day in expandRange(todayIso, formatDate(last), input)) {
      if (day.kind == DayKind.noSemester) continue;
      if (day.lessons.isEmpty && day.kind == DayKind.regular) continue;
      final head = [
        '- ${day.date} ${weekdayShort(day.weekday)}',
        if (day.kind == DayKind.holiday) 'праздник: ${day.name}',
        if (day.kind == DayKind.special) 'особый день: ${day.name}',
      ].join(' · ');
      if (day.lessons.isEmpty) {
        out.add('$head · занятий нет');
        continue;
      }
      final lessons = [
        for (final l in day.lessons)
          [
            lessonTime(l.start, l.end),
            l.title ?? 'занятие',
            _kindRoom(l),
            if (l.cancelled) '— отменена',
            if (l.movedTo != null) '— перенесена на ${l.movedTo}',
            if (l.movedFrom != null) '— перенос с ${l.movedFrom}',
          ].join(' '),
      ];
      out.add('$head: ${lessons.join('; ')}');
    }
    return out;
  }

  static String _kindRoom(Lesson l) {
    final room = l.roomText.isEmpty ? '' : ', ${l.roomText}';
    return '(${l.kind.label.toLowerCase()}$room)';
  }

  static int _byDue(StudyDebt a, StudyDebt b) {
    final ad = a.dueDate;
    final bd = b.dueDate;
    if (ad == bd) return a.title.compareTo(b.title);
    if (ad == null) return 1;
    if (bd == null) return -1;
    return ad.compareTo(bd);
  }

  static String _cut(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';
}
