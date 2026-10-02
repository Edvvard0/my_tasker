import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/local_llm/device_resources.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';
import 'package:my_tasker/core/local_llm/model_catalog.dart';
import 'package:my_tasker/core/local_llm/model_downloader.dart';
import 'package:my_tasker/core/local_llm/network_probe.dart';

/// Фаза модели на устройстве.
enum LocalModelPhase {
  notDownloaded,

  /// Есть недокачанный файл, загрузка не идёт.
  partial,

  /// Ждём Wi-Fi (загрузка запрошена, но сеть платная или её нет).
  waitingForNetwork,
  downloading,

  /// Скачано, считается SHA-256.
  verifying,
  ready,

  /// Последняя попытка закончилась ошибкой ([LocalModelState.failure]).
  failed,
}

/// Причина неудачи.
enum LocalModelFailureKind {
  noNetwork,
  notEnoughSpace,
  notEnoughTotalRam,
  notEnoughAvailableRam,
  shaMismatch,
  sizeMismatch,
  http,
  network,
  disk,
}

@immutable
class LocalModelFailure {
  const LocalModelFailure(this.kind, this.message);

  final LocalModelFailureKind kind;

  /// Текст для показа (по-русски).
  final String message;

  @override
  String toString() => 'LocalModelFailure(${kind.name}): $message';
}

@immutable
class LocalModelState {
  const LocalModelState({
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes,
    this.verifiedBytes = 0,
    this.failure,
    this.sha256,
    this.fileBytes,
  });

  static const LocalModelState absent = LocalModelState(
    phase: LocalModelPhase.notDownloaded,
  );

  final LocalModelPhase phase;
  final int receivedBytes;
  final int? totalBytes;

  /// Сколько байт уже прошло проверку суммы (фаза `verifying`).
  final int verifiedBytes;
  final LocalModelFailure? failure;

  /// Вычисленная SHA-256 готового файла (для закрепления в каталоге).
  final String? sha256;

  /// Размер готового файла на диске.
  final int? fileBytes;

  bool get isReady => phase == LocalModelPhase.ready;

  bool get isBusy =>
      phase == LocalModelPhase.downloading ||
      phase == LocalModelPhase.verifying ||
      phase == LocalModelPhase.waitingForNetwork;

  /// Доля 0..1 для индикатора; `null` — неизвестна.
  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    final done = phase == LocalModelPhase.verifying
        ? verifiedBytes
        : receivedBytes;
    return (done / total).clamp(0, 1).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      other is LocalModelState &&
      other.phase == phase &&
      other.receivedBytes == receivedBytes &&
      other.totalBytes == totalBytes &&
      other.verifiedBytes == verifiedBytes &&
      other.failure?.kind == failure?.kind &&
      other.sha256 == sha256 &&
      other.fileBytes == fileBytes;

  @override
  int get hashCode => Object.hash(
    phase,
    receivedBytes,
    totalBytes,
    verifiedBytes,
    failure?.kind,
    sha256,
    fileBytes,
  );
}

/// Итог проверки «можно ли запускать модель».
@immutable
class LaunchCheck {
  const LaunchCheck.ok() : failure = null;

  const LaunchCheck.blocked(LocalModelFailure this.failure);

  final LocalModelFailure? failure;

  bool get canRun => failure == null;
}

/// Менеджер файлов локальных моделей (решение этапа 10, п. 3): загрузка
/// только по Wi-Fi по умолчанию, продолжение после обрыва (`Range`),
/// проверка SHA-256, хранение в каталоге приложения, удаление, проверки
/// места и ОЗУ.
///
/// Файлы: `<dir>/<fileName>.part` — недокачанное; `<dir>/<fileName>` —
/// готовое; `<dir>/<fileName>.ok` — метка проверки («размер sha256»), без
/// неё готовый файл считается неподтверждённым (повторно 2,6 ГБ при каждом
/// запуске не хешируем).
class LocalModelManager {
  LocalModelManager({
    required this._modelsDir,
    required this._downloader,
    required this._resources,
    required this._network,
    Future<bool> Function()? wifiOnly,
    this._catalog = localModelCatalog,
    this.freeSpaceReserveBytes = 300 * 1024 * 1024,
    this.progressStepBytes = 512 * 1024,
    this.maxAutoRetries = 2,
    this.retryDelay = const Duration(seconds: 3),
    this.isInUse,
  }) : _wifiOnly = wifiOnly ?? (() async => true);

  final Future<Directory> Function() _modelsDir;
  final ModelDownloader _downloader;
  final DeviceResources _resources;
  final NetworkProbe _network;
  final Future<bool> Function() _wifiOnly;
  final List<LocalModelSpec> _catalog;

  /// Запас места сверх размера модели.
  final int freeSpaceReserveBytes;

  /// Как часто (в байтах) обновлять прогресс.
  final int progressStepBytes;

  /// Сколько раз повторять загрузку при обрыве без участия пользователя.
  final int maxAutoRetries;
  final Duration retryDelay;

  /// Модель сейчас загружена в движок: её нельзя удалить.
  final bool Function(String modelId)? isInUse;

  final Map<String, LocalModelState> _states = {};
  final Map<String, _Job> _jobs = {};
  final StreamController<Map<String, LocalModelState>> _changes =
      StreamController<Map<String, LocalModelState>>.broadcast();
  StreamSubscription<NetworkKind>? _networkSub;

  /// Каталог моделей.
  List<LocalModelSpec> get catalog => _catalog;

  LocalModelState stateOf(String id) => _states[id] ?? LocalModelState.absent;

  Map<String, LocalModelState> get snapshot => Map.unmodifiable(_states);

  /// Состояния при каждом изменении (первое значение — через [refresh]).
  Stream<Map<String, LocalModelState>> get states => _changes.stream;

  LocalModelSpec _spec(String id) => _catalog.firstWhere(
    (s) => s.id == id,
    orElse: () => throw ArgumentError.value(id, 'id', 'нет в каталоге'),
  );

  void _set(String id, LocalModelState state) {
    if (_states[id] == state) return;
    _states[id] = state;
    if (!_changes.isClosed) _changes.add(snapshot);
  }

  Future<File> _final(LocalModelSpec spec) async =>
      File('${(await _modelsDir()).path}/${spec.fileName}');
  Future<File> _part(LocalModelSpec spec) async =>
      File('${(await _modelsDir()).path}/${spec.fileName}.part');
  Future<File> _mark(LocalModelSpec spec) async =>
      File('${(await _modelsDir()).path}/${spec.fileName}.ok');

  /// Сканирует диск и обновляет состояния моделей, не занятых загрузкой.
  Future<void> refresh() async {
    for (final spec in _catalog) {
      if (_jobs.containsKey(spec.id)) continue;
      _set(spec.id, await _scan(spec));
    }
    if (!_changes.isClosed) _changes.add(snapshot);
  }

  Future<LocalModelState> _scan(LocalModelSpec spec) async {
    final done = await _final(spec);
    final mark = await _mark(spec);
    if (done.existsSync() && mark.existsSync()) {
      final parts = (await mark.readAsString()).trim().split(' ');
      final size = int.tryParse(parts.first);
      final hash = parts.length > 1 ? parts[1] : null;
      final length = await done.length();
      final pinOk = spec.sha256 == null || spec.sha256 == hash;
      if (size == length && hash != null && pinOk) {
        return LocalModelState(
          phase: LocalModelPhase.ready,
          receivedBytes: length,
          totalBytes: length,
          sha256: hash,
          fileBytes: length,
        );
      }
      // Метка не сходится с файлом: файл нельзя считать проверенным.
      await _deleteQuietly(done);
      await _deleteQuietly(mark);
    } else if (done.existsSync()) {
      await _deleteQuietly(done);
    }
    final part = await _part(spec);
    if (part.existsSync()) {
      final length = await part.length();
      return LocalModelState(
        phase: LocalModelPhase.partial,
        receivedBytes: length,
        totalBytes: spec.sizeBytes,
      );
    }
    return LocalModelState.absent;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Не удалось — повторим при следующем сканировании.
    }
  }

  /// Занятое моделями место на диске, байты (готовые и недокачанные).
  Future<int> usedBytes() async {
    final dir = await _modelsDir();
    if (!dir.existsSync()) return 0;
    var sum = 0;
    for (final entity in dir.listSync()) {
      if (entity is File) sum += entity.lengthSync();
    }
    return sum;
  }

  /// Свободное место на разделе с моделями; `null`, если неизвестно.
  Future<int?> freeBytes() async {
    final dir = await _modelsDir();
    return await _resources.freeDiskBytes(dir.path);
  }

  /// Файл готовой модели для движка; `null`, если модель не готова.
  Future<LlmModelFile?> modelFile(String id) async {
    final spec = _spec(id);
    final state = await _scan(spec);
    if (!state.isReady) return null;
    return LlmModelFile(
      modelId: spec.id,
      path: (await _final(spec)).path,
      contextTokens: spec.contextTokens,
    );
  }

  /// Можно ли сейчас запускать модель: ОЗУ устройства и свободная ОЗУ.
  /// Неизвестные значения не блокируют запуск.
  Future<LaunchCheck> checkCanRun(String id) async {
    final spec = _spec(id);
    final total = await _resources.totalRamBytes();
    if (total != null && total < spec.minTotalRamBytes) {
      return LaunchCheck.blocked(
        LocalModelFailure(
          LocalModelFailureKind.notEnoughTotalRam,
          'Нужно не меньше ${formatBytes(spec.minTotalRamBytes)} ОЗУ, '
          'на устройстве ${formatBytes(total)}',
        ),
      );
    }
    final available = await _resources.availableRamBytes();
    if (available != null && available < spec.minAvailableRamBytes) {
      return LaunchCheck.blocked(
        LocalModelFailure(
          LocalModelFailureKind.notEnoughAvailableRam,
          'Свободно ${formatBytes(available)} ОЗУ, нужно '
          '${formatBytes(spec.minAvailableRamBytes)}. Закройте другие '
          'приложения и повторите',
        ),
      );
    }
    return const LaunchCheck.ok();
  }

  /// Запускает (или продолжает) загрузку. Возвращается сразу после старта;
  /// ход — через [states]. [allowCellular] разрешает один раз качать по
  /// мобильной сети, не меняя настройку «только Wi-Fi».
  Future<void> start(String id, {bool allowCellular = false}) async {
    final spec = _spec(id);
    if (_jobs.containsKey(id)) return;
    if (stateOf(id).isReady) return;
    final job = _Job(allowCellular: allowCellular);
    job.policy = (kind) => _allowed(job, kind);
    _jobs[id] = job;
    _watchNetwork();
    job.done = _run(spec, job).whenComplete(() {
      _jobs.remove(id);
      if (_jobs.isEmpty) {
        unawaited(_networkSub?.cancel());
        _networkSub = null;
      }
    });
    // Предварительные проверки отработают до первого await внутри _run,
    // но состояние выставит сам цикл.
    await Future<void>.value();
  }

  /// Ждёт окончания загрузки модели (для тестов и сценариев «скачать и
  /// запустить»).
  Future<void> whenIdle(String id) async {
    while (_jobs.containsKey(id)) {
      await _jobs[id]!.done;
    }
  }

  void _watchNetwork() {
    _networkSub ??= _network.changes.listen((kind) {
      for (final job in _jobs.values) {
        job.onNetwork(kind);
      }
    });
  }

  Future<bool> _allowed(_Job job, NetworkKind kind) async {
    if (!kind.isOnline) return false;
    if (job.allowCellular) return true;
    if (!await _wifiOnly()) return true;
    return kind.isUnmetered;
  }

  Future<void> _run(LocalModelSpec spec, _Job job) async {
    var attempt = 0;
    try {
      while (true) {
        if (job.stopped) return;
        // 1. Сеть и политика Wi-Fi.
        final kind = await _network.current();
        if (!await _allowed(job, kind)) {
          if (!kind.isOnline) {
            _fail(
              spec.id,
              const LocalModelFailure(
                LocalModelFailureKind.noNetwork,
                'Нет сети. Загрузка продолжится с того же места',
              ),
            );
            return;
          }
          _set(spec.id, await _withPartial(spec, waiting: true));
          final resumed = await job.waitForNetwork(_network.current);
          if (!resumed) {
            _set(spec.id, await _scan(spec));
            return;
          }
          continue;
        }

        // 2. Место на диске: нужно докачать остаток + запас.
        final part = await _part(spec);
        final have = part.existsSync() ? await part.length() : 0;
        final free = await _resources.freeDiskBytes((await _modelsDir()).path);
        final need = spec.sizeBytes - have + freeSpaceReserveBytes;
        if (free != null && free < need) {
          _fail(
            spec.id,
            LocalModelFailure(
              LocalModelFailureKind.notEnoughSpace,
              'Не хватает места: нужно ${formatBytes(need)}, '
              'свободно ${formatBytes(free)}',
            ),
          );
          return;
        }

        // 3. Загрузка.
        final result = await _download(spec, job, part, have);
        if (result is _StepStopped) {
          _set(spec.id, await _scan(spec));
          return;
        }
        if (result is _StepNetworkChanged) continue;
        if (result is _StepFailed) {
          if (result.failure.kind == LocalModelFailureKind.network &&
              attempt < maxAutoRetries) {
            attempt++;
            await Future<void>.delayed(retryDelay);
            continue;
          }
          _fail(spec.id, result.failure);
          return;
        }
        // 4. Проверка и публикация.
        await _finish(spec, part, (result as _StepDone).totalBytes);
        return;
      }
    } on Object catch (e) {
      _fail(
        spec.id,
        LocalModelFailure(LocalModelFailureKind.disk, 'Ошибка: $e'),
      );
    }
  }

  Future<LocalModelState> _withPartial(
    LocalModelSpec spec, {
    required bool waiting,
  }) async {
    final part = await _part(spec);
    final have = part.existsSync() ? await part.length() : 0;
    return LocalModelState(
      phase: waiting
          ? LocalModelPhase.waitingForNetwork
          : LocalModelPhase.partial,
      receivedBytes: have,
      totalBytes: spec.sizeBytes,
    );
  }

  Future<_Step> _download(
    LocalModelSpec spec,
    _Job job,
    File part,
    int have,
  ) async {
    var lastEmitted = have;
    _set(
      spec.id,
      LocalModelState(
        phase: LocalModelPhase.downloading,
        receivedBytes: have,
        totalBytes: spec.sizeBytes,
      ),
    );
    final cancel = DownloadCancelToken();
    job.cancelCurrent = cancel.cancel;
    try {
      final outcome = await _downloader.download(
        url: Uri.parse(spec.url),
        file: part,
        resumeFrom: have,
        cancel: cancel,
        onProgress: (received, total) {
          if (received - lastEmitted < progressStepBytes &&
              received != (total ?? -1)) {
            return;
          }
          lastEmitted = received;
          _set(
            spec.id,
            LocalModelState(
              phase: LocalModelPhase.downloading,
              receivedBytes: received,
              totalBytes: total ?? spec.sizeBytes,
            ),
          );
        },
      );
      return _StepDone(outcome.totalBytes);
    } on DownloadFailure catch (e) {
      if (job.stopped) return const _StepStopped();
      if (job.networkDropped) {
        job.networkDropped = false;
        return const _StepNetworkChanged();
      }
      return _StepFailed(
        LocalModelFailure(switch (e.kind) {
          DownloadFailureKind.network => LocalModelFailureKind.network,
          DownloadFailureKind.http => LocalModelFailureKind.http,
          DownloadFailureKind.disk => LocalModelFailureKind.disk,
        }, e.message),
      );
    } finally {
      job.cancelCurrent = null;
    }
  }

  Future<void> _finish(LocalModelSpec spec, File part, int serverTotal) async {
    final length = await part.length();
    final expected = spec.sizeIsExact ? spec.sizeBytes : serverTotal;
    if (length != expected) {
      await _deleteQuietly(part);
      _fail(
        spec.id,
        LocalModelFailure(
          LocalModelFailureKind.sizeMismatch,
          'Размер файла ${formatBytes(length)} не совпал с ожидаемым '
          '${formatBytes(expected)}. Файл удалён, загрузите заново',
        ),
      );
      return;
    }
    _set(
      spec.id,
      LocalModelState(
        phase: LocalModelPhase.verifying,
        receivedBytes: length,
        totalBytes: length,
      ),
    );
    final hash = await sha256OfFile(
      part,
      onProgress: (done) {
        _set(
          spec.id,
          LocalModelState(
            phase: LocalModelPhase.verifying,
            receivedBytes: length,
            totalBytes: length,
            verifiedBytes: done,
          ),
        );
      },
    );
    final pinned = spec.sha256;
    if (pinned != null && pinned != hash) {
      await _deleteQuietly(part);
      _fail(
        spec.id,
        const LocalModelFailure(
          LocalModelFailureKind.shaMismatch,
          'Контрольная сумма не совпала: файл повреждён или подменён. '
          'Файл удалён, загрузите заново',
        ),
      );
      return;
    }
    final done = await _final(spec);
    await _deleteQuietly(done);
    await part.rename(done.path);
    await (await _mark(spec)).writeAsString('$length $hash');
    _set(
      spec.id,
      LocalModelState(
        phase: LocalModelPhase.ready,
        receivedBytes: length,
        totalBytes: length,
        sha256: hash,
        fileBytes: length,
      ),
    );
  }

  void _fail(String id, LocalModelFailure failure) {
    final old = stateOf(id);
    _set(
      id,
      LocalModelState(
        phase: LocalModelPhase.failed,
        receivedBytes: old.receivedBytes,
        totalBytes: old.totalBytes,
        failure: failure,
      ),
    );
  }

  /// Ставит загрузку на паузу: недокачанный файл остаётся, [start]
  /// продолжит с него.
  Future<void> pause(String id) async {
    final job = _jobs[id];
    if (job == null) return;
    job.stop();
    await job.done;
  }

  /// Удаляет недокачанный файл (освобождает место).
  Future<void> discardPartial(String id) async {
    await pause(id);
    final spec = _spec(id);
    await _deleteQuietly(await _part(spec));
    _set(id, await _scan(spec));
  }

  /// Удаляет модель целиком. Нельзя, пока она загружена в движок.
  Future<void> delete(String id) async {
    final spec = _spec(id);
    if (isInUse?.call(id) ?? false) {
      throw StateError('Модель сейчас используется: сначала выгрузите её');
    }
    await pause(id);
    await _deleteQuietly(await _final(spec));
    await _deleteQuietly(await _mark(spec));
    await _deleteQuietly(await _part(spec));
    _set(id, LocalModelState.absent);
  }

  Future<void> dispose() async {
    for (final job in _jobs.values.toList()) {
      job.stop();
    }
    for (final job in _jobs.values.toList()) {
      await job.done;
    }
    await _networkSub?.cancel();
    await _changes.close();
  }
}

/// SHA-256 файла потоком (не загружая его в память); [onProgress] получает
/// число обработанных байт.
Future<String> sha256OfFile(
  File file, {
  void Function(int doneBytes)? onProgress,
}) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  var done = 0;
  var lastReport = 0;
  await for (final chunk in file.openRead()) {
    input.add(chunk);
    done += chunk.length;
    if (onProgress != null && done - lastReport >= 8 * 1024 * 1024) {
      lastReport = done;
      onProgress(done);
    }
  }
  input.close();
  onProgress?.call(done);
  return sink.value.toString();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

sealed class _Step;

final class _StepStopped implements _Step {
  const _StepStopped();
}

final class _StepNetworkChanged implements _Step {
  const _StepNetworkChanged();
}

final class _StepDone implements _Step {
  const _StepDone(this.totalBytes);

  final int totalBytes;
}

final class _StepFailed implements _Step {
  const _StepFailed(this.failure);

  final LocalModelFailure failure;
}

/// Одна запущенная загрузка.
class _Job {
  _Job({required this.allowCellular});

  final bool allowCellular;
  bool stopped = false;
  bool networkDropped = false;
  void Function()? cancelCurrent;
  Future<void> done = Future<void>.value();

  /// Подходит ли сеть по политике «только Wi-Fi».
  late Future<bool> Function(NetworkKind) policy;

  Completer<bool>? _waiting;

  void stop() {
    stopped = true;
    cancelCurrent?.call();
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) waiting.complete(false);
  }

  /// Сеть сменилась: во время ожидания — возобновить, во время загрузки —
  /// прервать, если новая сеть не подходит.
  void onNetwork(NetworkKind kind) {
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) {
      unawaited(
        policy(kind).then((ok) {
          if (ok && !waiting.isCompleted) waiting.complete(true);
        }),
      );
      return;
    }
    if (cancelCurrent != null && !stopped) {
      unawaited(
        policy(kind).then((ok) {
          if (!ok && cancelCurrent != null) {
            networkDropped = true;
            cancelCurrent!.call();
          }
        }),
      );
    }
  }

  /// Ждёт сеть, подходящую по политике; `false`, если загрузку остановили.
  Future<bool> waitForNetwork(Future<NetworkKind> Function() probe) {
    final completer = Completer<bool>();
    _waiting = completer;
    if (stopped) completer.complete(false);
    // Сеть могла смениться, пока мы готовились ждать: проверяем ещё раз.
    unawaited(
      probe().then((kind) async {
        if (!completer.isCompleted && await policy(kind)) {
          completer.complete(true);
        }
      }),
    );
    return completer.future.whenComplete(() => _waiting = null);
  }
}
