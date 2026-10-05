import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/calendar/application/calendar_view.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/presentation/calendar_actions.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_taps.dart';
import 'package:my_tasker/features/study/application/study_calendar.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/study_context_source.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/presentation/lesson_sheet.dart';

import '../../support/study_env.dart';

void main() {
  group('слой «Учёба» в календаре', () {
    testWidgets('занятия показываются элементами слоя; отменённые и '
        'перенесённые из дня — нет; слой выключается', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/calendar',
        files: false,
      );
      await tester.runAsync(() async {
        await container
            .read(calendarRepositoryProvider)
            .ensureSystemCalendars();
        final repo = container.read(studyRepositoryProvider);
        await repo.saveOverride(
          ClassOverride(
            slotId: demo.mathMon,
            date: '2026-10-12',
            action: OverrideAction.cancel,
          ),
        );
      });
      await tester.pumpAndSettle();
      final span = DateSpan(
        DateTime.utc(2026, 10, 5),
        DateTime.utc(2026, 10, 19),
      );
      final items = container.read(calendarItemsProvider(span)).requireValue;
      final study = items.whereType<StudyEventItem>().toList();
      // 5 окт. — матан; 6 окт. — программирование; 8 окт. — 3 занятия
      // олимпиады; 12 окт. отменено; 13 окт. — нет (нечётная неделя);
      // 15 окт. — олимпиада; 19 окт. вне отрезка.
      expect(
        [for (final i in study) '${i.date} ${i.title}'],
        containsAll([
          '2026-10-05 Математический анализ',
          '2026-10-06 Программирование',
        ]),
      );
      expect(
        study.where(
          (i) => i.date == '2026-10-12' && i.title == 'Математический анализ',
        ),
        isEmpty,
      );
      final first = study.first;
      expect(first.layerKind, 'study');
      expect(first.allDay, isFalse);
      expect(first.start, DateTime.utc(2026, 10, 5, 8, 30));
      expect(first.location, 'к1 28');
      expect(first.event.calendarId, studyLayerId);

      // Перенос: в день переноса, в исходный — нет.
      await tester.runAsync(
        () => container
            .read(studyRepositoryProvider)
            .saveOverride(
              ClassOverride(
                slotId: demo.mathMon,
                date: '2026-10-05',
                action: OverrideAction.move,
                newDate: '2026-10-07',
              ),
            ),
      );
      await tester.pumpAndSettle();
      final moved = container
          .read(calendarItemsProvider(span))
          .requireValue
          .whereType<StudyEventItem>()
          .where((i) => i.title == 'Математический анализ')
          .map((i) => i.date);
      expect(moved, contains('2026-10-07'));
      expect(moved, isNot(contains('2026-10-05')));

      // Выключили слой — занятий нет.
      await tester.runAsync(
        () => container
            .read(calendarRepositoryProvider)
            .updateLayer(studyLayerId, visible: false),
      );
      await tester.pumpAndSettle();
      expect(
        container
            .read(calendarItemsProvider(span))
            .requireValue
            .whereType<StudyEventItem>(),
        isEmpty,
      );
    });

    testWidgets('занятие без времени — полоса «весь день»; без семестров '
        'слой пуст', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/calendar',
        files: false,
      );
      await tester.runAsync(() async {
        final repo = container.read(studyRepositoryProvider);
        await repo.replaceBells(semesterId: demo.semester, grid: const []);
      });
      await tester.pumpAndSettle();
      final data = container.read(studyDataProvider).requireValue;
      final items = buildStudyItems(
        data,
        fromDate: DateTime.utc(2026, 10, 5),
        toDate: DateTime.utc(2026, 10, 6),
      );
      expect(items.single.allDay, isTrue);
      expect(
        buildStudyItems(
          StudyData(
            semesters: const [],
            subjects: const [],
            bells: const [],
            slots: const [],
            dayRules: const [],
            overrides: const [],
            marks: const [],
            debts: const [],
            attachments: const [],
            calendar: HolidayCalendar.empty(),
            today: '2026-10-05',
          ),
          fromDate: DateTime.utc(2026, 10, 5),
          toDate: DateTime.utc(2026, 10, 6),
        ),
        isEmpty,
      );
    });

    testWidgets('календарь: занятие открывает лист занятия; перетаскивание '
        'не меняет расписание', (tester) async {
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (_) => '/calendar',
        files: false,
      );
      await tester.runAsync(
        () =>
            container.read(calendarRepositoryProvider).ensureSystemCalendars(),
      );
      await tester.pumpAndSettle();
      expect(find.text('Математический анализ'), findsWidgets);
      await tester.tap(find.text('Математический анализ').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lesson-when')), findsOneWidget);
      // Действия календаря над занятием молча ничего не делают.
      final items = container
          .read(
            calendarItemsProvider(
              DateSpan(DateTime.utc(2026, 10, 5), DateTime.utc(2026, 10, 6)),
            ),
          )
          .requireValue
          .whereType<StudyEventItem>()
          .toList();
      final ctx = tester.element(find.byKey(const Key('lesson-when')));
      final actions = CalendarActions(
        ctx,
        tester.element(find.byType(LessonSheet)) as WidgetRef,
      );
      await actions.move(items.first, 1, 30);
      await actions.resize(items.first, 120);
      expect(
        container
            .read(studyDataProvider)
            .requireValue
            .slotById[demo.mathMon]!
            .number,
        1,
      );
    });
  });

  group('нажатие на «Был на паре?»', () {
    test('разбор payload', () {
      expect(
        parseReminderPayload('study:slot|2026-10-05'),
        const StudyTarget('slot', '2026-10-05'),
      );
      expect(const StudyTarget('a', 'b'), const StudyTarget('a', 'b'));
      expect(
        const StudyTarget('a', 'b').hashCode,
        const StudyTarget('a', 'b').hashCode,
      );
      for (final bad in ['study:', 'study:slot', 'study:slot|', 'study:|d']) {
        expect(parseReminderPayload(bad), isNull, reason: bad);
      }
    });

    testWidgets('нажатие открывает лист занятия с отметкой', (tester) async {
      final (container, demo) = await pumpStudyDemo(tester, files: false);
      container
          .read(reminderTapsProvider)
          .add('study:${demo.mathMon}|2026-10-05');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lesson-when')), findsOneWidget);
      await tapKey(tester, 'mark-present');
      expect(
        container
            .read(studyDataProvider)
            .requireValue
            .markBySlotDate[(demo.mathMon, '2026-10-05')]
            ?.status,
        AttendanceStatus.present,
      );
    });
  });

  group('контекст ИИ «Учёба»', () {
    const source = StudyContextSource();

    test('описание источника', () {
      expect(source.id, 'study');
      expect(source.label, 'Учёба');
      expect(source.sensitive, isFalse);
      expect(source.description, isNotEmpty);
      expect(source.defaultFilter, {'period': 'week'});
      expect(source.filters.single.options.keys, ['day', 'week', 'month']);
      expect(source.summary(const {'period': 'day'}), 'расписание на сегодня');
      expect(
        source.summary(const {'period': 'month'}),
        'расписание на 30 дней',
      );
      expect(source.summary(const {}), 'расписание на 7 дней');
    });

    testWidgets('нет семестров — нет строк', (tester) async {
      final container = await pumpStudy(tester);
      final env = container.read(contextEnvProvider)();
      expect(
        await tester.runAsync(() => source.lines(env, source.defaultFilter)),
        isEmpty,
      );
    });

    testWidgets('долги, пропуски и расписание на неделю', (tester) async {
      final container = await pumpStudy(tester, seed: true);
      final env = container.read(contextEnvProvider)();
      final lines = (await tester.runAsync(
        () =>
            StudyContextSource(holidays: () async => HolidayCalendar.empty())
                .lines(env, source.defaultFilter),
      ))!;
      // Просроченный долг первым, с заметкой.
      expect(
        lines.first,
        startsWith('- Долг · Математический анализ · ЛР 1 (лабораторная)'),
      );
      expect(lines.first, contains('срок 2026-09-30'));
      expect(lines.first, contains('просрочен'));
      expect(lines.first, contains('заметка: Предел'));
      expect(lines.where((l) => l.startsWith('- Долг')), hasLength(3));
      expect(
        lines.firstWhere((l) => l.contains('Пропуски · Математический анализ')),
        allOf(
          contains('преподаватель Иванов Иван Иванович'),
          contains('пропустил 1'),
          contains('лимит 4'),
        ),
      );
      expect(
        lines.firstWhere((l) => l.startsWith('- Пропуски · Программирование')),
        contains('лимит не задан'),
      );
      final monday = lines.firstWhere((l) => l.startsWith('- 2026-10-05 Пн'));
      expect(
        monday,
        contains('08:30–10:00 Математический анализ (лекция, к1 28)'),
      );
      final thursday = lines.firstWhere((l) => l.startsWith('- 2026-10-08 Чт'));
      expect(thursday, contains('особый день: Подготовка к олимпиаде'));
      expect(thursday, isNot(contains('Математический анализ')));
      // Выходные без занятий не попадают.
      expect(lines.any((l) => l.startsWith('- 2026-10-10')), isFalse);
    });

    testWidgets('отмена, перенос и праздник; периоды', (tester) async {
      late StudyDemo demo;
      final container = await pumpStudy(
        tester,
        seedWith: (c) async {
          demo = await seedStudyDemo(c);
          final repo = c.read(studyRepositoryProvider);
          await repo.saveOverride(
            ClassOverride(
              slotId: demo.mathMon,
              date: '2026-10-05',
              action: OverrideAction.cancel,
            ),
          );
          await repo.saveOverride(
            ClassOverride(
              slotId: demo.mathMon,
              date: '2026-10-12',
              action: OverrideAction.move,
              newDate: '2026-10-14',
            ),
          );
        },
      );
      final env = container.read(contextEnvProvider)();
      final week = (await tester.runAsync(
        () => source.lines(env, {'period': 'week'}),
      ))!;
      expect(
        week.firstWhere((l) => l.startsWith('- 2026-10-05')),
        contains('— отменена'),
      );
      final day = (await tester.runAsync(
        () => source.lines(env, {'period': 'day'}),
      ))!;
      expect(day.where((l) => l.startsWith('- 2026-10-')), hasLength(1));
      final month = (await tester.runAsync(
        () => source.lines(env, {'period': 'month'}),
      ))!;
      expect(
        month.firstWhere((l) => l.startsWith('- 2026-10-12')),
        contains('— перенесена на 2026-10-14'),
      );
      expect(
        month.firstWhere((l) => l.startsWith('- 2026-10-14')),
        contains('— перенос с 2026-10-12'),
      );
      // Праздник (31 декабря) через встроенный файл праздников.
      final late = ContextEnv(
        now: DateTime.utc(2026, 12, 28, 9),
        zone: env.zone,
        readRows: env.readRows,
      );
      final holidays = (await tester.runAsync(
        () => const StudyContextSource().lines(late, {'period': 'week'}),
      ))!;
      expect(
        holidays.firstWhere((l) => l.startsWith('- 2026-12-31')),
        contains('праздник: Перенос выходного с 4 января'),
      );
    });

    testWidgets('все семестры в архиве — нет строк', (tester) async {
      late StudyDemo demo;
      final container = await pumpStudy(
        tester,
        seedWith: (c) async {
          demo = await seedStudyDemo(c);
          await c
              .read(studyRepositoryProvider)
              .setSemesterArchived(demo.semester, archived: true);
        },
      );
      final env = container.read(contextEnvProvider)();
      expect(await tester.runAsync(() => source.lines(env, {})), isEmpty);
    });
  });
}
