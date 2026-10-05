import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart'
    show ValidationError, ensureValid;
import 'package:my_tasker/features/study/domain/study_ids.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_validation.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

/// Семестры, предметы, звонки, пары, особые дни, изменения на дату,
/// посещаемость, долги и метаданные вложений: локальные записи через
/// [SyncStore] (строка + HLC + outbox в одной транзакции). Проверки — как
/// на сервере (`study_validation.dart`).
///
/// Строки с естественным ключом (звонок, особый день, изменение на дату,
/// отметка) имеют детерминированный `id` (`study_ids.dart`): повторная
/// запись той же сущности правит или восстанавливает строку, а не создаёт
/// вторую.
class StudyRepository {
  StudyRepository(
    this._store, {
    TaskRepository? tasks,
    String Function()? newId,
    DateTime Function()? now,
  }) : _newId = newId ?? uuid7,
       _now = now ?? DateTime.now,
       _tasks = tasks ?? TaskRepository(_store, newId: newId, now: now);

  final SyncStore _store;
  final TaskRepository _tasks;
  final String Function() _newId;
  final DateTime Function() _now;

  static const String semestersTable = 'study_semesters';
  static const String subjectsTable = 'study_subjects';
  static const String bellsTable = 'study_bells';
  static const String slotsTable = 'class_slots';
  static const String rulesTable = 'study_day_rules';
  static const String overridesTable = 'class_overrides';
  static const String attendanceTable = 'study_attendance';
  static const String debtsTable = 'study_debts';
  static const String attachmentsTable = 'attachments';

  /// Новый UUIDv7 для строки.
  String newId() => _newId();

  /// Сегодняшняя дата (UTC-календарь часов; интерфейс подставляет свою,
  /// когда нужна дата в поясе устройства).
  String get _today => formatDate(_now().toUtc());

  Json _changed(Json before, Json after) => {
    for (final e in after.entries)
      if (_differs(before[e.key], e.value)) e.key: e.value,
  };

  bool _differs(Object? a, Object? b) {
    if (a is List && b is List) return a.toString() != b.toString();
    if (a is Map && b is Map) return a.toString() != b.toString();
    return a != b;
  }

  Future<void> _update(String table, String id, Json before, Json after) async {
    final fields = _changed(before, after);
    if (fields.isNotEmpty) await _store.update(table, id, fields);
  }

  /// Создаёт или правит строку с детерминированным [id]: новая —
  /// создаётся, удалённая — восстанавливается, изменившиеся изменяемые
  /// поля ([mutable]) — обновляются.
  Future<void> _upsert(String table, String id, Json all, Json mutable) =>
      _store.transaction(() async {
        final row = await _store.getRow(table, id);
        if (row == null) {
          await _store.create(table, id, all);
          return;
        }
        if (row['deleted_at'] != null) await _store.restore(table, id);
        await _update(table, id, row, mutable);
      });

  // ---- семестры --------------------------------------------------------------

  Future<Semester?> getSemester(String id) async {
    final row = await _store.getRow(semestersTable, id);
    return row == null ? null : Semester.fromRow(row);
  }

  /// Создаёт семестр; `semester.id` задаёт вызывающий ([newId]).
  Future<String> createSemester(Semester semester) async {
    final clean = semester.copyWith(name: semester.name.trim());
    ensureValid(semesterProblem(clean));
    await _store.create(semestersTable, clean.id, clean.toFields());
    return clean.id;
  }

  Future<void> updateSemester(Semester next) async {
    final clean = next.copyWith(name: next.name.trim());
    ensureValid(semesterProblem(clean));
    await _store.transaction(() async {
      final current = await getSemester(clean.id);
      if (current == null) throw StateError('Семестра ${clean.id} нет');
      await _update(
        semestersTable,
        clean.id,
        current.toFields(),
        clean.toFields(),
      );
    });
  }

  Future<void> setSemesterArchived(String id, {required bool archived}) async {
    final current = await getSemester(id);
    if (current == null || current.archived == archived) return;
    await _store.update(semestersTable, id, {'archived': archived});
  }

  Future<void> deleteSemester(String id) =>
      _store.softDelete(semestersTable, id);

  Future<void> restoreSemester(String id) => _store.restore(semestersTable, id);

  // ---- предметы --------------------------------------------------------------

  Future<Subject?> getSubject(String id) async {
    final row = await _store.getRow(subjectsTable, id);
    return row == null ? null : Subject.fromRow(row);
  }

  Future<String> createSubject(Subject subject) async {
    final clean = _cleanSubject(subject);
    ensureValid(subjectProblem(clean));
    await _store.create(subjectsTable, clean.id, {
      'semester_id': clean.semesterId,
      ...clean.toFields(),
    });
    return clean.id;
  }

  Subject _cleanSubject(Subject s) => s.copyWith(
    name: s.name.trim(),
    teacher: _blankToNull(s.teacher),
    building: _blankToNull(s.building),
    room: _blankToNull(s.room),
    note: _blankToNull(s.note),
  );

  Future<void> updateSubject(Subject next) async {
    final clean = _cleanSubject(next);
    ensureValid(subjectProblem(clean));
    await _store.transaction(() async {
      final current = await getSubject(clean.id);
      if (current == null) throw StateError('Предмета ${clean.id} нет');
      await _update(
        subjectsTable,
        clean.id,
        current.toFields(),
        clean.toFields(),
      );
    });
  }

  Future<void> setSubjectArchived(String id, {required bool archived}) async {
    final current = await getSubject(id);
    if (current == null || current.archived == archived) return;
    await _store.update(subjectsTable, id, {'archived': archived});
  }

  Future<void> deleteSubject(String id) => _store.softDelete(subjectsTable, id);

  Future<void> restoreSubject(String id) => _store.restore(subjectsTable, id);

  // ---- звонки ----------------------------------------------------------------

  /// Задаёт звонок пары [number]: [onDate] `null` — обычная сетка
  /// семестра, дата — звонок только на этот день.
  Future<void> saveBell({
    required String semesterId,
    required int number,
    required String startTime,
    required String endTime,
    String? onDate,
  }) async {
    ensureValid(bellProblem(number, startTime, endTime, onDate: onDate));
    final id = bellId(semesterId, onDate, number);
    await _upsert(
      bellsTable,
      id,
      {
        'semester_id': semesterId,
        'on_date': onDate,
        'number': number,
        'start_time': startTime,
        'end_time': endTime,
      },
      {'start_time': startTime, 'end_time': endTime},
    );
  }

  /// Убирает звонок пары [number] (обычный или на дату).
  Future<void> deleteBell({
    required String semesterId,
    required int number,
    String? onDate,
  }) async {
    final id = bellId(semesterId, onDate, number);
    if (await _store.getRow(bellsTable, id) != null) {
      await _store.softDelete(bellsTable, id);
    }
  }

  /// Заменяет сетку целиком: звонки [grid] записываются, остальные номера
  /// этой сетки (обычной или на [onDate]) удаляются.
  Future<void> replaceBells({
    required String semesterId,
    required List<Bell> grid,
    String? onDate,
  }) => _store.transaction(() async {
    final keep = {for (final b in grid) b.number};
    for (final b in grid) {
      await saveBell(
        semesterId: semesterId,
        number: b.number,
        startTime: b.startTime,
        endTime: b.endTime,
        onDate: onDate,
      );
    }
    final rows = await _store.visibleRows(
      bellsTable,
      where: onDate == null
          ? 't.semester_id = ? AND t.on_date IS NULL'
          : 't.semester_id = ? AND t.on_date = ?',
      args: [semesterId, ?onDate],
    );
    for (final row in rows) {
      final number = row['number']! as int;
      if (!keep.contains(number)) {
        await _store.softDelete(bellsTable, row['id']! as String);
      }
    }
  });

  /// Убирает все звонки «только на дату» [onDate] (день возвращается к
  /// обычной сетке).
  Future<void> clearDateBells(String semesterId, String onDate) =>
      replaceBells(semesterId: semesterId, grid: const [], onDate: onDate);

  // ---- пары ------------------------------------------------------------------

  Future<ClassSlot?> getSlot(String id) async {
    final row = await _store.getRow(slotsTable, id);
    return row == null ? null : ClassSlot.fromRow(row);
  }

  Future<String> createSlot(ClassSlot slot) async {
    final clean = _cleanSlot(slot);
    ensureValid(slotProblem(clean));
    await _store.create(slotsTable, clean.id, {
      'semester_id': clean.semesterId,
      ...clean.toFields(),
    });
    return clean.id;
  }

  ClassSlot _cleanSlot(ClassSlot s) => s.copyWith(
    title: _blankToNull(s.title),
    building: _blankToNull(s.building),
    room: _blankToNull(s.room),
  );

  Future<void> updateSlot(ClassSlot next) async {
    final clean = _cleanSlot(next);
    ensureValid(slotProblem(clean));
    await _store.transaction(() async {
      final current = await getSlot(clean.id);
      if (current == null) throw StateError('Пары ${clean.id} нет');
      await _update(slotsTable, clean.id, current.toFields(), clean.toFields());
    });
  }

  /// Удаляет пару вместе с её изменениями и отметками (каскад сервера);
  /// 30 дней можно восстановить.
  Future<void> deleteSlot(String id) => _store.softDelete(slotsTable, id);

  Future<void> restoreSlot(String id) => _store.restore(slotsTable, id);

  // ---- особые дни ------------------------------------------------------------

  /// Сохраняет особый день: правило на день недели или на дату (область
  /// неизменяема — по ней считается `id`). Возвращает `id` строки.
  Future<String> saveDayRule(String semesterId, DayRule rule) async {
    final clean = DayRule(
      id: '',
      semesterId: semesterId,
      weekday: rule.weekday,
      onDate: rule.onDate,
      cycleWeek: rule.cycleWeek,
      title: rule.title.trim(),
      hideRegular: rule.hideRegular,
      items: rule.items,
    );
    ensureValid(dayRuleProblem(clean));
    final id = dayRuleId(
      semesterId,
      weekday: clean.weekday,
      onDate: clean.onDate,
      cycleWeek: clean.cycleWeek,
    );
    await _upsert(
      rulesTable,
      id,
      clean.toFields(semesterId),
      clean.toMutableFields(),
    );
    return id;
  }

  Future<void> deleteDayRule(String id) => _store.softDelete(rulesTable, id);

  Future<void> restoreDayRule(String id) => _store.restore(rulesTable, id);

  // ---- изменения на дату -------------------------------------------------------

  /// Задаёт изменение пары на дату [ClassOverride.date] (дата по
  /// расписанию): одно изменение на пару и дату. У отмены остальные поля
  /// не пишутся.
  Future<String> saveOverride(ClassOverride value) async {
    final clean = value.action == OverrideAction.cancel
        ? ClassOverride(
            slotId: value.slotId,
            date: value.date,
            action: OverrideAction.cancel,
          )
        : ClassOverride(
            slotId: value.slotId,
            date: value.date,
            action: value.action,
            newDate: value.action == OverrideAction.move ? value.newDate : null,
            startTime: value.startTime,
            endTime: value.endTime,
            building: _blankToNull(value.building),
            room: _blankToNull(value.room),
            subjectId: value.subjectId,
            title: _blankToNull(value.title),
            lessonKind: value.lessonKind,
          );
    ensureValid(overrideProblem(clean));
    final id = overrideId(clean.slotId, clean.date);
    await _upsert(overridesTable, id, {
      'slot_id': clean.slotId,
      'date': clean.date,
      ...clean.toMutableFields(),
    }, clean.toMutableFields());
    return id;
  }

  /// Убирает изменение пары на дату (пара снова идёт по расписанию).
  Future<void> clearOverride(String slotId, String date) async {
    final id = overrideId(slotId, date);
    if (await _store.getRow(overridesTable, id) != null) {
      await _store.softDelete(overridesTable, id);
    }
  }

  // ---- посещаемость ------------------------------------------------------------

  /// Отмечает занятие (пара [slotId] на дату по расписанию [date]).
  Future<String> mark(
    String slotId,
    String date,
    AttendanceStatus status, {
    String? note,
  }) async {
    final cleanNote = _blankToNull(note);
    ensureValid(attendanceProblem(date, cleanNote));
    final id = attendanceId(slotId, date);
    await _upsert(
      attendanceTable,
      id,
      {
        'slot_id': slotId,
        'date': date,
        'status': status.wire,
        'note': cleanNote,
      },
      {'status': status.wire, 'note': cleanNote},
    );
    return id;
  }

  /// Снимает отметку («не отмечено»).
  Future<void> unmark(String slotId, String date) async {
    final id = attendanceId(slotId, date);
    if (await _store.getRow(attendanceTable, id) != null) {
      await _store.softDelete(attendanceTable, id);
    }
  }

  // ---- долги -------------------------------------------------------------------

  Future<StudyDebt?> getDebt(String id) async {
    final row = await _store.getRow(debtsTable, id);
    return row == null ? null : StudyDebt.fromRow(row);
  }

  Future<String> createDebt(StudyDebt debt) async {
    final clean = _cleanDebt(debt);
    ensureValid(debtProblem(clean));
    await _store.create(debtsTable, clean.id, {
      'subject_id': clean.subjectId,
      ...clean.toFields(),
    });
    return clean.id;
  }

  StudyDebt _cleanDebt(StudyDebt d) => d.copyWith(
    title: d.title.trim(),
    note: _blankToNull(d.note),
    // Дата сдачи — только у сданного и зачтённого долга.
    doneDate: d.status == DebtStatus.open ? null : d.doneDate,
  );

  Future<void> updateDebt(StudyDebt next) async {
    final clean = _cleanDebt(next);
    ensureValid(debtProblem(clean));
    await _store.transaction(() async {
      final current = await getDebt(clean.id);
      if (current == null) throw StateError('Долга ${clean.id} нет');
      await _update(debtsTable, clean.id, current.toFields(), clean.toFields());
    });
  }

  /// Меняет статус долга; сдача ставит дату сдачи (сегодня, если не
  /// задана), возврат в «не сдана» убирает.
  Future<void> setDebtStatus(
    String id,
    DebtStatus status, {
    String? today,
  }) async {
    final debt = await getDebt(id);
    if (debt == null) return;
    await updateDebt(
      debt.copyWith(
        status: status,
        doneDate: status == DebtStatus.open
            ? null
            : (debt.doneDate ?? today ?? _today),
      ),
    );
  }

  Future<void> deleteDebt(String id) => _store.softDelete(debtsTable, id);

  Future<void> restoreDebt(String id) => _store.restore(debtsTable, id);

  /// Задача [taskId] жива (есть и не в корзине): ссылка долга ещё
  /// действует.
  Future<bool> hasLiveTask(String taskId) async {
    final row = await _store.getRow(TaskRepository.tasksTable, taskId);
    return row != null && row['deleted_at'] == null;
  }

  /// «Создать задачу» по долгу: задача Этапа 2 со сроком долга; ссылка
  /// хранится на стороне долга (`task_id`). Возвращает `id` задачи; если
  /// задача уже создана и жива — её `id`.
  Future<String> createTaskForDebt(
    String debtId, {
    required String subjectName,
  }) => _store.transaction(() async {
    final debt = await getDebt(debtId);
    if (debt == null) throw StateError('Долга $debtId нет');
    final existing = debt.taskId;
    if (existing != null && await hasLiveTask(existing)) return existing;
    final due = parseDate(debt.dueDate ?? '');
    final taskId = _newId();
    await _tasks.createTask(
      TaskEntity(
        id: taskId,
        title: '${debt.title} · $subjectName',
        status: TaskStatus.todo,
        due: due == null ? const TaskDue.none() : TaskDue.date(due),
        notes:
            'Учебный долг: ${debt.kind.label.toLowerCase()} по предмету '
            '«$subjectName».',
      ),
    );
    await _store.update(debtsTable, debtId, {'task_id': taskId});
    return taskId;
  });

  // ---- вложения ----------------------------------------------------------------

  /// Вложения, которые ещё не загружены на сервер (`pending`).
  Future<List<Attachment>> pendingUploads() async => [
    for (final r in await _store.visibleRows(
      attachmentsTable,
      where: "t.upload_status = 'pending'",
      orderBy: 't.created_at, t.id',
    ))
      Attachment.fromRow(r),
  ];

  /// Строка вложения уже подтверждена сервером (метаданные синхронизированы):
  /// только тогда `PUT /files/{id}` найдёт строку.
  Future<bool> isSynced(String id) async {
    final row = await _store.getRow(attachmentsTable, id);
    return row != null && (row['server_version'] as int? ?? 0) > 0;
  }

  Future<Attachment?> getAttachment(String id) async {
    final row = await _store.getRow(attachmentsTable, id);
    return row == null ? null : Attachment.fromRow(row);
  }

  /// Создаёт метаданные вложения (файл уже лежит на устройстве).
  Future<String> createAttachment(Attachment attachment) async {
    ensureValid(attachmentProblem(attachment));
    await _store.create(attachmentsTable, attachment.id, attachment.toFields());
    return attachment.id;
  }

  /// Файл загружен на сервер: `upload_status = uploaded` обычной правкой.
  Future<void> markUploaded(String id) async {
    final current = await getAttachment(id);
    if (current == null || current.uploadStatus == UploadStatus.uploaded) {
      return;
    }
    await _store.update(attachmentsTable, id, {
      'upload_status': UploadStatus.uploaded.wire,
    });
  }

  Future<void> renameAttachment(String id, String fileName) async {
    final current = await getAttachment(id);
    if (current == null) return;
    final name = fileName.trim();
    ensureValid(fileNameProblem(name));
    final extensions = allowedFiles[current.mimeType] ?? const <String>[];
    if (!extensions.contains(fileExtension(name))) {
      throw const ValidationError('Расширение файла не подходит к его типу');
    }
    if (name != current.fileName) {
      await _store.update(attachmentsTable, id, {'file_name': name});
    }
  }

  Future<void> deleteAttachment(String id) =>
      _store.softDelete(attachmentsTable, id);

  Future<void> restoreAttachment(String id) =>
      _store.restore(attachmentsTable, id);
}

String? _blankToNull(String? text) {
  final t = text?.trim();
  return t == null || t.isEmpty ? null : t;
}

final Provider<StudyRepository> studyRepositoryProvider =
    Provider<StudyRepository>(
      (ref) => StudyRepository(
        ref.watch(syncStoreProvider),
        tasks: ref.watch(taskRepositoryProvider),
        now: ref.watch(clockProvider),
      ),
    );
