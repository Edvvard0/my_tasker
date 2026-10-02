import 'dart:async';
import 'dart:io';

import 'package:my_tasker/core/local_llm/device_resources.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';
import 'package:my_tasker/core/local_llm/model_downloader.dart';
import 'package:my_tasker/core/local_llm/network_probe.dart';

/// Сценарий ответа поддельного движка: детерминированный поток токенов.
class FakeReply {
  /// Обычный ответ: токены по порядку.
  FakeReply(
    this.tokens, {
    this.failAfter,
    this.failWith,
    this.holdAfter,
    this.stats,
  });

  /// Мусорный JSON: ответ, оборванный на середине.
  FakeReply.truncatedJson()
    : this(['{"tool":"create_task","argu', 'ments":{"title":"Куп']);

  /// Корректный вызов `create_task`.
  factory FakeReply.task(Map<String, Object?> arguments, {String lead = ''}) {
    final json = '{"tool":"create_task","arguments":${_encode(arguments)}}';
    return FakeReply([if (lead.isNotEmpty) '$lead\n', json]);
  }

  final List<String> tokens;

  /// Бросить [failWith] после стольких токенов.
  final int? failAfter;
  final Object? failWith;

  /// Остановиться после стольких токенов и ждать [FakeLlmEngine.release]
  /// (медленный первый токен / «зависший» ответ для проверки отмены).
  final int? holdAfter;
  final LlmRuntimeStats? stats;

  static String _encode(Map<String, Object?> value) {
    final buffer = StringBuffer('{');
    var first = true;
    value.forEach((k, v) {
      if (!first) buffer.write(',');
      first = false;
      buffer.write('"$k":${_json(v)}');
    });
    buffer.write('}');
    return buffer.toString();
  }

  static String _json(Object? v) {
    if (v is String) return '"${v.replaceAll('"', r'\"')}"';
    if (v is List) return '[${v.map(_json).join(',')}]';
    return '$v';
  }
}

/// Поддельный движок: очередь заготовленных ответов, запись запросов.
class FakeLlmEngine implements LocalLlmEngine {
  FakeLlmEngine({this.supported = true});

  final bool supported;
  final List<FakeReply> replies = [];
  final List<List<LlmTurn>> requests = [];
  final List<LlmGenerationParams> paramsSeen = [];
  int loads = 0;
  int unloads = 0;
  int cancels = 0;
  Object? loadError;
  LlmModelInfo? _info;
  LlmRuntimeStats? _stats;
  bool _cancelled = false;
  bool _busy = false;
  Completer<void>? _gate;

  @override
  String get id => 'fake';

  @override
  bool get isSupported => supported;

  @override
  String? get unsupportedReason => supported ? null : 'Не поддерживается';

  @override
  bool get isLoaded => _info != null;

  @override
  LlmModelInfo? get loadedModel => _info;

  @override
  LlmRuntimeStats? get lastStats => _stats;

  @override
  Future<void> load(LlmModelFile model) async {
    loads++;
    // Сценарий теста задаёт любую ошибку (в том числе не Exception).
    // ignore: only_throw_errors
    if (loadError != null) throw loadError!;
    _info = LlmModelInfo(
      modelId: model.modelId,
      engineId: id,
      contextTokens: model.contextTokens,
      backend: 'cpu',
    );
  }

  /// Сразу «загружена» (для тестов, которым загрузка не важна).
  void markLoaded({int contextTokens = 4096}) {
    _info = LlmModelInfo(
      modelId: 'gemma-4-e2b-it',
      engineId: id,
      contextTokens: contextTokens,
      backend: 'cpu',
    );
  }

  /// Продолжает «зависший» ответ.
  void release() => _gate?.complete();

  @override
  Stream<String> generate(List<LlmTurn> turns, LlmGenerationParams params) {
    if (_busy) {
      return Stream.error(
        const LocalLlmException(LocalLlmErrorKind.busy, 'занято'),
      );
    }
    requests.add(List.of(turns));
    paramsSeen.add(params);
    final reply = replies.isEmpty ? FakeReply(['Ок']) : replies.removeAt(0);
    _busy = true;
    _cancelled = false;
    final controller = StreamController<String>();
    unawaited(() async {
      try {
        for (var i = 0; i < reply.tokens.length; i++) {
          // Сценарий теста задаёт любую ошибку (в том числе не Exception).
          // ignore: only_throw_errors
          if (reply.failAfter == i) throw reply.failWith!;
          if (reply.holdAfter == i) {
            _gate = Completer<void>();
            await _gate!.future;
          }
          if (_cancelled) break;
          await Future<void>.delayed(Duration.zero);
          if (_cancelled) break;
          controller.add(reply.tokens[i]);
        }
        if (reply.failAfter != null &&
            reply.failAfter! >= reply.tokens.length) {
          // Сценарий теста задаёт любую ошибку (в том числе не Exception).
          // ignore: only_throw_errors
          throw reply.failWith!;
        }
        _stats = reply.stats;
      } on Object catch (e) {
        controller.addError(e);
      } finally {
        _busy = false;
        await controller.close();
      }
    }());
    return controller.stream;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    _cancelled = true;
    _gate?.complete();
  }

  @override
  Future<void> unload() async {
    unloads++;
    _info = null;
  }
}

/// Поддельные ресурсы устройства.
class FakeResources implements DeviceResources {
  FakeResources({
    this.free = 100 * 1024 * 1024 * 1024,
    this.totalRam = 8 * 1024 * 1024 * 1024,
    this.availableRam = 5 * 1024 * 1024 * 1024,
    this.rss = 500 * 1024 * 1024,
    this.peak = 3 * 1024 * 1024 * 1024,
    this.thermalValue,
  });

  int? free;
  int? totalRam;
  int? availableRam;
  int? rss;
  int? peak;
  ThermalSample? thermalValue;

  @override
  Future<int?> freeDiskBytes(String path) async => free;

  @override
  Future<int?> totalRamBytes() async => totalRam;

  @override
  Future<int?> availableRamBytes() async => availableRam;

  @override
  Future<int?> currentRssBytes() async => rss;

  @override
  Future<int?> peakRssBytes() async => peak;

  @override
  Future<ThermalSample?> thermal() async => thermalValue;
}

/// Управляемая сеть.
class FakeNetwork implements NetworkProbe {
  FakeNetwork([this.kind = NetworkKind.wifi]);

  NetworkKind kind;
  final StreamController<NetworkKind> _changes =
      StreamController<NetworkKind>.broadcast();

  void set(NetworkKind value) {
    kind = value;
    _changes.add(value);
  }

  @override
  Future<NetworkKind> current() async => kind;

  @override
  Stream<NetworkKind> get changes => _changes.stream;
}

/// Поддельная загрузка: пишет заготовленные байты, умеет обрываться.
class FakeDownloader implements ModelDownloader {
  FakeDownloader(this.content);

  /// Содержимое «на сервере».
  final List<int> content;

  /// Сервер поддерживает `Range`.
  bool supportsRange = true;

  /// Оборвать загрузку после стольких байт (один раз).
  int? dropAfter;

  /// Ждать [releaseDownload] после этого числа байт (для сценариев
  /// «сеть сменилась посреди загрузки»).
  int? holdAt;
  Completer<void>? _hold;

  final List<int> resumePoints = [];
  int calls = 0;
  DownloadFailure? failure;

  void releaseDownload() => _hold?.complete();

  @override
  Future<DownloadOutcome> download({
    required Uri url,
    required File file,
    required int resumeFrom,
    required void Function(int received, int? total) onProgress,
    required DownloadCancelToken cancel,
  }) async {
    calls++;
    resumePoints.add(resumeFrom);
    if (failure != null) throw failure!;
    final from = supportsRange ? resumeFrom : 0;
    await file.parent.create(recursive: true);
    final raf = await file.open(
      mode: from > 0 ? FileMode.append : FileMode.write,
    );
    try {
      var received = from;
      onProgress(received, content.length);
      const step = 4;
      while (received < content.length) {
        if (cancel.isCancelled) {
          throw const DownloadFailure(
            DownloadFailureKind.network,
            'Загрузка остановлена',
          );
        }
        final holdPoint = holdAt;
        if (holdPoint != null && received >= holdPoint && _hold == null) {
          _hold = Completer<void>();
          await Future.any([_hold!.future, cancel.whenCancelled]);
          holdAt = null;
          if (cancel.isCancelled) {
            throw const DownloadFailure(
              DownloadFailureKind.network,
              'Загрузка остановлена',
            );
          }
        }
        final end = (received + step).clamp(0, content.length);
        await raf.writeFrom(content.sublist(received, end));
        received = end;
        onProgress(received, content.length);
        final drop = dropAfter;
        if (drop != null && received >= drop && received < content.length) {
          dropAfter = null;
          throw const DownloadFailure(
            DownloadFailureKind.network,
            'Обрыв соединения',
          );
        }
        await Future<void>.delayed(Duration.zero);
      }
      return DownloadOutcome(
        totalBytes: content.length,
        resumed: from > 0 && supportsRange,
      );
    } finally {
      await raf.close();
    }
  }
}
