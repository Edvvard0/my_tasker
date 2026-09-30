import 'dart:collection';
import 'dart:math';

import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_remote.dart';

import 'fake_sync_server.dart';

/// Что случится с очередным запросом.
enum Fault {
  none,

  /// Запрос не дошёл до сервера.
  dropRequest,

  /// Сервер обработал запрос, ответ потерялся.
  dropResponse,
}

/// Сценарий отказов сети: сначала очередь [scripted], затем случайные
/// отказы с вероятностями [pDropRequest] / [pDropResponse].
class FaultPlan {
  FaultPlan({this.random, this.pDropRequest = 0, this.pDropResponse = 0});

  final Random? random;
  final double pDropRequest;
  final double pDropResponse;
  final Queue<Fault> scripted = Queue<Fault>();

  /// Полностью без сети: каждый запрос не доходит.
  bool offline = false;

  int requests = 0;

  Fault next() {
    requests++;
    if (offline) return Fault.dropRequest;
    if (scripted.isNotEmpty) return scripted.removeFirst();
    final rng = random;
    if (rng == null) return Fault.none;
    final r = rng.nextDouble();
    if (r < pDropRequest) return Fault.dropRequest;
    if (r < pDropRequest + pDropResponse) return Fault.dropResponse;
    return Fault.none;
  }
}

/// [SyncRemote] устройства напрямую поверх [FakeSyncServer] с отказами
/// сети из [FaultPlan] (без HTTP: быстрые property-тесты).
class DirectRemote implements SyncRemote {
  DirectRemote(this.server, this.deviceId, {FaultPlan? faults})
    : faults = faults ?? FaultPlan();

  final FakeSyncServer server;
  final String deviceId;
  final FaultPlan faults;

  T _call<T>(T Function() action) {
    final fault = faults.next();
    if (fault == Fault.dropRequest) throw const ApiException.network('drop');
    final result = action();
    if (fault == Fault.dropResponse) throw const ApiException.network('lost');
    return result;
  }

  @override
  Future<PushResponse> push(List<Json> ops) => Future.sync(
    () => _call(
      () => PushResponse.fromJson(server.push(deviceId, deepCopy(ops))),
    ),
  );

  @override
  Future<PullPage> pull({required int since, required int limit}) =>
      Future.sync(
        () =>
            _call(() => PullPage.fromJson(server.pull(deviceId, since, limit))),
      );

  @override
  Future<ConflictsPage> conflicts({
    String reverted = 'all',
    int limit = 50,
    String? before,
  }) => Future.sync(
    () => _call(
      () => ConflictsPage.fromJson(
        server.conflictsPage(reverted: reverted, limit: limit, before: before),
      ),
    ),
  );

  @override
  Future<RevertResult> revert(String conflictId) => Future.sync(
    () =>
        _call(() => RevertResult.fromJson(server.revert(deviceId, conflictId))),
  );
}
