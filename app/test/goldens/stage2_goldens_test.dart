import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/presentation/event_editor.dart';
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';

import '../support/pump_app.dart';
import '../support/stage2_env.dart';

/// Golden-тесты Этапа 2 на телефоне и десктопе: «Сегодня», «Расписание»,
/// неделя, месяц, редакторы задачи и события. Эталоны — `files/*.png`;
/// обновление: `flutter test --update-goldens test/goldens`.
Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

BuildContext _context(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first);

void main() {
  group('Сегодня', () {
    testWidgets('телефон', (tester) async {
      await pumpStage2(tester, seed: true);
      await _shot(tester, 'today_phone');
    });

    testWidgets('десктоп', (tester) async {
      await pumpStage2(tester, seed: true, size: desktopSize);
      await _shot(tester, 'today_desktop');
    });
  });

  group('Календарь', () {
    testWidgets('расписание (телефон)', (tester) async {
      await pumpStage2(tester, seed: true, location: '/calendar');
      await _shot(tester, 'schedule_phone');
    });

    testWidgets('неделя (телефон)', (tester) async {
      await pumpStage2(tester, seed: true, location: '/calendar');
      await tester.tap(find.byKey(const Key('calendar-view-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-week')));
      await tester.pumpAndSettle();
      await _shot(tester, 'week_phone');
    });

    testWidgets('неделя (десктоп)', (tester) async {
      await pumpStage2(
        tester,
        seed: true,
        location: '/calendar',
        size: desktopSize,
      );
      await _shot(tester, 'week_desktop');
    });

    testWidgets('3 дня с пересечениями (телефон)', (tester) async {
      await pumpStage2(
        tester,
        seed: true,
        seedWith: seedOverlaps,
        location: '/calendar',
      );
      await tester.tap(find.byKey(const Key('calendar-view-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-threeDays')));
      await tester.pumpAndSettle();
      await _shot(tester, 'three_days_phone');
    });

    testWidgets('неделя с пересечениями (телефон)', (tester) async {
      await pumpStage2(
        tester,
        seed: true,
        seedWith: seedOverlaps,
        location: '/calendar',
      );
      await tester.tap(find.byKey(const Key('calendar-view-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-week')));
      await tester.pumpAndSettle();
      await _shot(tester, 'week_overlap_phone');
    });

    testWidgets('неделя с пересечениями (десктоп)', (tester) async {
      await pumpStage2(
        tester,
        seed: true,
        seedWith: seedOverlaps,
        location: '/calendar',
        size: desktopSize,
      );
      await _shot(tester, 'week_overlap_desktop');
    });

    testWidgets('месяц (телефон)', (tester) async {
      await pumpStage2(tester, seed: true, location: '/calendar');
      await tester.tap(find.byKey(const Key('calendar-view-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-month')));
      await tester.pumpAndSettle();
      await _shot(tester, 'month_phone');
    });

    testWidgets('месяц (десктоп)', (tester) async {
      await pumpStage2(
        tester,
        seed: true,
        location: '/calendar',
        size: desktopSize,
      );
      await tester.tap(find.byKey(const Key('view-month')));
      await tester.pumpAndSettle();
      await _shot(tester, 'month_desktop');
    });
  });

  group('Задачи и редакторы', () {
    testWidgets('список задач (телефон)', (tester) async {
      await pumpStage2(tester, seed: true, location: '/calendar/tasks');
      await _shot(tester, 'tasks_phone');
    });

    testWidgets('редактор задачи (телефон)', (tester) async {
      await pumpStage2(tester, seed: true);
      unawaited(showTaskEditor(_context(tester)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('task-title')),
        'Подготовить отчёт',
      );
      await tester.tap(find.byKey(const Key('task-date-tomorrow')));
      await tester.tap(find.byKey(const Key('task-priority-2')));
      await tester.pumpAndSettle();
      await _shot(tester, 'task_editor_phone');
    });

    testWidgets('редактор события с повторением (телефон)', (tester) async {
      await pumpStage2(tester, seed: true, location: '/calendar');
      unawaited(showEventEditor(_context(tester)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('event-title')), 'Матанализ');
      await tester.dragUntilVisible(
        find.byKey(const Key('repeat-freq-weekly')),
        find.byType(SingleChildScrollView).last,
        const Offset(0, -200),
      );
      await tester.tap(find.byKey(const Key('repeat-freq-weekly')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('repeat-cycle-1')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('repeat-end-count')));
      await tester.pumpAndSettle();
      await _shot(tester, 'event_editor_phone');
    });

    testWidgets('редактор события (десктоп)', (tester) async {
      await pumpStage2(
        tester,
        seed: true,
        location: '/calendar',
        size: desktopSize,
      );
      unawaited(showEventEditor(_context(tester)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('event-title')),
        'Созвон Creora',
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'event_editor_desktop');
    });
  });
}
