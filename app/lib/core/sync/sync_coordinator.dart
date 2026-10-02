import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:my_tasker/core/sync/background_sync.dart';
import 'package:my_tasker/core/sync/connectivity_monitor.dart';
import 'package:my_tasker/core/sync/sse_client.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_store.dart';

/// Запускает циклы синхронизации по событиям (spec 5.2): старт, появление
/// сети, 2–5 с после локальной правки, сигнал SSE, периодический таймер.
/// Циклы не накладываются: запрос во время цикла ставит один повтор.
class SyncCoordinator {
  SyncCoordinator({
    required this.engine,
    required this.store,
    required this.connectivity,
    required this.sse,
    this.background = const NoBackgroundSync(),
    this.onRevoked,
    this.debounce = const Duration(seconds: 3),
    this.interval = const Duration(minutes: 5),
    this.maxDebounceWait = const Duration(seconds: 10),
    this.foregroundBeat = const Duration(seconds: 30),
  });

  final SyncEngine engine;
  final SyncStore store;
  final ConnectivityMonitor connectivity;
  final SseClient sse;
  final BackgroundSync background;

  /// Сервер сообщил об отзыве устройства (`revoked` в SSE).
  final Future<void> Function()? onRevoked;

  /// Задержка после последней локальной правки (2–5 с по spec).
  final Duration debounce;

  /// Предел ожидания при непрерывных правках: debounce сдвигается каждой
  /// правкой, но цикл стартует не позже чем через это время после первой
  /// (иначе при долгом наборе данные не уходили бы вовсе).
  final Duration maxDebounceWait;

  /// Как часто приложение на переднем плане обновляет отметку в БД
  /// ([SyncStore.markForeground]); фоновая задача WorkManager по ней
  /// решает, что интерфейс уже синхронизируется сам.
  final Duration foregroundBeat;

  /// Период фонового таймера, пока приложение запущено.
  final Duration interval;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _debounceTimer;
  Timer? _maxWaitTimer;
  Timer? _beat;
  bool _foreground = true;
  Timer? _periodic;
  Future<SyncOutcome>? _current;
  bool _again = false;
  bool _online = true;
  bool _started = false;

  bool get isStarted => _started;

  /// Запускает слежение и первый цикл.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await engine.init();
    _online = await connectivity.isOnline();
    _subscriptions
      ..add(store.localWrites.listen((_) => scheduleSync()))
      ..add(
        connectivity.onlineChanges.listen((online) {
          final regained = online && !_online;
          _online = online;
          if (regained) {
            sse.nudge(); // не ждать остатка backoff SSE
            unawaited(syncNow());
          }
        }),
      )
      ..add(sse.signals.listen(_onSignal));
    _periodic = Timer.periodic(interval, (_) => unawaited(syncNow()));
    sse.start();
    if (_foreground) _startBeat();
    unawaited(background.register());
    unawaited(syncNow());
  }

  /// Останавливает всё (выход из аккаунта, закрытие приложения) и дожидается
  /// идущего цикла: после возврата движок не пишет в БД и не ходит в сеть.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _cancelDebounce();
    _periodic?.cancel();
    _beat?.cancel();
    _periodic = null;
    _beat = null;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await sse.stop();
    await background.cancel();
    try {
      await _current;
    } on Object {
      // Сбой цикла уже отражён в состоянии движка.
    }
    await _safe(store.clearForeground());
  }

  /// Состояние приложения изменилось (`WidgetsBindingObserver`). Возврат на
  /// передний план запускает цикл (за время в фоне сервер мог измениться, а
  /// SSE в фоне засыпает) и обновляет отметку «на переднем плане»; уход в
  /// фон снимает её, чтобы WorkManager мог работать.
  Future<void> onLifecycle(AppLifecycleState state) async {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (!_started) return;
    if (foreground) {
      _startBeat();
      sse.nudge();
      unawaited(syncNow());
    } else {
      _beat?.cancel();
      _beat = null;
      await _safe(store.clearForeground());
    }
  }

  void _startBeat() {
    _beat?.cancel();
    unawaited(_safe(store.markForeground()));
    _beat = Timer.periodic(
      foregroundBeat,
      (_) => unawaited(_safe(store.markForeground())),
    );
  }

  /// Отметка «на переднем плане» вспомогательна: сбой записи (БД уже
  /// закрыта при выходе) не должен ронять приложение.
  Future<void> _safe(Future<void> action) async {
    try {
      await action;
    } on Object {
      // Не критично.
    }
  }

  /// Цикл сейчас; если уже идёт — дожидается его и ставит один повтор.
  Future<SyncOutcome> syncNow() {
    final running = _current;
    if (running != null) {
      _again = true;
      return running;
    }
    return _current = _loop();
  }

  Future<SyncOutcome> _loop() async {
    try {
      var outcome = await engine.runCycle();
      while (_again && _started) {
        _again = false;
        outcome = await engine.runCycle();
      }
      return outcome;
    } finally {
      _again = false;
      _current = null;
    }
  }

  /// Цикл через [debounce] после последнего вызова.
  void scheduleSync() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _fire);
    _maxWaitTimer ??= Timer(maxDebounceWait, _fire);
  }

  void _fire() {
    _cancelDebounce();
    unawaited(syncNow());
  }

  void _cancelDebounce() {
    _debounceTimer?.cancel();
    _maxWaitTimer?.cancel();
    _debounceTimer = null;
    _maxWaitTimer = null;
  }

  Future<void> _onSignal(SseSignal signal) async {
    switch (signal.kind) {
      case SseSignalKind.revoked:
        await onRevoked?.call();
      case SseSignalKind.hello || SseSignalKind.changes:
        final head = signal.headVersion;
        if (head != null && head > await store.cursor()) {
          unawaited(syncNow());
        }
    }
  }
}
