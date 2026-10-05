import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_ids.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';

import '../../support/study_env.dart';

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(
    find
        .descendant(of: find.byKey(Key(key)), matching: find.byType(TextField))
        .first,
    text,
  );
}

StudyData _data(ProviderContainer container) =>
    container.read(studyDataProvider).requireValue;

Future<(ProviderContainer, StudyDemo)> _editor(
  WidgetTester tester, {
  String tab = 'slots',
}) async {
  final result = await pumpStudyDemo(
    tester,
    at: (_) => '/study/schedule/edit',
    files: false,
  );
  if (tab != 'slots') await tapKey(tester, 'editor-tab-$tab');
  return result;
}

void main() {
  group('редактор расписания: без семестра и несколько семестров', () {
    testWidgets('нет семестра: предложение', (tester) async {
      await pumpStudy(tester, location: '/study/schedule/edit');
      expect(find.byKey(const Key('editor-no-semester')), findsOneWidget);
    });

    testWidgets('два семестра: переключатель, у второго — свои пары', (
      tester,
    ) async {
      final (container, demo) = await _editor(tester);
      late String second;
      await tester.runAsync(() async {
        final repo = container.read(studyRepositoryProvider);
        second = repo.newId();
        await repo.createSemester(
          Semester(
            id: second,
            name: 'Весна 2027',
            startDate: '2027-02-01',
            endDate: '2027-06-30',
            week1Start: '2027-02-01',
          ),
        );
      });
      await tester.pumpAndSettle();
      await tapKey(tester, 'editor-semester-$second');
      expect(find.byKey(Key('slot-tile-${demo.mathMon}')), findsNothing);
      await tapKey(tester, 'slots-add-1');
      // Предметов у второго семестра нет: только «своё название».
      expect(find.byKey(const Key('slot-subject-none')), findsOneWidget);
      expect(find.byKey(Key('slot-subject-${demo.math}')), findsNothing);
    });
  });

  group('пары', () {
    testWidgets('новая пара: предмет, тип, день, неделя, звонок, аудитория', (
      tester,
    ) async {
      final (container, demo) = await _editor(tester);
      await tapKey(tester, 'slots-add-3');
      await tapKey(tester, 'slot-subject-${demo.prog}');
      await tapKey(tester, 'slot-kind-lab');
      await tapKey(tester, 'slot-cycle-1');
      await tapKey(tester, 'slot-number-4');
      await _enter(tester, 'slot-room', 'к1 28');
      await tapKey(tester, 'slot-save');
      final slot = _data(container).slots
          .firstWhere((s) => s.weekday == 3 && s.subjectId == demo.prog);
      expect(slot.kind, LessonKind.lab);
      expect(slot.cycleWeek, 1);
      expect(slot.number, 4);
      expect((slot.building, slot.room), ('1', '28'));
      expect(find.byKey(Key('slot-tile-${slot.id}')), findsOneWidget);
    });

    testWidgets('своё название и своё время; удаление пары с предупреждением', (
      tester,
    ) async {
      final (container, _) = await _editor(tester);
      await tapKey(tester, 'slots-add-5');
      await _enter(tester, 'slot-title', 'Кружок');
      await tapKey(tester, 'slot-time-own');
      await _enter(tester, 'slot-start', '17:00');
      await _enter(tester, 'slot-end', '18:30');
      await tapKey(tester, 'slot-save');
      final slot = _data(container).slots
          .firstWhere((s) => s.title == 'Кружок');
      expect(
        (slot.number, slot.startTime, slot.endTime),
        (null, '17:00', '18:30'),
      );
      expect(find.textContaining('17:00–18:30'), findsOneWidget);
      // Правка и удаление.
      await tester.tap(find.byKey(Key('slot-tile-${slot.id}')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'slot-delete');
      expect(find.textContaining('отметки'), findsOneWidget);
      await tapKey(tester, 'confirm-ok');
      expect(_data(container).slotById[slot.id], isNull);
    });

    testWidgets('удаление пары стирает её отметки: счётчики пересчитываются', (
      tester,
    ) async {
      final (container, demo) = await _editor(tester);
      expect(_data(container).attendance[demo.math]!.absent, 1);
      await tester.tap(find.byKey(Key('slot-tile-${demo.mathMon}')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'slot-delete');
      await tapKey(tester, 'confirm-ok');
      expect(_data(container).attendance[demo.math]!.absent, 0);
    });

    testWidgets(
      'ошибки: ни предмета, ни названия; неверное время и аудитория',
      (tester) async {
        await _editor(tester);
        await tapKey(tester, 'slots-add-2');
        await tapKey(tester, 'slot-save');
        expect(
          find.text('Выберите предмет или впишите название'),
          findsOneWidget,
        );
        await _enter(tester, 'slot-title', 'Кружок');
        await tapKey(tester, 'slot-time-own');
        await _enter(tester, 'slot-start', 'абв');
        await tapKey(tester, 'slot-save');
        expect(
          find.text('Время — в формате ЧЧ:ММ, например 08:30'),
          findsOneWidget,
        );
        await _enter(tester, 'slot-start', '10:00');
        await _enter(tester, 'slot-end', '09:00');
        await tapKey(tester, 'slot-save');
        expect(find.text('Конец должен быть позже начала'), findsOneWidget);
        await _enter(tester, 'slot-end', '11:00');
        await _enter(tester, 'slot-room', 'я' * 25);
        await tapKey(tester, 'slot-save');
        expect(find.text('Аудитория — не длиннее 20 символов'), findsOneWidget);
      },
    );
  });

  group('особые дни', () {
    testWidgets('«по четвергам обычных пар нет, 3 пары — подготовка к '
        'олимпиаде»: правило и три занятия', (tester) async {
      final (container, demo) = await _editor(tester, tab: 'rules');
      await tester.runAsync(
        () => container.read(studyRepositoryProvider).deleteDayRule(demo.rule),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rules-empty')), findsOneWidget);
      await tapKey(tester, 'rules-add');
      await _enter(tester, 'rule-title', 'Подготовка к олимпиаде');
      await tapKey(tester, 'rule-weekday-4');
      for (var i = 0; i < 3; i++) {
        await tapKey(tester, 'rule-item-add');
        await tapKey(tester, 'rule-item-ok');
      }
      await tapKey(tester, 'rule-save');
      final rule = _data(container).rulesOf(demo.semester).single;
      expect(rule.id, dayRuleId(demo.semester, weekday: 4));
      expect(rule.hideRegular, isTrue);
      expect(
        [for (final i in rule.items) (i.key, i.number, i.title)],
        [
          ('i1', 1, 'Подготовка к олимпиаде'),
          ('i2', 2, 'Подготовка к олимпиаде'),
          ('i3', 3, 'Подготовка к олимпиаде'),
        ],
      );
      // Четверг теперь особый день без обычных пар.
      final day = _data(container).dayOf('2026-10-08');
      expect(day.kind.wire, 'special');
      expect(day.lessons, hasLength(3));
    });

    testWidgets('правило на дату и на чётную неделю; своё время занятия', (
      tester,
    ) async {
      final (container, demo) = await _editor(tester, tab: 'rules');
      await tapKey(tester, 'rules-add');
      await _enter(tester, 'rule-title', 'Экскурсия');
      await tapKey(tester, 'rule-scope-date');
      await tapKey(tester, 'rule-date-tomorrow');
      await tapKey(tester, 'rule-hide-regular');
      await tapKey(tester, 'rule-item-add');
      await _enter(tester, 'rule-item-title', 'Музей');
      await tapKey(tester, 'rule-item-time-own');
      await _enter(tester, 'rule-item-start', '9.30');
      await _enter(tester, 'rule-item-end', '12:00');
      await _enter(tester, 'rule-item-room', 'к2 1');
      await tapKey(tester, 'rule-item-kind-lecture');
      await tapKey(tester, 'rule-item-ok');
      await tapKey(tester, 'rule-save');
      final dated = _data(container)
          .rulesOf(demo.semester)
          .firstWhere((r) => r.onDate != null);
      expect(dated.onDate, '2026-10-06');
      expect(dated.hideRegular, isFalse);
      expect(dated.items.single.startTime, '09:30');
      expect(dated.items.single.endTime, '12:00');
      expect(dated.items.single.room, '1');
      // Вторник: обычные пары остались (чётная неделя, программирование).
      final day = _data(container).dayOf('2026-10-06');
      expect(day.lessons.map((l) => l.title), contains('Программирование'));
      expect(day.lessons.map((l) => l.title), contains('Музей'));

      // Правило на день недели только в чётные недели.
      await tapKey(tester, 'rules-add');
      await _enter(tester, 'rule-title', 'Чётная пятница');
      await tapKey(tester, 'rule-weekday-5');
      await tapKey(tester, 'rule-cycle-2');
      await tapKey(tester, 'rule-save');
      final friday = _data(container)
          .rulesOf(demo.semester)
          .firstWhere((r) => r.weekday == 5);
      expect(friday.cycleWeek, 2);
    });

    testWidgets('правка существующего правила: область не меняется; занятия '
        'правятся и убираются', (tester) async {
      final (container, demo) = await _editor(tester, tab: 'rules');
      await tester.tap(find.byKey(Key('rule-tile-${demo.rule}')));
      await tester.pumpAndSettle();
      expect(find.text('Каждый четверг'), findsOneWidget);
      await _enter(tester, 'rule-title', 'Олимпиада');
      await tapKey(tester, 'rule-item-remove-2');
      await tapKey(tester, 'rule-item-remove-1');
      await tester.tap(find.byKey(const Key('rule-item-0')));
      await tester.pumpAndSettle();
      await _enter(tester, 'rule-item-title', 'Задачи');
      await tapKey(tester, 'rule-item-number-3');
      await tapKey(tester, 'rule-item-ok');
      await tapKey(tester, 'rule-save');
      final rule = _data(container).rulesOf(demo.semester).single;
      expect(rule.title, 'Олимпиада');
      expect(rule.items.single.title, 'Задачи');
      expect(rule.items.single.number, 3);
    });

    testWidgets('ошибки ввода и удаление правила', (tester) async {
      final (container, demo) = await _editor(tester, tab: 'rules');
      await tapKey(tester, 'rules-add');
      await tapKey(tester, 'rule-save');
      expect(find.byKey(const Key('rule-error')), findsOneWidget);
      await _enter(tester, 'rule-title', 'Правило');
      await tapKey(tester, 'rule-scope-date');
      await tapKey(tester, 'rule-save');
      expect(find.text('Выберите дату'), findsOneWidget);
      await tapKey(tester, 'rule-item-add');
      await _enter(tester, 'rule-item-title', '   ');
      await tapKey(tester, 'rule-item-ok');
      expect(find.text('Название не может быть пустым'), findsOneWidget);
      await _enter(tester, 'rule-item-title', 'Занятие');
      await tapKey(tester, 'rule-item-time-own');
      await _enter(tester, 'rule-item-start', 'ой');
      await tapKey(tester, 'rule-item-ok');
      expect(
        find.text('Время — в формате ЧЧ:ММ, например 08:30'),
        findsOneWidget,
      );
      await _enter(tester, 'rule-item-start', '10:00');
      await _enter(tester, 'rule-item-end', '09:00');
      await tapKey(tester, 'rule-item-ok');
      expect(find.text('Конец должен быть позже начала'), findsOneWidget);
      await _enter(tester, 'rule-item-end', '11:00');
      await _enter(tester, 'rule-item-room', 'я' * 25);
      await tapKey(tester, 'rule-item-ok');
      expect(find.text('Аудитория — не длиннее 20 символов'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('rule-tile-${demo.rule}')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'rule-delete');
      await tapKey(tester, 'confirm-ok');
      expect(_data(container).rulesOf(demo.semester), isEmpty);
    });

    testWidgets('правило не найдено', (tester) async {
      final (container, demo) = await _editor(tester, tab: 'rules');
      await tester.runAsync(
        () => container.read(studyRepositoryProvider).deleteDayRule(demo.rule),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('rule-tile-${demo.rule}')), findsNothing);
    });
  });

  group('звонки', () {
    testWidgets('сетка: список, быстрая сетка и правка по паре', (
      tester,
    ) async {
      final (container, demo) = await _editor(tester, tab: 'bells');
      expect(find.byKey(const Key('bell-tile-6')), findsOneWidget);
      await tapKey(tester, 'bells-edit');
      await _enter(tester, 'bells-gen-start', '9:00');
      await _enter(tester, 'bells-gen-duration', '80');
      await _enter(tester, 'bells-gen-breaks', '10,10,30');
      await _enter(tester, 'bells-gen-count', '4');
      await tapKey(tester, 'bells-generate');
      expect(find.byKey(const Key('bells-row-3')), findsOneWidget);
      expect(find.byKey(const Key('bells-row-4')), findsNothing);
      await _enter(tester, 'bells-end-0', '10:30');
      await tapKey(tester, 'bells-save');
      final bells = _data(container).bellsOf(demo.semester);
      expect(
        [for (final b in bells) '${b.number} ${b.startTime}-${b.endTime}'],
        ['1 09:00-10:30', '2 10:30-11:50', '3 12:00-13:20', '4 13:50-15:10'],
      );
      // Пары матана идут по новой сетке.
      expect(_data(container).dayOf('2026-10-05').lessons.first.start, '09:00');
    });

    testWidgets('«только на дату»: звонки дня заменяют обычные; возврат', (
      tester,
    ) async {
      final (container, demo) = await _editor(tester, tab: 'bells');
      await tapKey(tester, 'bells-add-date');
      expect(find.byKey(const Key('bells-row-5')), findsOneWidget);
      await _enter(tester, 'bells-start-0', '07:50');
      await _enter(tester, 'bells-end-0', '09:20');
      await tapKey(tester, 'bells-remove-5');
      await tapKey(tester, 'bells-save');
      // Запись только для изменённого номера, а не вся сетка.
      final dated = _data(container).dateBellsOf(demo.semester);
      expect(
        [for (final b in dated) '${b.number} ${b.startTime}'],
        ['1 07:50'],
      );
      expect(_data(container).dayOf('2026-10-05').lessons.first.start, '07:50');
      expect(_data(container).dayOf('2026-10-12').lessons.first.start, '08:30');
      expect(find.byKey(const Key('bells-date-2026-10-05')), findsOneWidget);
      await tester.tap(find.byKey(const Key('bells-date-2026-10-05')));
      await tester.pumpAndSettle();
      // Таблица даты — вся сетка с подставленным звонком даты.
      expect(find.byKey(const Key('bells-row-5')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('bells-start-0')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '07:50',
      );
      await tapKey(tester, 'bells-restore');
      expect(_data(container).dateBellsOf(demo.semester), isEmpty);
      expect(_data(container).dayOf('2026-10-05').lessons.first.start, '08:30');
    });

    testWidgets(
      '«только на дату»: звонок, снова равный обычному, не хранится',
      (tester) async {
        final (container, demo) = await _editor(tester, tab: 'bells');
        await tapKey(tester, 'bells-add-date');
        await _enter(tester, 'bells-start-1', '10:20');
        await _enter(tester, 'bells-end-1', '11:50');
        await tapKey(tester, 'bells-save');
        expect(_data(container).dateBellsOf(demo.semester), hasLength(1));
        await tester.tap(find.byKey(const Key('bells-date-2026-10-05')));
        await tester.pumpAndSettle();
        await _enter(tester, 'bells-start-1', '10:10');
        await _enter(tester, 'bells-end-1', '11:40');
        await tapKey(tester, 'bells-save');
        expect(_data(container).dateBellsOf(demo.semester), isEmpty);
      },
    );

    testWidgets('ошибки: быстрая сетка, время пары, дата', (tester) async {
      await _editor(tester, tab: 'bells');
      await tapKey(tester, 'bells-edit');
      await _enter(tester, 'bells-gen-count', '');
      await tapKey(tester, 'bells-generate');
      expect(find.textContaining('Заполните начало'), findsOneWidget);
      await _enter(tester, 'bells-gen-count', '6');
      await _enter(tester, 'bells-gen-breaks', '10,10');
      await tapKey(tester, 'bells-generate');
      expect(find.textContaining('Сетка не получилась'), findsOneWidget);
      await _enter(tester, 'bells-start-1', 'xx');
      await tapKey(tester, 'bells-save');
      expect(find.text('Пара 2: время — в формате ЧЧ:ММ'), findsOneWidget);
      await _enter(tester, 'bells-start-1', '12:00');
      await _enter(tester, 'bells-end-1', '11:00');
      await tapKey(tester, 'bells-save');
      expect(find.textContaining('Пара 2:'), findsOneWidget);
    });

    testWidgets('добавить пару: до двенадцати', (tester) async {
      final (container, demo) = await _editor(tester, tab: 'bells');
      await tapKey(tester, 'bells-edit');
      for (var i = 0; i < 8; i++) {
        await tapKey(tester, 'bells-add');
      }
      expect(find.byKey(const Key('bells-row-11')), findsOneWidget);
      expect(find.byKey(const Key('bells-row-12')), findsNothing);
      await tapKey(tester, 'bells-remove-11');
      await _enter(tester, 'bells-start-6', '19:00');
      await _enter(tester, 'bells-end-6', '20:30');
      for (var i = 7; i < 11; i++) {
        await tapKey(tester, 'bells-remove-7');
      }
      await tapKey(tester, 'bells-save');
      expect(_data(container).bellsOf(demo.semester), hasLength(7));
    });

    testWidgets('нет звонков: подсказка', (tester) async {
      final (container, demo) = await _editor(tester, tab: 'bells');
      await tester.runAsync(
        () => container
            .read(studyRepositoryProvider)
            .replaceBells(semesterId: demo.semester, grid: const []),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bells-empty')), findsOneWidget);
    });
  });

  group('изменения на даты', () {
    testWidgets('список, правка и возврат по расписанию', (tester) async {
      final (container, demo) = await _editor(tester, tab: 'overrides');
      expect(find.byKey(const Key('overrides-empty')), findsOneWidget);
      late String id;
      await tester.runAsync(() async {
        final repo = container.read(studyRepositoryProvider);
        id = await repo.saveOverride(
          ClassOverride(
            slotId: demo.mathMon,
            date: '2026-10-12',
            action: OverrideAction.move,
            newDate: '2026-10-14',
          ),
        );
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Перенесена на Ср, 14 окт.'), findsOneWidget);
      await tester.tap(find.byKey(Key('override-tile-$id')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('override-clear')), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'override-remove-$id');
      expect(_data(container).overrides, isEmpty);
    });

    testWidgets('отмена и изменение показываются подписями', (tester) async {
      final (container, demo) = await _editor(tester, tab: 'overrides');
      await tester.runAsync(() async {
        final repo = container.read(studyRepositoryProvider);
        await repo.saveOverride(
          ClassOverride(
            slotId: demo.mathMon,
            date: '2026-10-19',
            action: OverrideAction.cancel,
          ),
        );
        await repo.saveOverride(
          ClassOverride(
            slotId: demo.mathMon,
            date: '2026-10-26',
            action: OverrideAction.change,
            title: 'Другое',
          ),
        );
      });
      await tester.pumpAndSettle();
      expect(find.text('Отменена'), findsOneWidget);
      expect(find.text('Изменена'), findsOneWidget);
    });
  });

  group('редактор семестра', () {
    testWidgets('сдвиги чётности и без чередования', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/semesters',
        files: false,
      );
      await tapKey(tester, 'semester-edit-${demo.semester}');
      await tapKey(tester, 'semester-shift-add');
      await tester.tap(find.text('ОК'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('semester-shift-0')), findsOneWidget);
      await tapKey(tester, 'semester-shift-flip-0');
      await tapKey(tester, 'semester-save');
      final s = _data(container).semesters.single;
      expect(s.weekShifts, hasLength(1));
      expect(s.weekShifts.single.weeks, -1);
      // Без чередования сдвиги не сохраняются.
      await tapKey(tester, 'semester-edit-${demo.semester}');
      await tapKey(tester, 'semester-cycle-1');
      await tapKey(tester, 'semester-save');
      final s2 = _data(container).semesters.single;
      expect(s2.cycleLength, 1);
      expect(s2.weekShifts, isEmpty);
    });

    testWidgets('ошибка: пустое название; удаление семестра', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/semesters',
        files: false,
      );
      await tapKey(tester, 'semester-edit-${demo.semester}');
      await _enter(tester, 'semester-name', '  ');
      await tapKey(tester, 'semester-save');
      expect(find.byKey(const Key('semester-error')), findsOneWidget);
      await tapKey(tester, 'semester-delete');
      await tapKey(tester, 'confirm-ok');
      expect(_data(container).semesters, isEmpty);
    });

    testWidgets('создание без звонков по умолчанию', (tester) async {
      final container = await pumpStudy(tester, location: '/study/semesters');
      await tapKey(tester, 'semesters-add');
      await _enter(tester, 'semester-name', 'Весна');
      await tapKey(tester, 'semester-default-bells');
      await tapKey(tester, 'semester-cycle-1');
      await tapKey(tester, 'semester-save');
      final data = _data(container);
      expect(data.semesters.single.cycleLength, 1);
      expect(data.bells, isEmpty);
    });
  });
}
