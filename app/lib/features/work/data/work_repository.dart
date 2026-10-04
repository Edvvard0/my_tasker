import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/domain/work_validation.dart';

/// Черновик распределения платежа: на проект ([changeRequestId] `null` —
/// оплата базовой суммы) или на его доработку.
class AllocationDraft {
  const AllocationDraft({
    required this.projectId,
    required this.amount,
    this.changeRequestId,
  });

  final String projectId;
  final String? changeRequestId;
  final int amount;

  /// Ключ «куда»: по нему правка платежа сопоставляет строки.
  String get key => '$projectId|${changeRequestId ?? ''}';
}

/// Итог запуска таймера: новая запись и остановленные ради неё идущие.
class TimerStartResult {
  const TimerStartResult({required this.started, required this.stopped});

  final TimeEntry started;

  /// Записи, остановленные при старте («Один таймер на устройстве»).
  final List<TimeEntry> stopped;
}

/// Проекты, доработки, платежи, распределения, люди и учёт времени:
/// локальные записи через [SyncStore] (строка + HLC + outbox в одной
/// транзакции). Проверки — как на сервере, плюс правила нескольких строк,
/// которые сервер не проверяет (spec 3.3).
class WorkRepository {
  WorkRepository(
    this._store, {
    String Function()? newId,
    DateTime Function()? now,
  }) : _newId = newId ?? uuid7,
       _now = now ?? DateTime.now;

  final SyncStore _store;
  final String Function() _newId;
  final DateTime Function() _now;

  static const String projectsTable = 'projects';
  static const String peopleTable = 'people';
  static const String changeRequestsTable = 'change_requests';
  static const String paymentsTable = 'payments';
  static const String allocationsTable = 'payment_allocations';
  static const String timeEntriesTable = 'time_entries';

  DateTime get _nowUtc => _now().toUtc();

  /// Новый UUIDv7 для строки.
  String newId() => _newId();

  // ---- проекты --------------------------------------------------------------

  Future<WorkProject?> getProject(String id) async {
    final row = await _store.getRow(projectsTable, id);
    return row == null ? null : WorkProject.fromRow(row);
  }

  /// Создаёт проект; `project.id` задаёт вызывающий ([newId]).
  Future<String> createProject(WorkProject project) async {
    final clean = project.copyWith(title: project.title.trim());
    ensureValid(projectProblem(clean));
    await _store.create(projectsTable, clean.id, clean.toFields());
    return clean.id;
  }

  /// Правка проекта: уходят только изменившиеся поля.
  Future<void> updateProject(WorkProject next) async {
    final clean = next.copyWith(title: next.title.trim());
    ensureValid(projectProblem(clean));
    await _store.transaction(() async {
      final current = await getProject(clean.id);
      if (current == null) throw StateError('Проекта ${clean.id} нет');
      final before = current.toFields();
      final after = clean.toFields();
      final fields = <String, Object?>{
        for (final e in after.entries)
          if (_differs(before[e.key], e.value)) e.key: e.value,
      };
      if (fields.isNotEmpty) {
        await _store.update(projectsTable, clean.id, fields);
      }
    });
  }

  /// Статус проекта; при «завершён» без даты ставит сегодняшнюю.
  Future<void> setProjectStatus(
    String id,
    ProjectStatus status, {
    String? completedDate,
  }) async {
    final project = await getProject(id);
    if (project == null) return;
    var next = project.copyWith(status: status);
    if (status == ProjectStatus.completed && next.completedDate == null) {
      next = next.copyWith(completedDate: completedDate ?? formatDate(_nowUtc));
    }
    // Возврат в работу снимает архив: в архиве только завершённые.
    if (!status.archivable && next.archived) {
      next = next.copyWith(archived: false);
    }
    await updateProject(next);
  }

  /// В архив уходят только завершённые и отменённые проекты (решение 6);
  /// из архива можно вернуть любой.
  Future<void> setArchived(String id, {required bool archived}) async {
    final project = await getProject(id);
    if (project == null) return;
    if (archived && !project.effectiveStatus.archivable) {
      throw const ValidationError(
        'В архив уходит только завершённый или отменённый проект',
      );
    }
    if (project.archived == archived) return;
    await _store.update(projectsTable, id, {'archived': archived});
  }

  Future<void> deleteProject(String id) => _store.softDelete(projectsTable, id);

  Future<void> restoreProject(String id) => _store.restore(projectsTable, id);

  // ---- люди ---------------------------------------------------------------------

  Future<WorkPerson?> getPerson(String id) async {
    final row = await _store.getRow(peopleTable, id);
    return row == null ? null : WorkPerson.fromRow(row);
  }

  Future<String> createPerson(WorkPerson person) async {
    final clean = person.copyWith(name: person.name.trim());
    ensureValid(personProblem(clean));
    await _store.create(peopleTable, clean.id, clean.toFields());
    return clean.id;
  }

  Future<void> updatePerson(WorkPerson next) async {
    final clean = next.copyWith(name: next.name.trim());
    ensureValid(personProblem(clean));
    await _store.transaction(() async {
      final current = await getPerson(clean.id);
      if (current == null) throw StateError('Человека ${clean.id} нет');
      final before = current.toFields();
      final after = clean.toFields();
      final fields = <String, Object?>{
        for (final e in after.entries)
          if (_differs(before[e.key], e.value)) e.key: e.value,
      };
      if (fields.isNotEmpty) {
        await _store.update(peopleTable, clean.id, fields);
      }
    });
  }

  Future<void> setPersonArchived(String id, {required bool archived}) =>
      _store.update(peopleTable, id, {'archived': archived});

  /// Удаление человека не трогает проекты и платежи (spec 2): ссылки
  /// остаются, интерфейс показывает «заказчик не указан».
  Future<void> deletePerson(String id) => _store.softDelete(peopleTable, id);

  Future<void> restorePerson(String id) => _store.restore(peopleTable, id);

  // ---- доработки ----------------------------------------------------------------------

  Future<ChangeRequest?> getChangeRequest(String id) async {
    final row = await _store.getRow(changeRequestsTable, id);
    return row == null ? null : ChangeRequest.fromRow(row);
  }

  Future<String> createChangeRequest(ChangeRequest request) async {
    final clean = request.copyWith(title: request.title.trim());
    ensureValid(changeRequestProblem(clean));
    await _store.create(changeRequestsTable, clean.id, {
      'project_id': clean.projectId,
      ...clean.toFields(),
    });
    return clean.id;
  }

  Future<void> updateChangeRequest(ChangeRequest next) async {
    final clean = next.copyWith(title: next.title.trim());
    ensureValid(changeRequestProblem(clean));
    await _store.transaction(() async {
      final current = await getChangeRequest(clean.id);
      if (current == null) throw StateError('Доработки ${clean.id} нет');
      final before = current.toFields();
      final after = clean.toFields();
      final fields = <String, Object?>{
        for (final e in after.entries)
          if (_differs(before[e.key], e.value)) e.key: e.value,
      };
      if (fields.isNotEmpty) {
        await _store.update(changeRequestsTable, clean.id, fields);
      }
    });
  }

  /// Смена статуса доработки: «закрыта» ставит дату закрытия (сегодня,
  /// если не задана), остальные статусы дату не трогают (spec 1.3).
  Future<void> setChangeRequestStatus(
    String id,
    ChangeRequestStatus status, {
    String? closedDate,
  }) async {
    final current = await getChangeRequest(id);
    if (current == null) return;
    var next = current.copyWith(status: status);
    if (status == ChangeRequestStatus.closed && next.closedDate == null) {
      next = next.copyWith(closedDate: closedDate ?? formatDate(_nowUtc));
    }
    await updateChangeRequest(next);
  }

  /// Удаление доработки ничего не каскадирует (spec 2): полученные деньги
  /// остаются в «получено» проекта как оплата базовой суммы.
  Future<void> deleteChangeRequest(String id) =>
      _store.softDelete(changeRequestsTable, id);

  Future<void> restoreChangeRequest(String id) =>
      _store.restore(changeRequestsTable, id);

  // ---- платежи и распределения ---------------------------------------------------------

  Future<Payment?> getPayment(String id) async {
    final row = await _store.getRow(paymentsTable, id);
    return row == null ? null : Payment.fromRow(row);
  }

  Future<List<Allocation>> allocationsOfPayment(String paymentId) async => [
    for (final r in await _store.visibleRows(
      allocationsTable,
      where: 't.payment_id = ?',
      args: [paymentId],
      orderBy: 't.created_at, t.id',
    ))
      Allocation.fromRow(r),
  ];

  /// Доработки, на которые ссылаются строки распределения: нужны, чтобы
  /// проверить, что доработка принадлежит проекту строки.
  Future<List<ChangeRequest>> _referencedChangeRequests(
    List<AllocationDraft> drafts,
  ) async {
    final ids = {
      for (final d in drafts)
        if (d.changeRequestId != null) d.changeRequestId,
    };
    if (ids.isEmpty) return const [];
    return [
      for (final r in await _store.visibleRows(changeRequestsTable))
        if (ids.contains(r['id'])) ChangeRequest.fromRow(r),
    ];
  }

  List<Allocation> _asAllocations(String paymentId, List<AllocationDraft> d) =>
      [
        for (final a in d)
          Allocation(
            id: '',
            paymentId: paymentId,
            projectId: a.projectId,
            changeRequestId: a.changeRequestId,
            amount: a.amount,
          ),
      ];

  /// Проверка платежа с распределениями до записи.
  Future<void> _validatePayment(
    Payment payment,
    List<AllocationDraft> drafts,
  ) async {
    ensureValid(paymentProblem(payment));
    final keys = <String>{};
    for (final d in drafts) {
      if (!keys.add(d.key)) {
        throw const ValidationError(
          'Одно и то же назначение указано дважды — объедините строки',
        );
      }
    }
    final crs = await _referencedChangeRequests(drafts);
    ensureValid(
      allocationsProblem(payment, _asAllocations(payment.id, drafts), crs),
    );
  }

  /// Создаёт платёж и его распределения одной транзакцией. Сумма
  /// распределений не больше суммы платежа (проверяет клиент, spec 3.3).
  Future<String> createPayment(
    Payment payment,
    List<AllocationDraft> allocations,
  ) async {
    await _validatePayment(payment, allocations);
    await _store.transaction(() async {
      await _store.create(paymentsTable, payment.id, payment.toFields());
      for (final a in allocations) {
        await _store.create(allocationsTable, _newId(), {
          'payment_id': payment.id,
          'project_id': a.projectId,
          'change_request_id': a.changeRequestId,
          'amount': a.amount,
        });
      }
    });
    return payment.id;
  }

  /// Правка платежа и набора распределений: те же «куда» обновляют сумму,
  /// новые создаются, пропавшие удаляются (распределение нельзя
  /// «перенести» — только удалить и создать, spec 1.5).
  Future<void> updatePayment(
    Payment next,
    List<AllocationDraft> allocations,
  ) async {
    await _validatePayment(next, allocations);
    await _store.transaction(() async {
      final current = await getPayment(next.id);
      if (current == null) throw StateError('Платежа ${next.id} нет');
      final before = current.toFields();
      final after = next.toFields();
      final fields = <String, Object?>{
        for (final e in after.entries)
          if (_differs(before[e.key], e.value)) e.key: e.value,
      };
      if (fields.isNotEmpty) {
        await _store.update(paymentsTable, next.id, fields);
      }

      // После синхронизации с двух устройств на одно «куда» могут оказаться
      // несколько строк: оставляем первую, остальные удаляем, иначе их
      // суммы двоились бы в «получено».
      final existing = <String, List<Allocation>>{};
      for (final a in await allocationsOfPayment(next.id)) {
        existing
            .putIfAbsent('${a.projectId}|${a.changeRequestId ?? ''}', () => [])
            .add(a);
      }
      final wanted = {for (final d in allocations) d.key: d};
      for (final e in existing.entries) {
        final keep = wanted.containsKey(e.key) ? 1 : 0;
        for (final extra in e.value.skip(keep)) {
          await _store.softDelete(allocationsTable, extra.id);
        }
      }
      for (final e in wanted.entries) {
        final old = existing[e.key]?.first;
        if (old == null) {
          await _store.create(allocationsTable, _newId(), {
            'payment_id': next.id,
            'project_id': e.value.projectId,
            'change_request_id': e.value.changeRequestId,
            'amount': e.value.amount,
          });
        } else if (old.amount != e.value.amount) {
          await _store.update(allocationsTable, old.id, {
            'amount': e.value.amount,
          });
        }
      }
    });
  }

  /// Удаление платежа: распределения уходят каскадом на сервере; клиент
  /// скрывает их видимостью (spec 2).
  Future<void> deletePayment(String id) => _store.softDelete(paymentsTable, id);

  Future<void> restorePayment(String id) => _store.restore(paymentsTable, id);

  // ---- учёт времени ----------------------------------------------------------------------

  Future<TimeEntry?> getEntry(String id) async {
    final row = await _store.getRow(timeEntriesTable, id);
    return row == null ? null : TimeEntry.fromRow(row);
  }

  /// Идущие таймеры (видимые записи без `ended_at`), старые первыми.
  Future<List<TimeEntry>> runningEntries() async => [
    for (final r in await _store.visibleRows(
      timeEntriesTable,
      where: 't.ended_at IS NULL',
      orderBy: 't.started_at, t.id',
    ))
      TimeEntry.fromRow(r),
  ];

  /// Запись времени вручную (оба момента заданы).
  Future<String> addManualEntry(TimeEntry entry) async {
    final manual = TimeEntry(
      id: entry.id,
      projectId: entry.projectId,
      changeRequestId: entry.changeRequestId,
      taskId: entry.taskId,
      startedAt: entry.startedAt,
      endedAt: entry.endedAt,
      billable: entry.billable,
      note: entry.note,
      source: TimeSource.manual,
    );
    ensureValid(timeEntryProblem(manual));
    await _store.create(timeEntriesTable, manual.id, manual.toFields());
    return manual.id;
  }

  /// Правка записи (проект можно переназначить, spec 1.6).
  Future<void> updateEntry(TimeEntry next) async {
    ensureValid(timeEntryProblem(next));
    await _store.transaction(() async {
      final current = await getEntry(next.id);
      if (current == null) throw StateError('Записи ${next.id} нет');
      final before = current.toFields();
      final after = next.toFields()..remove('source');
      final fields = <String, Object?>{
        for (final e in after.entries)
          if (_differs(before[e.key], e.value)) e.key: e.value,
      };
      if (fields.isNotEmpty) {
        await _store.update(timeEntriesTable, next.id, fields);
      }
    });
  }

  Future<void> deleteEntry(String id) =>
      _store.softDelete(timeEntriesTable, id);

  Future<void> restoreEntry(String id) => _store.restore(timeEntriesTable, id);

  /// Момент остановки: не раньше начала и короче 14 суток (забытый таймер
  /// не даёт абсурдных часов, spec 1.6).
  DateTime stopMoment(TimeEntry entry, DateTime now) {
    var end = now.toUtc();
    if (end.isBefore(entry.startedAt)) end = entry.startedAt;
    final cap = entry.startedAt.add(
      maxEntryLength - const Duration(seconds: 1),
    );
    return end.isAfter(cap) ? cap : end;
  }

  /// Запускает таймер. Идущие на устройстве записи (в том числе
  /// пришедшие с другого устройства) останавливаются: «одновременно идёт
  /// только один таймер» (02, 4.11). Запуск идемпотентен: если уже идёт
  /// таймер на том же проекте, доработке и задаче (двойной тап), он и
  /// возвращается, новая запись не создаётся.
  Future<TimerStartResult> startTimer({
    required String projectId,
    String? changeRequestId,
    String? taskId,
    String? note,
    bool billable = true,
  }) async {
    late TimerStartResult result;
    await _store.transaction(() async {
      final now = _nowUtc;
      final stopped = <TimeEntry>[];
      final all = await runningEntries();
      TimeEntry? same;
      for (final running in all) {
        if (running.projectId == projectId &&
            running.changeRequestId == changeRequestId &&
            running.taskId == taskId) {
          same = running; // самый поздний по началу (список по возрастанию)
        }
      }
      for (final running in all) {
        if (same != null && running.id == same.id) continue;
        final end = stopMoment(running, now);
        await _store.update(timeEntriesTable, running.id, {
          'ended_at': storedWorkInstant(end),
        });
        stopped.add(running.copyWith(endedAt: end));
      }
      if (same != null) {
        result = TimerStartResult(started: same, stopped: stopped);
        return;
      }
      final entry = TimeEntry(
        id: _newId(),
        projectId: projectId,
        changeRequestId: changeRequestId,
        taskId: taskId,
        startedAt: now,
        billable: billable,
        note: note,
        source: TimeSource.timer,
      );
      ensureValid(timeEntryProblem(entry));
      await _store.create(timeEntriesTable, entry.id, entry.toFields());
      result = TimerStartResult(started: entry, stopped: stopped);
    });
    return result;
  }

  /// Останавливает идущую запись; возвращает её с `ended_at` (или `null`,
  /// если записи нет или она уже остановлена — например, с другого
  /// устройства).
  Future<TimeEntry?> stopTimer(String id) async {
    TimeEntry? stopped;
    await _store.transaction(() async {
      final entry = await getEntry(id);
      if (entry == null || !entry.isRunning) return;
      final end = stopMoment(entry, _nowUtc);
      await _store.update(timeEntriesTable, id, {
        'ended_at': storedWorkInstant(end),
      });
      stopped = entry.copyWith(endedAt: end);
    });
    return stopped;
  }

  /// «Отменить запись»: идущий таймер удаляется (в корзину на 30 дней).
  Future<void> discardTimer(String id) => deleteEntry(id);

  bool _differs(Object? a, Object? b) {
    if (a is List && b is List) return a.toString() != b.toString();
    return a != b;
  }
}

final workRepositoryProvider = Provider<WorkRepository>(
  (ref) => WorkRepository(
    ref.watch(syncStoreProvider),
    now: ref.watch(clockProvider),
  ),
);
