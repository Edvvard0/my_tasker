import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/domain/task_validation.dart';

/// Клиентские проверки — зеркало серверных (`tables.py`: `_timed_or_dated`,
/// `_override_valid`, `_task_valid`).
void main() {
  group('переопределение экземпляра', () {
    String? check({
      String key = '2026-10-06T07:00:00Z',
      DateTime? startAt,
      DateTime? endAt,
      DateTime? startDate,
      DateTime? endDate,
      String? title,
    }) => overrideProblem(
      originalStart: key,
      startAt: startAt,
      endAt: endAt,
      startDate: startDate,
      endDate: endDate,
      title: title,
    );

    test('нормальное — без замечаний', () {
      expect(check(), isNull);
      expect(
        check(
          startAt: DateTime.utc(2026, 10, 6, 8),
          endAt: DateTime.utc(2026, 10, 6, 9),
        ),
        isNull,
      );
      expect(
        check(
          key: '2026-10-06',
          startDate: DateTime.utc(2026, 10, 7),
          endDate: DateTime.utc(2026, 10, 8),
        ),
        isNull,
      );
    });

    test('конец раньше начала, оба вида, половина пары', () {
      expect(
        check(
          startAt: DateTime.utc(2026, 10, 6, 9),
          endAt: DateTime.utc(2026, 10, 6, 8),
        ),
        isNotNull,
      );
      expect(
        check(
          startDate: DateTime.utc(2026, 10, 8),
          endDate: DateTime.utc(2026, 10, 7),
        ),
        isNotNull,
      );
      expect(
        check(
          startAt: DateTime.utc(2026, 10, 6, 8),
          endAt: DateTime.utc(2026, 10, 6, 9),
          startDate: DateTime.utc(2026, 10, 7),
          endDate: DateTime.utc(2026, 10, 7),
        ),
        isNotNull,
      );
      expect(check(startAt: DateTime.utc(2026, 10, 6, 8)), isNotNull);
    });

    test('длиннее 366 суток и годы вне 1970…2200', () {
      expect(
        check(startAt: DateTime.utc(2026), endAt: DateTime.utc(2027, 1, 2)),
        isNull,
        reason: '366 суток — ещё можно',
      );
      expect(
        check(startAt: DateTime.utc(2026), endAt: DateTime.utc(2027, 1, 3)),
        isNotNull,
      );
      expect(
        check(startDate: DateTime.utc(2026), endDate: DateTime.utc(2027, 1, 3)),
        isNotNull,
      );
      expect(
        check(startAt: DateTime.utc(1969, 12, 31), endAt: DateTime.utc(1970)),
        isNotNull,
      );
      expect(
        check(
          startDate: DateTime.utc(2200, 12, 31),
          endDate: DateTime.utc(2201),
        ),
        isNotNull,
      );
    });

    test('ключ и название', () {
      expect(check(key: 'k'), isNotNull);
      expect(check(key: '2026-13-40'), isNotNull);
      expect(check(key: '2026-10-06T07:00:00'), isNotNull);
      expect(check(title: '   '), isNotNull);
    });
  });

  group('даты задачи', () {
    TaskEntity task(TaskDue due) =>
        TaskEntity(id: 'x', title: 'Т', status: TaskStatus.todo, due: due);

    test('годы 1970…2200', () {
      expect(
        taskProblem(task(TaskDue.date(DateTime.utc(2026, 10, 6)))),
        isNull,
      );
      expect(
        taskProblem(task(TaskDue.date(DateTime.utc(1969, 12, 31)))),
        isNotNull,
      );
      expect(taskProblem(task(TaskDue.date(DateTime.utc(2201)))), isNotNull);
      expect(
        taskProblem(task(TaskDue.at(DateTime.utc(2201), 'UTC'))),
        isNotNull,
      );
      expect(
        taskProblem(task(TaskDue.at(DateTime.utc(1969, 6), 'UTC'))),
        isNotNull,
      );
      expect(
        taskProblem(task(TaskDue.at(DateTime.utc(2026, 10, 6, 9), 'UTC'))),
        isNull,
      );
    });
  });
}
