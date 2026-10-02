import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

/// Тикать ли часы календаря по таймеру. По умолчанию — как автозапуск
/// фоновых задач (`syncAutostartProvider`): виджет-тесты его отключают, и
/// незавершённых таймеров у них не остаётся.
final Provider<bool> liveClockProvider = Provider<bool>(
  (ref) => ref.watch(syncAutostartProvider),
);

/// Текущий момент (UTC): тикает раз в 30 секунд — «линия сейчас» и
/// «через 25 мин». Тесты подставляют неподвижные часы.
class NowNotifier extends Notifier<DateTime> {
  @override
  DateTime build() {
    if (ticks && ref.watch(liveClockProvider)) {
      final timer = Timer.periodic(const Duration(seconds: 30), (_) {
        state = ref.read(clockProvider)().toUtc();
      });
      ref.onDispose(timer.cancel);
    }
    return ref.read(clockProvider)().toUtc();
  }

  /// Тикать по таймеру (тесты выключают).
  @protected
  bool get ticks => true;
}

final nowProvider = NotifierProvider<NowNotifier, DateTime>(NowNotifier.new);

/// Сегодняшняя дата в поясе устройства.
final todayProvider = Provider<DateTime>((ref) {
  final zone = ref.watch(deviceTimeZoneProvider);
  return dateOnly(utcToWall(zone, ref.watch(nowProvider)));
});

/// Текущее «настенное» время в поясе устройства.
final nowWallProvider = Provider<DateTime>((ref) {
  final zone = ref.watch(deviceTimeZoneProvider);
  return utcToWall(zone, ref.watch(nowProvider));
});

/// Через сколько дней выполненные и отменённые задачи уходят в архив
/// (spec 4.1: N дней — настройка клиента).
const Duration autoArchiveAfter = Duration(days: 30);

/// Первое открытие за сеанс: создаёт системные календари и переносит в
/// архив давно закрытые задачи.
final calendarBootstrapProvider = FutureProvider<void>((ref) async {
  await ref.watch(calendarRepositoryProvider).ensureSystemCalendars();
  await ref
      .watch(taskRepositoryProvider)
      .archiveClosedOlderThan(autoArchiveAfter);
});

StreamProvider<List<T>> _rows<T>(
  String table,
  T Function(Map<String, Object?>) parse, {
  String? orderBy,
}) => StreamProvider<List<T>>(
  (ref) => ref
      .watch(syncStoreProvider)
      .watchVisibleRows(table, orderBy: orderBy)
      .map((rows) => [for (final r in rows) parse(r)]),
);

final StreamProvider<List<CalendarLayer>> calendarLayersProvider =
    _rows<CalendarLayer>(
      'calendars',
      CalendarLayer.fromRow,
      orderBy: 't.position, t.id',
    );

final StreamProvider<List<EventEntity>> eventsProvider = _rows<EventEntity>(
  'events',
  EventEntity.fromRow,
);

final StreamProvider<List<EventOverride>> eventOverridesProvider =
    _rows<EventOverride>('event_overrides', EventOverride.fromRow);

final StreamProvider<List<TaskEntity>> tasksProvider = _rows<TaskEntity>(
  'tasks',
  TaskEntity.fromRow,
);

final StreamProvider<List<TaskCompletion>> taskCompletionsProvider =
    _rows<TaskCompletion>('task_completions', TaskCompletion.fromRow);

final StreamProvider<List<Subtask>> subtasksProvider = _rows<Subtask>(
  'subtasks',
  Subtask.fromRow,
  orderBy: 't.position, t.id',
);

final StreamProvider<List<Project>> projectsProvider = _rows<Project>(
  'projects',
  Project.fromRow,
  orderBy: 't.title',
);

final StreamProvider<List<Person>> peopleProvider = _rows<Person>(
  'people',
  Person.fromRow,
  orderBy: 't.name',
);

final StreamProvider<List<Tag>> tagsProvider = _rows<Tag>(
  'tags',
  Tag.fromRow,
  orderBy: 't.name',
);

/// Связи задача–тег: `task_id -> {tag_id}`.
final taskTagLinksProvider = StreamProvider<Map<String, Set<String>>>(
  (ref) =>
      ref.watch(syncStoreProvider).watchVisibleRows('task_tags').map((rows) {
        final map = <String, Set<String>>{};
        for (final r in rows) {
          map
              .putIfAbsent(r['task_id']! as String, () => {})
              .add(r['tag_id']! as String);
        }
        return map;
      }),
);

/// Цикл недель из `user_settings` (`null` — выключен).
final weekCycleProvider = StreamProvider<WeekCycle?>(
  (ref) => ref.watch(calendarSettingsRepositoryProvider).watchWeekCycle(),
);

/// Время напоминаний о событиях на весь день.
final allDayReminderTimeProvider = StreamProvider<String>(
  (ref) =>
      ref.watch(calendarSettingsRepositoryProvider).watchAllDayReminderTime(),
);

/// Праздники РФ; пока не загрузились (или ошибка) — пустой календарь.
final holidaysProvider = Provider<HolidayCalendar>(
  (ref) => ref.watch(holidayCalendarProvider).value ?? HolidayCalendar.empty(),
);
