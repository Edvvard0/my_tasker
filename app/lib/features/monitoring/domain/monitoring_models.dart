import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart' show Json;

/// Модели «Серверов» (spec `stage9_monitoring.md`, разделы 2 и 8).
///
/// Данные заказчика (сервер, сервис, проверка) — синхронизируемые строки;
/// «Пульс» (снимок, инциденты, самопроверка) приходит из API и не хранится
/// как строки. Чтение «мягкое»: неизвестное значение перечисления (новая
/// версия сервера) читается как значение по умолчанию, а не ломает экран.

const Object _unset = Object();

/// Вид проверки (`monitor_checks.kind`, неизменяем).
enum CheckKind {
  http('http', 'HTTP'),
  tcp('tcp', 'TCP'),
  dns('dns', 'DNS'),
  ssl('ssl', 'SSL');

  const CheckKind(this.wire, this.label);

  final String wire;
  final String label;

  static CheckKind parse(Object? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => http);
}

/// Тип DNS-записи проверки `dns` (`dns_record_type`).
const List<String> dnsRecordTypes = ['A', 'AAAA', 'CNAME', 'MX', 'NS', 'TXT'];

/// Статус проверки и сервиса в «Пульсе» (автомат алертов сервера).
enum PulseStatus {
  up('up'),
  down('down'),
  unknown('unknown');

  const PulseStatus(this.wire);

  final String wire;

  static PulseStatus parse(Object? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => unknown);
}

String? _text(Object? value) => value is String ? value : null;

int? _int(Object? value) => value is int ? value : null;

/// Сервер (`monitor_servers`): имя и публичный адрес.
@immutable
class MonitorServer {
  const MonitorServer({
    required this.id,
    required this.name,
    required this.host,
    this.provider,
    this.note,
  });

  factory MonitorServer.fromRow(Json row) => MonitorServer(
    id: (row['id'] as String?) ?? '',
    name: (row['name'] as String?) ?? '',
    host: (row['host'] as String?) ?? '',
    provider: _text(row['provider']),
    note: _text(row['note']),
  );

  final String id;
  final String name;
  final String host;
  final String? provider;
  final String? note;

  /// Изменяемые поля для записи (`create` / `update`).
  Json toFields() => {
    'name': name,
    'host': host,
    'provider': provider,
    'note': note,
  };

  MonitorServer copyWith({
    String? name,
    String? host,
    Object? provider = _unset,
    Object? note = _unset,
  }) => MonitorServer(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    provider: identical(provider, _unset) ? this.provider : provider as String?,
    note: identical(note, _unset) ? this.note : note as String?,
  );
}

/// Сервис / проект на сервере (`monitor_services`): карточка «Пульса».
@immutable
class MonitorService {
  const MonitorService({
    required this.id,
    required this.serverId,
    required this.name,
    this.workProjectId,
    this.critical = false,
    this.note,
  });

  factory MonitorService.fromRow(Json row) => MonitorService(
    id: (row['id'] as String?) ?? '',
    serverId: (row['server_id'] as String?) ?? '',
    name: (row['name'] as String?) ?? '',
    workProjectId: _text(row['work_project_id']),
    critical: row['critical'] == true,
    note: _text(row['note']),
  );

  final String id;

  /// Неизменяем после создания.
  final String serverId;
  final String name;

  /// Мягкая ссылка на проект Работы (без внешнего ключа).
  final String? workProjectId;

  /// Критичный сервис не подчиняется тихим часам уведомлений.
  final bool critical;
  final String? note;

  /// Изменяемые поля (без `server_id`).
  Json toFields() => {
    'name': name,
    'work_project_id': workProjectId,
    'critical': critical,
    'note': note,
  };

  MonitorService copyWith({
    String? name,
    Object? workProjectId = _unset,
    bool? critical,
    Object? note = _unset,
  }) => MonitorService(
    id: id,
    serverId: serverId,
    name: name ?? this.name,
    workProjectId: identical(workProjectId, _unset)
        ? this.workProjectId
        : workProjectId as String?,
    critical: critical ?? this.critical,
    note: identical(note, _unset) ? this.note : note as String?,
  );
}

/// Проверка (`monitor_checks`): HTTP, TCP, DNS или SSL.
@immutable
class MonitorCheck {
  const MonitorCheck({
    required this.id,
    required this.serviceId,
    required this.kind,
    required this.name,
    required this.intervalSeconds,
    required this.timeoutSeconds,
    this.url,
    this.host,
    this.port,
    this.dnsRecordType,
    this.expectedValue,
    this.expectedStatus,
    this.keyword,
    this.sslMinDays,
  });

  factory MonitorCheck.fromRow(Json row) => MonitorCheck(
    id: (row['id'] as String?) ?? '',
    serviceId: (row['service_id'] as String?) ?? '',
    kind: CheckKind.parse(row['kind']),
    name: (row['name'] as String?) ?? '',
    url: _text(row['url']),
    host: _text(row['host']),
    port: _int(row['port']),
    dnsRecordType: _text(row['dns_record_type']),
    expectedValue: _text(row['expected_value']),
    expectedStatus: _int(row['expected_status']),
    keyword: _text(row['keyword']),
    sslMinDays: _int(row['ssl_min_days']),
    intervalSeconds: _int(row['interval_seconds']) ?? defaultInterval,
    timeoutSeconds: _int(row['timeout_seconds']) ?? defaultTimeout,
  );

  /// Рекомендуемый интервал клиента (spec 2.3).
  static const int defaultInterval = 20;
  static const int defaultTimeout = 5;

  final String id;

  /// Неизменяем после создания.
  final String serviceId;

  /// Неизменяем: сменить вид — удалить и создать заново.
  final CheckKind kind;
  final String name;
  final String? url;
  final String? host;
  final int? port;
  final String? dnsRecordType;
  final String? expectedValue;
  final int? expectedStatus;
  final String? keyword;
  final int? sslMinDays;
  final int intervalSeconds;
  final int timeoutSeconds;

  /// Все поля вида; колонки, не относящиеся к виду, — `null` (spec 2.3).
  Json toFields() => {
    'name': name,
    'url': url,
    'host': host,
    'port': port,
    'dns_record_type': dnsRecordType,
    'expected_value': expectedValue,
    'expected_status': expectedStatus,
    'keyword': keyword,
    'ssl_min_days': sslMinDays,
    'interval_seconds': intervalSeconds,
    'timeout_seconds': timeoutSeconds,
  };

  /// Цель одной строкой для списка: адрес, `host:port` или имя запроса.
  String get target => switch (kind) {
    CheckKind.http => url ?? '',
    CheckKind.tcp => '${host ?? ''}:${port ?? ''}',
    CheckKind.dns => '${dnsRecordType ?? ''} ${host ?? ''}',
    CheckKind.ssl =>
      port == null || port == 443 ? host ?? '' : '${host ?? ''}:$port',
  };
}

// ------------------------------------------------------------------ «Пульс»

/// Доступность в базисных пунктах (`10 000` = 100 %); `null` — нет данных.
@immutable
class Availability {
  const Availability({this.h24, this.d7, this.d30});

  factory Availability.fromJson(Object? json) {
    final m = json is Map ? json : const <String, Object?>{};
    return Availability(
      h24: _int(m['h24']),
      d7: _int(m['d7']),
      d30: _int(m['d30']),
    );
  }

  final int? h24;
  final int? d7;
  final int? d30;

  Map<String, Object?> toJson() => {'h24': h24, 'd7': d7, 'd30': d30};
}

/// Карточка проверки в «Пульсе».
@immutable
class PulseCheck {
  const PulseCheck({
    required this.id,
    required this.kind,
    required this.name,
    required this.status,
    required this.availability,
    required this.spark,
    this.problem,
    this.lastAt,
    this.responseMs,
  });

  factory PulseCheck.fromJson(Json json) => PulseCheck(
    id: (json['id'] as String?) ?? '',
    kind: CheckKind.parse(json['kind']),
    name: (json['name'] as String?) ?? '',
    status: PulseStatus.parse(json['status']),
    problem: _text(json['problem']),
    lastAt: _text(json['last_at']),
    responseMs: _int(json['response_ms']),
    availability: Availability.fromJson(json['availability']),
    spark: [
      if (json['spark'] is List)
        for (final v in json['spark']! as List)
          if (v is int) v,
    ],
  );

  final String id;
  final CheckKind kind;
  final String name;
  final PulseStatus status;

  /// Код отказа генерации конфигурации (`resolve_failed`, …) или `null`.
  final String? problem;
  final String? lastAt;
  final int? responseMs;
  final Availability availability;

  /// Последние до 30 результатов от старых к новым: миллисекунды или `-1`
  /// для неудачи.
  final List<int> spark;
}

/// Карточка сервиса в «Пульсе».
@immutable
class PulseService {
  const PulseService({
    required this.id,
    required this.serverId,
    required this.name,
    required this.server,
    required this.critical,
    required this.status,
    required this.availability,
    required this.checks,
    this.downSince,
    this.responseMs,
    this.openIncident,
  });

  factory PulseService.fromJson(Json json) => PulseService(
    id: (json['id'] as String?) ?? '',
    serverId: (json['server_id'] as String?) ?? '',
    name: (json['name'] as String?) ?? '',
    server: (json['server'] as String?) ?? '',
    critical: json['critical'] == true,
    status: PulseStatus.parse(json['status']),
    downSince: _text(json['down_since']),
    availability: Availability.fromJson(json['availability']),
    responseMs: _int(json['response_ms']),
    openIncident: _text(json['open_incident']),
    checks: [
      if (json['checks'] is List)
        for (final c in json['checks']! as List)
          if (c is Map) PulseCheck.fromJson(c.cast()),
    ],
  );

  final String id;
  final String serverId;
  final String name;
  final String server;
  final bool critical;
  final PulseStatus status;
  final String? downSince;
  final Availability availability;
  final int? responseMs;
  final String? openIncident;
  final List<PulseCheck> checks;

  /// Проверки, которые не запускаются (имя не разрешается и т. п.).
  List<PulseCheck> get problems => [
    for (final c in checks)
      if (c.problem != null) c,
  ];

  /// Точки мини-графика сервиса: отклик самой длинной истории проверок.
  List<int> get spark {
    var best = const <int>[];
    for (final c in checks) {
      if (c.spark.length > best.length) best = c.spark;
    }
    return best;
  }
}

/// Состояние движка проверок в снимке.
@immutable
class PulseEngine {
  const PulseEngine({
    required this.configured,
    required this.healthy,
    required this.telegramConfigured,
    this.lastPollAt,
    this.error,
  });

  factory PulseEngine.fromJson(Object? json) {
    final m = json is Map ? json : const <String, Object?>{};
    return PulseEngine(
      configured: m['configured'] == true,
      healthy: m['healthy'] == true,
      telegramConfigured: m['telegram_configured'] == true,
      lastPollAt: _text(m['last_poll_at']),
      error: _text(m['error']),
    );
  }

  final bool configured;

  /// Опрос был не позже 60 с назад и без ошибки.
  final bool healthy;
  final bool telegramConfigured;
  final String? lastPollAt;
  final String? error;
}

/// Снимок «Пульса» целиком (`GET /monitoring/pulse`).
@immutable
class PulseSnapshot {
  const PulseSnapshot({
    required this.generatedAt,
    required this.engine,
    required this.services,
    required this.down,
    required this.up,
    required this.unknown,
  });

  factory PulseSnapshot.fromJson(Json json) {
    final summary = json['summary'] is Map
        ? (json['summary']! as Map).cast<String, Object?>()
        : const <String, Object?>{};
    final services = [
      if (json['services'] is List)
        for (final s in json['services']! as List)
          if (s is Map) PulseService.fromJson(s.cast()),
    ];
    int count(String key, PulseStatus status) =>
        _int(summary[key]) ?? services.where((s) => s.status == status).length;
    return PulseSnapshot(
      generatedAt: _text(json['generated_at']),
      engine: PulseEngine.fromJson(json['engine']),
      services: services,
      down: count('down', PulseStatus.down),
      up: count('up', PulseStatus.up),
      unknown: count('unknown', PulseStatus.unknown),
    );
  }

  final String? generatedAt;
  final PulseEngine engine;
  final List<PulseService> services;
  final int down;
  final int up;
  final int unknown;

  int get total => services.length;
}

/// Инцидент (`GET /monitoring/incidents`).
@immutable
class Incident {
  const Incident({
    required this.id,
    required this.serviceId,
    required this.startedAt,
    this.serviceName,
    this.endedAt,
    this.durationSeconds,
    this.reason,
    this.checkIds = const [],
  });

  factory Incident.fromJson(Json json) => Incident(
    id: (json['id'] as String?) ?? '',
    serviceId: (json['service_id'] as String?) ?? '',
    serviceName: _text(json['service_name']),
    startedAt: (json['started_at'] as String?) ?? '',
    endedAt: _text(json['ended_at']),
    durationSeconds: _int(json['duration_seconds']),
    reason: _text(json['reason']),
    checkIds: [
      if (json['check_ids'] is List)
        for (final v in json['check_ids']! as List)
          if (v is String) v,
    ],
  );

  final String id;
  final String serviceId;

  /// `null` — сервис уже удалён.
  final String? serviceName;
  final String startedAt;
  final String? endedAt;
  final int? durationSeconds;
  final String? reason;
  final List<String> checkIds;

  bool get isOpen => endedAt == null;

  Map<String, Object?> toJson() => {
    'id': id,
    'service_id': serviceId,
    'service_name': serviceName,
    'started_at': startedAt,
    'ended_at': endedAt,
    'duration_seconds': durationSeconds,
    'reason': reason,
    'check_ids': checkIds,
  };
}

/// Курсор следующей страницы инцидентов: пара `before` + `before_id`
/// (несколько инцидентов могут начаться в одну секунду).
@immutable
class IncidentCursor {
  const IncidentCursor(this.before, this.beforeId);

  final String before;
  final String beforeId;

  @override
  bool operator ==(Object other) =>
      other is IncidentCursor &&
      other.before == before &&
      other.beforeId == beforeId;

  @override
  int get hashCode => Object.hash(before, beforeId);
}

/// Страница инцидентов и курсор следующей (`null` — конец ленты).
@immutable
class IncidentPage {
  const IncidentPage({required this.incidents, this.next});

  factory IncidentPage.fromJson(Json json) {
    final before = _text(json['next_before']);
    final beforeId = _text(json['next_before_id']);
    return IncidentPage(
      incidents: [
        if (json['incidents'] is List)
          for (final i in json['incidents']! as List)
            if (i is Map) Incident.fromJson(i.cast()),
      ],
      next: before == null || beforeId == null
          ? null
          : IncidentCursor(before, beforeId),
    );
  }

  final List<Incident> incidents;
  final IncidentCursor? next;

  /// Форма ответа сервера (для офлайн-кэша).
  Map<String, Object?> toJson() => {
    'incidents': [for (final i in incidents) i.toJson()],
    'next_before': next?.before,
    'next_before_id': next?.beforeId,
  };
}

/// Отказ генерации конфигурации для проверки (`checks_rejected`).
@immutable
class RejectedCheck {
  const RejectedCheck({required this.checkId, required this.reason});

  final String checkId;
  final String reason;
}

/// Самопроверка мониторинга (`GET /monitoring/self-check`).
@immutable
class SelfCheck {
  const SelfCheck({
    required this.engineConfigured,
    required this.telegramConfigured,
    required this.checksActive,
    required this.rejected,
    required this.queued,
    this.lastPollAt,
    this.lagSeconds,
    this.engineError,
    this.configSyncedAt,
    this.telegramLastSuccessAt,
    this.telegramLastError,
  });

  factory SelfCheck.fromJson(Json json) {
    Json obj(Object? v) => v is Map ? v.cast<String, Object?>() : const {};
    final engine = obj(json['engine']);
    final config = obj(json['config']);
    final telegram = obj(json['telegram']);
    return SelfCheck(
      engineConfigured: engine['configured'] == true,
      lastPollAt: _text(engine['last_poll_at']),
      lagSeconds: _int(engine['lag_seconds']),
      engineError: _text(engine['error']),
      configSyncedAt: _text(config['synced_at']),
      checksActive: _int(config['checks_active']) ?? 0,
      rejected: [
        if (config['checks_rejected'] is List)
          for (final r in config['checks_rejected']! as List)
            if (r is Map)
              RejectedCheck(
                checkId: (r['check_id'] as String?) ?? '',
                reason: (r['reason'] as String?) ?? '',
              ),
      ],
      telegramConfigured: telegram['configured'] == true,
      telegramLastSuccessAt: _text(telegram['last_success_at']),
      telegramLastError: _text(telegram['last_error']),
      queued: _int(telegram['queued']) ?? 0,
    );
  }

  final bool engineConfigured;
  final String? lastPollAt;
  final int? lagSeconds;
  final String? engineError;
  final String? configSyncedAt;
  final int checksActive;
  final List<RejectedCheck> rejected;
  final bool telegramConfigured;
  final String? telegramLastSuccessAt;
  final String? telegramLastError;

  /// Сообщений Telegram в очереди.
  final int queued;
}

/// Итог «Отправить тест» (`POST /monitoring/telegram/test`).
@immutable
class TelegramTestResult {
  const TelegramTestResult({required this.ok, this.error});

  factory TelegramTestResult.fromJson(Json json) =>
      TelegramTestResult(ok: json['ok'] == true, error: _text(json['error']));

  final bool ok;

  /// Код ошибки: `not_configured`, `network`, `rate_limited`, …
  final String? error;
}
