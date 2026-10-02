import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_view.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../support/pump_app.dart';
import '../support/stage2_env.dart';

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

String _title(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('calendar-title'))).data!;

Future<List<EventEntity>> _events(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(() => c.read(eventsProvider.future)))!;

Future<List<TaskEntity>> _tasks(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(() => c.read(tasksProvider.future)))!;

Future<EventEntity> _event(
  WidgetTester tester,
  ProviderContainer c,
  String title,
) async => (await _events(tester, c)).firstWhere((e) => e.title == title);

void main() {
  group('телефон', () {
    testWidgets('пусто: расписание без событий', (tester) async {
      await pumpStage2(tester, location: '/calendar');
      expect(find.byKey(const Key('schedule-empty')), findsOneWidget);
      expect(_title(tester), 'Сентябрь');
      expect(find.byKey(const Key('week-badge')), findsNothing);
      expect(find.byKey(const Key('calendar-prev')), findsNothing);
    });

    testWidgets('данные: расписание, бейдж недели, слои и настройки', (
      tester,
    ) async {
      await pumpStage2(tester, location: '/calendar', seed: true);
      expect(find.byKey(const Key('schedule-list')), findsOneWidget);
      expect(find.text('Созвон Creora'), findsWidgets);
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const Key('week-badge')),
                matching: find.byType(Text),
              ),
            )
            .data,
        'Нечётная',
      );
      await tester.tap(find.byKey(const Key('calendar-layers')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('layers-manage')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cycle-card')), findsOneWidget);
    });

    testWidgets('меню видов: день, 3 дня, неделя, месяц, расписание', (
      tester,
    ) async {
      await pumpStage2(tester, location: '/calendar', seed: true);
      Future<void> pick(CalendarViewMode m) async {
        await tester.tap(find.byKey(const Key('calendar-view-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('view-${m.name}')));
        await tester.pumpAndSettle();
      }

      await pick(CalendarViewMode.day);
      expect(_title(tester), 'Ср, 30 сентября');
      expect(find.byKey(const Key('grid-scroll')), findsOneWidget);
      expect(find.byKey(const Key('backlog-peek')), findsOneWidget);
      await pick(CalendarViewMode.threeDays);
      expect(_title(tester), '30 сент.–2 окт.');
      await pick(CalendarViewMode.week);
      expect(_title(tester), '28 сент. – 4 окт. 2026');
      await pick(CalendarViewMode.month);
      expect(_title(tester), 'Сентябрь 2026');
      expect(find.byKey(const Key('backlog-peek')), findsNothing);
      await pick(CalendarViewMode.schedule);
      expect(find.byKey(const Key('schedule-list')), findsOneWidget);
    });

    testWidgets('свайп по сетке листает период, «Сегодня» возвращает', (
      tester,
    ) async {
      final c = await pumpStage2(tester, location: '/calendar', seed: true);
      unawaited(
        c.read(calendarViewProvider.notifier).setMode(CalendarViewMode.week),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-today')), findsNothing);
      await tester.fling(
        find.byKey(const Key('grid-scroll')),
        const Offset(-300, 0),
        1500,
      );
      await tester.pumpAndSettle();
      expect(_title(tester), '5 – 11 окт. 2026');
      await tester.fling(
        find.byKey(const Key('grid-scroll')),
        const Offset(300, 0),
        1500,
      );
      await tester.pumpAndSettle();
      await tester.fling(
        find.byKey(const Key('grid-scroll')),
        const Offset(300, 0),
        1500,
      );
      await tester.pumpAndSettle();
      expect(_title(tester), '21 – 27 сент. 2026');
      await _tap(tester, 'calendar-today');
      expect(_title(tester), '28 сент. – 4 окт. 2026');
    });

    testWidgets('месяц: выбор дня показывает его события', (tester) async {
      final c = await pumpStage2(tester, location: '/calendar', seed: true);
      unawaited(
        c.read(calendarViewProvider.notifier).setMode(CalendarViewMode.month),
      );
      await tester.pumpAndSettle();
      expect(find.text('Созвон Creora'), findsWidgets);
      await _tap(tester, 'month-cell-2026-09-26');
      expect(find.byKey(const Key('month-day-empty')), findsOneWidget);
      await _tap(tester, 'month-cell-2026-10-02');
      expect(find.text('Спринт: планирование'), findsWidgets);
    });

    testWidgets('«Без даты»: пик раскрывается, задача открывается', (
      tester,
    ) async {
      final c = await pumpStage2(tester, location: '/calendar', seed: true);
      unawaited(
        c.read(calendarViewProvider.notifier).setMode(CalendarViewMode.week),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Без даты · '), findsOneWidget);
      await _tap(tester, 'backlog-peek');
      expect(find.byKey(const Key('backlog-list')), findsOneWidget);
      await tester.tap(find.text('Купить кроссовки'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-title')), findsOneWidget);
    });

    testWidgets('тап по пустому слоту создаёт событие с этим временем', (
      tester,
    ) async {
      final c = await pumpStage2(tester, location: '/calendar');
      unawaited(
        c.read(calendarViewProvider.notifier).setMode(CalendarViewMode.day),
      );
      await tester.pumpAndSettle();
      final grid = tester.getTopLeft(find.byKey(const Key('grid-scroll')));
      await tester.tapAt(grid + const Offset(200, 150));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-title')), findsOneWidget);
    });

    testWidgets('тап по событию — карточка; «Изменить» открывает редактор', (
      tester,
    ) async {
      await pumpStage2(tester, location: '/calendar', seed: true);
      await tester.tap(find.text('Созвон Creora').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('details-edit')), findsOneWidget);
      expect(find.text('Zoom'), findsWidgets);
      await tester.tap(find.byKey(const Key('details-edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-title')), findsOneWidget);
    });

    testWidgets('ошибка чтения: карточка и «Повторить»', (tester) async {
      await pumpStage2(
        tester,
        location: '/calendar',
        overrides: [
          calendarDataProvider.overrideWithValue(
            const AsyncValue<CalendarData>.error('boom', StackTrace.empty),
          ),
        ],
      );
      expect(find.byKey(const Key('calendar-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('calendar-retry')));
      await tester.pump();
    });
  });

  group('праздники', () {
    testWidgets('ноябрь 2026: праздник в неделе и в расписании', (
      tester,
    ) async {
      final c = await pumpStage2(
        tester,
        location: '/calendar',
        seed: true,
        overrides: [
          holidayCalendarProvider.overrideWith(
            (ref) => HolidayCalendar.fromJsonString(
              File(holidaysAssetPath).readAsStringSync(),
            ),
          ),
        ],
      );
      final view = c.read(calendarViewProvider.notifier)
        ..goTo(DateTime.utc(2026, 11, 4));
      unawaited(view.setMode(CalendarViewMode.week));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('holiday-2026-11-04')), findsOneWidget);
      unawaited(view.setMode(CalendarViewMode.schedule));
      await tester.pumpAndSettle();
      expect(find.textContaining('единства'), findsWidgets);
    });
  });

  group('десктоп', () {
    Future<ProviderContainer> desktop(WidgetTester tester) => pumpStage2(
      tester,
      size: expandedSize,
      location: '/calendar',
      seed: true,
    );

    testWidgets('неделя по умолчанию, шаги и «Сегодня», бэклог справа', (
      tester,
    ) async {
      await desktop(tester);
      expect(_title(tester), '28 сент. – 4 окт. 2026');
      expect(find.byKey(const Key('backlog-panel')), findsOneWidget);
      expect(find.textContaining('Без даты · '), findsOneWidget);
      await _tap(tester, 'calendar-next');
      expect(_title(tester), '5 – 11 окт. 2026');
      await _tap(tester, 'calendar-prev');
      await _tap(tester, 'calendar-prev');
      expect(_title(tester), '21 – 27 сент. 2026');
      await _tap(tester, 'calendar-today');
      expect(_title(tester), '28 сент. – 4 окт. 2026');
      expect(find.byKey(const Key('now-line')), findsOneWidget);
    });

    testWidgets('сегменты видов и переход из месяца в день', (tester) async {
      await desktop(tester);
      await _tap(tester, 'view-month');
      expect(find.byKey(const Key('backlog-panel')), findsNothing);
      await _tap(tester, 'month-cell-2026-10-02');
      expect(_title(tester), 'Пт, 2 октября');
      await _tap(tester, 'view-threeDays');
      expect(find.byKey(const Key('grid-scroll')), findsOneWidget);
      await _tap(tester, 'view-schedule');
      expect(find.byKey(const Key('schedule-list')), findsOneWidget);
      await _tap(tester, 'view-week');
      await tester.tap(find.byKey(const Key('day-number-2026-10-02')));
      await tester.pumpAndSettle();
      expect(_title(tester), 'Пт, 2 октября');
    });

    testWidgets('перенос события перетаскиванием и «Отменить»', (tester) async {
      final c = await desktop(tester);
      final before = await _event(tester, c, 'Созвон Creora');
      final byPrefix = find.byWidgetPredicate(
        (w) =>
            w.key is Key &&
            '${w.key}'.contains('grid-item-${before.id}') &&
            '${w.key}'.contains('2026-09-30'),
      );
      expect(byPrefix, findsOneWidget);
      final handle = find.descendant(
        of: byPrefix,
        matching: find.byKey(const Key('grid-move-handle')),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(find.byKey(const Key('drag-overlay')), findsOneWidget);
      await gesture.moveBy(const Offset(0, 60));
      await gesture.up();
      await tester.pumpAndSettle();
      final after = await _event(tester, c, 'Созвон Creora');
      expect(
        after.startAt!.difference(before.startAt!).inMinutes,
        greaterThanOrEqualTo(60),
      );
      expect(find.textContaining('Перенесено на'), findsOneWidget);
      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(
        (await _event(tester, c, 'Созвон Creora')).startAt,
        before.startAt,
      );
    });

    testWidgets('растяжение нижнего края меняет длительность', (tester) async {
      final c = await desktop(tester);
      final before = await _event(tester, c, 'Тренировка');
      final block = find.byWidgetPredicate(
        (w) =>
            '${w.key}'.contains('grid-item-${before.id}') &&
            '${w.key}'.contains('2026-09-30'),
      );
      final handle = find.descendant(
        of: block,
        matching: find.byKey(const Key('grid-resize-handle')),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 30));
      await gesture.moveBy(const Offset(0, 60));
      await gesture.up();
      await tester.pumpAndSettle();
      final after = await _event(tester, c, 'Тренировка');
      expect(
        after.endAt!.difference(after.startAt!).inMinutes,
        greaterThan(60),
      );
    });

    testWidgets('повторяющееся: диалог области, «Только это» — override', (
      tester,
    ) async {
      final c = await desktop(tester);
      final master = await _event(tester, c, 'Английский');
      final block = find.byWidgetPredicate(
        (w) =>
            '${w.key}'.contains('grid-item-${master.id}') &&
            !'${w.key}'.contains('2026-09-30') &&
            '${w.key}'.contains('2026-10-02'),
      );
      final handle = find.descendant(
        of: block,
        matching: find.byKey(const Key('grid-move-handle')),
      );
      await tester.ensureVisible(handle);
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 30));
      await gesture.moveBy(const Offset(0, 60));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scope-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('scope-only')));
      await tester.pumpAndSettle();
      final overrides = await tester.runAsync(
        () => c.read(calendarRepositoryProvider).overridesOf(master.id),
      );
      expect(overrides, hasLength(1));
    });

    testWidgets('повторяющееся: закрытие диалога не меняет ничего', (
      tester,
    ) async {
      final c = await desktop(tester);
      final master = await _event(tester, c, 'Английский');
      final block = find.byWidgetPredicate(
        (w) =>
            '${w.key}'.contains('grid-item-${master.id}') &&
            '${w.key}'.contains('2026-10-02'),
      );
      final handle = find.descendant(
        of: block,
        matching: find.byKey(const Key('grid-move-handle')),
      );
      await tester.ensureVisible(handle);
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 30));
      await gesture.moveBy(const Offset(0, 60));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scope-dialog')), findsNothing);
      expect(await _event(tester, c, 'Английский'), master);
    });

    testWidgets('задача из бэклога падает в сетку и получает время', (
      tester,
    ) async {
      final c = await desktop(tester);
      final task = (await _tasks(
        tester,
        c,
      )).firstWhere((t) => t.title == 'Купить кроссовки');
      final drag = find.byKey(Key('backlog-drag-${task.id}'));
      final target = tester.getTopLeft(find.byKey(const Key('grid-scroll')));
      final gesture = await tester.startGesture(
        tester.getCenter(drag),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      await gesture.moveTo(target + const Offset(400, 300));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      final after = (await _tasks(
        tester,
        c,
      )).firstWhere((t) => t.id == task.id);
      expect(after.due.hasTime, isTrue);
      expect(after.durationMinutes, 60);
      expect(after.status, TaskStatus.todo);
      expect(find.textContaining('Назначено на'), findsOneWidget);
    });

    testWidgets('задача из бэклога в полосу «весь день»: только дата', (
      tester,
    ) async {
      final c = await desktop(tester);
      // Нужна полоса: добавим событие на весь день.
      await tester.runAsync(
        () =>
            addAllDayEvent(c, title: 'Отпуск', date: DateTime.utc(2026, 9, 30)),
      );
      await tester.pumpAndSettle();
      final task = (await _tasks(
        tester,
        c,
      )).firstWhere((t) => t.title == 'Разобрать почту');
      final drag = find.byKey(Key('backlog-drag-${task.id}'));
      final cell = find.byKey(const Key('allday-cell-2026-10-01'));
      final gesture = await tester.startGesture(
        tester.getCenter(drag),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(cell));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      final after = (await _tasks(
        tester,
        c,
      )).firstWhere((t) => t.id == task.id);
      expect(after.due.isNone, isFalse);
      expect(after.due.hasTime, isFalse);
    });

    testWidgets('«+» в бэклоге открывает редактор задачи', (tester) async {
      await desktop(tester);
      await _tap(tester, 'backlog-add');
      expect(find.byKey(const Key('task-title')), findsOneWidget);
    });

    testWidgets('окно не превращает мелкий блок в ошибку (узкое окно)', (
      tester,
    ) async {
      await pumpStage2(
        tester,
        size: mediumSize,
        location: '/calendar',
        seed: true,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
