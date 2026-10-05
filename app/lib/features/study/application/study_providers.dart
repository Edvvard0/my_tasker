import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';

StreamProvider<List<T>> _rows<T>(
  String table,
  T Function(Map<String, Object?>) parse, {
  String? orderBy,
}) => StreamProvider<List<T>>(
  (ref) => ref
      .watch(syncStoreProvider)
      .watchVisibleRows(table, orderBy: orderBy)
      .map((rows) => [for (final r in rows) parse(r)]),
);

final StreamProvider<List<Semester>> studySemestersProvider = _rows<Semester>(
  'study_semesters',
  Semester.fromRow,
  orderBy: 't.start_date DESC, t.id',
);

final StreamProvider<List<Subject>> studySubjectsProvider = _rows<Subject>(
  'study_subjects',
  Subject.fromRow,
  orderBy: 't.name, t.id',
);

final StreamProvider<List<Bell>> studyBellsProvider = _rows<Bell>(
  'study_bells',
  Bell.fromRow,
  orderBy: 't.number, t.id',
);

final StreamProvider<List<ClassSlot>> classSlotsProvider = _rows<ClassSlot>(
  'class_slots',
  ClassSlot.fromRow,
  orderBy: 't.weekday, t.number, t.id',
);

final StreamProvider<List<DayRule>> studyDayRulesProvider = _rows<DayRule>(
  'study_day_rules',
  DayRule.fromRow,
  orderBy: 't.created_at, t.id',
);

final StreamProvider<List<ClassOverride>> classOverridesProvider =
    _rows<ClassOverride>(
      'class_overrides',
      ClassOverride.fromRow,
      orderBy: 't.date, t.id',
    );

final StreamProvider<List<AttendanceMark>> studyAttendanceProvider =
    _rows<AttendanceMark>(
      'study_attendance',
      AttendanceMark.fromRow,
      orderBy: 't.date, t.id',
    );

final StreamProvider<List<StudyDebt>> studyDebtsProvider = _rows<StudyDebt>(
  'study_debts',
  StudyDebt.fromRow,
  orderBy: 't.due_date IS NULL, t.due_date, t.created_at, t.id',
);

final StreamProvider<List<Attachment>> studyAttachmentsProvider =
    _rows<Attachment>(
      'attachments',
      Attachment.fromRow,
      orderBy: 't.created_at, t.id',
    );

/// Весь снимок «Учёбы» с готовыми расчётами. Расчёты — чистые функции
/// `study_schedule.dart` (общие векторы с сервером); здесь только кэш.
@immutable
class StudyData {
  StudyData({
    required this.semesters,
    required this.subjects,
    required this.bells,
    required this.slots,
    required this.dayRules,
    required this.overrides,
    required this.marks,
    required this.debts,
    required this.attachments,
    required this.calendar,
    required this.today,
  });

  final List<Semester> semesters;
  final List<Subject> subjects;
  final List<Bell> bells;
  final List<ClassSlot> slots;
  final List<DayRule> dayRules;
  final List<ClassOverride> overrides;
  final List<AttendanceMark> marks;
  final List<StudyDebt> debts;
  final List<Attachment> attachments;

  /// Праздники РФ (Этап 2).
  final HolidayCalendar calendar;

  /// Сегодняшняя дата в поясе устройства (`YYYY-MM-DD`).
  final String today;

  late final Map<String, Semester> semesterById = {
    for (final s in semesters) s.id: s,
  };
  late final Map<String, Subject> subjectById = {
    for (final s in subjects) s.id: s,
  };
  late final Map<String, ClassSlot> slotById = {for (final s in slots) s.id: s};
  late final Map<String, StudyDebt> debtById = {for (final d in debts) d.id: d};
  late final Map<(String, String), AttendanceMark> markBySlotDate = {
    for (final m in marks) (m.slotId, m.date): m,
  };

  /// Неархивные семестры (в расписание входят только они).
  late final List<Semester> liveSemesters = [
    for (final s in semesters)
      if (!s.archived) s,
  ];

  /// Праздники на все даты неархивных семестров.
  late final Map<String, String> holidays = () {
    if (liveSemesters.isEmpty) return const <String, String>{};
    var first = liveSemesters.first.startDate;
    var last = liveSemesters.first.endDate;
    for (final s in liveSemesters) {
      if (s.startDate.compareTo(first) < 0) first = s.startDate;
      if (s.endDate.compareTo(last) > 0) last = s.endDate;
    }
    return studyHolidays(calendar, first, last);
  }();

  /// Входные данные развёртки: только предметы и пары живых семестров.
  late final ScheduleInput input = ScheduleInput(
    semesters: semesters,
    subjects: subjects,
    bells: bells,
    slots: slots,
    dayRules: dayRules,
    overrides: overrides,
    holidays: holidays,
  );

  final Map<String, ScheduleDay> _days = {};

  /// Расписание даты (кэшируется).
  ScheduleDay dayOf(String date) => _days[date] ??= expandDay(date, input);

  /// Расписание на [count] дней начиная с [first] (`YYYY-MM-DD`).
  List<ScheduleDay> days(String first, int count) {
    final start = parseDate(first)!;
    return [
      for (var i = 0; i < count; i++) dayOf(formatDate(addDays(start, i))),
    ];
  }

  /// Счётчики посещаемости по предметам на сегодня.
  late final Map<String, SubjectAttendance> attendance = {
    for (final a in attendanceSummary(today, input, marks)) a.subjectId: a,
  };

  /// Предметы семестра (неархивные первыми).
  List<Subject> subjectsOf(String semesterId, {bool archived = false}) => [
    for (final s in subjects)
      if (s.semesterId == semesterId && s.archived == archived) s,
  ];

  List<StudyDebt> debtsOf(String subjectId) => [
    for (final d in debts)
      if (d.subjectId == subjectId) d,
  ];

  /// Открытые долги (не сданы), по сроку.
  List<StudyDebt> get openDebts => [
    for (final d in debts)
      if (d.isOpen) d,
  ];

  List<Attachment> attachmentsOfSubject(String subjectId) => [
    for (final a in attachments)
      if (a.subjectId == subjectId) a,
  ];

  List<Attachment> attachmentsOfDebt(String debtId) => [
    for (final a in attachments)
      if (a.debtId == debtId) a,
  ];

  /// Пары семестра по дням недели.
  List<ClassSlot> slotsOf(String semesterId) => [
    for (final s in slots)
      if (s.semesterId == semesterId) s,
  ];

  /// Обычная сетка звонков семестра (по номеру).
  List<Bell> bellsOf(String semesterId) => [
    for (final b in bells)
      if (b.semesterId == semesterId && b.onDate == null) b,
  ]..sort((a, b) => a.number.compareTo(b.number));

  /// Звонки «только на дату».
  List<Bell> dateBellsOf(String semesterId) =>
      [
        for (final b in bells)
          if (b.semesterId == semesterId && b.onDate != null) b,
      ]..sort((a, b) {
        final c = a.onDate!.compareTo(b.onDate!);
        return c != 0 ? c : a.number.compareTo(b.number);
      });

  List<DayRule> rulesOf(String semesterId) => [
    for (final r in dayRules)
      if (r.semesterId == semesterId) r,
  ];

  /// Изменения пары на даты.
  List<ClassOverride> overridesOfSlot(String slotId) => [
    for (final o in overrides)
      if (o.slotId == slotId) o,
  ];

  /// Название предмета пары для списков («Мат. анализ»).
  String slotTitle(ClassSlot slot) {
    final t = slot.title;
    if (t != null && t.isNotEmpty) return t;
    final s = subjectById[slot.subjectId];
    return s?.name ?? 'Пара';
  }

  /// Семестр, с которым работает раздел: идущий сегодня, иначе ближайший
  /// будущий, иначе последний прошедший.
  Semester? get currentSemester {
    final now = semesterFor(today, semesters);
    if (now != null) return now;
    Semester? upcoming;
    Semester? past;
    for (final s in liveSemesters) {
      if (s.startDate.compareTo(today) > 0) {
        if (upcoming == null || s.startDate.compareTo(upcoming.startDate) < 0) {
          upcoming = s;
        }
      } else if (past == null || s.endDate.compareTo(past.endDate) > 0) {
        past = s;
      }
    }
    return upcoming ?? past;
  }

  /// Долги просрочены на сегодня.
  int get overdueCount => debts.where((d) => d.isOverdue(today)).length;
}

/// «Повторить» после ошибки чтения: пересоздаёт все потоки раздела.
void retryStudyData(WidgetRef ref) {
  ref
    ..invalidate(studySemestersProvider)
    ..invalidate(studySubjectsProvider)
    ..invalidate(studyBellsProvider)
    ..invalidate(classSlotsProvider)
    ..invalidate(studyDayRulesProvider)
    ..invalidate(classOverridesProvider)
    ..invalidate(studyAttendanceProvider)
    ..invalidate(studyDebtsProvider)
    ..invalidate(studyAttachmentsProvider);
}

/// Снимок «Учёбы»: ошибка любого потока — ошибка экрана, пока хотя бы
/// один загружается — загрузка.
final Provider<AsyncValue<StudyData>> studyDataProvider =
    Provider<AsyncValue<StudyData>>((ref) {
      final semesters = ref.watch(studySemestersProvider);
      final subjects = ref.watch(studySubjectsProvider);
      final bells = ref.watch(studyBellsProvider);
      final slots = ref.watch(classSlotsProvider);
      final rules = ref.watch(studyDayRulesProvider);
      final overrides = ref.watch(classOverridesProvider);
      final marks = ref.watch(studyAttendanceProvider);
      final debts = ref.watch(studyDebtsProvider);
      final attachments = ref.watch(studyAttachmentsProvider);
      final calendar = ref.watch(holidaysProvider);
      final today = formatDate(ref.watch(todayProvider));
      final all = <AsyncValue<Object?>>[
        semesters,
        subjects,
        bells,
        slots,
        rules,
        overrides,
        marks,
        debts,
        attachments,
      ];
      for (final v in all) {
        if (v.hasError && !v.hasValue) {
          return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
        }
      }
      if (all.any((v) => !v.hasValue)) return const AsyncValue.loading();
      return AsyncValue.data(
        StudyData(
          semesters: semesters.requireValue,
          subjects: subjects.requireValue,
          bells: bells.requireValue,
          slots: slots.requireValue,
          dayRules: rules.requireValue,
          overrides: overrides.requireValue,
          marks: marks.requireValue,
          debts: debts.requireValue,
          attachments: attachments.requireValue,
          calendar: calendar,
          today: today,
        ),
      );
    });
