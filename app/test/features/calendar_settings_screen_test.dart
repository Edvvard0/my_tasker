import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';

import '../support/fake_reminder_scheduler.dart';
import '../support/stage2_env.dart';

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
  await _settle(tester);
}

Future<WeekCycle?> _cycle(WidgetTester tester, ProviderContainer c) =>
    tester.runAsync<WeekCycle?>(() => c.read(weekCycleProvider.future));

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

Future<List<EventEntity>> _eventsNow(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(
  () async => [
    for (final r in await c.read(syncStoreProvider).visibleRows('events'))
      EventEntity.fromRow(r),
  ],
))!;

/// Drift-запросы идут в реальном времени, а виджеты — в поддельном: по
/// очереди прокачиваем оба, пока запись и перерисовка не закончатся.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  const route = '/calendar/settings';

  testWidgets('цикл выключен: переключатель включает чёт/нечёт', (
    tester,
  ) async {
    final c = await pumpStage2(tester, location: route);
    expect(
      _text(tester, 'cycle-status'),
      'Выключено: каждая неделя одинаковая.',
    );
    expect(find.byKey(const Key('cycle-skip')), findsNothing);
    await _tap(tester, 'cycle-switch');
    final cycle = (await _cycle(tester, c))!;
    expect(cycle.length, 2);
    expect(_text(tester, 'cycle-status'), startsWith('Сейчас: '));
    await _tap(tester, 'cycle-switch');
    expect(await _cycle(tester, c), isNull);
  });

  testWidgets('длина цикла и «Сейчас идёт неделя»', (tester) async {
    final c = await pumpStage2(tester, location: route, seed: true);
    expect(_text(tester, 'cycle-status'), 'Сейчас: нечётная неделя');
    await _tap(tester, 'cycle-now-2');
    expect(_text(tester, 'cycle-status'), 'Сейчас: чётная неделя');
    await _tap(tester, 'cycle-length-3');
    expect((await _cycle(tester, c))!.length, 3);
    expect(find.byKey(const Key('cycle-now-3')), findsOneWidget);
    await _tap(tester, 'cycle-now-3');
    expect(_text(tester, 'cycle-status'), 'Сейчас: неделя 3 неделя');
    expect(find.byKey(const Key('cycle-week1')), findsOneWidget);
  });

  testWidgets('«Пропустить неделю»: отмена занятий и «Отменить»', (
    tester,
  ) async {
    final c = await pumpStage2(tester, location: route, seed: true);
    await _tap(tester, 'cycle-skip');
    await _tap(tester, 'skip-this');
    expect(find.textContaining('Пропущено занятий: '), findsOneWidget);
    final events = await _eventsNow(tester, c);
    final english = events.firstWhere((e) => e.title == 'Английский');
    Future<int> cancelled() async => (await tester.runAsync(
      () => c.read(calendarRepositoryProvider).overridesOf(english.id),
    ))!.where((o) => o.cancelled).length;
    expect(await cancelled(), greaterThan(0));
    await tester.tap(find.text('Отменить'));
    await tester.pumpAndSettle();
    expect(await cancelled(), 0);
  });

  testWidgets('«Пропустить неделю» без серий на неделе — пояснение', (
    tester,
  ) async {
    await pumpStage2(
      tester,
      location: route,
      seedWith: (c) async {
        await c
            .read(calendarSettingsRepositoryProvider)
            .writeWeekCycle(
              WeekCycle(length: 2, week1Start: DateTime.utc(2026, 9, 28)),
            );
      },
    );
    await _tap(tester, 'cycle-skip');
    await _tap(tester, 'skip-next');
    expect(
      find.text('На этой неделе нет повторяющихся событий'),
      findsOneWidget,
    );
  });

  testWidgets('«Сдвинуть чётность»: подтверждение, счёт серий, отмена', (
    tester,
  ) async {
    final c = await pumpStage2(tester, location: route, seed: true);
    await _tap(tester, 'cycle-shift');
    expect(find.byKey(const Key('shift-dialog')), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect((await _cycle(tester, c))!.shifts, isEmpty);
    await _tap(tester, 'cycle-shift');
    await _tap(tester, 'shift-ok');
    expect(find.textContaining('Сдвинуто серий: '), findsOneWidget);
    expect((await _cycle(tester, c))!.shifts, hasLength(1));
  });

  testWidgets('время напоминаний «весь день» сохраняется', (tester) async {
    final c = await pumpStage2(tester, location: route);
    await _tap(tester, 'allday-reminder-1800');
    final time = await tester.runAsync(
      () => c.read(allDayReminderTimeProvider.future),
    );
    expect(time, '18:00');
  });

  testWidgets('разрешение выдано: кнопки нет', (tester) async {
    await pumpStage2(
      tester,
      location: route,
      overrides: [
        reminderSchedulerProvider.overrideWithValue(FakeReminderScheduler()),
      ],
    );
    expect(_text(tester, 'permission-text'), 'Уведомления разрешены.');
    expect(find.byKey(const Key('permission-request')), findsNothing);
  });

  for (final (state, text) in [
    (
      ReminderPermission.notificationsDenied,
      'Уведомления запрещены: напоминания не придут.',
    ),
    (
      ReminderPermission.exactAlarmsDenied,
      'Нет доступа к точным будильникам: напоминания могут опаздывать.',
    ),
  ]) {
    testWidgets('запрет ($state): кнопка «Разрешить» запрашивает доступ', (
      tester,
    ) async {
      final scheduler = FakeReminderScheduler()..state = state;
      await pumpStage2(
        tester,
        location: route,
        overrides: [reminderSchedulerProvider.overrideWithValue(scheduler)],
      );
      expect(_text(tester, 'permission-text'), text);
      await _tap(tester, 'permission-request');
      expect(scheduler.permissionRequests, 1);
      expect(_text(tester, 'permission-text'), 'Уведомления разрешены.');
    });
  }

  testWidgets('ссылка на слои и возврат в календарь', (tester) async {
    await pumpStage2(tester, location: route);
    await _tap(tester, 'settings-layers');
    expect(find.byKey(const Key('layers-list')), findsOneWidget);
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-title')), findsOneWidget);
  });
}
