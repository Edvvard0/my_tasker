import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/ids.dart' show isUuid7;
import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_table.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/study/data/study_sync_specs.dart';
import 'package:my_tasker/features/study/domain/study_ids.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';
import '../../support/study_env.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Таблицы Учёбы через общий стек синхронизации и фейковый сервер:
/// реестр, детерминированные id, неизменяемые поля, два устройства,
/// каскады видимости.
void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late StudyDevice phone;
  late StudyDevice pc;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    String next() => _uuid(7000 + ++counter);
    phone = await StudyDevice.create(server, clock: clock, newId: next);
    pc = await StudyDevice.create(server, clock: clock, newId: next);
  });
  tearDown(() async {
    await phone.close();
    await pc.close();
    await server.dispose();
  });

  Future<void> syncBoth() async {
    for (var i = 0; i < 3; i++) {
      expect(await phone.device.sync(), SyncOutcome.success);
      expect(await pc.device.sync(), SyncOutcome.success);
    }
    expect((await phone.device.store.outboxSummary()).rejected, 0);
    expect((await pc.device.store.outboxSummary()).rejected, 0);
  }

  Future<String> semester(StudyDevice d) async {
    final id = d.study.newId();
    await d.study.createSemester(
      Semester(
        id: id,
        name: 'Осень 2026',
        startDate: '2026-09-01',
        endDate: '2026-12-31',
        week1Start: '2026-08-31',
      ),
    );
    return id;
  }

  Future<String> subject(
    StudyDevice d,
    String sem, {
    String name = 'Физика',
  }) async {
    final id = d.study.newId();
    await d.study.createSubject(
      Subject(id: id, semesterId: sem, name: name, absenceLimit: 3),
    );
    return id;
  }

  Future<String> slot(StudyDevice d, String sem, String subj) async {
    final id = d.study.newId();
    await d.study.createSlot(
      ClassSlot(
        id: id,
        semesterId: sem,
        subjectId: subj,
        weekday: 1,
        number: 1,
        kind: LessonKind.lecture,
      ),
    );
    return id;
  }

  group('реестр', () {
    test('девять таблиц Этапа 7: порядок, родители, неизменяемые поля', () {
      final names = [for (final s in studySyncSpecs) s.name];
      expect(names, [
        'study_semesters',
        'study_subjects',
        'study_bells',
        'class_slots',
        'study_day_rules',
        'class_overrides',
        'study_attendance',
        'study_debts',
        'attachments',
      ]);
      final all = [for (final s in registeredSyncTables) s.name];
      for (final n in names) {
        expect(all, contains(n));
      }
      SyncRegistry(registeredSyncTables);
      Set<String> immutable(SyncTableSpec s) => {
        for (final c in s.columns)
          if (c.immutable) c.name,
      };
      expect(immutable(studySubjectsSpec), {'semester_id'});
      expect(immutable(studyBellsSpec), {'semester_id', 'on_date', 'number'});
      expect(immutable(classSlotsSpec), {'semester_id'});
      expect(immutable(studyDayRulesSpec), {
        'semester_id',
        'weekday',
        'on_date',
        'cycle_week',
      });
      expect(immutable(classOverridesSpec), {'slot_id', 'date'});
      expect(immutable(studyAttendanceSpec), {'slot_id', 'date'});
      expect(immutable(studyDebtsSpec), {'subject_id'});
      expect(immutable(attachmentsSpec), {
        'subject_id',
        'debt_id',
        'mime_type',
        'size_bytes',
        'sha256',
      });
      expect(immutable(studySemestersSpec), isEmpty);
      expect(
        [for (final r in classSlotsSpec.parents) r.parentTable],
        ['study_semesters', 'study_subjects'],
      );
      expect(
        [for (final r in attachmentsSpec.parents) r.parentTable],
        ['study_subjects', 'study_debts'],
      );
      expect(studyDebtsSpec.column('task_id')!.nullable, isTrue);
      expect(classOverridesSpec.column('subject_id')!.nullable, isTrue);
    });

    test('заголовки строк в корзине', () {
      expect(studySemestersSpec.titleOf({'name': 'Осень'}), 'Осень');
      expect(studySubjectsSpec.titleOf({'name': 'Физика'}), 'Физика');
      expect(
        studyBellsSpec.titleOf({'number': 2, 'on_date': null}),
        'Звонок 2',
      );
      expect(
        studyBellsSpec.titleOf({'number': 2, 'on_date': '2026-09-14'}),
        'Звонок 2 на 2026-09-14',
      );
      expect(classSlotsSpec.titleOf({'title': 'Кружок'}), 'Кружок');
      expect(classSlotsSpec.titleOf({'title': null}), 'Пара');
      expect(studyDayRulesSpec.titleOf({'title': 'Олимпиада'}), 'Олимпиада');
      expect(
        classOverridesSpec.titleOf({'date': '2026-09-07'}),
        contains('2026-09-07'),
      );
      expect(
        studyAttendanceSpec.titleOf({'date': '2026-09-07'}),
        contains('2026-09-07'),
      );
      expect(studyDebtsSpec.titleOf({'title': 'ЛР 3'}), 'ЛР 3');
      expect(attachmentsSpec.titleOf({'file_name': 'a.pdf'}), 'a.pdf');
    });
  });

  group('круг синхронизации двух устройств', () {
    test(
      'всё созданное на телефоне доезжает до ПК; id детерминированы',
      () async {
        final sem = await semester(phone);
        final subj = await subject(phone, sem);
        await phone.study.replaceBells(
          semesterId: sem,
          grid: generateBells('08:30', 90, 10, 3)!,
        );
        final slotId = await slot(phone, sem, subj);
        final ruleId = await phone.study.saveDayRule(
          sem,
          const DayRule(
            id: '',
            semesterId: '',
            weekday: 4,
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
          ),
        );
        await phone.study.saveOverride(
          ClassOverride(
            slotId: slotId,
            date: '2026-09-07',
            action: OverrideAction.cancel,
          ),
        );
        await phone.study.mark(slotId, '2026-09-14', AttendanceStatus.absent);
        final debtId = phone.study.newId();
        await phone.study.createDebt(
          StudyDebt(id: debtId, subjectId: subj, title: 'ЛР 1'),
        );
        final file = await phone.attachments.add(
          fileName: 'Методичка.pdf',
          bytes: fakePdf(),
          subjectId: subj,
        );
        await syncBoth();

        expect(ruleId, dayRuleId(sem, weekday: 4));
        expect(server.row('study_bells', bellId(sem, null, 1)), isNotNull);
        expect(
          server.row('class_overrides', overrideId(slotId, '2026-09-07')),
          isNotNull,
        );
        expect(
          server.row('study_attendance', attendanceId(slotId, '2026-09-14')),
          isNotNull,
        );
        for (final (table, id) in [
          ('study_semesters', sem),
          ('study_subjects', subj),
          ('class_slots', slotId),
          ('study_day_rules', ruleId),
          ('study_debts', debtId),
          ('attachments', file.id),
        ]) {
          expect(server.row(table, id), isNotNull, reason: table);
          expect(await pc.device.store.getRow(table, id), isNotNull);
        }
        final bells = await pc.device.store.visibleRows('study_bells');
        expect(bells, hasLength(3));
        final marks = await pc.device.store.visibleRows('study_attendance');
        expect(marks.single['status'], 'absent');
      },
    );

    test(
      'два устройства, отметившие одно и то же офлайн, дают одну строку',
      () async {
        final sem = await semester(phone);
        final subj = await subject(phone, sem);
        final slotId = await slot(phone, sem, subj);
        await syncBoth();

        await phone.study.mark(slotId, '2026-09-14', AttendanceStatus.present);
        clock.advance(const Duration(seconds: 5));
        await pc.study.mark(slotId, '2026-09-14', AttendanceStatus.absent);
        await phone.study.saveOverride(
          ClassOverride(
            slotId: slotId,
            date: '2026-09-14',
            action: OverrideAction.cancel,
          ),
        );
        await pc.study.saveOverride(
          ClassOverride(
            slotId: slotId,
            date: '2026-09-14',
            action: OverrideAction.change,
            title: 'Другое',
          ),
        );
        await phone.study.saveBell(
          semesterId: sem,
          number: 1,
          startTime: '08:30',
          endTime: '10:00',
        );
        await pc.study.saveBell(
          semesterId: sem,
          number: 1,
          startTime: '08:40',
          endTime: '10:10',
        );
        await syncBoth();
        for (final dev in [phone, pc]) {
          final marks = await dev.device.store.visibleRows('study_attendance');
          expect(marks, hasLength(1));
          expect(marks.single['id'], attendanceId(slotId, '2026-09-14'));
          expect(
            await dev.device.store.visibleRows('class_overrides'),
            hasLength(1),
          );
          expect(
            await dev.device.store.visibleRows('study_bells'),
            hasLength(1),
          );
        }
        expect(
          (await phone.device.store.visibleRows('study_attendance')).single,
          (await pc.device.store.visibleRows('study_attendance')).single,
        );
        // Победила последняя запись: пропуск ПК.
        expect(
          (await phone.device.store.visibleRows('study_attendance'))
              .single['status'],
          'absent',
        );
      },
    );

    test('удаление семестра скрывает всё ниже на втором устройстве', () async {
      final sem = await semester(phone);
      final subj = await subject(phone, sem);
      final slotId = await slot(phone, sem, subj);
      await phone.study.mark(slotId, '2026-09-14', AttendanceStatus.present);
      final debtId = phone.study.newId();
      await phone.study.createDebt(
        StudyDebt(id: debtId, subjectId: subj, title: 'ЛР 1'),
      );
      await phone.attachments.add(
        fileName: 'a.pdf',
        bytes: fakePdf(),
        debtId: debtId,
      );
      await syncBoth();
      expect(await pc.device.store.visibleRows('study_debts'), hasLength(1));

      await phone.study.deleteSemester(sem);
      await syncBoth();
      for (final table in [
        'study_semesters',
        'study_subjects',
        'class_slots',
        'study_attendance',
        'study_debts',
        'attachments',
      ]) {
        expect(
          await pc.device.store.visibleRows(table),
          isEmpty,
          reason: table,
        );
      }

      await phone.study.restoreSemester(sem);
      await syncBoth();
      expect(await pc.device.store.visibleRows('study_debts'), hasLength(1));
      expect(await pc.device.store.visibleRows('attachments'), hasLength(1));
    });

    test(
      '«создать задачу» по долгу: задача синхронизируется, ссылка у долга',
      () async {
        final sem = await semester(phone);
        final subj = await subject(phone, sem, name: 'Математика');
        final debtId = phone.study.newId();
        await phone.study.createDebt(
          StudyDebt(
            id: debtId,
            subjectId: subj,
            title: 'ЛР 2',
            dueDate: '2026-10-12',
          ),
        );
        final taskId = await phone.study.createTaskForDebt(
          debtId,
          subjectName: 'Математика',
        );
        // Повтор не создаёт вторую задачу.
        expect(
          await phone.study.createTaskForDebt(
            debtId,
            subjectName: 'Математика',
          ),
          taskId,
        );
        await syncBoth();
        final tasks = await pc.device.store.visibleRows('tasks');
        expect(tasks, hasLength(1));
        expect(tasks.single['id'], taskId);
        expect(tasks.single['title'], 'ЛР 2 · Математика');
        expect(tasks.single['due_date'], '2026-10-12');
        expect(tasks.single['status'], 'todo');
        expect(tasks.single['notes'], contains('Математика'));
        expect((await pc.study.getDebt(debtId))!.taskId, taskId);

        // Задачу удалили: следующее нажатие восстанавливает ту же задачу.
        await phone.device.store.softDelete('tasks', taskId);
        final again = await phone.study.createTaskForDebt(
          debtId,
          subjectName: 'Математика',
        );
        expect(again, taskId);
        final task = TaskEntity.fromRow(
          (await phone.device.store.getRow('tasks', again))!,
        );
        expect(task.due.isNone, isFalse);
        expect(
          (await phone.device.store.getRow('tasks', taskId))!['deleted_at'],
          isNull,
        );
        // Долг без срока — задача без срока.
        final other = phone.study.newId();
        await phone.study.createDebt(
          StudyDebt(id: other, subjectId: subj, title: 'ЛР 3'),
        );
        final t2 = await phone.study.createTaskForDebt(
          other,
          subjectName: 'Математика',
        );
        expect(
          TaskEntity.fromRow((await phone.device.store.getRow('tasks', t2))!)
              .due
              .isNone,
          isTrue,
        );
        await expectLater(
          phone.study.createTaskForDebt('нет', subjectName: 'x'),
          throwsStateError,
        );
      },
    );
  });

  group('корзина', () {
    test('служебные удаления (отметка, звонок, изменение) в общую корзину не '
        'попадают; предмет и долг — попадают; повторная запись возвращает '
        'строку', () async {
      final sem = await semester(phone);
      final subj = await subject(phone, sem);
      final sl = await slot(phone, sem, subj);
      await phone.study.saveBell(
        semesterId: sem,
        number: 1,
        startTime: '08:30',
        endTime: '10:00',
      );
      await phone.study.mark(sl, '2026-09-07', AttendanceStatus.absent);
      await phone.study.saveOverride(
        ClassOverride(
          slotId: sl,
          date: '2026-09-14',
          action: OverrideAction.cancel,
        ),
      );
      await phone.study.unmark(sl, '2026-09-07');
      await phone.study.clearOverride(sl, '2026-09-14');
      await phone.study.deleteBell(semesterId: sem, number: 1);
      final debt = phone.study.newId();
      await phone.study.createDebt(
        StudyDebt(id: debt, subjectId: subj, title: 'ЛР 1'),
      );
      await phone.study.deleteDebt(debt);
      final titles = [
        for (final i in await phone.device.store.trashItems()) i.table,
      ];
      expect(titles, ['study_debts']);
      // Отметка возвращается обычной записью (естественный ключ).
      await phone.study.mark(sl, '2026-09-07', AttendanceStatus.present);
      expect(
        await phone.device.store.visibleRows('study_attendance'),
        hasLength(1),
      );
    });
  });

  group('задача по долгу на двух устройствах', () {
    test('«Создать задачу» офлайн на обоих: после синхронизации одна задача, '
        'id детерминированный и годится для сервера (UUIDv7)', () async {
      final sem = await semester(phone);
      final subj = await subject(phone, sem, name: 'Математика');
      final debtId = phone.study.newId();
      await phone.study.createDebt(
        StudyDebt(
          id: debtId,
          subjectId: subj,
          title: 'ЛР 2',
          dueDate: '2026-10-12',
        ),
      );
      await syncBoth();
      // Оба устройства офлайн нажимают «Создать задачу».
      final onPhone = await phone.study.createTaskForDebt(
        debtId,
        subjectName: 'Математика',
      );
      final onPc = await pc.study.createTaskForDebt(
        debtId,
        subjectName: 'Математика',
      );
      expect(onPhone, onPc);
      expect(onPhone, debtTaskId(debtId));
      expect(isUuid7(onPhone), isTrue);
      await syncBoth();
      for (final d in [phone, pc]) {
        final tasks = await d.device.store.visibleRows('tasks');
        expect(tasks, hasLength(1));
        expect(tasks.single['id'], onPhone);
        expect((await d.study.getDebt(debtId))!.taskId, onPhone);
      }
      expect(server.row('tasks', onPhone)!['deleted_at'], isNull);
    });

    test('идентификатор зависит от долга и не меняется', () {
      expect(debtTaskId('a'), debtTaskId('a'));
      expect(debtTaskId('a'), isNot(debtTaskId('b')));
    });
  });

  group('репозиторий', () {
    test(
      'семестр: создание, правка, архив, удаление; ошибки проверок',
      () async {
        final id = await semester(phone);
        await phone.study.updateSemester(
          (await phone.study.getSemester(id))!.copyWith(name: ' Весна '),
        );
        expect((await phone.study.getSemester(id))!.name, 'Весна');
        await phone.study.setSemesterArchived(id, archived: true);
        expect((await phone.study.getSemester(id))!.archived, isTrue);
        // Повторная установка того же значения ничего не пишет.
        final pending = (await phone.device.store.outboxSummary()).pending;
        await phone.study.setSemesterArchived(id, archived: true);
        expect((await phone.device.store.outboxSummary()).pending, pending);
        await phone.study.setSemesterArchived('нет', archived: true);
        await expectLater(
          phone.study.createSemester(
            Semester(
              id: _uuid(1),
              name: '',
              startDate: '2026-09-01',
              endDate: '2026-12-31',
              week1Start: '2026-08-31',
            ),
          ),
          throwsA(isA<ValidationError>()),
        );
        await expectLater(
          phone.study.updateSemester(
            Semester(
              id: _uuid(404),
              name: 'x',
              startDate: '2026-09-01',
              endDate: '2026-12-31',
              week1Start: '2026-08-31',
            ),
          ),
          throwsStateError,
        );
        await phone.study.deleteSemester(id);
        expect(
          await phone.device.store.visibleRows('study_semesters'),
          isEmpty,
        );
      },
    );

    test(
      'предмет: пробелы обрезаются, архив, удаление и восстановление',
      () async {
        final sem = await semester(phone);
        final id = phone.study.newId();
        await phone.study.createSubject(
          Subject(
            id: id,
            semesterId: sem,
            name: '  Физика ',
            teacher: '  ',
            room: '101',
            building: '2',
          ),
        );
        final s = (await phone.study.getSubject(id))!;
        expect(s.name, 'Физика');
        expect(s.teacher, isNull);
        await phone.study.updateSubject(s.copyWith(teacher: 'Петрова'));
        expect((await phone.study.getSubject(id))!.teacher, 'Петрова');
        await phone.study.setSubjectArchived(id, archived: true);
        expect((await phone.study.getSubject(id))!.archived, isTrue);
        await phone.study.setSubjectArchived('нет', archived: true);
        await phone.study.deleteSubject(id);
        await phone.study.restoreSubject(id);
        expect(
          await phone.device.store.visibleRows('study_subjects'),
          hasLength(1),
        );
        await expectLater(
          phone.study.createSubject(
            Subject(id: _uuid(2), semesterId: sem, name: ' '),
          ),
          throwsA(isA<ValidationError>()),
        );
        await expectLater(
          phone.study.updateSubject(
            Subject(id: _uuid(404), semesterId: sem, name: 'x'),
          ),
          throwsStateError,
        );
      },
    );

    test('звонки: замена сетки, звонки на дату, удаление', () async {
      final sem = await semester(phone);
      await phone.study.replaceBells(
        semesterId: sem,
        grid: generateBells('08:30', 90, 10, 4)!,
      );
      expect(await phone.device.store.visibleRows('study_bells'), hasLength(4));
      // Сетка короче: лишние номера удаляются, остальные правятся.
      await phone.study.replaceBells(
        semesterId: sem,
        grid: generateBells('09:00', 90, 10, 2)!,
      );
      final rows = await phone.device.store.visibleRows(
        'study_bells',
        orderBy: 't.number',
      );
      expect([for (final r in rows) r['start_time']], ['09:00', '10:40']);
      // Звонки на дату не трогают обычные.
      await phone.study.replaceBells(
        semesterId: sem,
        grid: [
          const Bell(
            semesterId: '',
            number: 1,
            startTime: '07:50',
            endTime: '09:20',
          ),
        ],
        onDate: '2026-09-14',
      );
      expect(await phone.device.store.visibleRows('study_bells'), hasLength(3));
      await phone.study.clearDateBells(sem, '2026-09-14');
      expect(await phone.device.store.visibleRows('study_bells'), hasLength(2));
      // Удалённый звонок восстанавливается записью того же номера.
      await phone.study.deleteBell(semesterId: sem, number: 2);
      expect(await phone.device.store.visibleRows('study_bells'), hasLength(1));
      await phone.study.saveBell(
        semesterId: sem,
        number: 2,
        startTime: '10:50',
        endTime: '12:20',
      );
      expect(await phone.device.store.visibleRows('study_bells'), hasLength(2));
      await phone.study.deleteBell(semesterId: sem, number: 9);
      await expectLater(
        phone.study.saveBell(
          semesterId: sem,
          number: 1,
          startTime: '10:00',
          endTime: '09:00',
        ),
        throwsA(isA<ValidationError>()),
      );
    });

    test('особый день: сохранение, правка названия, удаление', () async {
      final sem = await semester(phone);
      const rule = DayRule(
        id: '',
        semesterId: '',
        weekday: 4,
        title: 'Олимпиада',
        hideRegular: true,
      );
      final id = await phone.study.saveDayRule(sem, rule);
      final again = await phone.study.saveDayRule(
        sem,
        const DayRule(
          id: '',
          semesterId: '',
          weekday: 4,
          title: 'Олимпиада 2',
          items: [
            RuleItem(key: 'a', title: 'T', kind: LessonKind.lab, number: 2),
          ],
        ),
      );
      expect(again, id);
      final row = (await phone.device.store.getRow('study_day_rules', id))!;
      expect(row['title'], 'Олимпиада 2');
      expect(row['hide_regular'], isFalse);
      await phone.study.deleteDayRule(id);
      expect(await phone.device.store.visibleRows('study_day_rules'), isEmpty);
      await phone.study.restoreDayRule(id);
      expect(
        await phone.device.store.visibleRows('study_day_rules'),
        hasLength(1),
      );
      // Правило на дату — своя строка.
      final dated = await phone.study.saveDayRule(
        sem,
        const DayRule(
          id: '',
          semesterId: '',
          onDate: '2026-09-17',
          title: 'Экскурсия',
        ),
      );
      expect(dated, dayRuleId(sem, onDate: '2026-09-17'));
      await expectLater(
        phone.study.saveDayRule(
          sem,
          const DayRule(id: '', semesterId: '', title: 'Без области'),
        ),
        throwsA(isA<ValidationError>()),
      );
    });

    test('изменение на дату: отмена очищает поля; сброс', () async {
      final sem = await semester(phone);
      final subj = await subject(phone, sem);
      final slotId = await slot(phone, sem, subj);
      final id = await phone.study.saveOverride(
        ClassOverride(
          slotId: slotId,
          date: '2026-09-14',
          action: OverrideAction.change,
          startTime: '14:00',
          endTime: '15:30',
          room: '5',
          building: '1',
          title: ' Другое ',
          lessonKind: LessonKind.lab,
        ),
      );
      var row = (await phone.device.store.getRow('class_overrides', id))!;
      expect(row['title'], 'Другое');
      expect(row['building'], '1');
      await phone.study.saveOverride(
        ClassOverride(
          slotId: slotId,
          date: '2026-09-14',
          action: OverrideAction.cancel,
          title: 'игнорируется',
          startTime: '10:00',
          endTime: '11:00',
        ),
      );
      row = (await phone.device.store.getRow('class_overrides', id))!;
      expect(row['action'], 'cancel');
      expect(row['title'], isNull);
      expect(row['start_time'], isNull);
      // Перенос.
      await phone.study.saveOverride(
        ClassOverride(
          slotId: slotId,
          date: '2026-09-14',
          action: OverrideAction.move,
          newDate: '2026-09-16',
        ),
      );
      row = (await phone.device.store.getRow('class_overrides', id))!;
      expect(row['new_date'], '2026-09-16');
      await phone.study.clearOverride(slotId, '2026-09-14');
      expect(await phone.device.store.visibleRows('class_overrides'), isEmpty);
      await phone.study.clearOverride(slotId, '2026-09-20');
      // Повторная запись восстанавливает строку.
      await phone.study.saveOverride(
        ClassOverride(
          slotId: slotId,
          date: '2026-09-14',
          action: OverrideAction.cancel,
        ),
      );
      expect(
        await phone.device.store.visibleRows('class_overrides'),
        hasLength(1),
      );
      await expectLater(
        phone.study.saveOverride(
          ClassOverride(
            slotId: slotId,
            date: '2026-09-14',
            action: OverrideAction.move,
          ),
        ),
        throwsA(isA<ValidationError>()),
      );
    });

    test('посещаемость: отметка, смена, снятие, повтор', () async {
      final sem = await semester(phone);
      final subj = await subject(phone, sem);
      final slotId = await slot(phone, sem, subj);
      final id = await phone.study.mark(
        slotId,
        '2026-09-14',
        AttendanceStatus.absent,
        note: ' болел ',
      );
      var row = (await phone.device.store.getRow('study_attendance', id))!;
      expect(row['note'], 'болел');
      await phone.study.mark(slotId, '2026-09-14', AttendanceStatus.present);
      row = (await phone.device.store.getRow('study_attendance', id))!;
      expect(row['status'], 'present');
      expect(row['note'], isNull);
      await phone.study.unmark(slotId, '2026-09-14');
      expect(await phone.device.store.visibleRows('study_attendance'), isEmpty);
      await phone.study.unmark(slotId, '2026-09-20');
      await phone.study.mark(slotId, '2026-09-14', AttendanceStatus.cancelled);
      expect(
        await phone.device.store.visibleRows('study_attendance'),
        hasLength(1),
      );
      await expectLater(
        phone.study.mark(slotId, 'x', AttendanceStatus.present),
        throwsA(isA<ValidationError>()),
      );
    });

    test('пара: правка, удаление и восстановление; ошибки', () async {
      final sem = await semester(phone);
      final subj = await subject(phone, sem);
      final id = await slot(phone, sem, subj);
      final s = (await phone.study.getSlot(id))!;
      await phone.study.updateSlot(s.copyWith(room: ' 5 ', building: '1'));
      expect((await phone.study.getSlot(id))!.room, '5');
      await phone.study.deleteSlot(id);
      await phone.study.restoreSlot(id);
      expect(await phone.device.store.visibleRows('class_slots'), hasLength(1));
      await expectLater(
        phone.study.createSlot(
          ClassSlot(
            id: _uuid(3),
            semesterId: sem,
            weekday: 1,
            number: 1,
            kind: LessonKind.lecture,
          ),
        ),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        phone.study.updateSlot(
          ClassSlot(
            id: _uuid(404),
            semesterId: sem,
            subjectId: subj,
            weekday: 1,
            number: 1,
            kind: LessonKind.lecture,
          ),
        ),
        throwsStateError,
      );
    });

    test(
      'долг: статус ставит дату сдачи, возврат снимает; правка и удаление',
      () async {
        final sem = await semester(phone);
        final subj = await subject(phone, sem);
        final id = phone.study.newId();
        await phone.study.createDebt(
          StudyDebt(id: id, subjectId: subj, title: ' ЛР 1 ', note: ' '),
        );
        var debt = (await phone.study.getDebt(id))!;
        expect(debt.title, 'ЛР 1');
        expect(debt.note, isNull);
        await phone.study.setDebtStatus(
          id,
          DebtStatus.submitted,
          today: '2026-10-05',
        );
        debt = (await phone.study.getDebt(id))!;
        expect(debt.status, DebtStatus.submitted);
        expect(debt.doneDate, '2026-10-05');
        await phone.study.setDebtStatus(
          id,
          DebtStatus.credited,
          today: '2026-10-06',
        );
        expect((await phone.study.getDebt(id))!.doneDate, '2026-10-05');
        await phone.study.setDebtStatus(id, DebtStatus.open);
        expect((await phone.study.getDebt(id))!.doneDate, isNull);
        // Без даты — берётся «сегодня» часов репозитория.
        await phone.study.setDebtStatus(id, DebtStatus.submitted);
        expect((await phone.study.getDebt(id))!.doneDate, '2026-10-05');
        await phone.study.setDebtStatus('нет', DebtStatus.submitted);
        await phone.study.updateDebt(debt.copyWith(title: 'ЛР 1 (новая)'));
        expect((await phone.study.getDebt(id))!.title, 'ЛР 1 (новая)');
        await phone.study.deleteDebt(id);
        await phone.study.restoreDebt(id);
        expect(
          await phone.device.store.visibleRows('study_debts'),
          hasLength(1),
        );
        await expectLater(
          phone.study.createDebt(
            StudyDebt(id: _uuid(4), subjectId: subj, title: ' '),
          ),
          throwsA(isA<ValidationError>()),
        );
        await expectLater(
          phone.study.updateDebt(
            StudyDebt(id: _uuid(404), subjectId: subj, title: 'x'),
          ),
          throwsStateError,
        );
      },
    );

    test('вложение: метаданные, переименование, удаление', () async {
      final sem = await semester(phone);
      final subj = await subject(phone, sem);
      final file = await phone.attachments.add(
        fileName: 'a.pdf',
        bytes: fakePdf(),
        subjectId: subj,
      );
      expect(file.mimeType, 'application/pdf');
      expect(file.uploadStatus, UploadStatus.pending);
      expect(await phone.study.pendingUploads(), hasLength(1));
      expect(await phone.study.isSynced(file.id), isFalse);
      await phone.study.renameAttachment(file.id, ' Лекции.pdf ');
      expect(
        (await phone.study.getAttachment(file.id))!.fileName,
        'Лекции.pdf',
      );
      await expectLater(
        phone.study.renameAttachment(file.id, 'лекции.docx'),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        phone.study.renameAttachment(file.id, 'a/b.pdf'),
        throwsA(isA<ValidationError>()),
      );
      await phone.study.renameAttachment('нет', 'x.pdf');
      await phone.study.markUploaded(file.id);
      await phone.study.markUploaded(file.id);
      await phone.study.markUploaded('нет');
      expect(await phone.study.pendingUploads(), isEmpty);
      await phone.study.deleteAttachment(file.id);
      await phone.study.restoreAttachment(file.id);
      expect(await phone.device.store.visibleRows('attachments'), hasLength(1));
      await phone.device.sync();
      expect(await phone.study.isSynced(file.id), isTrue);
      await expectLater(
        phone.study.createAttachment(
          const Attachment(
            id: 'z',
            fileName: 'a.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1,
            sha256: 'bad',
            subjectId: 's',
          ),
        ),
        throwsA(isA<ValidationError>()),
      );
    });
  });
}
