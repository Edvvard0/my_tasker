import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart' show Json;
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/sleep/data/sleep_settings.dart';
import 'package:my_tasker/features/sleep/domain/sleep_calc.dart';
import 'package:my_tasker/features/sleep/domain/sleep_habits.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';
import 'package:my_tasker/features/sleep/domain/sleep_tasks.dart';

StreamProvider<List<T>> _rows<T>(
  String table,
  T Function(Json) parse, {
  String? orderBy,
}) => StreamProvider<List<T>>(
  (ref) => ref
      .watch(syncStoreProvider)
      .watchVisibleRows(table, orderBy: orderBy)
      .map((rows) => [for (final r in rows) parse(r)]),
);

final StreamProvider<List<SleepEntry>> sleepEntriesProvider = _rows<SleepEntry>(
  'sleep_entries',
  SleepEntry.fromRow,
  orderBy: 't.date DESC, t.id',
);

final StreamProvider<List<DailyPlan>> dailyPlansProvider = _rows<DailyPlan>(
  'daily_plans',
  DailyPlan.fromRow,
  orderBy: 't.date DESC, t.id',
);

final StreamProvider<List<EveningCheckin>> eveningCheckinsProvider =
    _rows<EveningCheckin>(
      'evening_checkins',
      EveningCheckin.fromRow,
      orderBy: 't.date DESC, t.id',
    );

/// Строки задач для расчёта связи со сном (`taskLinkRow`).
final StreamProvider<List<Json>> sleepTaskRowsProvider =
    StreamProvider<List<Json>>(
      (ref) => ref
          .watch(syncStoreProvider)
          .watchVisibleRows('tasks')
          .map((rows) => [for (final r in rows) taskLinkRow(r)]),
    );

/// Весь снимок «Сна» с готовыми расчётами. Расчёты — чистые функции
/// `sleep_calc.dart` (общие векторы с сервером); здесь только кэш.
@immutable
class SleepData {
  SleepData({
    required this.entries,
    required this.plans,
    required this.checkins,
    required this.taskRows,
    required this.today,
  });

  final List<SleepEntry> entries;
  final List<DailyPlan> plans;
  final List<EveningCheckin> checkins;
  final List<Json> taskRows;

  /// Сегодняшняя дата в поясе устройства (`YYYY-MM-DD`).
  final String today;

  /// Записи сна с валидной длительностью, от новых к старым.
  late final List<SleepEntry> history = [
    for (final e in entries)
      if (e.view != null) e,
  ]..sort((a, b) => b.date.compareTo(a.date));

  late final Map<String, SleepEntry> entryByDate = {
    for (final e in history) e.date: e,
  };

  late final Map<String, DailyPlan> planByDate = {
    for (final p in plans) p.date: p,
  };

  late final Map<String, EveningCheckin> checkinByDate = {
    for (final c in checkins) c.date: c,
  };

  late final List<Json> _entryRows = [for (final e in entries) e.toRow()];

  /// Минуты сна по датам.
  late final Map<String, int> minutesByDay = {
    for (final e in history) e.date: e.view!.minutes,
  };

  late final SleepAverage average7 = averageSleep(_entryRows, today, 7);
  late final SleepAverage average30 = averageSleep(_entryRows, today, 30);

  late final SleepTaskLink link = sleepTaskLink(_entryRows, taskRows, today);

  late final RitualStreaks streaks = ritualStreaks(
    [for (final p in plans) p.date],
    [for (final c in checkins) c.date],
    today,
  );

  late final UsualTimes usual = usualTimes(history);

  /// Сон этой ночи (дата сна = сегодня).
  SleepEntry? get lastNight => entryByDate[today];

  bool get morningDone => planByDate.containsKey(today);
  bool get eveningDone => checkinByDate.containsKey(today);

  /// Дата [days] дней назад от сегодняшней.
  String daysAgo(int days) => formatDate(addDays(parseDate(today)!, -days));
}

/// «Повторить» после ошибки чтения: пересоздаёт все потоки раздела.
void retrySleepData(WidgetRef ref) {
  ref
    ..invalidate(sleepEntriesProvider)
    ..invalidate(dailyPlansProvider)
    ..invalidate(eveningCheckinsProvider)
    ..invalidate(sleepTaskRowsProvider);
}

/// Снимок «Сна»: ошибка любого потока — ошибка экрана, пока хотя бы один
/// загружается — загрузка.
final Provider<AsyncValue<SleepData>> sleepDataProvider =
    Provider<AsyncValue<SleepData>>((ref) {
      final entries = ref.watch(sleepEntriesProvider);
      final plans = ref.watch(dailyPlansProvider);
      final checkins = ref.watch(eveningCheckinsProvider);
      final tasks = ref.watch(sleepTaskRowsProvider);
      final today = formatDate(ref.watch(todayProvider));
      final all = <AsyncValue<Object?>>[entries, plans, checkins, tasks];
      for (final v in all) {
        if (v.hasError && !v.hasValue) {
          return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
        }
      }
      if (all.any((v) => !v.hasValue)) return const AsyncValue.loading();
      return AsyncValue.data(
        SleepData(
          entries: entries.requireValue,
          plans: plans.requireValue,
          checkins: checkins.requireValue,
          taskRows: tasks.requireValue,
          today: today,
        ),
      );
    });

final StreamProvider<SleepReminderSetting> morningReminderProvider =
    StreamProvider<SleepReminderSetting>(
      (ref) => ref.watch(sleepSettingsRepositoryProvider).watchMorning(),
    );

final StreamProvider<SleepReminderSetting> eveningReminderProvider =
    StreamProvider<SleepReminderSetting>(
      (ref) => ref.watch(sleepSettingsRepositoryProvider).watchEvening(),
    );
