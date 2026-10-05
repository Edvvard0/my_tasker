import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart'
    show tasksProvider;
import 'package:my_tasker/features/sleep/application/sleep_providers.dart';
import 'package:my_tasker/features/sleep/data/sleep_repository.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';
import 'package:my_tasker/features/sleep/presentation/sleep_entry_sheet.dart';
import 'package:my_tasker/features/sleep/presentation/sleep_widgets.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/sleep_env.dart';

/// Неделя ночей: 1-е…5-е октября (сегодня — 5-е).
Future<void> _week(ProviderContainer c, {bool today = true}) async {
  final repo = c.read(sleepRepositoryProvider);
  await seedNight(repo, '2026-10-01', wake: '07:00');
  await seedNight(repo, '2026-10-02', bed: '01:30', wake: '07:00', quality: 2);
  await seedNight(repo, '2026-10-03', wake: '07:30');
  if (today) await seedNight(repo, '2026-10-05', quality: 4);
}

Future<String?> showSleepEntryForTest(BuildContext context, {String? date}) =>
    showSleepEntrySheet(
      context,
      date: date,
      source: SleepSource.morningNotification,
    );

void main() {
  group('экран «Сон»', () {
    testWidgets('нет записей: «Как спалось?», одна кнопка', (tester) async {
      await pumpSleep(tester);
      expect(find.byKey(const Key('sleep-overview')), findsOneWidget);
      expect(find.byKey(const Key('sleep-hero-empty')), findsOneWidget);
      expect(find.textContaining('через пару недель'), findsOneWidget);
      expect(find.byKey(const Key('sleep-chart-card')), findsNothing);
      expect(find.byKey(const Key('sleep-rituals-card')), findsOneWidget);
      expect(find.byKey(const Key('sleep-kpi-7')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('запись «как обычно» в два касания, источник — вручную', (
      tester,
    ) async {
      final c = await pumpSleep(tester);
      await tester.tap(find.byKey(const Key('sleep-record')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sleep-preview')), findsOneWidget);
      expect(find.text('Сон: 8 ч'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sleep-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sleep-hero')), findsOneWidget);
      expect(find.text('8 ч'), findsWidgets);
      final e = await c.read(sleepRepositoryProvider).getEntry('2026-10-05');
      expect(e!.source, SleepSource.manual);
      expect(e.view!.bedLocal, '23:30');
      expect(e.view!.wakeLocal, '07:30');
    });

    testWidgets('со сном: герой, средние, графики, история', (tester) async {
      await pumpSleep(tester, seedWith: _week);
      expect(find.byKey(const Key('sleep-hero')), findsOneWidget);
      expect(find.text('7 ч 30 мин'), findsWidgets);
      expect(find.text('23:40 → 07:10'), findsWidgets);
      expect(find.text('самочувствие 4/5'), findsOneWidget);
      expect(find.byKey(const Key('sleep-kpi-7')), findsOneWidget);
      expect(find.text('4 из 7'), findsOneWidget);
      expect(find.byKey(const Key('sleep-bar-2026-10-05')), findsOneWidget);
      expect(find.byKey(const Key('sleep-threshold')), findsOneWidget);
      expect(find.byKey(const Key('heat-2026-10-05')), findsOneWidget);
      expect(find.text('4 из 30 · цель 7 ч'), findsOneWidget);
      expect(find.byKey(const Key('sleep-history-2026-10-03')), findsOneWidget);
      // Столбики: неделя -> месяц.
      expect(find.byKey(const Key('sleep-bar-2026-09-10')), findsNothing);
      await tester.tap(find.byKey(const Key('sleep-chart-month')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sleep-bar-2026-09-10')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sleep-chart-week')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sleep-bar-2026-09-10')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('нет записи этой ночью, но есть прежние', (tester) async {
      await pumpSleep(tester, seedWith: (c) => _week(c, today: false));
      expect(find.byKey(const Key('sleep-hero-empty')), findsOneWidget);
      expect(find.textContaining('Этой ночью записи ещё нет'), findsOneWidget);
    });

    testWidgets('правка записи из истории и удаление', (tester) async {
      final c = await pumpSleep(tester, seedWith: _week);
      await tester.ensureVisible(
        find.byKey(const Key('sleep-history-2026-10-03')),
      );
      await tester.tap(find.byKey(const Key('sleep-history-2026-10-03')));
      await settleDb(tester);
      expect(find.byKey(const Key('sleep-wake')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('sleep-wake')), '8:00');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sleep-quality-5')));
      await tester.tap(find.byKey(const Key('sleep-save')));
      await tester.pumpAndSettle();
      final e = (await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getEntry('2026-10-03'),
      ))!;
      expect(e.view!.wakeLocal, '08:00');
      expect(e.quality, 5);

      await tester.ensureVisible(
        find.byKey(const Key('sleep-history-2026-10-03')),
      );
      await tester.tap(find.byKey(const Key('sleep-history-2026-10-03')));
      await settleDb(tester);
      await tester.tap(find.byKey(const Key('sleep-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sleep-history-2026-10-03')), findsNothing);
      final gone = await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getEntry('2026-10-03'),
      );
      expect(gone, isNull);
    });

    testWidgets('тап по пустому дню на карте открывает запись за этот день', (
      tester,
    ) async {
      final c = await pumpSleep(tester, seedWith: _week);
      await tester.tap(find.byKey(const Key('heat-2026-10-04')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sleep-bed')), '23:00');
      await tester.enterText(find.byKey(const Key('sleep-wake')), '7:00');
      await tester.tap(find.byKey(const Key('sleep-save')));
      await tester.pumpAndSettle();
      final e = await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getEntry('2026-10-04'),
      );
      expect(e!.view!.minutes, 480);
    });

    testWidgets('история: показать все', (tester) async {
      await pumpSleep(
        tester,
        seedWith: (c) async {
          final repo = c.read(sleepRepositoryProvider);
          for (var d = 1; d <= 20; d++) {
            await seedNight(repo, '2026-09-${d.toString().padLeft(2, '0')}');
          }
        },
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('sleep-history-more')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('sleep-history-2026-09-01')), findsNothing);
      await tester.tap(find.byKey(const Key('sleep-history-more')));
      await tester.pumpAndSettle();
      expect(find.text('Свернуть'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('sleep-history-more')));
      await tester.tap(find.byKey(const Key('sleep-history-more')));
      await tester.pumpAndSettle();
      expect(find.text('Показать все · 20'), findsOneWidget);
    });

    testWidgets('десктоп: две колонки без переполнения', (tester) async {
      await pumpSleep(tester, size: desktopSize, seedWith: _week);
      expect(find.byKey(const Key('sleep-hero')), findsOneWidget);
      expect(find.byKey(const Key('sleep-link-card')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('ошибка чтения', () {
    testWidgets('«Сон»: карточка с «Повторить»', (tester) async {
      await pumpSleep(
        tester,
        overrides: [
          sleepEntriesProvider.overrideWith(
            (ref) => Stream<List<SleepEntry>>.error(StateError('сбой')),
          ),
        ],
      );
      expect(find.byKey(const Key('sleep-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sleep-retry')));
      await tester.pump();
      expect(find.byKey(const Key('sleep-error')), findsOneWidget);
    });

    testWidgets('«Утренний план»: задачи не прочитались', (tester) async {
      await pumpSleep(
        tester,
        location: '/sleep/morning',
        overrides: [
          tasksProvider.overrideWith(
            (ref) => Stream<List<TaskEntity>>.error(StateError('сбой')),
          ),
        ],
      );
      expect(find.byKey(const Key('ritual-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ritual-retry')));
      await tester.pump();
      expect(find.byKey(const Key('ritual-error')), findsOneWidget);
    });
  });

  group('связь сна с задачами', () {
    testWidgets('мало данных: плашка и оговорка', (tester) async {
      await pumpSleep(
        tester,
        seedWith: (c) async {
          await _week(c);
          await seedTask(
            c,
            'Дело',
            date: '2026-10-02',
            status: TaskStatus.done,
          );
          await seedTask(c, 'Дело 2', date: '2026-10-05');
        },
      );
      expect(find.byKey(const Key('sleep-link-card')), findsOneWidget);
      expect(find.text('МАЛО ДАННЫХ'), findsOneWidget);
      expect(find.byKey(const Key('sleep-link-short')), findsOneWidget);
      expect(find.byKey(const Key('sleep-link-normal')), findsOneWidget);
      expect(find.textContaining('не причина и следствие'), findsOneWidget);
      expect(find.textContaining('В дни после короткого сна'), findsOneWidget);
    });

    testWidgets('достаточно данных: доли и разница', (tester) async {
      await pumpSleep(
        tester,
        seedWith: (c) async {
          await _week(c);
          // Короткие ночи: 2-е (6:30 > 6 ч — делаем короче).
          final repo = c.read(sleepRepositoryProvider);
          await seedNight(repo, '2026-10-02', bed: '02:00', wake: '07:00');
          await seedNight(repo, '2026-10-04', bed: '02:30', wake: '07:00');
          for (final d in ['2026-10-02', '2026-10-04']) {
            await seedTask(c, 'Короткий $d', date: d);
          }
          for (final d in ['2026-10-01', '2026-10-03']) {
            await seedTask(
              c,
              'Нормальный $d',
              date: d,
              status: TaskStatus.done,
            );
          }
        },
      );
      expect(find.text('МАЛО ДАННЫХ'), findsNothing);
      expect(find.text('0 %'), findsOneWidget);
      expect(find.text('100 %'), findsOneWidget);
      expect(find.textContaining('Разница: +100 п. п.'), findsOneWidget);
    });

    testWidgets('нет задач: «сравнивать нечего»', (tester) async {
      await pumpSleep(tester, seedWith: _week);
      expect(find.byKey(const Key('sleep-link-empty')), findsOneWidget);
    });

    testWidgets('только нормальный сон и дни без сна', (tester) async {
      await pumpSleep(
        tester,
        seedWith: (c) async {
          await _week(c);
          await seedTask(c, 'А', date: '2026-10-01', status: TaskStatus.done);
          await seedTask(c, 'Б', date: '2026-10-04');
        },
      );
      expect(
        find.textContaining('В дни после нормального сна вы закрывали 100 %'),
        findsOneWidget,
      );
      expect(find.textContaining('без записи сна: 1'), findsOneWidget);
    });
  });

  group('форма сна', () {
    testWidgets('неверное время и подозрительно длинный сон', (tester) async {
      await pumpSleep(tester);
      await tester.tap(find.byKey(const Key('sleep-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sleep-bed')), 'abc');
      await tester.pumpAndSettle();
      expect(find.text('Введите время, например 23:40'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sleep-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sleep-error-text')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('sleep-bed')), '07:30');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sleep-long-hint')), findsOneWidget);
      expect(find.text('Сон: 24 ч'), findsOneWidget);
    });

    testWidgets('«Как обычно» возвращает привычный режим', (tester) async {
      await pumpSleep(tester, seedWith: _week);
      await tester.tap(find.byKey(const Key('sleep-edit')));
      await settleDb(tester);
      await tester.enterText(find.byKey(const Key('sleep-bed')), '22:00');
      await tester.tap(find.byKey(const Key('sleep-usual')));
      await tester.pumpAndSettle();
      expect(find.text('23:40'), findsWidgets);
    });

    testWidgets('самочувствие переключается и снимается', (tester) async {
      final c = await pumpSleep(tester);
      await tester.tap(find.byKey(const Key('sleep-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sleep-quality-3')));
      await tester.tap(find.byKey(const Key('sleep-quality-3')));
      await tester.enterText(find.byKey(const Key('sleep-note')), 'тихо');
      await tester.tap(find.byKey(const Key('sleep-save')));
      await tester.pumpAndSettle();
      final e = await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getEntry('2026-10-05'),
      );
      expect(e!.quality, isNull);
      expect(e.note, 'тихо');
    });

    testWidgets('запись из утреннего уведомления помечается источником', (
      tester,
    ) async {
      final c = await pumpSleep(tester);
      final context = tester.element(find.byKey(const Key('sleep-overview')));
      unawaited(showSleepEntryForTest(context));
      await tester.pumpAndSettle();
      expect(find.text('Как спал?'), findsWidgets);
      await tester.tap(find.byKey(const Key('sleep-save')));
      await tester.pumpAndSettle();
      final e = await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getEntry('2026-10-05'),
      );
      expect(e!.source, SleepSource.morningNotification);
    });

    testWidgets('запись, удалённая на другом устройстве, — сообщение', (
      tester,
    ) async {
      await pumpSleep(tester);
      final context = tester.element(find.byKey(const Key('sleep-overview')));
      unawaited(showSleepEntryForTest(context, date: '2026-01-01'));
      await settleDb(tester);
      expect(find.textContaining('Запись не найдена'), findsOneWidget);
    });
  });

  group('столбики и карта', () {
    testWidgets('SleepBars и SleepHeatmap: подписи для скринридера', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Column(
              children: [
                SleepBars(
                  dates: ['2026-10-04', '2026-10-05'],
                  minutes: {'2026-10-05': 300},
                  today: '2026-10-05',
                ),
                SleepHeatmap(
                  dates: ['2026-10-04', '2026-10-05'],
                  minutes: {'2026-10-05': 480},
                  today: '2026-10-05',
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        find.bySemanticsLabel(RegExp('4 октября: нет записи')),
        findsWidgets,
      );
      expect(find.bySemanticsLabel(RegExp('5 октября: 5 ч')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('5 октября: 8 ч')), findsOneWidget);
      semantics.dispose();
    });
  });
}
