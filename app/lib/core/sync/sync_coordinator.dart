import 'dart:async';

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

  /// Период фонового таймера, пока приложение запущено.
  final Duration interval;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _debounceTimer;
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
          if (regained) unawaited(syncNow());
        }),
      )
      ..add(sse.signals.listen(_onSignal));
    _periodic = Timer.periodic(interval, (_) => unawaited(syncNow()));
    sse.start();
    unawaited(background.register());
    unawaited(syncNow());
  }

  /// Останавливает всё (выход из аккаунта, закрытие приложения).
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _debounceTimer?.cancel();
    _periodic?.cancel();
    _debounceTimer = null;
    _periodic = null;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await sse.stop();
    await background.cancel();
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
    _debounceTimer = Timer(debounce, () => unawaited(syncNow()));
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
