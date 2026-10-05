import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart' show Json;
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart'
    show ValidationError, ensureValid;
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_validation.dart';

/// Серверы, сервисы и проверки: локальные записи через [SyncStore] (строка +
/// HLC + outbox в одной транзакции). Проверки — как на сервере
/// (`monitoring_validation.dart`, правила цели — `monitoring_targets.dart`).
///
/// Удаление сервера или сервиса — одна операция `delete` родителя: каскад
/// делает сервер, а на клиенте потомков скрывает видимость строк. Кнопки
/// «Выключить» нет (`04`, 1.1 №3): ненужный сервис просто удаляется в корзину.
class MonitoringRepository {
  MonitoringRepository(this._store, {String Function()? newId})
    : _newId = newId ?? uuid7;

  final SyncStore _store;
  final String Function() _newId;

  static const String serversTable = 'monitor_servers';
  static const String servicesTable = 'monitor_services';
  static const String checksTable = 'monitor_checks';

  /// Новый UUIDv7 для строки.
  String newId() => _newId();

  static String? _blankToNull(String? text) {
    final t = text?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  Json _changed(Json before, Json after) => {
    for (final e in after.entries)
      if (before[e.key] != e.value) e.key: e.value,
  };

  // ---- серверы -----------------------------------------------------------------

  Future<MonitorServer?> getServer(String id) async {
    final row = await _store.getRow(serversTable, id);
    return row == null || row['deleted_at'] != null
        ? null
        : MonitorServer.fromRow(row);
  }

  MonitorServer _cleanServer(MonitorServer s) => MonitorServer(
    id: s.id,
    name: s.name.trim(),
    host: s.host.trim(),
    provider: _blankToNull(s.provider),
    note: _blankToNull(s.note),
  );

  /// Создаёт сервер; `server.id` задаёт вызывающий ([newId]).
  Future<String> createServer(MonitorServer server) async {
    final clean = _cleanServer(server);
    ensureValid(serverProblem(clean));
    await _store.create(serversTable, clean.id, clean.toFields());
    return clean.id;
  }

  Future<void> updateServer(MonitorServer next) async {
    final clean = _cleanServer(next);
    ensureValid(serverProblem(clean));
    await _store.transaction(() async {
      final row = await _store.getRow(serversTable, clean.id);
      if (row == null || row['deleted_at'] != null) {
        throw StateError('Сервера ${clean.id} нет');
      }
      final fields = _changed(row, clean.toFields());
      if (fields.isNotEmpty) {
        await _store.update(serversTable, clean.id, fields);
      }
    });
  }

  /// В корзину вместе с сервисами и проверками (каскад делает сервер).
  Future<void> deleteServer(String id) => _store.softDelete(serversTable, id);

  Future<void> restoreServer(String id) => _store.restore(serversTable, id);

  // ---- сервисы -----------------------------------------------------------------

  Future<MonitorService?> getService(String id) async {
    final row = await _store.getRow(servicesTable, id);
    return row == null || row['deleted_at'] != null
        ? null
        : MonitorService.fromRow(row);
  }

  MonitorService _cleanService(MonitorService s) => MonitorService(
    id: s.id,
    serverId: s.serverId,
    name: s.name.trim(),
    workProjectId: s.workProjectId,
    critical: s.critical,
    note: _blankToNull(s.note),
  );

  Future<String> createService(MonitorService service) async {
    final clean = _cleanService(service);
    ensureValid(serviceProblem(clean));
    await _store.transaction(() async {
      final parent = await _store.getRow(serversTable, clean.serverId);
      if (parent == null || parent['deleted_at'] != null) {
        throw const ValidationError('Сервер не найден');
      }
      await _store.create(servicesTable, clean.id, {
        'server_id': clean.serverId,
        ...clean.toFields(),
      });
    });
    return clean.id;
  }

  /// Правка сервиса; `server_id` не меняется.
  Future<void> updateService(MonitorService next) async {
    final clean = _cleanService(next);
    ensureValid(serviceProblem(clean));
    await _store.transaction(() async {
      final row = await _store.getRow(servicesTable, clean.id);
      if (row == null || row['deleted_at'] != null) {
        throw StateError('Сервиса ${clean.id} нет');
      }
      final fields = _changed(row, clean.toFields());
      if (fields.isNotEmpty) {
        await _store.update(servicesTable, clean.id, fields);
      }
    });
  }

  Future<void> deleteService(String id) => _store.softDelete(servicesTable, id);

  Future<void> restoreService(String id) => _store.restore(servicesTable, id);

  // ---- проверки ----------------------------------------------------------------

  Future<MonitorCheck?> getCheck(String id) async {
    final row = await _store.getRow(checksTable, id);
    return row == null || row['deleted_at'] != null
        ? null
        : MonitorCheck.fromRow(row);
  }

  /// Оставляет только колонки, нужные виду: остальные — `null` (spec 2.3).
  MonitorCheck _cleanCheck(MonitorCheck c) {
    final used = usedColumns[c.kind]!;
    T? keep<T>(String column, T? value) => used.contains(column) ? value : null;
    return MonitorCheck(
      id: c.id,
      serviceId: c.serviceId,
      kind: c.kind,
      name: c.name.trim(),
      url: keep('url', _blankToNull(c.url)),
      host: keep('host', _blankToNull(c.host)),
      port: keep('port', c.port),
      dnsRecordType: keep('dns_record_type', _blankToNull(c.dnsRecordType)),
      expectedValue: keep('expected_value', _blankToNull(c.expectedValue)),
      expectedStatus: keep('expected_status', c.expectedStatus),
      keyword: keep('keyword', _blankToNull(c.keyword)),
      sslMinDays: keep('ssl_min_days', c.sslMinDays),
      intervalSeconds: c.intervalSeconds,
      timeoutSeconds: c.timeoutSeconds,
    );
  }

  Future<String> createCheck(MonitorCheck check) async {
    final clean = _cleanCheck(check);
    ensureValid(checkProblem(clean));
    await _store.transaction(() async {
      final parent = await _store.getRow(servicesTable, clean.serviceId);
      if (parent == null || parent['deleted_at'] != null) {
        throw const ValidationError('Сервис не найден');
      }
      await _store.create(checksTable, clean.id, {
        'service_id': clean.serviceId,
        'kind': clean.kind.wire,
        ...clean.toFields(),
      });
    });
    return clean.id;
  }

  /// Правка проверки; вид и сервис не меняются (удалить и создать заново).
  Future<void> updateCheck(MonitorCheck next) async {
    final clean = _cleanCheck(next);
    ensureValid(checkProblem(clean));
    await _store.transaction(() async {
      final row = await _store.getRow(checksTable, clean.id);
      if (row == null || row['deleted_at'] != null) {
        throw StateError('Проверки ${clean.id} нет');
      }
      if (row['kind'] != clean.kind.wire) {
        throw const ValidationError(
          'Вид проверки не меняется: удалите её и создайте заново',
        );
      }
      final fields = _changed(row, clean.toFields());
      if (fields.isNotEmpty) await _store.update(checksTable, clean.id, fields);
    });
  }

  Future<void> deleteCheck(String id) => _store.softDelete(checksTable, id);

  Future<void> restoreCheck(String id) => _store.restore(checksTable, id);
}

final Provider<MonitoringRepository> monitoringRepositoryProvider =
    Provider<MonitoringRepository>(
      (ref) => MonitoringRepository(ref.watch(syncStoreProvider)),
    );
