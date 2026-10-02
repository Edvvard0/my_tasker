import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';

import '../support/stage2_env.dart';

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
  testWidgets('в корзине — названия события и задачи; восстановление', (
    tester,
  ) async {
    final c = await pumpStage2(tester, location: '/settings/trash');
    final event = await tester.runAsync(
      () => addEvent(
        c,
        title: 'Созвон Creora',
        startUtc: '2026-09-30T12:00:00',
        endUtc: '2026-09-30T13:00:00',
      ),
    );
    await _settle(tester);
    final task = await tester.runAsync(
      () => addTask(c, title: 'Оплатить домен'),
    );
    await _settle(tester);
    await tester.runAsync(
      () => c.read(calendarRepositoryProvider).deleteEvent(event!.id),
    );
    await _settle(tester);
    await tester.runAsync(
      () => c.read(taskRepositoryProvider).deleteTask(task!.id),
    );
    await _settle(tester);
    expect(find.text('Созвон Creora'), findsOneWidget);
    expect(find.text('Оплатить домен'), findsOneWidget);
    await tester.tap(find.byKey(Key('restore-${event!.id}')));
    await _settle(tester);
    expect(find.text('Созвон Creora'), findsNothing);
    expect(find.text('Оплатить домен'), findsOneWidget);
  });
}
