import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart'
    show ValidationError, ensureValid;
import 'package:my_tasker/features/sleep/domain/sleep_calc.dart';
import 'package:my_tasker/features/sleep/domain/sleep_ids.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';
import 'package:my_tasker/features/sleep/domain/sleep_tasks.dart';
import 'package:my_tasker/features/sleep/domain/sleep_validation.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

/// Итог применения переноса задач из чек-ина.
class CarryOutcome {
  const CarryOutcome({required this.moved, required this.skipped});

  /// Задачи, у которых изменили срок.
  final List<CarryChange> moved;

  /// Пропущенные: причина в [CarryChange.reason] (`closed`, `recurring`,
  /// `unchanged`, … и `invalid` — задачу не удалось сохранить).
  final List<CarryChange> skipped;
}

/// Сон, утренний план и вечерний чек-ин: локальные записи через
/// [SyncStore] (строка + HLC + outbox в одной транзакции). Проверки — как на
/// сервере (`sleep_validation.dart`).
///
/// У всех трёх таблиц **одна строка на дату**: `id = uuid5(ns(таблица),
/// дата)` (`sleep_ids.dart`). Повторная запись того же дня правит или
/// восстанавливает строку, а не создаёт вторую; два устройства, записавшие
/// один день офлайн, делают одну строку. Колонка `date` неизменяема:
/// «перенос» записи на другую дату — это удаление и новая строка.
class SleepRepository {
  SleepRepository(
    this._store, {
    TaskRepository? tasks,
    DateTime Function()? now,
  }) : _tasks = tasks ?? TaskRepository(_store, now: now),
       _now = now ?? DateTime.now;

  final SyncStore _store;
  final TaskRepository _tasks;
  final DateTime Function() _now;

  Json _changed(Json before, Json after) => {
    for (final e in after.entries)
      if (_differs(before[e.key], e.value)) e.key: e.value,
  };

  bool _differs(Object? a, Object? b) {
    if (a is List && b is List) return a.toString() != b.toString();
    if (a is Map && b is Map) return a.toString() != b.toString();
    return a != b;
  }

  /// Создаёт строку с детерминированным [id]; существующую — правит
  /// изменившиеся поля [mutable], удалённую — сначала восстанавливает.
  Future<void> _upsert(String table, String id, Json all, Json mutable) =>
      _store.transaction(() async {
        final row = await _store.getRow(table, id);
        if (row == null) {
          await _store.create(table, id, all);
          return;
        }
        if (row['deleted_at'] != null) await _store.restore(table, id);
        final fields = _changed(row, mutable);
        if (fields.isNotEmpty) await _store.update(table, id, fields);
      });

  Future<Json?> _live(String table, String id) async {
    final row = await _store.getRow(table, id);
    return row == null || row['deleted_at'] != null ? null : row;
  }

  Future<void> _delete(String table, String id) async {
    if (await _live(table, id) != null) await _store.softDelete(table, id);
  }

  static String? _blankToNull(String? text) {
    final t = text?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  static DateTime _wholeSeconds(DateTime t) {
    final u = t.toUtc();
    return DateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second);
  }

  // ---- сон ---------------------------------------------------------------------

  Future<SleepEntry?> getEntry(String date) async {
    final row = await _live(sleepEntriesTable, sleepEntryId(date));
    return row == null ? null : SleepEntry.fromRow(row);
  }

  /// Записывает сон. Дата записи — локальная дата пробуждения в [wakeTz];
  /// запись того же дня правится. [replacesDate] — дата правимой записи: если
  /// из-за правки времени дата сменилась, старая строка удаляется, а новая
  /// создаётся. Возвращает дату записи.
  Future<String> saveSleep({
    required DateTime bedAt,
    required DateTime wakeAt,
    required String wakeTz,
    String? bedTz,
    SleepSource source = SleepSource.manual,
    int? quality,
    String? note,
    String? replacesDate,
  }) async {
    final bed = _wholeSeconds(bedAt);
    final wake = _wholeSeconds(wakeAt);
    final date = sleepDate(formatInstant(wake), wakeTz);
    if (date == null) throw const ValidationError('Неизвестный часовой пояс');
    final entry = SleepEntry(
      id: sleepEntryId(date),
      date: date,
      bedAt: bed,
      wakeAt: wake,
      bedTz: bedTz == wakeTz ? null : bedTz,
      wakeTz: wakeTz,
      source: source,
      quality: quality,
      note: _blankToNull(note),
    );
    ensureValid(sleepProblem(entry) ?? sleepTimeProblem(entry, _now()));
    await _store.transaction(() async {
      if (replacesDate != null && replacesDate != date) {
        await _delete(sleepEntriesTable, sleepEntryId(replacesDate));
      }
      await _upsert(sleepEntriesTable, entry.id, {
        'date': date,
        ...entry.toFields(),
      }, entry.toFields());
    });
    return date;
  }

  /// Самочувствие и заметка к уже записанному сну.
  Future<void> updateSleepMeta(
    String date, {
    int? quality,
    String? note,
  }) async {
    final entry = await getEntry(date);
    if (entry == null) throw StateError('Сна за $date нет');
    final next = entry.copyWith(quality: quality, note: _blankToNull(note));
    ensureValid(sleepProblem(next));
    final fields = _changed(entry.toFields(), next.toFields());
    if (fields.isNotEmpty) {
      await _store.update(sleepEntriesTable, entry.id, fields);
    }
  }

  Future<void> deleteSleep(String date) =>
      _delete(sleepEntriesTable, sleepEntryId(date));

  Future<void> restoreSleep(String date) =>
      _store.restore(sleepEntriesTable, sleepEntryId(date));

  // ---- утренний план -------------------------------------------------------------

  Future<DailyPlan?> getPlan(String date) async {
    final row = await _live(dailyPlansTable, dailyPlanId(date));
    return row == null ? null : DailyPlan.fromRow(row);
  }

  /// Сохраняет утренний план на [date]: до 10 «главных дел»; выбранное
  /// «главное» добавляется в список, если его там нет.
  Future<void> savePlan({
    required String date,
    required List<String> taskIds,
    String? mainTaskId,
    String? note,
  }) async {
    final ids = <String>[
      ?mainTaskId,
      for (final id in taskIds)
        if (id != mainTaskId) id,
    ];
    // Порядок выбора сохраняется: главное — первым.
    final plan = DailyPlan(
      id: dailyPlanId(date),
      date: date,
      taskIds: ids,
      mainTaskId: mainTaskId,
      note: _blankToNull(note),
    );
    ensureValid(planProblem(plan));
    await _upsert(dailyPlansTable, plan.id, {
      'date': date,
      ...plan.toFields(),
    }, plan.toFields());
  }

  Future<void> deletePlan(String date) =>
      _delete(dailyPlansTable, dailyPlanId(date));

  // ---- вечерний чек-ин -------------------------------------------------------------

  Future<EveningCheckin?> getCheckin(String date) async {
    final row = await _live(eveningCheckinsTable, eveningCheckinId(date));
    return row == null ? null : EveningCheckin.fromRow(row);
  }

  /// Сохраняет чек-ин за [date]. Решения о переносе — журнал намерения;
  /// сами даты задач меняет [applyCarryOver].
  Future<void> saveCheckin({
    required String date,
    required List<String> doneTaskIds,
    List<CarryDecision> carryOver = const [],
    int? rating,
    String? note,
  }) async {
    final checkin = EveningCheckin(
      id: eveningCheckinId(date),
      date: date,
      rating: rating,
      doneTaskIds: doneTaskIds,
      carryOver: carryOver,
      note: _blankToNull(note),
    );
    ensureValid(checkinProblem(checkin));
    await _upsert(eveningCheckinsTable, checkin.id, {
      'date': date,
      ...checkin.toFields(),
    }, checkin.toFields());
  }

  Future<void> deleteCheckin(String date) =>
      _delete(eveningCheckinsTable, eveningCheckinId(date));

  // ---- перенос задач -------------------------------------------------------------------

  /// Считает перенос ([planCarryOver]) и применяет его обычными правками
  /// задач (срок целиком, `inbox` -> `todo`; всё через синхронизацию).
  /// Повторное применение безопасно: уже перенесённое даёт `unchanged` /
  /// `not_in_future`. Задачу, которую не удалось сохранить, пропускает с
  /// причиной `invalid`.
  Future<CarryOutcome> applyCarryOver(
    String checkinDate,
    List<CarryDecision> decisions,
  ) => _store.transaction(() async {
    final rows = await _store.visibleRows('tasks');
    final plan = planCarryOver(
      checkinDate,
      [for (final d in decisions) d.toJson()],
      [for (final r in rows) taskLinkRow(r)],
    );
    final moved = <CarryChange>[];
    final skipped = <CarryChange>[];
    for (final change in plan) {
      if (change.isSkip) {
        skipped.add(change);
        continue;
      }
      final task = await _tasks.getTask(change.taskId);
      if (task == null) {
        skipped.add(CarryChange.skip(change.taskId, 'not_found'));
        continue;
      }
      final due = change.action == CarryAction.setDueAt
          ? TaskDue.at(parseInstant(change.dueAt!)!, change.dueTz!)
          : TaskDue.date(parseDate(change.dueDate!)!);
      try {
        await _tasks.updateTask(
          task.copyWith(
            due: due,
            status: change.status == 'todo' ? TaskStatus.todo : task.status,
          ),
        );
        moved.add(change);
      } on ValidationError {
        skipped.add(CarryChange.skip(change.taskId, 'invalid'));
      }
    }
    return CarryOutcome(moved: moved, skipped: skipped);
  });
}

final sleepRepositoryProvider = Provider<SleepRepository>(
  (ref) => SleepRepository(
    ref.watch(syncStoreProvider),
    tasks: ref.watch(taskRepositoryProvider),
    now: ref.watch(clockProvider),
  ),
);
