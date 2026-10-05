import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_ids.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/domain/study_validation.dart';

const _sem = '01900000-0000-7000-8000-000000000001';

Semester _semester({
  String start = '2026-09-01',
  String end = '2026-12-31',
  String week1 = '2026-08-31',
  int cycle = 2,
  List<WeekShift> shifts = const [],
  String name = 'Осень',
}) => Semester(
  id: _sem,
  name: name,
  startDate: start,
  endDate: end,
  week1Start: week1,
  cycleLength: cycle,
  weekShifts: shifts,
);

Attachment _file({
  String name = 'a.pdf',
  String mime = 'application/pdf',
  int size = 10,
  String? sha,
  String? subject = 's',
  String? debt,
}) => Attachment(
  id: 'x',
  subjectId: subject,
  debtId: debt,
  fileName: name,
  mimeType: mime,
  sizeBytes: size,
  sha256: sha ?? 'a' * 64,
);

void main() {
  group('детерминированные идентификаторы (значения посчитаны Python)', () {
    test('звонок', () {
      expect(bellId(_sem, null, 1), 'b8faed1e-dc17-593d-bbb8-e1dc33e25f49');
      expect(
        bellId(_sem, '2026-09-14', 1),
        'bef1861e-ca6e-538c-b1ac-5fb41e9ea590',
      );
    });

    test('особый день', () {
      expect(
        dayRuleId(_sem, weekday: 4),
        '1efd8e63-d3cf-52a3-b58f-5adc5b138b91',
      );
      expect(
        dayRuleId(_sem, weekday: 4, cycleWeek: 2),
        '4becfdf1-f258-5b07-870f-f445ed2f0a02',
      );
      expect(
        dayRuleId(_sem, onDate: '2026-09-17'),
        '334f9167-1412-513a-bf5f-67b5ccb737b3',
      );
    });

    test('изменение на дату и отметка', () {
      expect(
        overrideId(_sem, '2026-09-07'),
        '90fe7f56-48c4-5c0a-84f7-760218886b93',
      );
      expect(
        attendanceId(_sem, '2026-09-07'),
        'eaa1c030-9f46-51a1-a9fb-79105c6ff3da',
      );
    });
  });

  group('модели', () {
    test('перечисления читаются мягко', () {
      expect(LessonKind.parse('lab'), LessonKind.lab);
      expect(LessonKind.parse('новое'), LessonKind.other);
      expect(OverrideAction.parse('move'), OverrideAction.move);
      expect(OverrideAction.parse('?'), OverrideAction.change);
      expect(AttendanceStatus.parse('absent'), AttendanceStatus.absent);
      expect(AttendanceStatus.parse('?'), isNull);
      expect(DebtKind.parse('rgr'), DebtKind.rgr);
      expect(DebtKind.parse('?'), DebtKind.other);
      expect(DebtStatus.parse('credited'), DebtStatus.credited);
      expect(DebtStatus.parse('?'), DebtStatus.open);
      expect(UploadStatus.parse('uploaded'), UploadStatus.uploaded);
      expect(UploadStatus.parse('?'), UploadStatus.pending);
    });

    test('семестр: колонки, сдвиги, подписи недель', () {
      final s = Semester.fromRow(const {
        'id': 's',
        'name': 'Осень',
        'start_date': '2026-09-01',
        'end_date': '2026-12-31',
        'week1_start': '2026-08-31',
        'cycle_length': 2,
        'week_shifts': [
          {'from': '2026-10-12', 'weeks': 1},
          {'from': 'мусор', 'weeks': 1},
          'не запись',
          {'from': '2026-10-19', 'weeks': 'x'},
        ],
        'archived': true,
      });
      expect(s.archived, isTrue);
      expect(s.weekShifts, hasLength(1));
      expect(s.weekNumber('2026-10-05'), 2);
      // Сдвиг на неделю меняет чётность с 12 октября.
      expect(s.weekNumber('2026-10-12'), 2);
      expect(s.weekLabel(1), 'Нечётная');
      expect(s.weekLabel(2), 'Чётная');
      expect(_semester(cycle: 1).weekLabel(1), 'Каждая неделя');
      expect(_semester(cycle: 3).weekLabel(2), 'Неделя 2');
      expect(s.toFields()['week_shifts'], [
        {'from': '2026-10-12', 'weeks': 1},
      ]);
      expect(_semester().toFields()['week_shifts'], isNull);
      // Битая опорная дата не роняет расчёт.
      expect(_semester(week1: 'x').weekNumber('2026-10-05'), 1);
      expect(_semester(cycle: 0).cycle, isNull);
      expect(s.copyWith(name: 'Весна').name, 'Весна');
      expect(s.copyWith(archived: false).archived, isFalse);
    });

    test('предмет, пара, долг: copyWith и колонки', () {
      const subject = Subject(
        id: 's',
        semesterId: _sem,
        name: 'Физика',
        teacher: 'А',
        building: '2',
        room: '101',
        absenceLimit: 3,
        note: 'n',
      );
      expect(subject.copyWith(teacher: null).teacher, isNull);
      expect(subject.copyWith(absenceLimit: null).absenceLimit, isNull);
      expect(subject.copyWith(note: null).note, isNull);
      expect(subject.copyWith(building: null, room: null).room, isNull);
      expect(subject.copyWith(name: 'Х').name, 'Х');
      expect(subject.copyWith(archived: true).toFields()['archived'], isTrue);
      expect(Subject.fromRow(const {'id': 's'}).name, '');

      const slot = ClassSlot(
        id: 'p',
        semesterId: _sem,
        weekday: 1,
        kind: LessonKind.lab,
        subjectId: 's',
        number: 2,
        cycleWeek: 1,
      );
      final next = slot.copyWith(
        subjectId: null,
        title: 'Кружок',
        weekday: 3,
        number: null,
        startTime: '14:00',
        endTime: '15:00',
        kind: LessonKind.other,
        building: '1',
        room: '5',
        cycleWeek: null,
      );
      expect(next.toFields(), {
        'subject_id': null,
        'title': 'Кружок',
        'weekday': 3,
        'number': null,
        'start_time': '14:00',
        'end_time': '15:00',
        'kind': 'other',
        'building': '1',
        'room': '5',
        'cycle_week': null,
      });
      expect(ClassSlot.fromRow(const {'id': 'p'}).weekday, 1);

      const debt = StudyDebt(id: 'd', subjectId: 's', title: 'ЛР');
      expect(debt.isOpen, isTrue);
      expect(debt.isOverdue('2026-10-05'), isFalse);
      final late = debt.copyWith(dueDate: '2026-10-01');
      expect(late.isOverdue('2026-10-05'), isTrue);
      expect(late.isOverdue('2026-10-01'), isFalse);
      expect(
        late.copyWith(status: DebtStatus.submitted).isOverdue('2026-10-05'),
        isFalse,
      );
      expect(late.copyWith(taskId: 't').toFields()['task_id'], 't');
      expect(late.copyWith(doneDate: '2026-10-02').doneDate, '2026-10-02');
      expect(late.copyWith(note: null).note, isNull);
      expect(
        late.copyWith(kind: DebtKind.exam, title: 'Э').kind,
        DebtKind.exam,
      );
      expect(StudyDebt.fromRow(const {'id': 'd'}).kind, DebtKind.other);
    });

    test('особый день, изменение, отметка, звонок, вложение', () {
      final rule = DayRule.fromRow(const {
        'id': 'r',
        'semester_id': _sem,
        'weekday': 4,
        'title': 'Олимпиада',
        'hide_regular': true,
        'items': [
          {'key': 'i1', 'title': 'Занятие', 'kind': 'other', 'number': 1},
          'мусор',
        ],
      });
      expect(rule.items, hasLength(1));
      expect(rule.toMutableFields()['items'], [
        {'key': 'i1', 'title': 'Занятие', 'kind': 'other', 'number': 1},
      ]);
      expect(rule.toFields(_sem)['weekday'], 4);
      expect(DayRule.fromRow(const {}).items, isEmpty);

      final item = RuleItem.fromJson(const {
        'key': 'k',
        'title': 'T',
        'kind': 'lab',
        'start_time': '10:00',
        'end_time': '11:00',
        'building': '1',
        'room': '2',
        'cycle_week': 2,
      });
      expect(item.toJson(), {
        'key': 'k',
        'title': 'T',
        'kind': 'lab',
        'start_time': '10:00',
        'end_time': '11:00',
        'building': '1',
        'room': '2',
        'cycle_week': 2,
      });

      final o = ClassOverride.fromRow(const {
        'id': 'o',
        'slot_id': 'p',
        'date': '2026-09-07',
        'action': 'move',
        'new_date': '2026-09-09',
        'lesson_kind': 'lab',
        'subject_id': 's',
        'title': 'T',
      });
      expect(o.action, OverrideAction.move);
      expect(o.lessonKind, LessonKind.lab);
      expect(o.toMutableFields()['new_date'], '2026-09-09');
      expect(ClassOverride.fromRow(const {}).lessonKind, isNull);

      final mark = AttendanceMark.fromRow(const {
        'id': 'a',
        'slot_id': 'p',
        'date': '2026-09-07',
        'status': 'cancelled',
        'note': 'н',
      });
      expect(mark.status, AttendanceStatus.cancelled);
      expect(AttendanceMark.fromRow(const {}).status, AttendanceStatus.present);

      expect(Bell.fromRow(const {'number': 1}).id, '');

      final file = Attachment.fromRow({
        'id': 'x',
        'debt_id': 'd',
        'file_name': 'f.jpg',
        'mime_type': 'image/jpeg',
        'size_bytes': 5,
        'sha256': 'b' * 64,
        'upload_status': 'uploaded',
      });
      expect(file.isImage, isTrue);
      expect(file.toFields()['upload_status'], 'uploaded');
      expect(Attachment.fromRow(const {'id': 'x'}).isImage, isFalse);
    });
  });

  group('аудитория и сетка звонков', () {
    test('format_room и parse_room: частные случаи', () {
      expect(formatRoom('1', '28'), 'к1 28');
      expect(formatRoom('1', null), 'к1');
      expect(formatRoom(null, 'Спортзал'), 'Спортзал');
      expect(formatRoom(null, null), '');
      expect(formatRoom('', ''), '');
      expect(parseRoom('к1 28'), const RoomParts('1', '28'));
      expect(parseRoom('  К2 101 '), const RoomParts('2', '101'));
      expect(parseRoom('1-28б'), const RoomParts('1', '28б'));
      expect(parseRoom('Спортзал'), const RoomParts(null, 'Спортзал'));
      expect(parseRoom('   '), isNull);
      expect(parseRoom('1' * 21), isNull);
      expect(const RoomParts('1', '2').toString(), contains('1'));
      expect(
        const RoomParts('1', '2').hashCode,
        const RoomParts('1', '2').hashCode,
      );
    });

    test('генератор: список перемен, ошибки', () {
      expect(generateBells('08:30', 45, [5, 5], 3)!.map((b) => b.endTime), [
        '09:15',
        '10:05',
        '10:55',
      ]);
      expect(generateBells('08:30', 45, 'x', 3), isNull);
      expect(generateBells('08:30', 45, [5], 3), isNull);
      expect(generateBells('08:30', 45, [5, 500], 3), isNull);
      expect(generateBells('25:00', 45, 5, 3), isNull);
      expect(generateBells('23:00', 90, 5, 1), isNull);
      expect(generateBells('08:30', 90, 5, 13), isNull);
      expect(isStudyTime('08:30'), isTrue);
      expect(isStudyTime('24:00'), isFalse);
      expect(isStudyTime(null), isFalse);
      expect(toMinutes('08:30'), 510);
      expect(fromMinutes(510), '08:30');
    });
  });

  group('праздники учёбы', () {
    test('только holiday и transfer_off; рабочая суббота не учитывается', () {
      final calendar = HolidayCalendar.fromJsonString('''
{"updated": "x", "years": {"2026": {"status": "official", "days": [
 {"date": "2026-11-04", "type": "holiday", "name": "День народного единства"},
 {"date": "2026-11-03", "type": "transfer_off", "name": "Перенос"},
 {"date": "2026-11-28", "type": "working_weekend", "name": "Рабочая суббота"}
]}}}''');
      expect(studyHolidays(calendar, '2026-11-01', '2026-11-30'), {
        '2026-11-03': 'Перенос',
        '2026-11-04': 'День народного единства',
      });
      expect(studyHolidays(calendar, '2026-11-04', '2026-11-04'), {
        '2026-11-04': 'День народного единства',
      });
      expect(studyHolidays(calendar, '2027-01-01', '2027-01-31'), isEmpty);
      expect(studyHolidays(calendar, 'x', 'y'), isEmpty);
    });
  });

  group('развёртка и посещаемость: дополнительные случаи', () {
    final input = ScheduleInput(
      semesters: [_semester()],
      subjects: const [
        Subject(id: 'm', semesterId: _sem, name: 'Матан', absenceLimit: 2),
      ],
      slots: const [
        ClassSlot(
          id: 'p',
          semesterId: _sem,
          weekday: 1,
          subjectId: 'm',
          number: 1,
          kind: LessonKind.lecture,
        ),
      ],
      bells: const [
        Bell(semesterId: _sem, number: 1, startTime: '08:30', endTime: '10:00'),
      ],
    );

    test('expandRange и дни вне семестра', () {
      final days = expandRange('2026-08-30', '2026-09-08', input);
      expect(days, hasLength(10));
      expect(days.first.kind, DayKind.noSemester);
      expect(days.first.toJson()['semester_id'], isNull);
      final monday = days.firstWhere((d) => d.date == '2026-09-07');
      expect(monday.lessons.single.start, '08:30');
      expect(monday.cycleWeek, 2);
      expect(monday.lessons.single.isSlot, isTrue);
    });

    test('состояния лимита', () {
      expect(attendanceState(0, null), AttendanceState.noLimit);
      expect(attendanceState(1, 4), AttendanceState.ok);
      expect(attendanceState(3, 4), AttendanceState.near);
      expect(attendanceState(4, 4), AttendanceState.reached);
      expect(attendanceState(5, 4), AttendanceState.over);
    });

    test('счётчики: отметка «отменена» и вне семестра', () {
      final summary = attendanceSummary('2026-09-14', input, const [
        AttendanceMark(
          slotId: 'p',
          date: '2026-09-07',
          status: AttendanceStatus.cancelled,
        ),
        AttendanceMark(
          slotId: 'p',
          date: '2026-09-14',
          status: AttendanceStatus.absent,
        ),
      ]).single;
      expect(summary.cancelled, 1);
      expect(summary.absent, 1);
      expect(summary.left, 1);
      expect(summary.state, AttendanceState.ok);
      expect(summary.toJson()['state'], 'ok');
      // До начала семестра занятий нет.
      final before = attendanceSummary('2026-08-01', input, const []).single;
      expect(before.unmarked, 0);
    });

    test('lesson.toJson отдаёт все поля', () {
      final lesson = expandDay('2026-09-07', input).lessons.single;
      expect(lesson.toJson().keys, hasLength(21));
      expect(lesson.isMovedAway, isFalse);
    });
  });

  group('подписи', () {
    test('дни, даты, размеры', () {
      expect(weekdayName(4), 'Четверг');
      expect(weekdayShort(1), 'Пн');
      expect(dateLabel('2026-09-17'), 'Чт, 17 сент.');
      expect(dateLabel('мусор'), 'мусор');
      expect(dateLong('2026-09-17'), '17 сентября');
      expect(dateLong('x'), 'x');
      expect(lessonTime('08:30', '10:00'), '08:30–10:00');
      expect(lessonTime('08:30', null), '08:30');
      expect(lessonTime(null, null), 'без времени');
      expect(absencesText(1), '1 пропуск');
      expect(absencesText(3), '3 пропуска');
      expect(absencesText(5), '5 пропусков');
      expect(debtsCountText(0), 'нет долгов');
      expect(debtsCountText(2), '2 долга');
      expect(formatFileSize(512), '512 Б');
      expect(formatFileSize(1536), '1,5 КБ');
      expect(formatFileSize(3 * 1024 * 1024), '3,0 МБ');
      expect(cycleWeekLabel(null, null), 'Каждая неделя');
      expect(cycleWeekLabel(null, 2), 'Неделя 2');
      expect(cycleWeekLabel(_semester(), 2), 'Чётная');
    });

    test('время из ввода', () {
      expect(normalizeTime('8:30'), '08:30');
      expect(normalizeTime('830'), '08:30');
      expect(normalizeTime(' 8.30 '), '08:30');
      expect(normalizeTime('25:00'), isNull);
      expect(normalizeTime('abc'), isNull);
      expect(normalizeTime(''), isNull);
    });

    test('лимит и срок долга', () {
      SubjectAttendance a(int absent, int? limit) => SubjectAttendance(
        subjectId: 's',
        present: 0,
        absent: absent,
        cancelled: 0,
        unmarked: 0,
        limit: limit,
        left: limit == null ? null : limit - absent,
        state: attendanceState(absent, limit),
      );
      expect(absencesLimitText(a(2, 4)), 'Пропуски 2 из 4');
      expect(absencesLimitText(a(2, null)), 'Пропуски 2');
      expect(limitStateText(a(0, null)), 'Лимит не задан');
      expect(limitStateText(a(1, 4)), 'Осталось 3');
      expect(limitStateText(a(3, 4)), contains('близко'));
      expect(limitStateText(a(4, 4)), 'Лимит исчерпан');
      expect(limitStateText(a(6, 4)), 'Лимит превышен на 2');
      const debt = StudyDebt(
        id: 'd',
        subjectId: 's',
        title: 'ЛР',
        dueDate: '2026-09-30',
      );
      expect(dueText(debt, '2026-09-20'), 'Срок Ср, 30 сент.');
      expect(dueText(debt, '2026-10-05'), 'Просрочено на 5 дней');
      expect(dueText(debt, '2026-10-01'), 'Просрочено на 1 день');
      expect(
        dueText(const StudyDebt(id: 'd', subjectId: 's', title: 'ЛР'), 'x'),
        '',
      );
    });
  });

  group('проверки значений', () {
    test('семестр', () {
      expect(semesterProblem(_semester()), isNull);
      expect(semesterProblem(_semester(name: ' ')), isNotNull);
      expect(semesterProblem(_semester(start: 'x')), contains('даты'));
      expect(
        semesterProblem(_semester(start: '2026-12-01', end: '2026-09-01')),
        contains('раньше'),
      );
      expect(
        semesterProblem(_semester(start: '2026-01-01', end: '2027-03-01')),
        contains('400'),
      );
      expect(semesterProblem(_semester(cycle: 9)), contains('Цикл'));
      expect(
        semesterProblem(
          _semester(
            shifts: [WeekShift(from: DateTime.utc(2026, 9, 7), weeks: 9)],
          ),
        ),
        contains('Сдвиг'),
      );
      expect(
        semesterProblem(
          _semester(
            shifts: [
              for (var i = 0; i < 31; i++)
                WeekShift(from: DateTime.utc(2026, 9, 7), weeks: 1),
            ],
          ),
        ),
        contains('Сдвигов'),
      );
    });

    test('предмет и аудитория', () {
      Subject s({
        String name = 'Физика',
        String? teacher,
        String? building,
        String? room,
        int? limit,
        String? note,
      }) => Subject(
        id: 's',
        semesterId: _sem,
        name: name,
        teacher: teacher,
        building: building,
        room: room,
        absenceLimit: limit,
        note: note,
      );
      expect(subjectProblem(s()), isNull);
      expect(subjectProblem(s(name: '')), isNotNull);
      expect(subjectProblem(s(teacher: 'я' * 201)), contains('ФИО'));
      expect(subjectProblem(s(building: 'к 1')), contains('Корпус'));
      expect(subjectProblem(s(room: 'я' * 21)), contains('Кабинет'));
      expect(subjectProblem(s(room: '')), contains('Кабинет'));
      expect(subjectProblem(s(limit: 0)), contains('Лимит'));
      expect(subjectProblem(s(limit: 1000)), contains('Лимит'));
      expect(subjectProblem(s(note: 'я' * 5001)), contains('Заметка'));
      expect(roomProblem('1', '28'), isNull);
    });

    test('звонок', () {
      expect(bellProblem(1, '08:30', '10:00'), isNull);
      expect(bellProblem(0, '08:30', '10:00'), isNotNull);
      expect(bellProblem(13, '08:30', '10:00'), isNotNull);
      expect(bellProblem(1, '08:30', '10:00', onDate: 'x'), isNotNull);
      expect(bellProblem(1, '8:30', '10:00'), contains('ЧЧ:ММ'));
      expect(bellProblem(1, '10:00', '10:00'), contains('позже'));
    });

    test('пара', () {
      ClassSlot s({
        String? subject = 's',
        String? title,
        int weekday = 1,
        int? number = 1,
        String? start,
        String? end,
        int? cycle,
        String? building,
        String? room,
      }) => ClassSlot(
        id: 'p',
        semesterId: _sem,
        subjectId: subject,
        title: title,
        weekday: weekday,
        number: number,
        startTime: start,
        endTime: end,
        kind: LessonKind.lecture,
        cycleWeek: cycle,
        building: building,
        room: room,
      );
      expect(slotProblem(s()), isNull);
      expect(slotProblem(s(subject: null)), contains('предмет'));
      expect(slotProblem(s(subject: null, title: ' ')), contains('предмет'));
      expect(slotProblem(s(title: ' ')), contains('пустым'));
      expect(slotProblem(s(title: 'я' * 201)), contains('200'));
      expect(slotProblem(s(weekday: 8)), contains('День'));
      expect(slotProblem(s(number: null)), contains('номер'));
      expect(slotProblem(s(number: 13)), contains('Номер'));
      expect(slotProblem(s(cycle: 9)), contains('Неделя'));
      expect(
        slotProblem(s(number: null, start: '10:00', end: '09:00')),
        contains('позже'),
      );
      expect(
        slotProblem(s(number: null, start: '10:00')),
        contains('и начало'),
      );
      expect(slotProblem(s(building: 'а б')), contains('Корпус'));
    });

    test('особый день', () {
      RuleItem item({
        String key = 'i1',
        String title = 'Занятие',
        int? number = 1,
        String? start,
        String? end,
        int? cycle,
      }) => RuleItem(
        key: key,
        title: title,
        kind: LessonKind.other,
        number: number,
        startTime: start,
        endTime: end,
        cycleWeek: cycle,
      );
      DayRule r({
        String title = 'Олимпиада',
        int? weekday = 4,
        String? date,
        int? cycle,
        List<RuleItem>? items,
      }) => DayRule(
        id: '',
        semesterId: _sem,
        title: title,
        weekday: weekday,
        onDate: date,
        cycleWeek: cycle,
        items: items ?? [item()],
      );
      expect(dayRuleProblem(r()), isNull);
      expect(dayRuleProblem(r(title: '')), isNotNull);
      expect(dayRuleProblem(r(weekday: null)), contains('день недели'));
      expect(dayRuleProblem(r(date: '2026-09-17')), contains('день недели'));
      expect(dayRuleProblem(r(weekday: 9)), contains('День'));
      expect(dayRuleProblem(r(weekday: null, date: 'x')), contains('Дата'));
      expect(
        dayRuleProblem(r(weekday: null, date: '2026-09-17', cycle: 1)),
        contains('только у правила'),
      );
      expect(dayRuleProblem(r(cycle: 9)), contains('Неделя'));
      expect(
        dayRuleProblem(
          r(items: [for (var i = 0; i < 13; i++) item(key: 'k$i')]),
        ),
        contains('не больше'),
      );
      expect(dayRuleProblem(r(items: [item(key: 'К')])), contains('Ключ'));
      expect(dayRuleProblem(r(items: [item(title: ' ')])), isNotNull);
      expect(dayRuleProblem(r(items: [item(number: 13)])), contains('Номер'));
      expect(dayRuleProblem(r(items: [item(cycle: 9)])), contains('Неделя'));
      expect(
        dayRuleProblem(r(items: [item(number: null)])),
        contains('нужен номер'),
      );
      expect(
        dayRuleProblem(
          r(
            items: [item(number: null, start: '10:00', end: '09:00')],
          ),
        ),
        contains('позже'),
      );
      expect(
        dayRuleProblem(r(items: [item(), item()])),
        contains('повторяться'),
      );
      expect(
        dayRuleProblem(
          r(
            items: [
              for (var i = 0; i < 12; i++) item(key: 'k$i', title: 'я' * 190),
            ],
          ),
        ),
        contains('Слишком много'),
      );
    });

    test('изменение на дату, отметка, долг', () {
      ClassOverride o({
        String date = '2026-09-07',
        OverrideAction action = OverrideAction.change,
        String? newDate,
        String? title,
        String? start,
        String? end,
      }) => ClassOverride(
        slotId: 'p',
        date: date,
        action: action,
        newDate: newDate,
        title: title,
        startTime: start,
        endTime: end,
      );
      expect(overrideProblem(o()), isNull);
      expect(overrideProblem(o(date: 'x')), isNotNull);
      expect(overrideProblem(o(action: OverrideAction.move)), contains('дату'));
      expect(
        overrideProblem(o(action: OverrideAction.move, newDate: '2026-09-07')),
        contains('другую'),
      );
      expect(
        overrideProblem(o(action: OverrideAction.move, newDate: '2026-09-09')),
        isNull,
      );
      expect(overrideProblem(o(newDate: '2026-09-09')), isNotNull);
      expect(overrideProblem(o(title: ' ')), contains('пустым'));
      expect(overrideProblem(o(title: 'я' * 201)), contains('200'));
      expect(overrideProblem(o(start: '10:00')), contains('и начало'));
      expect(attendanceProblem('2026-09-07', null), isNull);
      expect(attendanceProblem('x', null), isNotNull);
      expect(attendanceProblem('2026-09-07', 'я' * 501), contains('500'));
      expect(
        debtProblem(const StudyDebt(id: 'd', subjectId: 's', title: 'ЛР')),
        isNull,
      );
      expect(
        debtProblem(const StudyDebt(id: 'd', subjectId: 's', title: ' ')),
        isNotNull,
      );
      expect(
        debtProblem(
          const StudyDebt(id: 'd', subjectId: 's', title: 'ЛР', dueDate: 'x'),
        ),
        contains('Срок'),
      );
      expect(
        debtProblem(
          const StudyDebt(id: 'd', subjectId: 's', title: 'ЛР', doneDate: 'x'),
        ),
        contains('Дата сдачи'),
      );
      expect(
        debtProblem(
          StudyDebt(id: 'd', subjectId: 's', title: 'ЛР', note: 'я' * 5001),
        ),
        contains('Заметка'),
      );
    });

    test('вложения', () {
      expect(attachmentProblem(_file()), isNull);
      expect(attachmentProblem(_file(subject: null)), contains('предмету'));
      expect(attachmentProblem(_file(debt: 'd')), contains('предмету'));
      expect(attachmentProblem(_file(subject: null, debt: 'd')), isNull);
      expect(attachmentProblem(_file(name: 'a/b.pdf')), contains('имени'));
      expect(attachmentProblem(_file(name: ' ')), contains('пустое'));
      expect(
        attachmentProblem(_file(mime: 'application/x-exe')),
        contains('тип'),
      );
      expect(attachmentProblem(_file(name: 'a.png')), contains('Расширение'));
      expect(attachmentProblem(_file(size: 0)), contains('пустой'));
      expect(attachmentProblem(_file(size: maxFileBytes + 1)), contains('25'));
      expect(attachmentProblem(_file(sha: 'ABC')), contains('SHA'));
      expect(fileNameProblem('..'), isNotNull);
      expect(fileNameProblem('я' * 256), contains('255'));
      expect(fileNameProblem('a\u0001b'), contains('/'));
      expect(fileNameProblem(r'a\b'), contains('/'));
      expect(fileNameProblem('Отчёт.docx'), isNull);
      expect(fileExtension('Фото.JPG'), '.jpg');
      expect(fileExtension('без'), '');
      expect(mimeTypeOf('a.JPG'), 'image/jpeg');
      expect(mimeTypeOf('a.heic'), 'image/heic');
      expect(mimeTypeOf('a.heif'), 'image/heic');
      expect(mimeTypeOf('a.docx'), startsWith('application/vnd'));
      expect(mimeTypeOf('a.exe'), isNull);
      expect(mimeTypeOf('a'), isNull);
    });

    test('размер JSON как у сервера', () {
      expect(serverJsonBytes('аб'), 2 + 12);
      expect(serverJsonBytes([1]), 3);
    });
  });
}
