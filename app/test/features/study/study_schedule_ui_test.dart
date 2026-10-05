import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/presentation/lesson_sheet.dart';

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

void main() {
  group('расписание: день и неделя', () {
    testWidgets('день: заголовок, неделя цикла, занятия; листание', (
      tester,
    ) async {
      await pumpStudyDemo(tester, at: (_) => '/study/schedule', files: false);
      expect(find.byKey(const Key('schedule-screen')), findsOneWidget);
      expect(find.text('Пн, 5 октября'), findsOneWidget);
      expect(find.text('Чётная'), findsOneWidget);
      expect(find.text('Математический анализ'), findsOneWidget);
      expect(find.text('08:30'), findsOneWidget);
      await tapKey(tester, 'schedule-next');
      expect(find.text('Вт, 6 октября'), findsOneWidget);
      expect(find.text('Программирование'), findsOneWidget);
      expect(find.textContaining('Практика'), findsOneWidget);
      await tapKey(tester, 'schedule-next');
      expect(
        find.byKey(const Key('schedule-empty-2026-10-07')),
        findsOneWidget,
      );
      await tapKey(tester, 'schedule-prev');
      await tapKey(tester, 'schedule-prev');
      expect(find.text('Пн, 5 октября'), findsOneWidget);
      await tapKey(tester, 'schedule-next');
      await tapKey(tester, 'schedule-today');
      expect(find.text('Пн, 5 октября'), findsOneWidget);
    });

    testWidgets('неделя: семь дней, особый четверг, лаба по нечётным', (
      tester,
    ) async {
      await pumpStudyDemo(tester, at: (_) => '/study/schedule', files: false);
      await tapKey(tester, 'schedule-mode-week');
      expect(
        find.text('5 окт. – 11 окт.'.replaceFirst('5 окт.', '5')),
        findsOneWidget,
      );
      for (var d = 5; d <= 11; d++) {
        final key = Key('schedule-day-2026-10-${d.toString().padLeft(2, '0')}');
        await tester.ensureVisible(find.byKey(key));
        expect(find.byKey(key), findsOneWidget, reason: '$d');
      }
      await tester.ensureVisible(
        find.byKey(const Key('schedule-day-2026-10-08')),
      );
      expect(find.text('Подготовка к олимпиаде'), findsNWidgets(4));
      await tapKey(tester, 'schedule-next');
      // Нечётная неделя 12–18 октября: на понедельнике добавляется физика-лаба.
      await tester.ensureVisible(
        find.byKey(const Key('schedule-day-2026-10-12')),
      );
      expect(find.text('Физика'), findsOneWidget);
      expect(find.text('Нечётная'), findsWidgets);
    });

    testWidgets('праздник и вне семестра', (tester) async {
      await pumpStudyDemo(tester, at: (_) => '/study/schedule', files: false);
      // Листаем недели до 31 декабря (праздничный четверг).
      await tapKey(tester, 'schedule-mode-week');
      for (var i = 0; i < 12; i++) {
        await tapKey(tester, 'schedule-next');
      }
      await tester.ensureVisible(
        find.byKey(const Key('schedule-day-2026-12-31')),
      );
      expect(find.text('Праздник'.toUpperCase()), findsOneWidget);
      expect(find.text('Праздник: занятий нет'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('schedule-day-2027-01-01')),
      );
      expect(find.text('Вне семестра'), findsWidgets);
    });

    testWidgets('кнопка редактора ведёт в редактор расписания', (tester) async {
      await pumpStudyDemo(tester, at: (_) => '/study/schedule', files: false);
      await tapKey(tester, 'schedule-edit');
      expect(find.byKey(const Key('schedule-editor')), findsOneWidget);
    });
  });

  group('лист занятия: посещаемость', () {
    testWidgets('был / пропустил / отменена преподавателем / снять отметку', (
      tester,
    ) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/schedule',
        files: false,
      );
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lesson-when')), findsOneWidget);
      expect(find.text('Пн, 5 окт. · 08:30–10:00'), findsOneWidget);
      await tapKey(tester, 'mark-present');
      var mark = _data(container).markBySlotDate[(demo.mathMon, '2026-10-05')];
      expect(mark?.status, AttendanceStatus.present);
      expect(find.byKey(const Key('lesson-when')), findsNothing);

      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'mark-absent');
      mark = _data(container).markBySlotDate[(demo.mathMon, '2026-10-05')];
      expect(mark?.status, AttendanceStatus.absent);
      expect(_data(container).attendance[demo.math]!.absent, 2);

      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'mark-cancelled');
      expect(_data(container).attendance[demo.math]!.absent, 1);
      expect(find.text('отменена преподавателем'), findsOneWidget);

      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'mark-clear');
      expect(
        _data(container).markBySlotDate[(demo.mathMon, '2026-10-05')],
        isNull,
      );
    });

    testWidgets('будущее занятие: отметка недоступна, изменения — да', (
      tester,
    ) async {
      await pumpStudyDemo(tester, at: (_) => '/study/schedule', files: false);
      await tapKey(tester, 'schedule-next');
      await tapKey(tester, 'schedule-next');
      await tapKey(tester, 'schedule-next');
      await tapKey(tester, 'schedule-next');
      await tapKey(tester, 'schedule-next');
      await tapKey(tester, 'schedule-next');
      await tapKey(tester, 'schedule-next');
      expect(find.text('Пн, 12 октября'), findsOneWidget);
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      expect(
        find.text('Отметить посещаемость можно в день занятия.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mark-present')), findsNothing);
      expect(find.byKey(const Key('lesson-override')), findsOneWidget);
    });
  });

  group('лист занятия: изменения «только на дату» и «для всех»', () {
    testWidgets('отмена пары: зачёркнута, в пропуски не идёт; возврат', (
      tester,
    ) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/schedule',
        files: false,
      );
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'lesson-override');
      expect(find.byKey(const Key('override-save')), findsOneWidget);
      await tapKey(tester, 'override-save');
      final lesson = _data(container).dayOf('2026-10-05').lessons.single;
      expect(lesson.cancelled, isTrue);
      expect(find.text('отменена'), findsOneWidget);
      expect(_data(container).attendance[demo.math]!.cancelled, 1);
      // Лист показывает «Вернуть по расписанию».
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      expect(
        find.text('Пара отменена на эту дату: в пропуски не идёт.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mark-present')), findsNothing);
      await tapKey(tester, 'lesson-restore');
      expect(
        _data(container).dayOf('2026-10-05').lessons.single.cancelled,
        isFalse,
      );
    });

    testWidgets('изменение: время, аудитория, название, тип', (tester) async {
      final (container, _) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/schedule',
        files: false,
      );
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'lesson-override');
      await tapKey(tester, 'override-action-change');
      await _enter(tester, 'override-start', '14:00');
      await _enter(tester, 'override-end', '15:30');
      await _enter(tester, 'override-room', 'к2 305');
      await _enter(tester, 'override-title', 'Консультация');
      await tapKey(tester, 'override-kind-practice');
      await tapKey(tester, 'override-save');
      final l = _data(container).dayOf('2026-10-05').lessons.single;
      expect(
        (l.start, l.end, l.roomText, l.title, l.kind, l.changed),
        ('14:00', '15:30', 'к2 305', 'Консультация', LessonKind.practice, true),
      );
      expect(find.text('Консультация'), findsOneWidget);
      expect(find.textContaining('изменена'), findsOneWidget);
    });

    testWidgets('другой предмет на дату', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/schedule',
        files: false,
      );
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'lesson-override');
      await tapKey(tester, 'override-action-change');
      await tapKey(tester, 'override-subject-${demo.physics}');
      await tapKey(tester, 'override-save');
      final l = _data(container).dayOf('2026-10-05').lessons.single;
      expect(l.subjectId, demo.physics);
      expect(l.title, 'Физика');
      // Занятие идёт на предмет-замену: пропуск по ней, не по матану.
      expect(
        _data(container).attendance[demo.physics]!.unmarked,
        greaterThan(0),
      );
    });

    testWidgets('перенос на другую дату', (tester) async {
      final (container, _) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/schedule',
        files: false,
      );
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'lesson-override');
      await tapKey(tester, 'override-action-move');
      // Без даты — ошибка.
      await tapKey(tester, 'override-save');
      expect(find.text('Выберите дату, на которую переносим'), findsOneWidget);
      await tapKey(tester, 'override-date-tomorrow');
      await _enter(tester, 'override-start', '14:00');
      await _enter(tester, 'override-end', '15:30');
      await tapKey(tester, 'override-save');
      final src = _data(container).dayOf('2026-10-05').lessons.single;
      expect(src.movedTo, '2026-10-06');
      expect(find.textContaining('перенесена на Вт, 6 окт.'), findsOneWidget);
      final dst = _data(container)
          .dayOf('2026-10-06')
          .lessons
          .firstWhere((l) => l.movedFrom != null);
      expect((dst.start, dst.end), ('14:00', '15:30'));
      // Перенесённое занятие открывается в день переноса.
      await tapKey(tester, 'schedule-next');
      expect(find.textContaining('перенос с Пн, 5 окт.'), findsOneWidget);
      await tester.tap(find.textContaining('перенос с Пн, 5 окт.'));
      await tester.pumpAndSettle();
      expect(find.text('Перенесена с Пн, 5 окт.'), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      // Исходное занятие — «призрак»: отметки нет, есть возврат.
      await tapKey(tester, 'schedule-prev');
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      expect(find.text('Пара перенесена на Вт, 6 окт.'), findsOneWidget);
      expect(find.byKey(const Key('mark-present')), findsNothing);
      await tapKey(tester, 'lesson-restore');
      expect(
        _data(container).dayOf('2026-10-05').lessons.single.movedTo,
        isNull,
      );
    });

    testWidgets('правка существующего изменения: сброс из редактора', (
      tester,
    ) async {
      final (container, _) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/schedule',
        files: false,
      );
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'lesson-override');
      await tapKey(tester, 'override-save');
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'lesson-override');
      expect(find.byKey(const Key('override-clear')), findsOneWidget);
      await tapKey(tester, 'override-clear');
      expect(_data(container).overrides, isEmpty);
    });

    testWidgets('ошибки ввода изменения: время и аудитория', (tester) async {
      await pumpStudyDemo(tester, at: (_) => '/study/schedule', files: false);
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'lesson-override');
      await tapKey(tester, 'override-action-change');
      await _enter(tester, 'override-start', '14:00');
      await tapKey(tester, 'override-save');
      expect(find.byKey(const Key('override-error')), findsOneWidget);
      await _enter(tester, 'override-end', '15:30');
      await _enter(tester, 'override-room', 'я' * 25);
      await tapKey(tester, 'override-save');
      expect(find.text('Аудитория — не длиннее 20 символов'), findsOneWidget);
    });

    testWidgets('для всех таких пар: правка самой пары', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/schedule',
        files: false,
      );
      await tester.tap(find.text('Математический анализ'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'lesson-edit-slot');
      await _enter(tester, 'slot-room', 'к2 41');
      await tapKey(tester, 'slot-save');
      expect(_data(container).slotById[demo.mathMon]!.room, '41');
      for (final d in ['2026-10-05', '2026-10-12', '2026-10-19']) {
        expect(_data(container).dayOf(d).lessons.first.roomText, 'к2 41');
      }
    });

    testWidgets('занятие особого дня: только сведения и правка правила', (
      tester,
    ) async {
      final (_, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/study/schedule',
        files: false,
      );
      await tapKey(tester, 'schedule-mode-week');
      final tile = find.byKey(Key('lesson-rule:${demo.rule}:i1'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(
        find.text('Занятие особого дня: не отмечается и в пропуски не идёт.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mark-present')), findsNothing);
      await tapKey(tester, 'lesson-edit-rule');
      expect(find.byKey(const Key('rule-title')), findsOneWidget);
    });

    testWidgets('занятие не найдено: расписание изменилось', (tester) async {
      await pumpStudyDemo(tester, at: (_) => '/study/schedule', files: false);
      final context = tester.element(find.byKey(const Key('schedule-screen')));
      unawaited(
        showAttendanceSheet(
          context,
          slotId: 'нет',
          scheduledDate: '2026-10-05',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lesson-missing')), findsOneWidget);
    });
  });
}
