import 'package:my_tasker/core/local_llm/chat_templates.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';

/// ЗАГОТОВКА запасного рантайма: llama.cpp (пакет `llamadart`) + Qwen GGUF
/// Q4 (решение этапа 10, п. 2). Окончательный выбор рантайма — по замерам на
/// Galaxy A55 в конце этапа; пока адаптер только фиксирует форму интеграции
/// и не подключён: зависимость `llamadart` в `pubspec.yaml` НЕ добавлена.
///
/// План подключения (если замеры покажут, что flutter_gemma не подходит):
/// 1. добавить `llamadart` в `pubspec.yaml`, проверить его актуальный API
///    (`pub.dev/packages/llamadart`), нужна сборка под `arm64-v8a`;
/// 2. `load` — открыть GGUF по `LlmModelFile.path`, `nCtx = contextTokens`,
///    потоки по числу больших ядер Exynos 1480, без GPU;
/// 3. `generate` — подать [ChatMlTemplate]`.render(turns)` (для Gemma GGUF —
///    [GemmaChatTemplate]), читать токены потоком, остановка по
///    `stopSequences` шаблона и по `maxOutputTokens`;
/// 4. `cancel` — флаг прерывания рантайма; `unload` — освободить контекст;
/// 5. добавить запись Qwen GGUF в `localModelCatalog` с SHA-256.
class LlamaCppEngine implements LocalLlmEngine {
  const LlamaCppEngine({this.template = const ChatMlTemplate()});

  /// Шаблон модели, с которой работает адаптер (Qwen — ChatML).
  final ChatTemplate template;

  static const LocalLlmException _notReady = LocalLlmException(
    LocalLlmErrorKind.notImplemented,
    'Запасной движок llama.cpp ещё не подключён',
  );

  @override
  String get id => 'llama_cpp';

  @override
  bool get isSupported => false;

  @override
  String? get unsupportedReason => _notReady.message;

  @override
  bool get isLoaded => false;

  @override
  LlmModelInfo? get loadedModel => null;

  @override
  LlmRuntimeStats? get lastStats => null;

  @override
  Future<void> load(LlmModelFile model) => Future.error(_notReady);

  @override
  Stream<String> generate(List<LlmTurn> turns, LlmGenerationParams params) =>
      Stream.error(_notReady);

  @override
  Future<void> cancel() async {}

  @override
  Future<void> unload() async {}
}

/// Движок для платформ без офлайн-модели (Windows и др.): `isSupported`
/// ложно, любая попытка — понятная ошибка «недоступно».
class UnsupportedLlmEngine implements LocalLlmEngine {
  const UnsupportedLlmEngine([
    this.reason =
        'Офлайн-модель недоступна на этой платформе: она работает только '
        'на Android. Используйте облачный чат.',
  ]);

  final String reason;

  LocalLlmException get _error =>
      LocalLlmException(LocalLlmErrorKind.unsupportedPlatform, reason);

  @override
  String get id => 'unsupported';

  @override
  bool get isSupported => false;

  @override
  String? get unsupportedReason => reason;

  @override
  bool get isLoaded => false;

  @override
  LlmModelInfo? get loadedModel => null;

  @override
  LlmRuntimeStats? get lastStats => null;

  @override
  Future<void> load(LlmModelFile model) => Future.error(_error);

  @override
  Stream<String> generate(List<LlmTurn> turns, LlmGenerationParams params) =>
      Stream.error(_error);

  @override
  Future<void> cancel() async {}

  @override
  Future<void> unload() async {}
}
