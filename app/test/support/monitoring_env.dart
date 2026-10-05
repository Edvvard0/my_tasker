import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/features/monitoring/data/monitoring_api.dart';
import 'package:my_tasker/features/monitoring/data/monitoring_repository.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';

import 'calendar_env.dart' show appRegistry;
import 'fake_server/fake_sync_server.dart';
import 'manual_clock.dart';
import 'pump_app.dart';
import 'sync_env.dart';

export 'pump_app.dart' show desktopSize, expandedSize, mediumSize, phoneSize;
export 'work_env.dart' show goTo, locationOf, tapKey;

/// «Сейчас» для экранов «Серверов» по умолчанию: понедельник, 5 октября 2026,
/// 14:40 по Москве.
final DateTime monitoringNow = DateTime.utc(2026, 10, 5, 11, 40);

/// Устройство в тесте: репозиторий «Серверов» поверх [TestDevice] (тесты
/// синхронизации без интерфейса).
class MonitoringDevice {
  MonitoringDevice(this.device, {String Function()? newId})
    : repo = MonitoringRepository(device.store, newId: newId);

  static Future<MonitoringDevice> create(
    FakeSyncServer server, {
    ManualClock? clock,
    String Function()? newId,
  }) async => MonitoringDevice(
    await TestDevice.create(server, clock: clock, registry: appRegistry()),
    newId: newId,
  );

  final TestDevice device;
  final MonitoringRepository repo;

  Future<void> close() => device.close();
}

/// Подделка [MonitoringApi]: ответы и ошибки задаёт тест, вызовы
/// записываются.
class FakeMonitoringApi implements MonitoringApi {
  FakeMonitoringApi({
    this.snapshot,
    this.etag = '"v1"',
    this.incidentPages = const [],
    this.self,
    this.testResult = const TelegramTestResult(ok: true),
  });

  /// Тело снимка (как у сервера); `null` — запрос не удаётся (см. [error]).
  Map<String, Object?>? snapshot;
  String? etag;

  /// Ошибка всех запросов (сеть, `429`, `503`, …).
  ApiException? error;

  /// Ошибка только следующего вызова `refresh`.
  ApiException? refreshError;

  /// Страницы инцидентов по порядку запросов.
  List<IncidentPage> incidentPages;
  SelfCheck? self;
  TelegramTestResult testResult;

  final List<String?> pulseEtags = [];
  int refreshCalls = 0;
  int telegramCalls = 0;
  final List<({IncidentCursor? cursor, String? serviceId})> incidentCalls = [];
  int selfCalls = 0;

  /// Как отвечает сервер на условный запрос: `304` при совпадении `ETag`.
  @override
  Future<PulseFetch> pulse({String? etag}) async {
    pulseEtags.add(etag);
    final failure = error;
    if (failure != null) throw failure;
    if (etag != null && etag == this.etag) {
      return const PulseFetch.notModified();
    }
    final body = snapshot!;
    return PulseFetch.fresh(PulseSnapshot.fromJson(body), this.etag, body);
  }

  @override
  Future<PulseFetch> refresh() async {
    refreshCalls++;
    final failure = refreshError ?? error;
    refreshError = null;
    if (failure != null) throw failure;
    final body = snapshot!;
    return PulseFetch.fresh(PulseSnapshot.fromJson(body), null, body);
  }

  @override
  Future<IncidentPage> incidents({
    int limit = 50,
    IncidentCursor? cursor,
    String? serviceId,
  }) async {
    incidentCalls.add((cursor: cursor, serviceId: serviceId));
    final failure = error;
    if (failure != null) throw failure;
    if (incidentPages.isEmpty) return const IncidentPage(incidents: []);
    final index = incidentCalls.length - 1;
    return incidentPages[index.clamp(0, incidentPages.length - 1)];
  }

  @override
  Future<SelfCheck> selfCheck() async {
    selfCalls++;
    final failure = error;
    if (failure != null) throw failure;
    return self ?? SelfCheck.fromJson(const {});
  }

  @override
  Future<TelegramTestResult> telegramTest() async {
    telegramCalls++;
    final failure = error;
    if (failure != null) throw failure;
    return testResult;
  }
}

/// Нет связи: ошибка сети.
const ApiException offlineError = ApiException.network('test');

/// Лимит `429` с паузой.
ApiException rateLimitError([int seconds = 7]) => ApiException(
  kind: ApiErrorKind.http,
  status: 429,
  code: 'rate_limited',
  retryAfter: Duration(seconds: seconds),
);

/// `503 monitoring_not_configured`.
const ApiException notConfiguredError = ApiException(
  kind: ApiErrorKind.http,
  status: 503,
  code: 'monitoring_not_configured',
);

/// Снимок «Пульса» в форме ответа сервера: [services] — карточки.
Map<String, Object?> pulseBody({
  required List<Map<String, Object?>> services,
  bool configured = true,
  bool healthy = true,
  String? engineError,
  bool telegram = true,
  String generatedAt = '2026-10-05T11:40:00Z',
}) {
  int count(String s) => services.where((x) => x['status'] == s).length;
  return {
    'generated_at': generatedAt,
    'engine': {
      'configured': configured,
      'last_poll_at': '2026-10-05T11:39:55Z',
      'healthy': healthy,
      'error': engineError,
      'telegram_configured': telegram,
    },
    'summary': {
      'services': services.length,
      'down': count('down'),
      'up': count('up'),
      'unknown': count('unknown'),
    },
    'services': services,
  };
}

/// Карточка сервиса в форме ответа сервера.
Map<String, Object?> pulseService({
  required String id,
  required String name,
  String server = 'Основной VPS',
  String serverId = 'srv-1',
  String status = 'up',
  bool critical = false,
  String? downSince,
  int? h24 = 10000,
  int? responseMs = 178,
  List<Map<String, Object?>>? checks,
}) => {
  'id': id,
  'server_id': serverId,
  'name': name,
  'server': server,
  'critical': critical,
  'status': status,
  'down_since': downSince,
  'availability': {'h24': h24, 'd7': h24, 'd30': h24},
  'response_ms': responseMs,
  'open_incident': downSince == null ? null : 'inc-$id',
  'checks':
      checks ??
      [pulseCheck(id: '$id-http', status: status, responseMs: responseMs)],
};

Map<String, Object?> pulseCheck({
  required String id,
  String kind = 'http',
  String name = 'Главная',
  String status = 'up',
  String? problem,
  int? responseMs = 178,
  List<int>? spark,
  int? h24 = 10000,
}) => {
  'id': id,
  'kind': kind,
  'name': name,
  'status': status,
  'problem': problem,
  'last_at': '2026-10-05T11:39:50Z',
  'response_ms': responseMs,
  'availability': {'h24': h24, 'd7': h24, 'd30': h24},
  'spark':
      spark ??
      [
        for (var i = 0; i < 24; i++)
          if (status == 'down' && i > 18) -1 else 120 + (i * 37) % 90,
      ],
};

/// Инцидент в форме ответа сервера.
Map<String, Object?> incidentJson({
  required String id,
  required String startedAt,
  String serviceId = 'svc-1',
  String? serviceName = 'Сайт',
  String? endedAt,
  int? duration,
  String reason = 'HTTP 502',
}) => {
  'id': id,
  'service_id': serviceId,
  'service_name': serviceName,
  'started_at': startedAt,
  'ended_at': endedAt,
  'duration_seconds': duration,
  'reason': reason,
  'check_ids': <String>[],
};

/// Страница инцидентов с курсором следующей (или без).
IncidentPage incidentPage(
  List<Map<String, Object?>> items, {
  String? nextBefore,
  String? nextBeforeId,
}) => IncidentPage.fromJson({
  'incidents': items,
  'next_before': nextBefore,
  'next_before_id': nextBeforeId,
});

/// Запускает приложение на экране «Серверов» с поддельным API; [seedWith]
/// наполняет серверы, сервисы и проверки заказчика.
Future<ProviderContainer> pumpMonitoring(
  WidgetTester tester, {
  required FakeMonitoringApi api,
  Size size = phoneSize,
  String location = '/work/servers',
  DateTime? now,
  Future<void> Function(ProviderContainer container)? seedWith,
  List<Override> overrides = const [],
}) async {
  final container = await pumpApp(
    tester,
    size: size,
    location: location,
    now: now ?? monitoringNow,
    settle: false,
    overrides: [monitoringApiProvider.overrideWithValue(api), ...overrides],
  );
  if (seedWith != null) await tester.runAsync(() => seedWith(container));
  await settleMonitoring(tester);
  return container;
}

/// Даёт завершиться чтению из БД (оно идёт в реальном времени) и дорисовывает.
Future<void> settleMonitoring(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  await tester.pumpAndSettle();
}

/// Постоянные id для тестов, где снимок «Пульса» должен ссылаться на
/// локальные сервер и сервис.
const String srvA = '01900000-0000-7000-8000-00000000a001';
const String svcA = '01900000-0000-7000-8000-00000000a002';
const String chkA = '01900000-0000-7000-8000-00000000a003';

/// Сервер -> сервис -> проверка в локальной БД; возвращает id.
Future<({String server, String service, String check})> seedMonitor(
  ProviderContainer c, {
  String serverName = 'Основной VPS',
  String host = 'example.com',
  String serviceName = 'Сайт',
  String checkName = 'Главная',
  String url = 'https://example.com',
  bool critical = false,
  String? serverId,
  String? serviceId,
  String? checkId,
}) async {
  final repo = c.read(monitoringRepositoryProvider);
  final server = await repo.createServer(
    MonitorServer(id: serverId ?? repo.newId(), name: serverName, host: host),
  );
  final service = await repo.createService(
    MonitorService(
      id: serviceId ?? repo.newId(),
      serverId: server,
      name: serviceName,
      critical: critical,
    ),
  );
  final check = await repo.createCheck(
    MonitorCheck(
      id: checkId ?? repo.newId(),
      serviceId: service,
      kind: CheckKind.http,
      name: checkName,
      url: url,
      intervalSeconds: 20,
      timeoutSeconds: 5,
    ),
  );
  return (server: server, service: service, check: check);
}
