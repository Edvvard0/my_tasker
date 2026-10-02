import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/calendar_blocks.dart';

import '../support/pump_app.dart';
import '../support/stage2_env.dart';

Future<void> _openMode(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(const Key('calendar-view-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  group('раскладка пересечений', () {
    // Четыре блока одновременно.
    final four = [for (var i = 0; i < 4; i++) (start: 600 + i * 5, end: 700)];

    test('все помещаются — без плашки', () {
      final layout = layoutLanes(four, maxLanes: 4);
      expect(layout.overflows, isEmpty);
      expect(layout.placements.every((p) => !p.hidden && p.lanes == 4), isTrue);
    });

    test('cap = 2: два блока и «+2» на последней колонке', () {
      final layout = layoutLanes(four, maxLanes: 2);
      expect(layout.placements.where((p) => p.hidden), hasLength(2));
      expect(layout.placements.where((p) => !p.hidden).map((p) => p.lane), [
        0,
        1,
      ]);
      expect(layout.placements.every((p) => p.lanes == 2), isTrue);
      final o = layout.overflows.single;
      expect(o.count, 2);
      expect(layout.placements[o.anchor].lane, 1);
      expect(o.startMinute, 610);
    });

    test('cap = 1: один блок и «+3»', () {
      final layout = layoutLanes(four, maxLanes: 1);
      expect(layout.placements.where((p) => !p.hidden), hasLength(1));
      expect(layout.overflows.single.count, 3);
      expect(layout.placements.every((p) => p.lanes == 1), isTrue);
    });

    test('независимые кластеры считаются отдельно', () {
      final layout = layoutLanes([
        (start: 600, end: 660),
        (start: 610, end: 660),
        (start: 620, end: 660),
        (start: 900, end: 960),
      ], maxLanes: 2);
      expect(layout.overflows, hasLength(1));
      expect(layout.placements.last.lanes, 1);
      expect(layout.placements.last.hidden, isFalse);
    });
  });

  group('укорочение по границе слова', () {
    const style = TextStyle(fontSize: 13);
    const scaler = TextScaler.noScaling;

    testWidgets('помещается — без изменений', (tester) async {
      expect(ellipsizeOnWords('Созвон', style, 500, scaler), 'Созвон');
    });

    testWidgets('не помещается — слова отрезаются целиком, слово не рвётся', (
      tester,
    ) async {
      const text = 'Подготовить отчёт для клиента';
      final cut = ellipsizeOnWords(text, style, 200, scaler);
      expect(cut, endsWith('…'));
      final words = cut.substring(0, cut.length - 1).split(' ');
      final original = text.split(' ');
      expect(words, original.take(words.length).toList());
      expect(words.length, lessThan(original.length));
    });

    testWidgets('первое слово не помещается — текст как есть', (tester) async {
      expect(ellipsizeOnWords('Матанализ', style, 10, scaler), 'Матанализ');
    });

    testWidgets('самое длинное слово: влезает или нет', (tester) async {
      expect(longestWordFits('аб вг', style, 100, scaler), isTrue);
      expect(longestWordFits('Матанализ вг', style, 20, scaler), isFalse);
    });
  });

  group('неделя на телефоне', () {
    testWidgets('по умолчанию «Расписание», неделя — компактные блоки', (
      tester,
    ) async {
      await pumpStage2(
        tester,
        seed: true,
        seedWith: seedOverlaps,
        location: '/calendar',
      );
      expect(find.byKey(const Key('schedule-list')), findsOneWidget);
      await _openMode(tester, 'view-week');
      // 7 колонок: блоки уже compactBlockWidth, названия — одна строка.
      final blocks = find.byWidgetPredicate(
        (w) => w.key.toString().contains('event-block-'),
      );
      expect(blocks, findsWidgets);
      for (final e in blocks.evaluate()) {
        expect(
          (e.renderObject! as RenderBox).size.width,
          lessThan(compactBlockWidth),
        );
        final texts = find.descendant(
          of: find.byElementPredicate((x) => x == e),
          matching: find.byType(Text),
        );
        for (final t in tester.widgetList<Text>(texts)) {
          expect(t.maxLines, 1, reason: 'компактный блок — одна строка');
          expect(t.softWrap, isFalse, reason: 'слова не рвутся');
        }
      }
      // Среда: четыре пересекающихся события — один блок и «+3».
      expect(find.text('+3'), findsOneWidget);
    });

    testWidgets('«+N» ведёт в день', (tester) async {
      await pumpStage2(
        tester,
        seed: true,
        seedWith: seedOverlaps,
        location: '/calendar',
      );
      await _openMode(tester, 'view-week');
      await tester.tap(find.text('+3'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('grid-day-2026-09-30')), findsOneWidget);
      expect(find.byKey(const Key('grid-day-2026-10-01')), findsNothing);
    });

    testWidgets('3 дня: колонка ~100 px — одна колонка и «+3»', (tester) async {
      await pumpStage2(
        tester,
        seed: true,
        seedWith: seedOverlaps,
        location: '/calendar',
      );
      await _openMode(tester, 'view-threeDays');
      expect(find.text('+3'), findsOneWidget);
    });
  });

  group('бэклог на десктопе', () {
    testWidgets('1440 px: панель 240 px, сворачивается и разворачивается', (
      tester,
    ) async {
      await pumpStage2(
        tester,
        seed: true,
        location: '/calendar',
        size: desktopSize,
      );
      expect(tester.getSize(find.byKey(const Key('backlog-panel'))).width, 240);
      await tester.tap(find.byKey(const Key('backlog-collapse')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('backlog-panel')), findsNothing);
      expect(find.byKey(const Key('backlog-rail')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('backlog-rail-count'))).data,
        '5',
      );
      await tester.tap(find.byKey(const Key('backlog-expand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('backlog-panel')), findsOneWidget);
    });

    testWidgets('шире 1440 px: панель 300 px', (tester) async {
      await pumpStage2(
        tester,
        seed: true,
        location: '/calendar',
        size: const Size(1800, 900),
      );
      expect(tester.getSize(find.byKey(const Key('backlog-panel'))).width, 300);
    });
  });

  testWidgets('провайдер событий отдаёт пересекающиеся события', (
    tester,
  ) async {
    final c = await pumpStage2(tester, seed: true, seedWith: seedOverlaps);
    final events = (await tester.runAsync(
      () => c.read(eventsProvider.future),
    ))!;
    expect(events.where((e) => e.title == 'Обед с Ромой'), hasLength(1));
  });
}
