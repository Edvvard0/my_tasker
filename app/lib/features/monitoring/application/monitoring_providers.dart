import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show NotifierProviderFamily;
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart' show Json;
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/monitoring/data/monitoring_api.dart';
import 'package:my_tasker/features/monitoring/data/pulse_cache.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_format.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';

// ---------------------------------------------------------------- данные заказчика

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

final StreamProvider<List<MonitorServer>> monitorServersProvider =
    _rows<MonitorServer>(
      'monitor_servers',
      MonitorServer.fromRow,
      orderBy: 't.name COLLATE NOCASE, t.id',
    );

final StreamProvider<List<MonitorService>> monitorServicesProvider =
    _rows<MonitorService>(
      'monitor_services',
      MonitorService.fromRow,
      orderBy: 't.name COLLATE NOCASE, t.id',
    );

final StreamProvider<List<MonitorCheck>> monitorChecksProvider =
    _rows<MonitorCheck>(
      'monitor_checks',
      MonitorCheck.fromRow,
      orderBy: 't.name COLLATE NOCASE, t.id',
    );

/// Серверы, сервисы и проверки заказчика одним снимком (работает офлайн).
@immutable
class MonitorData {
  MonitorData({
    required this.servers,
    required this.services,
    required this.checks,
  });

  final List<MonitorServer> servers;
  final List<MonitorService> services;
  final List<MonitorCheck> checks;

  late final Map<String, MonitorServer> serverById = {
    for (final s in servers) s.id: s,
  };
  late final Map<String, MonitorService> serviceById = {
    for (final s in services) s.id: s,
  };
  late final Map<String, MonitorCheck> checkById = {
    for (final c in checks) c.id: c,
  };

  List<MonitorService> servicesOf(String serverId) => [
    for (final s in services)
      if (s.serverId == serverId) s,
  ];

  List<MonitorCheck> checksOf(String serviceId) => [
    for (final c in checks)
      if (c.serviceId == serviceId) c,
  ];

  bool get isEmpty => servers.isEmpty;
}

final Provider<AsyncValue<MonitorData>> monitorDataProvider =
    Provider<AsyncValue<MonitorData>>((ref) {
      final servers = ref.watch(monitorServersProvider);
      final services = ref.watch(monitorServicesProvider);
      final checks = ref.watch(monitorChecksProvider);
      final error = servers.error ?? services.error ?? checks.error;
      if (error != null) return AsyncError(error, StackTrace.current);
      if (!servers.hasValue || !services.hasValue || !checks.hasValue) {
        return const AsyncLoading();
      }
      return AsyncData(
        MonitorData(
          servers: servers.requireValue,
          services: services.requireValue,
          checks: checks.requireValue,
        ),
      );
    });

// ---------------------------------------------------------------- «Пульс»

/// Как часто экран «Пульса» молча обновляет снимок (условный запрос с
/// `If-None-Match`: неизменный «Пульс» отвечает `304`). `null` — не
/// обновлять само (тесты).
final Provider<Duration?> pulsePollIntervalProvider = Provider<Duration?>(
  (ref) => const Duration(seconds: 20),
);

/// Не чаще раза в 5 секунд сервер читает движок по «Проверить сейчас»
/// (`REFRESH_MIN_SECONDS`): частые нажатия клиент не пересылает.
const Duration refreshCooldown = Duration(seconds: 5);

/// Тестовое сообщение Telegram — не чаще раза в 10 секунд
/// (`TELEGRAM_TEST_MIN_SECONDS`).
const Duration telegramTestCooldown = Duration(seconds: 10);

/// Итог нажатия «Проверить сейчас» и «Отправить тест».
enum ActionOutcome {
  /// Выполнено.
  done,

  /// Слишком рано: повтор не отправлен (защита от частых нажатий).
  tooSoon,

  /// Нет связи с сервером: данные — из кэша.
  offline,

  /// Сервер ответил лимитом (`429` / `rate_limited`).
  rateLimited,

  /// Другая ошибка; текст — [ActionResult.message].
  failed,
}

/// Результат действия с текстом для пользователя.
@immutable
class ActionResult {
  const ActionResult(this.outcome, [this.message]);

  final ActionOutcome outcome;
  final String? message;

  bool get ok => outcome == ActionOutcome.done;
}

/// Состояние экрана «Пульса»: снимок (свежий или из кэша), на какой момент он
/// актуален, нет ли связи.
@immutable
class PulseState {
  const PulseState({
    this.snapshot,
    this.asOf,
    this.loading = true,
    this.offline = false,
    this.refreshing = false,
    this.error,
  });

  final PulseSnapshot? snapshot;

  /// Когда данные были получены (часы устройства).
  final DateTime? asOf;

  /// Идёт первая загрузка (снимка ещё нет).
  final bool loading;

  /// Последний запрос не дошёл до сервера: показан кэш.
  final bool offline;

  /// Идёт «Проверить сейчас».
  final bool refreshing;

  /// Текст ошибки сервера (не сетевой): снимок остаётся, если он был.
  final String? error;

  bool get hasData => snapshot != null;

  PulseState copyWith({
    Object? snapshot = _keep,
    Object? asOf = _keep,
    bool? loading,
    bool? offline,
    bool? refreshing,
    Object? error = _keep,
  }) => PulseState(
    snapshot: identical(snapshot, _keep)
        ? this.snapshot
        : snapshot as PulseSnapshot?,
    asOf: identical(asOf, _keep) ? this.asOf : asOf as DateTime?,
    loading: loading ?? this.loading,
    offline: offline ?? this.offline,
    refreshing: refreshing ?? this.refreshing,
    error: identical(error, _keep) ? this.error : error as String?,
  );
}

const Object _keep = Object();

bool _isNetwork(Object e) => e is ApiException && e.isNetwork;

bool _isRateLimited(Object e) =>
    e is ApiException && (e.status == 429 || e.code == 'rate_limited');

Duration? _retryAfter(Object e) => e is ApiException ? e.retryAfter : null;

/// Снимок «Пульса»: сначала кэш (показывается сразу, офлайн-first), затем
/// условный запрос; без сети остаётся кэш с пометкой.
class PulseController extends Notifier<PulseState> {
  String? _etag;
  Timer? _timer;
  bool _disposed = false;
  bool _fetching = false;
  DateTime? _nextRefreshAt;

  @override
  PulseState build() {
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
    });
    unawaited(Future<void>(_start));
    return const PulseState();
  }

  DateTime _now() => ref.read(clockProvider)();

  Future<void> _start() async {
    final cached = await ref.read(pulseCacheProvider).readPulse();
    if (_disposed) return;
    if (cached != null) {
      _etag = cached.etag;
      state = state.copyWith(snapshot: cached.snapshot, asOf: cached.asOf);
    }
    await load();
    if (_disposed) return;
    final interval = ref.read(pulsePollIntervalProvider);
    if (interval != null) {
      _timer = Timer.periodic(interval, (_) => unawaited(load()));
    }
  }

  /// Условный запрос снимка. `304` — кэш актуален; сетевая ошибка — остаётся
  /// кэш с пометкой «нет сети».
  Future<void> load() async {
    if (_fetching || _disposed) return;
    _fetching = true;
    try {
      final result = await ref.read(monitoringApiProvider).pulse(etag: _etag);
      if (_disposed) return;
      final now = _now();
      final cache = ref.read(pulseCacheProvider);
      if (result.isNotModified) {
        if (state.snapshot != null) await cache.touchPulse(now);
      } else {
        _etag = result.etag;
        await cache.writePulse(raw: result.raw!, etag: result.etag, asOf: now);
        if (_disposed) return;
        state = state.copyWith(snapshot: result.snapshot);
      }
      state = state.copyWith(
        asOf: result.isNotModified && state.snapshot == null ? null : now,
        loading: false,
        offline: false,
        error: null,
      );
    } on Object catch (e) {
      if (_disposed) return;
      final offline = _isNetwork(e);
      state = state.copyWith(
        loading: false,
        offline: offline,
        error: offline ? null : monitoringErrorText(e),
      );
    } finally {
      _fetching = false;
    }
  }

  /// «Проверить сейчас»: сервер читает движок и возвращает новый снимок.
  /// Повтор раньше чем через 5 секунд и нажатие без связи на сервер не
  /// уходят.
  Future<ActionResult> refreshNow() async {
    if (state.refreshing) return const ActionResult(ActionOutcome.tooSoon);
    if (state.offline) {
      return const ActionResult(
        ActionOutcome.offline,
        'Нет связи с сервером: проверка недоступна.',
      );
    }
    final now = _now();
    final wait = _nextRefreshAt;
    if (wait != null && now.isBefore(wait)) {
      final seconds = wait.difference(now).inSeconds + 1;
      return ActionResult(
        ActionOutcome.tooSoon,
        'Подождите $seconds с: проверять чаще не нужно.',
      );
    }
    state = state.copyWith(refreshing: true);
    try {
      final result = await ref.read(monitoringApiProvider).refresh();
      if (_disposed) return const ActionResult(ActionOutcome.done);
      final at = _now();
      _etag = null;
      _nextRefreshAt = at.add(refreshCooldown);
      await ref.read(pulseCacheProvider).writePulse(raw: result.raw!, asOf: at);
      if (_disposed) return const ActionResult(ActionOutcome.done);
      state = state.copyWith(
        snapshot: result.snapshot,
        asOf: at,
        loading: false,
        offline: false,
        error: null,
        refreshing: false,
      );
      return const ActionResult(ActionOutcome.done);
    } on Object catch (e) {
      if (_disposed) return const ActionResult(ActionOutcome.failed);
      final offline = _isNetwork(e);
      final limited = _isRateLimited(e);
      if (limited) {
        _nextRefreshAt = _now().add(_retryAfter(e) ?? refreshCooldown);
      }
      state = state.copyWith(refreshing: false, offline: offline ? true : null);
      return ActionResult(
        offline
            ? ActionOutcome.offline
            : limited
            ? ActionOutcome.rateLimited
            : ActionOutcome.failed,
        monitoringErrorText(e),
      );
    }
  }
}

final NotifierProvider<PulseController, PulseState> pulseProvider =
    NotifierProvider.autoDispose<PulseController, PulseState>(
      PulseController.new,
    );

// ---------------------------------------------------------------- инциденты

/// Страницы ленты инцидентов: новые первыми, следующая страница — по
/// составному курсору (`before` + `before_id`).
@immutable
class IncidentsState {
  const IncidentsState({
    this.items = const [],
    this.next,
    this.loading = true,
    this.loadingMore = false,
    this.offline = false,
    this.error,
    this.asOf,
  });

  final List<Incident> items;

  /// Курсор следующей страницы; `null` — лента закончилась (или не загружена).
  final IncidentCursor? next;
  final bool loading;
  final bool loadingMore;

  /// Нет связи: показана последняя сохранённая страница.
  final bool offline;
  final String? error;
  final DateTime? asOf;

  bool get hasMore => next != null;

  IncidentsState copyWith({
    List<Incident>? items,
    Object? next = _keep,
    bool? loading,
    bool? loadingMore,
    bool? offline,
    Object? error = _keep,
    Object? asOf = _keep,
  }) => IncidentsState(
    items: items ?? this.items,
    next: identical(next, _keep) ? this.next : next as IncidentCursor?,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    offline: offline ?? this.offline,
    error: identical(error, _keep) ? this.error : error as String?,
    asOf: identical(asOf, _keep) ? this.asOf : asOf as DateTime?,
  );
}

/// Лента инцидентов; семейство по `service_id` (`null` — все сервисы).
class IncidentsController extends Notifier<IncidentsState> {
  IncidentsController(this.serviceId);

  final String? serviceId;
  bool _disposed = false;

  @override
  IncidentsState build() {
    ref.onDispose(() => _disposed = true);
    unawaited(Future<void>(_start));
    return const IncidentsState();
  }

  Future<void> _start() async {
    if (serviceId == null) {
      final cached = await ref.read(pulseCacheProvider).readIncidents();
      if (_disposed) return;
      if (cached != null) {
        state = state.copyWith(
          items: cached.page.incidents,
          next: cached.page.next,
          asOf: cached.asOf,
        );
      }
    }
    await reload();
  }

  /// Загружает первую страницу заново (кэшируется, если нет фильтра).
  Future<void> reload() async {
    state = state.copyWith(loading: state.items.isEmpty, error: null);
    try {
      final page = await ref
          .read(monitoringApiProvider)
          .incidents(serviceId: serviceId);
      if (_disposed) return;
      final now = ref.read(clockProvider)();
      if (serviceId == null) {
        await ref.read(pulseCacheProvider).writeIncidents(page, now);
      }
      if (_disposed) return;
      state = IncidentsState(
        items: page.incidents,
        next: page.next,
        loading: false,
        asOf: now,
      );
    } on Object catch (e) {
      if (_disposed) return;
      final offline = _isNetwork(e);
      state = state.copyWith(
        loading: false,
        offline: offline,
        error: offline ? null : monitoringErrorText(e),
      );
    }
  }

  /// Следующая страница по курсору. Без курсора и во время загрузки — ничего.
  Future<void> loadMore() async {
    final cursor = state.next;
    if (cursor == null || state.loadingMore || state.loading) return;
    state = state.copyWith(loadingMore: true, error: null);
    try {
      final page = await ref
          .read(monitoringApiProvider)
          .incidents(cursor: cursor, serviceId: serviceId);
      if (_disposed) return;
      final known = {for (final i in state.items) i.id};
      state = state.copyWith(
        items: [
          ...state.items,
          for (final i in page.incidents)
            if (!known.contains(i.id)) i,
        ],
        next: page.next,
        loadingMore: false,
        offline: false,
      );
    } on Object catch (e) {
      if (_disposed) return;
      final offline = _isNetwork(e);
      state = state.copyWith(
        loadingMore: false,
        offline: offline,
        error: offline ? null : monitoringErrorText(e),
      );
    }
  }
}

final NotifierProviderFamily<IncidentsController, IncidentsState, String?>
incidentsProvider = NotifierProvider.autoDispose
    .family<IncidentsController, IncidentsState, String?>(
      IncidentsController.new,
    );

// ---------------------------------------------------------------- самопроверка

/// Самопроверка мониторинга: движок, конфигурация, очередь Telegram.
final FutureProvider<SelfCheck> selfCheckProvider =
    FutureProvider.autoDispose<SelfCheck>(
      (ref) => ref.read(monitoringApiProvider).selfCheck(),
      // Повтор — кнопкой «Повторить», а не автоматически.
      retry: (_, _) => null,
    );

/// Кнопка «Отправить тест» Telegram: не чаще раза в 10 секунд, лимит сервера
/// (`rate_limited`) объясняется словами, а не повторяется.
class TelegramTestController extends Notifier<bool> {
  DateTime? _nextAt;
  bool _disposed = false;

  /// `true` — запрос в пути.
  @override
  bool build() {
    ref.onDispose(() => _disposed = true);
    return false;
  }

  Future<ActionResult> send() async {
    if (state) return const ActionResult(ActionOutcome.tooSoon);
    final now = ref.read(clockProvider)();
    final wait = _nextAt;
    if (wait != null && now.isBefore(wait)) {
      final seconds = wait.difference(now).inSeconds + 1;
      return ActionResult(
        ActionOutcome.tooSoon,
        'Подождите $seconds с: тестовое сообщение можно отправлять раз в '
        '${telegramTestCooldown.inSeconds} секунд.',
      );
    }
    state = true;
    _nextAt = now.add(telegramTestCooldown);
    try {
      final result = await ref.read(monitoringApiProvider).telegramTest();
      if (result.ok) return const ActionResult(ActionOutcome.done);
      return ActionResult(
        result.error == 'rate_limited'
            ? ActionOutcome.rateLimited
            : ActionOutcome.failed,
        _telegramMessage(result.error),
      );
    } on Object catch (e) {
      final limited = _isRateLimited(e);
      if (limited) _nextAt = now.add(_retryAfter(e) ?? telegramTestCooldown);
      return ActionResult(
        _isNetwork(e)
            ? ActionOutcome.offline
            : limited
            ? ActionOutcome.rateLimited
            : ActionOutcome.failed,
        monitoringErrorText(e),
      );
    } finally {
      if (!_disposed) state = false;
    }
  }

  String _telegramMessage(String? code) => telegramErrorText(code);
}

final NotifierProvider<TelegramTestController, bool> telegramTestProvider =
    NotifierProvider.autoDispose<TelegramTestController, bool>(
      TelegramTestController.new,
    );
