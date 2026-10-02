import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/presentation/event_editor.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_taps.dart';
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';

import '../../support/stage2_env.dart';

void main() {
  group('разбор payload уведомления', () {
    test('событие и задача', () {
      expect(
        parseReminderPayload('event:abc|2026-10-06T07:00:00Z'),
        const EventTarget('abc', '2026-10-06T07:00:00Z'),
      );
      expect(
        parseReminderPayload('event:abc|2026-10-06'),
        const EventTarget('abc', '2026-10-06'),
      );
      expect(parseReminderPayload('task:t1'), const TaskTarget('t1'));
    });

    test('чужое и битое — null', () {
      for (final bad in [
        null,
        '',
        'x:1',
        'event:',
        'event:abc',
        'event:abc|',
        'event:|k',
        'task:',
      ]) {
        expect(parseReminderPayload(bad), isNull, reason: '$bad');
      }
    });
  });

  group('шина нажатий', () {
    test('нажатие до подписки ждёт её (холодный старт)', () async {
      final taps = ReminderTaps()..add('task:t1');
      expect(taps.takePending(), const TaskTarget('t1'));
      expect(taps.takePending(), isNull);
    });

    test('с подпиской цель приходит в поток; мусор игнорируется', () async {
      final taps = ReminderTaps();
      final got = <ReminderTarget>[];
      final sub = taps.stream.listen(got.add);
      taps
        ..add('task:t1')
        ..add('junk')
        ..add('event:e|k');
      await Future<void>.delayed(Duration.zero);
      expect(got, const [TaskTarget('t1'), EventTarget('e', 'k')]);
      expect(taps.takePending(), isNull);
      await sub.cancel();
    });
  });

  group('нажатие на напоминание открывает объект', () {
    testWidgets('задача: открывается редактор', (tester) async {
      final c = await pumpStage2(tester, seed: true);
      final tasks = (await tester.runAsync(
        () => c.read(tasksProvider.future),
      ))!;
      c.read(reminderTapsProvider).add('task:${tasks.first.id}');
      await tester.pumpAndSettle();
      expect(find.byType(TaskEditor), findsOneWidget);
    });

    testWidgets('событие: открывается редактор экземпляра', (tester) async {
      final c = await pumpStage2(tester, seed: true);
      final events = (await tester.runAsync(
        () => c.read(eventsProvider.future),
      ))!;
      final e = events.firstWhere((x) => !x.allDay && x.rrule == null);
      c
          .read(reminderTapsProvider)
          .add(
            'event:${e.id}|${e.startAt!.toIso8601String().replaceAll('.000', '')}',
          );
      await tester.pumpAndSettle();
      expect(find.byType(EventEditor), findsOneWidget);
    });

    testWidgets('удалённый или неизвестный объект — ничего', (tester) async {
      final c = await pumpStage2(tester, seed: true);
      c.read(reminderTapsProvider).add('task:no-such-task');
      await tester.pumpAndSettle();
      expect(find.byType(TaskEditor), findsNothing);
    });
  });
}
