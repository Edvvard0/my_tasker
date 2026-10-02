import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/shell/app_router.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../support/stage2_env.dart';

/// Много данных, чтобы любой список был длиннее окна.
Future<void> _seedMany(ProviderContainer c) async {
  final calendars = c.read(calendarRepositoryProvider);
  final tasks = c.read(taskRepositoryProvider);
  for (var i = 0; i < 14; i++) {
    await calendars.createEvent(
      EventEntity(
        id: calendars.newEventId(),
        calendarId: systemCalendarId('personal'),
        title: 'Событие $i',
        allDay: false,
        startAt: DateTime.utc(
          2026,
          9,
          30,
          9 + i % 6,
        ).add(Duration(days: i % 5)),
        endAt: DateTime.utc(2026, 9, 30, 10 + i % 6).add(Duration(days: i % 5)),
        tz: 'Europe/Moscow',
      ),
    );
    await tasks.createTask(
      TaskEntity(
        id: tasks.newTaskId(),
        title: 'Задача $i',
        status: TaskStatus.todo,
        due: TaskDue.date(DateTime.utc(2026, 9, 30).add(Duration(days: i % 5))),
      ),
    );
  }
}

/// Прокручивает главный вертикальный список вниз и проверяет, что последняя
/// строка заканчивается над плавающим таб-баром.
Future<void> _expectLastRowAboveBar(WidgetTester tester, String path) async {
  final c = await pumpStage2(
    tester,
    size: const Size(390, 640),
    seedWith: _seedMany,
  );
  c.read(routerProvider).go(path);
  await tester.pumpAndSettle();
  final scrollable = find
      .byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      )
      .first;
  await tester.drag(scrollable, const Offset(0, -9000));
  await tester.pumpAndSettle();
  await tester.drag(scrollable, const Offset(0, -9000));
  await tester.pumpAndSettle();
  final barTop = tester
      .getTopLeft(find.byKey(const Key('floating-tab-bar')))
      .dy;
  final state = tester.state<ScrollableState>(scrollable);
  expect(state.position.pixels, state.position.maxScrollExtent);
  // Нижний край содержимого: последний виджет-строка внутри прокрутки.
  final bottoms = <double>[];
  for (final e
      in find
          .descendant(of: scrollable, matching: find.byType(Text))
          .evaluate()) {
    final box = e.renderObject! as RenderBox;
    final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    if (bottom <= 640) bottoms.add(bottom);
  }
  expect(bottoms, isNotEmpty, reason: path);
  bottoms.sort();
  expect(
    bottoms.last,
    lessThanOrEqualTo(barTop),
    reason: '$path: последняя строка спрятана за таб-баром',
  );
}

void main() {
  testWidgets('расписание: последняя строка над таб-баром', (tester) async {
    await _expectLastRowAboveBar(tester, '/calendar');
  });

  testWidgets('задачи: последняя строка над таб-баром', (tester) async {
    await _expectLastRowAboveBar(tester, '/calendar/tasks');
  });

  testWidgets('сегодня: последняя строка над таб-баром', (tester) async {
    await _expectLastRowAboveBar(tester, '/today');
  });
}
