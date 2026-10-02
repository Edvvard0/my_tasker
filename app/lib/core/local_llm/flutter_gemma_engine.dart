import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';

// Платформенный адаптер: тонкая склейка с пакетом `flutter_gemma`
// (LiteRT-LM). Вся логика — выше, по интерфейсу `LocalLlmEngine`; сам адаптер
// проверяется только на устройстве (экран замеров, этап «сборка»).
// coverage:ignore-file

/// Основной рантайм этапа 10: `flutter_gemma` + `flutter_gemma_litertlm`,
/// модель Gemma 4 E2B-it в формате `.litertlm`, **только CPU** (на Galaxy A55
/// GPU Xclipse в LiteRT-LM даёт мусор — решение этапа 10, п. 1).
///
/// Как устроено (проверено по `flutter_gemma` 1.11.3):
/// * файл модели скачивает наш менеджер (`LocalModelManager`), пакету он
///   отдаётся как внешний (`installModel(...).fromFile(path)`): пакет его не
///   копирует и не удаляет;
/// * `getActiveModel(maxTokens: контекст, preferredBackend: cpu)` — одна
///   модель на процесс; `maxTokens` — окно контекста, а не длина ответа;
/// * для каждой генерации создаётся новая сессия (`createSession`), в неё
///   подаются реплики по одной (`addQueryChunk`, `isUser` обязателен), шаблон
///   Gemma 4 применяет SDK; длину ответа ограничивает `maxOutputTokens`;
/// * отмена — `session.stopGeneration()` (отписки от потока мало).
///
/// Android: `minSdk 30`, только `arm64-v8a`, разрешение `INTERNET` в
/// релизной манифест-версии нужно только для загрузки (качаем сами через
/// Dio, плагину сеть не нужна).
class FlutterGemmaEngine implements LocalLlmEngine {
  FlutterGemmaEngine();

  static bool _initialized = false;

  InferenceModel? _model;
  InferenceModelSession? _session;
  LlmModelInfo? _info;
  LlmRuntimeStats? _lastStats;
  bool _busy = false;

  @override
  String get id => 'flutter_gemma';

  @override
  bool get isSupported =>
      Platform.isAndroid && Abi.current() == Abi.androidArm64;

  @override
  String? get unsupportedReason => isSupported
      ? null
      : 'Офлайн-модель работает только на Android (arm64). '
            'На этой платформе доступен облачный чат.';

  @override
  bool get isLoaded => _model != null;

  @override
  LlmModelInfo? get loadedModel => _info;

  @override
  LlmRuntimeStats? get lastStats => _lastStats;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await FlutterGemma.initialize(inferenceEngines: [const LiteRtLmEngine()]);
    _initialized = true;
  }

  @override
  Future<void> load(LlmModelFile model) async {
    if (!isSupported) {
      throw LocalLlmException(
        LocalLlmErrorKind.unsupportedPlatform,
        unsupportedReason!,
      );
    }
    await unload();
    try {
      await _ensureInitialized();
      await FlutterGemma.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromFile(model.path).install();
      final loaded = await FlutterGemma.getActiveModel(
        maxTokens: model.contextTokens,
        preferredBackend: PreferredBackend.cpu,
      );
      _model = loaded;
      _info = LlmModelInfo(
        modelId: model.modelId,
        engineId: id,
        contextTokens: model.contextTokens,
        backend: loaded.activeBackend?.name,
      );
    } on Object catch (e) {
      throw _mapError(e, LocalLlmErrorKind.loadFailed);
    }
  }

  LocalLlmException _mapError(Object e, LocalLlmErrorKind fallback) {
    final text = '$e'.toLowerCase();
    if (text.contains('memory') || text.contains('alloc')) {
      return const LocalLlmException(
        LocalLlmErrorKind.outOfMemory,
        'Не хватило памяти для модели. Закройте другие приложения.',
      );
    }
    return LocalLlmException(
      fallback,
      fallback == LocalLlmErrorKind.loadFailed
          ? 'Не удалось загрузить модель: $e'
          : 'Ошибка генерации: $e',
    );
  }

  @override
  Stream<String> generate(List<LlmTurn> turns, LlmGenerationParams params) {
    final model = _model;
    if (model == null) {
      return Stream.error(
        const LocalLlmException(
          LocalLlmErrorKind.notLoaded,
          'Модель не загружена',
        ),
      );
    }
    if (_busy) {
      return Stream.error(
        const LocalLlmException(
          LocalLlmErrorKind.busy,
          'Модель занята предыдущим ответом',
        ),
      );
    }
    _busy = true;
    final controller = StreamController<String>();
    var cancelled = false;
    unawaited(() async {
      InferenceModelSession? session;
      try {
        final system = turns
            .where((t) => t.role == LlmRole.system)
            .map((t) => t.text)
            .join('\n\n');
        session = await model.createSession(
          temperature: params.temperature,
          topK: params.topK,
          topP: params.topP,
          randomSeed: params.seed,
          maxOutputTokens: params.maxOutputTokens,
          systemInstruction: system.isEmpty ? null : system,
        );
        _session = session;
        for (final turn in turns) {
          if (turn.role == LlmRole.system) continue;
          await session.addQueryChunk(
            Message(text: turn.text, isUser: turn.role == LlmRole.user),
          );
        }
        await for (final token in session.getResponseAsync()) {
          if (cancelled) break;
          controller.add(token);
        }
        final metrics = session.getSessionMetrics();
        _lastStats = LlmRuntimeStats(
          inputTokens: metrics.inputTokens,
          outputTokens: metrics.outputTokens,
          timeToFirstTokenMs: metrics.timeToFirstTokenMs,
          tokensPerSecond: metrics.tokensPerSecond,
        );
      } on Object catch (e) {
        if (!cancelled) {
          controller.addError(_mapError(e, LocalLlmErrorKind.generationFailed));
        }
      } finally {
        _session = null;
        try {
          await session?.close();
        } on Object {
          // Сессия уже закрыта рантаймом.
        }
        _busy = false;
        await controller.close();
      }
    }());
    controller.onCancel = () async {
      cancelled = true;
      await _session?.stopGeneration();
    };
    return controller.stream;
  }

  @override
  Future<void> cancel() async {
    await _session?.stopGeneration();
  }

  @override
  Future<void> unload() async {
    final model = _model;
    _model = null;
    _info = null;
    if (model != null) {
      try {
        await model.close();
      } on Object {
        // Модель уже освобождена.
      }
    }
  }
}
