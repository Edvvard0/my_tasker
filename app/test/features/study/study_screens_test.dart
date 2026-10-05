import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';

import '../../support/study_env.dart';

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(
    find
        .descendant(of: find.byKey(Key(key)), matching: find.byType(TextField))
        .first,
    text,
  );
}

void main() {
  group('обзор «Учёбы»', () {
    testWidgets('нет семестра: пустое состояние; добавление семестра и звонки '
        'по умолчанию', (tester) async {
      final container = await pumpStudy(tester);
      expect(find.byKey(const Key('study-empty')), findsOneWidget);
      await tapKey(tester, 'study-empty-add');
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('semester-name')),
          matching: find.byType(TextField),
        ),
        'Осень 2026',
      );
      await tapKey(tester, 'semester-save');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('study-empty')), findsNothing);
      final data = container.read(studyDataProvider).requireValue;
      expect(data.semesters.single.name, 'Осень 2026');
      expect(data.bells, hasLength(6));
      expect(data.bells.first.startTime, '08:30');
      expect(find.byKey(const Key('kpi-week')), findsOneWidget);
    });

    testWidgets('плитки: пропуски, долги, неделя; сегодняшние занятия', (
      tester,
    ) async {
      await pumpStudy(tester, seed: true);
      expect(find.byKey(const Key('study-overview')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('kpi-absences')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(find.text('лимиты в порядке'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('kpi-debts')),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
      expect(find.text('просрочено 1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('kpi-week')),
          matching: find.text('Чётная'),
        ),
        findsOneWidget,
      );
      // Понедельник, чётная неделя: лекция по матану; лаба — по нечётным.
      expect(find.text('Математический анализ'), findsOneWidget);
      expect(find.text('Физика'), findsNothing);
      expect(find.textContaining('к1 28'), findsOneWidget);
    });

    testWidgets('четверг: особый день, обычные пары скрыты', (tester) async {
      await pumpStudy(tester, seed: true, now: DateTime.utc(2026, 10, 8, 9));
      expect(find.text('Особый день'.toUpperCase()), findsOneWidget);
      expect(find.text('Подготовка к олимпиаде'), findsNWidgets(4));
      expect(find.text('Математический анализ'), findsNothing);
    });

    testWidgets('праздник и вне семестра', (tester) async {
      await pumpStudy(tester, seed: true, now: DateTime.utc(2026, 12, 31, 9));
      expect(find.text('Праздник: занятий нет.'), findsOneWidget);
    });

    testWidgets('вне семестра: пояснение', (tester) async {
      await pumpStudy(tester, seed: true, now: DateTime.utc(2027, 2, 3, 9));
      expect(find.text('Сегодня вне семестра.'), findsOneWidget);
    });

    testWidgets('выходной день без занятий', (tester) async {
      await pumpStudy(tester, seed: true, now: DateTime.utc(2026, 10, 7, 9));
      expect(find.byKey(const Key('study-today-empty')), findsOneWidget);
      expect(find.text('Занятий сегодня нет.'), findsOneWidget);
    });

    testWidgets('исчерпан лимит: плитка предупреждает', (tester) async {
      await pumpStudy(
        tester,
        seedWith: (c) async {
          final demo = await seedStudyDemo(c);
          final repo = c.read(studyRepositoryProvider);
          for (final d in ['2026-09-21', '2026-09-28', '2026-10-05']) {
            await repo.mark(demo.mathMon, d, AttendanceStatus.absent);
          }
        },
      );
      expect(find.text('близко к лимиту: 1'), findsOneWidget);
    });

    testWidgets('ссылки ведут на экраны раздела', (tester) async {
      final container = await pumpStudy(tester, seed: true);
      final routes = {
        'study-subjects-link': '/study/subjects',
        'study-schedule-link': '/study/schedule',
        'study-editor-link': '/study/schedule/edit',
        'study-stats-link': '/study/stats',
        'study-semesters-link': '/study/semesters',
        'kpi-absences': '/study/stats',
        'kpi-debts': '/study/subjects',
        'kpi-week': '/study/schedule',
        'study-open-schedule': '/study/schedule',
      };
      for (final e in routes.entries) {
        await goTo(tester, container, '/study');
        await tapKey(tester, e.key);
        expect(locationOf(tester), e.value, reason: e.key);
      }
    });

    testWidgets('нажатие на занятие открывает лист занятия', (tester) async {
      await pumpStudy(tester, seed: true);
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lesson-when')), findsOneWidget);
    });

    testWidgets('«Новый семестр» из верхней панели', (tester) async {
      await pumpStudy(tester, seed: true);
      await tapKey(tester, 'study-add-semester');
      expect(find.byKey(const Key('semester-name')), findsOneWidget);
    });

    testWidgets('ошибка чтения: красная карточка и «Повторить»', (
      tester,
    ) async {
      await pumpStudy(
        tester,
        overrides: [
          studyDataProvider.overrideWithValue(
            AsyncValue<StudyData>.error(StateError('x'), StackTrace.empty),
          ),
        ],
      );
      expect(find.byKey(const Key('study-error')), findsOneWidget);
      await tapKey(tester, 'study-retry');
      expect(find.byKey(const Key('study-error')), findsOneWidget);
    });

    testWidgets('«Повторить» пересоздаёт все потоки раздела', (tester) async {
      var builds = 0;
      await pumpStudy(
        tester,
        overrides: [
          studySubjectsProvider.overrideWith((ref) {
            builds++;
            return builds == 1
                ? Stream<List<Subject>>.error(StateError('x'))
                : Stream.value(const <Subject>[]);
          }),
        ],
      );
      expect(find.byKey(const Key('study-error')), findsOneWidget);
      await tapKey(tester, 'study-retry');
      expect(builds, 2);
      expect(find.byKey(const Key('study-error')), findsNothing);
    });
  });

  group('предметы', () {
    testWidgets('нет семестра: сначала семестр', (tester) async {
      await pumpStudy(tester, location: '/study/subjects');
      expect(find.byKey(const Key('subjects-no-semester')), findsOneWidget);
    });

    testWidgets('список: карточки с преподавателем, аудиторией, пропусками и '
        'долгами; переход на экран предмета', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/subjects',
      );
      expect(find.text('Математический анализ'), findsOneWidget);
      expect(find.text('Иванов Иван Иванович'), findsOneWidget);
      expect(find.text('к1 28'), findsOneWidget);
      expect(find.text('Пропуски 1 из 4'.toUpperCase()), findsOneWidget);
      expect(find.text('2 долга, просрочено 1'), findsOneWidget);
      expect(find.text('1 долг'), findsOneWidget);
      expect(find.text('нет долгов'), findsOneWidget);
      await tester.tap(find.byKey(Key('subject-card-${demo.math}')));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/study/subjects/${demo.math}');
    });

    testWidgets('новый предмет и архив', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/subjects',
        files: false,
      );
      await tapKey(tester, 'subjects-add');
      await _enter(tester, 'subject-name', 'Химия');
      await _enter(tester, 'subject-teacher', 'Менделеев Д. И.');
      await _enter(tester, 'subject-room', 'к2-305');
      await _enter(tester, 'subject-limit', '5');
      await tapKey(tester, 'subject-save');
      final data = container.read(studyDataProvider).requireValue;
      final chem = data.subjects.firstWhere((s) => s.name == 'Химия');
      expect((chem.building, chem.room, chem.absenceLimit), ('2', '305', 5));
      expect(find.text('Химия'), findsOneWidget);
      expect(find.text('к2 305'), findsOneWidget);

      // В архив и обратно.
      await tester.runAsync(
        () => container
            .read(studyRepositoryProvider)
            .setSubjectArchived(demo.physics, archived: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('Физика'), findsNothing);
      await tapKey(tester, 'subjects-filter-archive');
      expect(find.text('Физика'), findsOneWidget);
      await tapKey(tester, 'subjects-filter-active');
      expect(find.text('Химия'), findsOneWidget);
    });

    testWidgets('пустые состояния: нет предметов и пустой архив', (
      tester,
    ) async {
      await pumpStudy(
        tester,
        location: '/study/subjects',
        seedWith: (c) async {
          final repo = c.read(studyRepositoryProvider);
          await repo.createSemester(
            Semester(
              id: repo.newId(),
              name: 'Осень',
              startDate: '2026-09-01',
              endDate: '2026-12-31',
              week1Start: '2026-08-31',
            ),
          );
        },
      );
      expect(find.byKey(const Key('subjects-empty')), findsOneWidget);
      await tapKey(tester, 'subjects-empty-add');
      expect(find.byKey(const Key('subject-name')), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'subjects-filter-archive');
      expect(find.text('Архив пуст'), findsOneWidget);
    });

    testWidgets('редактор предмета: ошибки ввода', (tester) async {
      await pumpStudyDemo(tester, at: (_) => '/study/subjects', files: false);
      await tapKey(tester, 'subjects-add');
      await tapKey(tester, 'subject-save');
      expect(find.byKey(const Key('subject-error')), findsOneWidget);
      await _enter(tester, 'subject-name', 'Химия');
      await _enter(tester, 'subject-room', 'я' * 25);
      await tapKey(tester, 'subject-save');
      expect(find.text('Аудитория — не длиннее 20 символов'), findsOneWidget);
    });
  });

  group('экран предмета', () {
    testWidgets('шапка, долги отдельными карточками, документы', (
      tester,
    ) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/subjects/${d.math}',
      );
      expect(find.byKey(const Key('subject-header')), findsOneWidget);
      expect(find.text('Иванов Иван Иванович'), findsOneWidget);
      expect(find.text('к1 28'), findsOneWidget);
      expect(find.byKey(const Key('subject-limit-pill')), findsOneWidget);
      expect(find.text('Осталось 3'), findsOneWidget);
      expect(
        find.text('Был 1 · пропустил 1 · отменено 0 · не отмечено 3'),
        findsOneWidget,
      );
      // Каждая лабораторная/практическая — отдельная карточка.
      for (final id in [demo.lab1, demo.practice2, demo.credit]) {
        expect(find.byKey(Key('debt-card-$id')), findsOneWidget);
      }
      expect(find.text('Просрочена'.toUpperCase()), findsOneWidget);
      expect(find.text('Методичка.pdf'), findsOneWidget);
      await tester.tap(find.byKey(Key('debt-card-${demo.lab1}')));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/study/debts/${demo.lab1}');
    });

    testWidgets('нет долгов, нет преподавателя и аудитории; заметка', (
      tester,
    ) async {
      await pumpStudyDemo(
        tester,
        at: (d) => '/study/subjects/${d.prog}',
        files: false,
      );
      expect(find.byKey(const Key('subject-no-debts')), findsOneWidget);
      expect(find.text('Сидоров П. К.'), findsOneWidget);
      expect(find.byKey(const Key('attachments-empty')), findsOneWidget);
    });

    testWidgets('добавить долг; изменить предмет; в архив', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/subjects/${d.prog}',
        files: false,
      );
      await tapKey(tester, 'subject-add-debt');
      await _enter(tester, 'debt-title', 'ЛР 7');
      await tapKey(tester, 'debt-kind-practice');
      await tapKey(tester, 'debt-due-tomorrow');
      await _enter(tester, 'debt-note', 'сделать до пятницы');
      await tapKey(tester, 'debt-save');
      final debt = container
          .read(studyDataProvider)
          .requireValue
          .debtsOf(demo.prog)
          .single;
      expect(debt.title, 'ЛР 7');
      expect(debt.kind, DebtKind.practice);
      expect(debt.dueDate, '2026-10-06');
      expect(find.text('сделать до пятницы'), findsOneWidget);
      expect(find.text('Срок Вт, 6 окт.'), findsOneWidget);

      await tapKey(tester, 'subject-edit');
      await _enter(tester, 'subject-note', 'Важно: сдать вовремя');
      await tapKey(tester, 'subject-save');
      expect(find.text('Важно: сдать вовремя'), findsOneWidget);

      await tapKey(tester, 'subject-edit');
      await tapKey(tester, 'subject-archive');
      final prog = container
          .read(studyDataProvider)
          .requireValue
          .subjectById[demo.prog]!;
      expect(prog.archived, isTrue);
    });

    testWidgets('удаление предмета с подтверждением', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/subjects/${d.prog}',
        files: false,
      );
      await tapKey(tester, 'subject-edit');
      await tapKey(tester, 'subject-delete');
      await tapKey(tester, 'confirm-ok');
      final data = container.read(studyDataProvider).requireValue;
      expect(data.subjectById[demo.prog], isNull);
      expect(find.byKey(const Key('subject-missing')), findsOneWidget);
    });

    testWidgets('предмета нет: сообщение', (tester) async {
      await pumpStudyDemo(
        tester,
        at: (_) => '/study/subjects/нет-такого',
        files: false,
      );
      expect(find.byKey(const Key('subject-missing')), findsOneWidget);
    });
  });

  group('карточка долга', () {
    testWidgets('статус, срок, заметка, вложения', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/debts/${d.lab1}',
      );
      expect(find.byKey(const Key('debt-header')), findsOneWidget);
      expect(find.text('Просрочено на 5 дней'), findsOneWidget);
      expect(
        find.text('Предел последовательности: вариант 7, оформить по ГОСТу'),
        findsOneWidget,
      );
      expect(find.text('Задание ЛР 1.jpg'), findsOneWidget);

      await tapKey(tester, 'debt-set-submitted');
      var debt = container
          .read(studyDataProvider)
          .requireValue
          .debtById[demo.lab1]!;
      expect(debt.status, DebtStatus.submitted);
      expect(debt.doneDate, '2026-10-05');
      expect(find.text('Сдана Пн, 5 окт.'), findsWidgets);
      await tapKey(tester, 'debt-set-credited');
      expect(
        container
            .read(studyDataProvider)
            .requireValue
            .debtById[demo.lab1]!
            .status,
        DebtStatus.credited,
      );
      await tapKey(tester, 'debt-set-open');
      debt = container
          .read(studyDataProvider)
          .requireValue
          .debtById[demo.lab1]!;
      expect(debt.doneDate, isNull);
    });

    testWidgets('заметка: кнопка сохранения появляется после правки', (
      tester,
    ) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/debts/${d.practice2}',
        files: false,
      );
      expect(find.byKey(const Key('debt-note-save')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('debt-note-field')).last,
        'Нужна распечатка',
      );
      await tester.pump();
      await tapKey(tester, 'debt-note-save');
      expect(find.byKey(const Key('debt-note-save')), findsNothing);
      expect(
        container
            .read(studyDataProvider)
            .requireValue
            .debtById[demo.practice2]!
            .note,
        'Нужна распечатка',
      );
      // Заметка с другого устройства приходит, пока поле не тронуто.
      await tester.runAsync(
        () => container
            .read(studyRepositoryProvider)
            .updateDebt(
              container
                  .read(studyDataProvider)
                  .requireValue
                  .debtById[demo.practice2]!
                  .copyWith(note: 'Из синхронизации'),
            ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Из синхронизации'), findsOneWidget);
    });

    testWidgets('«создать задачу»: задача этапа 2, ссылка у долга, открытие', (
      tester,
    ) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/debts/${d.lab1}',
        files: false,
      );
      await tapKey(tester, 'debt-create-task');
      final debt = container
          .read(studyDataProvider)
          .requireValue
          .debtById[demo.lab1]!;
      expect(debt.taskId, isNotNull);
      final repo = container.read(studyRepositoryProvider);
      expect(await repo.hasLiveTask(debt.taskId!), isTrue);
      // Открылся редактор задачи; закрываем и открываем по ссылке.
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('debt-create-task')), findsNothing);
      await tapKey(tester, 'debt-open-task');
      expect(find.text('ЛР 1 · Математический анализ'), findsWidgets);
    });

    testWidgets('ссылка на удалённую задачу сбрасывается', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/debts/${d.lab1}',
        files: false,
      );
      await tapKey(tester, 'debt-create-task');
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      final taskId = container
          .read(studyDataProvider)
          .requireValue
          .debtById[demo.lab1]!
          .taskId!;
      await tester.runAsync(
        () => container.read(syncStoreProvider).softDelete('tasks', taskId),
      );
      await tapKey(tester, 'debt-open-task');
      expect(find.byKey(const Key('debt-create-task')), findsOneWidget);
    });

    testWidgets('правка и удаление долга из редактора', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/debts/${d.practice2}',
        files: false,
      );
      await tapKey(tester, 'debt-edit');
      await _enter(tester, 'debt-title', 'Практика 2 (доп.)');
      await tapKey(tester, 'debt-due-none');
      await tapKey(tester, 'debt-status-credited');
      await tapKey(tester, 'debt-save');
      final debt = container
          .read(studyDataProvider)
          .requireValue
          .debtById[demo.practice2]!;
      expect(debt.title, 'Практика 2 (доп.)');
      expect(debt.dueDate, isNull);
      expect(debt.status, DebtStatus.credited);
      expect(debt.doneDate, '2026-10-05');

      await tapKey(tester, 'debt-edit');
      await tapKey(tester, 'debt-delete');
      await tapKey(tester, 'confirm-ok');
      expect(
        container.read(studyDataProvider).requireValue.debtById[demo.practice2],
        isNull,
      );
      // Вернулись к предмету.
      expect(find.byKey(const Key('debt-screen')), findsNothing);
    });

    testWidgets('ошибка ввода и несуществующий долг', (tester) async {
      await pumpStudyDemo(
        tester,
        at: (d) => '/study/debts/${d.lab1}',
        files: false,
      );
      await tapKey(tester, 'debt-edit');
      await _enter(tester, 'debt-title', '   ');
      await tapKey(tester, 'debt-save');
      expect(find.byKey(const Key('debt-error')), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await pumpStudyDemo(tester, at: (_) => '/study/debts/нет', files: false);
      expect(find.byKey(const Key('debt-missing')), findsOneWidget);
    });

    testWidgets('к предмету', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/debts/${d.lab1}',
        files: false,
      );
      await tapKey(tester, 'debt-open-subject');
      expect(locationOf(tester), '/study/subjects/${demo.math}');
    });
  });

  group('пропуски и семестры', () {
    testWidgets('статистика по предметам', (tester) async {
      await pumpStudyDemo(tester, at: (_) => '/study/stats', files: false);
      expect(find.text('Осень 2026: всего 1 пропуск'), findsOneWidget);
      expect(find.text('Математический анализ'), findsOneWidget);
      expect(find.text('Осталось 3'), findsNWidgets(2));
      expect(find.text('Лимит не задан'), findsOneWidget);
      expect(
        find.text('Был 1 · пропустил 1 · отменено 0 · не отмечено 3'),
        findsOneWidget,
      );
    });

    testWidgets('превышение лимита и переход к предмету', (tester) async {
      late StudyDemo demo;
      await pumpStudy(
        tester,
        location: '/study/stats',
        seedWith: (c) async {
          demo = await seedStudyDemo(c);
          final repo = c.read(studyRepositoryProvider);
          for (final d in [
            '2026-09-14',
            '2026-09-21',
            '2026-09-28',
            '2026-10-05',
          ]) {
            await repo.mark(demo.mathMon, d, AttendanceStatus.absent);
          }
        },
      );
      expect(find.text('Лимит превышен на 1'), findsOneWidget);
      await tester.tap(find.byKey(Key('stats-row-${demo.math}')));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/study/subjects/${demo.math}');
    });

    testWidgets('нет предметов: считать нечего', (tester) async {
      await pumpStudy(tester, location: '/study/stats');
      expect(find.byKey(const Key('stats-empty')), findsOneWidget);
    });

    testWidgets('семестры: список, архив и возврат, редактор', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/semesters',
        files: false,
      );
      expect(find.byKey(Key('semester-card-${demo.semester}')), findsOneWidget);
      expect(find.textContaining('предметов: 3'), findsOneWidget);
      await tapKey(tester, 'semester-archive-${demo.semester}');
      expect(find.text('Архив'.toUpperCase()), findsOneWidget);
      expect(find.text('Вернуть из архива'), findsOneWidget);
      // Архивный семестр выпадает из расписания.
      final data = container.read(studyDataProvider).requireValue;
      expect(data.dayOf('2026-10-05').kind, DayKind.noSemester);
      await tapKey(tester, 'semester-archive-${demo.semester}');
      expect(find.text('В архив'), findsOneWidget);
      await tapKey(tester, 'semester-edit-${demo.semester}');
      await _enter(tester, 'semester-name', 'Осень (правка)');
      await tapKey(tester, 'semester-cycle-3');
      await tapKey(tester, 'semester-save');
      final s = container.read(studyDataProvider).requireValue.semesters.single;
      expect((s.name, s.cycleLength), ('Осень (правка)', 3));
    });

    testWidgets('семестров нет: предложение; создание из списка', (
      tester,
    ) async {
      await pumpStudy(tester, location: '/study/semesters');
      expect(find.byKey(const Key('semesters-empty')), findsOneWidget);
      await tapKey(tester, 'semesters-add');
      expect(find.byKey(const Key('semester-name')), findsOneWidget);
    });
  });
}
