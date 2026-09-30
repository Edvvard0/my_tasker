import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/async/async_mutex.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/server_epoch.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_remote.dart';
import 'package:my_tasker/core/sync/sync_store.dart';

/// Чем занят движок.
enum SyncPhase { idle, syncing, resyncing }

/// Итог цикла.
enum SyncOutcome {
  success,

  /// Нет сети (в том числе обрыв посреди обмена).
  offline,

  /// Ошибка сервера или протокола; цикл прерван.
  failed,

  /// Сервер требует более новую версию приложения (`426`).
  blockedOldClient,

  /// Слишком частые запросы (`429`): пауза.
  rateLimited,

  /// Нужен вход.
  authRequired,

  /// Адрес сервера не настроен.
  notConfigured,
}

/// Причина последней неудачи (для индикатора и экрана «Синхронизация»).
enum SyncFailureKind {
  offline,
  server,
  protocol,
  rateLimited,
  clientTooOld,
  authRequired,
  notConfigured,
  unknown,
}

/// Неудача цикла: только тип и безопасный текст (без тел запросов).
@immutable
class SyncFailure {
  const SyncFailure(this.kind, this.message, this.at);

  final SyncFailureKind kind;
  final String message;
  final DateTime at;
}

/// Состояние движка синхронизации.
@immutable
class SyncRunState {
  const SyncRunState({
    this.phase = SyncPhase.idle,
    this.failure,
    this.blockedMinSchema,
    this.pausedUntil,
    this.clockSkew = false,
    this.pulledRows = 0,
    this.lastPushAt,
    this.lastPullAt,
    this.lastSuccessAt,
  });

  final SyncPhase phase;
  final SyncFailure? failure;

  /// Сервер требует схему клиента не ниже этой (`426`); `null` — нет.
  final int? blockedMinSchema;

  /// После `429`: до какого времени не обращаться к серверу.
  final DateTime? pausedUntil;

  /// Сервер отклонил метки времени как «из будущего» (`hlc_in_future`).
  final bool clockSkew;

  /// Сколько строк применено в текущем цикле (прогресс первой загрузки).
  final int pulledRows;

  final DateTime? lastPushAt;
  final DateTime? lastPullAt;
  final DateTime? lastSuccessAt;

  bool get isBusy => phase != SyncPhase.idle;
  bool get isBlocked => blockedMinSchema != null;

  SyncRunState copyWith({
    SyncPhase? phase,
    SyncFailure? failure,
    bool clearFailure = false,
    int? blockedMinSchema,
    bool clearBlocked = false,
    DateTime? pausedUntil,
    bool clearPause = false,
    bool? clockSkew,
    int? pulledRows,
    DateTime? lastPushAt,
    DateTime? lastPullAt,
    DateTime? lastSuccessAt,
  }) => SyncRunState(
    phase: phase ?? this.phase,
    failure: clearFailure ? null : (failure ?? this.failure),
    blockedMinSchema: clearBlocked
        ? null
        : (blockedMinSchema ?? this.blockedMinSchema),
    pausedUntil: clearPause ? null : (pausedUntil ?? this.pausedUntil),
    clockSkew: clockSkew ?? this.clockSkew,
    pulledRows: pulledRows ?? this.pulledRows,
    lastPushAt: lastPushAt ?? this.lastPushAt,
    lastPullAt: lastPullAt ?? this.lastPullAt,
    lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
  );
}

/// Движок синхронизации: цикл push -> pull, полная пересинхронизация
/// (spec 5.2, 5.3). Один цикл за раз (mutex); параллельные вызовы
/// `runCycle` присоединяются к уже идущему циклу.
class SyncEngine {
  SyncEngine({
    required this.store,
    required this.remote,
    required this.clientSchemaVersion,
    DateTime Function()? clock,
    this.pushBatchSize = SyncLimits.pushBatchMax,
    this.pullPageSize = SyncLimits.pullPageMax,
    this.maxRounds = 10,
    this.defaultPause = const Duration(seconds: 60),
  }) : assert(
         pushBatchSize > 0 && pushBatchSize <= SyncLimits.pushBatchMax,
         'пачка push: 1..${SyncLimits.pushBatchMax}',
       ),
       assert(
         pullPageSize > 0 && pullPageSize <= SyncLimits.pullPageMax,
         'страница pull: 1..${SyncLimits.pullPageMax}',
       ),
       _clock = clock ?? DateTime.now;

  final SyncStore store;
  final SyncRemote remote;

  /// Версия схемы клиента (`X-Client-Schema-Version`).
  final int clientSchemaVersion;
  final int pushBatchSize;
  final int pullPageSize;

  /// Предел повторов «push -> pull», пока в очереди появляются новые
  /// операции (правки во время цикла).
  final int maxRounds;

  /// Пауза после `429` без `Retry-After`.
  final Duration defaultPause;
  final DateTime Function() _clock;

  final AsyncMutex _mutex = AsyncMutex();
  final StreamController<SyncRunState> _changes =
      StreamController<SyncRunState>.broadcast();
  Future<SyncOutcome>? _running;
  SyncRunState _state = const SyncRunState();

  SyncRunState get state => _state;
  Stream<SyncRunState> get changes => _changes.stream;

  void _set(SyncRunState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  /// Загружает сохранённое состояние (время обменов, блокировку `426`) и
  /// проверяет набор зарегистрированных таблиц.
  Future<void> init() async {
    await store.reconcileKnownTables();
    final blocked = await store.blockedMinSchema();
    if (blocked != null && blocked <= clientSchemaVersion) {
      await store.setBlockedMinSchema(null); // приложение уже обновили
    }
    _set(
      _state.copyWith(
        lastPushAt: await store.lastPushAt(),
        lastPullAt: await store.lastPullAt(),
        lastSuccessAt: await store.lastSuccessAt(),
        blockedMinSchema: blocked != null && blocked > clientSchemaVersion
            ? blocked
            : null,
        clearBlocked: blocked == null || blocked <= clientSchemaVersion,
      ),
    );
  }

  /// Один цикл синхронизации: push, затем pull (и повтор, если во время
  /// цикла появились новые правки).
  Future<SyncOutcome> runCycle() =>
      _running ??= _mutex.protect(() => _guarded(_cycle)).whenComplete(() {
        _running = null;
      });

  /// Полная пересинхронизация (spec 5.3): outbox сохраняется, всё
  /// остальное перезагружается с сервера.
  Future<SyncOutcome> fullResync() =>
      _mutex.protect(() => _guarded(_resyncBody));

  Future<SyncOutcome> _guarded(Future<SyncOutcome> Function() body) async {
    final blocked = _state.blockedMinSchema;
    if (blocked != null) {
      if (clientSchemaVersion >= blocked) {
        await store.setBlockedMinSchema(null);
        _set(_state.copyWith(clearBlocked: true));
      } else {
        return SyncOutcome.blockedOldClient;
      }
    }
    final pausedUntil = _state.pausedUntil;
    if (pausedUntil != null) {
      if (_clock().isBefore(pausedUntil)) return SyncOutcome.rateLimited;
      _set(_state.copyWith(clearPause: true));
    }
    _set(_state.copyWith(phase: SyncPhase.syncing, pulledRows: 0));
    try {
      final outcome = await body();
      _set(_state.copyWith(phase: SyncPhase.idle));
      return outcome;
    } on ApiException catch (e) {
      return await _fail(e);
    } on Object catch (e) {
      _set(
        _state.copyWith(
          phase: SyncPhase.idle,
          failure: SyncFailure(
            SyncFailureKind.unknown,
            e.runtimeType.toString(),
            _clock(),
          ),
        ),
      );
      return SyncOutcome.failed;
    }
  }

  Future<SyncOutcome> _fail(ApiException e) async {
    var outcome = SyncOutcome.failed;
    var kind = SyncFailureKind.protocol;
    if (e.kind == ApiErrorKind.notConfigured) {
      outcome = SyncOutcome.notConfigured;
      kind = SyncFailureKind.notConfigured;
    } else if (e.isNetwork) {
      outcome = SyncOutcome.offline;
      kind = SyncFailureKind.offline;
    } else if (e.status == 401) {
      outcome = SyncOutcome.authRequired;
      kind = SyncFailureKind.authRequired;
    } else if (e.status == 426 || e.code == 'client_too_old') {
      final min = e.details['min_client_schema_version'];
      final required = min is int ? min : clientSchemaVersion + 1;
      await store.setBlockedMinSchema(required);
      _set(_state.copyWith(blockedMinSchema: required));
      outcome = SyncOutcome.blockedOldClient;
      kind = SyncFailureKind.clientTooOld;
    } else if (e.status == 429 || e.code == 'too_many_attempts') {
      _set(
        _state.copyWith(
          pausedUntil: _clock().add(e.retryAfter ?? defaultPause),
        ),
      );
      outcome = SyncOutcome.rateLimited;
      kind = SyncFailureKind.rateLimited;
    } else if (e.isServerError) {
      kind = SyncFailureKind.server;
    }
    _set(
      _state.copyWith(
        phase: SyncPhase.idle,
        failure: SyncFailure(kind, _describe(e), _clock()),
      ),
    );
    return outcome;
  }

  String _describe(ApiException e) =>
      [e.kind.name, if (e.status != null) '${e.status}', ?e.code].join(' ');

  Future<SyncOutcome> _cycle() async {
    final deferred = <String>{};
    var rounds = 0;
    do {
      await _push(deferred);
      if (await store.needsResync()) {
        await _resync();
      } else {
        await _pull();
      }
      rounds++;
    } while (rounds < maxRounds && await store.hasUnsent(exclude: deferred));
    await store.purgeOldTombstones();
    await _success();
    return SyncOutcome.success;
  }

  Future<SyncOutcome> _resyncBody() async {
    await _push(<String>{});
    await _resync();
    await store.purgeOldTombstones();
    await _success();
    return SyncOutcome.success;
  }

  Future<void> _success() async {
    await store.markSuccess();
    _set(_state.copyWith(clearFailure: true, lastSuccessAt: _clock()));
  }

  /// Push: пачки ≤ [pushBatchSize] в порядке создания. Обрыв оставляет
  /// операции `in_flight` с теми же `op_id`: повтор безопасен (сервер
  /// вернёт `duplicate`), pull не выполняется.
  Future<void> _push(Set<String> deferred) async {
    var skew = false;
    while (true) {
      final batch = await store.takeBatch(
        max: pushBatchSize,
        exclude: deferred,
      );
      if (batch.isEmpty) break;
      final response = await remote.push([for (final op in batch) op.toWire()]);
      final held = await store.applyPushResults(batch, response.results);
      deferred.addAll(held);
      // Смена эпохи ставит флаг: после отправки очереди — полная
      // пересинхронизация (outbox сохраняется).
      await store.observeEpoch(response.serverEpoch);
      skew =
          skew ||
          response.results.any((r) => !r.applied && r.code == 'hlc_in_future');
      await store.markPush();
      _set(_state.copyWith(lastPushAt: _clock()));
    }
    _set(_state.copyWith(clockSkew: skew));
  }

  /// Pull страницами; курсор двигается вместе с применением страницы.
  /// `410 resync_required` запускает полную пересинхронизацию.
  Future<void> _pull() async {
    var since = await store.cursor();
    while (true) {
      final PullPage page;
      try {
        page = await remote.pull(since: since, limit: pullPageSize);
      } on ApiException catch (e) {
        if (e.code == 'resync_required') {
          await _resync();
          return;
        }
        rethrow;
      }
      if (await _epochChanged(page.serverEpoch)) {
        await _resync();
        return;
      }
      final applied = await store.applyPage(page.changes, page.nextSince);
      await store.markPull();
      _set(
        _state.copyWith(
          lastPullAt: _clock(),
          pulledRows: _state.pulledRows + applied,
        ),
      );
      if (!page.hasMore) return;
      if (page.nextSince <= since) {
        throw const ApiException(kind: ApiErrorKind.malformed);
      }
      since = page.nextSince;
    }
  }

  /// Эпоха сервера сменилась (сервер восстановили из копии). Первая
  /// встреченная эпоха запоминается.
  Future<bool> _epochChanged(String? epoch) async =>
      await store.observeEpoch(epoch) == EpochAction.fullResync;

  /// Тянет все страницы с `since = 0` в память, затем одной транзакцией
  /// заменяет локальные строки (spec 5.3).
  Future<void> _resync() async {
    _set(_state.copyWith(phase: SyncPhase.resyncing, pulledRows: 0));
    final staged = <SyncChange>[];
    var since = 0;
    String? epoch;
    while (true) {
      final page = await remote.pull(since: since, limit: pullPageSize);
      epoch = page.serverEpoch ?? epoch;
      staged.addAll(page.changes);
      _set(_state.copyWith(pulledRows: staged.length));
      if (!page.hasMore) {
        since = page.nextSince;
        break;
      }
      if (page.nextSince <= since) {
        throw const ApiException(kind: ApiErrorKind.malformed);
      }
      since = page.nextSince;
    }
    await store.replaceAll(staged, since, epoch: epoch);
    await store.markPull();
    _set(_state.copyWith(phase: SyncPhase.syncing, lastPullAt: _clock()));
  }

  /// Освобождает ресурсы.
  Future<void> dispose() => _changes.close();
}
