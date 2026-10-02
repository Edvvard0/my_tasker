import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/server_epoch.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_table.dart';

/// Ключи служебной таблицы `sync_meta`.
abstract final class SyncMetaKeys {
  static const deviceId = 'device_id';
  static const deviceRegistered = 'device_registered';
  static const hlcL = 'hlc_l';
  static const hlcC = 'hlc_c';
  static const cursor = 'cursor';
  static const lastPushMs = 'last_push_ms';
  static const lastPullMs = 'last_pull_ms';
  static const lastSuccessMs = 'last_success_ms';
  static const blockedMinSchema = 'blocked_min_schema';
  static const needsResync = 'needs_resync';
  static const knownTables = 'known_tables';
  static const serverEpoch = 'server_epoch';

  /// Сколько строк pull пропущено из-за неразборчивой метки `updated_at`.
  static const skippedRows = 'skipped_rows';

  /// Последняя пропущенная строка (`таблица/id`) — для диагностики.
  static const lastSkippedRow = 'last_skipped_row';

  /// Время (мс Unix) последнего «пульса» интерфейса: пока он свежий,
  /// фоновая задача WorkManager не запускает цикл (см. [SyncStore.markForeground]).
  static const foregroundHeartbeatMs = 'foreground_heartbeat_ms';
}

/// Хранилище синхронизации поверх локальной БД: строки синхронизируемых
/// таблиц, outbox, HLC и курсор.
///
/// Главный инвариант (spec 5.1): правка строки, новая метка HLC и запись в
/// outbox выполняются в **одной** локальной транзакции. Применение страницы
/// pull (строки, `receive` HLC и сдвиг курсора) — тоже одна транзакция.
class SyncStore {
  SyncStore({
    required this.db,
    required this.registry,
    int Function()? nowMs,
    String Function()? newOpId,
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _newOpId = newOpId ?? uuid7;

  final AppDatabase db;
  final SyncRegistry registry;

  /// Часы устройства в миллисекундах Unix (подменяются в тестах).
  final int Function() nowMs;
  final String Function() _newOpId;

  final StreamController<void> _writes = StreamController<void>.broadcast();

  /// Сигнал «была локальная запись» (запускает синхронизацию с задержкой).
  Stream<void> get localWrites => _writes.stream;

  /// Выполняет [action] в одной транзакции БД.
  Future<T> transaction<T>(Future<T> Function() action) =>
      db.transaction(action);

  // ---- служебное состояние -------------------------------------------------

  Future<String?> readMeta(String key) async {
    final row = await (db.select(
      db.syncMeta,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> writeMeta(String key, String? value) async {
    if (value == null) {
      await (db.delete(db.syncMeta)..where((t) => t.key.equals(key))).go();
    } else {
      await db
          .into(db.syncMeta)
          .insertOnConflictUpdate(
            SyncMetaCompanion.insert(key: key, value: value),
          );
    }
  }

  Future<int?> _metaInt(String key) async {
    final value = await readMeta(key);
    return value == null ? null : int.tryParse(value);
  }

  /// Идентификатор устройства. До первого входа — временный локальный
  /// uuid7; при входе заменяется выданным сервером ([adoptDevice]).
  Future<String> deviceId() async {
    final existing = await readMeta(SyncMetaKeys.deviceId);
    if (existing != null) return existing;
    final created = uuid7();
    await writeMeta(SyncMetaKeys.deviceId, created);
    return created;
  }

  /// Курсор pull (`server_version`, до которого строки уже применены).
  Future<int> cursor() async => (await _metaInt(SyncMetaKeys.cursor)) ?? 0;

  Future<DateTime?> _metaTime(String key) async {
    final ms = await _metaInt(key);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<DateTime?> lastPushAt() => _metaTime(SyncMetaKeys.lastPushMs);
  Future<DateTime?> lastPullAt() => _metaTime(SyncMetaKeys.lastPullMs);
  Future<DateTime?> lastSuccessAt() => _metaTime(SyncMetaKeys.lastSuccessMs);

  Future<void> markPush() => writeMeta(SyncMetaKeys.lastPushMs, '${nowMs()}');
  Future<void> markPull() => writeMeta(SyncMetaKeys.lastPullMs, '${nowMs()}');
  Future<void> markSuccess() =>
      writeMeta(SyncMetaKeys.lastSuccessMs, '${nowMs()}');

  // ---- интерфейс на переднем плане (два изолята) ---------------------------

  /// Пульс интерфейса действителен столько, потом считается устаревшим
  /// (приложение убито без снятия отметки).
  static const Duration foregroundTtl = Duration(seconds: 90);

  /// Отмечает, что приложение на переднем плане. Интерфейс вызывает это при
  /// возврате в приложение и каждые ~30 с; фоновый изолят WorkManager
  /// читает ту же БД ([isForegroundActive]) и пропускает свой цикл — иначе
  /// два изолята гнали бы синхронизацию и refresh параллельно.
  Future<void> markForeground() =>
      writeMeta(SyncMetaKeys.foregroundHeartbeatMs, '${nowMs()}');

  /// Приложение ушло в фон: снимает отметку.
  Future<void> clearForeground() =>
      writeMeta(SyncMetaKeys.foregroundHeartbeatMs, null);

  /// Есть ли свежая отметка «интерфейс на переднем плане».
  Future<bool> isForegroundActive() async {
    final ms = await _metaInt(SyncMetaKeys.foregroundHeartbeatMs);
    if (ms == null) return false;
    final age = nowMs() - ms;
    return age >= 0 && age < foregroundTtl.inMilliseconds;
  }

  /// Сколько строк pull пропущено как неразборчивые (`updated_at`).
  Future<int> skippedRowCount() async =>
      (await _metaInt(SyncMetaKeys.skippedRows)) ?? 0;

  /// Последняя пропущенная строка (`таблица/id`) или `null`.
  Future<String?> lastSkippedRow() => readMeta(SyncMetaKeys.lastSkippedRow);

  /// Эпоха сервера, с которой клиент синхронизировался в последний раз.
  Future<String?> serverEpoch() => readMeta(SyncMetaKeys.serverEpoch);

  Future<void> setServerEpoch(String? value) =>
      writeMeta(SyncMetaKeys.serverEpoch, value);

  /// Сверяет эпоху из ответа сервера с запомненной: первую запоминает, при
  /// расхождении ставит флаг полной пересинхронизации (новая эпоха
  /// запоминается по её завершении). Возвращает решение.
  Future<EpochAction> observeEpoch(String? received) async {
    final action = epochAction(stored: await serverEpoch(), received: received);
    switch (action) {
      case EpochAction.store:
        await setServerEpoch(received);
      case EpochAction.fullResync:
        await setNeedsResync(value: true);
      case EpochAction.none:
        break;
    }
    return action;
  }

  Future<bool> needsResync() async =>
      (await readMeta(SyncMetaKeys.needsResync)) == '1';

  Future<void> setNeedsResync({required bool value}) =>
      writeMeta(SyncMetaKeys.needsResync, value ? '1' : null);

  /// Версия схемы клиента, которой не хватило серверу (`426`), или `null`.
  Future<int?> blockedMinSchema() => _metaInt(SyncMetaKeys.blockedMinSchema);

  Future<void> setBlockedMinSchema(int? value) =>
      writeMeta(SyncMetaKeys.blockedMinSchema, value?.toString());

  /// Если набор зарегистрированных таблиц вырос (обновление приложения),
  /// прошлые pull эти строки пропустили — нужна полная пересинхронизация.
  Future<void> reconcileKnownTables() async {
    final current = registry.names.join(',');
    final stored = await readMeta(SyncMetaKeys.knownTables);
    if (stored == current) return;
    await transaction(() async {
      if (stored != null) {
        final old = stored.split(',').toSet();
        if (!old.containsAll(registry.names) && (await cursor()) > 0) {
          await setNeedsResync(value: true);
        }
      }
      await writeMeta(SyncMetaKeys.knownTables, current);
    });
  }

  Future<HlcState> _loadHlc() async => HlcState(
    (await _metaInt(SyncMetaKeys.hlcL)) ?? 0,
    (await _metaInt(SyncMetaKeys.hlcC)) ?? 0,
  );

  Future<void> _saveHlc(HlcState state) async {
    await writeMeta(SyncMetaKeys.hlcL, '${state.l}');
    await writeMeta(SyncMetaKeys.hlcC, '${state.c}');
  }

  /// Текущее состояние часов (для тестов и диагностики).
  Future<HlcState> hlcState() => _loadHlc();

  /// Новая метка HLC для правки; состояние часов сохраняется в БД в
  /// текущей транзакции.
  Future<String> _stamp() async {
    final clock = HlcClock(await deviceId(), await _loadHlc());
    final stamp = clock.send(nowMs());
    await _saveHlc(clock.state);
    return stamp;
  }

  /// Принимает идентификатор устройства, выданный сервером при входе.
  ///
  /// Метки HLC неотправленных операций и собственные `updated_at`
  /// содержат старый идентификатор (временный или отозванного
  /// устройства); сервер отклонил бы такие операции
  /// (`hlc_device_mismatch`), поэтому суффикс меняется на новый.
  Future<void> adoptDevice(String newDeviceId) => transaction(() async {
    final old = await deviceId();
    if (old != newDeviceId) {
      await db.customUpdate(
        'UPDATE sync_outbox SET hlc = substr(hlc, 1, length(hlc) - 36) || ? '
        'WHERE substr(hlc, -36) = ?',
        variables: [Variable.withString(newDeviceId), Variable.withString(old)],
        updates: {db.syncOutbox},
      );
      for (final spec in registry.specs) {
        await db.customUpdate(
          'UPDATE "${spec.name}" SET '
          'updated_at = substr(updated_at, 1, length(updated_at) - 36) || ? '
          'WHERE substr(updated_at, -36) = ?',
          variables: [
            Variable.withString(newDeviceId),
            Variable.withString(old),
          ],
          updates: _tables(spec.name),
        );
        await db.customUpdate(
          'UPDATE "${spec.name}" SET origin_device_id = ? '
          'WHERE origin_device_id = ?',
          variables: [
            Variable.withString(newDeviceId),
            Variable.withString(old),
          ],
          updates: _tables(spec.name),
        );
      }
      await writeMeta(SyncMetaKeys.deviceId, newDeviceId);
    }
    await writeMeta(SyncMetaKeys.deviceRegistered, '1');
  });

  // ---- строки ------------------------------------------------------------

  /// Таблица Drift по имени. Зарегистрированная таблица обязана быть
  /// объявлена в `AppDatabase`; пустой набор (для таблиц, созданных вручную
  /// в тестах) лишь отключает реактивные обновления потоков.
  Set<TableInfo<Table, Object?>> _tables(String name) => {
    for (final t in db.allTables)
      if (t.actualTableName == name) t,
  };

  /// Поток результатов запроса, обновляемый при изменении [tables]. Не
  /// использует `Selectable.watch()` Drift: тот при отмене подписки заводит
  /// нулевой таймер, который мешает тестам виджетов и не нужен приложению.
  Stream<T> _watch<T>(
    Set<TableInfo<Table, Object?>> tables,
    Future<T> Function() query,
  ) {
    late final StreamController<T> controller;
    StreamSubscription<Object?>? subscription;
    var chain = Future<void>.value();

    void emit() {
      chain = chain.then((_) async {
        if (controller.isClosed) return;
        try {
          final value = await query();
          if (!controller.isClosed) controller.add(value);
        } on Object catch (error, stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        }
      });
    }

    controller = StreamController<T>(
      onListen: () {
        emit();
        subscription = db
            .tableUpdates(TableUpdateQuery.onAllTables(tables))
            .listen((_) => emit());
      },
      onCancel: () async {
        await subscription?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  static Variable<Object> _variable(Object? value) => switch (value) {
    null => const Variable<Object>(null),
    final String s => Variable<Object>(s),
    final int i => Variable<Object>(i),
    final double d => Variable<Object>(d),
    final bool b => Variable<Object>(b ? 1 : 0),
    _ => throw ArgumentError.value(value, 'value', 'неподдерживаемый тип'),
  };

  /// Строка таблицы (в JSON-виде) или `null`.
  Future<Json?> getRow(String table, String id) async {
    final spec = registry.spec(table);
    final rows = await db
        .customSelect(
          'SELECT * FROM "$table" WHERE id = ?',
          variables: [Variable.withString(id)],
          readsFrom: _tables(table),
        )
        .get();
    return rows.isEmpty ? null : spec.rowFromDb(rows.first.data);
  }

  Stream<Json?> watchRow(String table, String id) =>
      _watch(_tables(table), () => getRow(table, id));

  /// Записывает строку целиком или частично: колонки, которых нет в [row],
  /// сохраняют локальное значение (клиент новее сервера). Существующая
  /// строка обновляется `UPDATE`-ом (у `INSERT .. ON CONFLICT` проверка
  /// NOT NULL срабатывает раньше конфликта), новая — вставляется, а
  /// недостающие обязательные колонки получают нейтральное значение.
  Future<void> _writeRow(SyncTableSpec spec, Json row) async {
    final values = <String, Object?>{};
    for (final name in syncServiceColumns) {
      if (row.containsKey(name)) values[name] = row[name];
    }
    for (final c in spec.columns) {
      if (row.containsKey(c.name)) values[c.name] = c.toDb(row[c.name]);
    }
    final id = row['id']! as String;
    final table = _tables(spec.name);
    final changed = values.keys.where((c) => c != 'id').toList();
    if (changed.isNotEmpty) {
      final updated = await db.customUpdate(
        'UPDATE "${spec.name}" SET '
        '${changed.map((c) => '"$c" = ?').join(', ')} WHERE id = ?',
        variables: [
          for (final c in changed) _variable(values[c]),
          Variable.withString(id),
        ],
        updates: table,
      );
      if (updated > 0) return;
    }
    for (final c in spec.columns) {
      if (!values.containsKey(c.name) && !c.nullable) {
        values[c.name] = switch (c.type) {
          SyncColumnType.integer || SyncColumnType.boolean => 0,
          SyncColumnType.json => 'null',
          _ => '',
        };
      }
    }
    values
      ..putIfAbsent('created_at', () => row['updated_at'] ?? '')
      ..putIfAbsent('updated_at', () => '');
    final names = values.keys.toList();
    await db.customUpdate(
      'INSERT INTO "${spec.name}" (${names.map((c) => '"$c"').join(', ')}) '
      'VALUES (${List.filled(names.length, '?').join(', ')})',
      variables: [for (final c in names) _variable(values[c])],
      updates: table,
    );
  }

  // ---- локальные правки (spec 5.1) ---------------------------------------

  /// Создаёт строку: строка + метка HLC + операция outbox в одной
  /// транзакции. [fields] — все прикладные колонки.
  Future<Json> create(String table, String id, Json fields) async {
    final spec = registry.spec(table)..validateFields(fields, creating: true);
    final row = await transaction(() async {
      if (await getRow(table, id) != null) {
        throw StateError('Строка $table/$id уже существует');
      }
      final stamp = await _stamp();
      final created = msIso(hlcMs(stamp));
      final row = <String, Object?>{
        'id': id,
        'created_at': created,
        'updated_at': stamp,
        'deleted_at': null,
        'server_version': 0,
        'origin_device_id': await deviceId(),
        ...fields,
      };
      await _writeRow(spec, row);
      await _emit(
        table: table,
        rowId: id,
        type: OpType.upsert,
        fields: {...fields, 'created_at': created},
        baseVersion: 0,
        hlc: stamp,
      );
      return row;
    });
    _writes.add(null);
    return row;
  }

  /// Правка полей существующей строки.
  Future<void> update(String table, String id, Json fields) async {
    final spec = registry.spec(table)..validateFields(fields, creating: false);
    if (fields.isEmpty) return;
    await transaction(() async {
      final current = await _requireRow(table, id);
      final stamp = await _stamp();
      await _writeRow(spec, {'id': id, ...fields, 'updated_at': stamp});
      await _emit(
        table: table,
        rowId: id,
        type: OpType.upsert,
        fields: fields,
        baseVersion: current['server_version']! as int,
        hlc: stamp,
      );
    });
    _writes.add(null);
  }

  /// Мягкое удаление: `deleted_at` = время из HLC, операция `delete`.
  /// Дочерние строки клиент не трогает (spec 3.5): они скрываются
  /// видимостью, каскад приходит с сервера.
  Future<void> softDelete(String table, String id) async {
    final spec = registry.spec(table);
    final changed = await transaction(() async {
      final current = await _requireRow(table, id);
      if (current['deleted_at'] != null) return false;
      final stamp = await _stamp();
      await _writeRow(spec, {
        'id': id,
        'deleted_at': msIso(hlcMs(stamp)),
        'updated_at': stamp,
      });
      await _emit(
        table: table,
        rowId: id,
        type: OpType.delete,
        baseVersion: current['server_version']! as int,
        hlc: stamp,
      );
      return true;
    });
    if (changed) _writes.add(null);
  }

  /// Восстановление из корзины: `deleted_at = null`, операция
  /// `upsert {deleted_at: null}`.
  Future<void> restore(String table, String id) async {
    final spec = registry.spec(table);
    final changed = await transaction(() async {
      final current = await _requireRow(table, id);
      if (current['deleted_at'] == null) return false;
      final stamp = await _stamp();
      await _writeRow(spec, {
        'id': id,
        'deleted_at': null,
        'updated_at': stamp,
      });
      await _emit(
        table: table,
        rowId: id,
        type: OpType.upsert,
        fields: {'deleted_at': null},
        baseVersion: current['server_version']! as int,
        hlc: stamp,
      );
      return true;
    });
    if (changed) _writes.add(null);
  }

  Future<Json> _requireRow(String table, String id) async {
    final row = await getRow(table, id);
    if (row == null) throw StateError('Строки $table/$id нет');
    return row;
  }

  // ---- outbox --------------------------------------------------------------

  OutboxOp _op(OutboxEntry e) => OutboxOp(
    seq: e.seq,
    opId: e.opId,
    table: e.targetTable,
    rowId: e.rowId,
    type: e.opType,
    fields: e.fields == null
        ? null
        : (jsonDecode(e.fields!) as Map).cast<String, Object?>(),
    baseVersion: e.baseVersion,
    hlc: e.hlc,
    state: e.state,
    rejectCode: e.rejectCode,
    rejectMessage: e.rejectMessage,
    createdAtMs: e.createdAtMs,
  );

  Future<List<OutboxOp>> _rowOps(String table, String id) async {
    final rows =
        await (db.select(db.syncOutbox)
              ..where((t) => t.targetTable.equals(table) & t.rowId.equals(id))
              ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
            .get();
    return rows.map(_op).toList();
  }

  /// Добавляет операцию, схлопывая с последней `pending` той же строки
  /// (spec 5.1): результат чистой [collapseOutbox] переносится в БД.
  Future<void> _emit({
    required String table,
    required String rowId,
    required String type,
    required int baseVersion,
    required String hlc,
    Json? fields,
  }) async {
    final existing = await _rowOps(table, rowId);
    final newOp = <String, Object?>{
      'op_id': _newOpId(),
      'table': table,
      'id': rowId,
      'type': type,
      'base_version': baseVersion,
      'hlc': hlc,
      if (type == OpType.upsert) 'fields': fields ?? <String, Object?>{},
    };
    final before = [for (final op in existing) op.toLogic()];
    final after = collapseOutbox(before, newOp);
    if (after.length > before.length) {
      await db
          .into(db.syncOutbox)
          .insert(
            SyncOutboxCompanion.insert(
              opId: newOp['op_id']! as String,
              targetTable: table,
              rowId: rowId,
              opType: type,
              fields: Value(
                type == OpType.upsert ? jsonEncode(newOp['fields']) : null,
              ),
              baseVersion: baseVersion,
              hlc: hlc,
              createdAtMs: Value(nowMs()),
            ),
          );
      return;
    }
    // Схлопнуто в последнюю операцию строки: обновляем её на месте.
    final merged = after.last;
    await (db.update(
      db.syncOutbox,
    )..where((t) => t.opId.equals(merged['op_id']! as String))).write(
      SyncOutboxCompanion(
        opType: Value(merged['type']! as String),
        fields: Value(
          merged['type'] == OpType.upsert ? jsonEncode(merged['fields']) : null,
        ),
        hlc: Value(merged['hlc']! as String),
      ),
    );
  }

  /// Все операции outbox по порядку.
  Future<List<OutboxOp>> outbox() async {
    final rows = await (db.select(
      db.syncOutbox,
    )..orderBy([(t) => OrderingTerm.asc(t.seq)])).get();
    return rows.map(_op).toList();
  }

  /// Берёт до [max] операций `pending`/`in_flight` по порядку создания,
  /// кроме [exclude], и помечает их `in_flight` (spec 5.2, шаг 1).
  Future<List<OutboxOp>> takeBatch({
    int max = SyncLimits.pushBatchMax,
    Set<String> exclude = const {},
  }) => transaction(() async {
    final rows =
        await (db.select(db.syncOutbox)
              ..where(
                (t) =>
                    t.state.isIn([OpState.pending, OpState.inFlight]) &
                    t.opId.isNotIn(exclude),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.seq)])
              ..limit(max))
            .get();
    if (rows.isEmpty) return <OutboxOp>[];
    await (db.update(db.syncOutbox)
          ..where((t) => t.opId.isIn(rows.map((r) => r.opId).toList())))
        .write(const SyncOutboxCompanion(state: Value(OpState.inFlight)));
    return [for (final r in rows) _op(r).withState(OpState.inFlight)];
  });

  /// Применяет результаты push. Возвращает `op_id`, которые остаются в
  /// очереди и в этом цикле повторно не отправляются (`hlc_in_future`,
  /// либо сервер не вернул результат).
  Future<Set<String>> applyPushResults(
    List<OutboxOp> batch,
    List<PushOpResult> results,
  ) => transaction(() async {
    final byId = {for (final r in results) r.opId: r};
    final deferred = <String>{};
    for (final op in batch) {
      final result = byId[op.opId];
      if (result == null) {
        deferred.add(op.opId);
      } else if (result.applied) {
        await (db.delete(
          db.syncOutbox,
        )..where((t) => t.opId.equals(op.opId))).go();
      } else if (result.code == 'hlc_in_future') {
        // Сервер операцию не запомнил: остаётся в очереди, повтор позже.
        deferred.add(op.opId);
      } else {
        await (db.update(
          db.syncOutbox,
        )..where((t) => t.opId.equals(op.opId))).write(
          SyncOutboxCompanion(
            state: const Value(OpState.rejected),
            rejectCode: Value(result.code ?? 'rejected'),
            rejectMessage: Value(result.message),
          ),
        );
      }
    }
    return deferred;
  });

  /// Есть ли операции к отправке (кроме [exclude]).
  Future<bool> hasUnsent({Set<String> exclude = const {}}) async {
    final rows =
        await (db.select(db.syncOutbox)
              ..where(
                (t) =>
                    t.state.isIn([OpState.pending, OpState.inFlight]) &
                    t.opId.isNotIn(exclude),
              )
              ..limit(1))
            .get();
    return rows.isNotEmpty;
  }

  OutboxSummary _summary(List<OutboxEntry> rows) => OutboxSummary(
    pending: rows.where((r) => r.state == OpState.pending).length,
    inFlight: rows.where((r) => r.state == OpState.inFlight).length,
    rejected: rows.where((r) => r.state == OpState.rejected).length,
  );

  Future<OutboxSummary> outboxSummary() async =>
      _summary(await db.select(db.syncOutbox).get());

  Stream<OutboxSummary> watchOutboxSummary() =>
      _watch({db.syncOutbox}, outboxSummary).distinct();

  Stream<List<OutboxOp>> watchRejected() => _watch({db.syncOutbox}, () async {
    final rows =
        await (db.select(db.syncOutbox)
              ..where((t) => t.state.equals(OpState.rejected))
              ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
            .get();
    return rows.map(_op).toList();
  });

  /// «Повторить» отклонённую операцию: новая операция (свой `op_id`,
  /// свежий HLC, `base_version` = версия локальной строки), старая
  /// удаляется (spec 5.2, последний абзац).
  Future<void> retryRejected(String opId) async {
    final done = await transaction(() async {
      final entry = await (db.select(
        db.syncOutbox,
      )..where((t) => t.opId.equals(opId))).getSingleOrNull();
      if (entry == null || entry.state != OpState.rejected) return false;
      final op = _op(entry);
      await (db.delete(db.syncOutbox)..where((t) => t.opId.equals(opId))).go();
      final row = await getRow(op.table, op.rowId);
      if (row == null && op.type == OpType.delete) return true;
      // Более новые неотправленные правки той же строки главнее отклонённой:
      // свежий HLC повтора иначе затёр бы их значения.
      final newer = [
        for (final o in await _rowOps(op.table, op.rowId))
          if (o.seq > op.seq && o.state != OpState.rejected) o,
      ];
      var fields = op.fields;
      if (newer.isNotEmpty) {
        if (op.type == OpType.delete ||
            newer.any((o) => o.type == OpType.delete)) {
          return true; // новее уже есть решение по строке
        }
        final covered = {for (final o in newer) ...?o.fields?.keys};
        fields = {
          for (final e in (op.fields ?? const <String, Object?>{}).entries)
            if (!covered.contains(e.key)) e.key: e.value,
        };
        if (fields.isEmpty) return true;
      }
      await _emit(
        table: op.table,
        rowId: op.rowId,
        type: op.type,
        fields: fields,
        baseVersion: (row?['server_version'] as int?) ?? 0,
        hlc: await _stamp(),
      );
      return true;
    });
    if (done) _writes.add(null);
  }

  /// «Отбросить» отклонённую операцию. Локальная строка остаётся как есть,
  /// поэтому ставится флаг полной пересинхронизации: она вернёт строке
  /// серверное состояние.
  Future<void> discardRejected(String opId) async {
    final count = await transaction(() async {
      final removed =
          await (db.delete(db.syncOutbox)..where(
                (t) => t.opId.equals(opId) & t.state.equals(OpState.rejected),
              ))
              .go();
      if (removed > 0) await setNeedsResync(value: true);
      return removed;
    });
    if (count > 0) _writes.add(null);
  }

  // ---- применение данных сервера ---------------------------------------------

  Future<Map<(String, String), List<Json>>> _liveOps() async {
    final rows =
        await (db.select(db.syncOutbox)
              ..where((t) => t.state.isNotValue(OpState.rejected))
              ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
            .get();
    final map = <(String, String), List<Json>>{};
    for (final e in rows) {
      map.putIfAbsent((e.targetTable, e.rowId), () => []).add(_op(e).toLogic());
    }
    return map;
  }

  Future<int> _applyChanges(
    Iterable<SyncChange> changes,
    HlcClock clock,
    Map<(String, String), List<Json>> ops,
  ) async {
    var applied = 0;
    for (final change in changes) {
      final spec = registry.maybeSpec(change.table);
      if (spec == null) continue; // таблица новее клиента
      final serverRow = deepCopy(change.row);
      final updatedAt = serverRow['updated_at'];
      // Неразборчивая метка не должна ронять всю страницу: строку
      // пропускаем и записываем (курсор всё равно сдвинется).
      try {
        if (updatedAt is! String) throw const FormatException('updated_at');
        clock.receive(updatedAt, nowMs());
      } on FormatException {
        await _recordSkipped(change);
        continue;
      }
      final rowOps = ops[(change.table, change.id)];
      final row = rowOps == null ? serverRow : rebaseRow(serverRow, rowOps);
      row['id'] = change.id;
      await _writeRow(spec, row);
      applied++;
    }
    return applied;
  }

  Future<void> _recordSkipped(SyncChange change) async {
    await writeMeta(SyncMetaKeys.skippedRows, '${await skippedRowCount() + 1}');
    await writeMeta(
      SyncMetaKeys.lastSkippedRow,
      '${change.table}/${change.id}',
    );
  }

  /// Применяет страницу pull одной транзакцией: строки (с rebase
  /// неотправленных правок), `receive` HLC и сдвиг курсора (spec 5.2).
  /// Возвращает число применённых строк.
  Future<int> applyPage(List<SyncChange> changes, int nextSince) =>
      transaction(() async {
        final clock = HlcClock(await deviceId(), await _loadHlc());
        final applied = await _applyChanges(changes, clock, await _liveOps());
        await _saveHlc(clock.state);
        await writeMeta(SyncMetaKeys.cursor, '$nextSince');
        return applied;
      });

  /// Применяет одну строку сервера (ответ `revert`) как строку из pull,
  /// но курсор не двигает.
  Future<void> applyChange(SyncChange change) => transaction(() async {
    final clock = HlcClock(await deviceId(), await _loadHlc());
    await _applyChanges([change], clock, await _liveOps());
    await _saveHlc(clock.state);
  });

  /// Полная пересинхронизация (spec 5.3): в одной транзакции удаляет все
  /// локальные синхронизируемые строки, записывает [staged], накладывает
  /// неотправленные операции и ставит курсор. Outbox сохраняется целиком.
  Future<void> replaceAll(
    List<SyncChange> staged,
    int cursorValue, {
    String? epoch,
  }) => transaction(() async {
    for (final spec in registry.specs) {
      await db.customUpdate(
        'DELETE FROM "${spec.name}"',
        updates: _tables(spec.name),
      );
    }
    final clock = HlcClock(await deviceId(), await _loadHlc());
    final ops = await _liveOps();
    await _applyChanges(staged, clock, ops);
    await _rematerialiseCreates(staged, ops);
    await _saveHlc(clock.state);
    await writeMeta(SyncMetaKeys.cursor, '$cursorValue');
    if (epoch != null) await setServerEpoch(epoch);
    await setNeedsResync(value: false);
  });

  /// После полной пересинхронизации возвращает строки, которые существуют
  /// только благодаря неотправленным созданиям (`base_version = 0`) и
  /// которых нет среди серверных: без них операция осталась бы в outbox, а
  /// строка исчезла бы с экрана до её подтверждения. Правки строк, которых
  /// нет на сервере и чьё создание уже подтверждено, не воскрешаются.
  Future<void> _rematerialiseCreates(
    List<SyncChange> staged,
    Map<(String, String), List<Json>> ops,
  ) async {
    final onServer = {for (final c in staged) (c.table, c.id)};
    final device = await deviceId();
    for (final entry in ops.entries) {
      if (onServer.contains(entry.key)) continue;
      final spec = registry.maybeSpec(entry.key.$1);
      final first = entry.value.first;
      if (spec == null ||
          first['type'] != OpType.upsert ||
          first['base_version'] != 0) {
        continue;
      }
      final fields = first['fields']! as Map<String, Object?>;
      final hlc = first['hlc']! as String;
      final base = <String, Object?>{
        'id': entry.key.$2,
        'created_at': fields['created_at'] ?? msIso(hlcMs(hlc)),
        'updated_at': hlc,
        'deleted_at': null,
        'server_version': 0,
        'origin_device_id': device,
      };
      await _writeRow(spec, applyOpsToRow(base, entry.value));
    }
  }

  /// Удаляет локальные надгробия старше [SyncLimits.trashDays], по которым
  /// нет неотправленных операций (spec 3.8). Возвращает число строк.
  Future<int> purgeOldTombstones() async {
    final cutoff = msIso(
      nowMs() - const Duration(days: SyncLimits.trashDays).inMilliseconds,
    );
    var total = 0;
    for (final spec in registry.specs) {
      total += await db.customUpdate(
        'DELETE FROM "${spec.name}" WHERE deleted_at IS NOT NULL '
        'AND deleted_at < ? AND NOT EXISTS '
        '(SELECT 1 FROM sync_outbox o WHERE o.target_table = ? '
        'AND o.row_id = "${spec.name}".id)',
        variables: [
          Variable.withString(cutoff),
          Variable.withString(spec.name),
        ],
        updates: _tables(spec.name),
      );
    }
    return total;
  }

  // ---- видимость и корзина -------------------------------------------------

  String _visibleSql(SyncTableSpec spec, String alias, int depth) {
    final parts = ['$alias.deleted_at IS NULL'];
    for (final relation in spec.parents) {
      final parent = registry.spec(relation.parentTable);
      final p = 'p$depth';
      parts.add(
        '($alias."${relation.column}" IS NULL OR EXISTS '
        '(SELECT 1 FROM "${parent.name}" $p '
        'WHERE $p.id = $alias."${relation.column}" '
        'AND ${_visibleSql(parent, p, depth + 1)}))',
      );
    }
    return parts.join(' AND ');
  }

  Set<TableInfo<Table, Object?>> _visibilityTables(SyncTableSpec spec) {
    final tables = _tables(spec.name);
    for (final relation in spec.parents) {
      tables.addAll(_visibilityTables(registry.spec(relation.parentTable)));
    }
    return tables;
  }

  Selectable<QueryRow> _visibleQuery(
    String table,
    String? where,
    List<Object?> args,
    String? orderBy,
  ) {
    final spec = registry.spec(table);
    final sql =
        'SELECT t.* FROM "$table" t WHERE ${_visibleSql(spec, 't', 0)}'
        '${where == null ? '' : ' AND ($where)'}'
        '${orderBy == null ? '' : ' ORDER BY $orderBy'}';
    return db.customSelect(
      sql,
      variables: args.map(_variable).toList(),
      readsFrom: _visibilityTables(spec),
    );
  }

  /// Видимые строки таблицы: `deleted_at = null` и все родители видимы
  /// (spec 3.5). [where] — дополнительное условие SQL над алиасом `t`.
  Future<List<Json>> visibleRows(
    String table, {
    String? where,
    List<Object?> args = const [],
    String? orderBy,
  }) async {
    final spec = registry.spec(table);
    final rows = await _visibleQuery(table, where, args, orderBy).get();
    return [for (final r in rows) spec.rowFromDb(r.data)];
  }

  Stream<List<Json>> watchVisibleRows(
    String table, {
    String? where,
    List<Object?> args = const [],
    String? orderBy,
  }) => _watch(
    _visibilityTables(registry.spec(table)),
    () => visibleRows(table, where: where, args: args, orderBy: orderBy),
  );

  /// Корзина: удалённые не более [SyncLimits.trashDays] суток назад строки
  /// зарегистрированных таблиц без удалённого родителя (spec 3.8).
  ///
  /// Срок считается от получения удаления сервером, поэтому строка с ещё
  /// не отправленным удалением остаётся в корзине при любом локальном
  /// возрасте (с полным сроком), а не пропадает раньше, чем дойдёт до
  /// сервера. Запросов по числу строк нет: удалённые родители и очередь
  /// читаются по одному запросу на таблицу.
  Future<List<TrashItem>> trashItems() async {
    final now = DateTime.fromMillisecondsSinceEpoch(nowMs(), isUtc: true);
    const keep = Duration(days: SyncLimits.trashDays);
    final unsentDeletes = await _unsentDeletes();
    final deletedIds = <String, Set<String>>{};
    Future<Set<String>> deletedOf(String table) async => deletedIds[table] ??= {
      for (final r
          in await db
              .customSelect(
                'SELECT id FROM "$table" WHERE deleted_at IS NOT NULL',
                readsFrom: _tables(table),
              )
              .get())
        r.data['id']! as String,
    };
    final items = <TrashItem>[];
    for (final spec in registry.specs) {
      final rows = await db
          .customSelect(
            'SELECT * FROM "${spec.name}" WHERE deleted_at IS NOT NULL',
            readsFrom: _tables(spec.name),
          )
          .get();
      for (final data in rows) {
        final row = spec.rowFromDb(data.data);
        final id = row['id']! as String;
        final deletedAt = DateTime.tryParse(row['deleted_at']! as String);
        if (deletedAt == null) continue;
        var left = deletedAt.add(keep).difference(now);
        if (unsentDeletes.contains((spec.name, id))) left = keep;
        if (left <= Duration.zero) continue;
        var parentDeleted = false;
        for (final relation in spec.parents) {
          final parentId = row[relation.column];
          if (parentId is String &&
              (await deletedOf(relation.parentTable)).contains(parentId)) {
            parentDeleted = true;
            break;
          }
        }
        if (parentDeleted) continue;
        items.add(
          TrashItem(
            table: spec.name,
            label: spec.label,
            id: id,
            title: spec.titleOf(row),
            deletedAt: deletedAt.toUtc(),
            daysLeft: (left.inMilliseconds / Duration.millisecondsPerDay)
                .ceil(),
          ),
        );
      }
    }
    items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return items;
  }

  /// Строки с неотправленной операцией `delete` (не отклонённой).
  Future<Set<(String, String)>> _unsentDeletes() async {
    final rows =
        await (db.select(db.syncOutbox)..where(
              (t) =>
                  t.opType.equals(OpType.delete) &
                  t.state.isNotValue(OpState.rejected),
            ))
            .get();
    return {for (final r in rows) (r.targetTable, r.rowId)};
  }

  /// Корзина в реальном времени: пересчитывается при любом изменении
  /// зарегистрированных таблиц.
  Stream<List<TrashItem>> watchTrash() =>
      _watch({for (final s in registry.specs) ..._tables(s.name)}, trashItems);

  /// Освобождает ресурсы.
  Future<void> dispose() => _writes.close();
}

extension on OutboxOp {
  OutboxOp withState(String newState) => OutboxOp(
    seq: seq,
    opId: opId,
    table: table,
    rowId: rowId,
    type: type,
    baseVersion: baseVersion,
    hlc: hlc,
    state: newState,
    createdAtMs: createdAtMs,
    fields: fields,
    rejectCode: rejectCode,
    rejectMessage: rejectMessage,
  );
}
