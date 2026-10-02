import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';

import '../support/stage2_env.dart';

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
  await _settle(tester);
}

Future<List<CalendarLayer>> _layers(
  WidgetTester tester,
  ProviderContainer c,
) async =>
    (await tester.runAsync(() => c.read(calendarLayersProvider.future)))!;

Future<String> _createLayer(
  WidgetTester tester,
  ProviderContainer c,
  String name,
) async {
  final id = (await tester.runAsync(
    () => c.read(calendarRepositoryProvider).createLayer(name: name),
  ))!;
  await _settle(tester);
  return id;
}

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
  const route = '/calendar/layers';

  testWidgets('системные слои: список, замки, нет удаления', (tester) async {
    final c = await pumpStage2(tester, location: route);
    expect(find.byKey(const Key('layers-list')), findsOneWidget);
    for (final key in ['personal', 'work', 'study', 'tasks', 'holidays_ru']) {
      expect(find.byKey(Key('layer-${systemCalendarId(key)}')), findsOneWidget);
      expect(
        find.byKey(Key('layer-delete-${systemCalendarId(key)}')),
        findsNothing,
      );
    }
    expect(find.text('Показывает задачи со сроком'), findsOneWidget);
    expect(find.text('Праздники и выходные РФ'), findsOneWidget);
    expect((await _layers(tester, c)).length, 5);
  });

  testWidgets('видимость и порядок сохраняются', (tester) async {
    final c = await pumpStage2(tester, location: route);
    final id = systemCalendarId('work');
    await _tap(tester, 'layer-visible-$id');
    expect(
      (await _layers(tester, c)).firstWhere((l) => l.id == id).visible,
      false,
    );
    final before = [for (final l in await _layers(tester, c)) l.id];
    final index = before.indexOf(id);
    await _tap(tester, 'layer-down-$id');
    final after = [for (final l in await _layers(tester, c)) l.id];
    expect(after.indexOf(id), index + 1);
    await _tap(tester, 'layer-up-$id');
    expect([for (final l in await _layers(tester, c)) l.id], before);
  });

  testWidgets('новый слой: создание, ошибка пустого имени, переименование', (
    tester,
  ) async {
    final c = await pumpStage2(tester, location: route);
    await _tap(tester, 'layer-new-add');
    expect(find.text('Введите название'), findsNothing);
    expect(find.byType(InputDecorator), findsWidgets);
    await tester.enterText(find.byKey(const Key('layer-new-field')), 'Спорт');
    await _tap(tester, 'layer-new-add');
    final sport = (await _layers(
      tester,
      c,
    )).firstWhere((l) => l.name == 'Спорт');
    expect(find.text('Мой календарь'), findsOneWidget);

    await _tap(tester, 'layer-rename-${sport.id}');
    await tester.enterText(find.byKey(const Key('layer-rename-field')), 'Зал');
    await _tap(tester, 'layer-rename-ok');
    expect((await _layers(tester, c)).any((l) => l.name == 'Зал'), isTrue);

    await _tap(tester, 'layer-rename-${sport.id}');
    await tester.enterText(find.byKey(const Key('layer-rename-field')), '  ');
    await _tap(tester, 'layer-rename-ok');
    expect((await _layers(tester, c)).any((l) => l.name == 'Зал'), isTrue);
  });

  testWidgets('удаление пустого слоя', (tester) async {
    final c = await pumpStage2(tester, location: route);
    final id = await _createLayer(tester, c, 'Пустой');
    await tester.pumpAndSettle();
    await _tap(tester, 'layer-delete-$id');
    expect(find.textContaining('Слой пуст'), findsOneWidget);
    expect(find.byKey(const Key('layer-delete-move')), findsNothing);
    await _tap(tester, 'layer-delete-cancel');
    expect((await _layers(tester, c)).any((l) => l.id == id), isTrue);
    await _tap(tester, 'layer-delete-$id');
    await _tap(tester, 'layer-delete-all');
    expect((await _layers(tester, c)).any((l) => l.id == id), isFalse);
  });

  testWidgets('удаление слоя с событиями: перенести или удалить вместе', (
    tester,
  ) async {
    final c = await pumpStage2(tester, location: route);
    final id = await _createLayer(tester, c, 'Хобби');
    final repo = c.read(calendarRepositoryProvider);
    for (final title in ['А', 'Б']) {
      await tester.runAsync(
        () => repo.createEvent(
          EventEntity(
            id: repo.newEventId(),
            calendarId: id,
            title: title,
            allDay: true,
            startDate: DateTime.utc(2026, 10),
            endDate: DateTime.utc(2026, 10),
          ),
        ),
      );
      await _settle(tester);
    }
    await _tap(tester, 'layer-delete-$id');
    expect(find.textContaining('2 события'), findsOneWidget);
    await _tap(tester, 'layer-delete-move');
    final events = await _eventsNow(tester, c);
    expect(events, hasLength(2));
    expect(events.every((e) => e.calendarId != id), isTrue);
    // Второй слой: «удалить вместе».
    final id2 = await _createLayer(tester, c, 'Кино');
    await tester.runAsync(() async {
      final repo = c.read(calendarRepositoryProvider);
      await repo.createEvent(
        EventEntity(
          id: repo.newEventId(),
          calendarId: id2,
          title: 'Фильм',
          allDay: true,
          startDate: DateTime.utc(2026, 10, 2),
          endDate: DateTime.utc(2026, 10, 2),
        ),
      );
    });
    await tester.pumpAndSettle();
    await _tap(tester, 'layer-delete-$id2');
    expect(find.textContaining('1 событие'), findsOneWidget);
    await _tap(tester, 'layer-delete-all');
    final after = await _eventsNow(tester, c);
    expect(after.where((e) => e.title == 'Фильм'), isEmpty);
  });

  testWidgets('лист «Слои» календаря: галочки и переход к управлению', (
    tester,
  ) async {
    final c = await pumpStage2(tester, location: '/calendar', seed: true);
    await tester.tap(find.byKey(const Key('calendar-layers')));
    await tester.pumpAndSettle();
    final id = systemCalendarId('study');
    await _tap(tester, 'layer-check-$id');
    expect(
      (await _layers(tester, c)).firstWhere((l) => l.id == id).visible,
      false,
    );
    expect(find.text('Матанализ'), findsNothing);
    await _tap(tester, 'layers-manage');
    expect(find.byKey(const Key('layers-list')), findsOneWidget);
  });

  testWidgets('возврат назад ведёт в календарь', (tester) async {
    await pumpStage2(tester, location: route);
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-title')), findsOneWidget);
  });
}
