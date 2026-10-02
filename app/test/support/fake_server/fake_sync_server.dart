import 'dart:async';
import 'dart:math';

import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_table.dart';

import 'merge_decisions.dart';

/// Ошибка сервера в стандартной форме (spec 0).
ApiException serverError(
  int status,
  String code, [
  Map<String, Object?> details = const {},
]) => ApiException(
  kind: ApiErrorKind.http,
  status: status,
  code: code,
  message: code,
  details: details,
);

class _Row {
  _Row(this.table, this.id, this.createdAt, this.updatedAt, this.origin);

  final String table;
  final String id;
  String createdAt;
  String updatedAt;
  String origin;
  int version = 0;
  String? deletedAt;
  final Map<String, Object?> values = {};
  final Map<String, FieldEntry> entries = {};

  /// Родитель, каскадом удаливший строку.
  String? cascadeOf;

  _Row copy() {
    final r = _Row(table, id, createdAt, updatedAt, origin)
      ..version = version
      ..deletedAt = deletedAt
      ..cascadeOf = cascadeOf;
    r.values.addAll(deepCopy(values));
    r.entries.addAll(entries);
    return r;
  }
}

/// Запись журнала конфликтов (spec 3.9).
class ConflictRecord {
  ConflictRecord({
    required this.id,
    required this.createdAt,
    required this.table,
    required this.rowId,
    required this.field,
    required this.kind,
    required this.losingValue,
    required this.winningValue,
    required this.losingDevice,
    required this.winningDevice,
    required this.losingHlc,
    required this.winningHlc,
    required this.opId,
  });

  final String id;
  final String createdAt;
  final String table;
  final String rowId;
  final String field;
  final String kind;
  final Object? losingValue;
  final Object? winningValue;
  final String? losingDevice;
  final String? winningDevice;
  final String? losingHlc;
  final String? winningHlc;
  final String opId;
  String? revertedAt;

  Json toJson() => {
    'id': id,
    'created_at': createdAt,
    'table': table,
    'row_id': rowId,
    'field': field,
    'kind': kind,
    'losing_value': losingValue,
    'winning_value': winningValue,
    'losing_device_id': losingDevice,
    'winning_device_id': winningDevice,
    'losing_hlc': losingHlc,
    'winning_hlc': winningHlc,
    'reverted_at': revertedAt,
  };
}

/// Сервер синхронизации из spec 3 (слияние 3.4, каскады 3.5, pull 3.6,
/// очистка 3.8, конфликты 3.9) в памяти. Отвечает JSON-объектами в форме
/// API; ошибки — [ApiException]. Реализован независимо от клиента, по
/// тексту спецификации и общим векторам (`merge.json`).
class FakeSyncServer {
  FakeSyncServer({
    required this.registry,
    required this.nowMs,
    this.maxFutureDriftMs = 600000,
  });

  final SyncRegistry registry;
  final int Function() nowMs;
  final int maxFutureDriftMs;

  int head = 0;
  int purgeWatermark = 0;

  /// Идентификатор «эпохи»: меняется при восстановлении из копии.
  String? epoch = 'epoch-1';

  /// Строки, операции над которыми сервер отклоняет с `op_failed`.
  final Set<String> failOpRowIds = <String>{};
  final Map<(String, String), _Row> _rows = {};
  final Map<String, Json> _opLog = {};
  final Map<String, int> deviceCursors = {};
  final List<ConflictRecord> conflicts = [];
  final StreamController<({int head, String origin})> _commits =
      StreamController<({int head, String origin})>.broadcast();

  /// Число операций, обработанных `push` (без дубликатов).
  int processedOps = 0;

  /// Тела обработанных операций по `op_id` (для проверок в тестах).
  final Map<String, Json> processedBodies = {};

  /// Результат обработки операции (`status`, `server_version`, …).
  Json? resultOf(String opId) => _opLog[opId];

  /// Число вызовов `push` / `pull`.
  int pushCalls = 0;
  int pullCalls = 0;
  final List<int> pushSizes = [];

  /// Фиксация транзакции push/revert: другим устройствам уходит `changes`.
  Stream<({int head, String origin})> get commits => _commits.stream;

  // ---- резервная копия ------------------------------------------------------

  /// Снимок состояния (как резервная копия БД).
  Object backup() => (
    head,
    purgeWatermark,
    {for (final e in _rows.entries) e.key: e.value.copy()},
    Map<String, Json>.of(_opLog),
    List<ConflictRecord>.of(conflicts),
  );

  /// Восстановление из копии: состояние откатывается, «эпоха» меняется.
  void restore(Object backup, {required String newEpoch}) {
    final (h, w, rows, ops, log) =
        backup
            as (
              int,
              int,
              Map<(String, String), _Row>,
              Map<String, Json>,
              List<ConflictRecord>,
            );
    head = h;
    purgeWatermark = w;
    _rows
      ..clear()
      ..addAll({for (final e in rows.entries) e.key: e.value.copy()});
    _opLog
      ..clear()
      ..addAll(ops);
    conflicts
      ..clear()
      ..addAll(log);
    epoch = newEpoch;
  }

  // ---- чтение ---------------------------------------------------------------

  /// Строки таблицы в JSON-виде (в т.ч. надгробия), для проверок в тестах.
  Map<String, Json> snapshot(String table) => {
    for (final e in _rows.entries)
      if (e.key.$1 == table) e.key.$2: _wire(e.value),
  };

  Json? row(String table, String id) {
    final r = _rows[(table, id)];
    return r == null ? null : _wire(r);
  }

  Json _wire(_Row r) => {
    'id': r.id,
    'created_at': r.createdAt,
    'updated_at': r.updatedAt,
    'deleted_at': r.deletedAt,
    'server_version': r.version,
    'origin_device_id': r.origin,
    ...deepCopy(r.values),
  };

  // ---- pull -------------------------------------------------------------------

  Json pull(String device, int since, int limit) {
    pullCalls++;
    if (since < 0 || limit < 1 || limit > 1000) {
      throw serverError(422, 'validation_error');
    }
    if (since > head) {
      // Курсор клиента опережает сервер: сервер восстановлен из старой
      // копии (spec 3.6, 3.10). Курсор устройства не сохраняется.
      throw serverError(410, 'resync_required', {
        'purge_watermark': purgeWatermark,
        'head_version': head,
        'reason': 'cursor_ahead',
      });
    }
    if (since > 0 && since < purgeWatermark) {
      throw serverError(410, 'resync_required', {
        'purge_watermark': purgeWatermark,
        'head_version': head,
        'reason': 'purged',
      });
    }
    final all = _rows.values.where((r) => r.version > since).toList()
      ..sort((a, b) => a.version.compareTo(b.version));
    final page = all.take(limit).toList();
    final hasMore = all.length > page.length;
    deviceCursors[device] = since;
    return {
      'server_epoch': ?epoch,
      'changes': [
        for (final r in page)
          {
            'table': r.table,
            'id': r.id,
            'server_version': r.version,
            'row': _wire(r),
          },
      ],
      'next_since': hasMore ? page.last.version : head,
      'has_more': hasMore,
      'head_version': head,
      'purge_watermark': purgeWatermark,
      'server_time': msIso(nowMs()),
    };
  }

  // ---- push -------------------------------------------------------------------

  Json push(String device, List<Object?> ops) {
    pushCalls++;
    pushSizes.add(ops.length);
    if (ops.isEmpty) throw serverError(422, 'validation_error');
    if (ops.length > 500) throw serverError(413, 'batch_too_large');
    final before = head;
    final results = [for (final op in ops) _process(device, op)];
    if (head != before) _commits.add((head: head, origin: device));
    return {
      'server_epoch': ?epoch,
      'results': results,
      'head_version': head,
      'server_time': msIso(nowMs()),
    };
  }

  Json _rejected(String opId, String code, String message) => {
    'op_id': opId,
    'status': 'rejected',
    'code': code,
    'message': message,
    'server_version': null,
    'conflicts': 0,
    'duplicate': false,
  };

  Json _process(String device, Object? raw) {
    if (raw is! Map) return _rejected('', 'invalid_op', 'not an object');
    final op = raw.cast<String, Object?>();
    final opId = op['op_id'];
    final table = op['table'];
    final id = op['id'];
    final type = op['type'];
    final hlc = op['hlc'];
    final base = op['base_version'];
    if (opId is! String ||
        table is! String ||
        id is! String ||
        type is! String ||
        hlc is! String ||
        base is! int ||
        (type != OpType.upsert && type != OpType.delete)) {
      return _rejected(opId is String ? opId : '', 'invalid_op', 'shape');
    }
    if (!isUuid7(opId) || !isUuid(id)) {
      return _rejected(opId, 'invalid_id', 'id must be a uuid');
    }
    final logged = _opLog[opId];
    if (logged != null) return {...logged, 'duplicate': true};
    if (!isValidHlc(hlc)) return _rejected(opId, 'invalid_hlc', 'format');
    if (hlcDevice(hlc) != device) {
      return _remember(
        _rejected(opId, 'hlc_device_mismatch', 'device in hlc != token'),
      );
    }
    if (hlcMs(hlc) > nowMs() + maxFutureDriftMs) {
      // Не запоминается: клиент может отправить то же позже.
      return _rejected(opId, 'hlc_in_future', 'clock is ahead');
    }
    final spec = registry.maybeSpec(table);
    if (spec == null) {
      return _remember(_rejected(opId, 'unknown_table', table));
    }
    final rawFields = op['fields'];
    if (type == OpType.upsert && rawFields is! Map) {
      return _remember(_rejected(opId, 'invalid_op', 'fields'));
    }
    final fields = rawFields is Map
        ? rawFields.cast<String, Object?>()
        : <String, Object?>{};
    if (failOpRowIds.contains(id)) {
      // Страховочный код (spec 3.3): операцию не удалось применить.
      return _remember(_rejected(opId, 'op_failed', 'internal failure'));
    }
    processedOps++;
    processedBodies[opId] = deepCopy(op);
    final result = type == OpType.delete
        ? _delete(spec, id, opId, hlc, base)
        : _upsert(spec, id, opId, hlc, base, fields);
    return _remember(result);
  }

  Json _remember(Json result) {
    _opLog[result['op_id']! as String] = result;
    return result;
  }

  Json _applied(String opId, int? version, int conflictCount) => {
    'op_id': opId,
    'status': 'applied',
    'code': null,
    'message': null,
    'server_version': version,
    'conflicts': conflictCount,
    'duplicate': false,
  };

  // Проверка прикладных полей: (ошибка, очищенные значения).
  (Json?, Map<String, Object?>) _clean(
    SyncTableSpec spec,
    String opId,
    Map<String, Object?> fields, {
    required bool creating,
    _Row? existing,
  }) {
    final clean = <String, Object?>{};
    for (final e in fields.entries) {
      final name = e.key;
      if (name == 'created_at' || syncServiceColumns.contains(name)) {
        if (name == 'deleted_at' && e.value != null) {
          return (_rejected(opId, 'invalid_field', 'deleted_at'), clean);
        }
        continue;
      }
      final column = spec.column(name);
      if (column == null) continue; // неизвестные колонки отбрасываются
      if (!column.accepts(e.value)) {
        return (_rejected(opId, 'invalid_field', name), clean);
      }
      if (existing != null &&
          column.immutable &&
          !_same(existing.values[name], e.value)) {
        return (_rejected(opId, 'immutable_field', name), clean);
      }
      clean[name] = e.value;
    }
    return (null, clean);
  }

  static bool _same(Object? a, Object? b) =>
      a.runtimeType == b.runtimeType &&
      jsonEncodeSorted(a) == jsonEncodeSorted(b);

  Json _upsert(
    SyncTableSpec spec,
    String id,
    String opId,
    String hlc,
    int base,
    Map<String, Object?> fields,
  ) {
    final existing = _rows[(spec.name, id)];
    final (error, clean) = _clean(
      spec,
      opId,
      fields,
      creating: existing == null,
      existing: existing,
    );
    if (error != null) return error;
    if (existing == null) return _create(spec, id, opId, hlc, fields, clean);
    for (final relation in spec.parents) {
      final parent = clean[relation.column];
      if (parent is String && _rows[(relation.parentTable, parent)] == null) {
        return _rejected(opId, 'parent_not_found', relation.column);
      }
    }
    final row = existing;
    final version = ++head;
    var conflictCount = 0;
    final device = hlcDevice(hlc);
    final restore =
        fields.containsKey('deleted_at') && fields['deleted_at'] == null;
    var changed = false;

    void record(
      String kind,
      String field,
      Object? losing,
      Object? winning,
      String? losingDevice,
      String? winningDevice,
      String? losingHlc,
      String? winningHlc,
    ) {
      conflictCount++;
      _addConflict(
        spec.name,
        id,
        opId,
        kind,
        field,
        losing,
        winning,
        losingDevice,
        winningDevice,
        losingHlc,
        winningHlc,
      );
    }

    if (row.deletedAt != null) {
      final entry = row.entries['deleted_at']!;
      final decision = tombstoneEditDecision(
        entryDeleted: entry,
        opHlc: hlc,
        baseVersion: base,
        restore: restore,
      );
      // Пока родитель в корзине, строка остаётся в корзине вместе с ним.
      final blocked =
          (decision == 'restore' || decision == 'resurrect_conflict') &&
          _hasDeletedParent(spec, row);
      switch (blocked ? 'stay_deleted' : decision) {
        case 'restore' || 'resurrect_conflict':
          if (decision == 'resurrect_conflict') {
            record(
              'resurrected',
              'deleted_at',
              {'deleted_at': row.deletedAt},
              {'deleted_at': null},
              hlcDevice(entry.h),
              device,
              entry.h,
              hlc,
            );
          }
          _restoreRow(row, hlc, version);
          changed = true;
        case 'stay_deleted_conflict':
          record(
            'edit_vs_delete',
            'deleted_at',
            restore ? {'deleted_at': null} : deepCopy(clean),
            {'deleted_at': row.deletedAt},
            device,
            hlcDevice(entry.h),
            hlc,
            entry.h,
          );
        default:
          break; // stay_deleted: без конфликта, поля всё равно сливаются
      }
    }
    for (final e in clean.entries) {
      final entry = row.entries[e.key];
      final decision = fieldDecision(
        sameValue: _same(row.values[e.key], e.value),
        entry: entry,
        opHlc: hlc,
        baseVersion: base,
      );
      switch (decision) {
        case 'apply' || 'apply_conflict':
          if (decision == 'apply_conflict') {
            record(
              'field',
              e.key,
              row.values[e.key],
              e.value,
              hlcDevice(entry!.h),
              device,
              entry.h,
              hlc,
            );
          }
          row.values[e.key] = e.value;
          row.entries[e.key] = FieldEntry(version, hlc);
          changed = true;
        case 'touch':
          // Метка поля обновилась: updated_at тоже должен её отразить, иначе
          // клиент, прочитавший строку, не «услышит» эту метку в своих часах.
          row.entries[e.key] = FieldEntry(version, hlc);
          if (hlc.compareTo(row.updatedAt) > 0) row.updatedAt = hlc;
        case 'keep_conflict':
          record(
            'field',
            e.key,
            e.value,
            row.values[e.key],
            device,
            hlcDevice(entry!.h),
            hlc,
            entry.h,
          );
      }
    }
    if (changed) {
      if (hlc.compareTo(row.updatedAt) > 0) row.updatedAt = hlc;
      row.origin = device;
    }
    row.version = version;
    return _applied(opId, version, conflictCount);
  }

  bool _hasDeletedParent(SyncTableSpec spec, _Row row) {
    for (final relation in spec.parents) {
      final parent = row.values[relation.column];
      if (parent is String &&
          _rows[(relation.parentTable, parent)]?.deletedAt != null) {
        return true;
      }
    }
    return false;
  }

  void _restoreRow(_Row row, String hlc, int version) {
    row
      ..deletedAt = null
      ..cascadeOf = null
      ..entries['deleted_at'] = FieldEntry(version, hlc)
      ..version = version;
    // Потомки, удалённые этим же каскадом, возвращаются вместе с родителем.
    for (final child in _rows.values.toList()) {
      if (child.deletedAt != null && child.cascadeOf == row.id) {
        _restoreRow(child, hlc, ++head);
      }
    }
  }

  Json _create(
    SyncTableSpec spec,
    String id,
    String opId,
    String hlc,
    Map<String, Object?> fields,
    Map<String, Object?> clean,
  ) {
    final createdAt = fields['created_at'];
    if (createdAt is! String) {
      return _rejected(opId, 'missing_fields', 'created_at');
    }
    for (final c in spec.columns) {
      if (!c.nullable && !clean.containsKey(c.name)) {
        return _rejected(opId, 'missing_fields', c.name);
      }
    }
    if (spec.name == 'user_settings' &&
        id != userSettingsId('${clean['key']}')) {
      return _rejected(opId, 'invalid_id', 'id must be uuid5(namespace, key)');
    }
    _Row? deletedParent;
    for (final relation in spec.parents) {
      final parent = clean[relation.column];
      if (parent is! String) continue;
      final parentRow = _rows[(relation.parentTable, parent)];
      if (parentRow == null) {
        return _rejected(opId, 'parent_not_found', relation.column);
      }
      if (parentRow.deletedAt != null) deletedParent = parentRow;
    }
    final version = ++head;
    final row = _Row(spec.name, id, createdAt, hlc, hlcDevice(hlc))
      ..version = version;
    for (final e in clean.entries) {
      row.values[e.key] = e.value;
      row.entries[e.key] = FieldEntry(version, hlc);
    }
    for (final c in spec.columns) {
      row.values.putIfAbsent(c.name, () => null);
    }
    _rows[(spec.name, id)] = row;
    var conflictCount = 0;
    if (deletedParent != null) {
      row
        ..deletedAt = deletedParent.deletedAt
        ..cascadeOf = deletedParent.id
        ..entries['deleted_at'] = FieldEntry(version, hlc);
      conflictCount++;
      _addConflict(
        spec.name,
        id,
        opId,
        'parent_deleted',
        'deleted_at',
        {'deleted_at': null},
        {'deleted_at': deletedParent.deletedAt},
        hlcDevice(hlc),
        null,
        hlc,
        null,
      );
    }
    return _applied(opId, version, conflictCount);
  }

  Json _delete(
    SyncTableSpec spec,
    String id,
    String opId,
    String hlc,
    int base,
  ) {
    final row = _rows[(spec.name, id)];
    if (row == null) return _applied(opId, null, 0);
    final version = ++head;
    row.version = version;
    final decision = deleteDecision(
      alreadyDeleted: row.deletedAt != null,
      fieldEntries: row.entries,
      opHlc: hlc,
      baseVersion: base,
    );
    var conflictCount = 0;
    final device = hlcDevice(hlc);
    // Срок корзины — от получения сервером (spec 3.8): deleted_at = большее
    // из времени HLC и времени приёма.
    final iso = msIso(max(hlcMs(hlc), nowMs()));
    switch (decision) {
      case 'delete' || 'delete_edit_conflict':
        if (decision == 'delete_edit_conflict') {
          final losing = <String, Object?>{};
          Object? winningHlc;
          for (final e in row.entries.entries) {
            if (e.key != 'deleted_at' && isConcurrent(e.value, base, device)) {
              losing[e.key] = row.values[e.key];
              winningHlc = e.value.h;
            }
          }
          conflictCount++;
          _addConflict(
            spec.name,
            id,
            opId,
            'edit_vs_delete',
            'deleted_at',
            losing,
            {'deleted_at': iso},
            hlcDevice('$winningHlc'),
            device,
            '$winningHlc',
            hlc,
          );
        }
        _deleteRow(row, hlc, version, iso);
        if (hlc.compareTo(row.updatedAt) > 0) row.updatedAt = hlc;
        row.origin = device;
      case 'delete_lost':
        conflictCount++;
        final winner = row.entries.entries
            .where(
              (e) =>
                  e.key != 'deleted_at' && isConcurrent(e.value, base, device),
            )
            .map((e) => e.value)
            .reduce((a, b) => a.h.compareTo(b.h) >= 0 ? a : b);
        _addConflict(
          spec.name,
          id,
          opId,
          'resurrected',
          'deleted_at',
          {'deleted_at': iso},
          {'deleted_at': null},
          device,
          hlcDevice(winner.h),
          hlc,
          winner.h,
        );
    }
    return _applied(opId, version, conflictCount);
  }

  void _deleteRow(_Row row, String hlc, int version, String iso) {
    row
      ..deletedAt = iso
      ..entries['deleted_at'] = FieldEntry(version, hlc);
    // Каскад: живые потомки удаляются с той же меткой (spec 3.5).
    for (final spec in registry.specs) {
      for (final relation in spec.parents) {
        if (relation.parentTable != row.table) continue;
        for (final child in _rows.values.toList()) {
          if (child.table == spec.name &&
              child.deletedAt == null &&
              child.values[relation.column] == row.id) {
            child.cascadeOf = row.id;
            final childVersion = ++head;
            child.version = childVersion;
            _deleteRow(child, hlc, childVersion, iso);
          }
        }
      }
    }
  }

  void _addConflict(
    String table,
    String rowId,
    String opId,
    String kind,
    String field,
    Object? losing,
    Object? winning,
    String? losingDevice,
    String? winningDevice,
    String? losingHlc,
    String? winningHlc,
  ) {
    conflicts.add(
      ConflictRecord(
        id: uuid7(),
        createdAt: msIso(nowMs()),
        table: table,
        rowId: rowId,
        field: field,
        kind: kind,
        losingValue: deepCopy<Object?>(losing),
        winningValue: deepCopy<Object?>(winning),
        losingDevice: losingDevice,
        winningDevice: winningDevice,
        losingHlc: losingHlc,
        winningHlc: winningHlc,
        opId: opId,
      ),
    );
  }

  // ---- журнал конфликтов -----------------------------------------------------

  Json conflictsPage({
    String reverted = 'all',
    int limit = 50,
    String? before,
  }) {
    var list = conflicts.reversed.toList();
    if (reverted == 'true') {
      list = list.where((c) => c.revertedAt != null).toList();
    }
    if (reverted == 'false') {
      list = list.where((c) => c.revertedAt == null).toList();
    }
    if (before != null) {
      final index = list.indexWhere((c) => c.id == before);
      if (index >= 0) list = list.sublist(index + 1);
    }
    final page = list.take(limit).toList();
    return {
      'conflicts': [for (final c in page) c.toJson()],
      'next_before': list.length > page.length ? page.last.id : null,
    };
  }

  /// «Вернуть моё» (spec 3.9): проигравшее значение применяется как новая
  /// операция от текущего устройства со свежей меткой HLC.
  Json revert(String device, String conflictId) {
    final conflict = conflicts.where((c) => c.id == conflictId).firstOrNull;
    if (conflict == null) throw serverError(404, 'conflict_not_found');
    if (conflict.revertedAt != null) {
      throw serverError(409, 'conflict_already_reverted');
    }
    if (conflict.kind == 'parent_deleted') {
      throw serverError(409, 'not_revertable');
    }
    final row = _rows[(conflict.table, conflict.rowId)];
    if (row == null) throw serverError(409, 'row_not_found');
    var maxMs = nowMs();
    for (final e in row.entries.values) {
      if (hlcMs(e.h) >= maxMs) maxMs = hlcMs(e.h) + 1;
    }
    if (hlcMs(row.updatedAt) >= maxMs) maxMs = hlcMs(row.updatedAt) + 1;
    final hlc = formatHlc(maxMs, 0, device);
    final spec = registry.spec(conflict.table);
    final opId = uuid7();
    final Json result;
    switch (conflict.kind) {
      case 'field':
        result = _upsert(spec, row.id, opId, hlc, row.version, {
          conflict.field: conflict.losingValue,
        });
      case 'resurrected':
        result = _delete(spec, row.id, opId, hlc, row.version);
      default: // edit_vs_delete
        result = _upsert(spec, row.id, opId, hlc, row.version, {
          'deleted_at': null,
        });
    }
    if (result['status'] != 'applied') {
      throw serverError(422, 'revert_rejected');
    }
    conflict.revertedAt = msIso(nowMs());
    _commits.add((head: head, origin: device));
    return {
      'conflict': conflict.toJson(),
      'change': {
        'table': row.table,
        'id': row.id,
        'server_version': row.version,
        'row': _wire(row),
      },
    };
  }

  // ---- очистка корзины (spec 3.8) -----------------------------------------------

  /// Физически удаляет надгробия: старше 30 суток, версия ≤ курсора каждого
  /// активного устройства ([activeDevices]) и без потомков. Возвращает число.
  int purge({required Set<String> activeDevices}) {
    final cutoff = nowMs() - const Duration(days: 30).inMilliseconds;
    final minCursor = activeDevices.isEmpty
        ? head
        : activeDevices
              .map((d) => deviceCursors[d] ?? 0)
              .reduce((a, b) => a < b ? a : b);
    var purged = 0;
    for (final row in _rows.values.toList()) {
      if (row.deletedAt == null) continue;
      final deletedMs = DateTime.parse(row.deletedAt!).millisecondsSinceEpoch;
      if (deletedMs >= cutoff || row.version > minCursor) continue;
      final hasChildren = _rows.values.any(
        (c) => registry
            .spec(c.table)
            .parents
            .any(
              (r) => r.parentTable == row.table && c.values[r.column] == row.id,
            ),
      );
      if (hasChildren) continue;
      _rows.remove((row.table, row.id));
      if (row.version > purgeWatermark) purgeWatermark = row.version;
      purged++;
    }
    return purged;
  }

  Future<void> dispose() => _commits.close();
}

/// Каноническая запись JSON (ключи по алфавиту) для сравнения значений.
String jsonEncodeSorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return '{${keys.map((k) => '"$k":${jsonEncodeSorted(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(jsonEncodeSorted).join(',')}]';
  if (value is String) return '"${value.replaceAll('"', r'\"')}"';
  return '$value';
}
